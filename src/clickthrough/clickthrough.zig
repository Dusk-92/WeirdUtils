//! Click-through module.
//!
//! Makes interactable objects clickable through players and units by hooking
//! WorldIntersectionTest (0x480DF0). When the raycast hits a player, we
//! re-raycast without players to find interactable NPCs or GOs behind them.
//! When it hits a unit, we re-raycast GO-only to find interactable GOs.
//!
//! Hooks:
//!   WorldIntersectionTest (0x480DF0) -- sole raycast entry, called from HitTestPoint

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "clickthrough";

// =============================================================================
// WoW addresses
// =============================================================================

const ADDR_WorldIntersectionTest: usize = 0x480DF0;
const ADDR_GetObjectByGUID: usize = 0x464870;

// =============================================================================
// HitTestResult layout
// =============================================================================

const HIT_GUID_LO: usize = 0x00;
const HIT_GUID_HI: usize = 0x04;
const HIT_RESULT_SIZE: usize = 0x34;

// Object struct offsets
const OBJ_DESCRIPTOR: usize = 0x08;
const OBJ_TYPE_MASK_OFFSET: usize = 0x08; // at *(*(obj+8)+8)

// Type masks
const TYPE_UNIT: u32 = 0x09;
const TYPE_PLAYER: u32 = 0x19;

// Raycast flags
const FLAG_GO: u32 = 0x04;

// =============================================================================
// Object filtering
// =============================================================================

const OBJ_TYPE: usize = 0x14;
const OBJ_TYPE_UNIT: u32 = 3;
const OBJ_TYPE_GO: u32 = 5;
const DESC_NPC_FLAGS: usize = 0x93 * 4; // UNIT_NPC_FLAGS = OBJECT_END(0x06) + 0x8D = 0x93
const ADDR_CallSpellCastHandler: usize = 0x5F8800;

fn getObjectByGUID(guid_lo: u32, guid_hi: u32) u32 {
    if (guid_lo == 0 and guid_hi == 0) return 0;
    return hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, ADDR_GetObjectByGUID, .{ guid_lo, guid_hi });
}

/// Check if the GUID refers to an interactable GO (mailbox, soulwell, etc.)
fn isInteractableGO(guid_lo: u32, guid_hi: u32) bool {
    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0) return false;
    const obj_type = hook.readMem(u32, obj + OBJ_TYPE);
    if (obj_type != OBJ_TYPE_GO) return false;
    // CallSpellCastHandler: __fastcall(obj_ECX) -> bool
    return hook.call(fn (u32) callconv(hook.cc.fastcall) u8, ADDR_CallSpellCastHandler, .{obj}) != 0;
}

/// Check if the GUID refers to an NPC with interaction flags (vendor, quest giver, etc.)
fn isInteractableNPC(guid_lo: u32, guid_hi: u32) bool {
    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0) return false;
    const obj_type = hook.readMem(u32, obj + OBJ_TYPE);
    if (obj_type != OBJ_TYPE_UNIT) return false;
    const desc = hook.readMem(u32, obj + OBJ_DESCRIPTOR);
    if (desc < 0x10000 or desc >= 0x7F000000) return false;
    return hook.readMem(u32, desc + DESC_NPC_FLAGS) != 0;
}

/// Check if the second raycast result is something we should click through to.
fn isClickthroughTarget(guid_lo: u32, guid_hi: u32, allow_npcs: bool) bool {
    if (guid_lo == 0 and guid_hi == 0) return false;
    if (isInteractableGO(guid_lo, guid_hi)) return true;
    if (allow_npcs) {
        const obj = getObjectByGUID(guid_lo, guid_hi);
        if (obj != 0) {
            const obj_type = hook.readMem(u32, obj + OBJ_TYPE);
            const desc = hook.readMem(u32, obj + OBJ_DESCRIPTOR);
            const npc_flags: u32 = if (desc >= 0x10000 and desc < 0x7F000000) hook.readMem(u32, desc + DESC_NPC_FLAGS) else 0;
            log.fmt("[ct] NPC check: obj=0x{x} type={d} desc=0x{x} npc_flags=0x{x}\n", .{ obj, obj_type, desc, npc_flags });
        }
        if (isInteractableNPC(guid_lo, guid_hi)) return true;
    }
    return false;
}

