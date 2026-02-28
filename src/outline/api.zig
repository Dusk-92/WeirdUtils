//! Public API for the outline subsystem.
//!
//! Exposes init/cleanup/config functions called from main.zig,
//! and a Lua C callback for `/wu outline` commands.

const std = @import("std");
const hook = @import("hook");
const con = @import("../console.zig");
const tracker = @import("tracker.zig");
const model_hook = @import("model_hook.zig");
const d3d9_hook = @import("d3d9_hook.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

/// Install model hooks immediately. D3D9 hooks are deferred until the first
/// model hook fires (i.e. the game is actively rendering), because creating a
/// dummy D3D9 device during engine init corrupts the d3d9 proxy's state and
/// causes model rendering to stutter at ~10fps.
pub fn init() bool {
    con.print("[outline] Module loaded\n");

    // Multi-DLL safety: only one instance per process should hook
    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\OutlineHook_{d}", .{GetCurrentProcessId()}) catch return false;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return false;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[outline] Another DLL owns hooks (mutex taken), skipping\n");
        return true;
    }
    g_is_hook_owner = true;

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
    if (g_is_hook_owner) {
        d3d9_hook.removeHooks();
        model_hook.removeHooks();
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
