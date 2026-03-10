//! DPS log module — structured combat log events.
//!
//! Hooks packet handlers for SMSG_SPELLNONMELEEDAMAGELOG,
//! SMSG_PERIODICAURALOG, SMSG_SPELLHEALLOG, and SMSG_ATTACKERSTATEUPDATE
//! to fire custom Lua events with structured numeric/string args, so addons
//! can skip string parsing.
//!
//! Custom events (registered in unused event table slots):
//!   COMBAT_LOG_SPELL_DMG  (551) — spell damage (direct)
//!   COMBAT_LOG_PERIODIC   (552) — periodic damage/heal ticks
//!   COMBAT_LOG_HEAL       (553) — direct heals
//!   COMBAT_LOG_MELEE      (554) — melee damage (auto-attack + special)
//!
//! Lua args for COMBAT_LOG_SPELL_DMG:
//!   arg1=targetGUID, arg2=casterGUID, arg3=spellId, arg4=damage,
//!   arg5=school, arg6=absorb, arg7=resist, arg8=blocked, arg9=hitInfo
//!
//! Lua args for COMBAT_LOG_PERIODIC:
//!   arg1=targetGUID, arg2=casterGUID, arg3=spellId, arg4=amount,
//!   arg5=school, arg6=absorb, arg7=resist, arg8=auraType, arg9=powerType
//!
//! Lua args for COMBAT_LOG_HEAL:
//!   arg1=targetGUID, arg2=casterGUID, arg3=spellId, arg4=healAmount,
//!   arg5=isCrit
//!
//! Lua args for COMBAT_LOG_MELEE:
//!   arg1=targetGUID, arg2=attackerGUID, arg3=totalDamage, arg4=school,
//!   arg5=absorb, arg6=resist, arg7=blocked, arg8=hitInfo, arg9=victimState

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "dpslog";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Custom event IDs & names
// =============================================================================

/// We register events at slots 551..554 (beyond nampower's 549/550).
/// The event name string pointer array has 4-byte stride per event ID.
/// Nampower: 549→0xBE1A2C, 550→0xBE1A30 → base = 0xBE1198.
///   551: 0xBE1A34   552: 0xBE1A38   553: 0xBE1A3C   554: 0xBE1A40
const EVENT_SPELL_DMG: u32 = 551;
const EVENT_PERIODIC: u32 = 552;
const EVENT_HEAL: u32 = 553;
const EVENT_MELEE: u32 = 554;

/// Derived from nampower: event 549 string ptr is at 0xBE1A2C → base = 0xBE1198.
const EVENT_STR_PTR_BASE: u32 = 0xBE1198;

/// Static event name strings — must outlive the process.
const event_name_spell_dmg: [*:0]const u8 = "COMBAT_LOG_SPELL_DMG";
const event_name_periodic: [*:0]const u8 = "COMBAT_LOG_PERIODIC";
const event_name_heal: [*:0]const u8 = "COMBAT_LOG_HEAL";
const event_name_melee: [*:0]const u8 = "COMBAT_LOG_MELEE";

// TODO: Detect nampower via GetModuleHandleA("nampower.dll") and skip
// overlapping SpellNonMeleeDmgLog/PeriodicAuraLog hooks if loaded (nampower
// fires SPELL_DAMAGE_EVENT_SELF/OTHER for those). Low priority — most users
// won't run both DLLs simultaneously.

// =============================================================================
// CDataStore helpers — direct memory reads from packet buffer
// =============================================================================
//
// CDataStore layout (from nampower cdatastore.hpp):
//   +0x00: vtable
//   +0x04: m_buffer (u8 pointer)
//   +0x08: m_base
//   +0x0C: m_alloc
//   +0x10: m_size
//   +0x14: m_read  (current read position)
//
// NOTE: the nampower header shows m_buffer at +0x00 after vtable, but
// CDataStore is a virtual class — vtable is +0x00, members follow.
// Let's match nampower's actual memory layout which treats it as:
//   m_buffer at offset after vtable. In the C++ class, the first member
//   after the vtable IS m_buffer. So:
//   +0x00: vtable ptr
//   +0x04: m_buffer
//   +0x08: m_base
//   +0x0C: m_alloc
//   +0x10: m_size
//   +0x14: m_read

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

