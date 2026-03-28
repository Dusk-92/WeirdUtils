//! timer_fix -- TSC calibration + OS timer tweaks (ported from VanillaFixes)
//!
//! The vanilla client poorly calibrates its RDTSC frequency, causing animation
//! stutter. We recalibrate using QueryPerformanceFrequency as reference and
//! patch the game's timer globals. A/B tested: BASELINE restores original
//! values, CUSTOM applies calibrated values.
//!
//! Timer globals (1.12.1 build 5875):
//!   pUseTSC:              0x00884c80 (BOOL)
//!   pTimerTicksPerSecond:  0x008332c0 (u64)
//!   pTimerToMilliseconds:  0x008332c8 (f64)
//!   pTimerOffset:          0x00884c88 (f64)

const hook = @import("zhook");

const ADDR_USE_TSC: usize = 0x00884c80;
const ADDR_TICKS_PER_SEC: usize = 0x008332c0;
const ADDR_TO_MS: usize = 0x008332c8;
const ADDR_OFFSET: usize = 0x00884c88;

const WINAPI = @import("std").builtin.CallingConvention.winapi;
const LARGE_INTEGER = extern struct { QuadPart: i64 };

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *LARGE_INTEGER) callconv(WINAPI) i32;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *LARGE_INTEGER) callconv(WINAPI) i32;
extern "kernel32" fn GetTickCount() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentThread() callconv(WINAPI) usize;
extern "kernel32" fn SetThreadPriority(hThread: usize, nPriority: i32) callconv(WINAPI) i32;
extern "kernel32" fn GetCurrentProcessorNumber() callconv(WINAPI) u32;
extern "kernel32" fn SetThreadAffinityMask(hThread: usize, dwThreadAffinityMask: usize) callconv(WINAPI) usize;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(WINAPI) void;

