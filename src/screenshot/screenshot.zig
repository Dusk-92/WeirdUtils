const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");
const png = @import("png.zig");

const WINAPI = std.builtin.CallingConvention.winapi;

// =============================================================================
// Windows API
// =============================================================================

const HANDLE = *anyopaque;

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(WINAPI) void;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(WINAPI) ?HANDLE;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(WINAPI) i32;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(WINAPI) i32;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn ReleaseMutex(hMutex: HANDLE) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

// =============================================================================
// State
// =============================================================================

const tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };

// CVar for compression level persistence (0–9, default 6)
const CVAR_NAME = "screenshotQuality";
const CVAR_LOOKUP: usize = 0x0063DEC0;
const RegisterCVarFn = *const fn ([*:0]const u8, u32, u32, [*:0]const u8, u32, u32, u32, u32) callconv(fc) u32;
const registerCVar: RegisterCVarFn = @ptrFromInt(0x0063DB90);

fn readCVarQuality() i32 {
    const cvar_ptr = hook.fastcall(u32, CVAR_LOOKUP, @intFromPtr(@as([*:0]const u8, CVAR_NAME)), @as(u32, 0));
    if (cvar_ptr == 0) return 6;
    const val = hook.readMem(i32, cvar_ptr + 40);
    return std.math.clamp(val, 0, 9);
}

const TgaWriteFn = fn (u32, u32) callconv(tc) i32;
var tga_hook: hook.Detour(TgaWriteFn) = .{};
var screenshot_dir: [260]u8 = undefined;
var screenshot_dir_len: usize = 0;
var screenshot_counter: u8 = 0;
var last_screenshot_time: u64 = 0; // packed YMDHMS - resets counter on new second

// =============================================================================
// Ring buffer queue (max 8 pending screenshots)
// =============================================================================

const MAX_PENDING = 8;

const PendingScreenshot = struct {
    buffer: [*]u8,
    width: u16,
    height: u16,
    size: u32,
    level: png.Level,
};

var queue: [MAX_PENDING]PendingScreenshot = undefined;
var queue_head: usize = 0;
var queue_tail: usize = 0;
var queue_count: usize = 0;
var mutex: std.atomic.Mutex = .unlocked;
var worker_running: bool = false;
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "pngscreenshots";

var g_mutex: ?HANDLE = null;
var g_is_hook_owner: bool = false;

pub fn isActive() bool {
    return g_is_hook_owner;
}

fn enqueue(shot: PendingScreenshot) bool {
    if (queue_count >= MAX_PENDING) return false;
    queue[queue_tail] = shot;
    queue_tail = (queue_tail + 1) % MAX_PENDING;
    queue_count += 1;
    return true;
}

fn dequeue() ?PendingScreenshot {
    if (queue_count == 0) return null;
    const shot = queue[queue_head];
    queue_head = (queue_head + 1) % MAX_PENDING;
    queue_count -= 1;
    return shot;
}

// =============================================================================
// Directory extraction - capture path prefix from game's first TGA filename
// =============================================================================

fn extractDir(filename_ptr: u32) void {
    const path: [*:0]const u8 = @ptrFromInt(filename_ptr);
    const span = std.mem.span(path);
    var last_sep: usize = 0;
    for (span, 0..) |c, i| {
        if (c == '\\' or c == '/') last_sep = i + 1;
    }
    if (last_sep > 0 and last_sep <= screenshot_dir.len) {
        @memcpy(screenshot_dir[0..last_sep], span[0..last_sep]);
        screenshot_dir_len = last_sep;
    }
}

// =============================================================================
// Call original CTgaFile::Write - __thiscall(self_ECX, filename_stack) ret 4
// =============================================================================

fn callOriginal(self: u32, filename: u32) i32 {
    return tga_hook.callOriginal(.{ self, filename });
}

// =============================================================================
// Detour: CTgaFile::Write at 0x5a4810
// Thunked from __fastcall(self_ECX, _EDX, filename_stack) → cdecl
// =============================================================================

