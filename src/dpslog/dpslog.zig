//! DPS log module — TBC/WotLK-style COMBAT_LOG_EVENT_UNFILTERED for vanilla 1.12.1.
//!
//! Fires a unified COMBAT_LOG_EVENT_UNFILTERED with WotLK-style subevent names and
//! structured args. All subevents share: arg1=subevent, arg2=sourceGUID,
//! arg3=destGUID. Remaining args are subevent-specific.
//!
//! See reference/COMBAT_LOG_EVENT_WOTLK.md for full WotLK spec.
//! See RESEARCH.md "Implementation Status" for what's implemented vs TODO.
//!
//! WotLK CLEU parity — see WOTLK_CLEU_SPEC.md for full spec.
//! Base: arg1=subevent, arg2=sourceGUID, arg3=sourceName, arg4=destGUID, arg5=destName
//! Spell prefix: spellId, spellName, spellSchool
//! Env prefix: envType(string)
//! Swing prefix: (none)
//!
//!   _DAMAGE: amount, overkill(-1), school, resisted, blocked, absorbed,
//!       critical, glancing, crushing
//!   _MISSED: missType(string), amountMissed
//!   _HEAL: amount, overheal, absorbed, critical
//!   _ENERGIZE: amount, powerType
//!   _LEECH/_DRAIN: amount, powerType(-2=health), extraAmount
//!   _EXTRA_ATTACKS: amount
//!   _AURA_APPLIED/REMOVED: auraType(string)
//!   _AURA_DOSE: auraType(string), amount(stacks)
//!   _CAST_START/SUCCESS/INSTAKILL/SUMMON/RESURRECT: (prefix only)
//!   _CAST_FAILED: failedType(string)
//!   _INTERRUPT/_DISPEL_FAILED: extraSpellId, extraSpellName, extraSchool
//!   _DISPEL/_STOLEN/_AURA_BROKEN_SPELL: extraSpellId, extraSpellName,
//!       extraSchool, auraType(string)
//!   _AURA_BROKEN: auraType(string)
//!   UNIT_DIED/PARTY_KILL/UNIT_DESTROYED: (base only)
//!
//! Power types: 0=mana, 1=rage, 2=focus, 3=energy, 4=combo points
//! Env types:   0=EXHAUSTED, 1=DROWNING, 2=FALLING, 3=LAVA, 4=SLIME, 5=FIRE
//! Miss types:  "MISS", "DODGE", "PARRY", "BLOCK", "EVADE", "IMMUNE",
//!              "DEFLECT", "RESIST", "ABSORB", "REFLECT"
//! Aura types:  "BUFF", "DEBUFF"

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const lua = @import("../lua.zig");
const mod_mutex = @import("../mutex.zig");
const wow = @import("../wow.zig");
const o = @import("../offsets.zig");

pub const module_name: [*:0]const u8 = "dpslog";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

// Ring buffer for recent damage events — used by SPELL_AURA_BROKEN heuristic.
// Damage packets arrive BEFORE descriptor updates (which trigger aura removal),
// so the buffer is populated by the time auraRemovedDetour checks it.
const DAMAGE_RING_SIZE = 16;
const DamageEntry = struct {
    target_guid: u64 = 0,
    source_guid: u64 = 0,
    spell_id: u32 = 0,
};
var damage_ring: [DAMAGE_RING_SIZE]DamageEntry = [_]DamageEntry{.{}} ** DAMAGE_RING_SIZE;
var damage_ring_idx: u8 = 0;

fn recordDamage(target: u64, source: u64, spell_id: u32) void {
    damage_ring[damage_ring_idx] = .{ .target_guid = target, .source_guid = source, .spell_id = spell_id };
    damage_ring_idx = (damage_ring_idx + 1) % DAMAGE_RING_SIZE;
}

/// Find most recent damage to a target. Returns source GUID and spell ID.
fn findRecentDamage(target: u64) ?DamageEntry {
    // Search backwards from most recent entry
    var i: u8 = 0;
    while (i < DAMAGE_RING_SIZE) : (i += 1) {
        const idx = (damage_ring_idx -% 1 -% i) % DAMAGE_RING_SIZE;
        if (damage_ring[idx].target_guid == target) return damage_ring[idx];
    }
    return null;
}

// Ring buffer for recent spell casts — used to infer aura caster.
// SPELL_CAST_SUCCESS/SPELL_GO fire before SPELL_AURA_APPLIED, so the
// caster is in the buffer by the time the aura hook checks it.
const CAST_RING_SIZE = 32;
const CastEntry = struct {
    caster_guid: u64 = 0,
    target_guid: u64 = 0,
    spell_id: u32 = 0,
};
var cast_ring: [CAST_RING_SIZE]CastEntry = [_]CastEntry{.{}} ** CAST_RING_SIZE;
var cast_ring_idx: u8 = 0;

fn recordCast(caster: u64, target: u64, spell_id: u32) void {
    cast_ring[cast_ring_idx] = .{ .caster_guid = caster, .target_guid = target, .spell_id = spell_id };
    cast_ring_idx = (cast_ring_idx + 1) % CAST_RING_SIZE;
}

/// Find the caster of a spell on a target from recent casts.
fn findCaster(target: u64, spell_id: u32) u64 {
    var i: u8 = 0;
    while (i < CAST_RING_SIZE) : (i += 1) {
        const idx = (cast_ring_idx -% 1 -% i) % CAST_RING_SIZE;
        const entry = cast_ring[idx];
        if (entry.spell_id == spell_id and (entry.target_guid == target or entry.target_guid == 0)) {
            return entry.caster_guid;
        }
    }
    return 0;
}

// Per-unit per-slot caster tracking — set on SPELL_AURA_APPLIED, read on SPELL_AURA_REMOVED.
// Keyed by (unit_guid, slot_index) → caster_guid. Fixed-size cache, LRU eviction.
const AURA_CASTER_CACHE_SIZE = 128;
const AuraCasterEntry = struct {
    unit_guid: u64 = 0,
    slot: u32 = 0,
    caster_guid: u64 = 0,
};
var aura_caster_cache: [AURA_CASTER_CACHE_SIZE]AuraCasterEntry = [_]AuraCasterEntry{.{}} ** AURA_CASTER_CACHE_SIZE;
var aura_caster_idx: u8 = 0;

fn setAuraCaster(unit: u64, slot: u32, caster: u64) void {
    // Check if entry already exists and update it
    for (&aura_caster_cache) |*entry| {
        if (entry.unit_guid == unit and entry.slot == slot) {
            entry.caster_guid = caster;
            return;
        }
    }
    // New entry
    aura_caster_cache[aura_caster_idx] = .{ .unit_guid = unit, .slot = slot, .caster_guid = caster };
    aura_caster_idx = (aura_caster_idx +% 1) % AURA_CASTER_CACHE_SIZE;
}

fn getAuraCaster(unit: u64, slot: u32) u64 {
    for (aura_caster_cache) |entry| {
        if (entry.unit_guid == unit and entry.slot == slot) return entry.caster_guid;
    }
    return 0;
}

fn clearAuraCaster(unit: u64, slot: u32) void {
    for (&aura_caster_cache) |*entry| {
        if (entry.unit_guid == unit and entry.slot == slot) {
            entry.* = .{};
            return;
        }
    }
}

/// Scan a unit's aura slots for a damage shield spell matching the given school.
/// Returns the spell ID or 0 if not found.
/// SPELL_AURA_DAMAGE_SHIELD = 15 in EffectApplyAuraName.
const AURA_DAMAGE_SHIELD: u32 = 15;
const EFFECT_APPLY_AURA_NAME_BASE: u32 = 0x16C; // EffectApplyAuraName[0] in SpellRec

fn findDamageShieldSpell(attacker_guid: u64, school: u32) u32 {
    // Need the attacker's object to read aura descriptors.
    // This runs during packet handler processing (not aura callbacks),
    // but name resolution is deferred. We can safely look up the object here
    // since this is a table-swapped handler (object manager is stable).
    const obj = wow.getObjectByGUID(attacker_guid);
    if (obj == 0) return 0;
    const desc = wow.getDescriptor(obj);
    if (desc == 0) return 0;

    // UNIT_FIELD_AURA: 48 spell IDs at descriptor offset 0xA4 (index 0x29 from OBJECT_END=0x06)
    const AURA_BASE: u32 = 0xA4;
    var slot: u32 = 0;
    while (slot < 48) : (slot += 1) {
        const spell_id = hook.readMem(u32, desc + AURA_BASE + slot * 4);
        if (spell_id == 0) continue;

        // Check if this spell has a DAMAGE_SHIELD aura effect matching the school
        if (getSpellRecord(spell_id)) |rec| {
            const spell_school = hook.readMem(u32, rec + 0x04); // SpellRec.School
            // School match: packet school should match the spell's school
            if (spell_school & school != 0 or spell_school == school) {
                // Check EffectApplyAuraName[0..2] for DAMAGE_SHIELD (15)
                var eff: u32 = 0;
                while (eff < 3) : (eff += 1) {
                    const aura_name = hook.readMem(u32, rec + EFFECT_APPLY_AURA_NAME_BASE + eff * 4);
                    if (aura_name == AURA_DAMAGE_SHIELD) return spell_id;
                }
            }
        }
    }
    return 0;
}

/// SpellRec AuraInterruptFlags offset and damage-break bits.
const SPELL_AURA_INTERRUPT_FLAGS_OFFSET: u32 = 0x58;
const AURA_INTERRUPT_FLAG_DAMAGE: u32 = 0x02;
const AURA_INTERRUPT_FLAG_DIRECT_DAMAGE: u32 = 0x01000000;

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// COMBAT_LOG_EVENT_UNFILTERED — slot assigned dynamically in createEventsDetour
// =============================================================================

var g_event_combat_log: u32 = 0;
const EVENT_TABLE_MAIN: u32 = 0xBE1198;
const event_name: [*:0]const u8 = "COMBAT_LOG_EVENT_UNFILTERED";

// =============================================================================
// Subevent name strings (WotLK naming)
// =============================================================================

// Damage
const SUB_SWING_DAMAGE: [*:0]const u8 = "SWING_DAMAGE";
const SUB_RANGE_DAMAGE: [*:0]const u8 = "RANGE_DAMAGE";
const SUB_SPELL_DAMAGE: [*:0]const u8 = "SPELL_DAMAGE";
const SUB_SPELL_PERIODIC_DAMAGE: [*:0]const u8 = "SPELL_PERIODIC_DAMAGE";
const SUB_DAMAGE_SHIELD: [*:0]const u8 = "DAMAGE_SHIELD";
const SUB_ENV_DAMAGE: [*:0]const u8 = "ENVIRONMENTAL_DAMAGE";

// Missed
const SUB_SWING_MISSED: [*:0]const u8 = "SWING_MISSED";
const SUB_RANGE_MISSED: [*:0]const u8 = "RANGE_MISSED";
const SUB_SPELL_MISSED: [*:0]const u8 = "SPELL_MISSED";
const SUB_SPELL_PERIODIC_MISSED: [*:0]const u8 = "SPELL_PERIODIC_MISSED";
const SUB_DAMAGE_SHIELD_MISSED: [*:0]const u8 = "DAMAGE_SHIELD_MISSED";

// Heal
const SUB_SPELL_HEAL: [*:0]const u8 = "SPELL_HEAL";
const SUB_SPELL_PERIODIC_HEAL: [*:0]const u8 = "SPELL_PERIODIC_HEAL";

// Energize / Drain
const SUB_SPELL_ENERGIZE: [*:0]const u8 = "SPELL_ENERGIZE";
const SUB_SPELL_DRAIN: [*:0]const u8 = "SPELL_DRAIN";
const SUB_SPELL_PERIODIC_ENERGIZE: [*:0]const u8 = "SPELL_PERIODIC_ENERGIZE";
const SUB_SPELL_PERIODIC_DRAIN: [*:0]const u8 = "SPELL_PERIODIC_DRAIN";
const SUB_SPELL_PERIODIC_LEECH: [*:0]const u8 = "SPELL_PERIODIC_LEECH";

// Aura
const SUB_SPELL_AURA_APPLIED: [*:0]const u8 = "SPELL_AURA_APPLIED";
const SUB_SPELL_AURA_REMOVED: [*:0]const u8 = "SPELL_AURA_REMOVED";
const SUB_SPELL_AURA_APPLIED_DOSE: [*:0]const u8 = "SPELL_AURA_APPLIED_DOSE";
const SUB_SPELL_AURA_REMOVED_DOSE: [*:0]const u8 = "SPELL_AURA_REMOVED_DOSE";
const SUB_SPELL_AURA_REFRESH: [*:0]const u8 = "SPELL_AURA_REFRESH";
const SUB_SPELL_AURA_BROKEN: [*:0]const u8 = "SPELL_AURA_BROKEN";
const SUB_SPELL_AURA_BROKEN_SPELL: [*:0]const u8 = "SPELL_AURA_BROKEN_SPELL";

// Cast
const SUB_SPELL_CAST_START: [*:0]const u8 = "SPELL_CAST_START";
const SUB_SPELL_CAST_SUCCESS: [*:0]const u8 = "SPELL_CAST_SUCCESS";
const SUB_SPELL_CAST_FAILED: [*:0]const u8 = "SPELL_CAST_FAILED";

// Misc
const SUB_SPELL_INTERRUPT: [*:0]const u8 = "SPELL_INTERRUPT";
const SUB_SPELL_DISPEL: [*:0]const u8 = "SPELL_DISPEL";
const SUB_SPELL_STOLEN: [*:0]const u8 = "SPELL_STOLEN";
const SUB_SPELL_EXTRA_ATTACKS: [*:0]const u8 = "SPELL_EXTRA_ATTACKS";
const SUB_SPELL_SUMMON: [*:0]const u8 = "SPELL_SUMMON";
const SUB_SPELL_RESURRECT: [*:0]const u8 = "SPELL_RESURRECT";
const SUB_SPELL_INSTAKILL: [*:0]const u8 = "SPELL_INSTAKILL";
const SUB_PARTY_KILL: [*:0]const u8 = "PARTY_KILL";
const SUB_UNIT_DIED: [*:0]const u8 = "UNIT_DIED";
const SUB_DAMAGE_SPLIT: [*:0]const u8 = "DAMAGE_SPLIT";
const SUB_SPELL_DISPEL_FAILED: [*:0]const u8 = "SPELL_DISPEL_FAILED";
const SUB_UNIT_DESTROYED: [*:0]const u8 = "UNIT_DESTROYED";

// Miss type strings (for _MISSED suffix arg)
const MISS_MISS: [*:0]const u8 = "MISS";
const MISS_DODGE: [*:0]const u8 = "DODGE";
const MISS_PARRY: [*:0]const u8 = "PARRY";
const MISS_BLOCK: [*:0]const u8 = "BLOCK";
const MISS_EVADE: [*:0]const u8 = "EVADE";
const MISS_IMMUNE: [*:0]const u8 = "IMMUNE";
const MISS_DEFLECT: [*:0]const u8 = "DEFLECT";
const MISS_RESIST: [*:0]const u8 = "RESIST";
const MISS_ABSORB: [*:0]const u8 = "ABSORB";
const MISS_REFLECT: [*:0]const u8 = "REFLECT";

/// Zero GUID for events without a source.
const GUID_ZERO: [*:0]const u8 = "0x0000000000000000";

