//! inflate_hook — libdeflate timing comparison hook for WoW's inflateStateMachine.
//!
//! Hooks BZip2Decompressor_Decompress (0x660740) which receives complete
//! compressed buffers. Runs both original and libdeflate, times both,
//! logs the comparison.

const hook_lib = @import("zhook");
const logging = @import("../logging.zig");

const FC: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const SC: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };
const std = @import("std");

// Game memory allocator: ReallocMemory(NULL, size, ...) = malloc, FreeMemory(ptr, ...) = free
const gameRealloc: *const fn (u32, u32, u32, u32, u32) callconv(SC) ?*anyopaque = @ptrFromInt(0x646320);
const gameFreeMemory: *const fn (u32, u32, u32, u32) callconv(SC) u32 = @ptrFromInt(0x646430);

fn gameAlloc(size: u32) ?*anyopaque {
    return gameRealloc(0, size, 0, 0, 0);
}

fn gameFree(ptr: *anyopaque) void {
    _ = gameFreeMemory(@intFromPtr(ptr), 0, 0, 0);
}

// libdeflate C API (linked from static lib)
extern fn libdeflate_alloc_decompressor() ?*anyopaque;
extern var libdeflate_x86_cpu_features: u32;
extern fn libdeflate_free_decompressor(?*anyopaque) void;
extern fn libdeflate_zlib_decompress(
    decompressor: ?*anyopaque,
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_len: usize,
    actual_out: *usize,
) c_int;
extern fn libdeflate_deflate_decompress(
    decompressor: ?*anyopaque,
    in_ptr: [*]const u8,
    in_len: usize,
    out_ptr: [*]u8,
    out_len: usize,
    actual_out: *usize,
) c_int;

var decompressor: ?*anyopaque = null;
var log: logging.Logger = .{};

// Static decompressor memory — avoids using game allocator which may not be malloc-compatible
var static_decompressor_mem: [12288]u8 align(16) = undefined; // 12KB > 11564 bytes needed

// Reusable output buffer for libdeflate timing — static 256KB, no heap allocation needed
var ld_buf_backing: [256 * 1024]u8 align(16) = undefined;
var ld_buf: [*]u8 = &ld_buf_backing;
const ld_buf_size: u32 = 256 * 1024;

// Timing accumulators
var orig_total_cycles: u64 = 0;
var fast_total_cycles: u64 = 0;
var call_count: u64 = 0;
var mismatch_count: u64 = 0;
var success_count: u64 = 0;
var total_bytes: u64 = 0;
var total_in_bytes: u64 = 0;
// Per-type counters: index by compression mask bit
var type_counts: [8]u64 = .{0} ** 8; // bits 0-7
// Per raw type byte counter (full byte value)
var raw_type_counts: [256]u32 = .{0} ** 256;
// Track first-seen header bytes per type for format identification
var type_headers_logged: [256]bool = .{false} ** 256;

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

// =============================================================================
// Hook: DecompressData_WithOptions (0x661A80)
// __cdecl(outBuf, &outSize, inBuf, &inSize, flags) → returns ptr (0=fail, 1=ok)
//
// This is the top-level decompression dispatcher. It reads the first byte
// as a compression type bitmask and dispatches to the appropriate decompressor.
// We intercept here to run libdeflate on the same data for comparison.
// =============================================================================

const DecompressFn = fn (u32, u32, u32, u32, u32) callconv(SC) u32;
pub var decompress_hook: hook_lib.Detour(DecompressFn) = .{};

pub fn decompressDetour(out_buf: u32, out_size_ptr: u32, in_buf: u32, in_size: u32, flags: u32) callconv(SC) u32 {
    // param1 = outBuf, param2 = &outSize (ptr), param3 = inBuf, param4 = inSize (value), param5 = flags
    // Read output buffer capacity BEFORE the original modifies *out_size_ptr
    const out_capacity = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
    const in_ptr: [*]const u8 = @ptrFromInt(in_buf);

    // Save input data BEFORE calling original — the original may modify the input buffer
    // (overlap handling in DecompressData_WithOptions copies data around)
    var saved_input_backing: [8192]u8 = undefined;
    const save_len = @min(in_size, saved_input_backing.len);
    @memcpy(saved_input_backing[0..save_len], in_ptr[0..save_len]);

    // Run original and time it
    const t0 = rdtsc();
    const ret = decompress_hook.callOriginal(.{ out_buf, out_size_ptr, in_buf, in_size, flags });
    const orig_cycles = rdtsc() - t0;

    orig_total_cycles +|= orig_cycles;
    call_count +|= 1;

    if (ret != 0 and in_size > 2 and out_capacity > 0) {
        const comp_type = in_ptr[0];
        const actual_out = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
        total_bytes +|= actual_out;
        total_in_bytes +|= in_size;

        inline for (0..8) |bit| {
            if ((comp_type & (@as(u8, 1) << @intCast(bit))) != 0)
                type_counts[bit] +|= 1;
        }
        raw_type_counts[comp_type] +|= 1;

        // Log first-seen header per type
        if (!type_headers_logged[comp_type]) {
            type_headers_logged[comp_type] = true;
            log.fmt("  type=0x{x:0>2} in={d} out={d} hdr:", .{ comp_type, in_size, actual_out });
            const dump_len = @min(in_size - 1, 16);
            for (0..dump_len) |i| log.fmt(" {x:0>2}", .{in_ptr[1 + i]});
            log.print("\n");
        }

        // Time libdeflate on zlib-only streams (type == 0x02, header 78 xx)
        if (comp_type == 0x02 and decompressor != null and actual_out > 0) {
            // Use actual_out (post-original) as the exact expected size.
            // out_capacity (pre-original) may be larger than needed but actual_out
            // is what the original produced — libdeflate should produce the same.
            const ld_out_size = actual_out;

            // Use static buffer — skip calls larger than 256KB
            if (ld_out_size <= ld_buf_size) {
                const buf = ld_buf;
                // Log first call for debugging
                if (success_count == 0 and mismatch_count == 0) {
                    log.fmt("  ld_call: buf=0x{x} size={d} in=0x{x} in_size={d} hdr={x:0>2}{x:0>2}\n", .{
                        @intFromPtr(buf), ld_out_size,
                        @intFromPtr(in_ptr + 1), in_size - 1,
                        in_ptr[1], in_ptr[2],
                    });
                }
                var ld_out: usize = 0;
                const t1 = rdtsc();
                // Use saved input — original may have modified the buffer
                const ld_ret = libdeflate_zlib_decompress(
                    decompressor,
                    @ptrCast(saved_input_backing[1..save_len]),
                    save_len - 1,
                    @ptrCast(buf),
                    ld_out_size,
                    &ld_out,
                );
                const fast_cycles = rdtsc() - t1;
                fast_total_cycles +|= fast_cycles;
                if (ld_ret == 0 and ld_out == actual_out)
                    success_count +|= 1
                else
                    mismatch_count +|= 1;
            }
        }
    }

    return ret;
}

