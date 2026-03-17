//! DPS log module — TBC/WotLK-style COMBAT_LOG_EVENT for vanilla 1.12.1.
//!
//! Fires a unified COMBAT_LOG_EVENT with WotLK-style subevent names and
//! structured args. All subevents share: arg1=subevent, arg2=sourceGUID,
//! arg3=destGUID. Remaining args are subevent-specific.
//!
//! See reference/COMBAT_LOG_EVENT_WOTLK.md for full WotLK spec.
//! See RESEARCH.md "Implementation Status" for what's implemented vs TODO.
//!
//! Arg layouts per suffix type:
//!
//!   _DAMAGE (spell prefix): arg4=spellId, arg5=amount, arg6=school,
//!       arg7=resisted, arg8=absorbed, arg9=blocked, arg10=critical
//!   _DAMAGE (swing):        arg4=amount, arg5=school, arg6=resisted,
//!       arg7=absorbed, arg8=blocked, arg9=critical, arg10=0
//!   _DAMAGE (environmental): arg4=envType, arg5=amount, arg6=absorbed,
//!       arg7-10=0
//!   _MISSED (spell prefix): arg4=spellId, arg5=spellSchool, arg6=missType(string)
//!   _MISSED (swing):        arg4=missType(string)
//!   _HEAL (spell prefix):   arg4=spellId, arg5=amount, arg6=0(overheal),
//!       arg7=0(absorbed), arg8=critical
//!   _ENERGIZE:              arg4=spellId, arg5=amount, arg6=powerType
//!   _DRAIN/_LEECH:          arg4=spellId, arg5=amount, arg6=powerType,
//!       arg7=extraAmount
//!   _AURA_APPLIED/REMOVED:  arg4=spellId, arg5=spellSchool, arg6=auraType(string)
//!   _AURA_APPLIED_DOSE/REMOVED_DOSE: same + arg7=amount(stacks)
//!   _CAST_START/SUCCESS:    arg4=spellId, arg5=spellSchool
//!   _CAST_FAILED:           arg4=spellId, arg5=spellSchool, arg6=failedType(string)
//!   _INTERRUPT:             arg4=spellId, arg5=spellSchool, arg6=extraSpellId,
//!       arg7=extraSpellSchool
//!   _DISPEL/_STOLEN:        arg4=spellId, arg5=spellSchool, arg6=extraSpellId,
//!       arg7=extraSpellSchool, arg8=auraType(string)
//!   _EXTRA_ATTACKS:         arg4=spellId, arg5=spellSchool, arg6=amount
//!   UNIT_DIED/PARTY_KILL:   (base params only)
//!
//! Power types: 0=mana, 1=rage, 2=focus, 3=energy, 4=combo points
//! Env types:   0=EXHAUSTED, 1=DROWNING, 2=FALLING, 3=LAVA, 4=SLIME, 5=FIRE
//! Miss types:  "MISS", "DODGE", "PARRY", "BLOCK", "EVADE", "IMMUNE",
//!              "DEFLECT", "RESIST", "ABSORB", "REFLECT"
//! Aura types:  "BUFF", "DEBUFF"

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");
const wow = @import("../wow.zig");

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

/// SpellRec AuraInterruptFlags offset and damage-break bits.
const SPELL_AURA_INTERRUPT_FLAGS_OFFSET: u32 = 0x58;
const AURA_INTERRUPT_FLAG_DAMAGE: u32 = 0x02;
const AURA_INTERRUPT_FLAG_DIRECT_DAMAGE: u32 = 0x01000000;

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// COMBAT_LOG_EVENT — slot assigned dynamically in createEventsDetour
// =============================================================================

var g_event_combat_log: u32 = 0;
const EVENT_TABLE_MAIN: u32 = 0xBE1198;
const event_name: [*:0]const u8 = "COMBAT_LOG_EVENT";

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
// SignalEventParam fire functions — one per format pattern
// =============================================================================
//
// SignalEventParam (0x703F50): __cdecl(eventId, fmtStr, ...)
// Each fire function uses a specific format string for its arg pattern.
// On x86 cdecl, all args are 4 bytes on stack (pointers and ints alike).

const SIGNAL: u32 = 0x703F50;

/// Pattern A: 3 strings + 7 numbers — _DAMAGE, _HEAL, _ENERGIZE, etc.
/// subevent, srcGUID, dstGUID, n1..n7
fn fireCombatLog(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8, n1: u32, n2: u32, n3: u32, n4: u32, n5: u32, n6: u32, n7: u32) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%d%d%d%d%d%d%d", sub, src, dst, n1, n2, n3, n4, n5, n6, n7 });
}

/// Pattern B: 4 strings — SWING_MISSED (subevent, src, dst, missType)
fn fireSwingMissed(src: [*:0]const u8, dst: [*:0]const u8, miss_type: [*:0]const u8) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%s", SUB_SWING_MISSED, src, dst, miss_type });
}