fn tgaWriteDetour(self: u32, filename: u32) callconv(tc) i32 {
    // CVar 0 = disabled, fall through to original TGA write
    const quality = readCVarQuality();
    if (quality == 0) return callOriginal(self, filename);

    // Validate TGA header fields
    const pixel_data = hook.readMem(u32, self + 0x04);
    const additional_header = hook.readMem(u8, self + 0x08);
    const color_map_type = hook.readMem(u8, self + 0x09);
    const image_type = hook.readMem(u8, self + 0x0a);

    if (pixel_data == 0 or filename == 0 or image_type != 2 or additional_header != 0 or color_map_type != 0) {
        return callOriginal(self, filename);
    }

    const width = hook.readMem(u16, self + 0x14);
    const height = hook.readMem(u16, self + 0x16);
    const size: u32 = @as(u32, width) * @as(u32, height) * 3;

    // Capture screenshot directory from the first TGA path we see
    if (screenshot_dir_len == 0) extractDir(filename);

    // Allocate buffer and copy BGR pixel data
    const buffer = std.heap.page_allocator.alloc(u8, size) catch
        return callOriginal(self, filename);
    const src: [*]const u8 = @ptrFromInt(pixel_data);
    @memcpy(buffer, src[0..size]);

    // Enqueue for async processing
    while (!mutex.tryLock()) {}
    defer mutex.unlock();

    if (!enqueue(.{ .buffer = buffer.ptr, .width = width, .height = height, .size = size, .level = png.mapLevel(quality) })) {
        std.heap.page_allocator.free(buffer);
        return callOriginal(self, filename);
    }

    // Spawn worker if not already running
    if (!worker_running) {
        worker_running = true;
        const thread = std.Thread.spawn(.{}, workerThread, .{}) catch {
            worker_running = false;
            return 1;
        };
        thread.detach();
    }

    return 1; // suppress original TGA write
}

// =============================================================================
// Worker thread - dequeues shots, converts BGR→RGB, writes PNG
// =============================================================================

fn workerThread() void {
    while (true) {
        var shot: PendingScreenshot = undefined;
        {
            while (!mutex.tryLock()) {}
            defer mutex.unlock();
            if (dequeue()) |s| {
                shot = s;
            } else {
                worker_running = false;
                return;
            }
        }

        processScreenshot(shot);
    }
}

fn processScreenshot(shot: PendingScreenshot) void {
    defer std.heap.page_allocator.free(shot.buffer[0..shot.size]);

    // BGR → RGB swap
    const total: u32 = @as(u32, shot.width) * @as(u32, shot.height);
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const off = i * 3;
        const tmp = shot.buffer[off];
        shot.buffer[off] = shot.buffer[off + 2];
        shot.buffer[off + 2] = tmp;
    }

    // Generate filename: {dir}WoWScrnShot_MMDDYY_HHMMSS_X.png (X = 0–F hex)
    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);

    // Pack timestamp into a single comparable value - reset counter on new second
    const now: u64 = @as(u64, st.wYear) << 32 | @as(u64, st.wMonth) << 24 |
        @as(u64, st.wDay) << 16 | @as(u64, st.wHour) << 10 |
        @as(u64, st.wMinute) << 4 | @as(u64, st.wSecond);
    if (now != last_screenshot_time) {
        screenshot_counter = 0;
        last_screenshot_time = now;
    }

    const suffix: u8 = if (screenshot_counter < 16) "0123456789ABCDEF"[screenshot_counter] else return;
    screenshot_counter += 1;

    var name_buf: [260]u8 = undefined;
    const name_slice = std.fmt.bufPrint(&name_buf, "{s}WoWScrnShot_{:0>2}{:0>2}{:0>2}_{:0>2}{:0>2}{:0>2}_{c}.png", .{
        screenshot_dir[0..screenshot_dir_len],
        st.wMonth,
        st.wDay,
        st.wYear % @as(u16, 100),
        st.wHour,
        st.wMinute,
        st.wSecond,
        suffix,
    }) catch return;

    // Null-terminate for CreateFileA
    if (name_slice.len >= name_buf.len) return;
    name_buf[name_slice.len] = 0;

    writePng(@ptrCast(name_slice.ptr), shot.buffer, shot.width, shot.height, shot.level);
}

// =============================================================================
// File I/O bridge for png.zig
// =============================================================================

fn writeToFile(handle: HANDLE, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        var written: u32 = 0;
        _ = WriteFile(handle, data[off..].ptr, @intCast(data.len - off), &written, null);
        if (written == 0) return;
        off += written;
    }
}

fn writePng(path: [*:0]const u8, pixels: [*]const u8, width: u16, height: u16, level: png.Level) void {
    const handle = CreateFileA(path, 0x40000000, 0, null, 2, 0x80, null) orelse return;
    defer _ = CloseHandle(handle);
    png.encode(handle, writeToFile, pixels, width, height, level);
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHook() void {
    con.print("[screenshot] Module loaded\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    // Register CVar for compression quality persistence (saved to config.wtf)
    _ = registerCVar(CVAR_NAME, 0, 0, "6", 0, 1, 0, 0);

    // CTgaFile::Write at 0x5a4810
    // __thiscall(self, filename) ret 4
    //
    // Another DLL (UnitXP_SP3) hooks this same address during DLL_PROCESS_ATTACH,
    // replacing the prologue with an E9 JMP. Restore the original prologue first
    // so prepare() builds a trampoline to the real function rather than chaining
    // through UnitXP's detour.
    hook.writeProtected(0x5a4810, &.{ 0x55, 0x8B, 0xEC, 0x83, 0xEC, 0x08 });
    _ = tga_hook.attach(0x5a4810, &tgaWriteDetour);
}

pub fn removeHook() void {
    if (g_is_hook_owner) {
        tga_hook.detach();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