pub fn dumpStats() void {
    if (call_count == 0) return;
    const MS_DIV: u64 = 3_000_000;
    const type_names = [8][]const u8{ "huff", "zlib", "b2", "b3", "bzip", "pkw", "adpcm1", "adpcm2" };
    log.fmt("inflate: {d} calls, in={d}KB out={d}KB, orig={d}ms fast={d}ms (ok={d} fail={d})\n", .{
        call_count,
        total_in_bytes / 1024,
        total_bytes / 1024,
        orig_total_cycles / MS_DIV,
        fast_total_cycles / MS_DIV,
        success_count,
        mismatch_count,
    });
    // Type bits distribution
    log.print("  bits:");
    for (type_names, 0..) |name, i| {
        if (type_counts[i] > 0) {
            log.fmt(" {s}={d}", .{ name, type_counts[i] });
        }
    }
    log.print("\n");
    // Raw type byte distribution (shows exact combos used)
    log.print("  raw:");
    for (raw_type_counts, 0..) |count, i| {
        if (count > 0) {
            log.fmt(" 0x{x:0>2}={d}", .{ i, count });
        }
    }
    log.print("\n");
    // Reset
    orig_total_cycles = 0;
    fast_total_cycles = 0;
    call_count = 0;
    success_count = 0;
    mismatch_count = 0;
    total_bytes = 0;
    total_in_bytes = 0;
    for (&type_counts) |*c| c.* = 0;
    for (&raw_type_counts) |*c| c.* = 0;
}

fn staticMalloc(size: usize) callconv(.c) ?*anyopaque {
    if (size <= static_decompressor_mem.len) {
        return @ptrCast(&static_decompressor_mem);
    }
    return null;
}

fn staticFree(_: ?*anyopaque) callconv(.c) void {}

extern fn libdeflate_alloc_decompressor_with_funcs(?*const fn (usize) callconv(.c) ?*anyopaque, ?*const fn (?*anyopaque) callconv(.c) void) ?*anyopaque;

pub fn install(logger: logging.Logger) bool {
    log = logger;
    // Use static memory — bypass game allocator entirely
    decompressor = libdeflate_alloc_decompressor();
    if (decompressor == null) {
        log.print("inflate_hook: failed to allocate libdeflate decompressor\n");
        return false;
    }
    // Quick sanity test: decompress a trivial zlib stream
    {
        // zlib-compressed "hello" (pre-computed)
        const test_in = [_]u8{ 0x78, 0x9C, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00, 0x06, 0x2C, 0x02, 0x15 };
        var test_out: [64]u8 = undefined;
        var test_len: usize = 0;
        const test_ret = libdeflate_zlib_decompress(
            decompressor,
            &test_in,
            test_in.len,
            &test_out,
            test_out.len,
            &test_len,
        );
        log.fmt("inflate_hook: sanity test ret={d} len={d} data='{s}'\n", .{
            test_ret, test_len, test_out[0..@min(test_len, 32)],
        });
    }
    log.fmt("inflate_hook: cpu_features=0x{x:0>8}\n", .{libdeflate_x86_cpu_features});
    if (decompress_hook.attach(0x661A80, &decompressDetour) == .ok) {
        log.print("inflate_hook: hooked DecompressData_WithOptions\n");
        return true;
    }
    log.print("inflate_hook: failed to hook\n");
    return false;
}

pub fn remove() void {
    decompress_hook.detach();
    if (decompressor) |d| {
        libdeflate_free_decompressor(d);
        decompressor = null;
    }
}