/// Pattern C: 3 strings + 2 numbers + 1 string — SPELL_MISSED, SPELL_AURA_*, SPELL_CAST_FAILED
/// subevent, srcGUID, dstGUID, spellId, spellSchool, stringArg
fn fireSpellStr(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8, spell_id: u32, spell_school: u32, str_arg: [*:0]const u8) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, [*:0]const u8) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%d%d%s", sub, src, dst, spell_id, spell_school, str_arg });
}

/// Pattern D: 3 strings + 2 numbers — SPELL_CAST_START/SUCCESS, SPELL_SUMMON, etc.
/// subevent, srcGUID, dstGUID, spellId, spellSchool
fn fireSpell(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8, spell_id: u32, spell_school: u32) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%d%d", sub, src, dst, spell_id, spell_school });
}

/// Pattern E: 3 strings only — UNIT_DIED, PARTY_KILL
fn fireBase(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s", sub, src, dst });
}

/// Pattern F: 3s + 2d + 1s + 1d — SPELL_AURA_APPLIED_DOSE/REMOVED_DOSE
fn fireSpellStrD(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8, spell_id: u32, spell_school: u32, str_arg: [*:0]const u8, amount: u32) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, [*:0]const u8, u32) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%d%d%s%d", sub, src, dst, spell_id, spell_school, str_arg, amount });
}

/// Pattern G: 3s + 4d + 1s — SPELL_DISPEL/STOLEN (spellId, spellSchool, extraSpellId, extraSchool, auraType)
fn fireSpellDispel(sub: [*:0]const u8, src: [*:0]const u8, dst: [*:0]const u8, spell_id: u32, spell_school: u32, extra_id: u32, extra_school: u32, aura_type: [*:0]const u8) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, [*:0]const u8) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%d%d%d%d%s", sub, src, dst, spell_id, spell_school, extra_id, extra_school, aura_type });
}

/// Pattern H: 4 strings + 6 numbers — ENVIRONMENTAL_DAMAGE (envType as string)
fn fireEnvDamage(dst: [*:0]const u8, env_str: [*:0]const u8, amount: u32, school: u32, absorb: u32) void {
    const F = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, u32) callconv(hook.cc.cdecl) void;
    @call(.auto, @as(*const F, @ptrFromInt(SIGNAL)), .{ g_event_combat_log, "%s%s%s%s%d%d%d%d%d", SUB_ENV_DAMAGE, GUID_ZERO, dst, env_str, amount, school, absorb, 0, 0 });
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

        log.fmt("createEventsDetour: COMBAT_LOG_EVENT at slot {d}, capacity={d}\n", .{ slot, capacity });
    }
}

// =============================================================================
// Hook: SpellNonMeleeDmgLogHandler (0x5E85E0)
// Packet: SMSG_SPELLNONMELEEDAMAGELOG
// Fires: SPELL_DAMAGE
// =============================================================================

const FastCallPacketHandlerFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;

var spell_dmg_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

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
        const src_str = guidToString(caster_guid.?);
        const dst_str = guidToString(target_guid.?);
        const critical: u32 = if (hit_info.? & 0x02 != 0) 1 else 0;

        // Classify the damage subevent
        const sub = if (spell_id.? == 75 or spell_id.? == 5019)
            SUB_RANGE_DAMAGE // Auto Shot / Wand Shoot
        else if (isDamageSplitSpell(spell_id.?))
            SUB_DAMAGE_SPLIT // Soul Link, Blessing of Sacrifice, etc.
        else
            SUB_SPELL_DAMAGE;
        log.fmt("{s}: spell={d} amt={d} school={d} crit={d}\n", .{
            std.mem.span(sub), spell_id.?, damage.?, @as(u32, school.?), critical,
        });
        fireCombatLog(sub, src_str, dst_str, spell_id.?, damage.?, @as(u32, school.?), @bitCast(resist.?), absorb.?, blocked.?, critical);
        recordDamage(target_guid.?, caster_guid.?, spell_id.?);
    }

    return spell_dmg_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: PeriodicAuraLogHandler (0x626DD0)
// Packet: SMSG_PERIODICAURALOG
// Fires: SPELL_PERIODIC_DAMAGE, SPELL_PERIODIC_HEAL, SPELL_PERIODIC_ENERGIZE,
//        SPELL_PERIODIC_DRAIN, SPELL_PERIODIC_LEECH
// =============================================================================

