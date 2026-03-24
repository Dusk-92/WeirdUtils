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

// libdeflate C API (linked from static lib)
extern fn libdeflate_alloc_decompressor() ?*anyopaque;
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

// Timing accumulators
var orig_total_cycles: u64 = 0;
var fast_total_cycles: u64 = 0;
var call_count: u64 = 0;
var mismatch_count: u64 = 0;
var total_bytes: u64 = 0;

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

pub fn decompressDetour(out_buf: u32, out_size_ptr: u32, in_buf: u32, in_size_ptr: u32, flags: u32) callconv(SC) u32 {
    // Read input/output sizes
    const in_size = @as(*const u32, @ptrFromInt(in_size_ptr)).*;
    const out_size = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
    const in_ptr: [*]const u8 = @ptrFromInt(in_buf);

    // Run original first (this is the authoritative result)
    const t0 = rdtsc();
    const ret = decompress_hook.callOriginal(.{ out_buf, out_size_ptr, in_buf, in_size_ptr, flags });
    const orig_cycles = rdtsc() - t0;

    // Only compare if original succeeded, we have a decompressor, and buffer is non-trivial
    if (ret != 0 and decompressor != null and in_size > 16 and out_size > 0) {
        // Read the compression type byte — first byte of compressed data
        const comp_type = in_ptr[0];

        // Only test zlib/deflate streams (type byte has bit patterns for different compressors)
        // The actual data starts at byte 1 (after the type byte)
        // For now, test on all calls regardless of type — libdeflate handles raw deflate
        _ = comp_type;

        // Allocate temp buffer for libdeflate output
        const actual_out_size = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
        if (actual_out_size > 0 and actual_out_size < 4 * 1024 * 1024) {
            // Use VirtualAlloc or stack for small buffers
            var fast_buf: [65536]u8 = undefined;
            const use_buf: [*]u8 = if (actual_out_size <= 65536) &fast_buf else return ret;

            var actual_out: usize = 0;
            const t1 = rdtsc();
            const ld_ret = libdeflate_deflate_decompress(
                decompressor,
                in_ptr + 1, // skip type byte
                in_size - 1,
                use_buf,
                actual_out_size,
                &actual_out,
            );
            const fast_cycles = rdtsc() - t1;

            orig_total_cycles +|= orig_cycles;
            fast_total_cycles +|= fast_cycles;
            call_count +|= 1;
            total_bytes +|= actual_out_size;

            // Check if libdeflate succeeded and produced same output
            if (ld_ret == 0 and actual_out == actual_out_size) {
                // Compare outputs
                const orig_out: [*]const u8 = @ptrFromInt(out_buf);
                var match = true;
                for (0..actual_out_size) |i| {
                    if (orig_out[i] != use_buf[i]) {
                        match = false;
                        break;
                    }
                }
                if (!match) mismatch_count +|= 1;
            }
        }
    } else {
        orig_total_cycles +|= orig_cycles;
        call_count +|= 1;
    }

    return ret;
}

pub fn dumpStats() void {
    if (call_count == 0) return;
    const MS_DIV: u64 = 3_000_000;
    log.fmt("inflate: {d} calls, {d}MB, orig={d}ms fast={d}ms ({d} mismatches)\n", .{
        call_count,
        total_bytes / (1024 * 1024),
        orig_total_cycles / MS_DIV,
        fast_total_cycles / MS_DIV,
        mismatch_count,
    });
    // Reset
    orig_total_cycles = 0;
    fast_total_cycles = 0;
    call_count = 0;
    mismatch_count = 0;
    total_bytes = 0;
}

pub fn install(logger: logging.Logger) bool {
    log = logger;
    decompressor = libdeflate_alloc_decompressor();
    if (decompressor == null) {
        log.print("inflate_hook: failed to allocate libdeflate decompressor\n");
        return false;
    }
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
