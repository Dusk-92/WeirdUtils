//! Client-side world marker system
//!
//! Manages up to 5 colored markers placed at world positions.
//! Uses CreateEntityInstance_WithAttachment (0x6707c0) for entity lifecycle.
//!
//! Lua API:
//!   WorldMarker(index, x, y, z)  — place marker at coordinates
//!   WorldMarker(index, "unit")   — place marker at unit's position
//!   WorldMarker(index)           — place marker at cursor terrain position
//!   ClearWorldMarker(index)      — remove specific marker (1-5)
//!   ClearWorldMarker()           — remove all markers

const std = @import("std");
const hook = @import("zhook");
const o = @import("offsets.zig");
const wow = @import("../outline/wow.zig");
const con = @import("../console.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
extern "kernel32" fn GetTickCount() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

// =============================================================================
// Constants
// =============================================================================

const NUM_MARKERS = 5;
const MARKER_Z_OFFSET: f32 = 2.0;

// M2 animation IDs for Raid_UI_FX models (not standard Birth/Death)
const ANIM_STAND: u32 = 0; // 4000ms grow-in (bones scale from 1x to full)
const ANIM_HOLD: u32 = 158; // sustained idle at full scale (loops)
const ANIM_DECAY: u32 = 159; // 666ms shrink-out
const DECAY_DURATION_MS: u32 = 700; // slightly over 666ms to ensure animation completes

const MODEL_PATHS = [NUM_MARKERS][*:0]const u8{
    "Spells\\Raid_UI_FX_Yellow.m2",
    "Spells\\Raid_UI_FX_Cyan.m2",
    "Spells\\Raid_UI_FX_Green.m2",
    "Spells\\Raid_UI_FX_Purple.m2",
    "Spells\\Raid_UI_FX_Red.m2",
};

// =============================================================================
// Types
// =============================================================================

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

// =============================================================================
// State
// =============================================================================

var marker_entities: [NUM_MARKERS]?*anyopaque = .{null} ** NUM_MARKERS;

// Entities playing their Decay animation before destruction.
// Cleaned up lazily on the next marker operation.
// TODO: could use actual game timing (e.g. frame delta from WorldFrameUpdate) instead of GetTickCount
const MAX_DESPAWNING = 8;
const DespawningEntity = struct {
    entity: *anyopaque,
    start_tick: u32,
};
var despawning: [MAX_DESPAWNING]?DespawningEntity = .{null} ** MAX_DESPAWNING;

// =============================================================================
// Lua C API (WoW 1.12.1 — all __fastcall, L in ECX)
// =============================================================================

const fc = std.builtin.CallingConvention{ .x86_fastcall = .{} };

const lapi = struct {
    fn gettop(L: u32) i32 {
        const f: *const fn (u32) callconv(fc) i32 = @ptrFromInt(0x6F3070);
        return f(L);
    }

    fn isnumber(L: u32, index: i32) bool {
        const f: *const fn (u32, i32) callconv(fc) u32 = @ptrFromInt(0x6F34D0);
        return f(L, index) != 0;
    }

    fn isstring(L: u32, index: i32) bool {
        const f: *const fn (u32, i32) callconv(fc) u32 = @ptrFromInt(0x6F3510);
        return f(L, index) != 0;
    }

    fn tonumber(L: u32, index: i32) f64 {
        const f: *const fn (u32, i32) callconv(fc) f64 = @ptrFromInt(0x6F3620);
        return f(L, index);
    }

    fn tostring(L: u32, index: i32) ?[*:0]const u8 {
        const f: *const fn (u32, i32) callconv(fc) ?[*:0]const u8 = @ptrFromInt(0x6F3690);
        return f(L, index);
    }

    fn pushstring(L: u32, s: [*:0]const u8) void {
        const f: *const fn (u32, [*:0]const u8) callconv(fc) void = @ptrFromInt(0x6F3890);
        f(L, s);
    }

    fn pushnumber(L: u32, n: f64) void {
        const f: *const fn (u32, f64) callconv(fc) void = @ptrFromInt(0x6F3810);
        f(L, n);
    }
};

// =============================================================================
// Position helpers
// =============================================================================

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

/// Resolve a unit ID string ("player", "target", etc.) to a world position.
fn resolveUnitPosition(unit_id: [*:0]const u8) ?Vec3 {
    const guid = wow.unitGUID(unit_id);
    if (guid == 0) return null;
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const pos = getUnitPosition(obj);
    if (pos.x == 0 and pos.y == 0 and pos.z == 0) return null;
    return pos;
}

/// Get the terrain position under the mouse cursor by calling UpdateHitTest.
/// This performs a camera-through-cursor raycast and stores the result at
/// worldFrame+0x350. Safe to call from Lua callbacks (saves/restores matrices).
fn getCursorTerrainPosition() ?Vec3 {
    const world_frame = hook.readMem(u32, o.PTR_WORLD_FRAME);
    if (world_frame == 0 or world_frame < 0x10000) return null;

    // Zero the intersection point before raycasting so we can detect "no hit"
    // (HitTestPoint returns 0 for both "terrain hit" and "no hit" in normal mode —
    // WorldIntersectionTest returns gameStateFlags & 1, which is 0 outside AoE targeting.
    // On a real hit the coords are overwritten; on sky/no-hit they stay zeroed.)
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_X)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Y)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Z)).* = 0;

    // UpdateHitTest — __fastcall(ECX=worldFrame)
    hook.fastcall(void, o.FN_UPDATE_HIT_TEST, world_frame, 0);

    const x = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_X);
    const y = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Y);
    const z = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Z);

    if (x == 0 and y == 0 and z == 0) return null;

    return .{ .x = x, .y = y, .z = z };
}