// Environmental damage type strings (WotLK naming)
const ENV_EXHAUSTED: [*:0]const u8 = "EXHAUSTED";
const ENV_DROWNING: [*:0]const u8 = "DROWNING";
const ENV_FALLING: [*:0]const u8 = "FALLING";
const ENV_LAVA: [*:0]const u8 = "LAVA";
const ENV_SLIME: [*:0]const u8 = "SLIME";
const ENV_FIRE: [*:0]const u8 = "FIRE";

fn envTypeToString(env_type: u32) [*:0]const u8 {
    return switch (env_type) {
        0 => ENV_EXHAUSTED,
        1 => ENV_DROWNING,
        2 => ENV_FALLING,
        3 => ENV_LAVA,
        4 => ENV_SLIME,
        5 => ENV_FIRE,
        else => ENV_FALLING,
    };
}

// =============================================================================
// Melee hitInfo flags (from cmangos)
// =============================================================================

const HITINFO_LEFTSWING: u32 = 0x04;
const HITINFO_MISS: u32 = 0x10;
const HITINFO_CRITICALHIT: u32 = 0x80;
const HITINFO_BLOCK: u32 = 0x800;
const HITINFO_CRUSHING: u32 = 0x2000;
const HITINFO_GLANCING: u32 = 0x4000;

// =============================================================================
// Unit power descriptor offsets (from m_data at obj+0x08)
// =============================================================================

/// UNIT_FIELD_HEALTH at absolute index 0x16. Offset = 0x58.
const DESC_HEALTH: u32 = 0x16 * 4; // 0x58
/// UNIT_FIELD_MAXHEALTH at absolute index 0x1C. Offset = 0x70.
const DESC_MAXHEALTH: u32 = 0x1C * 4; // 0x70
/// UNIT_FIELD_POWER1 at absolute index 0x17. Power(N) = 0x5C + N*4.
const DESC_POWER_BASE: u32 = 0x17 * 4; // 0x5C
/// UNIT_FIELD_MAXPOWER1 at absolute index 0x1D. MaxPower(N) = 0x74 + N*4.
const DESC_MAXPOWER_BASE: u32 = 0x1D * 4; // 0x74

// Victim states
const VS_UNAFFECTED: u32 = 0;
const VS_NORMAL: u32 = 1;
const VS_DODGE: u32 = 2;
const VS_PARRY: u32 = 3;
const VS_INTERRUPT: u32 = 4;
const VS_BLOCK: u32 = 5;
const VS_EVADE: u32 = 6;
const VS_IMMUNE: u32 = 7;
const VS_DEFLECT: u32 = 8;

// =============================================================================
// CDataStore helpers
// =============================================================================

const CDS_BUFFER = 0x04;
const CDS_BASE = 0x08;
const CDS_SIZE = 0x10;
const CDS_READ = 0x14;

fn cdsGetRead(cds: u32) u32 {
    return hook.readMem(u32, cds + CDS_READ);
}

fn cdsSetRead(cds: u32, pos: u32) void {
    @as(*align(1) u32, @ptrFromInt(cds + CDS_READ)).* = pos;
}

fn cdsBuffer(cds: u32) u32 {
    return hook.readMem(u32, cds + CDS_BUFFER);
}

fn cdsBase(cds: u32) u32 {
    return hook.readMem(u32, cds + CDS_BASE);
}

fn cdsSize(cds: u32) u32 {
    return hook.readMem(u32, cds + CDS_SIZE);
}

fn cdsGet(comptime T: type, cds: u32) ?T {
    const rpos = cdsGetRead(cds);
    const end = rpos + @sizeOf(T);
    if (end > cdsSize(cds)) return null;
    const buf = cdsBuffer(cds);
    const base = cdsBase(cds);
    const val = @as(*align(1) const T, @ptrFromInt(buf -% base + rpos)).*;
    cdsSetRead(cds, end);
    return val;
}

fn cdsGetPackedGuid(cds: u32) ?u64 {
    const mask = cdsGet(u8, cds) orelse return null;
    var guid: u64 = 0;
    inline for (0..8) |i| {
        if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
            const b = cdsGet(u8, cds) orelse return null;
            guid |= @as(u64, b) << @intCast(i * 8);
        }
    }
    return guid;
}

// =============================================================================
// GUID → hex string conversion
// =============================================================================

var guid_bufs: [4][20]u8 = undefined;
var guid_buf_idx: u2 = 0;

fn guidToString(guid: u64) [*:0]const u8 {
    const idx = guid_buf_idx;
    guid_buf_idx +%= 1;
    const buf = &guid_bufs[idx];

    buf[0] = '0';
    buf[1] = 'x';
    const hex = "0123456789ABCDEF";
    inline for (0..16) |i| {
        const shift: u6 = @intCast((15 - i) * 4);
        buf[2 + i] = hex[@intCast((guid >> shift) & 0xF)];
    }
    buf[18] = 0;
    return @ptrCast(buf[0..18 :0]);
}

// =============================================================================
// Handler Table Swap — replace NetClient opcode dispatch entries
// =============================================================================
//
// NetClient__ProcessMessage (0x537AA0) dispatches packets via:
//   handler = NetClient[opcode * 4 + 0x74]
//   call handler(ECX=context, EDX=opcode, stack: timestamp, CDataStore*)
//
// We swap pointers in the heap-allocated NetClient object (no code patching).
// Original handler is saved and called after our processing.

const NETCLIENT_PTR: u32 = 0xC28128;
const HANDLER_TABLE_BASE: u32 = 0x74;

const HandlerSwap = struct {
    opcode: u16,
    original: u32 = 0,
    active: bool = false,
};

// Max swaps we'll ever need (one per opcode we intercept)
const MAX_SWAPS = 16;
var handler_swaps: [MAX_SWAPS]HandlerSwap = [_]HandlerSwap{.{ .opcode = 0 }} ** MAX_SWAPS;
var swap_count: u32 = 0;

fn getNetClient() ?u32 {
    const nc = hook.readMem(u32, NETCLIENT_PTR);
    return if (nc != 0) nc else null;
}

fn handlerSlotAddr(net_client: u32, opcode: u16) u32 {
    return net_client + @as(u32, opcode) * 4 + HANDLER_TABLE_BASE;
}

fn swapHandler(opcode: u16, replacement: u32) bool {
    const nc = getNetClient() orelse {
        log.fmt("swapHandler: NetClient is NULL, cannot swap opcode 0x{X}\n", .{opcode});
        return false;
    };
    if (swap_count >= MAX_SWAPS) {
        log.fmt("swapHandler: swap table full\n", .{});
        return false;
    }
    const slot = handlerSlotAddr(nc, opcode);
    const original = hook.readMem(u32, slot);
    if (original == 0) {
        log.fmt("swapHandler: no handler registered for opcode 0x{X}\n", .{opcode});
        return false;
    }

    handler_swaps[swap_count] = .{
        .opcode = opcode,
        .original = original,
        .active = true,
    };
    swap_count += 1;

    // Write our replacement into the table (heap memory, writable)
    @as(*align(1) u32, @ptrFromInt(slot)).* = replacement;
    log.fmt("swapHandler: opcode 0x{X} swapped (original=0x{X})\n", .{ opcode, original });
    return true;
}

fn getOriginalHandler(opcode: u16) ?u32 {
    for (handler_swaps[0..swap_count]) |entry| {
        if (entry.opcode == opcode and entry.active) return entry.original;
    }
    return null;
}

fn callOriginalHandler(opcode: u16, unk: u32, opc: u32, unk2: u32, cds: u32) u32 {
    const original = getOriginalHandler(opcode) orelse return 0;
    return @call(.auto, @as(*const FastCallPacketHandlerFn, @ptrFromInt(original)), .{ unk, opc, unk2, cds });
}

fn restoreAllHandlers() void {
    const nc = getNetClient() orelse return;
    for (handler_swaps[0..swap_count]) |*entry| {
        if (entry.active) {
            const slot = handlerSlotAddr(nc, entry.opcode);
            @as(*align(1) u32, @ptrFromInt(slot)).* = entry.original;
            entry.active = false;
            log.fmt("restoreHandler: opcode 0x{X} restored\n", .{entry.opcode});
        }
    }
    swap_count = 0;
}

// =============================================================================
// SignalEventParam fire functions — one per format pattern
// =============================================================================
//
// SignalEventParam (0x703F50): __cdecl(eventId, fmtStr, ...)
// Each fire function uses a specific format string for its arg pattern.
// On x86 cdecl, all args are 4 bytes on stack (pointers and ints alike).

const SIGNAL: u32 = 0x703F50;

// =============================================================================
// Unit flags — WotLK COMBATLOG_OBJECT_* bitmask computation
// =============================================================================

// Affiliation
const FLAG_AFFILIATION_MINE: u32 = 0x1;
const FLAG_AFFILIATION_PARTY: u32 = 0x2;
const FLAG_AFFILIATION_RAID: u32 = 0x4;
const FLAG_AFFILIATION_OUTSIDER: u32 = 0x8;

// Reaction
const FLAG_REACTION_FRIENDLY: u32 = 0x10;
const FLAG_REACTION_NEUTRAL: u32 = 0x20;
const FLAG_REACTION_HOSTILE: u32 = 0x40;

// Control
const FLAG_CONTROL_PLAYER: u32 = 0x100;
const FLAG_CONTROL_NPC: u32 = 0x200;

// Type
const FLAG_TYPE_PLAYER: u32 = 0x400;
const FLAG_TYPE_NPC: u32 = 0x800;
const FLAG_TYPE_PET: u32 = 0x1000;
const FLAG_TYPE_GUARDIAN: u32 = 0x2000;
const FLAG_TYPE_OBJECT: u32 = 0x4000;

// Special (non-exclusive, OR'd into main flags)
const FLAG_TARGET: u32 = 0x10000;
const FLAG_FOCUS: u32 = 0x20000;
const FLAG_MAINASSIST: u32 = 0x80000;

const PARTY_MEMBER_GUIDS: u32 = 0x00BC75F8 + 8; // party[0] GUID at leader+8 (leader at BC75F8)
const RAID_ROSTER_ARRAY: u32 = 0x00B712A8;
const RAID_MEMBER_COUNT: u32 = 0x00B713E0;

fn computeUnitFlags(guid: u64) u32 {
    if (guid == 0) return 0;

    // getObjectByGUID walks the object manager hash table, which is unsafe during
    // SMSG_UPDATE_OBJECT processing (aura hooks fire mid-update, hash table may be inconsistent).
    // TODO: find a safe way to compute flags without object manager access.
    // For now, infer what we can from the GUID type alone.
    const hi: u32 = @truncate(guid >> 32);
    const guid_type: u32 = (hi >> 16) & 0xF0F0;
    if (guid_type == 0x0000) {
        // Player GUID — we know it's a player, but can't determine reaction/affiliation safely
        return FLAG_TYPE_PLAYER | FLAG_CONTROL_PLAYER | FLAG_REACTION_FRIENDLY | FLAG_AFFILIATION_OUTSIDER;
    }

    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return FLAG_AFFILIATION_OUTSIDER | FLAG_REACTION_HOSTILE | FLAG_CONTROL_NPC | FLAG_TYPE_NPC;

    var flags: u32 = 0;

    // --- Type + Control ---
    const obj_type = wow.getObjectType(obj);
    switch (obj_type) {
        .player => {
            flags |= FLAG_TYPE_PLAYER | FLAG_CONTROL_PLAYER;
        },
        .unit => {
            // Check if this is a pet/guardian (has summoner) or an NPC
            const desc = wow.getUnitDescriptor(obj);
            if (desc != 0) {
                const summoner = wow.readGUID(desc + o.DESC_SUMMONEDBY);
                if (summoner != 0) {
                    // Summoned unit — pet or guardian. Check if summoner is a player.
                    const summoner_obj = wow.getObjectByGUID(summoner);
                    if (summoner_obj != 0 and wow.getObjectType(summoner_obj) == .player) {
                        flags |= FLAG_TYPE_PET | FLAG_CONTROL_PLAYER;
                    } else {
                        flags |= FLAG_TYPE_GUARDIAN | FLAG_CONTROL_NPC;
                    }
                } else {
                    flags |= FLAG_TYPE_NPC | FLAG_CONTROL_NPC;
                }
            } else {
                flags |= FLAG_TYPE_NPC | FLAG_CONTROL_NPC;
            }
        },
        else => {
            flags |= FLAG_TYPE_OBJECT | FLAG_CONTROL_NPC;
        },
    }

    // --- Reaction ---
    const local_player = wow.getLocalPlayer();
    if (local_player != 0 and obj != local_player) {
        const reaction = hook.call(fn (u32, u32) callconv(hook.cc.thiscall) u32, o.FN_UNIT_REACTION, .{ local_player, obj });
        if (reaction >= 4) {
            flags |= FLAG_REACTION_FRIENDLY;
        } else if (reaction >= 2) {
            flags |= FLAG_REACTION_NEUTRAL;
        } else {
            flags |= FLAG_REACTION_HOSTILE;
        }
    } else {
        flags |= FLAG_REACTION_FRIENDLY; // self is always friendly
    }

    // --- Affiliation ---
    const my_guid = wow.getPlayerGUID();
    if (guid == my_guid) {
        flags |= FLAG_AFFILIATION_MINE;
    } else if (isInRaid(guid)) {
        flags |= FLAG_AFFILIATION_RAID;
    } else if (isInParty(guid)) {
        flags |= FLAG_AFFILIATION_PARTY;
    } else {
        // Check if this is our pet (summoner = us)
        if (obj_type == .unit) {
            const desc2 = wow.getUnitDescriptor(obj);
            if (desc2 != 0) {
                const summoner2 = wow.readGUID(desc2 + o.DESC_SUMMONEDBY);
                if (summoner2 == my_guid) {
                    flags |= FLAG_AFFILIATION_MINE;
                }
            }
        }
        if (flags & 0xF == 0) {
            flags |= FLAG_AFFILIATION_OUTSIDER;
        }
    }

    // --- Special flags ---
    const target_guid = wow.unitGUID("target");
    if (target_guid != 0 and guid == target_guid) {
        flags |= FLAG_TARGET;
    }
    // No focus target in vanilla (added in TBC)

    return flags;
}

fn computeRaidFlags(guid: u64) u32 {
    if (guid == 0) return 0;
    // Check raid target markers (Star=0 through Skull=7)
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const marker_guid = wow.readGUID(o.RAID_TARGET_ARRAY + i * 8);
        if (marker_guid != 0 and marker_guid == guid) {
            return @as(u32, 1) << @intCast(i);
        }
    }
    return 0;
}

fn isInRaid(guid: u64) bool {
    const count = hook.readMem(u32, RAID_MEMBER_COUNT);
    if (count == 0) return false;
    const arr = hook.readMem(u32, RAID_ROSTER_ARRAY);
    if (arr == 0) return false;
    var i: u32 = 0;
    while (i < count and i < 40) : (i += 1) {
        const entry_ptr = hook.readMem(u32, arr + i * 4);
        if (entry_ptr == 0 or !wow.isValidPtr(entry_ptr)) continue;
        const member_guid = wow.readGUID(entry_ptr);
        if (member_guid == guid) return true;
    }
    return false;
}

