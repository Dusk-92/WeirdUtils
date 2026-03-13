// Runtime registry for module isActive() function pointers.
// Populated by main.zig during install(), queried by addons.zig during login.
// Exists solely to avoid duplicating module imports in addons.zig.

const std = @import("std");

const MAX = 32;
var names: [MAX][*:0]const u8 = undefined;
var fns: [MAX]*const fn () bool = undefined;
var count: usize = 0;

/// Register a module's isActive function. Called from main.zig install().
pub fn register(name: [*:0]const u8, f: *const fn () bool) void {
    if (count >= MAX) return;
    names[count] = name;
    fns[count] = f;
    count += 1;
}

/// Check if a module is active by name. Returns true if unknown (no isActive).
pub fn isActive(name: [*:0]const u8) bool {
    for (0..count) |i| {
        if (std.mem.orderZ(u8, names[i], name) == .eq) return fns[i]();
    }
    return true;
}