var periodic_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn periodicAuraLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const count = cdsGet(u32, cds);

    if (target_guid != null and caster_guid != null and spell_id != null and count != null) {
        const src_str = guidToString(caster_guid.?);
        const dst_str = guidToString(target_guid.?);

        const aura_type = cdsGet(u32, cds);
        if (aura_type) |at| {
            switch (at) {
                3, 89 => {
                    // SPELL_PERIODIC_DAMAGE
                    const amount = cdsGet(u32, cds) orelse 0;
                    const spell_school = cdsGet(u32, cds) orelse 0;
                    const absorb = cdsGet(u32, cds) orelse 0;
                    const resist = cdsGet(i32, cds) orelse 0;
                    fireCombatLog(SUB_SPELL_PERIODIC_DAMAGE, src_str, dst_str, spell_id.?, amount, spell_school, @bitCast(resist), absorb, 0, 0);
                    recordDamage(target_guid.?, caster_guid.?, spell_id.?);
                },
                8, 20 => {
                    // SPELL_PERIODIC_HEAL
                    const amount = cdsGet(u32, cds) orelse 0;
                    fireCombatLog(SUB_SPELL_PERIODIC_HEAL, src_str, dst_str, spell_id.?, amount, 0, 0, 0, 0, 0);
                },
                21, 24 => {
                    // SPELL_PERIODIC_ENERGIZE
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const amount = cdsGet(u32, cds) orelse 0;
                    // Compute overEnergize from descriptors (before original processes the update)
                    var over_energize: u32 = 0;
                    if (target_guid != null) {
                        const cur = getUnitPower(target_guid.?, power_type) orelse 0;
                        const max = getUnitMaxPower(target_guid.?, power_type) orelse 0;
                        if (max > 0 and cur + amount > max) {
                            over_energize = cur + amount - max;
                        }
                    }
                    fireCombatLog(SUB_SPELL_PERIODIC_ENERGIZE, src_str, dst_str, spell_id.?, amount, over_energize, power_type, 0, 0, 0);
                },
                53 => {
                    // SPELL_PERIODIC_LEECH — health drain (Drain Life, Siphon Life)
                    // Packet format: damage, spellSchool, absorb, resist (same as periodic damage)
                    const amount = cdsGet(u32, cds) orelse 0;
                    const spell_school = cdsGet(u32, cds) orelse 0;
                    const absorb = cdsGet(u32, cds) orelse 0;
                    const resist = cdsGet(i32, cds) orelse 0;
                    // WotLK _LEECH suffix: amount, powerType(0=health), extraAmount(gained back)
                    // Vanilla doesn't send the gained amount separately — approximate as amount - absorb - resist
                    const effective: u32 = if (amount > absorb) amount - absorb else 0;
                    const gained: u32 = if (effective > @as(u32, @bitCast(resist))) effective - @as(u32, @bitCast(resist)) else 0;
                    fireCombatLog(SUB_SPELL_PERIODIC_LEECH, src_str, dst_str, spell_id.?, amount, spell_school, gained, absorb, @bitCast(resist), 0);
                    recordDamage(target_guid.?, caster_guid.?, spell_id.?);
                },
                64 => {
                    // SPELL_PERIODIC_DRAIN — mana drain/leech (Mana Burn, Drain Mana)
                    // Packet format: powerType, amount, gainMultiplier
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const amount = cdsGet(u32, cds) orelse 0;
                    const extra = cdsGet(u32, cds) orelse 0; // multiplied gain
                    fireCombatLog(SUB_SPELL_PERIODIC_DRAIN, src_str, dst_str, spell_id.?, amount, power_type, extra, 0, 0, 0);
                },
                else => {},
            }
        }
    }

    cdsSetRead(cds, saved_read);
    return periodic_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: ProcessSpellPowerDrainMessage (0x62C770) — downstream of SMSG_SPELLHEALLOG
// __fastcall(ECX=casterGuid_ptr, EDX=targetGuid_ptr, stack: spellId, healAmount, isCrit)
// RET 0xC (3 stack params). Ghidra mislabel — actually heal display function.
// Fires: SPELL_HEAL
// =============================================================================

const HealDisplayFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var heal_hook: hook.Detour(HealDisplayFn) = .{};

fn healDisplayDetour(caster_ptr: u32, target_ptr: u32, spell_id: u32, heal_amount: u32, is_crit: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and target_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const target_lo = hook.readMem(u32, target_ptr);
        const target_hi = hook.readMem(u32, target_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);
        const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);

        if (caster_guid != 0 and target_guid != 0) {
            const src_str = guidToString(caster_guid);
            const dst_str = guidToString(target_guid);
            const critical: u32 = if (is_crit != 0) 1 else 0;
            // _HEAL: spellId, amount, overheal(0), absorbed(0), critical
            fireCombatLog(SUB_SPELL_HEAL, src_str, dst_str, spell_id, heal_amount, 0, 0, critical, 0, 0);
        }
    }

    heal_hook.callOriginal(.{ caster_ptr, target_ptr, spell_id, heal_amount, is_crit });
}

// =============================================================================
// Hook: MeleeDispatcher (0x6255B0)
// Shared handler for opcodes 0x143-0x14A. We filter for 0x14A.
// Packet: SMSG_ATTACKERSTATEUPDATE (opcode 0x14A)
// Fires: SWING_DAMAGE or SWING_MISSED
// =============================================================================

const OPCODE_ATTACKERSTATEUPDATE: u32 = 0x14A;

