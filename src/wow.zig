//! Shared game memory access wrappers for WoW 1.12.1.
//!
//! Provides safe read helpers for the object manager, unit descriptors,
//! corpse fields, raid targets, map queries, and calling-convention
//! wrappers for game functions.

const std = @import("std");
const hook = @import("zhook");
const o = @import("offsets.zig");

// Re-export ObjectType so consumers can use wow.ObjectType
pub const ObjectType = enum(u32) {
    null_obj = 0,
    item = 1,
    container = 2,
    unit = 3,
    player = 4,
    game_object = 5,
    dynamic_object = 6,
    corpse = 7,
    _,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

// =============================================================================
// Pointer validation
// =============================================================================

const WINAPI = std.builtin.CallingConvention.winapi;

extern "kernel32" fn IsBadReadPtr(
    lp: ?*const anyopaque,
    ucb: usize,
) callconv(WINAPI) i32;

/// Quick sanity check — reject null, low-address, and kernel-space pointers.
pub fn isValidPtr(addr: u32) bool {
    return addr >= 0x10000 and addr < 0x7F000000;
}

/// Page-level read check via Windows API.
pub fn isReadablePtr(addr: u32, size: usize) bool {
    if (addr < 0x10000 or addr >= 0x7F000000) return false;
    return IsBadReadPtr(@ptrFromInt(addr), size) == 0;
}

// =============================================================================
// Object manager traversal
// =============================================================================

pub fn isInGame() bool {
    return hook.readMem(u32, o.IS_IN_WORLD) != 0;
}

/// The object manager is a more useful runtime readiness signal for the
/// standalone Outline path than IS_IN_WORLD on modified 1.12.1 clients.
pub fn hasObjectManager() bool {
    return hook.readMem(u32, o.OBJECT_MANAGER_PTR) != 0;
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

pub fn getObjectType(obj: u32) ObjectType {
    if (!isValidPtr(obj)) return .null_obj;
    return @enumFromInt(hook.readMem(u32, obj + o.OBJECT_TYPE_OFFSET));
}

pub fn getObjectTypeRaw(obj: u32) u32 {
    if (!isValidPtr(obj)) return 0;
    return hook.readMem(u32, obj + o.OBJECT_TYPE_OFFSET);
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

/// Read the descriptor/m_data pointer (at obj + 0x08).
pub fn getDescriptor(obj: u32) u32 {
    if (!isValidPtr(obj)) return 0;
    return hook.readMem(u32, obj + o.OBJECT_DATA_OFFSET);
}

/// Read the unit descriptor pointer (at obj + 0x110).
pub fn getUnitDescriptor(obj: u32) u32 {
    if (!isValidPtr(obj)) return 0;
    return hook.readMem(u32, obj + o.UNIT_DESCRIPTOR_OFFSET);
}

pub fn getObjectEntry(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + o.DESC_ENTRY);
}

pub fn getNpcFlags(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + o.DESC_NPC_FLAGS);
}

pub fn isLootable(obj: u32) bool {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return false;
    return (hook.readMem(u32, desc + o.DESC_UNIT_DYNAMIC_FLAGS) & o.UNIT_DYNFLAG_LOOTABLE) != 0;
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

pub fn getUnitPosition(unit: u32) Vec3 {
    if (unit == 0) return .{ .x = 0, .y = 0, .z = 0 };
    const movement = hook.readMem(u32, unit + o.UNIT_MOVEMENT_OFFSET);
    if (movement == 0 or movement < 0x10000) return .{ .x = 0, .y = 0, .z = 0 };
    return .{
        .x = hook.readMem(f32, movement + o.MOVEMENT_POS_X),
        .y = hook.readMem(f32, movement + o.MOVEMENT_POS_Y),
        .z = hook.readMem(f32, movement + o.MOVEMENT_POS_Z),
    };
}

// =============================================================================
// Corpse helpers
// =============================================================================

pub fn isSkeletonCorpse(obj: u32) bool {
    if (!isValidPtr(obj)) return false;
    const desc = hook.readMem(u32, obj + o.OBJECT_DATA_OFFSET);
    if (!isValidPtr(desc)) return false;
    const flags = hook.readMem(u32, desc + o.CORPSE_FIELD_FLAGS);
    return (flags & o.CORPSE_FLAG_BONE) != 0;
}

pub fn getCorpseOwnerGUID(obj: u32) u64 {
    if (!isValidPtr(obj)) return 0;
    const desc = hook.readMem(u32, obj + o.OBJECT_DATA_OFFSET);
    if (!isValidPtr(desc)) return 0;
    return readGUID(desc + o.CORPSE_FIELD_OWNER);
}

// =============================================================================
// Map / Battleground detection
// =============================================================================

/// Check if the current map is a battleground by reading Map.dbc mapType.
pub fn isInBattleground() bool {
    const obj_mgr = hook.readMem(u32, o.OBJECT_MANAGER_PTR);
    if (obj_mgr == 0) return false;
    const map_id = hook.readMem(u32, obj_mgr + o.OBJMGR_MAP_ID_OFFSET);
    const dbc_max = hook.readMem(u32, o.MAP_DBC_MAX);
    if (map_id > dbc_max) return false;
    const table_base = hook.readMem(u32, o.MAP_DBC_DATA);
    if (table_base == 0) return false;
    const row = hook.readMem(u32, table_base + map_id * 4);
    if (row == 0) return false;
    const map_type = hook.readMem(u32, row + o.MAP_DBC_MAP_TYPE_OFFSET);
    return map_type == o.MAP_TYPE_BATTLEGROUND;
}

/// Current map ID from the object manager (ObjMgr+0xCC).
/// Returns 0xFFFFFFFF if the object manager is not available.
pub fn getMapId() u32 {
    const obj_mgr = hook.readMem(u32, o.OBJECT_MANAGER_PTR);
    if (obj_mgr == 0) return 0xFFFFFFFF;
    return hook.readMem(u32, obj_mgr + o.OBJMGR_MAP_ID_OFFSET);
}

// =============================================================================
// Game function wrappers
// =============================================================================

/// UnitGUID("player") / UnitGUID("target") → 64-bit GUID.
pub fn unitGUID(unit_id: [*:0]const u8) u64 {
    // UnitGUID is __fastcall with its single argument in ECX.
    // hook.call + hook.cc.fastcall is currently miscompiled by Zig 0.16 on x86
    // as a stack argument. Because the callee consumes no stack argument, that
    // leaked 4 bytes per call; Outline calls UnitGUID("player"/"target") every
    // frame, so ESP drifted until execution returned into stack data.
    //
    // With a single register argument, x86_thiscall is ABI-compatible here:
    // ECX=unit_id, no stack args, u64 returned in EDX:EAX.
    const f_native: *const fn ([*:0]const u8) callconv(.{ .x86_thiscall = .{} }) u64 =
        @ptrFromInt(o.FN_UNIT_GUID);
    return @call(.never_tail, f_native, .{unit_id});
}

/// Resolve a GUID → object pointer via the object manager hash table.
pub fn getObjectByGUID(guid: u64) u32 {
    if (guid == 0) return 0;
    if (hook.readMem(u32, o.OBJECT_MANAGER_PTR) == 0) return 0;
    const lo: u32 = @truncate(guid);
    const hi: u32 = @truncate(guid >> 32);
    const result = hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, o.FN_GET_OBJECT_BY_GUID, .{ lo, hi });
    // Guard: hash table can return stale/invalid pointers for destroyed objects
    if (result != 0 and !isValidPtr(result)) return 0;
    return result;
}

/// Split-GUID variant for callers that already have lo/hi parts.
pub fn getObjectByGUIDSplit(guid_lo: u32, guid_hi: u32) u32 {
    if (guid_lo == 0 and guid_hi == 0) return 0;
    if (hook.readMem(u32, o.OBJECT_MANAGER_PTR) == 0) return 0;
    return hook.call(fn (u32, u32) callconv(hook.cc.stdcall) u32, o.FN_GET_OBJECT_BY_GUID, .{ guid_lo, guid_hi });
}

/// ClntObjMgrGetActivePlayer → local player GUID.
pub fn getPlayerGUID() u64 {
    return hook.call(fn () callconv(hook.cc.fastcall) u64, o.FN_GET_PLAYER_GUID, .{});
}

/// Get the local player's object pointer.
pub fn getLocalPlayer() u32 {
    const guid = unitGUID("player");
    if (guid == 0) return 0;
    return getObjectByGUID(guid);
}

// =============================================================================
// Group membership (party + raid)
// =============================================================================

/// Check if a GUID is the local player or in the player's party/raid.
pub fn isInGroup(guid: u64) bool {
    if (guid == 0) return false;
    if (getPlayerGUID() == guid) return true;

    // Party: 4 GUID slots at PARTY_MEMBER_GUIDS
    for (0..4) |i| {
        const member = readGUID(@intCast(o.PARTY_MEMBER_GUIDS + i * 8));
        if (member != 0 and member == guid) return true;
    }

    // Raid roster
    const count = hook.readMem(u32, o.RAID_ROSTER_COUNT);
    var j: u32 = 0;
    while (j < count and j < 40) : (j += 1) {
        const entry_ptr = hook.readMem(u32, @intCast(o.RAID_ROSTER_ARRAY + j * 4));
        if (entry_ptr == 0) continue;
        if (readGUID(entry_ptr) == guid) return true;
    }

    return false;
}

/// Creature cache at address 0xC0E138 (not a pointer — the object IS at this address).
const CREATURE_CACHE: u32 = 0xC0E138;

/// Cache_RequestData — generic cache lookup.
/// __thiscall(ECX=cacheObj, stack: entryId, guidPtr, callback, callbackArg, flags)
/// Returns pointer to cache row or NULL.
const FN_CACHE_REQUEST: usize = 0x566240;

/// Resolve a GUID to a unit/NPC name.
pub fn getNameByGUID(guid: u64) [*:0]const u8 {
    if (guid == 0) return "";
    const lo: u32 = @truncate(guid);
    const hi: u32 = @truncate(guid >> 32);

    // Check GUID type — high bytes distinguish player vs creature
    const guid_type: u32 = hi & 0xF0F00000;
    if (guid_type == 0) {
        // Player GUID — use player name cache (RetrieveNPCDataFromCache)
        var name_buf: [2]u32 = .{ 0, 0 };
        const result = hook.call(fn (u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) u32, o.FN_NAME_CACHE_LOOKUP, .{
            o.NAME_CACHE_OBJ, lo, hi, @intFromPtr(&name_buf), 0, 0, 0,
        });
        if (result != 0) {
            return @ptrFromInt(result);
        }
    } else {
        // Creature/pet GUID — resolve via object (safe during lazy resolution)
        const obj = getObjectByGUID(guid);
        if (obj != 0) {
            const name = getNameByObject(obj);
            if (@intFromPtr(name) != 0 and name[0] != 0) return name;
        }
    }
    return "";
}

/// CGUnit_C::GetNameFromCacheOrUnknown — __thiscall(ECX=unitObj, stack=outPtr), returns char*.
const FN_UNIT_GET_NAME: usize = 0x609210;

/// Resolve a GUID to a unit name via the unit object. Only safe to call when the
/// object manager is in a stable state (NOT during SMSG_UPDATE_OBJECT processing).
pub fn getNameByObject(obj: u32) [*:0]const u8 {
    if (obj == 0 or !isValidPtr(obj)) return "";
    const desc = hook.readMem(u32, obj + 8);
    if (desc == 0 or !isValidPtr(desc)) return "";
    const name_ptr = hook.call(fn (u32, u32) callconv(hook.cc.thiscall) u32, FN_UNIT_GET_NAME, .{ obj, 0 });
    if (name_ptr != 0 and isValidPtr(name_ptr)) {
        return @ptrFromInt(name_ptr);
    }
    return "";
}

/// Get the current target's GUID.
pub fn getTargetGUID() u64 {
    return unitGUID("target");
}

/// Check if a unit is friendly to the local player.
pub fn isUnitFriendly(unit: u32, local_player: u32) bool {
    if (unit == 0 or local_player == 0) return false;
    const reaction = hook.call(fn (u32, u32) callconv(hook.cc.thiscall) i32, o.FN_UNIT_REACTION, .{ local_player, unit });
    return reaction >= 4;
}

// =============================================================================
// Model owner resolution
// =============================================================================

const MODEL_OWNER_DIRECT: usize = 0x28;
const MODEL_OWNER_CALLBACK: usize = 0x3C0;

pub fn resolveModelOwner(model: u32) u32 {
    if (!isReadablePtr(model, MODEL_OWNER_CALLBACK + 4)) return 0;

    const candidate_cb = hook.readMem(u32, model + MODEL_OWNER_CALLBACK);
    if (candidate_cb != 0 and isReadablePtr(candidate_cb, 0x40)) {
        const guid_lo = hook.readMem(u32, candidate_cb + o.OBJECT_GUID_OFFSET);
        if (guid_lo != 0 and guid_lo < 0x10000000) return candidate_cb;
    }

    const candidate_dir = hook.readMem(u32, model + MODEL_OWNER_DIRECT);
    if (candidate_dir != 0 and isReadablePtr(candidate_dir, 0x40)) {
        const guid_lo = hook.readMem(u32, candidate_dir + o.OBJECT_GUID_OFFSET);
        if (guid_lo != 0 and guid_lo < 0x10000000) return candidate_dir;
    }

    return 0;
}

// =============================================================================
// Raid target cache
// =============================================================================

var cached_raid_targets: [8]u64 = .{0} ** 8;

pub fn cacheRaidTargets() void {
    for (0..8) |i| {
        cached_raid_targets[i] = readGUID(@intCast(o.RAID_TARGET_ARRAY + i * 8));
    }
}

pub fn getRaidMarkForGUID(guid: u64) u8 {
    if (guid == 0) return 0;
    for (cached_raid_targets, 0..) |rt, i| {
        if (rt == guid) return @intCast(i + 1);
    }
    return 0;
}
