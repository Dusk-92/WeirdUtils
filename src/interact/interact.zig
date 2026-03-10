const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const offsets = @import("../offsets.zig");
const wow = @import("../wow.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn GetTickCount() callconv(WINAPI) u32;

// =============================================================================
// Module-specific addresses
// =============================================================================

const Offsets = struct {
    const FUN_RIGHT_CLICK_UNIT: usize = 0x60BEA0;
    const FUN_RIGHT_CLICK_OBJECT: usize = 0x5F8660;
    const FUN_SET_TARGET: usize = 0x493540;
    const LOOT_GUID_LO: usize = 0x00B71B48;
    const LOOT_GUID_HI: usize = 0x00B71B4C;
    const LUA_ERROR: usize = 0x6F4940;
    const LUA_ISNUMBER: usize = 0x6F34D0;
    const LUA_TONUMBER: usize = 0x6F3620;
};

// =============================================================================
// Types
// =============================================================================

const ObjectType = enum(u32) {
    none = 0,
    item = 1,
    container = 2,
    unit = 3,
    player = 4,
    game_object = 5,
    dynamic_object = 6,
    corpse = 7,
};

const C3Vector = struct {
    y: f32,
    x: f32,
    z: f32,
};

// =============================================================================
// Calling Conventions
// =============================================================================

// =============================================================================
// Game API
// =============================================================================

fn getObjectPointer(guid: u64) u32 {
    return wow.getObjectByGUID(guid);
}

fn isInWorld() bool {
    return wow.isInGame();
}

fn getUnitPosition(unit: u32) C3Vector {
    return .{
        .y = hook.readMem(f32, unit + 0x09B8),
        .x = hook.readMem(f32, unit + 0x09BC),
        .z = hook.readMem(f32, unit + 0x09C0),
    };
}

fn getObjectPosition(pointer: u32) C3Vector {
    const p = hook.readMem(u32, pointer + 0x110);
    return .{
        .y = hook.readMem(f32, p + 0x24),
        .x = hook.readMem(f32, p + 0x28),
        .z = hook.readMem(f32, p + 0x2C),
    };
}

fn getUnitHealth(unit: u32) i32 {
    return hook.readMem(i32, hook.readMem(u32, unit + 0x8) + 0x58);
}

fn isUnitLootable(unit: u32) bool {
    const flags = hook.readMem(i32, hook.readMem(u32, unit + 0x8) + 0x23C);
    return (flags & 1) != 0;
}

fn isUnitSkinnable(unit: u32) bool {
    const flags = hook.readMem(i32, hook.readMem(u32, unit + 0x8) + 0xB8);
    return (flags & 0x4000000) == 0x4000000;
}

fn setTarget(guid: u64) void {
    const lo: u32 = @truncate(guid);
    const hi: u32 = @truncate(guid >> 32);
    hook.call(fn (u32, u32) callconv(hook.cc.stdcall) void, Offsets.FUN_SET_TARGET, .{ lo, hi });
}

fn rightClickInteract(pointer: u32, autoloot: i32, fun_ptr: usize) void {
    hook.call(fn (u32, i32) callconv(hook.cc.thiscall) void, fun_ptr, .{ pointer, autoloot });
}

// =============================================================================
// Utility
// =============================================================================

fn distance3D(v1: C3Vector, v2: C3Vector) f32 {
    const dx = v2.x - v1.x;
    const dy = v2.y - v1.y;
    const dz = v2.z - v1.z;
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

const blacklist = [_]u32{ 179830, 179831, 179785, 179786 };

fn isBlacklisted(id: u32) bool {
    for (blacklist) |b| {
        if (b == id) return true;
    }
    return false;
}

// =============================================================================
// Lua helpers
// =============================================================================

fn luaIsNumber(L: *anyopaque, idx: i32) bool {
    return hook.call(fn (usize, i32) callconv(hook.cc.fastcall) u32, Offsets.LUA_ISNUMBER, .{ @intFromPtr(L), idx }) != 0;
}

fn luaToNumber(L: *anyopaque, idx: i32) f64 {
    return hook.call(fn (usize, i32) callconv(hook.cc.fastcall) f64, Offsets.LUA_TONUMBER, .{ @intFromPtr(L), idx });
}

fn luaPrintError(L: *anyopaque, msg: [*:0]const u8) void {
    hook.call(fn (*anyopaque, [*:0]const u8) callconv(.c) void, Offsets.LUA_ERROR, .{ L, msg });
}

// =============================================================================
// InteractNearest - find closest interactable within 5 yards, right-click it
// =============================================================================

pub fn interactNearest(L: *anyopaque) callconv(.c) u32 {
    if (!isInWorld()) return 0;

    if (!luaIsNumber(L, 1)) {
        luaPrintError(L, "Usage: InteractNearest(autoloot)");
        return 0;
    }

    const objects = hook.readMem(u32, offsets.OBJECT_MANAGER_PTR);
    var current_object = hook.readMem(u32, objects + 0xAC);

    const player_guid = hook.readMem(u64, objects + 0xC0);
    const player = getObjectPointer(player_guid);
    const p_pos = getUnitPosition(player);

    var best_distance: f32 = 1000.0;
    var candidate: u32 = 0xFFFFFFFF;

    while (current_object != 0 and (current_object & 1) == 0) {
        const guid = hook.readMem(u64, current_object + 0x30);
        const pointer = getObjectPointer(guid);
        const obj_type = hook.readMem(u32, pointer + 0x14);

        // Skip objects summoned by players (totems, pets, etc.)
        const summoned_by_guid = hook.readMem(u64, hook.readMem(u32, pointer + 0x8) + 0x30);
        const summoned_by = getObjectPointer(summoned_by_guid);

        if (summoned_by_guid != 0 and summoned_by != 0) {
            const owner_type = hook.readMem(u32, summoned_by + 0x14);
            if (owner_type == @intFromEnum(ObjectType.player)) {
                current_object = hook.readMem(u32, current_object + 0x3C);
                continue;
            }
        }

        var o_pos: C3Vector = undefined;
        if (obj_type == @intFromEnum(ObjectType.unit)) {
            o_pos = getUnitPosition(current_object);
        } else if (obj_type == @intFromEnum(ObjectType.game_object)) {
            o_pos = getObjectPosition(current_object);
        } else {
            current_object = hook.readMem(u32, current_object + 0x3C);
            continue;
        }

        const dist = distance3D(o_pos, p_pos);
        if (dist <= 5.0 and dist < best_distance) {
            if (obj_type == @intFromEnum(ObjectType.unit)) {
                const health = getUnitHealth(current_object);
                if (health == 0 and (isUnitLootable(current_object) or isUnitSkinnable(current_object))) {
                    best_distance = dist;
                    candidate = current_object;
                } else if (health > 0) {
                    best_distance = dist;
                    candidate = current_object;
                }
            } else if (obj_type == @intFromEnum(ObjectType.game_object)) {
                const id = hook.readMem(u32, pointer + 0x294);
                if (!isBlacklisted(id)) {
                    best_distance = dist;
                    candidate = current_object;
                }
            }
        }

        current_object = hook.readMem(u32, current_object + 0x3C);
    }

    if (candidate == 0xFFFFFFFF) return 0;

    const candidate_guid = hook.readMem(u64, candidate + 0x30);
    const candidate_pointer = getObjectPointer(candidate_guid);
    const candidate_type = hook.readMem(u32, candidate_pointer + 0x14);

    const autoloot: i32 = @intFromFloat(luaToNumber(L, 1));

    if (candidate_type == @intFromEnum(ObjectType.unit)) {
        setTarget(candidate_guid);
        rightClickInteract(candidate, autoloot, Offsets.FUN_RIGHT_CLICK_UNIT);
    } else {
        rightClickInteract(candidate_pointer, autoloot, Offsets.FUN_RIGHT_CLICK_OBJECT);
    }

    return 1;
}

// =============================================================================
// LootAllCorpses - queue nearby lootable corpses, loot them sequentially
// =============================================================================

const MAX_LOOT_QUEUE: usize = 100;

const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "interact";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

var loot_queue: [MAX_LOOT_QUEUE]u64 = .{0} ** MAX_LOOT_QUEUE;
var loot_queue_count: usize = 0;
var loot_queue_index: usize = 0;
var loot_active: bool = false;
var loot_last_interact_time: u32 = 0;
var loot_next_delay: u32 = 0;

fn interactNextCorpse() void {
    while (loot_queue_index < loot_queue_count) {
        const guid = loot_queue[loot_queue_index];
        loot_queue_index += 1;

        const pointer = getObjectPointer(guid);
        if (pointer == 0) continue;

        const obj_type = hook.readMem(u32, pointer + 0x14);
        if (obj_type != @intFromEnum(ObjectType.unit)) continue;

        if (getUnitHealth(pointer) != 0) continue;
        if (!isUnitLootable(pointer)) continue;

        setTarget(guid);
        rightClickInteract(pointer, 1, Offsets.FUN_RIGHT_CLICK_UNIT);
        const now = GetTickCount();
        loot_last_interact_time = now;
        // 300ms base + 0-100ms jitter
        loot_next_delay = 300 + (now *% 2654435761) % 101;
        return;
    }

    loot_active = false;
}

fn processLootQueue() void {
    const now = GetTickCount();
    const elapsed = now -% loot_last_interact_time;

    const loot_guid_lo = hook.readMem(u32, Offsets.LOOT_GUID_LO);
    const loot_guid_hi = hook.readMem(u32, Offsets.LOOT_GUID_HI);

    if (loot_guid_lo != 0 or loot_guid_hi != 0) {
        // Loot window is open - wait for auto-loot to finish.
        // If items remain after timeout (e.g. unique items already owned),
        // skip to next corpse.
        if (elapsed > 1500) {
            interactNextCorpse();
        }
        return;
    }

    // Loot GUID is zero - loot closed or server hasn't responded yet
    if (elapsed < loot_next_delay) return;

    interactNextCorpse();
}

pub fn lootAllCorpses(_: *anyopaque) callconv(.c) u32 {
    if (!isInWorld()) return 0;

    // Cancel any in-progress chain
    loot_queue_count = 0;
    loot_queue_index = 0;
    loot_active = false;

    const objects = hook.readMem(u32, offsets.OBJECT_MANAGER_PTR);
    var current_object = hook.readMem(u32, objects + 0xAC);

    const player_guid = hook.readMem(u64, objects + 0xC0);
    const player = getObjectPointer(player_guid);
    const p_pos = getUnitPosition(player);

    while (current_object != 0 and (current_object & 1) == 0) {
        if (loot_queue_count >= MAX_LOOT_QUEUE) break;

        const guid = hook.readMem(u64, current_object + 0x30);
        const pointer = getObjectPointer(guid);
        const obj_type = hook.readMem(u32, pointer + 0x14);

        if (obj_type == @intFromEnum(ObjectType.unit)) {
            const o_pos = getUnitPosition(current_object);
            const dist = distance3D(o_pos, p_pos);

            if (dist <= 5.0) {
                const health = getUnitHealth(current_object);
                if (health == 0 and isUnitLootable(current_object)) {
                    loot_queue[loot_queue_count] = guid;
                    loot_queue_count += 1;
                }
            }
        }

        current_object = hook.readMem(u32, current_object + 0x3C);
    }

    if (loot_queue_count == 0) return 0;

    loot_active = true;
    interactNextCorpse();

    return 0;
}

// =============================================================================
// Hook: SceneEnd (0x5A17A0)
// __thiscall(CGxDevice*), 9-byte prologue, no fixups.
// Per-frame hook for processing the loot queue.
// =============================================================================

const SceneEndFn = fn (u32) callconv(hook.cc.thiscall) void;
var scene_end_hook: hook.Detour(SceneEndFn) = .{};

fn hookSceneEnd(device: u32) callconv(hook.cc.thiscall) void {
    if (loot_active) {
        processLootQueue();
    }

    scene_end_hook.callOriginal(.{device});
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .console);
    _ = scene_end_hook.attach(offsets.FN_SCENE_END, &hookSceneEnd);
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        scene_end_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