fn isInParty(guid: u64) bool {
    // Party member GUIDs at 0xBC75F8+8 (4 members, 8 bytes each)
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const member_guid = wow.readGUID(PARTY_MEMBER_GUIDS + i * 8);
        if (member_guid != 0 and member_guid == guid) return true;
    }
    return false;
}

// =============================================================================
// Fire functions — WotLK CLEU parity (see WOTLK_CLEU_SPEC.md)
//
// Base args: sub(s), srcGUID(s), srcName(s), dstGUID(s), dstName(s)
// Spell prefix: spellId(d), spellName(s), spellSchool(d)
// Env prefix: envType(s)
// Swing prefix: (none)
// =============================================================================

/// Convert u32 boolean (0 or nonzero) to Lua-compatible value:
/// nonzero → "1" string pointer (truthy in Lua)
/// zero → null pointer (pushes nil via %s in SignalEventParam)
const LUA_TRUE: [*:0]const u8 = "1";
fn boolToLua(val: u32) u32 {
    return if (val != 0) @intFromPtr(LUA_TRUE) else 0;
}

// =============================================================================
// CombatLogGetCurrentEventInfo — lazy arg retrieval
// =============================================================================
//
// Fire functions store raw IDs/GUIDs. All name resolution, flag computation,
// and spell lookups happen lazily in luaCombatLogGetCurrentEventInfo() when
// addons request the data — at which point the object manager is stable.

const CLEUArgType = enum { str, num, bool_val, nil, guid, spell_id, damage_shield_spell };

const DamageShieldKey = struct {
    attacker_guid: u64,
    school: u32,
};

const CLEUArg = union {
    str: [*:0]const u8,
    num: u32,
    guid: u64,
    ds_key: DamageShieldKey,
    nil: void,
};

const CLEUEntry = struct {
    arg: CLEUArg,
    typ: CLEUArgType,
};

const MAX_CLEU_ARGS = 30;
var g_cleu_args: [MAX_CLEU_ARGS]CLEUEntry = undefined;
var g_cleu_count: u32 = 0;

fn cleuReset() void {
    g_cleu_count = 0;
}

fn cleuStr(s: [*:0]const u8) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    g_cleu_args[g_cleu_count] = .{ .arg = .{ .str = s }, .typ = .str };
    g_cleu_count += 1;
}

fn cleuNum(n: u32) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    g_cleu_args[g_cleu_count] = .{ .arg = .{ .num = n }, .typ = .num };
    g_cleu_count += 1;
}

fn cleuBool(val: u32) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    if (val != 0) {
        g_cleu_args[g_cleu_count] = .{ .arg = .{ .num = 1 }, .typ = .bool_val };
    } else {
        g_cleu_args[g_cleu_count] = .{ .arg = .{ .nil = {} }, .typ = .nil };
    }
    g_cleu_count += 1;
}

/// Store a GUID for deferred resolution. At request time, pushes:
/// guidString, name, unitFlags, raidFlags (4 values)
fn cleuGuid(guid: u64) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    g_cleu_args[g_cleu_count] = .{ .arg = .{ .guid = guid }, .typ = .guid };
    g_cleu_count += 1;
}

/// Store a spell ID for deferred resolution. At request time, pushes:
/// spellId, spellName, spellSchool (3 values)
fn cleuSpellId(id: u32) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    g_cleu_args[g_cleu_count] = .{ .arg = .{ .num = id }, .typ = .spell_id };
    g_cleu_count += 1;
}

/// Store a damage shield spell lookup key. At request time, scans attacker's
/// auras for a DAMAGE_SHIELD effect matching the school, then pushes:
/// spellId, spellName, spellSchool (3 values)
fn cleuDamageShieldSpell(attacker_guid: u64, school: u32) void {
    if (g_cleu_count >= MAX_CLEU_ARGS) return;
    g_cleu_args[g_cleu_count] = .{ .arg = .{ .ds_key = .{ .attacker_guid = attacker_guid, .school = school } }, .typ = .damage_shield_spell };
    g_cleu_count += 1;
}

/// Store base args: subevent, srcGUID (deferred), dstGUID (deferred)
fn cleuBase(sub: [*:0]const u8, src_guid: u64, dst_guid: u64) void {
    cleuReset();
    cleuStr(sub);
    cleuGuid(src_guid); // expands to: srcGUID, srcName, srcFlags, srcRaidFlags
    cleuGuid(dst_guid); // expands to: dstGUID, dstName, dstFlags, dstRaidFlags
}

/// Store spell prefix as deferred spell ID
fn cleuSpellPrefix(id: u32) void {
    cleuSpellId(id);
}

fn signalEvent() void {
    const F = fn (u32, [*:0]const u8) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "" });
}

/// Resolve all deferred values and push to Lua. Called from Lua event handlers
/// when the object manager is stable.
pub fn luaCombatLogGetCurrentEventInfo(L: usize) callconv(hook.cc.fastcall) u32 {
    const state: lua.State = @ptrFromInt(L);
    var push_count: u32 = 0;
    var i: u32 = 0;
    while (i < g_cleu_count) : (i += 1) {
        const entry = g_cleu_args[i];
        switch (entry.typ) {
            .str => {
                lua.pushstring(state, entry.arg.str);
                push_count += 1;
            },
            .num => {
                lua.pushnumber(state, @floatFromInt(@as(i32, @bitCast(entry.arg.num))));
                push_count += 1;
            },
            .bool_val => {
                lua.pushnumber(state, 1.0);
                push_count += 1;
            },
            .nil => {
                lua.pushnil(state);
                push_count += 1;
            },
            .guid => {
                // Deferred GUID: push guidString, name, flags, raidFlags
                const guid = entry.arg.guid;
                lua.pushstring(state, guidToString(guid));
                lua.pushstring(state, wow.getNameByGUID(guid));
                lua.pushnumber(state, @floatFromInt(computeUnitFlags(guid)));
                lua.pushnumber(state, @floatFromInt(computeRaidFlags(guid)));
                push_count += 4;
            },
            .spell_id => {
                // Deferred spell: push spellId, spellName, spellSchool
                const id = entry.arg.num;
                lua.pushnumber(state, @floatFromInt(id));
                lua.pushstring(state, getSpellName(id));
                lua.pushnumber(state, @floatFromInt(getSpellSchool(id)));
                push_count += 3;
            },
            .damage_shield_spell => {
                // Deferred damage shield: scan attacker auras, push spellId, spellName, spellSchool
                const key = entry.arg.ds_key;
                const id = findDamageShieldSpell(key.attacker_guid, key.school);
                lua.pushnumber(state, @floatFromInt(id));
                lua.pushstring(state, getSpellName(id));
                lua.pushnumber(state, @floatFromInt(if (id != 0) getSpellSchool(id) else key.school));
                push_count += 3;
            },
        }
    }
    return push_count;
}

/// Spell prefix + _DAMAGE suffix (9 fields: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing)
/// Used by: SPELL_DAMAGE, RANGE_DAMAGE, SPELL_PERIODIC_DAMAGE, DAMAGE_SHIELD, DAMAGE_SPLIT
fn fireSpellDamage(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, amount: u32, overkill: u32, dmg_school: u32, resisted: u32, blocked: u32, absorbed: u32, critical: u32, glancing: u32, crushing: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuNum(amount); cleuNum(overkill); cleuNum(dmg_school); cleuNum(resisted);
    cleuNum(blocked); cleuNum(absorbed); cleuBool(critical); cleuBool(glancing); cleuBool(crushing);
    signalEvent();
}

fn fireSwingDamage(src_guid: u64, dst_guid: u64, amount: u32, overkill: u32, school: u32, resisted: u32, blocked: u32, absorbed: u32, critical: u32, glancing: u32, crushing: u32) void {
    cleuBase(SUB_SWING_DAMAGE, src_guid, dst_guid);
    cleuNum(amount); cleuNum(overkill); cleuNum(school); cleuNum(resisted);
    cleuNum(blocked); cleuNum(absorbed); cleuBool(critical); cleuBool(glancing); cleuBool(crushing);
    signalEvent();
}

fn fireEnvDamage(dst_guid: u64, env_str: [*:0]const u8, amount: u32, overkill: u32, school: u32, resisted: u32, blocked: u32, absorbed: u32, critical: u32, glancing: u32, crushing: u32) void {
    cleuBase(SUB_ENV_DAMAGE, 0, dst_guid);
    cleuStr(env_str);
    cleuNum(amount); cleuNum(overkill); cleuNum(school); cleuNum(resisted);
    cleuNum(blocked); cleuNum(absorbed); cleuBool(critical); cleuBool(glancing); cleuBool(crushing);
    signalEvent();
}

fn fireSwingMissed(src_guid: u64, dst_guid: u64, miss_type: [*:0]const u8, amount_missed: u32) void {
    cleuBase(SUB_SWING_MISSED, src_guid, dst_guid);
    cleuStr(miss_type); cleuNum(amount_missed);
    signalEvent();
}

fn fireSpellMissed(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, miss_type: [*:0]const u8, amount_missed: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuStr(miss_type); cleuNum(amount_missed);
    signalEvent();
}

fn fireSpellHeal(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, amount: u32, overheal: u32, absorbed: u32, critical: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuNum(amount); cleuNum(overheal); cleuNum(absorbed); cleuBool(critical);
    signalEvent();
}

fn fireSpellEnergize(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, amount: u32, power_type: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuNum(amount); cleuNum(power_type);
    signalEvent();
}

fn fireSpellLeech(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, amount: u32, power_type: u32, extra_amount: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuNum(amount); cleuNum(power_type); cleuNum(extra_amount);
    signalEvent();
}

fn fireSpellExtraAttacks(src_guid: u64, dst_guid: u64, id: u32, amount: u32) void {
    cleuBase(SUB_SPELL_EXTRA_ATTACKS, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuNum(amount);
    signalEvent();
}

fn fireSpellStr(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, str_arg: [*:0]const u8) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuStr(str_arg);
    signalEvent();
}

fn fireSpellStrD(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, str_arg: [*:0]const u8, amount: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuStr(str_arg); cleuNum(amount);
    signalEvent();
}

fn fireSpell(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    signalEvent();
}

fn fireSpellInterrupt(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, extra_id: u32) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuSpellId(extra_id); // interrupted/resisted spell — deferred resolution
    signalEvent();
}

fn fireSpellDispel(sub: [*:0]const u8, src_guid: u64, dst_guid: u64, id: u32, extra_id: u32, aura_type: [*:0]const u8) void {
    cleuBase(sub, src_guid, dst_guid);
    cleuSpellPrefix(id);
    cleuSpellId(extra_id); // dispelled spell — deferred resolution
    cleuStr(aura_type);
    signalEvent();
}

fn fireBase(sub: [*:0]const u8, src_guid: u64, dst_guid: u64) void {
    cleuBase(sub, src_guid, dst_guid);
    signalEvent();
}

// =============================================================================
// Hook: InitializeGameEngine (0x401570)
// __thiscall(ECX=this), RET 0xC (3 stack params)
// Registers all packet handlers. We install table swaps after it returns.
// =============================================================================

const InitGameEngineFn = fn (u32, u32, u32, u32) callconv(hook.cc.thiscall) void;
var init_engine_hook: hook.Detour(InitGameEngineFn) = .{};

fn initGameEngineDetour(this: u32, p1: u32, p2: u32, p3: u32) callconv(hook.cc.thiscall) void {
    init_engine_hook.callOriginal(.{ this, p1, p2, p3 });
    // All packet handlers are now registered — install our table swaps
    installHandlerSwaps();
}

// =============================================================================
// Hook: FrameScript_CreateEvents (0x703D90)
// After the chain runs, write our event into the internal table.
// =============================================================================

var create_events_hook: hook.Detour(fn (u32, u32) callconv(hook.cc.fastcall) void) = .{};

/// DuplicateStringWithAllocation at 0x64a620 — allocates via SMemAlloc and copies.
/// Same function SuperWoW uses to register its custom events.
const DupString = fn ([*:0]const u8, [*:0]const u8, u32) callconv(hook.cc.stdcall) u32;
const DUP_STRING: u32 = 0x64a620;
const DUP_STRING_SRC: [*:0]const u8 = "dpslog";

const PREFERRED_EVENT_SLOT: u32 = 650;
const MAX_EVENT_SLOT: u32 = 800;
const MIN_EVENT_CAPACITY: u32 = MAX_EVENT_SLOT + 1;
const INTERNAL_ARRAY_PTR: u32 = 0x00ceef68;
const INTERNAL_CAPACITY_PTR: u32 = 0x00ceef64;

// =============================================================================
// Hook: resize_lua_event_array (0x7053B0)
// __thiscall(ECX=&struct_ceef60, stack=new_count)
// If count > 200 (not GlueXML), expand to at least MIN_EVENT_CAPACITY.
// =============================================================================

const EVENT_STRUCT: u32 = 0x00ceef60;

var resize_events_hook: hook.Detour(fn (u32, u32) callconv(hook.cc.thiscall) void) = .{};

fn resizeEventsDetour(this: u32, new_count: u32) callconv(hook.cc.thiscall) void {
    var count = new_count;
    if (count > 200 and count < MIN_EVENT_CAPACITY) {
        log.fmt("resizeEventsDetour: expanding {d} -> {d}\n", .{ count, MIN_EVENT_CAPACITY });
        count = MIN_EVENT_CAPACITY;
    }
    resize_events_hook.callOriginal(.{ this, count });
}

fn createEventsDetour(param1: u32, max_event_id: u32) callconv(hook.cc.fastcall) void {
    create_events_hook.callOriginal(.{ param1, max_event_id });

    if (param1 == EVENT_TABLE_MAIN) {
        const capacity = hook.readMem(u32, INTERNAL_CAPACITY_PTR);
        const internal_array = hook.readMem(u32, INTERNAL_ARRAY_PTR);

        if (internal_array == 0 or capacity <= PREFERRED_EVENT_SLOT) {
            log.fmt("createEventsDetour: capacity {d} too small\n", .{capacity});
            return;
        }

        // Find an empty slot (name_ptr == 0), starting at preferred slot.
        const limit = @min(capacity, MAX_EVENT_SLOT + 1);
        var slot: u32 = PREFERRED_EVENT_SLOT;
        while (slot < limit) : (slot += 1) {
            const name_at_slot = hook.readMem(u32, internal_array + slot * 16);
            if (name_at_slot == 0) break;
        }
        if (slot >= limit) {
            log.fmt("createEventsDetour: no empty slot in {d}-{d}\n", .{ PREFERRED_EVENT_SLOT, limit - 1 });
            return;
        }

        // Duplicate our event name string using the engine's allocator.
        const name_ptr = @call(.auto, @as(*const DupString, @ptrFromInt(DUP_STRING)), .{ event_name, DUP_STRING_SRC, 0x51c });

        // Write into internal table entry: each entry is 16 bytes, name at +0.
        hook.writeMem(internal_array + slot * 16, std.mem.asBytes(&name_ptr));
        g_event_combat_log = slot;

        log.fmt("createEventsDetour: COMBAT_LOG_EVENT_UNFILTERED at slot {d}, capacity={d}\n", .{ slot, capacity });
    }
}

