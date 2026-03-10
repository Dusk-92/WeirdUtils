//! GO click-through module.
//!
//! Makes game objects (mailboxes, soulwells, etc.) clickable through players
//! and units by hooking WorldIntersectionTest (0x480DF0). When the normal
//! raycast hits a player/unit, we re-call the original with GO-only flags.
//! If a GO is found, we return that result instead.
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
// Target GO filtering
// =============================================================================

const OBJ_TYPE: usize = 0x14;
const OBJ_TYPE_GO: u32 = 5;
const ADDR_CallSpellCastHandler: usize = 0x5F8800;

fn getObjectByGUID(guid_lo: u32, guid_hi: u32) u32 {
    if (guid_lo == 0 and guid_hi == 0) return 0;
    return hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, ADDR_GetObjectByGUID, .{ guid_lo, guid_hi });
}

/// Check if the GUID refers to an interactable GO.
fn isInteractableGO(guid_lo: u32, guid_hi: u32) bool {
    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0) return false;
    const obj_type = hook.readMem(u32, obj + OBJ_TYPE);
    if (obj_type != OBJ_TYPE_GO) return false;
    // CallSpellCastHandler: __fastcall(obj_ECX) -> bool
    return hook.call(fn (u32) callconv(hook.cc.fastcall) u8, ADDR_CallSpellCastHandler, .{obj}) != 0;
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
    if (type_mask != TYPE_UNIT and type_mask != TYPE_PLAYER) return hit_type;

    // Hit a unit/player. Re-call original with unit/player flags stripped.
    const go_flags: u32 = 0x04; // GOs only
    var go_result = [_]u8{0} ** HIT_RESULT_SIZE;
    const go_hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, go_flags, @intFromPtr(&go_result) });

    g_log_counter +%= 1;
    if (g_log_counter % 60 == 0) {
        const go_lo = std.mem.readInt(u32, go_result[HIT_GUID_LO..][0..4], .little);
        const go_hi = std.mem.readInt(u32, go_result[HIT_GUID_HI..][0..4], .little);
        log.fmt("[ct] unit/player mask=0x{x}, GO re-raycast: type={d} guid=0x{x}:{x}\n", .{ type_mask, go_hit_type, go_hi, go_lo });
    }

    if (go_hit_type < 2) return hit_type;

    const go_guid_lo = std.mem.readInt(u32, go_result[HIT_GUID_LO..][0..4], .little);
    const go_guid_hi = std.mem.readInt(u32, go_result[HIT_GUID_HI..][0..4], .little);

    if (!isInteractableGO(go_guid_lo, go_guid_hi)) return hit_type;

    log.fmt("[ct] GO click-through: 0x{x}:{x} replaces unit/player 0x{x}:{x}\n", .{ go_guid_hi, go_guid_lo, buf_hi, buf_lo });

    // Replace the caller's hitResult with the GO result
    const dst: [*]u8 = @ptrFromInt(hit_result);
    @memcpy(dst[0..HIT_RESULT_SIZE], &go_result);

    return go_hit_type;
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
