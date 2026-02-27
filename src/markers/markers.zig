//! Client-side marker system
//!
//! Creates world objects at arbitrary positions for raid markers,
//! player indicators, etc.
//!
//! Uses CreateEntityInstance_WithAttachment (0x6707c0) — the game's
//! native high-level entity creation API. For M2 models, this routes
//! through CreateWorldUnit which handles all spatial registration,
//! render setup, and lifecycle management.

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
// Game function wrappers
// =============================================================================

/// CreateEntityInstance_WithAttachment — __fastcall, RET 0x14.
/// ECX=modelPath, EDX=positionVec3ptr, stack: facing, flags, updateNow, param6, param7.
/// Routes M2 models through CreateWorldUnit, WMO models through CreateGameObject.
/// Returns a fully-registered game entity pointer.
fn createEntityInstance(path: [*:0]const u8, pos: *[3]f32, facing: f32, flags: u32, update_now: u32) ?*anyopaque {
    const facing_bits: u32 = @bitCast(facing);
    const stack_args = [5]u32{
        facing_bits, // param_3: facing angle
        flags, // param_4: flags/type
        update_now, // param_5: update position immediately (1=yes)
        0, // param_6
        0, // param_7
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
        : .{ .memory = true, .cc = true }
    );

    return if (result != 0) @ptrFromInt(result) else null;
}

/// DestroyWorldObjectAndRelease — __fastcall(ECX=obj), tail JMP.
fn destroyWorldObject(obj: *anyopaque) void {
    asm volatile ("call *%[func]"
        :
        : [_] "{ecx}" (@intFromPtr(obj)),
          [func] "r" (o.FN_DESTROY_WORLD_OBJECT),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// Marker management
// =============================================================================

var test_marker: ?*anyopaque = null;

const MODEL_PATH: [*:0]const u8 = "Spells\\ErrorCube.mdx";

/// Create a test marker at player position using the native entity creation API.
pub fn createTestMarker() ?*anyopaque {
    if (test_marker != null) {
        con.print("[markers] marker already exists, destroy first\n");
        return test_marker;
    }

    const player = wow.getLocalPlayer();
    if (player == 0) {
        con.print("[markers] no local player\n");
        return null;
    }

    const pos = getUnitPosition(player);
    con.fmt("[markers] player pos = {d:.1}, {d:.1}, {d:.1}\n", .{ pos.x, pos.y, pos.z });
    if (pos.x == 0 and pos.y == 0 and pos.z == 0) return null;

    var position = [3]f32{ pos.x, pos.y, pos.z + 2.0 };

    con.print("[markers] calling CreateEntityInstance_WithAttachment...\n");
    const obj = createEntityInstance(MODEL_PATH, &position, 0.0, 0, 1) orelse {
        con.print("[markers] CreateEntityInstance_WithAttachment FAILED\n");
        return null;
    };

    const obj_ptr: u32 = @intCast(@intFromPtr(obj));
    con.fmt("[markers] entity created at 0x{X:0>8}\n", .{obj_ptr});

    // Debug dump key fields
    const refcount = hook.readMem(u16, obj_ptr + 0xE);
    const flags_90 = hook.readMem(u32, obj_ptr + 0x90);
    const model_88 = hook.readMem(u32, obj_ptr + 0x88);
    const pos_x = hook.readMem(f32, obj_ptr + 0x5C);
    const pos_y = hook.readMem(f32, obj_ptr + 0x60);
    const pos_z = hook.readMem(f32, obj_ptr + 0x64);
    con.fmt("[markers] refcount={d} flags90=0x{X:0>8} model88=0x{X:0>8}\n", .{ refcount, flags_90, model_88 });
    con.fmt("[markers] bsph(+5C)={d:.1},{d:.1},{d:.1}\n", .{ pos_x, pos_y, pos_z });

    test_marker = obj;
    return obj;
}

/// Destroy the test marker. Safe to call multiple times.
pub fn destroyTestMarker() void {
    const marker = test_marker orelse return;
    test_marker = null;

    con.print("[markers] destroying marker...\n");
    destroyWorldObject(marker);
    con.print("[markers] marker destroyed\n");
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
    // Nothing to hook - markers are created via Lua commands
}

pub fn removeHooks() void {
    destroyTestMarker();
}