// Windows API for OS timer tweaks
extern "kernel32" fn GetModuleHandleA(lpModuleName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetCurrentProcess() callconv(WINAPI) usize;

fn increaseTimerResolution() void {
    const ntdll = GetModuleHandleA("ntdll") orelse return;

    const NtQueryFn = *const fn (*u32, *u32, *u32) callconv(WINAPI) i32;
    const NtSetFn = *const fn (u32, i32, *u32) callconv(WINAPI) i32;

    const query_ptr = GetProcAddress(ntdll, "NtQueryTimerResolution");
    const set_ptr = GetProcAddress(ntdll, "NtSetTimerResolution");

    if (query_ptr != null and set_ptr != null) {
        const query: NtQueryFn = @ptrCast(query_ptr.?);
        const set: NtSetFn = @ptrCast(set_ptr.?);

        var min_res: u32 = 0;
        var max_res: u32 = 0;
        var cur_res: u32 = 0;
        _ = query(&min_res, &max_res, &cur_res);

        // Request 0.5ms (5000 * 100ns) or hardware max, whichever is larger
        const desired = @max(max_res, 5000);
        var actual: u32 = 0;
        _ = set(desired, 1, &actual); // 1 = TRUE (enable)
        return;
    }

    // Fallback: timeBeginPeriod(1) via winmm
    const winmm = GetModuleHandleA("winmm") orelse return;
    const TbpFn = *const fn (u32) callconv(WINAPI) u32;
    const tbp_ptr = GetProcAddress(winmm, "timeBeginPeriod") orelse return;
    const tbp: TbpFn = @ptrCast(tbp_ptr);
    _ = tbp(1);
}

fn disablePowerThrottling() void {
    const kernel32 = GetModuleHandleA("kernel32") orelse return;
    const SpiPtr = GetProcAddress(kernel32, "SetProcessInformation") orelse return;

    // ProcessPowerThrottling = 4
    const PowerThrottlingState = extern struct {
        Version: u32,
        ControlMask: u32,
        StateMask: u32,
    };
    const SetProcessInfoFn = *const fn (usize, u32, *PowerThrottlingState, u32) callconv(WINAPI) i32;
    const setProcessInfo: SetProcessInfoFn = @ptrCast(SpiPtr);
    const process = GetCurrentProcess();

    // PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = 2
    var state1 = PowerThrottlingState{ .Version = 1, .ControlMask = 2, .StateMask = 0 };
    _ = setProcessInfo(process, 4, &state1, @sizeOf(PowerThrottlingState));

    // PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 1
    var state2 = PowerThrottlingState{ .Version = 1, .ControlMask = 1, .StateMask = 0 };
    _ = setProcessInfo(process, 4, &state2, @sizeOf(PowerThrottlingState));
}

// Saved original values (before calibration) for A/B testing
var orig_ticks_per_sec: u64 = 0;
var orig_to_ms: f64 = 0;
var orig_offset: f64 = 0;

// Calibrated values
var cal_ticks_per_sec: u64 = 0;
var cal_to_ms: f64 = 0;
var cal_offset: f64 = 0;

var is_calibrated: bool = false;

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

fn timeSample() struct { qpc: i64, tsc: u64 } {
    Sleep(0); // yield to get fresh timeslice
    var qpc: LARGE_INTEGER = .{ .QuadPart = 0 };
    _ = QueryPerformanceCounter(&qpc);
    const tsc = rdtsc();
    asm volatile ("lfence" ::: "memory");
    return .{ .qpc = qpc.QuadPart, .tsc = tsc };
}

fn calibrateTSC() u64 {
    const thread = GetCurrentThread();
    _ = SetThreadPriority(thread, 2); // THREAD_PRIORITY_HIGHEST
    const core: u5 = @truncate(GetCurrentProcessorNumber());
    _ = SetThreadAffinityMask(thread, @as(usize, 1) << core);

    const baseline = timeSample();
    Sleep(500);
    const after = timeSample();

    _ = SetThreadPriority(thread, 0); // THREAD_PRIORITY_NORMAL
    _ = SetThreadAffinityMask(thread, 0); // all cores

    var freq: LARGE_INTEGER = .{ .QuadPart = 0 };
    _ = QueryPerformanceFrequency(&freq);

    const qpc_delta: f64 = @floatFromInt(after.qpc - baseline.qpc);
    const tsc_delta: f64 = @floatFromInt(after.tsc - baseline.tsc);
    const elapsed_sec = qpc_delta / @as(f64, @floatFromInt(freq.QuadPart));

    return @intFromFloat(@round(tsc_delta / elapsed_sec));
}

fn writeTimerValues(ticks: u64, to_ms: f64, offset: f64) void {
    const ticks_bytes = @as([8]u8, @bitCast(ticks));
    hook.writeProtected(ADDR_TICKS_PER_SEC, &ticks_bytes);
    const ms_bytes = @as([8]u8, @bitCast(to_ms));
    hook.writeProtected(ADDR_TO_MS, &ms_bytes);
    const off_bytes = @as([8]u8, @bitCast(offset));
    hook.writeProtected(ADDR_OFFSET, &off_bytes);
}

/// Calibrate and save both original and calibrated values.
/// Called once from transform44.installHooks().
pub fn init() void {
    // OS-level tweaks (independent of TSC calibration)
    increaseTimerResolution();
    disablePowerThrottling();

    const tsc_was_enabled = hook.readMem(u32, ADDR_USE_TSC) != 0;

    // Save original values (if TSC was already enabled)
    if (tsc_was_enabled) {
        orig_ticks_per_sec = hook.readMem(u64, ADDR_TICKS_PER_SEC);
        const orig_ms_bytes = hook.readMem(u64, ADDR_TO_MS);
        orig_to_ms = @bitCast(orig_ms_bytes);
        const orig_off_bytes = hook.readMem(u64, ADDR_OFFSET);
        orig_offset = @bitCast(orig_off_bytes);
    } else {
        // TSC not in use -- game is using GetTickCount (1000 ticks/sec).
        // Save those as "original" for A/B comparison.
        orig_ticks_per_sec = 1000;
        orig_to_ms = 1.0;
        orig_offset = 0;
    }

    // Calibrate
    cal_ticks_per_sec = calibrateTSC();
    cal_to_ms = 1000.0 / @as(f64, @floatFromInt(cal_ticks_per_sec));

    // Align TSC epoch with GetTickCount
    const gtc: f64 = @floatFromInt(GetTickCount());
    const tsc_ms: f64 = @as(f64, @floatFromInt(rdtsc())) * cal_to_ms;
    cal_offset = gtc - tsc_ms;

    // Check if already well-calibrated (within 0.1%)
    if (tsc_was_enabled) {
        const orig_f: f64 = @floatFromInt(orig_ticks_per_sec);
        const cal_f: f64 = @floatFromInt(cal_ticks_per_sec);
        const diff_pct = @abs(cal_f - orig_f) / cal_f * 100.0;

        if (diff_pct < 0.1) {
            // Already calibrated (VanillaFixes or similar), keep original
            is_calibrated = false;
            return;
        }
    }

    is_calibrated = true;
    // Enable TSC mode if it wasn't already
    if (!tsc_was_enabled) {
        const one = @as([4]u8, @bitCast(@as(u32, 1)));
        hook.writeProtected(ADDR_USE_TSC, &one);
    }
    // Apply calibrated values
    writeTimerValues(cal_ticks_per_sec, cal_to_ms, cal_offset);
}

/// Switch to calibrated (CUSTOM) timer values.
pub fn applyCalibrated() void {
    if (!is_calibrated) return;
    const one = @as([4]u8, @bitCast(@as(u32, 1)));
    hook.writeProtected(ADDR_USE_TSC, &one);
    writeTimerValues(cal_ticks_per_sec, cal_to_ms, cal_offset);
}

/// Restore original (BASELINE) timer values.
pub fn applyOriginal() void {
    if (!is_calibrated) return;
    // If TSC was originally disabled, restore that state
    if (orig_ticks_per_sec == 1000) {
        const zero = @as([4]u8, @bitCast(@as(u32, 0)));
        hook.writeProtected(ADDR_USE_TSC, &zero);
    }
    writeTimerValues(orig_ticks_per_sec, orig_to_ms, orig_offset);
}

pub const TimerInfo = struct {
    calibrated: bool,
    orig_freq: u64,
    cal_freq: u64,
    diff_pct_x10: u64, // tenths of a percent
};

pub fn getInfo() TimerInfo {
    const orig_f: f64 = @floatFromInt(orig_ticks_per_sec);
    const cal_f: f64 = @floatFromInt(cal_ticks_per_sec);
    const diff = if (cal_f > 0) @abs(cal_f - orig_f) / cal_f * 1000.0 else 0;
    return .{
        .calibrated = is_calibrated,
        .orig_freq = orig_ticks_per_sec,
        .cal_freq = cal_ticks_per_sec,
        .diff_pct_x10 = @intFromFloat(diff),
    };
}
