//! Client-side marker system using CreateGameObject_WithProperties
//!
//! Creates world objects at arbitrary positions for raid markers,
//! player indicators, etc.

const hook = @import("hook");
const o = @import("offsets.zig");
const wow = @import("../outline/wow.zig");
const con = @import("../console.zig");

// =============================================================================
// Position helpers
// =============================================================================

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

/// Get unit position from movement struct
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
// GameObject creation - function pointer wrappers
// =============================================================================

/// CreateGameObject_WithProperties — __fastcall:
///   ECX = model, EDX = callback1
///   Stack (callee-clean, RET 0x14): callback2, x, y, z, flags
pub fn createGameObject(
    model: ?*anyopaque,
    callback1: ?*anyopaque,
    callback2: ?*anyopaque,
    x: f32,
    y: f32,
    z: f32,
    flags: u32,
) ?*anyopaque {
    // 5 stack params (callee cleans via RET 0x14)
    const stack_args = [5]u32{
        if (callback2) |c| @intCast(@intFromPtr(c)) else 0,
        @as(u32, @bitCast(x)),
        @as(u32, @bitCast(y)),
        @as(u32, @bitCast(z)),
        flags,
    };

    const result: u32 = asm volatile (
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (if (model) |m| @intFromPtr(m) else @as(usize, 0)),
          [_] "{edx}" (if (callback1) |c| @intFromPtr(c) else @as(usize, 0)),
          [a] "r" (&stack_args),
          [func] "r" (o.FN_CREATE_GAMEOBJECT),
        : .{ .memory = true, .cc = true }
    );

    return if (result != 0) @ptrFromInt(result) else null;
}

