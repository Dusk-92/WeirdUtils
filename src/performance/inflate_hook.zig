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
const gameFreeMemory: *const fn (u32, u32, u32) callconv(SC) u32 = @ptrFromInt(0x646430);

fn gameAlloc(size: u32) ?*anyopaque {
    return gameRealloc(0, size, 0, 0, 0);
}

fn gameFree(ptr: *anyopaque) void {
    _ = gameFreeMemory(@intFromPtr(ptr), 0, 0);
}

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
    // param2 = &outSize (pointer), param4 = inSize (value, NOT pointer)
    const out_size = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
    const in_ptr: [*]const u8 = @ptrFromInt(in_buf);

    // Run original first (this is the authoritative result)
    const t0 = rdtsc();
    const ret = decompress_hook.callOriginal(.{ out_buf, out_size_ptr, in_buf, in_size, flags });
    const orig_cycles = rdtsc() - t0;

    orig_total_cycles +|= orig_cycles;
    call_count +|= 1;

    // Only process if original succeeded and buffers are valid
    if (ret != 0 and decompressor != null and in_size > 2 and out_size > 0) {
        const actual_out_size = @as(*const u32, @ptrFromInt(out_size_ptr)).*;
        if (actual_out_size > 0 and actual_out_size < 4 * 1024 * 1024) {
            // First byte = compression type bitmask:
            //   0x01 = Huffman/sparse  0x02 = zlib   0x10 = bzip2
            //   0x20 = PKWare DCL      0x40 = ADPCM mono  0x80 = ADPCM stereo
            const comp_type = in_ptr[0];
            total_bytes +|= actual_out_size;

            // Track type distribution
            inline for (0..8) |bit| {
                if ((comp_type & (@as(u8, 1) << @intCast(bit))) != 0)
                    type_counts[bit] +|= 1;
            }

            // Log first-seen header for each compression type
            if (!type_headers_logged[comp_type]) {
                type_headers_logged[comp_type] = true;
                log.fmt("  type=0x{x:0>2} in_size={d} out_size={d} hdr:", .{ comp_type, in_size, actual_out_size });
                // Dump first 16 bytes after type byte
                const dump_len = @min(in_size - 1, 16);
                for (0..dump_len) |i| {
                    log.fmt(" {x:0>2}", .{in_ptr[1 + i]});
                }
                log.print("\n");
            }
            raw_type_counts[comp_type] +|= 1;
            total_in_bytes +|= in_size;
        }
    }

    return ret;
}

pub fn dumpStats() void {
    if (call_count == 0) return;
    const MS_DIV: u64 = 3_000_000;
    const type_names = [8][]const u8{ "huff", "zlib", "b2", "b3", "bzip", "pkw", "adpcm1", "adpcm2" };
    log.fmt("inflate: {d} calls, in={d}KB out={d}KB, orig={d}ms\n", .{
        call_count,
        total_in_bytes / 1024,
        total_bytes / 1024,
        orig_total_cycles / MS_DIV,
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