fn installHandlerSwaps() void {
    // Always re-install — InitializeGameEngine re-registers all handlers,
    // overwriting any previous swaps (even if NetClient pointer is the same).
    swap_count = 0;
    // Packet handler table swaps (no code patching, heap pointer writes only)
    if (!swapHandler(0x250, @intFromPtr(&spellNonMeleeDmgLogDetour)))
        log.print("FAILED to swap SPELLNONMELEEDAMAGELOG (0x250)\n")
    else
        log.print("Swapped SPELLNONMELEEDAMAGELOG (0x250)\n");

    if (!swapHandler(0x24E, @intFromPtr(&periodicAuraLogDetour)))
        log.print("FAILED to swap PERIODICAURALOG (0x24E)\n")
    else
        log.print("Swapped PERIODICAURALOG (0x24E)\n");

    if (!swapHandler(0x150, @intFromPtr(&healLogDetour)))
        log.print("FAILED to swap SPELLHEALLOG (0x150)\n")
    else
        log.print("Swapped SPELLHEALLOG (0x150)\n");

    if (!swapHandler(0x14A, @intFromPtr(&meleeDispatcherDetour)))
        log.print("FAILED to swap ATTACKERSTATEUPDATE (0x14A)\n")
    else
        log.print("Swapped ATTACKERSTATEUPDATE (0x14A)\n");

    if (!swapHandler(0x1F5, @intFromPtr(&partyKillLogDetour)))
        log.print("FAILED to swap PARTYKILLLOG (0x1F5)\n")
    else
        log.print("Swapped PARTYKILLLOG (0x1F5)\n");

    if (!swapHandler(0x131, @intFromPtr(&spellStartDetour)))
        log.print("FAILED to swap SPELL_START (0x131)\n")
    else
        log.print("Swapped SPELL_START (0x131)\n");

    if (!swapHandler(0x132, @intFromPtr(&spellStartDetour)))
        log.print("FAILED to swap SPELL_GO (0x132)\n")
    else
        log.print("Swapped SPELL_GO (0x132)\n");

    if (!swapHandler(0x130, @intFromPtr(&castResultDetour)))
        log.print("FAILED to swap CAST_RESULT (0x130)\n")
    else
        log.print("Swapped CAST_RESULT (0x130)\n");

    if (!swapHandler(0x24B, @intFromPtr(&spellMissedDetour)))
        log.print("FAILED to swap SPELLLOGMISS (0x24B)\n")
    else
        log.print("Swapped SPELLLOGMISS (0x24B)\n");

    if (!swapHandler(0x24F, @intFromPtr(&damageShieldDetour)))
        log.print("FAILED to swap SPELLDAMAGESHIELD (0x24F)\n")
    else
        log.print("Swapped SPELLDAMAGESHIELD (0x24F)\n");

    if (!swapHandler(0x24C, @intFromPtr(&spellLogExecuteDetour)))
        log.print("FAILED to swap SPELLLOGEXECUTE (0x24C)\n")
    else
        log.print("Swapped SPELLLOGEXECUTE (0x24C)\n");

    if (!swapHandler(0x32F, @intFromPtr(&instaKillDetour)))
        log.print("FAILED to swap SPELLINSTAKILLLOG (0x32F)\n")
    else
        log.print("Swapped SPELLINSTAKILLLOG (0x32F)\n");

    log.fmt("installHandlerSwaps: {d} handlers swapped\n", .{swap_count});
}

// =============================================================================
// Hook: SpellNonMeleeDmgLogHandler (0x5E85E0)
// Packet: SMSG_SPELLNONMELEEDAMAGELOG
// Fires: SPELL_DAMAGE
// =============================================================================

const FastCallPacketHandlerFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;

fn spellNonMeleeDmgLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const damage = cdsGet(u32, cds);
    const school = cdsGet(u8, cds);
    const absorb = cdsGet(u32, cds);
    const resist = cdsGet(i32, cds);
    _ = cdsGet(u8, cds); // periodicLog
    _ = cdsGet(u8, cds); // unused
    const blocked = cdsGet(u32, cds);
    const hit_info = cdsGet(u32, cds);

    cdsSetRead(cds, saved_read);

    if (target_guid != null and caster_guid != null and spell_id != null and
        damage != null and school != null and absorb != null and resist != null and
        blocked != null and hit_info != null)
    {
        const critical: u32 = if (hit_info.? & 0x02 != 0) 1 else 0;

        // Classify the damage subevent
        if (isPeriodicLeechSpell(spell_id.?)) {
            // Vanilla routes periodic leech (Drain Life, Siphon Life) through the spell damage
            // packet instead of PERIODICAURALOG. Reclassify as SPELL_PERIODIC_LEECH.
            // WotLK _LEECH suffix: amount, powerType, extraAmount
            // For health leech: powerType = -2 (0xFFFFFFFE, WotLK convention for health)
            // Approximate gained: damage - absorb - resist (heal is suppressed in heal hook)
            const effective: u32 = if (damage.? > absorb.?) damage.? - absorb.? else 0;
            const resist_u: u32 = @bitCast(resist.?);
            const gained: u32 = if (effective > resist_u) effective - resist_u else 0;
            log.fmt("SPELL_PERIODIC_LEECH: [{d}]{s} amt={d} gained={d}\n", .{ spell_id.?, std.mem.span(getSpellName(spell_id.?)), damage.?, gained });
            // _LEECH: spellId, amount, powerType(-2=health), extraAmount(gained)
            fireSpellLeech(SUB_SPELL_PERIODIC_LEECH, caster_guid.?, target_guid.?, spell_id.?, damage.?, @bitCast(@as(i32, -2)), gained);
            recordDamage(target_guid.?, caster_guid.?, spell_id.?);
        } else {
            const sub = if (spell_id.? == 75 or spell_id.? == 5019)
                SUB_RANGE_DAMAGE // Auto Shot / Wand Shoot
            else if (isDamageSplitSpell(spell_id.?))
                SUB_DAMAGE_SPLIT // Soul Link, Blessing of Sacrifice, etc.
            else
                SUB_SPELL_DAMAGE;
            const overkill = computeOverkill(target_guid.?, damage.?);
            log.fmt("{s}: [{d}]{s} amt={d} school={d} crit={d}\n", .{
                std.mem.span(sub), spell_id.?, std.mem.span(getSpellName(spell_id.?)), damage.?, @as(u32, school.?), critical,
            });
            fireSpellDamage(sub, caster_guid.?, target_guid.?, spell_id.?, damage.?, overkill, @as(u32, school.?), @bitCast(resist.?), blocked.?, absorb.?, critical, 0, 0);
            recordDamage(target_guid.?, caster_guid.?, spell_id.?);
        }
    }

    return callOriginalHandler(0x250, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: PeriodicAuraLogHandler (0x626DD0)
// Packet: SMSG_PERIODICAURALOG
// Fires: SPELL_PERIODIC_DAMAGE, SPELL_PERIODIC_HEAL, SPELL_PERIODIC_ENERGIZE,
//        SPELL_PERIODIC_DRAIN, SPELL_PERIODIC_LEECH
// =============================================================================

fn periodicAuraLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const count = cdsGet(u32, cds);

    if (target_guid != null and caster_guid != null and spell_id != null and count != null) {

        const aura_type = cdsGet(u32, cds);
        if (aura_type) |at| {
            switch (at) {
                3, 89 => {
                    // SPELL_PERIODIC_DAMAGE
                    const amount = cdsGet(u32, cds) orelse 0;
                    const spell_school = cdsGet(u32, cds) orelse 0;
                    const absorb = cdsGet(u32, cds) orelse 0;
                    const resist = cdsGet(i32, cds) orelse 0;
                    const overkill = computeOverkill(target_guid.?, amount);
                    fireSpellDamage(SUB_SPELL_PERIODIC_DAMAGE, caster_guid.?, target_guid.?, spell_id.?, amount, overkill, spell_school, @bitCast(resist), 0, absorb, 0, 0, 0);
                    recordDamage(target_guid.?, caster_guid.?, spell_id.?);
                },
                8, 20 => {
                    // SPELL_PERIODIC_HEAL
                    const amount = cdsGet(u32, cds) orelse 0;
                    const overheal = computeOverheal(target_guid.?, amount);
                    fireSpellHeal(SUB_SPELL_PERIODIC_HEAL, caster_guid.?, target_guid.?, spell_id.?, amount, overheal, 0, 0);
                },
                21, 24 => {
                    // SPELL_PERIODIC_ENERGIZE
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const raw_amount = cdsGet(u32, cds) orelse 0;
                    // Power display divisor table at 0x86F978 (verified from client binary):
                    // Mana(0)=1, Rage(1)=10, Focus(2)=1, Energy(3)=1, Happiness(4)=1000
                    // SMSG_SPELLENERGIZELOG handler divides by this; PERIODICAURALOG does not.
                    const divisor: u32 = switch (power_type) {
                        1 => 10, // rage
                        4 => 1000, // happiness
                        else => 1,
                    };
                    const amount = raw_amount / divisor;
                    fireSpellEnergize(SUB_SPELL_PERIODIC_ENERGIZE, caster_guid.?, target_guid.?, spell_id.?, amount, power_type);
                },
                53 => {
                    // SPELL_PERIODIC_LEECH — health leech (Drain Life, Siphon Life)
                    // NOTE: vanilla server routes health leech through SendSpellNonMeleeDamageLog,
                    // NOT PERIODICAURALOG. This case won't fire on vanilla servers — Drain Life
                    // ticks are reclassified in spellNonMeleeDmgLogDetour via isPeriodicLeechSpell().
                    // Kept for protocol completeness.
                    const amount = cdsGet(u32, cds) orelse 0;
                    _ = cdsGet(u32, cds); // school
                    const absorb = cdsGet(u32, cds) orelse 0;
                    const resist = cdsGet(i32, cds) orelse 0;
                    const effective: u32 = if (amount > absorb) amount - absorb else 0;
                    const resist_u: u32 = @bitCast(resist);
                    const gained: u32 = if (effective > resist_u) effective - resist_u else 0;
                    // _LEECH: spellId, amount, powerType(-2=health), extraAmount(gained)
                    fireSpellLeech(SUB_SPELL_PERIODIC_LEECH, caster_guid.?, target_guid.?, spell_id.?, amount, @bitCast(@as(i32, -2)), gained);
                    recordDamage(target_guid.?, caster_guid.?, spell_id.?);
                },
                64 => {
                    // SPELL_AURA_PERIODIC_MANA_LEECH — power leech/drain
                    // Packet format: powerType(u32), amount(u32), gainMultiplier(f32)
                    // multiplier > 0 = LEECH (caster gains amount*mult): Drain Mana, Viper Sting
                    // multiplier == 0 = DRAIN (caster gains nothing): rare boss mechanics
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const amount = cdsGet(u32, cds) orelse 0;
                    const multiplier = cdsGet(f32, cds) orelse 0.0;
                    if (multiplier > 0.0) {
                        const gained: u32 = @intFromFloat(@as(f32, @floatFromInt(amount)) * multiplier);
                        log.fmt("SPELL_PERIODIC_LEECH: spell={d} amt={d} power={d} gained={d} mult={d}\n", .{ spell_id.?, amount, power_type, gained, @as(u32, @bitCast(multiplier)) });
                        fireSpellLeech(SUB_SPELL_PERIODIC_LEECH, caster_guid.?, target_guid.?, spell_id.?, amount, power_type, gained);
                    } else {
                        log.fmt("SPELL_PERIODIC_DRAIN: [{d}]{s} amt={d} power={d}\n", .{ spell_id.?, std.mem.span(getSpellName(spell_id.?)), amount, power_type });
                        fireSpellLeech(SUB_SPELL_PERIODIC_DRAIN, caster_guid.?, target_guid.?, spell_id.?, amount, power_type, 0);
                    }
                },
                else => {},
            }
        }
    }

    cdsSetRead(cds, saved_read);
    return callOriginalHandler(0x24E, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: SMSG_SPELLHEALLOG (opcode 0x150) — handler table swap
// Packet: victimPackGUID, casterPackGUID, uint32 spellId, uint32 healAmount, uint8 isCrit
// Fires: SPELL_HEAL
// =============================================================================

fn healLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const heal_amount = cdsGet(u32, cds);
    const is_crit = cdsGet(u8, cds);

    cdsSetRead(cds, saved_read);

    if (target_guid != null and caster_guid != null and spell_id != null and
        heal_amount != null and is_crit != null and
        caster_guid.? != 0 and target_guid.? != 0 and !isPeriodicLeechSpell(spell_id.?))
    {
        // Suppress heal for periodic leech spells — already covered by SPELL_PERIODIC_LEECH
        const critical: u32 = if (is_crit.? != 0) 1 else 0;
        const overheal = computeOverheal(target_guid.?, heal_amount.?);
        // _HEAL: spellId, amount, overheal, absorbed(0), critical
        fireSpellHeal(SUB_SPELL_HEAL, caster_guid.?, target_guid.?, spell_id.?, heal_amount.?, overheal, 0, critical);
    }

    return callOriginalHandler(0x150, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: MeleeDispatcher (0x6255B0)
// Shared handler for opcodes 0x143-0x14A. We filter for 0x14A.
// Packet: SMSG_ATTACKERSTATEUPDATE (opcode 0x14A)
// Fires: SWING_DAMAGE or SWING_MISSED
// =============================================================================

const OPCODE_ATTACKERSTATEUPDATE: u32 = 0x14A;

fn meleeDispatcherDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (opcode == OPCODE_ATTACKERSTATEUPDATE) {
        parseMeleePacket(cds);
    }

    return callOriginalHandler(0x14A, unk, opcode, unk2, cds);
}

fn parseMeleePacket(cds: u32) void {
    const saved_read = cdsGetRead(cds);
    defer cdsSetRead(cds, saved_read);

    const hit_info = cdsGet(u32, cds) orelse return;
    const attacker_guid = cdsGetPackedGuid(cds) orelse return;
    const target_guid = cdsGetPackedGuid(cds) orelse return;
    const total_damage = cdsGet(u32, cds) orelse return;
    const sub_count = cdsGet(u8, cds) orelse return;

    var school: u32 = 0;
    var absorb: u32 = 0;
    var resist: u32 = 0;

    if (sub_count > 0) {
        school = cdsGet(u32, cds) orelse 0;
        _ = cdsGet(f32, cds); // damageFP
        _ = cdsGet(u32, cds); // damage (use totalDamage instead)
        absorb = cdsGet(u32, cds) orelse 0;
        resist = cdsGet(u32, cds) orelse 0;

        var i: u8 = 1;
        while (i < sub_count) : (i += 1) {
            _ = cdsGet(u32, cds);
            _ = cdsGet(f32, cds);
            _ = cdsGet(u32, cds);
            _ = cdsGet(u32, cds);
            _ = cdsGet(u32, cds);
        }
    }

    const victim_state = cdsGet(u32, cds) orelse return;
    _ = cdsGet(u32, cds); // unknown1
    _ = cdsGet(u32, cds); // unknown2
    _ = cdsGet(u32, cds); // spellId

    var blocked: u32 = 0;
    if (hit_info & 0x1 != 0) {
        blocked = cdsGet(u32, cds) orelse 0;
    }


    // Determine miss type from victimState
    const miss_type: ?[*:0]const u8 = switch (victim_state) {
        VS_UNAFFECTED => if (hit_info & HITINFO_MISS != 0) MISS_MISS else null,
        VS_DODGE => MISS_DODGE,
        VS_PARRY => MISS_PARRY,
        VS_BLOCK => MISS_BLOCK, // full block (0 damage)
        VS_EVADE => MISS_EVADE,
        VS_IMMUNE => MISS_IMMUNE,
        VS_DEFLECT => MISS_DEFLECT,
        else => null,
    };

    if (miss_type) |mt| {
        log.fmt("SWING_MISSED: vs={d} type={s}\n", .{ victim_state, std.mem.span(mt) });
        fireSwingMissed(attacker_guid, target_guid, mt, 0);
    } else {
        const critical: u32 = if (hit_info & HITINFO_CRITICALHIT != 0) 1 else 0;
        const glancing: u32 = if (hit_info & HITINFO_GLANCING != 0) 1 else 0;
        const crushing: u32 = if (hit_info & HITINFO_CRUSHING != 0) 1 else 0;
        const overkill = computeOverkill(target_guid, total_damage);
        log.fmt("SWING_DAMAGE: dmg={d} crit={d} glance={d} crush={d} hitInfo=0x{x}\n", .{ total_damage, critical, glancing, crushing, hit_info });
        // _DAMAGE: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
        fireSwingDamage(attacker_guid, target_guid, total_damage, overkill, school, resist, blocked, absorb, critical, glancing, crushing);
        recordDamage(target_guid, attacker_guid, 0);
    }
}

// =============================================================================
// Hook: ProcessEnvironmentalDamage (0x62AAC0)
// Fires: ENVIRONMENTAL_DAMAGE
// =============================================================================

const EnvDmgFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var env_dmg_hook: hook.Detour(EnvDmgFn) = .{};

fn envDamageDetour(victim_guid_ptr: u32, damage_type: u32, damage: u32, absorb: u32, resist: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (victim_guid_ptr != 0) {
        const guid_lo = hook.readMem(u32, victim_guid_ptr);
        const guid_hi = hook.readMem(u32, victim_guid_ptr + 4);
        const victim_guid: u64 = @as(u64, guid_hi) << 32 | @as(u64, guid_lo);

        if (victim_guid != 0) {
            const env_str = envTypeToString(damage_type);
            // Env school: falling=1(physical), fire/lava=4(fire), drowning/slime=8(nature), exhausted=1
            const school: u32 = switch (damage_type) {
                1, 4 => 8, // drowning, slime → nature
                3, 5 => 4, // lava, fire → fire
                else => 1, // exhausted, falling → physical
            };
            const overkill = computeOverkill(victim_guid, damage);
            log.fmt("ENVIRONMENTAL_DAMAGE: type={s} dmg={d} absorb={d}\n", .{ std.mem.span(env_str), damage, absorb });
            fireEnvDamage(victim_guid, env_str, damage, overkill, school, 0, 0, absorb, 0, 0, 0);
            recordDamage(victim_guid, 0, 0);
        }
    }

    env_dmg_hook.callOriginal(.{ victim_guid_ptr, damage_type, damage, absorb, resist });
}

// =============================================================================
// Helper: missInfo → string (from SpellMissInfo enum)
// =============================================================================

fn missInfoToString(info: u8) [*:0]const u8 {
    return switch (info) {
        1 => MISS_MISS,
        2 => MISS_RESIST,
        3 => MISS_DODGE,
        4 => MISS_PARRY,
        5 => MISS_BLOCK,
        6 => MISS_EVADE,
        7, 8 => MISS_IMMUNE,
        9 => MISS_DEFLECT,
        10 => MISS_ABSORB,
        11 => MISS_REFLECT,
        else => MISS_MISS,
    };
}

// =============================================================================
// Helper: active player GUID (for events with implicit caster)
// =============================================================================

fn getActivePlayerGuid() u64 {
    return hook.call(fn () callconv(hook.cc.fastcall) u64, 0x468550, .{});
}

// =============================================================================
// Hook: SMSG_SPELLLOGMISS (opcode 0x24B) — handler table swap
// Packet: uint32 spellId, casterGUID(8 raw), uint8 unk, uint32 targetCount,
//         [targetGUID(8 raw), uint8 missInfo] x count
// Fires: SPELL_MISSED, RANGE_MISSED, SPELL_PERIODIC_MISSED, DAMAGE_SHIELD_MISSED
// =============================================================================

fn spellMissedDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const spell_id = cdsGet(u32, cds);
    const caster_guid = cdsGet(u64, cds);
    _ = cdsGet(u8, cds); // unknown byte
    const target_count = cdsGet(u32, cds);

    if (spell_id != null and caster_guid != null and target_count != null and
        caster_guid.? != 0 and spell_id.? != 0)
    {
        const sub = if (spell_id.? == 75 or spell_id.? == 5019)
            SUB_RANGE_MISSED
        else if (isDamageShieldSpell(spell_id.?))
            SUB_DAMAGE_SHIELD_MISSED
        else if (isPeriodicSpell(spell_id.?))
            SUB_SPELL_PERIODIC_MISSED
        else
            SUB_SPELL_MISSED;

        var i: u32 = 0;
        while (i < target_count.?) : (i += 1) {
            const target_guid = cdsGet(u64, cds) orelse break;
            const miss_info = cdsGet(u8, cds) orelse break;
            if (target_guid == 0) continue;

            const miss_str = missInfoToString(miss_info);
            log.fmt("{s}: [{d}]{s} miss={s}\n", .{ std.mem.span(sub), spell_id.?, std.mem.span(getSpellName(spell_id.?)), std.mem.span(miss_str) });
            fireSpellMissed(sub, caster_guid.?, target_guid, spell_id.?, miss_str, 0);
        }
    }

    cdsSetRead(cds, saved_read);
    return callOriginalHandler(0x24B, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: ProcessSpellDrainEffectMessage (0x62CA20) — downstream of SMSG_SPELLDAMAGESHIELD
// Packet: victimGUID(8 raw), attackerGUID(8 raw), uint32 damage, uint32 school
// Fires: DAMAGE_SHIELD
// =============================================================================

fn damageShieldDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const victim_guid = cdsGet(u64, cds);
    const attacker_guid = cdsGet(u64, cds);
    const damage = cdsGet(u32, cds);
    const school = cdsGet(u32, cds);

    cdsSetRead(cds, saved_read);

    if (victim_guid != null and attacker_guid != null and damage != null and school != null and
        victim_guid.? != 0 and attacker_guid.? != 0)
    {
        const overkill = computeOverkill(victim_guid.?, damage.?);
        // Build CLEU buffer directly — spell prefix is deferred via damage_shield_spell
        cleuBase(SUB_DAMAGE_SHIELD, attacker_guid.?, victim_guid.?);
        cleuDamageShieldSpell(victim_guid.?, school.?);
        cleuNum(damage.?); cleuNum(overkill); cleuNum(school.?); cleuNum(0);
        cleuNum(0); cleuNum(0); cleuBool(0); cleuBool(0); cleuBool(0);
        signalEvent();
    }

    return callOriginalHandler(0x24F, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: ProcessStandardPowerGainMessage (0x62CA00) — downstream of SMSG_SPELLENERGIZELOG
// __fastcall(ECX=casterGuid_ptr, EDX=targetGuid_ptr, stack: spellId, powerType, amount)
// RET 0xC (3 stack params)
// Fires: SPELL_ENERGIZE
// =============================================================================

const EnergizeFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var energize_hook: hook.Detour(EnergizeFn) = .{};

fn energizeDetour(caster_ptr: u32, target_ptr: u32, spell_id: u32, power_type: u32, amount: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and target_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const target_lo = hook.readMem(u32, target_ptr);
        const target_hi = hook.readMem(u32, target_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);
        const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);

        if (caster_guid != 0 and target_guid != 0) {
            log.fmt("SPELL_ENERGIZE: [{d}]{s} amt={d} power={d}\n", .{ spell_id, std.mem.span(getSpellName(spell_id)), amount, power_type });
            fireSpellEnergize(SUB_SPELL_ENERGIZE, caster_guid.?, target_guid.?, spell_id, amount, power_type);
        }
    }

    energize_hook.callOriginal(.{ caster_ptr, target_ptr, spell_id, power_type, amount });
}

// =============================================================================
// Hook: DisplaySpellInterruptMessage (0x626A10) — downstream of SMSG_SPELLLOGEXECUTE
// __fastcall(ECX=casterGuid_ptr, EDX=targetGuid_ptr, stack: interruptedSpellId)
// RET 0x4 (1 stack param)
// Fires: SPELL_INTERRUPT
// =============================================================================

const SpellInterruptFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;

var spell_interrupt_hook: hook.Detour(SpellInterruptFn) = .{};

fn spellInterruptDetour(caster_ptr: u32, target_ptr: u32, interrupted_spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and target_ptr != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const target_lo = hook.readMem(u32, target_ptr);
        const target_hi = hook.readMem(u32, target_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);
        const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);

        if (caster_guid != 0 and target_guid != 0 and interrupted_spell_id != 0) {
            log.fmt("SPELL_INTERRUPT: interrupted={d}\n", .{interrupted_spell_id});
            // _INTERRUPT: spellId(interrupt ability — unknown, pass 0), spellSchool, extraSpellId(interrupted), extraSchool
            fireSpellInterrupt(SUB_SPELL_INTERRUPT, caster_guid.?, target_guid.?, 0, "", 0, interrupted_spell_id);
        }
    }

    spell_interrupt_hook.callOriginal(.{ caster_ptr, target_ptr, interrupted_spell_id });
}