/// CleanupWorldObject(obj) - __thiscall: ECX = obj, 0 stack params
pub fn cleanupWorldObject(obj: *anyopaque) void {
    asm volatile ("call *%[func]"
        :
        : [_] "{ecx}" (@intFromPtr(obj)),
          [func] "r" (o.FN_CLEANUP_WORLD_OBJECT),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

/// Update object position directly
pub fn setObjectPosition(obj: *anyopaque, pos: Vec3) void {
    const ptr: u32 = @intCast(@intFromPtr(obj));
    @as(*f32, @ptrFromInt(ptr + o.OBJ_POS_X)).* = pos.x;
    @as(*f32, @ptrFromInt(ptr + o.OBJ_POS_Y)).* = pos.y;
    @as(*f32, @ptrFromInt(ptr + o.OBJ_POS_Z)).* = pos.z;
}

/// Set object alpha (0-255)
pub fn setObjectAlpha(obj: *anyopaque, alpha: u8) void {
    const ptr: u32 = @intCast(@intFromPtr(obj));
    // ARGB format - alpha in high byte
    const color: u32 = (@as(u32, alpha) << 24) | 0x00189680;
    @as(*u32, @ptrFromInt(ptr + o.OBJ_COLOR)).* = color;
}

// =============================================================================
// Animation
// =============================================================================

/// PlayAnimation(obj, animId) - __thiscall: ECX = obj, 1 stack param (callee-clean, RET 4)
pub fn playAnimation(obj: *anyopaque, anim_id: u32) void {
    asm volatile (
        \\push %[anim]
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(obj)),
          [anim] "r" (anim_id),
          [func] "r" (o.FN_PLAY_ANIMATION),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// Marker management
// =============================================================================

var test_marker: ?*anyopaque = null;

const MODEL_PATH: [*:0]const u8 = "World\\ArtTest\\Boxtest\\xyz.m2";

/// loadModelByName — __fastcall(ECX=path), returns model cache entry or null.
fn loadModel(path: [*:0]const u8) ?*anyopaque {
    con.fmt("[markers] loadModelByName(\"{s}\")\n", .{@as([*:0]const u8, path)});
    const result: u32 = asm volatile ("call *%[func]"
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@intFromPtr(path)),
          [func] "r" (o.FN_LOAD_MODEL_BY_NAME),
        : .{ .edx = true, .memory = true, .cc = true }
    );
    if (result != 0) {
        con.fmt("[markers]   -> model at 0x{X:0>8}\n", .{result});
    } else {
        con.print("[markers]   -> FAILED (returned null)\n");
    }
    return if (result != 0) @ptrFromInt(result) else null;
}

/// Create a test marker at player position
pub fn createTestMarker() ?*anyopaque {
    const player = wow.getLocalPlayer();
    if (player == 0) {
        con.print("[markers] createTestMarker: no local player\n");
        return null;
    }

    const pos = getUnitPosition(player);
    con.fmt("[markers] player pos = {d:.1}, {d:.1}, {d:.1}\n", .{ pos.x, pos.y, pos.z });
    if (pos.x == 0 and pos.y == 0 and pos.z == 0) return null;

    const model = loadModel(MODEL_PATH);
    con.fmt("[markers] createGameObject(model={?}, pos=({d:.1},{d:.1},{d:.1}))\n", .{
        @as(?usize, if (model) |m| @intFromPtr(m) else null),
        pos.x, pos.y, pos.z + 1.0,
    });
    const marker = createGameObject(model, null, null, pos.x, pos.y, pos.z + 1.0, 0);

    if (marker) |m| {
        con.fmt("[markers]   -> object at 0x{X:0>8}\n", .{@intFromPtr(m)});
        test_marker = m;
    } else {
        con.print("[markers]   -> createGameObject FAILED\n");
    }

    return marker;
}

/// Destroy test marker
pub fn destroyTestMarker() void {
    if (test_marker) |m| {
        cleanupWorldObject(m);
        test_marker = null;
    }
}

/// Update test marker position to follow player
pub fn updateTestMarker() void {
    if (test_marker == null) return;

    const player = wow.getLocalPlayer();
    if (player == 0) return;

    const pos = getUnitPosition(player);
    if (pos.x == 0 and pos.y == 0 and pos.z == 0) return;

    setObjectPosition(test_marker.?, .{ .x = pos.x, .y = pos.y, .z = pos.z + 1.0 });
}

// =============================================================================
// Lua helpers
// =============================================================================

/// lua_pushnumber at 0x6F3810: __fastcall(L_ECX, double_on_stack). Callee cleans (RET 8).
fn luaPushNumber(L: u32, n: f64) void {
    const raw: [2]u32 = @bitCast(n);
    asm volatile (
        \\push %[hi]
        \\push %[lo]
        \\call *%[func]
        :
        : [_] "{ecx}" (L),
          [lo] "r" (raw[0]),
          [hi] "r" (raw[1]),
          [func] "r" (@as(u32, 0x6F3810)),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// Lua API
// =============================================================================

/// Lua: TestMarkerCreate() - create marker at player position
pub fn luaTestMarkerCreate(L: u32) callconv(.c) u32 {
    if (createTestMarker()) |_| {
        hook.fastcall(void, 0x6F3890, L, @intFromPtr(@as([*:0]const u8, "Marker created")));
    } else {
        hook.fastcall(void, 0x6F3890, L, @intFromPtr(@as([*:0]const u8, "Failed to create marker")));
    }
    return 1;
}

/// Lua: TestMarkerDestroy() - destroy test marker
pub fn luaTestMarkerDestroy(L: u32) callconv(.c) u32 {
    destroyTestMarker();
    hook.fastcall(void, 0x6F3890, L, @intFromPtr(@as([*:0]const u8, "Marker destroyed")));
    return 1;
}

/// Lua: TestMarkerToggle() - toggle marker on/off
pub fn luaTestMarkerToggle(L: u32) callconv(.c) u32 {
    if (test_marker != null) {
        destroyTestMarker();
        hook.fastcall(void, 0x6F3890, L, @intFromPtr(@as([*:0]const u8, "Marker off")));
    } else {
        _ = createTestMarker();
        hook.fastcall(void, 0x6F3890, L, @intFromPtr(@as([*:0]const u8, "Marker on")));
    }
    return 1;
}

/// Lua: local x, y, z = GetPlayerPosition()
pub fn luaGetPlayerPosition(L: u32) callconv(.c) u32 {
    const player = wow.getLocalPlayer();
    if (player == 0) return 0;

    const pos = getUnitPosition(player);
    luaPushNumber(L, @floatCast(pos.x));
    luaPushNumber(L, @floatCast(pos.y));
    luaPushNumber(L, @floatCast(pos.z));
    return 3;
}

// =============================================================================
// Install hooks
// =============================================================================

pub fn installHooks() void {
    // Nothing to hook yet - markers are created via Lua commands
}

pub fn removeHooks() void {
    destroyTestMarker();
}
