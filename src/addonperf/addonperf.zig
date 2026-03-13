//! addonperf — Expose addon memory and CPU usage to Lua.
//!
//! Vanilla WoW (1.12.1) lacks the TBC+ addon profiling API:
//!   GetAddOnMemoryUsage(index|name) -> kB
//!   UpdateAddOnMemoryUsage()
//!   GetAddOnCPUUsage(index|name) -> ms
//!   UpdateAddOnCPUUsage()
//!   ResetAddOnCPUUsage(index|name)
//!   GetScriptCPUUsage() -> enabled
//!
//! This module hooks the Lua engine to track per-addon memory and CPU,
//! then registers these functions so addons like !Swatter / Blizzard_DebugTools
//! can query performance data.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "addonperf";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Lua API stubs
// =============================================================================

/// GetAddOnMemoryUsage(index|"name") -> kB (float)
/// Returns memory used by the specified addon in kilobytes.
pub fn luaGetAddOnMemoryUsage(L: *anyopaque) callconv(.c) u32 {
    // TODO: track per-addon Lua memory via lua_gc / allocator hooks
    _ = L;
    return 0; // pushes nothing — returns 0 results
}

/// UpdateAddOnMemoryUsage()
/// Triggers a memory usage snapshot for all addons.
pub fn luaUpdateAddOnMemoryUsage(L: *anyopaque) callconv(.c) u32 {
    _ = L;
    return 0;
}

/// GetAddOnCPUUsage(index|"name") -> totalMs, recentMs
/// Returns total and recent CPU time for the specified addon.
pub fn luaGetAddOnCPUUsage(L: *anyopaque) callconv(.c) u32 {
    // TODO: hook FrameScript dispatch to measure per-addon handler time
    _ = L;
    return 0;
}

/// UpdateAddOnCPUUsage()
/// Triggers a CPU usage snapshot for all addons.
pub fn luaUpdateAddOnCPUUsage(L: *anyopaque) callconv(.c) u32 {
    _ = L;
    return 0;
}

/// ResetAddOnCPUUsage(index|"name")
/// Resets CPU counters for the specified addon (or all if no arg).
pub fn luaResetAddOnCPUUsage(L: *anyopaque) callconv(.c) u32 {
    _ = L;
    return 0;
}

/// GetScriptCPUUsage() -> enabled (1/nil)
/// Returns whether CPU profiling is active.
pub fn luaGetScriptCPUUsage(L: *anyopaque) callconv(.c) u32 {
    const L_ptr = @intFromPtr(L);
    // Always enabled when this module is loaded
    hook.call(fn (usize, i32) callconv(hook.cc.fastcall) void, 0x6F36B0, .{ L_ptr, @as(i32, 1) }); // lua_pushboolean
    return 1;
}

// =============================================================================
// Install / remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    log.print("addonperf: stub module loaded\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
