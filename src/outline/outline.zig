//! Public API for the outline subsystem.
//!
//! Exposes init/cleanup/config functions called from main.zig,
//! and a Lua C callback for `/wu outline` commands.

const std = @import("std");
const lua = @import("../lua.zig");
const logging = @import("../logging.zig");
const tracker = @import("tracker.zig");
const model_hook = @import("model_hook.zig");
const d3d9_hook = @import("d3d9_hook.zig");
const wow = @import("../wow.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "outline";
var log: logging.Logger = .{};

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var g_model_hooks_installed: bool = false;


noinline fn luaGetTopNative(L: lua.State) i32 {
    var result: i32 = undefined;
    asm volatile (
        \\mov $0x6F3070, %%eax
        \\call *%%eax
        : [ret] "={eax}" (result),
        : [state] "{ecx}" (@intFromPtr(L)),
    );
    return result;
}

noinline fn luaIsStringNative(L: lua.State, index: i32) bool {
    var result: u32 = undefined;
    asm volatile (
        \\mov $0x6F3510, %%eax
        \\call *%%eax
        : [ret] "={eax}" (result),
        : [state] "{ecx}" (@intFromPtr(L)),
          [index] "{edx}" (index),
    );
    return result != 0;
}

noinline fn luaToStringNative(L: lua.State, index: i32) ?[*:0]const u8 {
    var result: usize = undefined;
    asm volatile (
        \\mov $0x6F3690, %%eax
        \\call *%%eax
        : [ret] "={eax}" (result),
        : [state] "{ecx}" (@intFromPtr(L)),
          [index] "{edx}" (index),
    );
    return if (result == 0) null else @ptrFromInt(result);
}

noinline fn luaPushBooleanNative(L: lua.State, value: i32) void {
    asm volatile (
        \\mov $0x6F39F0, %%eax
        \\call *%%eax
        :
        : [state] "{ecx}" (@intFromPtr(L)),
          [value] "{edx}" (value),
    );
}

noinline fn luaPushStringNative(L: lua.State, value: [*:0]const u8) void {
    asm volatile (
        \\mov $0x6F3890, %%eax
        \\call *%%eax
        :
        : [state] "{ecx}" (@intFromPtr(L)),
          [value] "{edx}" (@intFromPtr(value)),
    );
}

pub fn isActive() bool {
    return g_is_hook_owner;
}

/// Install model hooks immediately. D3D9 hooks are deferred until the first
/// model hook fires (i.e. the game is actively rendering), because creating a
/// dummy D3D9 device during engine init corrupts the d3d9 proxy's state and
/// causes model rendering to stutter at ~10fps.
pub fn init() bool {

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return true;

    log = logging.Logger.open(module_name, .console);
    tracker.initLogger();
    if (!model_hook.installHooks()) return false;
    g_model_hooks_installed = true;
    return true;
}

/// Called from the first model hook callback, once rendering is active.
/// Safe to create the dummy D3D9 device now - the game's real device is
/// fully initialised and the proxy's state is stable.
pub fn initD3D9Deferred() void {
    _ = d3d9_hook.installHooks();
}

/// Remove all outline hooks. Called during DLL_PROCESS_DETACH.
pub fn cleanup() void {
    if (g_is_hook_owner) {
        d3d9_hook.removeHooks();
        model_hook.removeHooks();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_model_hooks_installed = false;
    g_is_hook_owner = false;
}

/// Enable or disable outline rendering.
pub fn setEnabled(on: bool) void {
    tracker.enabled = on;
}

/// Check if outlines are enabled.
pub fn isEnabled() bool {
    return tracker.enabled;
}

/// Lua C callback for outline commands.
///
/// Usage from Lua:
///   OutlineCommand()          → returns (enabled: bool)
///   OutlineCommand("on")      → enable outlines
///   OutlineCommand("off")     → disable outlines
pub fn outlineCommand(L: lua.State) callconv(.{ .x86_thiscall = .{} }) u32 {
    const nargs = luaGetTopNative(L);

    if (nargs >= 1 and luaIsStringNative(L, 1)) {
        if (luaToStringNative(L, 1)) |s| {
            const span = std.mem.span(s);
            if (eql(span, "on") or eql(span, "enable")) {
                setEnabled(true);
            } else if (eql(span, "off") or eql(span, "disable")) {
                setEnabled(false);
            }
        }
    }

    luaPushBooleanNative(L, if (isEnabled()) 1 else 0);
    return 1;
}

/// Return a compact sticky diagnostic line for in-game testing.
/// Usage:
///   /run DEFAULT_CHAT_FRAME:AddMessage(OutlineDebug())
pub fn outlineDebug(L: lua.State) callconv(.{ .x86_thiscall = .{} }) u32 {
    // Capture player/target from the context where GetGUIDFromName is known to
    // work on this client, then pin the resolved objects for the render thread.
    const player_guid = wow.unitGUID("player");
    const target_guid = wow.unitGUID("target");
    const player_obj = if (player_guid != 0) wow.getObjectByGUID(player_guid) else 0;
    const target_obj = if (target_guid != 0) wow.getObjectByGUID(target_guid) else 0;
    tracker.setDebugPinnedObjects(player_obj, target_obj);

    if (player_guid != 0) tracker.debug_unit_player_guid_seen = true;
    if (target_guid != 0) tracker.debug_unit_target_guid_seen = true;

    _ = d3d9_hook.lateRehookIfLost();
    const live = d3d9_hook.getLiveHookState();

    var buf: [336]u8 = undefined;
    const msg = std.fmt.bufPrintZ(
        &buf,
        "OutlineDBG shst={d} hooks={d}{d}{d} tgt={d} mdl={d} sb={d} rs={d} odip={d} cache={d} pipe={d}/{d}",
        .{
            d3d9_hook.debug_shader_stage,
            @intFromBool(live.endscene_ours),
            @intFromBool(live.dip_ours),
            @intFromBool(live.reset_ours),
            @intFromBool(tracker.debug_target_seen),
            @intFromBool(tracker.debug_target_model_seen),
            @intFromBool(d3d9_hook.debug_state_block_seen),
            @intFromBool(d3d9_hook.debug_outer_state_restore_seen),
            @intFromBool(d3d9_hook.debug_outline_dip_seen),
            @intFromBool(d3d9_hook.debug_cached_draw_seen),
            @intFromBool(d3d9_hook.debug_pipeline_entered_seen),
            @intFromBool(d3d9_hook.debug_pipeline_ready_seen),
        },
    ) catch {
        luaPushStringNative(L, "OutlineDBG format error");
        return 1;
    };

    luaPushStringNative(L, msg.ptr);
    return 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
