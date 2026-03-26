//! inflate_hook — libdeflate replacement for WoW's zlib inflate.
//!
//! Hooks DecompressData_WithOptions (0x661A80). For type 0x02 (zlib) streams,
//! uses libdeflate (~2.2x faster than stock zlib). Falls back to original on failure.
//!
//! Thread-safety: the decompressor struct contains mutable decode tables rebuilt
//! per block, so each thread gets its own cached decompressor via Zig's native
//! threadlocal (OS-managed TLS). This avoids both the race condition
//! (shared decompressor -> wild writes) and the per-call alloc overhead.
//!
//! Benchmark results (84k calls, heavy load):
//!   stock=2681ms | per-call-alloc=1304ms (2.05x) | tls-cached=1194ms (2.2x)

const hook_lib = @import("zhook");
const logging = @import("../logging.zig");
const std = @import("std");

// libdeflate C API
extern fn libdeflate_alloc_decompressor() ?*anyopaque;
extern fn libdeflate_free_decompressor(?*anyopaque) void;
extern fn libdeflate_zlib_decompress(?*anyopaque, [*]const u8, usize, [*]u8, usize, *usize) c_int;

var lib_available: bool = false;
var log: logging.Logger = .{};

// --- Thread-local decompressor ---
// Each thread lazily allocates its own decompressor on first use.
// OS-managed TLS via Zig's threadlocal -- works correctly on both
// native Windows and Wine without manual FS segment access.
threadlocal var tls_decomp: ?*anyopaque = null;

fn getTlsDecompressor() ?*anyopaque {
    if (tls_decomp) |d| return d;
    const d = libdeflate_alloc_decompressor() orelse return null;
    tls_decomp = d;
    return d;
}

// --- Timing ---
var fast_total_cycles: u64 = 0;
var orig_total_cycles: u64 = 0;
var call_count: u64 = 0;
var success_count: u64 = 0;
var fallback_count: u64 = 0;

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
}

const DecompressFn = fn (u32, u32, u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) u32;
pub var decompress_hook: hook_lib.Detour(DecompressFn) = .{};

pub fn decompressDetour(out_buf: u32, out_size_ptr: u32, in_buf: u32, in_size: u32, flags: u32) callconv(.{ .x86_stdcall = .{} }) u32 {
    const in_ptr: [*]const u8 = @ptrFromInt(in_buf);
    const out_capacity = @as(*const u32, @ptrFromInt(out_size_ptr)).*;

    // Accept type 0x02 with valid zlib CMF (deflate method = low nibble 0x08)
    if (lib_available and in_size > 3 and out_capacity > 0 and
        in_ptr[0] == 0x02 and (in_ptr[1] & 0x0F) == 0x08)
    {
        if (getTlsDecompressor()) |decomp| {
            var ld_out: usize = 0;
            const t1 = rdtsc();
            const ld_ret = libdeflate_zlib_decompress(
                decomp,
                in_ptr + 1,
                in_size - 1,
                @ptrFromInt(out_buf),
                out_capacity,
                &ld_out,
            );
            fast_total_cycles +|= rdtsc() - t1;

            if (ld_ret == 0) {
                call_count +|= 1;
                success_count +|= 1;
                return 1;
            }
        }
    }

    // Fallback to original
    call_count +|= 1;
    const t0 = rdtsc();
    const ret = decompress_hook.callOriginal(.{ out_buf, out_size_ptr, in_buf, in_size, flags });
    orig_total_cycles +|= rdtsc() - t0;
    fallback_count +|= 1;
    return ret;
}

pub fn dumpStats() void {
    if (call_count == 0) return;
    const MS = 3_000_000;
    log.fmt("inflate: {d} calls | fast={d} ({d}ms) fallback={d} ({d}ms)\n", .{
        call_count, success_count, fast_total_cycles / MS, fallback_count, orig_total_cycles / MS,
    });
    fast_total_cycles = 0;
    orig_total_cycles = 0;
    call_count = 0;
    success_count = 0;
    fallback_count = 0;
}

pub fn install() bool {
    const test_decomp = libdeflate_alloc_decompressor();
    if (test_decomp == null) return false;
    libdeflate_free_decompressor(test_decomp);
    lib_available = true;
    return decompress_hook.attach(0x661A80, &decompressDetour) == .ok;
}

pub fn remove() void {
    decompress_hook.detach();
    lib_available = false;
}