// =============================================================================
// Hook: SMSG_SPELLLOGEXECUTE (opcode 0x24C) — handler table swap
// Packet: casterPackGUID, uint32 spellId, uint32 effectCount,
//         per effect: uint32 effectType, uint32 logCount,
//         per log entry: varies by effectType (see SpellDefines.h)
// Fires: SPELL_INTERRUPT, SPELL_ENERGIZE, SPELL_EXTRA_ATTACKS,
//        SPELL_SUMMON, SPELL_RESURRECT
// Replaces 4 downstream hooks: 0x626A10, 0x62D9F0, 0x62CA00, 0x62ACE0
// =============================================================================

// Vanilla spell effect type constants
const EFFECT_INSTAKILL: u32 = 1;
const EFFECT_POWER_DRAIN: u32 = 8;
const EFFECT_HEAL: u32 = 10;
const EFFECT_ADD_EXTRA_ATTACKS: u32 = 19;
const EFFECT_CREATE_ITEM: u32 = 24;
const EFFECT_ENERGIZE: u32 = 30;
const EFFECT_DISPEL: u32 = 38;
const EFFECT_SUMMON_PET: u32 = 56;
const EFFECT_HEAL_MAX_HEALTH: u32 = 67;
const EFFECT_INTERRUPT_CAST: u32 = 68;
const EFFECT_FEED_PET: u32 = 101;
const EFFECT_DURABILITY_DAMAGE: u32 = 111;
const EFFECT_RESURRECT_NEW: u32 = 113;

fn spellLogExecuteDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const effect_count = cdsGet(u32, cds);

    if (caster_guid != null and spell_id != null and effect_count != null and
        caster_guid.? != 0 and spell_id.? != 0)
    {
        const spell_name = getSpellName(spell_id.?);

        var eff_i: u32 = 0;
        while (eff_i < effect_count.?) : (eff_i += 1) {
            const effect_type = cdsGet(u32, cds) orelse break;
            const log_count = cdsGet(u32, cds) orelse break;

            var log_i: u32 = 0;
            while (log_i < log_count) : (log_i += 1) {
                switch (effect_type) {
                    EFFECT_POWER_DRAIN => {
                        // targetGUID(8), amount(4), powerType(4), multiplier(float 4)
                        const target = cdsGet(u64, cds) orelse break;
                        const amount = cdsGet(u32, cds) orelse break;
                        const power_type = cdsGet(u32, cds) orelse break;
                        _ = cdsGet(u32, cds) orelse break; // multiplier float, skip
                        if (target != 0) {
                            log.fmt("SPELL_DRAIN: [{d}]{s} amt={d} power={d}\n", .{ spell_id.?, std.mem.span(spell_name), amount, power_type });
                            fireSpellEnergize(SUB_SPELL_DRAIN, caster_guid.?, target, spell_id.?, amount, power_type);
                        }
                    },
                    EFFECT_ENERGIZE => {
                        // targetGUID(8), amount(4), powerType(4)
                        const target = cdsGet(u64, cds) orelse break;
                        const amount = cdsGet(u32, cds) orelse break;
                        const power_type = cdsGet(u32, cds) orelse break;
                        if (target != 0) {
                            fireSpellEnergize(SUB_SPELL_ENERGIZE, caster_guid.?, target, spell_id.?, amount, power_type);
                        }
                    },
                    EFFECT_ADD_EXTRA_ATTACKS => {
                        // targetGUID(8), count(4)
                        const target = cdsGet(u64, cds) orelse break;
                        const count = cdsGet(u32, cds) orelse break;
                        log.fmt("SPELL_EXTRA_ATTACKS: [{d}]{s} count={d}\n", .{ spell_id.?, std.mem.span(spell_name), count });
                        fireSpellExtraAttacks(caster_guid.?, target, spell_id.?, count);
                    },
                    EFFECT_INTERRUPT_CAST => {
                        // targetGUID(8), interruptedSpellId(4)
                        const target = cdsGet(u64, cds) orelse break;
                        const interrupted_id = cdsGet(u32, cds) orelse break;
                        if (target != 0 and interrupted_id != 0) {
                            log.fmt("SPELL_INTERRUPT: [{d}]{s} interrupted=[{d}]{s}\n", .{
                                spell_id.?, std.mem.span(spell_name), interrupted_id, std.mem.span(getSpellName(interrupted_id)),
                            });
                            // Now we have the interrupting spell ID (spell_id) — previously was 0
                            fireSpellInterrupt(SUB_SPELL_INTERRUPT, caster_guid.?, target, spell_id.?, interrupted_id);
                        }
                    },
                    EFFECT_HEAL, EFFECT_HEAL_MAX_HEALTH => {
                        // targetGUID(8), amount(4), critical(4)
                        _ = cdsGet(u64, cds) orelse break;
                        _ = cdsGet(u32, cds) orelse break;
                        _ = cdsGet(u32, cds) orelse break;
                        // Heals from SPELLLOGEXECUTE are handled by SMSG_SPELLHEALLOG — skip here
                    },
                    EFFECT_CREATE_ITEM => {
                        // itemEntry(4)
                        _ = cdsGet(u32, cds) orelse break;
                    },
                    EFFECT_FEED_PET => {
                        // itemEntry(4)
                        _ = cdsGet(u32, cds) orelse break;
                    },
                    EFFECT_DURABILITY_DAMAGE => {
                        // targetGUID(8), itemEntry(4), unk(4)
                        _ = cdsGet(u64, cds) orelse break;
                        _ = cdsGet(u32, cds) orelse break;
                        _ = cdsGet(u32, cds) orelse break;
                    },
                    else => {
                        // Most other effect types: just targetGUID(8)
                        // This covers INSTAKILL, RESURRECT, DISPEL, SUMMON variants, etc.
                        const target = cdsGet(u64, cds) orelse break;

                        if (target != 0) {

                            if (effect_type == EFFECT_INSTAKILL) {
                                // SPELL_INSTAKILL with caster from SPELLLOGEXECUTE (packet-level casterGUID)
                                log.fmt("SPELL_INSTAKILL: [{d}]{s} caster=0x{x} victim=0x{x}\n", .{ spell_id.?, std.mem.span(spell_name), caster_guid.?, target });
                                fireSpell(SUB_SPELL_INSTAKILL, caster_guid.?, target, spell_id.?);
                            } else if (isSummonEffect(effect_type)) {
                                fireSpell(SUB_SPELL_SUMMON, caster_guid.?, target, spell_id.?);
                            } else if (isResurrectEffect(effect_type)) {
                                fireSpell(SUB_SPELL_RESURRECT, caster_guid.?, target, spell_id.?);
                            }
                        }
                    },
                }
            }
        }
    }

    cdsSetRead(cds, saved_read);
    return callOriginalHandler(0x24C, unk, opcode, unk2, cds);
}