var melee_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn meleeDispatcherDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (opcode == OPCODE_ATTACKERSTATEUPDATE) {
        parseMeleePacket(cds);
    }

    return melee_hook.callOriginal(.{ unk, opcode, unk2, cds });
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

    const src_str = guidToString(attacker_guid);
    const dst_str = guidToString(target_guid);

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
        fireSwingMissed(src_str, dst_str, mt);
    } else {
        const critical: u32 = if (hit_info & HITINFO_CRITICALHIT != 0) 1 else 0;
        // Pack glancing/crushing/offhand into flags bitmask (arg10):
        //   bit0=glancing, bit1=crushing, bit2=offhand
        const flags: u32 = (if (hit_info & HITINFO_GLANCING != 0) @as(u32, 1) else 0) |
            (if (hit_info & HITINFO_CRUSHING != 0) @as(u32, 2) else 0) |
            (if (hit_info & HITINFO_LEFTSWING != 0) @as(u32, 4) else 0);
        log.fmt("SWING_DAMAGE: dmg={d} crit={d} flags={d} hitInfo=0x{x}\n", .{ total_damage, critical, flags, hit_info });
        // _DAMAGE: amount, school, resisted, absorbed, blocked, critical, flags(glancing|crushing|offhand)
        fireCombatLog(SUB_SWING_DAMAGE, src_str, dst_str, total_damage, school, resist, absorb, blocked, critical, flags);
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
            const dst_str = guidToString(victim_guid);
            const env_str = envTypeToString(damage_type);
            // Env school: falling=1(physical), fire/lava=4(fire), drowning/slime=8(nature), exhausted=1
            const school: u32 = switch (damage_type) {
                1, 4 => 8, // drowning, slime → nature
                3, 5 => 4, // lava, fire → fire
                else => 1, // exhausted, falling → physical
            };
            log.fmt("ENVIRONMENTAL_DAMAGE: type={s} dmg={d} absorb={d}\n", .{ std.mem.span(env_str), damage, absorb });
            fireEnvDamage(dst_str, env_str, damage, school, absorb);
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
// Hook: ProcessSpellCombatResult (0x62BAB0) — downstream of SMSG_SPELLLOGMISS
// __fastcall(ECX=missType, EDX=spellId, stack: casterGuidLo, casterGuidHi,
//            targetGuidLo, targetGuidHi, isFromSpellLogMiss)
// RET 0x14 (5 stack params)
// Fires: SPELL_MISSED, RANGE_MISSED, SPELL_PERIODIC_MISSED, DAMAGE_SHIELD_MISSED
// =============================================================================

const SpellMissedFn = fn (u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var spell_missed_hook: hook.Detour(SpellMissedFn) = .{};

fn spellMissedDetour(miss_type: u32, spell_id: u32, caster_lo: u32, caster_hi: u32, target_lo: u32, target_hi: u32, is_spell_log_miss: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);
    const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);

    if (caster_guid != 0 and target_guid != 0 and spell_id != 0) {
        const src_str = guidToString(caster_guid);
        const dst_str = guidToString(target_guid);
        const miss_str = missInfoToString(@truncate(miss_type));
        const school = getSpellSchool(spell_id);
        // Classify miss subevent by spell type
        const sub = if (spell_id == 75 or spell_id == 5019)
            SUB_RANGE_MISSED
        else if (isDamageShieldSpell(spell_id))
            SUB_DAMAGE_SHIELD_MISSED
        else if (isPeriodicSpell(spell_id))
            SUB_SPELL_PERIODIC_MISSED
        else
            SUB_SPELL_MISSED;
        log.fmt("{s}: spell={d} miss={s} logmiss={d}\n", .{ std.mem.span(sub), spell_id, std.mem.span(miss_str), is_spell_log_miss });
        fireSpellStr(sub, src_str, dst_str, spell_id, school, miss_str);
    }

    spell_missed_hook.callOriginal(.{ miss_type, spell_id, caster_lo, caster_hi, target_lo, target_hi, is_spell_log_miss });
}

// =============================================================================
// Hook: ProcessSpellDrainEffectMessage (0x62CA20) — downstream of SMSG_SPELLDAMAGESHIELD
// __fastcall(ECX=victimGuid_ptr, EDX=casterGuid_ptr, stack: damage, school)
// RET 0x8 (2 stack params)
// Fires: DAMAGE_SHIELD
// =============================================================================

const DamageShieldFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var damage_shield_hook: hook.Detour(DamageShieldFn) = .{};

