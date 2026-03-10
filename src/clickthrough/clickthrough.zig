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
const offsets = @import("../offsets.zig");
const wow = @import("../wow.zig");

pub const module_name: [*:0]const u8 = "clickthrough";

// =============================================================================
// WoW addresses (module-specific)
// =============================================================================

const ADDR_WorldIntersectionTest: usize = 0x480DF0;

// =============================================================================
// HitTestResult layout
// =============================================================================

const HIT_GUID_LO: usize = 0x00;
const HIT_GUID_HI: usize = 0x04;
const HIT_RESULT_SIZE: usize = 0x34;

// Object struct offsets
const OBJ_TYPE_MASK_OFFSET: usize = 0x08; // at *(*(obj+8)+8)

// Type masks
const TYPE_UNIT: u32 = 0x09;
const TYPE_PLAYER: u32 = 0x19;

// Raycast flags
const FLAG_GO: u32 = 0x04;

/// Check if the GUID refers to an interactable GO.
fn isInteractableGO(guid_lo: u32, guid_hi: u32) bool {
    const obj = wow.getObjectByGUIDSplit(guid_lo, guid_hi);
    if (obj == 0) return false;
    if (wow.getObjectTypeRaw(obj) != @intFromEnum(wow.ObjectType.game_object)) return false;
    return hook.call(fn (u32) callconv(hook.cc.fastcall) u8, offsets.FN_CALL_SPELL_CAST_HANDLER, .{obj}) != 0;
}

/// Check if the GUID refers to an NPC with interaction flags (vendor, quest giver, etc.)
fn isInteractableNPC(guid_lo: u32, guid_hi: u32) bool {
    const obj = wow.getObjectByGUIDSplit(guid_lo, guid_hi);
    if (obj == 0) return false;
    if (wow.getObjectTypeRaw(obj) != @intFromEnum(wow.ObjectType.unit)) return false;
    return wow.getNpcFlags(obj) != 0;
}

/// Check if the second raycast result is something we should click through to.
fn isClickthroughTarget(guid_lo: u32, guid_hi: u32, allow_npcs: bool) bool {
    if (guid_lo == 0 and guid_hi == 0) return false;
    if (isInteractableGO(guid_lo, guid_hi)) return true;
    if (allow_npcs and isInteractableNPC(guid_lo, guid_hi)) return true;
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

// =============================================================================
// Hook: WorldIntersectionTest (0x480DF0)
// Called from HitTestPoint with the ray and flags. We call original, check
// the result, and if it's a unit/player, re-call with GO-only flags.
// =============================================================================

fn worldIntersectDetour(world_frame: u32, ray_start: u32, ray_end: u32, flags: u32, hit_result: u32) callconv(hook.cc.thiscall) u32 {
    // Call original with caller's flags
    const hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, flags, hit_result });

    // No click-through in battlegrounds
    if (!g_is_hook_owner or hit_result == 0 or hit_type != 2 or wow.isInBattleground()) return hit_type;

    // hitType 2 = object hit. Check if it's a unit/player.
    const buf_lo = hook.readMem(u32, hit_result + HIT_GUID_LO);
    const buf_hi = hook.readMem(u32, hit_result + HIT_GUID_HI);

    if (buf_lo == 0 and buf_hi == 0) return hit_type;

    const obj = wow.getObjectByGUIDSplit(buf_lo, buf_hi);
    if (obj == 0) return hit_type;

    const desc_ptr = wow.getDescriptor(obj);
    if (!wow.isValidPtr(desc_ptr)) return hit_type;

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

    if (recast_hit_type < 2) return hit_type;

    const r_guid_lo = std.mem.readInt(u32, recast_result[HIT_GUID_LO..][0..4], .little);
    const r_guid_hi = std.mem.readInt(u32, recast_result[HIT_GUID_HI..][0..4], .little);

    if (!isClickthroughTarget(r_guid_lo, r_guid_hi, allow_npcs)) return hit_type;

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
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    _ = wit_hook.attach(ADDR_WorldIntersectionTest, &worldIntersectDetour);

    log.fmt("WorldIntersectionTest hooked at 0x{x}\n", .{ADDR_WorldIntersectionTest});
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