// SMSG_SPELLINSTAKILLLOG (0x32F) — pass through only, SPELL_INSTAKILL handled by SPELLLOGEXECUTE
fn instaKillDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    return callOriginalHandler(0x32F, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: PartyKillLogHandler (0x628890)
// Packet: SMSG_PARTYKILLLOG (opcode 0x01F5)
// Fires: PARTY_KILL
// =============================================================================

fn partyKillLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const player_guid = cdsGet(u64, cds);
    const victim_guid = cdsGet(u64, cds);

    cdsSetRead(cds, saved_read);

    if (player_guid != null and victim_guid != null) {
        fireBase(SUB_PARTY_KILL, player_guid.?, victim_guid.?);
    }

    return callOriginalHandler(0x1F5, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: SpellStartHandler (0x6E7640)
// Handles both SMSG_SPELL_START (0x0131) and SMSG_SPELL_GO (0x0132)
// Fires: SPELL_CAST_START (0x131) or SPELL_CAST_SUCCESS (0x132)
// =============================================================================

const OPCODE_SPELL_START: u32 = 0x131;
const OPCODE_SPELL_GO: u32 = 0x132;

fn spellStartDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (opcode == OPCODE_SPELL_START or opcode == OPCODE_SPELL_GO) {
        const saved_read = cdsGetRead(cds);

        // Packet: itemGuid(packed), casterGuid(packed), spellId(u32), castFlags(u16),
        //         timer(u32, SPELL_START only), targetMask(u16), [unitTargetPackGUID if flag 0x2]
        _ = cdsGetPackedGuid(cds); // item/caster GUID (skip)
        const caster_guid = cdsGetPackedGuid(cds);
        const spell_id = cdsGet(u32, cds);
        const cast_flags = cdsGet(u16, cds);

        if (caster_guid != null and spell_id != null and cast_flags != null) {
            // SPELL_START has timer before targets, SPELL_GO has hit/miss lists
            if (opcode == OPCODE_SPELL_START) {
                _ = cdsGet(u32, cds); // timer
            }

            // Parse target mask and extract unit target
            const target_mask = cdsGet(u16, cds) orelse 0;
            const TARGET_FLAG_UNIT: u16 = 0x0002;
            var spell_target: u64 = 0;
            if (target_mask & TARGET_FLAG_UNIT != 0) {
                spell_target = cdsGetPackedGuid(cds) orelse 0;
            }

            if (opcode == OPCODE_SPELL_START) {
                fireSpell(SUB_SPELL_CAST_START, caster_guid.?, spell_target, spell_id.?);
            } else {
                fireSpell(SUB_SPELL_CAST_SUCCESS, caster_guid.?, spell_target, spell_id.?);

                // Record cast for aura caster inference
                recordCast(caster_guid.?, spell_target, spell_id.?);

                // Heuristic SPELL_AURA_REFRESH for all units:
                // Parse SPELL_GO hit targets. If a hit target already has this aura
                // in their descriptors, infer a refresh. This is best-effort — the
                // server sends NO explicit refresh notification to observers in vanilla.
                if (hasApplyAuraEffect(spell_id.?)) {
                    // Skip local player — SetActionCooldownTimer hook handles their
                    // refreshes reliably via SMSG_UPDATE_AURA_DURATION.
                    const local_guid = getActivePlayerGuid();
                    _ = cdsGet(u16, cds); // castFlags
                    if (cdsGet(u8, cds)) |hit_count| {
                        var hits: u8 = 0;
                        while (hits < hit_count) : (hits += 1) {
                            const target_guid = cdsGetPackedGuid(cds) orelse break;
                            if (target_guid != 0) recordCast(caster_guid.?, target_guid, spell_id.?);
                            if (target_guid != 0 and target_guid != local_guid) {
                                if (unitHasAura(target_guid, spell_id.?)) |slot| {
                                    const aura_type = getAuraType(spell_id.?, slot);
                                    fireSpellStr(SUB_SPELL_AURA_REFRESH, caster_guid.?, target_guid, spell_id.?, aura_type);
                                }
                            }
                        }
                    }
                }
            }
        }

        cdsSetRead(cds, saved_read);
    }

    // Both 0x131 and 0x132 share this handler; callOriginal uses the opcode passed in EDX
    return callOriginalHandler(@intCast(opcode), unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: CastResultHandler (0x6E7330)
// Packet: SMSG_CAST_RESULT (opcode 0x0130) — local player only
// Fires: SPELL_CAST_FAILED (when status != 0)
// =============================================================================

fn castResultDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const spell_id = cdsGet(u32, cds);
    const status = cdsGet(u8, cds);

    cdsSetRead(cds, saved_read);

    if (spell_id != null and status != null and status.? != 0) {
        const player_guid = getActivePlayerGuid();
        if (player_guid != 0) {
            fireSpellStr(SUB_SPELL_CAST_FAILED, player_guid, 0, spell_id.?, "FAILED");
        }
    }

    return callOriginalHandler(0x130, unk, opcode, unk2, cds);
}

// =============================================================================
// Hook: HandleSpellInterruptUpdate (0x6E75F0)
// Handles SMSG_SPELL_FAILED_OTHER (0x2A6) and SMSG_SPELL_FAILURE (0x133)
// Broadcast to all nearby — captures other units' cast failures.
// stdcall(msgType, dataBuffer), RET 8.
// Packet: packedGuid + spellId(u32)
// Fires: SPELL_CAST_FAILED for other units
// =============================================================================

var spell_failed_other_hook: hook.Detour(DispelFailedFn) = .{}; // same CC as dispel failed: stdcall(2), ret 8

fn spellFailedOtherDetour(msg_type: u32, cds: u32) callconv(hook.cc.stdcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);

    cdsSetRead(cds, saved_read);

    if (caster_guid != null and spell_id != null and spell_id.? != 0) {
        // Skip if this is the local player (already handled by CastResultHandler)
        const player_guid = getActivePlayerGuid();
        if (caster_guid.? != player_guid) {
            fireSpellStr(SUB_SPELL_CAST_FAILED, caster_guid.?, 0, spell_id.?, "FAILED");
        }
    }

    return spell_failed_other_hook.callOriginal(.{ msg_type, cds });
}

// =============================================================================
// Hook: HandleUnitDeath (0x605860) — death transition callback
// __fastcall(ECX=unitObject), plain RET (0 stack params)
// Called from HandleUnitHealthChange (0x6046F0) when newHealth < 1 && oldHealth > 0
// Single xref — only fires on actual death transition.
// Fires: UNIT_DIED
// =============================================================================

const UnitDeathFn = fn (u32) callconv(hook.cc.fastcall) void;

var unit_death_hook: hook.Detour(UnitDeathFn) = .{};

fn unitDeathDetour(unit_obj: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (unit_obj != 0) {
        const guid_ptr = hook.readMem(u32, unit_obj + 8);
        if (guid_ptr != 0) {
            const guid_lo = hook.readMem(u32, guid_ptr);
            const guid_hi = hook.readMem(u32, guid_ptr + 4);
            const guid: u64 = @as(u64, guid_hi) << 32 | @as(u64, guid_lo);

            if (guid != 0) {
                // Check creature type: totems (type 11) fire UNIT_DESTROYED
                // CGUnit_GetCreatureType fallback path: obj+0xB30 -> +0x18
                const is_totem = blk: {
                    const name_cache = hook.readMem(u32, unit_obj + 0xB30);
                    if (name_cache != 0) {
                        break :blk hook.readMem(u32, name_cache + 0x18) == 11; // CREATURE_TYPE_TOTEM
                    }
                    break :blk false;
                };
                if (is_totem) {
                    log.fmt("UNIT_DESTROYED: unit=0x{x}\n", .{guid});
                    fireBase(SUB_UNIT_DESTROYED, 0, guid);
                } else {
                    fireBase(SUB_UNIT_DIED, 0, guid);
                }
            }
        }
    }

    unit_death_hook.callOriginal(.{unit_obj});
}

// =============================================================================
// Hook: CastSpell (0x612320) — aura removal callback
// __thiscall(ECX=unitObject, stack: slotIndex, spellId), RET 0x8 (2 stack params)
// Called from compareAndUpdateObjectArrays (0x604D00) when old aura active but new is NOT.
// Single xref — safe to hook.
// Fires: SPELL_AURA_REMOVED
// =============================================================================

const AuraChangeFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var aura_removed_hook: hook.Detour(AuraChangeFn) = .{};

fn auraRemovedDetour(unit_obj: u32, _edx: u32, slot_index: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (unit_obj != 0 and spell_id != 0) {
        const guid_ptr = hook.readMem(u32, unit_obj + 8);
        if (guid_ptr != 0) {
            const guid_lo = hook.readMem(u32, guid_ptr);
            const guid_hi = hook.readMem(u32, guid_ptr + 4);
            const guid: u64 = @as(u64, guid_hi) << 32 | @as(u64, guid_lo);

            if (guid != 0) {
                const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);

                // Check if this aura was broken by damage (SPELL_AURA_BROKEN heuristic).
                // If the spell has damage-break flags and the target was recently damaged,
                // fire SPELL_AURA_BROKEN_SPELL (spell break) or SPELL_AURA_BROKEN (melee break).
                if (getSpellRecord(spell_id)) |rec| {
                    const aura_int_flags = hook.readMem(u32, rec + SPELL_AURA_INTERRUPT_FLAGS_OFFSET);
                    if (aura_int_flags & (AURA_INTERRUPT_FLAG_DAMAGE | AURA_INTERRUPT_FLAG_DIRECT_DAMAGE) != 0) {
                        if (findRecentDamage(guid)) |dmg| {
                            if (dmg.spell_id != 0) {
                                fireSpellDispel(SUB_SPELL_AURA_BROKEN_SPELL, dmg.source_guid, guid, spell_id, dmg.spell_id, aura_type);
                            } else {
                                fireSpellStr(SUB_SPELL_AURA_BROKEN, dmg.source_guid, guid, spell_id, aura_type);
                            }
                        }
                    }
                }

                // Always fire SPELL_AURA_REMOVED (even if broken — WotLK fires both)
                const caster = getAuraCaster(guid, slot_index);
                fireSpellStr(SUB_SPELL_AURA_REMOVED, caster, guid, spell_id, aura_type);
                clearAuraCaster(guid, slot_index);
            }
        }
    }

    aura_removed_hook.callOriginal(.{ unit_obj, _edx, slot_index, spell_id });
}

// =============================================================================
// Hook: SetSpellTarget (0x6123F0) — aura application callback
// __thiscall(ECX=unitObject, stack: slotIndex, spellId), RET 0x8 (2 stack params)
// Called from compareAndUpdateObjectArrays (0x604D00) when new aura active but old was NOT.
// Single xref — safe to hook.
// Fires: SPELL_AURA_APPLIED
// =============================================================================

var aura_applied_hook: hook.Detour(AuraChangeFn) = .{};

fn auraAppliedDetour(unit_obj: u32, _edx: u32, slot_index: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (unit_obj != 0 and spell_id != 0) {
        const guid_ptr = hook.readMem(u32, unit_obj + 8);
        if (guid_ptr != 0) {
            const guid_lo = hook.readMem(u32, guid_ptr);
            const guid_hi = hook.readMem(u32, guid_ptr + 4);
            const guid: u64 = @as(u64, guid_hi) << 32 | @as(u64, guid_lo);

            if (guid != 0) {
                const caster = findCaster(guid, spell_id);
                setAuraCaster(guid, slot_index, caster);
                const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);
                fireSpellStr(SUB_SPELL_AURA_APPLIED, caster, guid, spell_id, aura_type);
            }
        }
    }

    aura_applied_hook.callOriginal(.{ unit_obj, _edx, slot_index, spell_id });
}

// =============================================================================
// Hook: ValidateSpellSlot (0x612450) — aura stack count change
// __thiscall(ECX=unitObject, stack: slotIndex, requestedLevel), RET 0x8 (2 stack params)
// Called from updateObjectWithByteValue (0x604EA0) for EVERY aura count change.
// requestedLevel = OLD count (from saved data), live descriptor has NEW count.
// Fires: SPELL_AURA_APPLIED_DOSE (increase) or SPELL_AURA_REMOVED_DOSE (decrease)
// =============================================================================

var aura_dose_hook: hook.Detour(AuraChangeFn) = .{};

fn auraDoseDetour(unit_obj: u32, _edx: u32, slot_index: u32, old_count_raw: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (unit_obj != 0 and slot_index < 48) {
        const m_data = hook.readMem(u32, unit_obj + 0x110);
        if (m_data != 0) {
            const old_count: u8 = @truncate(old_count_raw);
            const new_count = hook.readMem(u8, m_data + 0x1AC + slot_index);

            if (old_count != new_count) {
                // Spell ID from UNIT_FIELD_AURA array (offset 0xA4, 4 bytes per slot)
                const spell_id = hook.readMem(u32, m_data + 0xA4 + slot_index * 4);
                if (spell_id != 0) {
                    const guid_ptr = hook.readMem(u32, unit_obj + 8);
                    if (guid_ptr != 0) {
                        const guid_lo = hook.readMem(u32, guid_ptr);
                        const guid_hi = hook.readMem(u32, guid_ptr + 4);
                        const guid: u64 = @as(u64, guid_hi) << 32 | @as(u64, guid_lo);

                        if (guid != 0) {
                            const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);

                            const caster = getAuraCaster(guid, slot_index);
                            if (new_count > old_count) {
                                fireSpellStrD(SUB_SPELL_AURA_APPLIED_DOSE, caster, guid, spell_id, aura_type, new_count);
                            } else {
                                fireSpellStrD(SUB_SPELL_AURA_REMOVED_DOSE, caster, guid, spell_id, aura_type, new_count);
                            }
                        }
                    }
                }
            }
        }
    }

    aura_dose_hook.callOriginal(.{ unit_obj, _edx, slot_index, old_count_raw });
}

// =============================================================================
// Hook: ProcessExtraAttacksSpellMessage (0x62D9F0) — extra attacks notification
// __fastcall(ECX=casterGUID_ptr, EDX=unused, stack: spellId), RET 0x4 (1 stack param)
// Called from SPELLLOGEXECUTE handler for effectType 19 (EXTRA_ATTACKS in vanilla).
// Fires: SPELL_EXTRA_ATTACKS
// =============================================================================

const ExtraAttacksFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;

var extra_attacks_hook: hook.Detour(ExtraAttacksFn) = .{};