// =============================================================================
// Hook state
// =============================================================================

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

// WorldIntersectionTest: __thiscall(ECX=worldFrame, rayStart*, rayEnd*, flags, hitResult*) -> hitType
// RET 0x10 (4 stack args)
const WorldIntersectFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) u32;
var wit_hook: hook.Detour(WorldIntersectFn) = .{};

var log: logging.Logger = .{};
var g_log_counter: u32 = 0;

// =============================================================================
// Hook: WorldIntersectionTest (0x480DF0)
// Called from HitTestPoint with the ray and flags. We call original, check
// the result, and if it's a unit/player, re-call with GO-only flags.
// =============================================================================

fn worldIntersectDetour(world_frame: u32, ray_start: u32, ray_end: u32, flags: u32, hit_result: u32) callconv(hook.cc.thiscall) u32 {
    // Call original with caller's flags
    const hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, flags, hit_result });

    if (!g_is_hook_owner or hit_result == 0 or hit_type != 2) return hit_type;

    // hitType 2 = object hit. Check if it's a unit/player.
    const buf_lo = hook.readMem(u32, hit_result + HIT_GUID_LO);
    const buf_hi = hook.readMem(u32, hit_result + HIT_GUID_HI);

    if (buf_lo == 0 and buf_hi == 0) return hit_type;

    const obj = getObjectByGUID(buf_lo, buf_hi);
    if (obj == 0) return hit_type;

    const desc_ptr = hook.readMem(u32, obj + OBJ_DESCRIPTOR);
    if (desc_ptr < 0x10000 or desc_ptr >= 0x7F000000) return hit_type;

    const type_mask = hook.readMem(u32, desc_ptr + OBJ_TYPE_MASK_OFFSET);

    // Determine re-raycast flags and whether NPCs are valid targets:
    //   Player hit → remove player flag, allow NPCs + GOs
    //   Unit hit   → GO-only flags, only allow GOs
    const recast_flags: u32 = switch (type_mask) {
        TYPE_PLAYER => flags & ~@as(u32, 0x10), // everything except players
        TYPE_UNIT => FLAG_GO, // GOs only
        else => return hit_type,
    };
    const allow_npcs = (type_mask == TYPE_PLAYER);

    var recast_result = [_]u8{0} ** HIT_RESULT_SIZE;
    const recast_hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, recast_flags, @intFromPtr(&recast_result) });

    g_log_counter +%= 1;
    if (g_log_counter % 60 == 0) {
        const r_lo = std.mem.readInt(u32, recast_result[HIT_GUID_LO..][0..4], .little);
        const r_hi = std.mem.readInt(u32, recast_result[HIT_GUID_HI..][0..4], .little);
        log.fmt("[ct] mask=0x{x} recast(flags=0x{x}): type={d} guid=0x{x}:{x}\n", .{ type_mask, recast_flags, recast_hit_type, r_hi, r_lo });
    }

    if (recast_hit_type < 2) return hit_type;

    const r_guid_lo = std.mem.readInt(u32, recast_result[HIT_GUID_LO..][0..4], .little);
    const r_guid_hi = std.mem.readInt(u32, recast_result[HIT_GUID_HI..][0..4], .little);

    if (!isClickthroughTarget(r_guid_lo, r_guid_hi, allow_npcs)) return hit_type;

    log.fmt("[ct] click-through: 0x{x}:{x} replaces 0x{x}:{x}\n", .{ r_guid_hi, r_guid_lo, buf_hi, buf_lo });

    // Replace the caller's hitResult with the recast result
    const dst: [*]u8 = @ptrFromInt(hit_result);
    @memcpy(dst[0..HIT_RESULT_SIZE], &recast_result);

    return recast_hit_type;
}

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    logging.print("[clickthrough] Module loaded\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    _ = wit_hook.attach(ADDR_WorldIntersectionTest, &worldIntersectDetour);

    log.fmt("[clickthrough] WorldIntersectionTest hooked at 0x{x}\n", .{ADDR_WorldIntersectionTest});
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        wit_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}

pub fn onShutdown() void {}
