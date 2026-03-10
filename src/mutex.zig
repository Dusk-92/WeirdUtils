const std = @import("std");
const con = @import("logging.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: ?[*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;

const ERROR_ALREADY_EXISTS: u32 = 183;

pub const Result = struct {
    handle: ?*anyopaque,
    is_owner: bool,
};

/// Try to acquire the per-process module mutex.
/// Format: `Local\WeirdUtils_<module_name>_<PID>`
pub fn acquire(module_name: [*:0]const u8) Result {
    var buf: [80]u8 = undefined;
    const name_span = std.mem.span(module_name);
    const formatted = std.fmt.bufPrint(&buf, "Local\\WeirdUtils_{s}_{d}", .{ name_span, GetCurrentProcessId() }) catch return .{ .handle = null, .is_owner = false };
    return doAcquire(&buf, formatted.len, name_span);
}

/// Acquire with a legacy mutex name format: `Local\<legacy_prefix>_<PID>`
/// Used by transmogfix which shipped before the naming convention was established.
pub fn acquireLegacy(legacy_prefix: [*:0]const u8, module_name: [*:0]const u8) Result {
    var buf: [80]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "Local\\{s}_{d}", .{ std.mem.span(legacy_prefix), GetCurrentProcessId() }) catch return .{ .handle = null, .is_owner = false };
    return doAcquire(&buf, formatted.len, std.mem.span(module_name));
}

fn doAcquire(buf: *[80]u8, len: usize, log_name: []const u8) Result {
    buf[len] = 0;

    const mutex = CreateMutexA(null, 1, @ptrCast(buf[0..len :0]));
    if (mutex == null) return .{ .handle = null, .is_owner = false };

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(mutex.?);
        con.fmt("[{s}] Another DLL owns hooks (mutex taken), skipping\n", .{log_name});
        return .{ .handle = null, .is_owner = false };
    }

    return .{ .handle = mutex, .is_owner = true };
}

/// Release and close a module mutex.
pub fn release(mutex: *?*anyopaque) void {
    if (mutex.*) |m| {
        _ = ReleaseMutex(m);
        _ = CloseHandle(m);
        mutex.* = null;
    }
}