/// Read a T from the CDataStore at the current read position, advancing m_read.
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

/// Read a packed GUID from the CDataStore. Returns null on read error.
/// Packed GUID format: 1-byte mask, then one byte per set bit in the mask.
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

/// Convert a u64 GUID to a 0x-prefixed hex string. Returns pointer to static buffer.
/// Uses two alternating buffers so we can format target + caster in one call.
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
// SignalEventParam — fire a Lua event with structured args
// =============================================================================
//
// SignalEventParam (0x703F50): __cdecl(eventId, fmtStr, ...)
// The format string uses %s/%d to push args as Lua event args (arg1, arg2, ...).
// We use typed wrapper functions since Zig can't express variadic cdecl generically.

/// Fire spell damage event: "%s%s%d%d%d%d%d%d%d"
/// args: targetGuid, casterGuid, spellId, damage, school, absorb, resist, blocked, hitInfo
fn fireSpellDamageEvent(event_id: u32, target: [*:0]const u8, caster: [*:0]const u8, spell_id: u32, damage: u32, school: u32, absorb: u32, resist: i32, blocked: u32, hit_info: u32) void {
    const SignalFn = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, i32, u32, u32) callconv(hook.cc.cdecl) void;
    const f: *const SignalFn = @ptrFromInt(0x703F50);
    // Format: targetGuid(s), casterGuid(s), spellId(d), damage(d), school(d), absorb(d), resist(d), blocked(d), hitInfo(d)
    @call(.auto, f, .{ event_id, "%s%s%d%d%d%d%d%d%d", target, caster, spell_id, damage, school, absorb, resist, blocked, hit_info });
}

/// Fire periodic event: "%s%s%d%d%d%d%d%d%d"
/// Same format as spell damage but with auraType instead of hitInfo.
fn firePeriodicEvent(event_id: u32, target: [*:0]const u8, caster: [*:0]const u8, spell_id: u32, amount: u32, school: u32, absorb: u32, resist: i32, aura_type: u32, power_type: u32) void {
    const SignalFn = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, i32, u32, u32) callconv(hook.cc.cdecl) void;
    const f: *const SignalFn = @ptrFromInt(0x703F50);
    @call(.auto, f, .{ event_id, "%s%s%d%d%d%d%d%d%d", target, caster, spell_id, amount, school, absorb, resist, aura_type, power_type });
}

/// Fire heal event: "%s%s%d%d%d"
/// args: targetGuid, casterGuid, spellId, healAmount, isCrit
fn fireHealEvent(event_id: u32, target: [*:0]const u8, caster: [*:0]const u8, spell_id: u32, amount: u32, is_crit: u32) void {
    const SignalFn = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32) callconv(hook.cc.cdecl) void;
    const f: *const SignalFn = @ptrFromInt(0x703F50);
    @call(.auto, f, .{ event_id, "%s%s%d%d%d", target, caster, spell_id, amount, is_crit });
}

// =============================================================================
// Hook: FrameScript_CreateEvents (0x703D90)
// Expands max event count to accommodate our custom event slots.
// =============================================================================

/// FrameScript_CreateEvents signature: __fastcall(ECX=param1, EDX=maxEventId)
/// Nampower hooks this as (int param_1, uint32_t maxEventId) — the first two
/// args in fastcall go to ECX and EDX.
var create_events_hook: hook.Detour(fn (u32, u32) callconv(hook.cc.fastcall) void) = .{};

fn createEventsDetour(param1: u32, max_event_id: u32) callconv(hook.cc.fastcall) void {
    // Expand to at least 556 (we use slots 551..554, need maxId > 554)
    var new_max = max_event_id;
    if (new_max < 556) {
        new_max = 556;
        log.fmt("FrameScript_CreateEvents: expanded maxEventId {d} -> {d}\n", .{ max_event_id, new_max });
    }
    create_events_hook.callOriginal(.{ param1, new_max });
}