// =============================================================================
// Game function wrappers
// =============================================================================

/// CreateEntityInstance_WithAttachment — __fastcall, RET 0x14.
fn createEntityInstance(path: [*:0]const u8, pos: *[3]f32, facing: f32, flags: u32, update_now: u32) ?*anyopaque {
    const facing_bits: u32 = @bitCast(facing);
    const stack_args = [5]u32{
        facing_bits,
        flags,
        update_now,
        0,
        0,
    };

    const result: u32 = asm volatile (
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@intFromPtr(path)),
          [_] "{edx}" (@intFromPtr(pos)),
          [a] "r" (&stack_args),
          [func] "r" (o.FN_CREATE_ENTITY_INSTANCE),
        : .{ .memory = true, .cc = true });

    return if (result != 0) @ptrFromInt(result) else null;
}

/// CleanupEntity_ProcessAttachments — __fastcall(ECX=entity), no stack params.
fn cleanupEntity(obj: *anyopaque) void {
    asm volatile ("call *%[func]"
        :
        : [_] "{ecx}" (@intFromPtr(obj)),
          [func] "r" (o.FN_CLEANUP_ENTITY),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Animation
// =============================================================================

/// Play an animation on an entity's M2 model render context (entity+0x88).
/// CM2Model__PlayBoneAnimation — __thiscall(ECX=model), RET 0x1c.
fn playAnimation(entity: *anyopaque, anim_id: u32, queue: bool) void {
    const model = hook.readMem(u32, @intFromPtr(entity) + 0x88);
    if (model == 0 or model < 0x10000) return;

    const speed_bits: u32 = @bitCast(@as(f32, 1.0));
    const stack_args = [7]u32{
        0xFFFFFFFF, // boneIndex: all bones
        anim_id,
        @bitCast(@as(i32, -1)), // seqIndex: random
        0, // animData: NULL
        speed_bits, // speed: 1.0
        1, // blendMode: blend
        if (queue) @as(u32, 1) else @as(u32, 0),
    };

    asm volatile (
        \\ push 24(%[a])
        \\ push 20(%[a])
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        :
        : [_] "{ecx}" (model),
          [a] "r" (&stack_args),
          [func] "r" (o.FN_PLAY_BONE_ANIMATION),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
}

/// Clean up despawning entities whose Decay animation has finished.
fn cleanupDespawning() void {
    const now = GetTickCount();
    for (&despawning) |*slot| {
        if (slot.*) |d| {
            if (now -% d.start_tick >= DECAY_DURATION_MS) {
                cleanupEntity(d.entity);
                slot.* = null;
            }
        }
    }
}

/// Force-cleanup all despawning entities immediately (for shutdown).
fn forceCleanupDespawning() void {
    for (&despawning) |*slot| {
        if (slot.*) |d| {
            cleanupEntity(d.entity);
            slot.* = null;
        }
    }
}

/// Start despawn animation and defer entity destruction.
fn beginDespawn(entity: *anyopaque) void {
    playAnimation(entity, ANIM_DECAY, false);

    // Find a free despawning slot
    for (&despawning) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .entity = entity, .start_tick = GetTickCount() };
            return;
        }
    }
    // All slots full — force-cleanup the oldest and reuse slot 0
    if (despawning[0]) |old| {
        cleanupEntity(old.entity);
    }
    despawning[0] = .{ .entity = entity, .start_tick = GetTickCount() };
}

// =============================================================================
// Marker management
// =============================================================================

