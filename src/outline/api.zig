//! Public API for the outline subsystem.
//!
//! Exposes init/cleanup/config functions called from main.zig,
//! and a Lua C callback for `/wu outline` commands.

const hook = @import("hook");
const tracker = @import("tracker.zig");
const model_hook = @import("model_hook.zig");
const d3d9_hook = @import("d3d9_hook.zig");

/// Install model hooks immediately. D3D9 hooks are deferred until the first
/// model hook fires (i.e. the game is actively rendering), because creating a
/// dummy D3D9 device during engine init corrupts the d3d9 proxy's state and
/// causes model rendering to stutter at ~10fps.
pub fn init() bool {
    if (!model_hook.installHooks()) return false;
    return true;
}

/// Called from the first model hook callback, once rendering is active.
/// Safe to create the dummy D3D9 device now — the game's real device is
/// fully initialised and the proxy's state is stable.
pub fn initD3D9Deferred() void {
    _ = d3d9_hook.installHooks();
}

/// Remove all outline hooks. Called during DLL_PROCESS_DETACH.
pub fn cleanup() void {
    d3d9_hook.removeHooks();
    model_hook.removeHooks();
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
pub fn outlineCommand(L: *anyopaque) callconv(.c) u32 {
    const nargs = hook.fastcall(i32, 0x6F3070, @intFromPtr(L), @as(u32, 0)); // lua_gettop

    if (nargs >= 1) {
        // Check if first arg is a string
        const is_str = hook.fastcall(u32, 0x6F3510, @intFromPtr(L), @as(u32, 1)); // lua_isstring
        if (is_str != 0) {
            const str_ptr = hook.fastcall(u32, 0x6F3690, @intFromPtr(L), @as(u32, 1)); // lua_tostring
            if (str_ptr != 0) {
                const s: [*:0]const u8 = @ptrFromInt(str_ptr);
                const span = @import("std").mem.span(s);
                if (eql(span, "on") or eql(span, "enable")) {
                    setEnabled(true);
                } else if (eql(span, "off") or eql(span, "disable")) {
                    setEnabled(false);
                }
            }
        }
    }

    // Push current state as boolean
    hook.fastcall(void, 0x6F39F0, @intFromPtr(L), @as(u32, if (isEnabled()) 1 else 0)); // lua_pushboolean
    return 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