// =============================================================================
// Hook: SpellNonMeleeDmgLogHandler (0x5E85E0)
// Packet: SMSG_SPELLNONMELEEDAMAGELOG
// Convention: FastCall(unk, opCode, unk2, CDataStore*)
// =============================================================================

const FastCallPacketHandlerFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;

var spell_dmg_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn spellNonMeleeDmgLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Save read position
    const saved_read = cdsGetRead(cds);

    // Parse SMSG_SPELLNONMELEEDAMAGELOG packet
    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const damage = cdsGet(u32, cds);
    const school = cdsGet(u8, cds);
    const absorb = cdsGet(u32, cds);
    const resist = cdsGet(i32, cds);
    const _periodic_log = cdsGet(u8, cds);
    const _unused = cdsGet(u8, cds);
    const blocked = cdsGet(u32, cds);
    const hit_info = cdsGet(u32, cds);

    // Restore read position before calling original
    cdsSetRead(cds, saved_read);

    // Fire event if all fields parsed successfully
    if (target_guid != null and caster_guid != null and spell_id != null and
        damage != null and school != null and absorb != null and resist != null and
        blocked != null and hit_info != null)
    {
        const target_str = guidToString(target_guid.?);
        const caster_str = guidToString(caster_guid.?);

        fireSpellDamageEvent(
            EVENT_SPELL_DMG,
            target_str,
            caster_str,
            spell_id.?,
            damage.?,
            @as(u32, school.?),
            absorb.?,
            resist.?,
            blocked.?,
            hit_info.?,
        );
    }

    _ = _periodic_log;
    _ = _unused;

    return spell_dmg_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: PeriodicAuraLogHandler (0x626DD0)
// Packet: SMSG_PERIODICAURALOG
// Convention: FastCall(unk, opCode, unk2, CDataStore*)
// =============================================================================

var periodic_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn periodicAuraLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    // Parse SMSG_PERIODICAURALOG packet
    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const count = cdsGet(u32, cds);

    if (target_guid != null and caster_guid != null and spell_id != null and count != null) {
        const target_str = guidToString(target_guid.?);
        const caster_str = guidToString(caster_guid.?);

        // Process first aura entry (count is almost always 1)
        const aura_type = cdsGet(u32, cds);
        if (aura_type) |at| {
            switch (at) {
                3, 89 => {
                    // PERIODIC_DAMAGE / PERIODIC_DAMAGE_PERCENT
                    const amount = cdsGet(u32, cds) orelse 0;
                    const spell_school = cdsGet(u32, cds) orelse 0;
                    const absorb = cdsGet(u32, cds) orelse 0;
                    const resist = cdsGet(i32, cds) orelse 0;

                    firePeriodicEvent(EVENT_PERIODIC, target_str, caster_str, spell_id.?, amount, spell_school, absorb, resist, at, 0);
                },
                8, 20 => {
                    // PERIODIC_HEAL / OBS_MOD_HEALTH
                    const amount = cdsGet(u32, cds) orelse 0;

                    firePeriodicEvent(EVENT_PERIODIC, target_str, caster_str, spell_id.?, amount, 0, 0, 0, at, 0);
                },
                21, 24 => {
                    // OBS_MOD_MANA / PERIODIC_ENERGIZE
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const amount = cdsGet(u32, cds) orelse 0;

                    firePeriodicEvent(EVENT_PERIODIC, target_str, caster_str, spell_id.?, amount, 0, 0, 0, at, power_type);
                },
                64 => {
                    // PERIODIC_MANA_LEECH
                    const power_type = cdsGet(u32, cds) orelse 0;
                    const amount = cdsGet(u32, cds) orelse 0;
                    _ = cdsGet(u32, cds); // multiplier (skip)

                    firePeriodicEvent(EVENT_PERIODIC, target_str, caster_str, spell_id.?, amount, 0, 0, 0, at, power_type);
                },
                else => {},
            }
        }
    }

    // Restore read position
    cdsSetRead(cds, saved_read);

    return periodic_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: SpellHealLogHandler (0x5E89C0)