fn damageShieldDetour(victim_ptr: u32, caster_ptr: u32, damage: u32, school: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (victim_ptr != 0 and caster_ptr != 0) {
        const victim_lo = hook.readMem(u32, victim_ptr);
        const victim_hi = hook.readMem(u32, victim_ptr + 4);
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const victim_guid: u64 = @as(u64, victim_hi) << 32 | @as(u64, victim_lo);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

        if (victim_guid != 0 and caster_guid != 0) {
            const src_str = guidToString(caster_guid);
            const dst_str = guidToString(victim_guid);
            log.fmt("DAMAGE_SHIELD: dmg={d} school={d}\n", .{ damage, school });
            // No spellId available in SMSG_SPELLDAMAGESHIELD — pass 0
            fireCombatLog(SUB_DAMAGE_SHIELD, src_str, dst_str, 0, damage, school, 0, 0, 0, 0);
        }
    }

    damage_shield_hook.callOriginal(.{ victim_ptr, caster_ptr, damage, school });
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
            const src_str = guidToString(caster_guid);
            const dst_str = guidToString(target_guid);
            const extra_school = getSpellSchool(interrupted_spell_id);
            log.fmt("SPELL_INTERRUPT: interrupted={d}\n", .{interrupted_spell_id});
            // _INTERRUPT: spellId(interrupt ability — unknown, pass 0), spellSchool, extraSpellId(interrupted), extraSchool
            fireSpellDispel(SUB_SPELL_INTERRUPT, src_str, dst_str, 0, 0, interrupted_spell_id, extra_school, "");
        }
    }

    spell_interrupt_hook.callOriginal(.{ caster_ptr, target_ptr, interrupted_spell_id });
}

// =============================================================================
// Hook: ProcessInstaKillSpellMessage (0x62CBE0) — downstream of SMSG_SPELLINSTAKILLLOG
// __fastcall(ECX=casterGuid_ptr, EDX=spellId)
// Plain RET (0 stack params)
// Fires: SPELL_INSTAKILL
// =============================================================================

const InstaKillFn = fn (u32, u32) callconv(hook.cc.fastcall) void;

var instakill_hook: hook.Detour(InstaKillFn) = .{};

fn instaKillDetour(caster_ptr: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

        if (caster_guid != 0) {
            const src_str = guidToString(caster_guid);
            const school = getSpellSchool(spell_id);
            log.fmt("SPELL_INSTAKILL: spell={d} caster=0x{x}\n", .{ spell_id, caster_guid });
            // No victim GUID in SMSG_SPELLINSTAKILLLOG — pass zero GUID
            fireSpell(SUB_SPELL_INSTAKILL, src_str, GUID_ZERO, spell_id, school);
        }
    }

    instakill_hook.callOriginal(.{ caster_ptr, spell_id });
}

// =============================================================================
// Hook: PartyKillLogHandler (0x628890)
// Packet: SMSG_PARTYKILLLOG (opcode 0x01F5)
// Fires: PARTY_KILL
// =============================================================================

var party_kill_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn partyKillLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const player_guid = cdsGet(u64, cds);
    const victim_guid = cdsGet(u64, cds);

    cdsSetRead(cds, saved_read);

    if (player_guid != null and victim_guid != null) {
        const src_str = guidToString(player_guid.?);
        const dst_str = guidToString(victim_guid.?);
        log.fmt("PARTY_KILL: src=0x{x} dst=0x{x}\n", .{ player_guid.?, victim_guid.? });
        fireBase(SUB_PARTY_KILL, src_str, dst_str);
    }

    return party_kill_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: SpellStartHandler (0x6E7640)
// Handles both SMSG_SPELL_START (0x0131) and SMSG_SPELL_GO (0x0132)
// Fires: SPELL_CAST_START (0x131) or SPELL_CAST_SUCCESS (0x132)
// =============================================================================

const OPCODE_SPELL_START: u32 = 0x131;
const OPCODE_SPELL_GO: u32 = 0x132;

var spell_start_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn spellStartDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (opcode == OPCODE_SPELL_START or opcode == OPCODE_SPELL_GO) {
        const saved_read = cdsGetRead(cds);

        // Packet: itemGuid(packed), casterGuid(packed), spellId(u32), castFlags(u16)
        _ = cdsGetPackedGuid(cds); // item/caster GUID (skip)
        const caster_guid = cdsGetPackedGuid(cds);
        const spell_id = cdsGet(u32, cds);

        if (caster_guid != null and spell_id != null) {
            const src_str = guidToString(caster_guid.?);
            const school = getSpellSchool(spell_id.?);
            if (opcode == OPCODE_SPELL_START) {
                log.fmt("SPELL_CAST_START: spell={d} caster=0x{x}\n", .{ spell_id.?, caster_guid.? });
                fireSpell(SUB_SPELL_CAST_START, src_str, GUID_ZERO, spell_id.?, school);
            } else {
                log.fmt("SPELL_CAST_SUCCESS: spell={d} caster=0x{x}\n", .{ spell_id.?, caster_guid.? });
                fireSpell(SUB_SPELL_CAST_SUCCESS, src_str, GUID_ZERO, spell_id.?, school);

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
                            if (target_guid != 0 and target_guid != local_guid) {
                                if (unitHasAura(target_guid, spell_id.?)) |slot| {
                                    const dst_str = guidToString(target_guid);
                                    const aura_type = getAuraType(spell_id.?, slot);
                                    log.fmt("SPELL_AURA_REFRESH (heuristic): spell={d} target=0x{x}\n", .{ spell_id.?, target_guid });
                                    fireSpellStr(SUB_SPELL_AURA_REFRESH, src_str, dst_str, spell_id.?, school, aura_type);
                                }
                            }
                        }
                    }
                }
            }
        }

        cdsSetRead(cds, saved_read);
    }

    return spell_start_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: CastResultHandler (0x6E7330)
