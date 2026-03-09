//! Game memory access wrappers for WoW 1.12.1.
//!
//! Provides safe read helpers for the object manager, unit descriptors,
//! corpse fields, raid targets, and calling-convention wrappers for
//! game functions (UnitGUID, GetObjectByGUID, UnitReaction).

const std = @import("std");
const hook = @import("zhook");
const o = @import("offsets.zig");
const types = @import("types.zig");

// =============================================================================
// Pointer validation
// =============================================================================

const WINAPI = std.builtin.CallingConvention.winapi;

extern "kernel32" fn IsBadReadPtr(
    lp: ?*const anyopaque,
    ucb: usize,
) callconv(WINAPI) i32;

/// Quick sanity check - reject null, low-address, and kernel-space pointers.
pub fn isValidPtr(addr: u32) bool {
    return addr >= 0x10000 and addr < 0x7F000000;
}

/// Check if a pointer is readable using the Windows API (matches C++ IsValidReadPtr).
/// This does an actual page-level check, not just a range check.
fn isReadablePtr(addr: u32, size: usize) bool {
    if (addr < 0x10000 or addr >= 0x7F000000) return false;
    return IsBadReadPtr(@ptrFromInt(addr), size) == 0;
}

// =============================================================================
// Object manager traversal
// =============================================================================

pub fn isInGame() bool {
    return hook.readMem(u32, o.IS_IN_WORLD) != 0;
}

pub fn objectFirst() u32 {
    const obj_mgr = hook.readMem(u32, o.OBJECT_MANAGER_PTR);
    if (obj_mgr == 0) return 0;
    return hook.readMem(u32, obj_mgr + o.OBJECT_LIST_OFFSET);
}

pub fn objectNext(current: u32) u32 {
    if (current == 0 or (current & 1) != 0) return 0;
    const obj_mgr = hook.readMem(u32, o.OBJECT_MANAGER_PTR);
    if (obj_mgr == 0) return 0;
    const base = hook.readMem(u32, obj_mgr + o.OBJECT_NEXT_OFFSET);
    const next = hook.readMem(u32, base + current + 4);
    if (next == 0 or (next & 1) != 0) return 0;
    return next;
}

// =============================================================================
// Object field reads
// =============================================================================

pub fn getObjectType(obj: u32) types.ObjectType {
    if (!isValidPtr(obj)) return .null_obj;
    return @enumFromInt(hook.readMem(u32, obj + o.OBJECT_TYPE_OFFSET));
}

pub fn readGUID(addr: u32) u64 {
    const lo = hook.readMem(u32, addr);
    const hi = hook.readMem(u32, addr + 4);
    return (@as(u64, hi) << 32) | lo;
}

pub fn getObjectGUID(obj: u32) u64 {
    if (!isValidPtr(obj)) return 0;
    return readGUID(obj + o.OBJECT_GUID_OFFSET);
}

// =============================================================================
// Unit helpers
// =============================================================================

pub fn isUnitDead(unit: u32) bool {
    if (!isValidPtr(unit)) return false;
    const desc = hook.readMem(u32, unit + o.UNIT_DESCRIPTOR_OFFSET);
    if (!isValidPtr(desc)) return false;
    const flags = hook.readMem(u32, desc + o.UNIT_FLAGS_OFFSET);
    return (flags & o.UNIT_FLAG_DEAD) != 0;
}

// =============================================================================
// Corpse helpers
// =============================================================================

pub fn isSkeletonCorpse(obj: u32) bool {
    if (!isValidPtr(obj)) return false;
    const desc = hook.readMem(u32, obj + o.CORPSE_DESCRIPTOR_OFFSET);
    if (!isValidPtr(desc)) return false;
    const flags = hook.readMem(u32, desc + o.CORPSE_FIELD_FLAGS);
    return (flags & o.CORPSE_FLAG_BONE) != 0;
}

pub fn getCorpseOwnerGUID(obj: u32) u64 {
    if (!isValidPtr(obj)) return 0;
    const desc = hook.readMem(u32, obj + o.CORPSE_DESCRIPTOR_OFFSET);
    if (!isValidPtr(desc)) return 0;
    return readGUID(desc + o.CORPSE_FIELD_OWNER);
}