// Packet: SMSG_SPELLHEALLOG (opcode 0x150)
// Convention: FastCall(unk, opCode, unk2, CDataStore*)
// Packet format: targetGuid(PackedGuid), casterGuid(PackedGuid),
//   spellId(u32), healAmount(u32), isCrit(u8)
// =============================================================================

var heal_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn spellHealLogDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const saved_read = cdsGetRead(cds);

    // Parse SMSG_SPELLHEALLOG packet
    const target_guid = cdsGetPackedGuid(cds);
    const caster_guid = cdsGetPackedGuid(cds);
    const spell_id = cdsGet(u32, cds);
    const heal_amount = cdsGet(u32, cds);
    const is_crit_raw = cdsGet(u8, cds);

    cdsSetRead(cds, saved_read);

    if (target_guid != null and caster_guid != null and spell_id != null and
        heal_amount != null and is_crit_raw != null)
    {
        const target_str = guidToString(target_guid.?);
        const caster_str = guidToString(caster_guid.?);
        const is_crit: u32 = if (is_crit_raw.? != 0) 1 else 0;

        fireHealEvent(EVENT_HEAL, target_str, caster_str, spell_id.?, heal_amount.?, is_crit);
    }

    return heal_hook.callOriginal(.{ unk, opcode, unk2, cds });
}

// =============================================================================
// Hook: MeleeDispatcher (0x6255B0)
// Shared packet handler for opcodes 0x143-0x14A. We filter for 0x14A only.
// Packet: SMSG_ATTACKERSTATEUPDATE (opcode 0x14A)
// Convention: FastCall(unk, opCode, unk2, CDataStore*)
//
// Packet format:
//   hitInfo(u32), attackerGuid(PackedGuid), targetGuid(PackedGuid),
//   totalDamage(u32), subDamageCount(u8),
//   per sub: school(u32), damageFP(f32), damage(u32), absorb(u32), resist(u32),
//   victimState(u32), unknown1(u32), unknown2(u32), spellId(u32),
//   if hitInfo & 0x1: blocked(u32)
// =============================================================================

const OPCODE_ATTACKERSTATEUPDATE: u32 = 0x14A;

var melee_hook: hook.Detour(FastCallPacketHandlerFn) = .{};

fn meleeDispatcherDetour(unk: u32, opcode: u32, unk2: u32, cds: u32) callconv(hook.cc.fastcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Only intercept SMSG_ATTACKERSTATEUPDATE; pass all other opcodes through
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

    // Read first sub-damage entry for school/absorb/resist
    var school: u32 = 0;
    var absorb: u32 = 0;
    var resist: u32 = 0;

    if (sub_count > 0) {
        school = cdsGet(u32, cds) orelse 0;
        _ = cdsGet(f32, cds); // damageFP (skip)
        _ = cdsGet(u32, cds); // damage (skip, use totalDamage)
        absorb = cdsGet(u32, cds) orelse 0;
        resist = cdsGet(u32, cds) orelse 0;

        // Skip remaining sub-damage entries
        var i: u8 = 1;
        while (i < sub_count) : (i += 1) {
            _ = cdsGet(u32, cds); // school
            _ = cdsGet(f32, cds); // damageFP
            _ = cdsGet(u32, cds); // damage
            _ = cdsGet(u32, cds); // absorb
            _ = cdsGet(u32, cds); // resist
        }
    }

    const victim_state = cdsGet(u32, cds) orelse return;
    _ = cdsGet(u32, cds); // unknown1
    _ = cdsGet(u32, cds); // unknown2
    _ = cdsGet(u32, cds); // spellId (0 for melee, nonzero for special attacks)

    var blocked: u32 = 0;
    if (hit_info & 0x1 != 0) {
        blocked = cdsGet(u32, cds) orelse 0;
    }

    const target_str = guidToString(target_guid);
    const attacker_str = guidToString(attacker_guid);

    // Fire melee event: same 9-arg format as spell damage
    // arg1=target, arg2=attacker, arg3=totalDamage, arg4=school,
    // arg5=absorb, arg6=resist, arg7=blocked, arg8=hitInfo, arg9=victimState
    fireMeleeEvent(EVENT_MELEE, target_str, attacker_str, total_damage, school, absorb, resist, blocked, hit_info, victim_state);
}