// Packet: SMSG_CAST_RESULT (opcode 0x0130)
// Fires: SPELL_CAST_FAILED (when status != 0)
// =============================================================================

var cast_result_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn castResultDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    const spell_id = cdsGet(u32, cds);
    const status = cdsGet(u8, cds);

    cdsSetRead(cds, saved_read);

    if (spell_id != null and status != null and status.? != 0) {
        // SMSG_CAST_RESULT is only sent to the casting player
        const player_guid = getActivePlayerGuid();
        if (player_guid != 0) {
            const src_str = guidToString(player_guid);
            const school = getSpellSchool(spell_id.?);
            log.fmt("SPELL_CAST_FAILED: spell={d} status={d}\n", .{ spell_id.?, status.? });
            fireSpellStr(SUB_SPELL_CAST_FAILED, src_str, GUID_ZERO, spell_id.?, school, "FAILED");
        }
    }

    return cast_result_hook.callOriginal(.{ unk, opcode, unk2, cds });
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
                const dst_str = guidToString(guid);
                log.fmt("UNIT_DIED: unit=0x{x}\n", .{guid});
                fireBase(SUB_UNIT_DIED, GUID_ZERO, dst_str);
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
                const dst_str = guidToString(guid);
                const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);
                const school = getSpellSchool(spell_id);

                // Check if this aura was broken by damage (SPELL_AURA_BROKEN heuristic).
                // If the spell has damage-break flags and the target was recently damaged,
                // fire SPELL_AURA_BROKEN_SPELL (spell break) or SPELL_AURA_BROKEN (melee break).
                if (getSpellRecord(spell_id)) |rec| {
                    const aura_int_flags = hook.readMem(u32, rec + SPELL_AURA_INTERRUPT_FLAGS_OFFSET);
                    if (aura_int_flags & (AURA_INTERRUPT_FLAG_DAMAGE | AURA_INTERRUPT_FLAG_DIRECT_DAMAGE) != 0) {
                        if (findRecentDamage(guid)) |dmg| {
                            const src_str = if (dmg.source_guid != 0) guidToString(dmg.source_guid) else GUID_ZERO;
                            if (dmg.spell_id != 0) {
                                // Spell broke the aura — WotLK arg order: broken aura as primary, breaker as extra
                                const dmg_school = getSpellSchool(dmg.spell_id);
                                log.fmt("SPELL_AURA_BROKEN_SPELL: aura={d} by spell={d} src=0x{x}\n", .{ spell_id, dmg.spell_id, dmg.source_guid });
                                fireSpellDispel(SUB_SPELL_AURA_BROKEN_SPELL, src_str, dst_str, spell_id, school, dmg.spell_id, dmg_school, aura_type);
                            } else {
                                // Melee (swing) broke the aura — no breaking spell ID
                                log.fmt("SPELL_AURA_BROKEN: aura={d} by melee src=0x{x}\n", .{ spell_id, dmg.source_guid });
                                fireSpellStr(SUB_SPELL_AURA_BROKEN, src_str, dst_str, spell_id, school, aura_type);
                            }
                        }
                    }
                }

                // Always fire SPELL_AURA_REMOVED (even if broken — WotLK fires both)
                log.fmt("SPELL_AURA_REMOVED: spell={d} slot={d} unit=0x{x}\n", .{ spell_id, slot_index, guid });
                fireSpellStr(SUB_SPELL_AURA_REMOVED, GUID_ZERO, dst_str, spell_id, school, aura_type);
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
                const dst_str = guidToString(guid);
                const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);
                const school = getSpellSchool(spell_id);
                log.fmt("SPELL_AURA_APPLIED: spell={d} slot={d} unit=0x{x}\n", .{ spell_id, slot_index, guid });
                fireSpellStr(SUB_SPELL_AURA_APPLIED, GUID_ZERO, dst_str, spell_id, school, aura_type);
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
                            const dst_str = guidToString(guid);
                            const aura_type: [*:0]const u8 = getAuraType(spell_id, slot_index);
                            const school = getSpellSchool(spell_id);

                            if (new_count > old_count) {
                                log.fmt("SPELL_AURA_APPLIED_DOSE: spell={d} slot={d} count={d}\n", .{ spell_id, slot_index, new_count });
                                fireSpellStrD(SUB_SPELL_AURA_APPLIED_DOSE, GUID_ZERO, dst_str, spell_id, school, aura_type, new_count);
                            } else {
                                log.fmt("SPELL_AURA_REMOVED_DOSE: spell={d} slot={d} count={d}\n", .{ spell_id, slot_index, new_count });
                                fireSpellStrD(SUB_SPELL_AURA_REMOVED_DOSE, GUID_ZERO, dst_str, spell_id, school, aura_type, new_count);
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

fn extraAttacksDetour(caster_ptr: u32, _edx: u32, spell_id: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (caster_ptr != 0 and spell_id != 0) {
        const caster_lo = hook.readMem(u32, caster_ptr);
        const caster_hi = hook.readMem(u32, caster_ptr + 4);
        const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

        if (caster_guid != 0) {
            const src_str = guidToString(caster_guid);
            const school = getSpellSchool(spell_id);
            log.fmt("SPELL_EXTRA_ATTACKS: spell={d}\n", .{spell_id});
            // _EXTRA_ATTACKS: spellId, spellSchool, amount(0 — not available from downstream)
            fireCombatLog(SUB_SPELL_EXTRA_ATTACKS, src_str, GUID_ZERO, spell_id, school, 0, 0, 0, 0, 0);
        }
    }

    extra_attacks_hook.callOriginal(.{ caster_ptr, _edx, spell_id });
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
            const src_str = guidToString(caster_guid);
            const dst_str = guidToString(target_guid);
            const extra_school = getSpellSchool(spell_id);
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
            fireSpellDispel(SUB_SPELL_DISPEL, src_str, dst_str, 0, 0, spell_id, extra_school, aura_type_str);
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
        // EffectApplyAuraName[0..2] at offset 0x178, 0x17C, 0x180
        inline for (0..3) |i| {
            const aura = hook.readMem(u32, rec + 0x178 + @as(u32, @intCast(i)) * 4);
            if (aura == 81 or aura == 153 or aura == 193) return true;
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
            const is_energize = isEnergizeEffect(e0) or isEnergizeEffect(e1) or isEnergizeEffect(e2);

            if (is_summon or is_resurrect or is_energize) {
                const caster_lo = hook.readMem(u32, caster_ptr);
                const caster_hi = hook.readMem(u32, caster_ptr + 4);
                const caster_guid: u64 = @as(u64, caster_hi) << 32 | @as(u64, caster_lo);

                if (caster_guid != 0) {
                    const src_str = guidToString(caster_guid);
                    const school = hook.readMem(u32, rec + 0x04);

                    // Target may be NULL for summons (SPELLLOGEXECUTE case 10 passes NULL)
                    var dst_str: [*:0]const u8 = GUID_ZERO;
                    if (target_ptr != 0) {
                        const target_lo = hook.readMem(u32, target_ptr);
                        const target_hi = hook.readMem(u32, target_ptr + 4);
                        const target_guid: u64 = @as(u64, target_hi) << 32 | @as(u64, target_lo);
                        if (target_guid != 0) {
                            dst_str = guidToString(target_guid);
                        }
                    }

                    if (is_summon) {
                        log.fmt("SPELL_SUMMON: spell={d}\n", .{spell_id});
                        fireSpell(SUB_SPELL_SUMMON, src_str, dst_str, spell_id, school);
                    }
                    if (is_resurrect) {
                        log.fmt("SPELL_RESURRECT: spell={d}\n", .{spell_id});
                        fireSpell(SUB_SPELL_RESURRECT, src_str, dst_str, spell_id, school);
                    }
                    if (is_energize) {
                        log.fmt("SPELL_ENERGIZE: spell={d}\n", .{spell_id});
                        // _ENERGIZE: spellId, amount(0 — not available from SPELLLOGEXECUTE), powerType(0 — unknown)
                        fireCombatLog(SUB_SPELL_ENERGIZE, src_str, dst_str, spell_id, 0, 0, 0, 0, 0, 0);
                    }
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
                        const dst_str = guidToString(player_guid);
                        const aura_type = getAuraType(spell_id, slot);
                        const school = getSpellSchool(spell_id);
                        log.fmt("SPELL_AURA_REFRESH: spell={d} slot={d}\n", .{ spell_id, slot });
                        fireSpellStr(SUB_SPELL_AURA_REFRESH, GUID_ZERO, dst_str, spell_id, school, aura_type);
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
            const src_str = guidToString(caster_guid);
            const dst_str = guidToString(target_guid);

            // Loop: read spell IDs until buffer exhausted (ReadPointerFromStream reads u32)
            var count: u32 = 0;
            while (count < 20) : (count += 1) { // safety cap
                const spell_id = cdsGet(u32, cds);
                if (spell_id == null) break;
                if (spell_id.? == 0) break;

                const school = getSpellSchool(spell_id.?);
                log.fmt("SPELL_DISPEL_FAILED: spell={d} caster=0x{x} target=0x{x}\n", .{
                    spell_id.?, caster_guid, target_guid,
                });
                fireSpell(SUB_SPELL_DISPEL_FAILED, src_str, dst_str, spell_id.?, school);
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

    if (spell_dmg_hook.attach(0x5E85E0, &spellNonMeleeDmgLogDetour) != .ok) {
        log.print("FAILED to hook SpellNonMeleeDmgLogHandler\n");
    } else {
        log.print("Hooked SpellNonMeleeDmgLogHandler\n");
    }

    if (periodic_hook.attach(0x626DD0, &periodicAuraLogDetour) != .ok) {
        log.print("FAILED to hook PeriodicAuraLogHandler\n");
    } else {
        log.print("Hooked PeriodicAuraLogHandler\n");
    }

    if (heal_hook.attach(0x62C770, &healDisplayDetour) != .ok) {
        log.print("FAILED to hook ProcessSpellPowerDrainMessage\n");
    } else {
        log.print("Hooked ProcessSpellPowerDrainMessage (SPELL_HEAL)\n");
    }

    if (melee_hook.attach(0x6255B0, &meleeDispatcherDetour) != .ok) {
        log.print("FAILED to hook MeleeDispatcher\n");
    } else {
        log.print("Hooked MeleeDispatcher\n");
    }

    if (env_dmg_hook.attach(0x62AAC0, &envDamageDetour) != .ok) {
        log.print("FAILED to hook ProcessEnvironmentalDamage\n");
    } else {
        log.print("Hooked ProcessEnvironmentalDamage\n");
    }

    if (party_kill_hook.attach(0x628890, &partyKillLogDetour) != .ok) {
        log.print("FAILED to hook PartyKillLogHandler\n");
    } else {
        log.print("Hooked PartyKillLogHandler\n");
    }

    if (spell_start_hook.attach(0x6E7640, &spellStartDetour) != .ok) {
        log.print("FAILED to hook SpellStartHandler\n");
    } else {
        log.print("Hooked SpellStartHandler\n");
    }

    if (cast_result_hook.attach(0x6E7330, &castResultDetour) != .ok) {
        log.print("FAILED to hook CastResultHandler\n");
    } else {
        log.print("Hooked CastResultHandler\n");
    }

    if (spell_missed_hook.attach(0x62BAB0, &spellMissedDetour) != .ok) {
        log.print("FAILED to hook ProcessSpellCombatResult\n");
    } else {
        log.print("Hooked ProcessSpellCombatResult (SPELL_MISSED)\n");
    }

    if (damage_shield_hook.attach(0x62CA20, &damageShieldDetour) != .ok) {
        log.print("FAILED to hook ProcessSpellDrainEffectMessage\n");
    } else {
        log.print("Hooked ProcessSpellDrainEffectMessage (DAMAGE_SHIELD)\n");
    }

    if (spell_interrupt_hook.attach(0x626A10, &spellInterruptDetour) != .ok) {
        log.print("FAILED to hook DisplaySpellInterruptMessage\n");
    } else {
        log.print("Hooked DisplaySpellInterruptMessage (SPELL_INTERRUPT)\n");
    }

    if (instakill_hook.attach(0x62CBE0, &instaKillDetour) != .ok) {
        log.print("FAILED to hook ProcessInstaKillSpellMessage\n");
    } else {
        log.print("Hooked ProcessInstaKillSpellMessage (SPELL_INSTAKILL)\n");
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

    if (extra_attacks_hook.attach(0x62D9F0, &extraAttacksDetour) != .ok) {
        log.print("FAILED to hook ProcessExtraAttacksSpellMessage\n");
    } else {
        log.print("Hooked ProcessExtraAttacksSpellMessage (SPELL_EXTRA_ATTACKS)\n");
    }

    if (dispel_hook.attach(0x62D480, &dispelDetour) != .ok) {
        log.print("FAILED to hook ProcessAuraDispelMessage\n");
    } else {
        log.print("Hooked ProcessAuraDispelMessage (SPELL_DISPEL)\n");
    }

    if (spell_effect_hook.attach(0x62ACE0, &spellEffectDetour) != .ok) {
        log.print("FAILED to hook ProcessSpellEffect\n");
    } else {
        log.print("Hooked ProcessSpellEffect (SPELL_SUMMON/RESURRECT/ENERGIZE)\n");
    }

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
        dispel_failed_hook.detach();
        aura_duration_hook.detach();
        spell_effect_hook.detach();
        dispel_hook.detach();
        extra_attacks_hook.detach();
        aura_dose_hook.detach();
        aura_applied_hook.detach();
        aura_removed_hook.detach();
        unit_death_hook.detach();
        instakill_hook.detach();
        spell_interrupt_hook.detach();
        damage_shield_hook.detach();
        spell_missed_hook.detach();
        cast_result_hook.detach();
        spell_start_hook.detach();
        party_kill_hook.detach();
        env_dmg_hook.detach();
        melee_hook.detach();
        heal_hook.detach();
        periodic_hook.detach();
        spell_dmg_hook.detach();
        create_events_hook.detach();
        resize_events_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
