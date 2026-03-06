//! DPS log module.
//!
//! Provides structured Lua objects for combat log events so addons can read
//! parsed fields directly instead of re-parsing the combat log string.
//!
//! TODO: Hook combat log event dispatch, build Lua tables per event type.

const con = @import("../console.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "dpslog";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    con.print("[dpslog] Module loaded (stub)\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