/// Fire melee event: "%s%s%d%d%d%d%d%d%d"
/// args: targetGuid, attackerGuid, totalDamage, school, absorb, resist, blocked, hitInfo, victimState
fn fireMeleeEvent(event_id: u32, target: [*:0]const u8, attacker: [*:0]const u8, damage: u32, school: u32, absorb: u32, resist: u32, blocked: u32, hit_info: u32, victim_state: u32) void {
    const SignalFn = fn (u32, [*:0]const u8, [*:0]const u8, [*:0]const u8, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.cdecl) void;
    const f: *const SignalFn = @ptrFromInt(0x703F50);
    @call(.auto, f, .{ event_id, "%s%s%d%d%d%d%d%d%d", target, attacker, damage, school, absorb, resist, blocked, hit_info, victim_state });
}

// =============================================================================
// Custom event registration — write event name ptrs to unused table slots
// =============================================================================

fn registerCustomEvents() void {
    // Each event slot's string name pointer is at EVENT_STR_PTR_BASE + eventId * 4
    // These are in .data (RW), so writeProtected is needed since the event name
    // array is in .rdata/.data boundary area.

    const spell_dmg_addr = EVENT_STR_PTR_BASE + EVENT_SPELL_DMG * 4;
    const periodic_addr = EVENT_STR_PTR_BASE + EVENT_PERIODIC * 4;
    const heal_addr = EVENT_STR_PTR_BASE + EVENT_HEAL * 4;
    const melee_addr = EVENT_STR_PTR_BASE + EVENT_MELEE * 4;

    const spell_dmg_ptr: u32 = @intFromPtr(event_name_spell_dmg);
    const periodic_ptr: u32 = @intFromPtr(event_name_periodic);
    const heal_ptr: u32 = @intFromPtr(event_name_heal);
    const melee_ptr: u32 = @intFromPtr(event_name_melee);

    hook.writeProtected(spell_dmg_addr, std.mem.asBytes(&spell_dmg_ptr));
    hook.writeProtected(periodic_addr, std.mem.asBytes(&periodic_ptr));
    hook.writeProtected(heal_addr, std.mem.asBytes(&heal_ptr));
    hook.writeProtected(melee_addr, std.mem.asBytes(&melee_ptr));

    log.fmt("Registered events: {d}={s}, {d}={s}, {d}={s}, {d}={s}\n", .{
        EVENT_SPELL_DMG, std.mem.span(event_name_spell_dmg),
        EVENT_PERIODIC,  std.mem.span(event_name_periodic),
        EVENT_HEAL,      std.mem.span(event_name_heal),
        EVENT_MELEE,     std.mem.span(event_name_melee),
    });
}

// =============================================================================
// Install / remove
// =============================================================================

pub fn installHooks() void {

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .console);

    // Register custom events (overwrite event name string pointers)
    registerCustomEvents();

    // Hook FrameScript_CreateEvents to expand event count
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

    if (heal_hook.attach(0x5E89C0, &spellHealLogDetour) != .ok) {
        log.print("FAILED to hook SpellHealLogHandler\n");
    } else {
        log.print("Hooked SpellHealLogHandler\n");
    }

    if (melee_hook.attach(0x6255B0, &meleeDispatcherDetour) != .ok) {
        log.print("FAILED to hook MeleeDispatcher\n");
    } else {
        log.print("Hooked MeleeDispatcher\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        melee_hook.detach();
        heal_hook.detach();
        periodic_hook.detach();
        spell_dmg_hook.detach();
        create_events_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
