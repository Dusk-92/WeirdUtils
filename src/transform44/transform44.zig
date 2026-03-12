//! transform44 — hook for transformMatrix4x4 (0x714260)
//!
//! transformMatrix4x4 is the main per-frame bone transform engine for M2 models.
//! 17703 bytes, processes bone entries (0x118 bytes each, array at model+0x90).

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "transform44";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
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
    log.print("transform44 module loaded\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
