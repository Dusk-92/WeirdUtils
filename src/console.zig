//! Debug console — compiles out entirely in non-Debug builds.
//!
//! Usage from any module:
//!   const con = @import("../console.zig");   // or appropriate relative path
//!   con.print("[markers] loaded\n");
//!   con.fmt("[markers] pos = {d}, {d}, {d}\n", .{ x, y, z });

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

    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
    var handle: ?*anyopaque = null;
} else void;

pub fn init() void {
    if (debug) {
        _ = win.AllocConsole();
        _ = win.SetConsoleTitleA("weirdutils");
        win.handle = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        print("[weirdutils] Console attached\n");
    }
}

pub fn deinit() void {
    if (debug) {
        if (win.handle != null) {
            print("[weirdutils] Detaching\n");
            _ = win.FreeConsole();
            win.handle = null;
        }
    }
}

pub fn print(msg: []const u8) void {
    if (debug) {
        if (win.handle) |h| {
            _ = win.WriteConsoleA(h, msg.ptr, @intCast(msg.len), null, null);
        }
    }
}

pub fn fmt(comptime f: []const u8, args: anytype) void {
    if (debug) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, f, args) catch return;
        print(msg);
    }
}