fn extraAttacksDetour(caster_ptr: u32, count: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

        if (caster_guid != 0) {
            const src_str = guidToString(caster_guid);
            const school = getSpellSchool(spell_id);
            log.fmt("SPELL_EXTRA_ATTACKS: [{d}]{s} count={d}\n", .{ spell_id, std.mem.span(getSpellName(spell_id)), count });
            // _EXTRA_ATTACKS: spellId, spellSchool, amount
            fireSpellExtraAttacks(src_str, 0, "", spell_id, school, count);
        }
    }

    extra_attacks_hook.callOriginal(.{ caster_ptr, count, spell_id });
}

// =============================================================================
// Hook: ProcessAuraDispelMessage (0x62D480) — aura dispel notification
// __fastcall(ECX=casterGUID_ptr, EDX=targetGUID_ptr, stack: dispelledSpellId), RET 0x4
// Called from SMSG_SPELLDISPELLOG handler (0x5E8B60) per dispelled aura.
// Fires: SPELL_DISPEL
// =============================================================================

var dispel_hook: hook.Detour(ExtraAttacksFn) = .{}; // Same fn type: fastcall(ptr, ptr, u32)

fn dispelDetour(caster_ptr: u32, target_ptr: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and target_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const target_lo = hook.readMem(u32, target_ptr);
        const target_hi = hook.readMem(u32, target_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);
        const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);

        if (caster_guid != 0 and target_guid != 0) {
            // Determine aura type from spell DB for the dispelled aura
            const aura_type_str: [*:0]const u8 = blk: {
                if (getSpellRecord(spell_id)) |rec| {
                    const attrs = hook.readMem(u32, rec + 0x18);
                    if (attrs & 0x4000000 != 0) break :blk @as([*:0]const u8, "DEBUFF");
                }
                break :blk @as([*:0]const u8, "BUFF");
            };
            log.fmt("SPELL_DISPEL: dispelled={d}\n", .{spell_id});
            // _DISPEL: dispelSpellId(0 — unknown), school, extraSpellId(dispelled aura), extraSchool, auraType
            fireSpellDispel(SUB_SPELL_DISPEL, caster_guid, target_guid, 0, spell_id, aura_type_str);
        }
    }

    dispel_hook.callOriginal(.{ caster_ptr, target_ptr, spell_id });
}

// =============================================================================
// Spell DB lookup — WowClientDB<SpellRec> at 0xC0D780
// =============================================================================
//
// Structure: m_records(+0), m_numRecords(+4), m_recordsById(+8), m_maxId(+C), m_loaded(+10)
// SpellRec: Id(+0), School(+4), Effect[3](+F4/+F8/+FC)
// Access: *(*(0xC0D788) + spellId * 4) → SpellRec* (from nampower reference)

const SPELL_DB_RECORDS: u32 = 0xC0D788; // m_recordsById pointer
const SPELL_DB_MAX_ID: u32 = 0xC0D78C; // m_maxId

/// GetSpellNameById (0x6264B0): __fastcall(ECX=spellId) -> EAX=char*
/// Returns localized spell name string, or null if invalid.
const GET_SPELL_NAME: u32 = 0x6264B0;

/// Locale index global at 0xC0E080 — 0 for English.
const LOCALE_INDEX: u32 = 0xC0E080;

var spell_name_debug_count: u32 = 0;

fn getSpellName(spell_id: u32) [*:0]const u8 {
    if (spell_id == 0) return "";
    // SpellRec name at offset 0x1E0 + locale*4 (verified from SuperWoW: puVar3[locale + 0x78])
    // 0x78 * 4 = 0x1E0. Locale index global at 0xC0E080.
    const rec = getSpellRecord(spell_id) orelse return "";
    const locale = hook.readMem(u32, LOCALE_INDEX);
    const name_ptr = hook.readMem(u32, rec + 0x1E0 + locale * 4);
    if (name_ptr == 0) return "";
    // Debug: log first 5 lookups
    if (spell_name_debug_count < 5) {
        spell_name_debug_count += 1;
        const name: [*:0]const u8 = @ptrFromInt(name_ptr);
        log.fmt("[SPELLNAME] id={d} locale={d} -> 0x{x} \"{s}\"\n", .{ spell_id, locale, name_ptr, std.mem.span(name) });
    }
    return @ptrFromInt(name_ptr);
}

fn getSpellRecord(spell_id: u32) ?u32 {
    if (spell_id == 0) return null;
    const max_id = hook.readMem(u32, SPELL_DB_MAX_ID);
    if (spell_id > max_id) return null;
    const records_ptr = hook.readMem(u32, SPELL_DB_RECORDS);
    if (records_ptr == 0) return null;
    const rec = hook.readMem(u32, records_ptr + spell_id * 4);
    if (rec == 0) return null;
    return rec;
}

/// Look up spell school bitmask from spell DB.
fn getSpellSchool(spell_id: u32) u32 {
    if (getSpellRecord(spell_id)) |rec| {
        return hook.readMem(u32, rec + 0x04);
    }
    return 0;
}

/// Read a unit's current power value from descriptors.
/// power_type: 0=mana, 1=rage, 2=focus, 3=energy, 4=combo
fn getUnitPower(guid: u64, power_type: u32) ?u32 {
    if (power_type > 4) return null;
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const m_data = hook.readMem(u32, obj + 0x08);
    if (m_data == 0) return null;
    return hook.readMem(u32, m_data + DESC_POWER_BASE + power_type * 4);
}

/// Read a unit's max power value from descriptors.
fn getUnitMaxPower(guid: u64, power_type: u32) ?u32 {
    if (power_type > 4) return null;
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const m_data = hook.readMem(u32, obj + 0x08);
    if (m_data == 0) return null;
    return hook.readMem(u32, m_data + DESC_MAXPOWER_BASE + power_type * 4);
}

/// Read a unit's current health from descriptors.
fn getUnitHealth(guid: u64) ?u32 {
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const m_data = hook.readMem(u32, obj + 0x08);
    if (m_data == 0) return null;
    return hook.readMem(u32, m_data + DESC_HEALTH);
}

/// Read a unit's max health from descriptors.
fn getUnitMaxHealth(guid: u64) ?u32 {
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const m_data = hook.readMem(u32, obj + 0x08);
    if (m_data == 0) return null;
    return hook.readMem(u32, m_data + DESC_MAXHEALTH);
}

/// Compute overkill: how much damage exceeded target's remaining HP.
/// Returns -1 (as u32 bitcast) if the target survives — WotLK convention.
fn computeOverkill(target_guid: u64, damage: u32) u32 {
    const hp = getUnitHealth(target_guid) orelse return @bitCast(@as(i32, -1));
    if (damage >= hp) return damage - hp;
    return @bitCast(@as(i32, -1));
}

/// Compute overheal: how much healing exceeded the target's health deficit.
fn computeOverheal(target_guid: u64, heal_amount: u32) u32 {
    const cur = getUnitHealth(target_guid) orelse return 0;
    const max = getUnitMaxHealth(target_guid) orelse return 0;
    const deficit = if (max > cur) max - cur else 0;
    if (heal_amount > deficit) return heal_amount - deficit;
    return 0;
}

/// Vanilla spell effect types for summon abilities.
fn isSummonEffect(e: u32) bool {
    return e == 28 or e == 42 or e == 56 or
        (e >= 85 and e <= 88) or (e >= 104 and e <= 107) or e == 109;
}

/// Vanilla spell effect types for resurrect abilities.
fn isResurrectEffect(e: u32) bool {
    return e == 18 or e == 113;
}

/// Vanilla spell effect type for energize.
fn isEnergizeEffect(e: u32) bool {
    return e == 30;
}

/// Check if spell has a damage split aura effect (Soul Link, Blessing of Sacrifice, etc.)
/// SPELL_AURA_SPLIT_DAMAGE_PCT=81, SPLIT_DAMAGE_FLAT=153, SPLIT_DAMAGE_GROUP_PCT=193
fn isDamageSplitSpell(spell_id: u32) bool {
    if (getSpellRecord(spell_id)) |rec| {
        // EffectApplyAuraName[0..2] at offset 0x16C, 0x170, 0x174 (client Spell.dbc layout)
        inline for (0..3) |i| {
            const aura = hook.readMem(u32, rec + 0x16C + @as(u32, @intCast(i)) * 4);
            if (aura == 81 or aura == 153 or aura == 193) return true;
        }
    }
    return false;
}

/// Check if spell has SPELL_AURA_PERIODIC_LEECH (53) — health drain (Drain Life, Siphon Life).
/// Vanilla server routes these through SendSpellNonMeleeDamageLog, not PERIODICAURALOG,
/// so we reclassify them from SPELL_DAMAGE to SPELL_PERIODIC_LEECH in the damage hook.
fn isPeriodicLeechSpell(spell_id: u32) bool {
    const rec = getSpellRecord(spell_id) orelse return false;
    inline for (0..3) |i| {
        const effect = hook.readMem(u32, rec + 0xF4 + i * 4);
        if (effect == 6 or effect == 27) { // APPLY_AURA or APPLY_AREA_AURA
            const aura = hook.readMem(u32, rec + 0x16C + i * 4);
            if (aura == 53) return true;
        }
    }
    return false;
}

/// Determine aura type from spell DB Attributes flag.
/// Spell attribute 0x4000000 = SPELL_ATTR_NEGATIVE (harmful/debuff).
/// Falls back to slot-based heuristic if spell not found in DB.
fn getAuraType(spell_id: u32, slot_index: u32) [*:0]const u8 {
    if (getSpellRecord(spell_id)) |rec| {
        const attrs = hook.readMem(u32, rec + 0x18);
        if (attrs & 0x4000000 != 0) return "DEBUFF";
        return "BUFF";
    }
    // Fallback: slots 0-39 = buffs, 40-47 = debuffs
    return if (slot_index < 40) "BUFF" else "DEBUFF";
}

/// Check if spell has any APPLY_AURA (6) or APPLY_AREA_AURA (27) effect.
fn hasApplyAuraEffect(spell_id: u32) bool {
    if (getSpellRecord(spell_id)) |rec| {
        const e0 = hook.readMem(u32, rec + 0xF4);
        const e1 = hook.readMem(u32, rec + 0xF8);
        const e2 = hook.readMem(u32, rec + 0xFC);
        return e0 == 6 or e0 == 27 or e1 == 6 or e1 == 27 or e2 == 6 or e2 == 27;
    }
    return false;
}

/// Check if spell has any periodic aura effect (DoT, HoT, periodic energize/drain/leech).
/// Checks EffectApplyAuraName[0..2] at offsets 0x16C..0x174 for periodic aura types.
fn isPeriodicSpell(spell_id: u32) bool {
    const rec = getSpellRecord(spell_id) orelse return false;
    const periodic_auras = [_]u32{ 3, 8, 20, 21, 24, 53, 64, 89 };
    inline for (0..3) |i| {
        const effect = hook.readMem(u32, rec + 0xF4 + i * 4);
        if (effect == 6 or effect == 27) {
            const aura = hook.readMem(u32, rec + 0x16C + i * 4);
            inline for (periodic_auras) |pa| {
                if (aura == pa) return true;
            }
        }
    }
    return false;
}

/// Check if spell has a SPELL_AURA_DAMAGE_SHIELD (26) effect.
fn isDamageShieldSpell(spell_id: u32) bool {
    const rec = getSpellRecord(spell_id) orelse return false;
    inline for (0..3) |i| {
        const effect = hook.readMem(u32, rec + 0xF4 + i * 4);
        if (effect == 6 or effect == 27) {
            const aura = hook.readMem(u32, rec + 0x16C + i * 4);
            if (aura == 26) return true;
        }
    }
    return false;
}

/// Check if a unit already has a specific aura spell. Returns slot index if found.
fn unitHasAura(guid: u64, spell_id: u32) ?u32 {
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const m_data = hook.readMem(u32, obj + 0x8);
    if (m_data == 0) return null;

    for (0..48) |i| {
        const slot: u32 = @intCast(i);
        const sid = hook.readMem(u32, m_data + 0xA4 + slot * 4);
        if (sid == spell_id) {
            const flags_byte = hook.readMem(u8, m_data + 0x164 + slot / 2);
            const nibble: u8 = if (slot % 2 == 0) flags_byte & 0x0F else flags_byte >> 4;
            if ((nibble & 0xE) != 0) return slot;
        }
    }
    return null;
}

// =============================================================================
// Hook: ProcessSpellEffect (0x62ACE0) — generic spell effect display
// __fastcall(ECX=casterGUID_ptr, EDX=targetGUID_ptr, stack: spellId), RET 0x4
// Called from SPELLLOGEXECUTE for many effect types (cases 0, 2, 10/default).
// effectType 30 (ENERGIZE) falls through to default case → this function.
// We filter by spell DB Effect[] lookup to detect SUMMON, RESURRECT, and ENERGIZE.
// Fires: SPELL_SUMMON, SPELL_RESURRECT, SPELL_ENERGIZE
// =============================================================================

var spell_effect_hook: hook.Detour(ExtraAttacksFn) = .{};

fn spellEffectDetour(caster_ptr: u32, target_ptr: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and spell_id != 0) {
        if (getSpellRecord(spell_id)) |rec| {
            const e0 = hook.readMem(u32, rec + 0xF4);
            const e1 = hook.readMem(u32, rec + 0xF8);
            const e2 = hook.readMem(u32, rec + 0xFC);

            const is_summon = isSummonEffect(e0) or isSummonEffect(e1) or isSummonEffect(e2);
            const is_resurrect = isResurrectEffect(e0) or isResurrectEffect(e1) or isResurrectEffect(e2);

            if (is_summon or is_resurrect) {
                const caster_lo = hook.readMem(u32, caster_ptr);
                const caster_hi = hook.readMem(u32, caster_ptr + 4);
                const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

                if (caster_guid != 0) {
                    const school = hook.readMem(u32, rec + 0x04);

                    // Target may be NULL for summons (SPELLLOGEXECUTE case 10 passes NULL)
                    var effect_target: u64 = 0;
                    var dst_name: [*:0]const u8 = "";
                    if (target_ptr != 0) {
                        const target_lo = hook.readMem(u32, target_ptr);
                        const target_hi = hook.readMem(u32, target_ptr + 4);
                        effect_target = @as(u64, target_hi) << 32 | @as(u64, target_lo);
                        if (effect_target != 0) {
                            dst_name = wow.getNameByGUID(effect_target);
                        }
                    }

                    if (is_summon) {
                        fireSpell(SUB_SPELL_SUMMON, caster_guid, effect_target, spell_id, school);
                    }
                    if (is_resurrect) {
                        fireSpell(SUB_SPELL_RESURRECT, caster_guid, effect_target, spell_id, school);
                    }
                    // SPELL_ENERGIZE now handled by dedicated ProcessStandardPowerGainMessage hook
                }
            }
        }
    }

    spell_effect_hook.callOriginal(.{ caster_ptr, target_ptr, spell_id });
}

