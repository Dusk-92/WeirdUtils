//! Debug logging - compiles out entirely in non-Debug builds.
//!
//! Per-module Logger with optional file output and per-call destination routing.
//! Log files are created lazily on first write -- modules that never log to
//! file produce no `.log` file.
//!
//!   const logging = @import("../logging.zig");
//!   var log: logging.Logger = .{};
//!
//!   // In installHooks:
//!   log = logging.Logger.open("mymodule", .console);  // console only (file created on demand)
//!   log = logging.Logger.open("mymodule", .both);      // console + file by default
//!   log = logging.Logger.open(null, .console);          // no file at all
//!
//!   // Default destination (auto-prefixed with [mymodule]):
//!   log.print("loaded\n");                              // -> [mymodule] loaded
//!   log.fmt("val={d}\n", .{v});                         // -> [mymodule] val=42
//!
//!   // Override for specific calls:
//!   log.to(.file).fmt("noisy={d}\n", .{n});             // file only
//!   log.to(.both).print("important event\n");           // console + file
//!   log.to(.console).print("console only\n");           // console only
//!
//! Global console-only convenience (no auto-prefix):
//!   logging.print("[addons] loaded\n");
//!   logging.fmt("[addons] count={d}\n", .{n});

const std = @import("std");
const builtin = @import("builtin");

const debug = builtin.mode == .Debug;

const WINAPI = std.builtin.CallingConvention.winapi;

const win = if (debug) struct {
    extern "kernel32" fn AllocConsole() callconv(WINAPI) i32;
    extern "kernel32" fn FreeConsole() callconv(WINAPI) i32;
    extern "kernel32" fn SetConsoleTitleA(title: [*:0]const u8) callconv(WINAPI) i32;
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(WINAPI) ?*anyopaque;
    extern "kernel32" fn WriteConsoleA(
        hOut: *anyopaque,
        buf: [*]const u8,
        len: u32,
        written: ?*u32,
        reserved: ?*anyopaque,
    ) callconv(WINAPI) i32;
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(WINAPI) ?*anyopaque;
    extern "kernel32" fn WriteFile(
        hFile: *anyopaque,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(WINAPI) i32;
    extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;

    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_READ: u32 = 0x00000001;
    const CREATE_ALWAYS: u32 = 2;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    var console_handle: ?*anyopaque = null;
} else void;

// =============================================================================
// Console management (called from main.zig install/uninstall)
// =============================================================================

pub fn init() void {
    if (debug) {
        _ = win.AllocConsole();
        _ = win.SetConsoleTitleA("weirdutils");
        win.console_handle = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        print("[weirdutils] Console attached\n");
    }
}

pub fn deinit() void {
    if (debug) {
        if (win.console_handle != null) {
            print("[weirdutils] Detaching\n");
            _ = win.FreeConsole();
            win.console_handle = null;
        }
    }
}

// =============================================================================
// Output destination
// =============================================================================

pub const Output = enum { console, file, both };

// =============================================================================
// Logger
// =============================================================================

pub const Logger = struct {
    file_handle: if (debug) ?*anyopaque else void = if (debug) null else {},
    default_dest: if (debug) Output else void = if (debug) .console else {},
    /// Module name for lazy file creation. Null = no file output.
    file_name: if (debug) ?[*:0]const u8 else void = if (debug) null else {},
    /// Auto-prefix: "[name] " prepended to every log line.
    prefix: if (debug) [32]u8 else void = if (debug) .{0} ** 32 else {},
    prefix_len: if (debug) u8 else void = if (debug) 0 else {},

    /// Open a logger with optional file output. File is created lazily on
    /// first write, so modules that never log to file produce no `.log` file.
    /// Pass null for no file (console-only even when dest is .both/.file).
    pub fn open(module_name: ?[*:0]const u8, default: Output) Logger {
        if (debug) {
            var l: Logger = .{ .default_dest = default, .file_name = module_name };
            if (module_name) |name| {
                const span = std.mem.span(name);
                if (span.len + 3 <= l.prefix.len) {
                    l.prefix[0] = '[';
                    @memcpy(l.prefix[1..][0..span.len], span);
                    l.prefix[1 + span.len] = ']';
                    l.prefix[2 + span.len] = ' ';
                    l.prefix_len = @intCast(3 + span.len);
                }
            }
            return l;
        }
        return .{};
    }

    pub fn close(self: *Logger) void {
        if (debug) {
            if (self.file_handle) |h| {
                _ = win.CloseHandle(h);
                self.file_handle = null;
            }
        }
    }

    /// Print using the default destination.
    pub fn print(self: *Logger, msg: []const u8) void {
        if (debug) self.dispatch(self.default_dest, msg);
    }

    /// Format and print using the default destination.
    pub fn fmt(self: *Logger, comptime f: []const u8, args: anytype) void {
        if (debug) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, f, args) catch return;
            self.dispatch(self.default_dest, msg);
        }
    }

    /// Override the destination for a single call.
    pub fn to(self: *Logger, dest: Output) Writer {
        return .{ .logger = self, .dest = dest };
    }

    pub const Writer = struct {
        logger: *Logger,
        dest: Output,

        pub fn print(self: Writer, msg: []const u8) void {
            if (debug) self.logger.dispatch(self.dest, msg);
        }

        pub fn fmt(self: Writer, comptime f: []const u8, args: anytype) void {
            if (debug) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, f, args) catch return;
                self.logger.dispatch(self.dest, msg);
            }
        }
    };

    fn dispatch(self: *Logger, dest: Output, msg: []const u8) void {
        const pfx = self.prefix[0..self.prefix_len];
        switch (dest) {
            .console => {
                if (pfx.len > 0) writeConsole(pfx);
                writeConsole(msg);
            },
            .file => {
                if (pfx.len > 0) self.writeFile(pfx);
                self.writeFile(msg);
            },
            .both => {
                if (pfx.len > 0) {
                    writeConsole(pfx);
                    self.writeFile(pfx);
                }
                writeConsole(msg);
                self.writeFile(msg);
            },
        }
    }

    fn writeFile(self: *Logger, msg: []const u8) void {
        const h = self.ensureFileOpen() orelse return;
        _ = win.WriteFile(h, msg.ptr, @intCast(msg.len), null, null);
    }

    /// Lazily create the log file on first write.
    fn ensureFileOpen(self: *Logger) ?*anyopaque {
        if (self.file_handle) |h| return h;
        const name = self.file_name orelse return null;
        const span = std.mem.span(name);
        var buf: [64]u8 = undefined;
        if (span.len + 4 >= buf.len) return null;
        @memcpy(buf[0..span.len], span);
        @memcpy(buf[span.len..][0..4], ".log");
        buf[span.len + 4] = 0;
        const fh = win.CreateFileA(
            @ptrCast(buf[0 .. span.len + 4 :0]),
            win.GENERIC_WRITE,
            win.FILE_SHARE_READ,
            null,
            win.CREATE_ALWAYS,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (fh) |h| {
            if (@intFromPtr(h) != 0xFFFFFFFF) {
                self.file_handle = h;
                return h;
            }
        }
        return null;
    }
};

// =============================================================================
// Global console-only convenience (for utility files and main.zig)
// =============================================================================

pub fn print(msg: []const u8) void {
    if (debug) writeConsole(msg);
}

pub fn fmt(comptime f: []const u8, args: anytype) void {
    if (debug) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, f, args) catch return;
        writeConsole(msg);
    }
}

fn writeConsole(msg: []const u8) void {
    if (win.console_handle) |h| {
        _ = win.WriteConsoleA(h, msg.ptr, @intCast(msg.len), null, null);
    }
}