/// Place a marker at the given world position. Replaces any existing marker in that slot.
/// index is 0-based (0..4).
fn placeMarker(index: usize, pos: Vec3) bool {
    if (index >= NUM_MARKERS) return false;

    // Clear existing marker in this slot
    clearMarker(index);

    var position = [3]f32{ pos.x, pos.y, pos.z + MARKER_Z_OFFSET };

    const obj = createEntityInstance(MODEL_PATHS[index], &position, 0.0, 0, 1) orelse {
        con.fmt("[markers] failed to create marker {d}\n", .{index + 1});
        return false;
    };

    // CM2Model_CreateForModelObject already plays Stand (grow-in).
    // Queue Hold (sustained idle) to start after Stand completes.
    playAnimation(obj, ANIM_HOLD, true);

    marker_entities[index] = obj;
    con.fmt("[markers] marker {d} placed at {d:.1}, {d:.1}, {d:.1}\n", .{ index + 1, pos.x, pos.y, pos.z });
    return true;
}

/// Remove a specific marker. index is 0-based.
fn clearMarker(index: usize) void {
    if (index >= NUM_MARKERS) return;
    cleanupDespawning();
    if (marker_entities[index]) |existing| {
        beginDespawn(existing);
        marker_entities[index] = null;
    }
}

/// Remove all markers.
fn clearAllMarkers() void {
    cleanupDespawning();
    var any = false;
    for (0..NUM_MARKERS) |i| {
        if (marker_entities[i]) |existing| {
            beginDespawn(existing);
            marker_entities[i] = null;
            any = true;
        }
    }
    if (any) con.print("[markers] all markers cleared\n");
}

// =============================================================================
// Lua API
// =============================================================================

/// Lua: WorldMarker(index [, x, y, z | "unitId"])
///   WorldMarker(1, x, y, z)  — place at coordinates
///   WorldMarker(1, "target") — place at unit's current position
///   WorldMarker(1)           — place at cursor terrain position
pub fn luaWorldMarker(L: u32) callconv(.c) u32 {
    const nargs = lapi.gettop(L);

    if (nargs < 1 or !lapi.isnumber(L, 1)) {
        con.print("[markers] WorldMarker: expected index (1-5)\n");
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lapi.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        con.print("[markers] WorldMarker: index must be 1-5\n");
        return 0;
    }
    const index: usize = @intCast(raw_index - 1);

    if (nargs >= 4 and lapi.isnumber(L, 2)) {
        // WorldMarker(index, x, y, z)
        const x: f32 = @floatCast(lapi.tonumber(L, 2));
        const y: f32 = @floatCast(lapi.tonumber(L, 3));
        const z: f32 = @floatCast(lapi.tonumber(L, 4));
        _ = placeMarker(index, .{ .x = x, .y = y, .z = z });
    } else if (nargs >= 2 and lapi.isstring(L, 2)) {
        // WorldMarker(index, "unitId")
        const unit_id = lapi.tostring(L, 2) orelse {
            con.print("[markers] WorldMarker: invalid unit string\n");
            return 0;
        };
        const pos = resolveUnitPosition(unit_id) orelse {
            con.fmt("[markers] WorldMarker: unit '{s}' not found\n", .{std.mem.span(unit_id)});
            return 0;
        };
        _ = placeMarker(index, pos);
    } else {
        // WorldMarker(index) — cursor terrain position
        const pos = getCursorTerrainPosition() orelse {
            con.print("[markers] no terrain under cursor\n");
            return 0;
        };
        _ = placeMarker(index, pos);
    }

    return 0;
}

/// Lua: ClearWorldMarker([index])
///   ClearWorldMarker(1) — remove marker 1
///   ClearWorldMarker()  — remove all markers
pub fn luaClearWorldMarker(L: u32) callconv(.c) u32 {
    const nargs = lapi.gettop(L);

    if (nargs == 0) {
        clearAllMarkers();
        return 0;
    }

    if (!lapi.isnumber(L, 1)) {
        con.print("[markers] ClearWorldMarker: expected index (1-5) or no args\n");
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lapi.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        con.print("[markers] ClearWorldMarker: index must be 1-5\n");
        return 0;
    }

    clearMarker(@intCast(raw_index - 1));
    return 0;
}

/// Lua: local x, y, z = GetPlayerPosition()
pub fn luaGetPlayerPosition(L: u32) callconv(.c) u32 {
    const player = wow.getLocalPlayer();
    if (player == 0) return 0;

    const pos = getUnitPosition(player);
    lapi.pushnumber(L, @floatCast(pos.x));
    lapi.pushnumber(L, @floatCast(pos.y));
    lapi.pushnumber(L, @floatCast(pos.z));
    return 3;
}

// =============================================================================
// Install hooks
// =============================================================================

pub fn installHooks() void {
    con.print("[markers] Module loaded\n");

    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\MarkersHook_{d}", .{GetCurrentProcessId()}) catch return;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[markers] Another DLL owns markers (mutex taken), skipping\n");
        return;
    }
    g_is_hook_owner = true;
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // Force-cleanup: no time for animations during shutdown
        for (&marker_entities) |*slot| {
            if (slot.*) |existing| {
                cleanupEntity(existing);
                slot.* = null;
            }
        }
        forceCleanupDespawning();
    }

    if (g_is_hook_owner) {
        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