// =============================================================================
// Model owner resolution
// =============================================================================

/// Try to resolve the game object that owns a render model.
/// Tries callback owner (model+0x3C0) first, then direct owner (model+0x28).
/// Uses IsBadReadPtr for page-level validation, matching the C++ IsValidReadPtr pattern.
pub fn resolveModelOwner(model: u32) u32 {
    // Need to read up to model+0x3C0+4
    if (!isReadablePtr(model, o.MODEL_OWNER_CALLBACK + 4)) return 0;

    // Try callback owner first - more reliable for units
    const candidate_cb = hook.readMem(u32, model + o.MODEL_OWNER_CALLBACK);
    if (candidate_cb != 0 and isReadablePtr(candidate_cb, 0x40)) {
        const guid_lo = hook.readMem(u32, candidate_cb + o.OBJECT_GUID_OFFSET);
        if (guid_lo != 0 and guid_lo < 0x10000000) return candidate_cb;
    }

    // Fallback to direct owner (already validated model is readable past 0x28)
    const candidate_dir = hook.readMem(u32, model + o.MODEL_OWNER_DIRECT);
    if (candidate_dir != 0 and isReadablePtr(candidate_dir, 0x40)) {
        const guid_lo = hook.readMem(u32, candidate_dir + o.OBJECT_GUID_OFFSET);
        if (guid_lo != 0 and guid_lo < 0x10000000) return candidate_dir;
    }

    return 0;
}

// =============================================================================
// Game function wrappers (calling-convention bridges)
// =============================================================================

/// UnitGUID("player") / UnitGUID("target") → 64-bit GUID.
/// __fastcall(unitIdStr_ECX) → EDX:EAX (u64).
pub fn unitGUID(unit_id: [*:0]const u8) u64 {
    return hook.call(fn ([*:0]const u8) callconv(hook.cc.fastcall) u64, o.FN_UNIT_GUID, .{unit_id});
}

/// Resolve a GUID → object pointer via the object manager hash table.
/// Ghidra-verified: __stdcall(guidLow, guidHigh) with RET 8.
pub fn getObjectByGUID(guid: u64) u32 {
    if (guid == 0) return 0;
    const lo: u32 = @truncate(guid);
    const hi: u32 = @truncate(guid >> 32);
    return hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, o.FN_GET_OBJECT_BY_GUID, .{ lo, hi });
}

/// Get the local player's object pointer.
pub fn getLocalPlayer() u32 {
    const guid = unitGUID("player");
    if (guid == 0) return 0;
    return getObjectByGUID(guid);
}

/// Get the current target's GUID.
pub fn getTargetGUID() u64 {
    return unitGUID("target");
}

/// Check if a unit is friendly to the local player.
/// Uses UnitReaction(__thiscall): ECX = localPlayer, stack = unit → int reaction.
/// Reaction >= 4 means friendly.
pub fn isUnitFriendly(unit: u32, local_player: u32) bool {
    if (unit == 0 or local_player == 0) return false;
    const reaction = hook.call(fn (u32, u32) callconv(hook.cc.thiscall) i32, o.FN_UNIT_REACTION, .{ local_player, unit });
    return reaction >= 4;
}

// =============================================================================
// Raid target cache
// =============================================================================

var cached_raid_targets: [8]u64 = .{0} ** 8;

/// Read the 8 raid target GUIDs from WoW's static array into a local cache.
pub fn cacheRaidTargets() void {
    for (0..8) |i| {
        cached_raid_targets[i] = readGUID(@intCast(o.RAID_TARGET_ARRAY + i * 8));
    }
}

/// Return the raid mark index (1-8) for a given GUID, or 0 if not marked.
pub fn getRaidMarkForGUID(guid: u64) u8 {
    if (guid == 0) return 0;
    for (cached_raid_targets, 0..) |rt, i| {
        if (rt == guid) return @intCast(i + 1);
    }
    return 0;
}