// =============================================================================
// TODO: Remaining hooks (require deep aura system research)
// =============================================================================
// Hook: SetActionCooldownTimer (0x4E4390) — aura duration update
// __fastcall(ECX=auraSlot: u8, EDX=duration_ms: u32)
// Called from SMSG_UPDATE_AURA_DURATION (opcode 0x137) handler.
// This packet fires on both initial application and refresh.
// On initial application: descriptor update (SMSG_UPDATE_OBJECT) hasn't arrived yet,
//   so the aura slot is still empty → we skip (SPELL_AURA_APPLIED handles it).
// On refresh: the slot already has an active aura from the earlier application →
//   we detect it and fire SPELL_AURA_REFRESH.
//
// ⚠ LOCAL PLAYER ONLY — vanilla sends SMSG_UPDATE_AURA_DURATION only to the
// buffed player. Other units' aura refreshes are invisible: the descriptor spell ID
// doesn't change, and no packet is sent to observers. WotLK fixed this with
// SMSG_AURA_UPDATE which carries full aura state for all units.
// To cover all units, a deeper approach is needed — e.g. hooking inside
// compareAndUpdateObjectArrays (0x604D00) to intercept descriptor writes before
// the diff comparison, or shadowing the aura slot table to detect same-ID overwrites.
//
// Fires: SPELL_AURA_REFRESH (local player only)
// =============================================================================

const AuraDurationFn = fn (u32, u32) callconv(hook.cc.fastcall) void;

var aura_duration_hook: hook.Detour(AuraDurationFn) = .{};

fn auraDurationDetour(slot: u32, duration: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (slot < 48) {
        // Get local player object
        const player_guid = getActivePlayerGuid();
        if (player_guid != 0) {
            const player_obj = wow.getObjectByGUID(player_guid);

            if (player_obj != 0) {
                // Read descriptor data pointer: object+0x8 = descriptor base
                const m_data = hook.readMem(u32, player_obj + 0x8);
                if (m_data != 0) {
                    // UNIT_FIELD_AURA starts at descriptor offset 0xA4, each slot is 4 bytes
                    const spell_id = hook.readMem(u32, m_data + 0xA4 + slot * 4);

                    // UNIT_FIELD_AURAFLAGS: packed nibbles (4 bits per slot) at offset 0x164
                    // Each byte covers 2 slots: even slot = low nibble, odd slot = high nibble
                    const flags_byte = hook.readMem(u8, m_data + 0x164 + slot / 2);
                    const nibble: u8 = if (slot % 2 == 0) flags_byte & 0x0F else flags_byte >> 4;
                    const is_active = spell_id != 0 and (nibble & 0xE) != 0;

                    if (is_active) {
                        // Slot already has this aura — this is a refresh
                        const aura_type = getAuraType(spell_id, slot);
                        log.fmt("SPELL_AURA_REFRESH: [{d}]{s} slot={d}\n", .{ spell_id, std.mem.span(getSpellName(spell_id)), slot });
                        fireSpellStr(SUB_SPELL_AURA_REFRESH, 0, player_guid, spell_id, aura_type);
                    }
                }
            }
        }
    }

    aura_duration_hook.callOriginal(.{ slot, duration });
}

// =============================================================================
// Hook: ProcessMultipleSpellInterrupts (0x628C20) — dispel failed notification
// Packet: SMSG_DISPEL_FAILED (0x262)
// stdcall(messageType, dataBuffer), RET 8
// Data: casterGUID(packed) + targetGUID(packed) + spellId(u32) * N
// Fires: SPELL_DISPEL_FAILED
// =============================================================================

const DispelFailedFn = fn (u32, u32) callconv(hook.cc.stdcall) ?*anyopaque;

var dispel_failed_hook: hook.Detour(DispelFailedFn) = .{};

fn dispelFailedDetour(msg_type: u32, cds: u32) callconv(hook.cc.stdcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    // ReadPointerPairFromBuffer reads 2 u32s (lo + hi = 64-bit GUID), NOT packed
    const caster_lo = cdsGet(u32, cds);
    const caster_hi = cdsGet(u32, cds);
    const target_lo = cdsGet(u32, cds);
    const target_hi = cdsGet(u32, cds);

    if (caster_lo != null and caster_hi != null and target_lo != null and target_hi != null) {
        const caster_guid: u64 = @as(u64, caster_hi.?) << 32 | @as(u64, caster_lo.?);
        const target_guid: u64 = @as(u64, target_hi.?) << 32 | @as(u64, target_lo.?);

        if (caster_guid != 0 and target_guid != 0) {

            // Loop: read spell IDs until buffer exhausted (ReadPointerFromStream reads u32)
            var count: u32 = 0;
            while (count < 20) : (count += 1) { // safety cap
                const spell_id = cdsGet(u32, cds);
                if (spell_id == null) break;
                if (spell_id.? == 0) break;

                log.fmt("SPELL_DISPEL_FAILED: [{d}]{s} caster=0x{x} target=0x{x}\n", .{
                    spell_id.?, std.mem.span(getSpellName(spell_id.?)), caster_guid, target_guid,
                });
                fireSpellInterrupt(SUB_SPELL_DISPEL_FAILED, caster_guid, target_guid, 0, spell_id.?);
            }
        }
    }

    cdsSetRead(cds, saved_read);
    return dispel_failed_hook.callOriginal(.{ msg_type, cds });
}

// RANGE_MISSED already handled via spell ID check in SPELL_MISSED hook

// Event registration now happens dynamically in createEventsDetour.

// =============================================================================
// Install / remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);

    if (resize_events_hook.attach(0x7053B0, &resizeEventsDetour) != .ok) {
        log.print("FAILED to hook resize_lua_event_array\n");
    } else {
        log.print("Hooked resize_lua_event_array\n");
    }

    if (create_events_hook.attach(0x703D90, &createEventsDetour) != .ok) {
        log.print("FAILED to hook FrameScript_CreateEvents\n");
    } else {
        log.print("Hooked FrameScript_CreateEvents\n");
    }

    if (init_engine_hook.attach(0x401570, &initGameEngineDetour) != .ok) {
        log.print("FAILED to hook InitializeGameEngine\n");
    } else {
        log.print("Hooked InitializeGameEngine (handler table swaps after return)\n");
    }

    if (env_dmg_hook.attach(0x62AAC0, &envDamageDetour) != .ok) {
        log.print("FAILED to hook ProcessEnvironmentalDamage\n");
    } else {
        log.print("Hooked ProcessEnvironmentalDamage\n");
    }


    if (spell_failed_other_hook.attach(0x6E75F0, &spellFailedOtherDetour) != .ok) {
        log.print("FAILED to hook HandleSpellInterruptUpdate\n");
    } else {
        log.print("Hooked HandleSpellInterruptUpdate (SPELL_CAST_FAILED others)\n");
    }


    if (unit_death_hook.attach(0x605860, &unitDeathDetour) != .ok) {
        log.print("FAILED to hook HandleUnitDeath\n");
    } else {
        log.print("Hooked HandleUnitDeath (UNIT_DIED)\n");
    }

    if (aura_removed_hook.attach(0x612320, &auraRemovedDetour) != .ok) {
        log.print("FAILED to hook CastSpell\n");
    } else {
        log.print("Hooked CastSpell (SPELL_AURA_REMOVED)\n");
    }

    if (aura_applied_hook.attach(0x6123F0, &auraAppliedDetour) != .ok) {
        log.print("FAILED to hook SetSpellTarget\n");
    } else {
        log.print("Hooked SetSpellTarget (SPELL_AURA_APPLIED)\n");
    }

    if (aura_dose_hook.attach(0x612450, &auraDoseDetour) != .ok) {
        log.print("FAILED to hook ValidateSpellSlot\n");
    } else {
        log.print("Hooked ValidateSpellSlot (SPELL_AURA_*_DOSE)\n");
    }

    // extra_attacks_hook — now handled by SPELLLOGEXECUTE table swap (0x24C)

    if (dispel_hook.attach(0x62D480, &dispelDetour) != .ok) {
        log.print("FAILED to hook ProcessAuraDispelMessage\n");
    } else {
        log.print("Hooked ProcessAuraDispelMessage (SPELL_DISPEL)\n");
    }

    // spell_effect_hook — now handled by SPELLLOGEXECUTE table swap (0x24C)

    if (aura_duration_hook.attach(0x4E4390, &auraDurationDetour) != .ok) {
        log.print("FAILED to hook SetActionCooldownTimer\n");
    } else {
        log.print("Hooked SetActionCooldownTimer (SPELL_AURA_REFRESH)\n");
    }

    if (dispel_failed_hook.attach(0x628C20, &dispelFailedDetour) != .ok) {
        log.print("FAILED to hook ProcessMultipleSpellInterrupts\n");
    } else {
        log.print("Hooked ProcessMultipleSpellInterrupts (SPELL_DISPEL_FAILED)\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // Restore handler table swaps (no code to unpatch)
        restoreAllHandlers();
        // Detach remaining JMP-patching detours (non-packet hooks)
        spell_failed_other_hook.detach();
        dispel_failed_hook.detach();
        aura_duration_hook.detach();
        dispel_hook.detach();
        aura_dose_hook.detach();
        aura_applied_hook.detach();
        aura_removed_hook.detach();
        unit_death_hook.detach();
        // spell_interrupt_hook — now in SPELLLOGEXECUTE table swap
        env_dmg_hook.detach();
        // energize_hook — now in SPELLLOGEXECUTE table swap
        init_engine_hook.detach();
        create_events_hook.detach();
        resize_events_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}

// =============================================================================
// Lua function: GetSpellInfo(spellId) — WotLK-compatible
// Returns: name, rank, icon, castTime, minRange, maxRange, spellId
//
// SpellRec field offsets (dword indices from SuperWoW, byte offset = index * 4):
//   Name:           [0x78 + locale] = byte 0x1E0 + locale*4
//   Rank:           [0x81 + locale] = byte 0x204 + locale*4  (SpellNameSubtext)
//   SpellIconID:    [0x8A]          = byte 0x228
//   CastingTimeIdx: [0x55]          = byte 0x154
//   RangeIdx:       [0x54]          = byte 0x150
// =============================================================================

/// SpellRec field offsets (byte offsets from record base)
/// Verified from nampower game.hpp SpellRec struct + SuperWoW Ghidra analysis.
const SPELL_CAST_TIME_IDX: u32 = 0x48; // CastingTimeIndex — indexes SpellCastTimes.dbc
const SPELL_RANGE_IDX: u32 = 0x90; // rangeIndex — indexes SpellRange.dbc
const SPELL_ICON_ID: u32 = 0x1D4; // SpellIconID — indexes SpellIcon.dbc
const SPELL_NAME_BASE: u32 = 0x1E0; // SpellName[0] — + locale*4 for localized name
const SPELL_RANK_BASE: u32 = 0x204; // SpellNameSubtext[0] — + locale*4 for rank string

/// SpellIcon.dbc (verified: nampower + SuperWoW)
/// Record: [0]=ID, [0x04]=texture_path_string_ptr
const SPELL_ICON_RECORDS: u32 = 0xC0D7EC; // m_recordsById
const SPELL_ICON_MAX_ID: u32 = 0xC0D7F0;

/// SpellRange.dbc (verified: nampower offsets.hpp)
/// Record: [0]=ID, [0x04]=minRange(f32), [0x08]=maxRange(f32), [0x0C]=flags, [0x10]=name[8 locales]
const SPELL_RANGE_RECORDS: u32 = 0xC0D79C; // m_recordsById
const SPELL_RANGE_MAX_ID: u32 = 0xC0D7A0;

/// SpellCastTimes.dbc (verified: Ghidra analysis of Spell_C_GetCastTime 0x6E3340)
/// Record: [0]=ID, [0x04]=baseCastTime(ms), [0x08]=castTimePerLevel, [0x0C]=minCastTime
const CAST_TIMES_RECORDS: u32 = 0xC0D878; // m_recordsById
const CAST_TIMES_MAX_ID: u32 = 0xC0D87C;

fn readDbRecord(records_ptr_addr: u32, max_id_addr: u32, id: u32) ?u32 {
    if (id == 0) return null;
    const max_id = hook.readMem(u32, max_id_addr);
    if (id > max_id) return null;
    const records_ptr = hook.readMem(u32, records_ptr_addr);
    if (records_ptr == 0) return null;
    const rec = hook.readMem(u32, records_ptr + id * 4);
    if (rec == 0) return null;
    return rec;
}

fn readLocString(rec: u32, base_offset: u32) [*:0]const u8 {
    const locale = hook.readMem(u32, LOCALE_INDEX);
    const ptr = hook.readMem(u32, rec + base_offset + locale * 4);
    if (ptr == 0) return "";
    return @ptrFromInt(ptr);
}

/// GetSpellInfo(spellId) -> name, rank, icon, castTime, minRange, maxRange, spellId
/// Matches WotLK API. Returns nil if spell doesn't exist.
pub fn luaGetSpellInfo(L: usize) callconv(hook.cc.fastcall) u32 {
    const state: lua.State = @ptrFromInt(L);
    const nargs = lua.gettop(state);
    if (nargs < 1) return 0;

    const spell_id: u32 = @intFromFloat(lua.tonumber(state, 1));
    const rec = getSpellRecord(spell_id) orelse {
        // Invalid spell — return nil (WotLK behavior)
        lua.pushnil(state);
        return 1;
    };

    // 1. name
    lua.pushstring(state, readLocString(rec, SPELL_NAME_BASE));

    // 2. rank (SpellNameSubtext)
    lua.pushstring(state, readLocString(rec, SPELL_RANK_BASE));

    // 3. icon texture path — resolve SpellIconID through SpellIcon.dbc
    const icon_id = hook.readMem(u32, rec + SPELL_ICON_ID);
    if (readDbRecord(SPELL_ICON_RECORDS, SPELL_ICON_MAX_ID, icon_id)) |icon_rec| {
        // SpellIcon.dbc record: [0]=ID, [1]=texture path string
        const tex_ptr = hook.readMem(u32, icon_rec + 4);
        if (tex_ptr != 0) {
            lua.pushstring(state, @ptrFromInt(tex_ptr));
        } else {
            lua.pushnil(state);
        }
    } else {
        lua.pushnil(state);
    }

    // 4. castTime (ms) — resolve CastingTimeIndex through SpellCastTimes.dbc
    const cast_idx = hook.readMem(u32, rec + SPELL_CAST_TIME_IDX);
    if (readDbRecord(CAST_TIMES_RECORDS, CAST_TIMES_MAX_ID, cast_idx)) |ct_rec| {
        // SpellCastTimes.dbc record: [0]=ID, [1]=castTime (ms)
        const cast_time = hook.readMem(u32, ct_rec + 4);
        lua.pushnumber(state, @floatFromInt(cast_time));
    } else {
        lua.pushnumber(state, 0);
    }

    // 5. minRange, 6. maxRange — resolve RangeIndex through SpellRange.dbc
    const range_idx = hook.readMem(u32, rec + SPELL_RANGE_IDX);
    if (readDbRecord(SPELL_RANGE_RECORDS, SPELL_RANGE_MAX_ID, range_idx)) |range_rec| {
        // SpellRange.dbc record: [0]=ID, [1]=minRange(float), [2]=maxRange(float)
        const min_range: f32 = @bitCast(hook.readMem(u32, range_rec + 4));
        const max_range: f32 = @bitCast(hook.readMem(u32, range_rec + 8));
        lua.pushnumber(state, @floatCast(min_range));
        lua.pushnumber(state, @floatCast(max_range));
    } else {
        lua.pushnumber(state, 0);
        lua.pushnumber(state, 0);
    }

    // 7. spellId (echo back — matches WotLK)
    lua.pushnumber(state, @floatFromInt(spell_id));

    return 7; // 7 return values
}
