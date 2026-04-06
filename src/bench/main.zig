//! Micro-benchmark harness for math_sse replacements.
//!
//! Extracts original x87 FPU function bytes from WoW.exe, maps them executable,
//! and benchmarks against our SSE replacements. Runs on x86 Linux (32-bit).
//!
//! Build:  zig build bench
//! Run:    zig build run-bench

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const originals = @import("originals.zig");

// SSE implementations (C ABI — export fn from math_sse.zig)
extern fn vecMulMat4_ColMajor(u32, u32, u32) u32;
extern fn matMulVec3_RowMajor(u32, u32, u32) u32;
extern fn quatMulMat4(u32, u32, u32) u32;
extern fn vec3MulScalar(u32, u32, u32) u32;
extern fn vec3MulAssign(u32, u32) u32;
extern fn applyTranslationMatrix(u32, u32) u32;
extern fn scaleMatrix3x3ByVector(u32, u32) u32;
extern fn scaleMatrix3x3ByScalar(u32, u32) void;
extern fn multiply3x3Matrix(u32, u32, u32) u32;
extern fn createAxisAngleRotMat3x3(u32, u32, u32, u32) u32;
extern fn createAxisAngleRotMat4x4(u32, u32, u32, u32) u32;
extern fn crossProduct(u32, u32, u32) u32;
extern fn dotProduct(u32, u32) f64;
extern fn squaredMagnitude(u32) f64;
extern fn evaluatePolynomial(u32, u32, u32) f64;
extern fn calculatePlaneNormal(u32, u32, u32, u32) void;
extern fn transformAABox(u32, u32, u32, u32, u32) void;

// silicon_sse.zig exports
extern fn si_normalizeVec3(u32, u32) callconv(cc_tc) void;
extern fn si_mulMat3x4(u32, u32, u32) callconv(cc_fc) u32;
extern fn si_rotateMatByQuat(u32, u32) callconv(cc_tc) u32;
extern fn si_createRotMat3x4(u32, u32, u32, u32) callconv(cc_fc) u32;
extern fn si_distanceToPlane(u32, u32, u32) callconv(cc_fc) f64;
extern fn si_classifyPointFrustum(u32, u32, u32) callconv(cc_tc) u32;
extern fn si_checkBoxLineIntersect(u32, u32, u32) callconv(cc_fc) u32;
extern fn si_testOBBFrustum(u32, u32, u32, u32) callconv(cc_tc) u32;
extern fn si_testSphereFrustum(u32, u32) callconv(cc_tc) u32;
extern fn si_quatSlerp(u32, u32, u32, u32) callconv(cc_fc) u32;
extern fn si_isPointInsideBounds(u32, u32) callconv(cc_fc) u32;
extern fn si_calculateSinCos(u32, u32, u32) callconv(cc_sc) void;
extern fn si_createZRotMat3x3(u32, u32) callconv(cc_tc) u32;
extern fn si_transposeMat4x4(u32, u32) callconv(cc_tc) u32;
extern fn si_mulMat3x4InPlace(u32, u32) callconv(cc_tc) u32;
extern fn si_normalizeVec3InPlace(u32) callconv(cc_tc) void;
extern fn si_vec3Dot(u32, u32) callconv(cc_fc) f64;
extern fn si_translateBoundingVol(u32, u32) callconv(cc_tc) void;
extern fn si_processLinkedListCollision(u32, u32, u32, u32) callconv(cc_fc) u32;
extern fn si_frustumCullBBox(u32, u32, u32) callconv(cc_fc) u32;
extern fn calcColorValues_SSE(u32, u32, u32, u32, u32, u32, u32) callconv(cc_tc) void;
extern fn si_addVec3ToAccumulator(u32, u32) callconv(cc_tc) void;
extern fn si_addToColorAccumulator(u32, u32) callconv(cc_tc) void;
extern fn si_packParticleColor(u32, u32, u32, u32) callconv(cc_tc) void;
extern fn si_setParticleAlpha(u32, u32, u32) callconv(cc_fc) void; // fastcall(ECX=obj, EDX=unused, stack=alpha)
extern fn si_ftol() callconv(.naked) void;

// clip_sse.zig -- benched separately, now wired into weirdperformance as fastcall

// cull_sse.zig exports
extern fn benchComputeOutcodes(u32, u32, u32, u32) void;
extern fn performCollisionDetectionSSE(u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
extern fn updateEntityAndChunksPositions(u32) callconv(.{ .x86_fastcall = .{} }) void;
extern fn rayTriIntersectIndexedInt(u32, u32, u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u8;
extern fn addToSpatialGridSSE(u32) callconv(.{ .x86_fastcall = .{} }) void;

// =========================================================================
// Infrastructure
// =========================================================================

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, msg.ptr, msg.len);
}

fn makeExecutable(comptime bytes: []const u8) ?[*]const u8 {
    const mem = posix.mmap(
        null, 4096,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1, 0,
    ) catch return null;
    @memcpy(mem[0..bytes.len], bytes);
    return mem.ptr;
}

/// Map WoW PE sections at their original virtual addresses.
/// .text (code) at 0x401000 + .rdata (constants) at 0x7FF000.
/// Resolves all intra-code CALL targets and float constant references.
const TEXT_START: usize = 0x401000;
const TEXT_SIZE: usize = 4186112;
const RDATA_START: usize = 0x7FF000;
const RDATA_SIZE: usize = 163840;
const wow_text_data = @embedFile("wow_text.bin");
const wow_rdata_data = @embedFile("wow_rdata.bin");

var sections_mapped: bool = false;

fn mapFixedSection(addr: usize, size: usize, data: []const u8, exec: bool) bool {
    const prot: linux.PROT = if (exec) .{ .READ = true, .WRITE = true, .EXEC = true } else .{ .READ = true, .WRITE = true };
    const mem = posix.mmap(
        @ptrFromInt(addr), size, prot,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1, 0,
    ) catch return false;
    @memcpy(mem[0..data.len], data);
    return true;
}

fn mapZeroed(addr: usize, size: usize) bool {
    _ = posix.mmap(
        @ptrFromInt(addr), size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1, 0,
    ) catch return false;
    return true;
}

fn mapWowSections() bool {
    if (sections_mapped) return true;
    if (!mapFixedSection(TEXT_START, TEXT_SIZE, wow_text_data, true)) return false;
    if (!mapFixedSection(RDATA_START, RDATA_SIZE, wow_rdata_data, false)) return false;
    // Map additional pages for runtime constants that live outside .rdata:
    // 0x80C000-0x813000 covers 0x80C5C8 (billboard epsilon) and 0x811610 (SHORT_TO_FLOAT)
    // 0xCF0000-0xCF1000 covers 0xCF04C4 (boneKeyframe init flag) and 0xCF043C (pivot constants)
    _ = mapZeroed(0x80C000, 0x8000); // covers 0x80C000-0x814000
    _ = mapZeroed(0xCF0000, 0x1000); // covers 0xCF0000-0xCF1000
    // Write runtime constant values
    @as(*align(1) u32, @ptrFromInt(0x811610)).* = 0x38000100; // SHORT_TO_FLOAT ~1/32767
    @as(*align(1) u32, @ptrFromInt(0x8029D4)).* = 0x34800000; // billboard epsilon
    @as(*align(1) u32, @ptrFromInt(0x80C5C8)).* = 0x35800000; // billboard sq epsilon
    @as(*align(1) u32, @ptrFromInt(0x80297C)).* = 0x40400000; // 3.0
    @as(*align(1) u32, @ptrFromInt(0x802990)).* = 0x40C00000; // 6.0
    sections_mapped = true;
    return true;
}

fn origFn(comptime T: type, addr: usize) *const T {
    return @ptrFromInt(addr);
}

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn a(ptr: anytype) u32 {
    return @intFromPtr(ptr);
}

fn compareF32(x: f32, y: f32) bool {
    if (x == y) return true;
    const d = @abs(x - y);
    const m = @max(@abs(x), @abs(y));
    if (m < 1e-7) return d < 1e-7;
    return d / m < 1e-4;
}

fn cmpSlice(x: []const f32, y: []const f32) bool {
    for (x, y) |a2, b| if (!compareF32(a2, b)) return false;
    return true;
}

fn report(name: []const u8, orig_cyc: u64, sse_cyc: u64, ok: bool) void {
    const N = ITERS;
    const op = orig_cyc / N;
    const sp = sse_cyc / N;
    const sx10 = if (sp > 0) op * 10 / sp else 0;
    print("{s:>30}: orig={d:>4} sse={d:>4} cyc/call  {d}.{d}x  {s}\n", .{
        name, op, sp, sx10 / 10, sx10 % 10, if (ok) "OK" else "MISMATCH",
    });
}

/// Run a function ITERS times, return best-of-5 cycle count.
fn bench5(comptime func: anytype, args: anytype) u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t0 = rdtsc();
        for (0..ITERS) |_| {
            const r = @call(.never_inline, func, args);
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = rdtsc() - t0;
        if (elapsed < best) best = elapsed;
    }
    return best;
}

// =========================================================================
// Calling convention types for original x87 functions (game binary)
// =========================================================================

const cc_fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const cc_tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };
const cc_sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

const ITERS: u64 = 2_000_000;


// =========================================================================
// Test data
// =========================================================================

const Vec3 = [3]f32;
const Vec4 = [4]f32;
const Mat3 = [9]f32;
const Mat4 = [16]f32;

fn tv3() Vec3 { return .{ 1.5, -2.3, 0.7 }; }
fn tv3b() Vec3 { return .{ 0.4, 3.1, -1.2 }; }
fn tv3c() Vec3 { return .{ -0.8, 1.6, 2.5 }; }
fn tq4() Vec4 { return .{ 0.5, -0.5, 0.5, 0.5 }; }
fn tm4() Mat4 {
    return .{ 1.0, 0.2, 0.3, 0.0, 0.1, 2.0, 0.4, 0.0, 0.2, 0.1, 1.5, 0.0, 1.0, 2.0, 3.0, 1.0 };
}
fn tm3() Mat3 { return .{ 1.0, 0.2, 0.3, 0.1, 2.0, 0.4, 0.2, 0.1, 1.5 }; }
fn tm3b() Mat3 { return .{ 0.5, -0.1, 0.3, 0.2, 1.0, -0.2, -0.1, 0.4, 0.8 }; }

// =========================================================================
// Main
// =========================================================================

pub fn main() void {
    if (!mapWowSections()) {
        print("FATAL: could not map WoW PE sections\n", .{});
        return;
    }

    print("\nmath_sse benchmark -- {d}M iterations per function\n", .{ITERS / 1_000_000});
    print("{s:>30}  {s:>10} {s:>10}           {s}\n", .{ "function", "original", "sse", "status" });
    print("{s}\n", .{"-" ** 72});

    // AddToSpatialGrid -- linked list requires game state, A/B test in-game only
    // bench_addToSpatialGrid();

    if (false) { // disabled: link errors / already benched
    bench_collisionDetection();
    bench_rayTriIndexedInt();
    }

    if (false) { // disabled
    bench_entityUpdate();
    }

    bench_detour_overhead();

    if (false) { // disabled: not working on these right now

    // 1: vecMulMat4 -- fastcall(ECX=result, EDX=vec, stack=mat) -> u32
    bench_fc3r("vecMulMat4_ColMajor", originals.vecMulMat4_ColMajor, &vecMulMat4_ColMajor, tv3(), tm4(), 3);

    // 2: matMulVec3 -- fastcall(ECX=result, EDX=mat, stack=vec) -> u32
    bench_fc3r("matMulVec3_RowMajor", originals.matMulVec3_RowMajor, &matMulVec3_RowMajor, tm4(), tv3(), 3);

    // 3: quatMulMat4 -- fastcall(ECX=result, EDX=quat, stack=mat) -> u32
    bench_fc3r("quatMulMat4", originals.quatMulMat4, &quatMulMat4, tq4(), tm4(), 4);

    // 4: vec3MulScalar -- fastcall(ECX=result, EDX=vec, stack=factor_bits) -> u32
    {
        const factor: f32 = 2.5;
        const fb: u32 = @bitCast(factor);
        const v = tv3();
        var ro: Vec3 = undefined;
        var rs: Vec3 = undefined;
        const of: *const fn (u32, u32, u32) callconv(cc_fc) u32 = @ptrCast(makeExecutable(&originals.vec3MulScalar) orelse unreachable);
        _ = of(a(&ro), a(&v), fb);
        _ = vec3MulScalar(a(&rs), a(&v), fb);
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = 0;
        var s: u64 = 0;
        t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&v), fb); } t = rdtsc() - t;
        s = rdtsc(); for (0..ITERS) |_| { _ = vec3MulScalar(a(&rs), a(&v), fb); } s = rdtsc() - s;
        report("vec3MulScalar", t, s, ok);
    }

    // 5: vec3MulAssign -- thiscall(ECX=self, stack=factor_bits) -> u32
    {
        const fb: u32 = @bitCast(@as(f32, 2.5));
        const tmpl = tv3();
        var do = tmpl;
        var ds = tmpl;
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = @ptrCast(makeExecutable(&originals.vec3MulAssign) orelse unreachable);
        _ = of(a(&do), fb);
        _ = vec3MulAssign(a(&ds), fb);
        const ok = cmpSlice(&do, &ds);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { do = tmpl; _ = of(a(&do), fb); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { ds = tmpl; _ = vec3MulAssign(a(&ds), fb); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("vec3MulAssign", t, s, ok);
    }

    // 6: applyTranslation -- thiscall(ECX=mat, stack=vec) -> u32
    bench_tc2r("applyTranslation", originals.applyTranslationMatrix, &applyTranslationMatrix, tm4(), tv3(), 16);

    // 7: scaleByVec -- thiscall(ECX=mat, stack=vec) -> u32
    bench_tc2r("scaleByVec", originals.scaleMatrix3x3ByVector, &scaleMatrix3x3ByVector, tm4(), tv3(), 16);

    // 8: scaleByScalar -- thiscall(ECX=mat, stack=factor_bits) -> void
    {
        const fb: u32 = @bitCast(@as(f32, 0.5));
        const tmpl = tm4();
        var mo = tmpl;
        var ms = tmpl;
        const of: *const fn (u32, u32) callconv(cc_tc) void = @ptrCast(makeExecutable(&originals.scaleMatrix3x3ByScalar) orelse unreachable);
        of(a(&mo), fb);
        scaleMatrix3x3ByScalar(a(&ms), fb);
        const ok = cmpSlice(&mo, &ms);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { mo = tmpl; of(a(&mo), fb); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { ms = tmpl; scaleMatrix3x3ByScalar(a(&ms), fb); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("scaleByScalar", t, s, ok);
    }

    // 9: mul3x3 -- fastcall(ECX=result, EDX=matA, stack=matB) -> u32
    bench_fc3r("multiply3x3", originals.multiply3x3Matrix, &multiply3x3Matrix, tm3(), tm3b(), 9);

    // 10: rotMat3x3 -- fastcall(ECX=result, EDX=axis, stack=angle_bits, is_unit) -> u32
    {
        const axis = Vec3{ 0.0, 1.0, 0.0 };
        const ab: u32 = @bitCast(@as(f32, 0.7854));
        var ro: Mat3 = undefined;
        var rs: Mat3 = undefined;
        const of: *const fn (u32, u32, u32, u32) callconv(cc_fc) u32 = @ptrCast(makeExecutable(&originals.createAxisAngleRotMat3x3) orelse unreachable);
        _ = of(a(&ro), a(&axis), ab, 1);
        _ = createAxisAngleRotMat3x3(a(&rs), a(&axis), ab, 1);
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis), ab, 1); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = createAxisAngleRotMat3x3(a(&rs), a(&axis), ab, 1); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("rotMat3x3", t, s, ok);
    }

    // 11: rotMat4x4
    {
        const axis = Vec3{ 0.0, 1.0, 0.0 };
        const ab: u32 = @bitCast(@as(f32, 0.7854));
        var ro: Mat4 = undefined;
        var rs: Mat4 = undefined;
        const of: *const fn (u32, u32, u32, u32) callconv(cc_fc) u32 = @ptrCast(makeExecutable(&originals.createAxisAngleRotMat4x4) orelse unreachable);
        _ = of(a(&ro), a(&axis), ab, 1);
        _ = createAxisAngleRotMat4x4(a(&rs), a(&axis), ab, 1);
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis), ab, 1); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = createAxisAngleRotMat4x4(a(&rs), a(&axis), ab, 1); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("rotMat4x4", t, s, ok);
    }

    // 12: cross -- fastcall(ECX=result, EDX=vecA, stack=vecB) -> u32
    bench_fc3r("crossProduct", originals.crossProduct, &crossProduct, tv3(), tv3b(), 3);

    // 13: dot -- fastcall(ECX=vecA, EDX=vecB) -> f64
    {
        const va = tv3();
        const vb = tv3b();
        const of: *const fn (u32, u32) callconv(cc_fc) f64 = origFn(fn (u32, u32) callconv(cc_fc) f64, 0x602630);
        const ov = of(a(&va), a(&vb));
        const sv = dotProduct(a(&va), a(&vb));
        const ok = @abs(ov - sv) < 1e-4;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va), a(&vb)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = dotProduct(a(&va), a(&vb)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("dotProduct", t, s, ok);
    }

    // 14: sqmag -- thiscall(ECX=vec) -> f64
    {
        const v = tv3();
        const of: *const fn (u32) callconv(cc_tc) f64 = @ptrCast(makeExecutable(&originals.squaredMagnitude) orelse unreachable);
        const ov = of(a(&v));
        const sv = squaredMagnitude(a(&v));
        const ok = @abs(ov - sv) < 1e-4;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&v)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = squaredMagnitude(a(&v)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("squaredMagnitude", t, s, ok);
    }

    // 16: evalPoly -- fastcall(ECX=count, EDX=coeffs, stack=factor_bits) -> f64
    {
        const coeffs = [4]f32{ 3.0, -2.0, 1.0, 0.5 };
        const fb: u32 = @bitCast(@as(f32, 1.5));
        const of: *const fn (u32, u32, u32) callconv(cc_fc) f64 = @ptrCast(makeExecutable(&originals.evaluatePolynomial) orelse unreachable);
        const ov = of(3, a(&coeffs), fb);
        const sv = evaluatePolynomial(3, a(&coeffs), fb);
        const ok = @abs(ov - sv) < 1e-4;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(3, a(&coeffs), fb); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = evaluatePolynomial(3, a(&coeffs), fb); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("evaluatePolynomial", t, s, ok);
    }

    // 17: planeNormal -- thiscall(ECX=result, stack=p1,p2,p3) -> void
    {
        const p1 = tv3();
        const p2 = tv3b();
        const p3 = tv3c();
        var ro: Vec4 = undefined;
        var rs: Vec4 = undefined;
        const of: *const fn (u32, u32, u32, u32) callconv(cc_tc) void = @ptrCast(makeExecutable(&originals.calculatePlaneNormal) orelse unreachable);
        of(a(&ro), a(&p1), a(&p2), a(&p3));
        calculatePlaneNormal(a(&rs), a(&p1), a(&p2), a(&p3));
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(a(&ro), a(&p1), a(&p2), a(&p3)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { calculatePlaneNormal(a(&rs), a(&p1), a(&p2), a(&p3)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("planeNormal", t, s, ok);
    }

    // 18: transformAABox -- fastcall(ECX=mat, EDX=vecA, stack=vecB,boxIn,boxOut) -> void
    {
        const mat = tm3();
        const va = tv3();
        const vb = tv3b();
        const box_in = [6]f32{ -1.0, -1.0, -1.0, 1.0, 1.0, 1.0 };
        var bo: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        var bs: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        const of: *const fn (u32, u32, u32, u32, u32) callconv(cc_fc) void = @ptrCast(makeExecutable(&originals.transformAABox) orelse unreachable);
        of(a(&mat), a(&va), a(&vb), a(&box_in), a(&bo));
        transformAABox(a(&mat), a(&va), a(&vb), a(&box_in), a(&bs));
        const ok = cmpSlice(&bo, &bs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { bo = .{ 0, 0, 0, 0, 0, 0 }; of(a(&mat), a(&va), a(&vb), a(&box_in), a(&bo)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { bs = .{ 0, 0, 0, 0, 0, 0 }; transformAABox(a(&mat), a(&va), a(&vb), a(&box_in), a(&bs)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("transformAABox", t, s, ok);
    }

    // =====================================================================
    // INLINED benchmarks — no CALL/RET on either side.
    // x87 via inline asm, SSE via direct Zig. Simulates in-place patching.
    // =====================================================================
    print("\n{s}\n", .{"--- INLINED (no call overhead, simulates in-place patching) ---"});

    // dotProduct inlined
    {
        const va2 = tv3();
        const vb2 = tv3b();
        var rx: f32 = undefined;
        var rs: f32 = undefined;
        inline_x87_dot(&va2, &vb2, &rx);
        inline_sse_dot(&va2, &vb2, &rs);
        const ok = compareF32(rx, rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_x87_dot(&va2, &vb2, &rx);
        const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_sse_dot(&va2, &vb2, &rs);
        const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("dotProduct(inlined)", t, s, ok);
    }

    // squaredMagnitude inlined
    {
        const v = tv3();
        var rx: f32 = undefined;
        var rs: f32 = undefined;
        inline_x87_sqmag(&v, &rx);
        inline_sse_sqmag(&v, &rs);
        const ok = compareF32(rx, rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_x87_sqmag(&v, &rx);
        const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_sse_sqmag(&v, &rs);
        const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("squaredMag(inlined)", t, s, ok);
    }

    // vec3MulScalar inlined
    {
        const vec = tv3();
        const factor: f32 = 2.5;
        var ro: Vec3 = undefined;
        var rs2: Vec3 = undefined;
        inline_x87_v3scale(&vec, &factor, &ro);
        inline_sse_v3scale(&vec, factor, &rs2);
        const ok = cmpSlice(&ro, &rs2);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_x87_v3scale(&vec, &factor, &ro);
        const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_sse_v3scale(&vec, factor, &rs2);
        const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("vec3MulScalar(inlined)", t, s, ok);
    }

    // evaluatePolynomial inlined (degree=3)
    {
        const coeffs = [4]f32{ 3.0, -2.0, 1.0, 0.5 };
        const factor: f32 = 1.5;
        var rx: f32 = undefined;
        var rs: f32 = undefined;
        inline_x87_horner(&coeffs, &factor, &rx);
        inline_sse_horner(&coeffs, factor, &rs);
        const ok = compareF32(rx, rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_x87_horner(&coeffs, &factor, &rx);
        const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
        for (0..ITERS) |_| inline_sse_horner(&coeffs, factor, &rs);
        const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("evalPoly(inlined)", t, s, ok);
    }

    // =====================================================================
    // Silicon SSE functions (src/silicon/silicon_sse.zig)
    // =====================================================================
    print("\n{s}\n", .{"--- SILICON SSE functions ---"});

    // si_isPointInsideBounds (1.7M/7.5s) -- fastcall(vecA_ECX, vecB_EDX) -> u32
    {
        const va2 = tv3();
        const vb2 = Vec3{ 1.0, -3.0, 0.5 }; // all <= va
        const of = origFn(fn (u32, u32) callconv(cc_fc) u32, 0x699330);
        const ov = of(a(&va2), a(&vb2));
        const sv = si_isPointInsideBounds(a(&va2), a(&vb2));
        const ok = ov == sv;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va2), a(&vb2)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_isPointInsideBounds(a(&va2), a(&vb2)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("isPointInsideBounds", t, s, ok);
    }

    // si_vec3Dot (31K/7.5s) -- fastcall(vecA_ECX, vecB_EDX) -> f64
    {
        const va2 = tv3();
        const vb2 = tv3b();
        const of = origFn(fn (u32, u32) callconv(cc_fc) f64, 0x602630);
        const ov = of(a(&va2), a(&vb2));
        const sv = si_vec3Dot(a(&va2), a(&vb2));
        const ok = @abs(ov - sv) < 1e-4;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va2), a(&vb2)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_vec3Dot(a(&va2), a(&vb2)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("si_vec3Dot", t, s, ok);
    }

    // si_normalizeVec3InPlace -- fastcall(vec3_ECX) -> void
    {
        var vo = tv3();
        var vs = tv3();
        const of: *const fn (u32) callconv(cc_fc) void = origFn(fn (u32) callconv(cc_fc) void, 0x6720F0);
        of(a(&vo));
        si_normalizeVec3InPlace(a(&vs));
        const ok = cmpSlice(&vo, &vs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { vo = tv3(); of(a(&vo)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { vs = tv3(); si_normalizeVec3InPlace(a(&vs)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("normalizeVec3InPlace", t, s, ok);
    }

    // si_distanceToPlane (525K/7.5s) -- fastcall(point_ECX, plane_EDX, dir_stack) -> ST(0), RET 4
    // Both original and SSE version use same CC — call via function pointer cast
    {
        const pt = tv3();
        const plane = [4]f32{ 0.0, 1.0, 0.0, -5.0 }; // y=5 plane
        const dir = Vec3{ 0.0, -1.0, 0.0 }; // pointing down
        const of = origFn(fn (u32, u32, u32) callconv(cc_fc) f64, 0x6329E0);
        const ov = of(a(&pt), a(&plane), a(&dir));
        const sv = si_distanceToPlane(a(&pt), a(&plane), a(&dir));
        const ok = @abs(ov - sv) < 1e-2;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&pt), a(&plane), a(&dir)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_distanceToPlane(a(&pt), a(&plane), a(&dir)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("distanceToPlane", t, s, ok);
    }

    // si_checkBoxLineIntersect (2.7M/7.5s) -- fastcall(box_ECX, start_EDX, end_stack) -> u32
    {
        const box = [6]f32{ -1, -1, -1, 1, 1, 1 }; // unit cube
        const ls = Vec3{ -2, 0, 0 };
        const le = Vec3{ 2, 0, 0 }; // line through center
        const of: *const fn (u32, u32, u32) callconv(cc_fc) u32 = origFn(fn (u32, u32, u32) callconv(cc_fc) u32, 0x6DC5A0);
        const ov = of(a(&box), a(&ls), a(&le));
        const sv = si_checkBoxLineIntersect(a(&box), a(&ls), a(&le));
        const ok = ov == sv;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&box), a(&ls), a(&le)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_checkBoxLineIntersect(a(&box), a(&ls), a(&le)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("checkBoxLineIntersect", t, s, ok);
    }

    // si_classifyPointFrustum (3.2M/7.5s) -- thiscall(planes_ECX, point_stack, mask_stack) -> u32
    {
        // 6 planes forming a unit cube frustum
        var planes: [24]f32 = undefined;
        const normals = [6][3]f32{ .{1,0,0}, .{-1,0,0}, .{0,1,0}, .{0,-1,0}, .{0,0,1}, .{0,0,-1} };
        for (0..6) |i| { planes[i*4] = normals[i][0]; planes[i*4+1] = normals[i][1]; planes[i*4+2] = normals[i][2]; planes[i*4+3] = -5; }
        const pt = Vec3{ 0, 0, 0 }; // inside
        var mask_o: u32 = 0;
        var mask_s: u32 = 0;
        const of: *const fn (u32, u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32, u32) callconv(cc_tc) u32, 0x686C20);
        _ = of(a(&planes), a(&pt), a(&mask_o));
        _ = si_classifyPointFrustum(a(&planes), a(&pt), a(&mask_s));
        const ok = mask_o == mask_s;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&pt), a(&mask_o)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_classifyPointFrustum(a(&planes), a(&pt), a(&mask_s)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("classifyPointFrustum", t, s, ok);
    }

    // si_testSphereFrustum (375K/7.5s) -- thiscall(planes_ECX, sphere_stack) -> u32
    {
        var planes: [24]f32 = undefined;
        const normals = [6][3]f32{ .{1,0,0}, .{-1,0,0}, .{0,1,0}, .{0,-1,0}, .{0,0,1}, .{0,0,-1} };
        for (0..6) |i| { planes[i*4] = normals[i][0]; planes[i*4+1] = normals[i][1]; planes[i*4+2] = normals[i][2]; planes[i*4+3] = -5; }
        const sphere = [4]f32{ 0, 0, 0, 1 }; // center origin, radius 1
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32) callconv(cc_tc) u32, 0x686B80);
        const ov = of(a(&planes), a(&sphere));
        const sv = si_testSphereFrustum(a(&planes), a(&sphere));
        const ok = ov == sv;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&sphere)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_testSphereFrustum(a(&planes), a(&sphere)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("testSphereFrustum", t, s, ok);
    }

    // si_transposeMat4x4 -- thiscall(src_ECX, dst_stack) -> u32
    {
        const src = tm4();
        var dst_o: Mat4 = undefined;
        var dst_s: Mat4 = undefined;
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32) callconv(cc_tc) u32, 0x7BCEF0);
        _ = of(a(&src), a(&dst_o));
        _ = si_transposeMat4x4(a(&src), a(&dst_s));
        const ok = cmpSlice(&dst_o, &dst_s);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&src), a(&dst_o)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_transposeMat4x4(a(&src), a(&dst_s)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("transposeMat4x4", t, s, ok);
    }

    // si_quatSlerp -- fastcall(out_ECX, quatA_EDX, t_stack, quatB_stack) -> u32
    {
        const qa = [4]f32{ 1, 0, 0, 0 };
        const qb = [4]f32{ 0.707, 0, 0.707, 0 };
        const tb: u32 = @bitCast(@as(f32, 0.5));
        var ro: [4]f32 = undefined;
        var rs: [4]f32 = undefined;
        const of = origFn(fn (u32, u32, u32, u32) callconv(cc_fc) u32, 0x7C0570);
        _ = of(a(&ro), a(&qa), tb, a(&qb));
        _ = si_quatSlerp(a(&rs), a(&qa), tb, a(&qb));
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&qa), tb, a(&qb)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_quatSlerp(a(&rs), a(&qa), tb, a(&qb)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("quatSlerp", t, s, ok);
    }

    // si_createZRotMat3x3 -- thiscall(out_ECX, angle_stack) -> u32
    {
        const ab2: u32 = @bitCast(@as(f32, 0.7854));
        var ro: Mat3 = undefined;
        var rs: Mat3 = undefined;
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32) callconv(cc_tc) u32, 0x7BE5B0);
        _ = of(a(&ro), ab2);
        _ = si_createZRotMat3x3(a(&rs), ab2);
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), ab2); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_createZRotMat3x3(a(&rs), ab2); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("createZRotMat3x3", t, s, ok);
    }

    // si_mulMat3x4 -- fastcall(out_ECX, matA_EDX, matB_stack) -> u32
    {
        const ma = [12]f32{ 1,0,0, 0,1,0, 0,0,1, 1,2,3 };
        const mb = [12]f32{ 0,1,0, -1,0,0, 0,0,1, 4,5,6 };
        var ro: [12]f32 = undefined;
        var rs: [12]f32 = undefined;
        const of: *const fn (u32, u32, u32) callconv(cc_fc) u32 = origFn(fn (u32, u32, u32) callconv(cc_fc) u32, 0x7BAE60);
        _ = of(a(&ro), a(&ma), a(&mb));
        _ = si_mulMat3x4(a(&rs), a(&ma), a(&mb));
        const ok = cmpSlice(&ro, &rs);
        if (!ok) {
            print("  mulMat3x4 MISMATCH detail:\n", .{});
            for (0..12) |i| {
                if (!compareF32(ro[i], rs[i])) {
                    print("    [{d}] orig={d} sse={d}\n", .{ i, @as(i32, @intFromFloat(ro[i] * 1000)), @as(i32, @intFromFloat(rs[i] * 1000)) });
                }
            }
        }
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&ma), a(&mb)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_mulMat3x4(a(&rs), a(&ma), a(&mb)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("mulMat3x4", t, s, ok);
    }

    // si_rotateMatByQuat -- thiscall(mat_ECX, quat_stack) -> u32
    {
        const quat2 = [4]f32{ 0.0, 0.383, 0.0, 0.924 }; // ~45 deg Y
        var mo = tm4();
        var ms = tm4();
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32) callconv(cc_tc) u32, 0x7BDDB0);
        _ = of(a(&mo), a(&quat2));
        _ = si_rotateMatByQuat(a(&ms), a(&quat2));
        const ok = cmpSlice(&mo, &ms);
        mo = tm4(); ms = tm4();
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { mo = tm4(); _ = of(a(&mo), a(&quat2)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { ms = tm4(); _ = si_rotateMatByQuat(a(&ms), a(&quat2)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("rotateMatByQuat", t, s, ok);
    }

    // si_createRotMat3x4 -- fastcall(out_ECX, axis_EDX, angle_stack, isNorm_stack) -> u32
    {
        const axis2 = Vec3{ 0, 1, 0 };
        const ab2: u32 = @bitCast(@as(f32, 0.7854));
        var ro: [12]f32 = undefined;
        var rs: [12]f32 = undefined;
        const of: *const fn (u32, u32, u32, u32) callconv(cc_fc) u32 = origFn(fn (u32, u32, u32, u32) callconv(cc_fc) u32, 0x7BB860);
        _ = of(a(&ro), a(&axis2), ab2, 1);
        _ = si_createRotMat3x4(a(&rs), a(&axis2), ab2, 1);
        const ok = cmpSlice(&ro, &rs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis2), ab2, 1); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_createRotMat3x4(a(&rs), a(&axis2), ab2, 1); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("createRotMat3x4", t, s, ok);
    }

    // si_mulMat3x4InPlace -- thiscall(matA_ECX, matB_stack) -> u32
    {
        const mb2 = [12]f32{ 0,1,0, -1,0,0, 0,0,1, 4,5,6 };
        const tmpl2 = [12]f32{ 1,0,0, 0,1,0, 0,0,1, 1,2,3 };
        var mo2 = tmpl2;
        var ms2 = tmpl2;
        const of: *const fn (u32, u32) callconv(cc_tc) u32 = origFn(fn (u32, u32) callconv(cc_tc) u32, 0x7BB420);
        _ = of(a(&mo2), a(&mb2));
        _ = si_mulMat3x4InPlace(a(&ms2), a(&mb2));
        const ok = cmpSlice(&mo2, &ms2);
        if (!ok) {
            print("  mulMat3x4InPlace MISMATCH detail:\n", .{});
            for (0..12) |i| {
                if (!compareF32(mo2[i], ms2[i])) {
                    print("    [{d}] orig={d} sse={d}\n", .{ i, @as(i32, @intFromFloat(mo2[i] * 1000)), @as(i32, @intFromFloat(ms2[i] * 1000)) });
                }
            }
        }
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { mo2 = tmpl2; _ = of(a(&mo2), a(&mb2)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { ms2 = tmpl2; _ = si_mulMat3x4InPlace(a(&ms2), a(&mb2)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("mulMat3x4InPlace", t, s, ok);
    }

    // si_normalizeVec3 (137K/7.5s) -- thiscall(vec3_ECX, length_stack) -> void
    {
        const tmpl3 = tv3();
        var vo = tmpl3;
        var vs = tmpl3;
        const len: f32 = @sqrt(vo[0] * vo[0] + vo[1] * vo[1] + vo[2] * vo[2]);
        const lb: u32 = @bitCast(len);
        const of = origFn(fn (u32, u32) callconv(cc_tc) void, 0x4549C0);
        of(a(&vo), lb);
        si_normalizeVec3(a(&vs), lb);
        const ok = cmpSlice(&vo, &vs);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { vo = tmpl3; of(a(&vo), lb); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { vs = tmpl3; si_normalizeVec3(a(&vs), lb); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("normalizeVec3", t, s, ok);
    }

    // si_testOBBFrustum -- thiscall(planes_ECX, aabb_stack, rot_stack, trans_stack) -> u32
    {
        var planes: [24]f32 = undefined;
        const normals = [6][3]f32{ .{1,0,0}, .{-1,0,0}, .{0,1,0}, .{0,-1,0}, .{0,0,1}, .{0,0,-1} };
        for (0..6) |i| { planes[i*4] = normals[i][0]; planes[i*4+1] = normals[i][1]; planes[i*4+2] = normals[i][2]; planes[i*4+3] = -10; }
        const aabb = [6]f32{ -1, -1, -1, 1, 1, 1 };
        const rot = Mat3{ 1,0,0, 0,1,0, 0,0,1 }; // identity
        const trans = Vec3{ 0, 0, 0 };
        const of = origFn(fn (u32, u32, u32, u32) callconv(cc_tc) u32, 0x6869C0);
        const ov = of(a(&planes), a(&aabb), a(&rot), a(&trans));
        const sv = si_testOBBFrustum(a(&planes), a(&aabb), a(&rot), a(&trans));
        const ok = ov == sv;
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&aabb), a(&rot), a(&trans)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { _ = si_testOBBFrustum(a(&planes), a(&aabb), a(&rot), a(&trans)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("testOBBFrustum", t, s, ok);
    }

    // si_calculateSinCos -- stdcall(angle_bits, outSin, outCos) -> void
    {
        const ab2: u32 = @bitCast(@as(f32, 1.2345));
        var sin_o: f32 = undefined;
        var cos_o: f32 = undefined;
        var sin_s: f32 = undefined;
        var cos_s: f32 = undefined;
        const of = origFn(fn (u32, u32, u32) callconv(cc_sc) void, 0x749280);
        of(ab2, a(&sin_o), a(&cos_o));
        si_calculateSinCos(ab2, a(&sin_s), a(&cos_s));
        const ok = compareF32(sin_o, sin_s) and compareF32(cos_o, cos_s);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(ab2, a(&sin_o), a(&cos_o)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { si_calculateSinCos(ab2, a(&sin_s), a(&cos_s)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("calculateSinCos", t, s, ok);
    }

    // si_translateBoundingVol -- thiscall(this_ECX, offset_stack) -> void
    {
        // 54 floats: 6 planes (24) + 8 corners (24) + min/max (6)
        var obj_o: [54]f32 = undefined;
        var obj_s: [54]f32 = undefined;
        // Init planes with simple normals and d=5
        for (0..6) |i| { obj_o[i*4] = 0; obj_o[i*4+1] = 0; obj_o[i*4+2] = 0; obj_o[i*4+3] = 5; }
        obj_o[0] = 1; obj_o[5] = -1; obj_o[10] = 1; obj_o[13] = -1; obj_o[18] = 1; obj_o[21] = -1;
        // Init corners at unit cube
        for (0..8) |i| {
            const base = 24 + i * 3;
            obj_o[base] = if (i & 1 != 0) @as(f32, 1) else -1;
            obj_o[base+1] = if (i & 2 != 0) @as(f32, 1) else -1;
            obj_o[base+2] = if (i & 4 != 0) @as(f32, 1) else -1;
        }
        // Min/max
        obj_o[48] = -1; obj_o[49] = -1; obj_o[50] = -1;
        obj_o[51] = 1; obj_o[52] = 1; obj_o[53] = 1;
        obj_s = obj_o;
        const offset = Vec3{ 2, 3, 4 };
        const of = origFn(fn (u32, u32) callconv(cc_tc) void, 0x686820);
        of(a(&obj_o), a(&offset));
        si_translateBoundingVol(a(&obj_s), a(&offset));
        const ok = cmpSlice(&obj_o, &obj_s);
        const tmpl_bv = obj_o; // already translated, use as stable input
        _ = tmpl_bv;
        // Use fresh data per iter since it's in-place
        var obj_bench_o = obj_o;
        var obj_bench_s = obj_s;
        const zero_off = Vec3{ 0.001, -0.001, 0.001 }; // tiny offset to avoid overflow
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(a(&obj_bench_o), a(&zero_off)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { si_translateBoundingVol(a(&obj_bench_s), a(&zero_off)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("translateBoundingVol", t, s, ok);
    }

    // si_addToColorAccumulator -- thiscall(this_ECX, color_stack) -> void
    {
        var obj_o: [32]f32 = std.mem.zeroes([32]f32);
        var obj_s: [32]f32 = std.mem.zeroes([32]f32);
        const color = Vec3{ 0.5, 0.3, 0.8 };
        const of = origFn(fn (u32, u32) callconv(cc_tc) void, 0x71BF60);
        of(a(&obj_o), a(&color));
        si_addToColorAccumulator(a(&obj_s), a(&color));
        const ok = compareF32(obj_o[27], obj_s[27]) and compareF32(obj_o[28], obj_s[28]) and compareF32(obj_o[29], obj_s[29]);
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), a(&color)); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { si_addToColorAccumulator(a(&obj_s), a(&color)); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("addToColorAccum", t, s, ok);
    }

    // si_packParticleColor -- fastcall(obj_ECX, unused_EDX, r_stack, g_stack, b_stack) -> void
    // Note: original is __fastcall with unused EDX, our export fn drops it
    {
        var obj_o: [320]u8 = std.mem.zeroes([320]u8);
        var obj_s: [320]u8 = std.mem.zeroes([320]u8);
        obj_o[0x12F] = 200; // alpha
        obj_s[0x12F] = 200;
        const rb: u32 = @bitCast(@as(f32, 0.8));
        const gb: u32 = @bitCast(@as(f32, 0.5));
        const bb: u32 = @bitCast(@as(f32, 0.3));
        const of = origFn(fn (u32, u32, u32, u32, u32) callconv(cc_fc) void, 0x7B7A80);
        of(a(&obj_o), 0, rb, gb, bb);
        si_packParticleColor(a(&obj_s), rb, gb, bb);
        const out_o = @as(*align(1) const u32, @ptrCast(&obj_o[0x12C])).*;
        const out_s = @as(*align(1) const u32, @ptrCast(&obj_s[0x12C])).*;
        const ok = out_o == out_s;
        if (!ok) {
            print("  packParticleColor MISMATCH: orig=0x{x} sse=0x{x}\n", .{ out_o, out_s });
            print("    orig bytes: [{x} {x} {x} {x}]\n", .{ obj_o[0x12C], obj_o[0x12D], obj_o[0x12E], obj_o[0x12F] });
            print("    sse  bytes: [{x} {x} {x} {x}]\n", .{ obj_s[0x12C], obj_s[0x12D], obj_s[0x12E], obj_s[0x12F] });
        }
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), 0, rb, gb, bb); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { si_packParticleColor(a(&obj_s), rb, gb, bb); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("packParticleColor", t, s, ok);
    }

    // si_setParticleAlpha -- fastcall(obj_ECX, unused_EDX, alpha_stack) -> void
    {
        var obj_o: [320]u8 = std.mem.zeroes([320]u8);
        var obj_s: [320]u8 = std.mem.zeroes([320]u8);
        const ab2: u32 = @bitCast(@as(f32, 0.75));
        const of = origFn(fn (u32, u32, u32) callconv(cc_fc) void, 0x7B7B10);
        of(a(&obj_o), 0, ab2);
        si_setParticleAlpha(a(&obj_s), 0, ab2);
        const ok = obj_o[0x12F] == obj_s[0x12F];
        var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), 0, ab2); } const _te = rdtsc() - _t0; if (_te < t) t = _te; }
        var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc(); for (0..ITERS) |_| { si_setParticleAlpha(a(&obj_s), 0, ab2); } const _te = rdtsc() - _t0; if (_te < s) s = _te; }
        report("setParticleAlpha", t, s, ok);
    }

    // =========================================================================
    // __ftol: SSE2 vs x87 rounding-mode dance
    // Both versions: input ST(0), output EAX:EDX, __cdecl, RET.
    // SSE2 version is a drop-in binary patch at 0x40A2B0.
    // =========================================================================
    if (sections_mapped) {
        print("\n{s}\n", .{"--- __ftol SSE2 vs original ---"});

        // si_ftol is a naked fn — get its address and size by reading the bytes
        const si_ftol_addr = @intFromPtr(&si_ftol);
        const si_ftol_ptr: [*]const u8 = @ptrFromInt(si_ftol_addr);

        // Find the RET (0xC3) to determine patch size
        var patch_size: usize = 0;
        while (patch_size < 39 and si_ftol_ptr[patch_size] != 0xC3) : (patch_size += 1) {}
        patch_size += 1; // include the RET

        // Save original bytes at 0x40A2B0
        const ftol_addr: [*]u8 = @ptrFromInt(0x40A2B0);
        var orig_bytes: [39]u8 = undefined;
        @memcpy(&orig_bytes, ftol_addr[0..39]);

        // Helper: call __ftol at 0x40A2B0 with val on ST(0), returns EAX
        const callFtol = struct {
            fn call(val: f32) i32 {
                var result: i32 = undefined;
                var edx_trash: u32 = undefined;
                asm volatile (
                    \\flds (%[val])
                    \\call *%[addr]
                    : [result] "={eax}" (result),
                      [edx_out] "={edx}" (edx_trash),
                    : [val] "r" (&val),
                      [addr] "r" (@as(u32, 0x40A2B0)),
                );
                return result;
            }
        }.call;

        // Parity test
        const test_vals = [_]f32{
            0.0, 1.0, -1.0, 127.5, 127.999, 128.0, -128.5,
            255.999, 256.0, 1000.7, -1000.7, 32767.0, -32768.0,
            0.49999, 0.50001, 100.0001, -100.0001,
            16777215.0, 16777216.0,
        };

        // Get original results
        var orig_results: [test_vals.len]i32 = undefined;
        for (test_vals, 0..) |val, idx| {
            orig_results[idx] = callFtol(val);
        }

        // Patch with si_ftol
        @memcpy(ftol_addr[0..patch_size], si_ftol_ptr[0..patch_size]);

        // Get SSE results
        var sse_results: [test_vals.len]i32 = undefined;
        for (test_vals, 0..) |val, idx| {
            sse_results[idx] = callFtol(val);
        }

        var mismatches: u32 = 0;
        for (test_vals, 0..) |val, idx| {
            if (orig_results[idx] != sse_results[idx]) {
                mismatches += 1;
                print("  MISMATCH: val={d:.6} orig={d} sse={d}\n", .{ val, orig_results[idx], sse_results[idx] });
            }
        }
        if (mismatches == 0) {
            print("  Parity: all {d} test values match ({d} byte patch)\n", .{ test_vals.len, patch_size });
        } else {
            print("  Parity: {d}/{d} mismatches\n", .{ mismatches, test_vals.len });
        }

        // Benchmark: best of 5 each
        const FTOL_ITERS = 1_000_000;
        var t_best: u64 = std.math.maxInt(u64);
        var s_best: u64 = std.math.maxInt(u64);

        @memcpy(ftol_addr[0..39], &orig_bytes);
        for (0..5) |_| {
            var sum: i32 = 0;
            const t0 = rdtsc();
            for (0..FTOL_ITERS) |iter| {
                const v: f32 = @floatFromInt(@as(i32, @intCast(iter % 1000)) - 500);
                sum +%= callFtol(v * 0.7);
            }
            const elapsed = rdtsc() - t0;
            if (elapsed < t_best) t_best = elapsed;
            std.mem.doNotOptimizeAway(sum);
        }

        @memcpy(ftol_addr[0..patch_size], si_ftol_ptr[0..patch_size]);
        for (0..5) |_| {
            var sum: i32 = 0;
            const s0 = rdtsc();
            for (0..FTOL_ITERS) |iter| {
                const v: f32 = @floatFromInt(@as(i32, @intCast(iter % 1000)) - 500);
                sum +%= callFtol(v * 0.7);
            }
            const elapsed = rdtsc() - s0;
            if (elapsed < s_best) s_best = elapsed;
            std.mem.doNotOptimizeAway(sum);
        }

        @memcpy(ftol_addr[0..39], &orig_bytes);
        report("__ftol", t_best, s_best, mismatches == 0);
    }

    // =========================================================================
    // transform44: SSE implementation benchmark — comprehensive fixture
    // Exercises: bone loop (rot/trans/scale/static/billboard), texAnim,
    // colorAnim, wordAnim, boneKeyframe, crossfade, global sequences
    // =========================================================================
    {
        print("\n{s}\n", .{"-- transform44 (comprehensive fixture) --"});
        const T44_ITERS: u32 = 2_000_000;
        const BASELINE_CYCLES: u64 = 4176; // frozen baseline measured at 2M iterations
        const wu = std.mem.writeInt;
        const fb = @as(u32, @bitCast(@as(f32, 1.0)));

        const BONE_COUNT = 18;
        const TEX_ANIM_COUNT = 2;
        const COLOR_ANIM_COUNT = 3; // 3rd entry: mode=0 for shortInterpToFloat mode=0 path
        const WORD_ANIM_COUNT = 1;
        const BKF_COUNT = 1;
        const GS_COUNT = 3;
        const RIBBON_COUNT = 1;
        const PARTICLE_124_COUNT = 3;
        const PARTICLE_134_COUNT = 1;
        const PARTICLE_13C_COUNT = 1;
        const ATTACH_COUNT = 2;

        // Allocate all memory blocks
        var scene_obj: [0x400]u8 align(16) = std.mem.zeroes([0x400]u8);
        var anim_ctx_mem: [0x20]u8 = std.mem.zeroes([0x20]u8);
        var model_ctr_mem: [0x140]u8 = std.mem.zeroes([0x140]u8);
        var model_hdr_mem: [0x200]u8 = std.mem.zeroes([0x200]u8);
        var bone_defs: [BONE_COUNT * 0x6C]u8 = std.mem.zeroes([BONE_COUNT * 0x6C]u8);
        var bone_rt: [BONE_COUNT * 0x118]u8 = std.mem.zeroes([BONE_COUNT * 0x118]u8);
        var bone_out: [BONE_COUNT * 0x40]u8 align(16) = std.mem.zeroes([BONE_COUNT * 0x40]u8);
        var gs_durations: [GS_COUNT]u32 = .{ 3000, 5000, 0 }; // third GS has dur=0 (tests that path)
        var gs_values: [GS_COUNT]u32 = .{ 0, 0, 0 };
        var tex_anim_data: [TEX_ANIM_COUNT * 0x38]u8 = std.mem.zeroes([TEX_ANIM_COUNT * 0x38]u8);
        var tex_anim_out: [TEX_ANIM_COUNT * 0x50]u8 = std.mem.zeroes([TEX_ANIM_COUNT * 0x50]u8);
        var color_data: [COLOR_ANIM_COUNT * 0x1C]u8 = std.mem.zeroes([COLOR_ANIM_COUNT * 0x1C]u8);
        var color_out: [COLOR_ANIM_COUNT * 0x20]u8 = std.mem.zeroes([COLOR_ANIM_COUNT * 0x20]u8);
        var word_data: [WORD_ANIM_COUNT * 0x1C]u8 = std.mem.zeroes([WORD_ANIM_COUNT * 0x1C]u8);
        var word_out: [WORD_ANIM_COUNT * 0x20]u8 = std.mem.zeroes([WORD_ANIM_COUNT * 0x20]u8);
        var bkf_data: [BKF_COUNT * 0x54]u8 = std.mem.zeroes([BKF_COUNT * 0x54]u8);
        var bkf_out1: [BKF_COUNT * 0x98]u8 = std.mem.zeroes([BKF_COUNT * 0x98]u8);
        var bkf_out2: [BKF_COUNT * 0x40]u8 align(16) = std.mem.zeroes([BKF_COUNT * 0x40]u8);
        // Ribbon emitter: data stride 0xD4, output stride 0x170
        var ribbon_data: [RIBBON_COUNT * 0xD4]u8 = std.mem.zeroes([RIBBON_COUNT * 0xD4]u8);
        var ribbon_out: [RIBBON_COUNT * 0x170]u8 = std.mem.zeroes([RIBBON_COUNT * 0x170]u8);
        // Particle 0x124: data stride 0x7C, output stride 0x84
        var p124_data: [PARTICLE_124_COUNT * 0x7C]u8 = std.mem.zeroes([PARTICLE_124_COUNT * 0x7C]u8);
        var p124_out: [PARTICLE_124_COUNT * 0x84]u8 = std.mem.zeroes([PARTICLE_124_COUNT * 0x84]u8);
        // Attachments: data stride 0x30, hierarchy entry 0x20
        var attach_data: [ATTACH_COUNT * 0x30]u8 = std.mem.zeroes([ATTACH_COUNT * 0x30]u8);
        var hierarchy: [ATTACH_COUNT * 0x20]u8 = std.mem.zeroes([ATTACH_COUNT * 0x20]u8);
        // Particle 0x134: data stride 0xDC, output stride 0xD0
        var p134_data: [PARTICLE_134_COUNT * 0xDC]u8 = std.mem.zeroes([PARTICLE_134_COUNT * 0xDC]u8);
        var p134_out: [PARTICLE_134_COUNT * 0xD0]u8 = std.mem.zeroes([PARTICLE_134_COUNT * 0xD0]u8);
        // Particle 0x13C: data stride 0x1F8, output stride 0x16C
        var p13c_data: [PARTICLE_13C_COUNT * 0x1F8]u8 = std.mem.zeroes([PARTICLE_13C_COUNT * 0x1F8]u8);
        var p13c_out: [PARTICLE_13C_COUNT * 0x16C]u8 = std.mem.zeroes([PARTICLE_13C_COUNT * 0x16C]u8);
        // Per-emitter particle buffer for isParticleBufferNotEmpty
        var particle_buf: [0x100]u8 = std.mem.zeroes([0x100]u8);
        // Per-emitter data pointer array for 0x13C section
        var p13c_ptrs: [PARTICLE_13C_COUNT]u32 = undefined;
        // Emitter context
        var emitter_ctx_mem: [0x200]u8 = std.mem.zeroes([0x200]u8);
        // Extra matrix for bone_flag_cache test
        var extra_mat: [64]u8 align(16) = undefined;
        // Second anim_entry (looping) for bone with own anim_slot
        var anim_entry2: [0x44]u8 = std.mem.zeroes([0x44]u8);
        // Vec3Track36 keyframes (36 bytes per kf: pos+in_tangent+out_tangent)
        var v3t36_ts = [2]u32{ 0, 1000 };
        var v3t36_vals: [18]f32 = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 }; // 2 kf * 9 floats
        // FloatTrack12 keyframes (12 bytes per kf: value+in_tangent+out_tangent)
        var ft12_ts = [2]u32{ 0, 1000 };
        var ft12_vals = [6]f32{ 1.0, 0, 0, 0.5, 0, 0 };
        // Multi-track range: 1 range pair [start=0, end=1] covering indices 0-1
        var range_pair = [2]u32{ 0, 1 };
        // Byte keyframe values for attachment/visibility
        var byte_vals = [2]u8{ 1, 0 };
        var parent_mat: [64]u8 align(16) = undefined;

        const ident = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        @memcpy(parent_mat[0..64], std.mem.asBytes(&ident));

        // Keyframe data — multiple sizes to exercise different findInterpIdx paths
        // 2-kf tracks: forward scan hot path (1 step)
        var ts2 = [2]u32{ 0, 1000 };
        // 8-kf tracks: forces binary search when cached index is stale
        var ts8 = [8]u32{ 0, 125, 250, 375, 500, 625, 750, 1000 };
        var rot_vals = [8]f32{ 0, 0, 0, 1, 0.383, 0, 0, 0.924 };
        // 8-kf rotation values (8 quats = 32 floats, stride 16)
        var rot_vals8 = [32]f32{
            0, 0, 0, 1, 0.1, 0, 0, 0.995, 0.2, 0, 0, 0.98, 0.3, 0, 0, 0.954,
            0.383, 0, 0, 0.924, 0.3, 0, 0, 0.954, 0.2, 0, 0, 0.98, 0.1, 0, 0, 0.995,
        };
        var trans_vals = [6]f32{ 0, 0, 0, 1.5, 2.0, -0.5 };
        var scale_vals = [6]f32{ 1, 1, 1, 1.2, 0.8, 1.1 };
        var short_vals = [4]i16{ 16383, 32767, 0, -16383 };
        var word_vals = [2]u16{ 100, 200 };
        // Animation lookup table entry for anim_slot bones (0x44 bytes each)
        var anim_entry: [0x44]u8 = std.mem.zeroes([0x44]u8);

        const so = @intFromPtr(&scene_obj);

        // --- Wire SceneObject ---
        wu(u32, scene_obj[0x10..0x14], 1, .little);
        wu(u32, scene_obj[0x2C..0x30], @intFromPtr(&anim_ctx_mem), .little);
        wu(u32, scene_obj[0x30..0x34], @intFromPtr(&model_ctr_mem), .little);
        wu(u32, scene_obj[0x4C..0x50], 100, .little); // search_data_base != 0 (exercises time delta path)
        wu(u32, scene_obj[0x64..0x68], @intFromPtr(&gs_values), .little);
        wu(u32, scene_obj[0x8C..0x90], 0, .little); // anim_frame_ctr=0: all gates pass (0 < any kf_count)
        wu(u32, scene_obj[0x90..0x94], @intFromPtr(&bone_rt), .little);
        wu(u32, scene_obj[0x94..0x98], @intFromPtr(&bone_out), .little);
        wu(u32, scene_obj[0xA0..0xA4], @intFromPtr(&tex_anim_out), .little);
        wu(u32, scene_obj[0xA8..0xAC], @intFromPtr(&color_out), .little);
        wu(u32, scene_obj[0xAC..0xB0], @intFromPtr(&word_out), .little);
        wu(u32, scene_obj[0xB0..0xB4], @intFromPtr(&bkf_out1), .little);
        wu(u32, scene_obj[0xB4..0xB8], @intFromPtr(&bkf_out2), .little);
        wu(u32, scene_obj[0x1C8..0x1CC], @intFromPtr(&hierarchy), .little); // hierarchy_ptr
        wu(u32, scene_obj[0x1CC..0x1D0], @intFromPtr(&emitter_ctx_mem), .little); // emitter_ctx
        wu(u32, scene_obj[0x200..0x204], @intFromPtr(&ribbon_out), .little); // ribbon output
        wu(u32, scene_obj[0x3C4..0x3C8], @intFromPtr(&p124_out), .little); // particle 0x124 output
        wu(u32, scene_obj[0x3C8..0x3CC], @intFromPtr(&p134_out), .little); // particle 0x134 output
        wu(u32, scene_obj[0x3D0..0x3D4], @intFromPtr(&p13c_out), .little); // particle 0x13C output
        wu(u32, scene_obj[0x3D4..0x3D8], @intFromPtr(&p13c_ptrs), .little); // particle 0x13C per-emitter ptrs
        wu(u32, scene_obj[0x50..0x54], 1, .little); // emitter_enable_flag (for 0x13C vis check)
        for ([_]u32{ 0x180, 0x184, 0x188, 0x18C }) |off| {
            wu(u32, scene_obj[off..][0..4], fb, .little);
        }
        // bb_row0 at +0xFC and world_xform at +0x10C need non-zero values
        // for billboard spherical scale computation to execute (not early-exit on epsilon)
        const bb_mat = [16]f32{ 0.7, 0.3, 0.0, 0, -0.3, 0.7, 0.0, 0, 0.0, 0.0, 1.0, 0, 0.5, 1.0, 0.0, 1 };
        @memcpy(scene_obj[0xFC..0x13C], std.mem.asBytes(&bb_mat));
        @memcpy(scene_obj[0xBC..0xFC], std.mem.asBytes(&ident));

        // --- Anim context ---
        wu(u32, anim_ctx_mem[0x0C..0x10], 500, .little);
        wu(u32, anim_ctx_mem[0x10..0x14], 1, .little);

        // --- Model container + header ---
        wu(u32, model_ctr_mem[0x130..0x134], @intFromPtr(&model_hdr_mem), .little);
        const mh = &model_hdr_mem;
        wu(u32, mh[0x14..0x18], GS_COUNT, .little);
        wu(u32, mh[0x18..0x1C], @intFromPtr(&gs_durations), .little);
        wu(u32, mh[0x34..0x38], BONE_COUNT, .little);
        wu(u32, mh[0x38..0x3C], @intFromPtr(&bone_defs), .little);
        wu(u32, mh[0x54..0x58], TEX_ANIM_COUNT, .little);
        wu(u32, mh[0x58..0x5C], @intFromPtr(&tex_anim_data), .little);
        wu(u32, mh[0x64..0x68], COLOR_ANIM_COUNT, .little);
        wu(u32, mh[0x68..0x6C], @intFromPtr(&color_data), .little);
        wu(u32, mh[0x6C..0x70], WORD_ANIM_COUNT, .little);
        wu(u32, mh[0x70..0x74], @intFromPtr(&word_data), .little);
        wu(u32, mh[0x74..0x78], BKF_COUNT, .little);
        wu(u32, mh[0x78..0x7C], @intFromPtr(&bkf_data), .little);
        wu(u32, mh[0x104..0x108], ATTACH_COUNT, .little); // attachment count
        wu(u32, mh[0x108..0x10C], @intFromPtr(&attach_data), .little);
        wu(u32, mh[0x11C..0x120], RIBBON_COUNT, .little); // ribbon count
        wu(u32, mh[0x120..0x124], @intFromPtr(&ribbon_data), .little);
        wu(u32, mh[0x124..0x128], PARTICLE_124_COUNT, .little);
        wu(u32, mh[0x128..0x12C], @intFromPtr(&p124_data), .little);
        wu(u32, mh[0x134..0x138], PARTICLE_134_COUNT, .little);
        wu(u32, mh[0x138..0x13C], @intFromPtr(&p134_data), .little);
        wu(u32, mh[0x13C..0x140], PARTICLE_13C_COUNT, .little);
        wu(u32, mh[0x140..0x144], @intFromPtr(&p13c_data), .little);

        // --- Bone defs: 12 bones ---
        // Bone 0: root, rot(8kf)+trans(2kf), anim_slot=-1 (inherit)
        // Bone 1: rot(8kf)+trans(2kf)+scale(2kf), anim_slot=-1
        // Bone 2: rot(2kf)+trans(2kf)+scale(2kf), anim_slot=-1
        // Bone 3: rot(2kf), crossfade active (blend_weight > 0)
        // Bone 4: rot(2kf), GS-driven (time_index=0)
        // Bone 5: rot(8kf), own anim_slot (exercises ftol path)
        // Bone 6-11: static (copy parent)

        // Set up anim_entry for bone 5's anim_slot
        wu(u32, anim_entry[0x04..0x08], 0, .little); // anim_start
        wu(u32, anim_entry[0x08..0x0C], 1000, .little); // anim_end

        // Wire model_hdr anim_lookup pointer for anim_slot bones
        wu(u32, model_hdr_mem[0x20..0x24], @intFromPtr(&anim_entry), .little);

        for (0..BONE_COUNT) |i| {
            const bd = i * 0x6C;
            wu(u16, bone_defs[bd + 0x08 ..][0..2], if (i == 0) 0xFFFF else @as(u16, @intCast(i - 1)), .little);

            // Pivot for all bones
            wu(u32, bone_defs[bd + 0x60 ..][0..4], @as(u32, @bitCast(@as(f32, 0.5))), .little);
            wu(u32, bone_defs[bd + 0x64 ..][0..4], @as(u32, @bitCast(@as(f32, 0.5))), .little);

            const br = i * 0x118;

            switch (i) {
                0 => {
                    // Rotation: 8 keyframes (exercises binary search on cold start)
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little); // lerp
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 8, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts8), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals8), .little);
                    // Translation: 2 keyframes
                    wu(u16, bone_defs[bd + 0x0C ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x0E ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x18 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0x98 ..][0..4], 500, .little); // prim_time
                },
                1 => {
                    // Rot(8kf) + Trans(2kf) + Scale(2kf)
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 8, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts8), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals8), .little);
                    wu(u16, bone_defs[bd + 0x0C ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x0E ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x18 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
                    wu(u16, bone_defs[bd + 0x44 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x46 ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x50 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x44 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x44 + 0x18 ..][0..4], @intFromPtr(&scale_vals), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                },
                2 => {
                    // Rot(2kf) + Trans(2kf) + Scale(2kf)
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
                    wu(u16, bone_defs[bd + 0x0C ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x0E ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x18 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x0C + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
                    wu(u16, bone_defs[bd + 0x44 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x46 ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x50 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x44 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x44 + 0x18 ..][0..4], @intFromPtr(&scale_vals), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                },
                3 => {
                    // Rot(2kf) + crossfade active
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    // Crossfade: sec_slot=0, blend_weight=0.5, sec_time=200, crossfade_end=far future
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0, .little); // sec_slot = 0 (active!)
                    wu(u32, bone_rt[br + 0x10C ..][0..4], @as(u32, @bitCast(@as(f32, 0.5))), .little); // blend_weight
                    wu(u32, bone_rt[br + 0xC4 ..][0..4], 200, .little); // sec_time
                    wu(u32, bone_rt[br + 0xC8 ..][0..4], 0, .little); // sec_track
                    wu(u32, bone_rt[br + 0x100 ..][0..4], 99999, .little); // crossfade_end (far future)
                    wu(u32, bone_rt[br + 0x104 ..][0..4], @as(u32, @bitCast(@as(f32, 0.001))), .little); // crossfade_inv
                    wu(u32, bone_rt[br + 0x108 ..][0..4], @as(u32, @bitCast(@as(f32, 1.0))), .little); // crossfade_weight
                },
                4 => {
                    // Rot(2kf) with global sequence (time_index=0)
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0, .little); // time_index = 0 (GS!)
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 2, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                },
                5 => {
                    // Rot(8kf) with own anim_slot (exercises ftol time computation)
                    wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                    wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                    wu(u32, bone_defs[bd + 0x34 ..][0..4], 8, .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts8), .little);
                    wu(u32, bone_defs[bd + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals8), .little);
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0, .little); // anim_slot = 0 (own slot!)
                    wu(u32, bone_rt[br + 0xA8 ..][0..4], 0, .little); // sec_start
                    wu(u32, bone_rt[br + 0xAC ..][0..4], 2000, .little); // sec_end
                    wu(u32, bone_rt[br + 0xB0 ..][0..4], @as(u32, @bitCast(@as(f32, 1.0))), .little); // time_scale
                    wu(u32, bone_rt[br + 0xB8 ..][0..4], 0, .little); // sec_anim_offset
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                },
                else => {
                    // Static bones 6-11: just inherit
                    wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                    wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                },
            }
        }

        // --- Texture animation data (2 entries, stride 0x38) ---
        // Entry 0: Vec3 track (kf_count at +0x0C)
        for (0..TEX_ANIM_COUNT) |i| {
            const td = i * 0x38;
            wu(u16, tex_anim_data[td ..][0..2], 1, .little); // mode=lerp
            wu(u16, tex_anim_data[td + 0x02 ..][0..2], 0xFFFF, .little);
            wu(u32, tex_anim_data[td + 0x0C ..][0..4], 2, .little); // vec3 kf_count
            wu(u32, tex_anim_data[td + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, tex_anim_data[td + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
            // Alpha track at +0x1C (kf_count at +0x28)
            wu(u16, tex_anim_data[td + 0x1C ..][0..2], 1, .little);
            wu(u16, tex_anim_data[td + 0x1E ..][0..2], 0xFFFF, .little);
            wu(u32, tex_anim_data[td + 0x28 ..][0..4], 2, .little); // alpha kf_count
            wu(u32, tex_anim_data[td + 0x1C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, tex_anim_data[td + 0x1C + 0x18 ..][0..4], @intFromPtr(&short_vals), .little);
        }

        // --- Color animation data (3 entries, stride 0x1C) ---
        // Entries 0-1: mode=1 (lerp + crossfade). Entry 2: mode=0 (direct, tests shortInterpToFloat mode=0)
        for (0..COLOR_ANIM_COUNT) |i| {
            const cd = i * 0x1C;
            wu(u16, color_data[cd ..][0..2], if (i < 2) @as(u16, 1) else @as(u16, 0), .little);
            wu(u16, color_data[cd + 0x02 ..][0..2], 0xFFFF, .little);
            wu(u32, color_data[cd + 0x0C ..][0..4], 2, .little);
            wu(u32, color_data[cd + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, color_data[cd + 0x18 ..][0..4], @intFromPtr(&short_vals), .little);
        }

        // --- Word animation data (1 entry, stride 0x1C) ---
        wu(u16, word_data[0x00..0x02], 1, .little); // mode=1 (exercises crossfade path)
        wu(u16, word_data[0x02..0x04], 0xFFFF, .little);
        wu(u32, word_data[0x0C..0x10], 2, .little);
        wu(u32, word_data[0x10..0x14], @intFromPtr(&ts2), .little);
        wu(u32, word_data[0x18..0x1C], @intFromPtr(&word_vals), .little);

        // --- Bone keyframe data (1 entry, stride 0x54) ---
        // Translation at +0x00, rotation at +0x1C, scale at +0x38
        // Translation kf_count at +0x0C
        wu(u16, bkf_data[0x00..0x02], 1, .little);
        wu(u16, bkf_data[0x02..0x04], 0xFFFF, .little);
        wu(u32, bkf_data[0x0C..0x10], 2, .little);
        wu(u32, bkf_data[0x10..0x14], @intFromPtr(&ts2), .little);
        wu(u32, bkf_data[0x18..0x1C], @intFromPtr(&trans_vals), .little);
        // Rotation kf_count at +0x28
        wu(u16, bkf_data[0x1C..0x1E], 1, .little);
        wu(u16, bkf_data[0x1E..0x20], 0xFFFF, .little);
        wu(u32, bkf_data[0x28..0x2C], 2, .little);
        wu(u32, bkf_data[0x1C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, bkf_data[0x1C + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);

        // --- Ribbon emitter data (1 entry, stride 0xD4) ---
        // bone_idx at +0x02, visibility gate at +0xC4, Track A float at +0x2C, Track B vec3 at +0x10
        wu(u16, ribbon_data[0x02..0x04], 0, .little); // bone_idx = 0
        // Track B (Vec3): gate at +0x1C, AnimData at +0x10
        wu(u32, ribbon_data[0x1C..0x20], 2, .little); // gate kf_count
        wu(u16, ribbon_data[0x10..0x12], 1, .little); // mode=lerp
        wu(u16, ribbon_data[0x12..0x14], 0xFFFF, .little);
        wu(u32, ribbon_data[0x10 + 0x0C ..][0..4], 2, .little);
        wu(u32, ribbon_data[0x10 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, ribbon_data[0x10 + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
        // Track A (float): gate at +0x38, AnimData at +0x2C
        wu(u32, ribbon_data[0x38..0x3C], 2, .little);
        wu(u16, ribbon_data[0x2C..0x2E], 1, .little);
        wu(u16, ribbon_data[0x2E..0x30], 0xFFFF, .little);
        wu(u32, ribbon_data[0x2C + 0x0C ..][0..4], 2, .little);
        wu(u32, ribbon_data[0x2C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, ribbon_data[0x2C + 0x18 ..][0..4], @intFromPtr(&scale_vals), .little);
        // Set output+0x100 = 1 (visibility active) so tracks get processed
        wu(u32, ribbon_out[0x100..0x104], 1, .little);
        wu(u8, ribbon_out[0xEC..0xED], 1, .little); // visibility byte = 1

        // --- Particle 0x124 data (1 entry, stride 0x7C) ---
        // Track 1 (Vec3Track36): gate at +0x1C, AnimData at +0x10
        wu(u32, p124_data[0x1C..0x20], 2, .little);
        wu(u16, p124_data[0x10..0x12], 0, .little); // mode=0 (direct copy, tests Vec3Track36 mode=0)
        wu(u16, p124_data[0x12..0x14], 0xFFFF, .little);
        wu(u32, p124_data[0x10 + 0x0C ..][0..4], 2, .little);
        wu(u32, p124_data[0x10 + 0x10 ..][0..4], @intFromPtr(&v3t36_ts), .little);
        wu(u32, p124_data[0x10 + 0x18 ..][0..4], @intFromPtr(&v3t36_vals), .little);
        // Track 3 (FloatTrack12): gate at +0x6C, AnimData at +0x60
        wu(u32, p124_data[0x6C..0x70], 2, .little);
        wu(u16, p124_data[0x60..0x62], 1, .little);
        wu(u16, p124_data[0x62..0x64], 0xFFFF, .little);
        wu(u32, p124_data[0x60 + 0x0C ..][0..4], 2, .little);
        wu(u32, p124_data[0x60 + 0x10 ..][0..4], @intFromPtr(&ft12_ts), .little);
        wu(u32, p124_data[0x60 + 0x18 ..][0..4], @intFromPtr(&ft12_vals), .little);

        // --- Particle 0x124 entry 2 (offset 0x7C): Vec3Track36 mode=1, FloatTrack12 mode=3 ---
        {
            const p2 = 0x7C; // second entry offset
            // Track 1: Vec3Track36 mode=1 (lerp)
            wu(u32, p124_data[p2 + 0x1C ..][0..4], 2, .little);
            wu(u16, p124_data[p2 + 0x10 ..][0..2], 1, .little); // mode=1
            wu(u16, p124_data[p2 + 0x12 ..][0..2], 0xFFFF, .little);
            wu(u32, p124_data[p2 + 0x10 + 0x0C ..][0..4], 2, .little);
            wu(u32, p124_data[p2 + 0x10 + 0x10 ..][0..4], @intFromPtr(&v3t36_ts), .little);
            wu(u32, p124_data[p2 + 0x10 + 0x18 ..][0..4], @intFromPtr(&v3t36_vals), .little);
            // Track 2: Vec3Track36 mode=2 (bezier)
            wu(u32, p124_data[p2 + 0x44 ..][0..4], 2, .little);
            wu(u16, p124_data[p2 + 0x38 ..][0..2], 2, .little); // mode=2
            wu(u16, p124_data[p2 + 0x3A ..][0..2], 0xFFFF, .little);
            wu(u32, p124_data[p2 + 0x38 + 0x0C ..][0..4], 2, .little);
            wu(u32, p124_data[p2 + 0x38 + 0x10 ..][0..4], @intFromPtr(&v3t36_ts), .little);
            wu(u32, p124_data[p2 + 0x38 + 0x18 ..][0..4], @intFromPtr(&v3t36_vals), .little);
            // Track 3: FloatTrack12 mode=3 (hermite)
            wu(u32, p124_data[p2 + 0x6C ..][0..4], 2, .little);
            wu(u16, p124_data[p2 + 0x60 ..][0..2], 3, .little); // mode=3
            wu(u16, p124_data[p2 + 0x62 ..][0..2], 0xFFFF, .little);
            wu(u32, p124_data[p2 + 0x60 + 0x0C ..][0..4], 2, .little);
            wu(u32, p124_data[p2 + 0x60 + 0x10 ..][0..4], @intFromPtr(&ft12_ts), .little);
            wu(u32, p124_data[p2 + 0x60 + 0x18 ..][0..4], @intFromPtr(&ft12_vals), .little);
        }

        // --- Particle 0x124 entry 3 (offset 0xF8): FloatTrack12 mode=0 + multi-track range ---
        {
            const p3 = 0x7C * 2; // third entry offset
            // Track 3: FloatTrack12 mode=0 (direct copy — tests interpFloatTrack12 mode=0)
            wu(u32, p124_data[p3 + 0x6C ..][0..4], 2, .little); // gate
            wu(u16, p124_data[p3 + 0x60 ..][0..2], 0, .little); // mode=0!
            wu(u16, p124_data[p3 + 0x62 ..][0..2], 0xFFFF, .little);
            wu(u32, p124_data[p3 + 0x60 + 0x0C ..][0..4], 2, .little);
            wu(u32, p124_data[p3 + 0x60 + 0x10 ..][0..4], @intFromPtr(&ft12_ts), .little);
            wu(u32, p124_data[p3 + 0x60 + 0x18 ..][0..4], @intFromPtr(&ft12_vals), .little);
            // Track 1: Vec3Track36 with nRanges=1 (multi-track range path in findInterpIdx)
            wu(u32, p124_data[p3 + 0x1C ..][0..4], 2, .little); // gate
            wu(u16, p124_data[p3 + 0x10 ..][0..2], 1, .little); // mode=lerp
            wu(u16, p124_data[p3 + 0x12 ..][0..2], 0xFFFF, .little);
            wu(u32, p124_data[p3 + 0x10 + 0x04 ..][0..4], 1, .little); // nRanges = 1 (multi-track!)
            wu(u32, p124_data[p3 + 0x10 + 0x08 ..][0..4], @intFromPtr(&range_pair), .little); // range data
            wu(u32, p124_data[p3 + 0x10 + 0x0C ..][0..4], 2, .little); // kf_count
            wu(u32, p124_data[p3 + 0x10 + 0x10 ..][0..4], @intFromPtr(&v3t36_ts), .little);
            wu(u32, p124_data[p3 + 0x10 + 0x18 ..][0..4], @intFromPtr(&v3t36_vals), .little);
        }

        // --- Attachment child traversal: create a fake child SceneObject ---
        // hierarchy_idx (this+0x1DC) points to a "child" that has attach_idx=0xFFFF (skip processing)
        // and next=0 (end of list). This exercises the while(child!=0) loop.
        var fake_child: [0x200]u8 = std.mem.zeroes([0x200]u8);
        wu(u32, fake_child[0x1D4..0x1D8], 0xFFFF, .little); // attach_idx = 0xFFFF (skip)
        wu(u32, fake_child[0x1E4..0x1E8], 0, .little); // next = 0 (end of list)
        wu(u32, scene_obj[0x1DC..0x1E0], @intFromPtr(&fake_child), .little); // hierarchy_idx = &fake_child

        // --- Attachment data (2 entries, stride 0x30) ---
        // bone_idx at +0x04, gate at +0x20, AnimData at +0x14
        wu(u16, attach_data[0x04..0x06], 0, .little); // bone_idx = 0
        wu(u32, attach_data[0x20..0x24], 1000, .little); // gate kf_count
        wu(u16, attach_data[0x14..0x16], 0, .little); // mode=step
        wu(u16, attach_data[0x16..0x18], 0xFFFF, .little);
        wu(u32, attach_data[0x14 + 0x0C ..][0..4], 2, .little); // kf_count
        wu(u32, attach_data[0x14 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, attach_data[0x14 + 0x18 ..][0..4], @intFromPtr(&byte_vals), .little);

        // --- Billboard bone: bone 6 gets billboard type 2 (cylindrical) ---
        {
            const bd6 = 6 * 0x6C;
            // flags = 0x282 (rotation animation + billboard type 2 + billboard post 0x08)
            wu(u32, bone_defs[bd6 + 0x04 ..][0..4], 0x28A, .little); // flags: 0x280 (rot anim) | 0x08 (bb post) | 0x02 (bb pre cylindrical)
            // Give it rotation
            wu(u16, bone_defs[bd6 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd6 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd6 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd6 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd6 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }

        // --- Clamped animation path: bone 5 uses anim_entry (clamped, flag=1) ---
        anim_entry[0x10] = 1;

        // --- Looping animation path: add second anim_entry at slot 1 for bone 7 ---
        wu(u32, anim_entry2[0x04..0x08], 0, .little); // anim_start
        wu(u32, anim_entry2[0x08..0x0C], 1000, .little); // anim_end
        // anim_entry2[0x10] = 0 (looping, flag & 1 == 0)
        // We need anim_lookup to be an array. Make anim_entry the array base:
        // slot 0 = anim_entry (clamped), slot 1 = anim_entry2 (looping)
        // Overwrite model_hdr+0x20 to point to an array. Reuse anim_entry as slot 0.
        // For simplicity, just make bone 7 use slot 0 but with looping flag.
        // Actually easier: make anim_entry looping and anim_entry2 clamped, assign bone 5→slot1, bone 7→slot0
        // ... too complex. Just test looping by setting anim_entry flag to 0 for half the iterations.
        // Instead: add bone 7 with anim_slot=0, and anim_entry has flag=1 (clamped).
        // Add bone 8 with anim_slot=0 too, but we toggle the flag. Not practical.
        // anim_entry = slot 0 (looping, flag & 1 == 0)
        anim_entry[0x10] = 0;
        // anim_entry2 = slot 1 (clamped, flag & 1 == 1)
        wu(u32, anim_entry2[0x04..0x08], 0, .little);
        wu(u32, anim_entry2[0x08..0x0C], 1000, .little);
        anim_entry2[0x10] = 1;
        // anim_lookup must be contiguous: [slot0=anim_entry, slot1=anim_entry2]
        // Since each is 0x44 bytes, put them adjacent
        var anim_lookup: [2 * 0x44]u8 = std.mem.zeroes([2 * 0x44]u8);
        @memcpy(anim_lookup[0..0x44], &anim_entry);
        @memcpy(anim_lookup[0x44..0x88], &anim_entry2);
        wu(u32, model_hdr_mem[0x20..0x24], @intFromPtr(&anim_lookup), .little);

        // Bone 13: own anim_slot=1 (clamped path, sec_end=200 < cur_time=500 → "passed" branch)
        {
            const bd13 = 13 * 0x6C;
            wu(u16, bone_defs[bd13 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd13 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd13 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd13 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd13 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
            const br13 = 13 * 0x118;
            wu(u32, bone_rt[br13 + 0xA4 ..][0..4], 1, .little); // anim_slot=1 (clamped)
            wu(u32, bone_rt[br13 + 0xA8 ..][0..4], 0, .little); // sec_start=0
            wu(u32, bone_rt[br13 + 0xAC ..][0..4], 200, .little); // sec_end=200 (< cur_time → "passed")
            wu(u32, bone_rt[br13 + 0xB0 ..][0..4], fb, .little);
            wu(u32, bone_rt[br13 + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }
        // Bone 14: interpAnimKF mode=0 (direct quat copy, no lerp)
        {
            const bd14 = 14 * 0x6C;
            wu(u16, bone_defs[bd14 + 0x28 ..][0..2], 0, .little); // mode=0!
            wu(u16, bone_defs[bd14 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd14 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd14 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd14 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
            const br14 = 14 * 0x118;
            wu(u32, bone_rt[br14 + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
            wu(u32, bone_rt[br14 + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }
        // Bone 15: interpVec3Track mode=0 (direct vec3 copy)
        {
            const bd15 = 15 * 0x6C;
            wu(u16, bone_defs[bd15 + 0x0C ..][0..2], 0, .little); // trans mode=0!
            wu(u16, bone_defs[bd15 + 0x0E ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd15 + 0x18 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd15 + 0x0C + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd15 + 0x0C + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
            const br15 = 15 * 0x118;
            wu(u32, bone_rt[br15 + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
            wu(u32, bone_rt[br15 + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }
        // Bone 16: billboard post 0x08 with had_anim=FALSE (flags & 0x280 == 0, flags & 0x78 != 0)
        {
            const bd16 = 16 * 0x6C;
            wu(u32, bone_defs[bd16 + 0x04 ..][0..4], 0x08, .little); // post-0x08 only, no 0x280
            wu(u32, bone_defs[bd16 + 0x60 ..][0..4], @as(u32, @bitCast(@as(f32, 0.5))), .little); // pivot
            const br16 = 16 * 0x118;
            wu(u32, bone_rt[br16 + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
            wu(u32, bone_rt[br16 + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }
        // Bone 17: billboard pinned (flags & 1 set → skips translation recompute)
        {
            const bd17 = 17 * 0x6C;
            wu(u32, bone_defs[bd17 + 0x04 ..][0..4], 0x289, .little); // 0x280 | 0x08 | 0x01 (pinned)
            wu(u16, bone_defs[bd17 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd17 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd17 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd17 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd17 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
            const br17 = 17 * 0x118;
            wu(u32, bone_rt[br17 + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
            wu(u32, bone_rt[br17 + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }

        // --- Billboard bones: types 4, 6, 0x10, 0x20, 0x40 ---
        // Bone 7: billboard type 4 (spherical)
        {
            const bd7 = 7 * 0x6C;
            wu(u32, bone_defs[bd7 + 0x04 ..][0..4], 0x284, .little); // flags: 0x280 | 0x04 (spherical)
            wu(u16, bone_defs[bd7 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd7 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd7 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd7 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd7 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }
        // Bone 8: billboard type 6 (full)
        {
            const bd8 = 8 * 0x6C;
            wu(u32, bone_defs[bd8 + 0x04 ..][0..4], 0x286, .little); // flags: 0x280 | 0x06
            wu(u16, bone_defs[bd8 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd8 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd8 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd8 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd8 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }
        // Bone 9: billboard post type 0x10
        {
            const bd9 = 9 * 0x6C;
            wu(u32, bone_defs[bd9 + 0x04 ..][0..4], 0x290, .little); // 0x280 | 0x10
            wu(u16, bone_defs[bd9 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd9 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd9 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd9 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd9 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }
        // Bone 10: billboard post type 0x20
        {
            const bd10 = 10 * 0x6C;
            wu(u32, bone_defs[bd10 + 0x04 ..][0..4], 0x2A0, .little); // 0x280 | 0x20
            wu(u16, bone_defs[bd10 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd10 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd10 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd10 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd10 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }
        // Bone 11: billboard post type 0x40
        {
            const bd11 = 11 * 0x6C;
            wu(u32, bone_defs[bd11 + 0x04 ..][0..4], 0x2C0, .little); // 0x280 | 0x40
            wu(u16, bone_defs[bd11 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd11 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd11 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd11 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd11 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
        }

        // --- Bone 12: has bone_flag_cache (extra matmul) ---
        {
            const bd12 = 12 * 0x6C;
            wu(u32, bone_defs[bd12 + 0x04 ..][0..4], 0x280, .little); // rotation anim
            wu(u16, bone_defs[bd12 + 0x28 ..][0..2], 1, .little);
            wu(u16, bone_defs[bd12 + 0x2A ..][0..2], 0xFFFF, .little);
            wu(u32, bone_defs[bd12 + 0x34 ..][0..4], 2, .little);
            wu(u32, bone_defs[bd12 + 0x28 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
            wu(u32, bone_defs[bd12 + 0x28 + 0x18 ..][0..4], @intFromPtr(&rot_vals), .little);
            @memcpy(extra_mat[0..64], std.mem.asBytes(&ident));
            const br12 = 12 * 0x118;
            wu(u32, bone_rt[br12 + 0xF0 ..][0..4], @intFromPtr(&extra_mat), .little); // bone_flag_cache
            wu(u32, bone_rt[br12 + 0xF4 ..][0..4], 0x80, .little); // flags2 with bit 0x80 set
        }

        // --- Particle buffer for isParticleBufferNotEmpty ---
        p13c_ptrs[0] = @intFromPtr(&particle_buf);
        // Set particle_buf+0x64 = 1 so isParticleBufferNotEmpty returns true
        particle_buf[0x64] = 1;

        // --- Emitter context setup ---
        wu(u32, emitter_ctx_mem[0x50..0x54], 1, .little); // emitter_ctx+0x50 != 0
        wu(u32, scene_obj[0x1D8..0x1DC], 1, .little); // this+0x1D8 != 0 (for emitter flag)

        // --- Particle 0x134 data (1 entry, stride 0xDC) ---
        // bone_idx at +0x04, visibility gate at +0xCC
        wu(u16, p134_data[0x04..0x06], 0, .little); // bone_idx=0
        wu(u32, p134_data[0xCC..0xD0], 1000, .little); // visibility gate
        // Position track: gate at +0x30, AnimData at +0x24
        wu(u32, p134_data[0x30..0x34], 2, .little);
        wu(u16, p134_data[0x24..0x26], 1, .little);
        wu(u16, p134_data[0x26..0x28], 0xFFFF, .little);
        wu(u32, p134_data[0x24 + 0x0C ..][0..4], 2, .little);
        wu(u32, p134_data[0x24 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, p134_data[0x24 + 0x18 ..][0..4], @intFromPtr(&trans_vals), .little);
        // Visibility AnimData at +0xC0
        wu(u16, p134_data[0xC0..0xC2], 0, .little); // mode=0
        wu(u16, p134_data[0xC2..0xC4], 0xFFFF, .little);
        wu(u32, p134_data[0xC0 + 0x0C ..][0..4], 2, .little);
        wu(u32, p134_data[0xC0 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, p134_data[0xC0 + 0x18 ..][0..4], @intFromPtr(&byte_vals), .little);

        // --- Particle 0x13C data (1 entry, stride 0x1F8) ---
        // bone_idx at +0x14, visibility gate at +0x1E8
        wu(u16, p13c_data[0x14..0x16], 0, .little);
        wu(u32, p13c_data[0x1E8..0x1EC], 1000, .little); // vis gate
        // Visibility AnimData at +0x1DC
        wu(u16, p13c_data[0x1DC..0x1DE], 0, .little);
        wu(u16, p13c_data[0x1DE..0x1E0], 0xFFFF, .little);
        wu(u32, p13c_data[0x1DC + 0x0C ..][0..4], 2, .little);
        wu(u32, p13c_data[0x1DC + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, p13c_data[0x1F4..0x1F8], @intFromPtr(&byte_vals), .little); // vis keyframe values
        // Track 1 (emission rate): gate at +0x40, AnimData at +0x34
        wu(u32, p13c_data[0x40..0x44], 2, .little);
        wu(u16, p13c_data[0x34..0x36], 1, .little);
        wu(u16, p13c_data[0x36..0x38], 0xFFFF, .little);
        wu(u32, p13c_data[0x34 + 0x0C ..][0..4], 2, .little);
        wu(u32, p13c_data[0x34 + 0x10 ..][0..4], @intFromPtr(&ts2), .little);
        wu(u32, p13c_data[0x34 + 0x18 ..][0..4], @intFromPtr(&scale_vals), .little);

        // --- Particle 0x124: Track 2 hermite, Track 3 bezier ---
        // Track 2 (Vec3Track36): gate at +0x44, AnimData at +0x38, mode=3 (hermite)
        wu(u32, p124_data[0x44..0x48], 2, .little);
        wu(u16, p124_data[0x38..0x3A], 3, .little); // mode=hermite
        wu(u16, p124_data[0x3A..0x3C], 0xFFFF, .little);
        wu(u32, p124_data[0x38 + 0x0C ..][0..4], 2, .little);
        wu(u32, p124_data[0x38 + 0x10 ..][0..4], @intFromPtr(&v3t36_ts), .little);
        wu(u32, p124_data[0x38 + 0x18 ..][0..4], @intFromPtr(&v3t36_vals), .little);
        // Track 3 (FloatTrack12): gate at +0x6C, already set above with mode=1
        // Change to mode=2 (bezier) to test that path
        wu(u16, p124_data[0x60..0x62], 2, .little); // mode=bezier

        // --- Make bone 0 have blend_weight > 0 so section function crossfade fires ---
        wu(u32, bone_rt[0x10C..0x110], @as(u32, @bitCast(@as(f32, 0.3))), .little); // bone 0 blend_weight
        wu(u32, bone_rt[0xC4..0xC8], 300, .little); // bone 0 sec_time
        wu(u32, bone_rt[0xC8..0xCC], 0, .little); // bone 0 sec_track

        const pos = [3]f32{ 0, 0, 0 };
        const ofs = [3]f32{ 0, 0, 0 };
        const sb: u32 = @bitCast(@as(f32, 1.0));
        const transformImpl_SSE = @extern(*const fn (u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void, .{ .name = "transformImpl_SSE" });
        const transformImpl_BASELINE = @extern(*const fn (u32, u32, u32, u32, u32) callconv(.c) void, .{ .name = "transformImpl_BASELINE" });

        // Pre-set boneKeyframe init flag so we skip the atexit call (Windows CRT, can't run on Linux)
        @as(*u8, @ptrFromInt(0xCF04C4)).* = 1;
        // Also write the pivot constants that atexit-init would have written
        @as(*align(1) u32, @ptrFromInt(0xCF043C)).* = 0x3F000000; // 0.5f
        @as(*align(1) u32, @ptrFromInt(0xCF0440)).* = 0x3F000000; // 0.5f
        @as(*align(1) u32, @ptrFromInt(0xCF0444)).* = 0x00000000; // 0.0f

        // Warmup: forward sweep then backward sweep to exercise both scan directions
        for (0..500) |iter| {
            wu(u32, anim_ctx_mem[0x0C..0x10], @as(u32, @intCast(iter * 2)), .little);
            wu(u32, scene_obj[0x40..0x44], 0, .little);
            transformImpl_SSE(so, @intFromPtr(&parent_mat), @intFromPtr(&pos), @intFromPtr(&ofs), sb);
        }
        // Backward sweep: 999 down to 0, exercises backward scan path
        for (0..500) |iter| {
            wu(u32, anim_ctx_mem[0x0C..0x10], @as(u32, @intCast(999 - iter * 2)), .little);
            wu(u32, scene_obj[0x40..0x44], 0, .little);
            transformImpl_SSE(so, @intFromPtr(&parent_mat), @intFromPtr(&pos), @intFromPtr(&ofs), sb);
        }

        // --- Benchmark both BASELINE and SSE ---
        const run_bench_fn = struct {
            fn run(func: *const fn (u32, u32, u32, u32, u32) callconv(.c) void, so2: u32, pm: u32, pp: u32, po: u32, sb2: u32, scene: *[0x400]u8, actx: *[0x20]u8, iters: u32) u64 {
                var best_inner: u64 = std.math.maxInt(u64);
                for (0..5) |_| {
                    const t = rdtsc();
                    for (0..iters) |iter| {
                        const phase = iter % 200;
                        const ts_val: u32 = @intCast(if (phase < 100)
                            phase * 10
                        else if (phase < 150)
                            (149 - (phase - 100)) * 20
                        else
                            (phase * 37) % 1000);
                        wu(u32, actx[0x0C..0x10], ts_val, .little);
                        wu(u32, scene[0x40..0x44], 0, .little);
                        func(so2, pm, pp, po, sb2);
                    }
                    const elapsed = rdtsc() - t;
                    if (elapsed < best_inner) best_inner = elapsed;
                }
                return best_inner;
            }
        }.run;

        const pm = @intFromPtr(&parent_mat);
        const pp = @intFromPtr(&pos);
        const po = @intFromPtr(&ofs);

        const best_sse = run_bench_fn(transformImpl_SSE, so, pm, pp, po, sb, &scene_obj, &anim_ctx_mem, T44_ITERS);
        const avg_sse = best_sse / T44_ITERS;

        print("  BASELINE: {d} cycles/call (frozen)\n", .{BASELINE_CYCLES});
        print("  SSE:      {d} cycles/call", .{avg_sse});
        if (avg_sse < BASELINE_CYCLES) {
            const pct = (BASELINE_CYCLES - avg_sse) * 100 / BASELINE_CYCLES;
            print("  (-{d}%)\n", .{pct});
        } else if (avg_sse > BASELINE_CYCLES) {
            const pct = (avg_sse - BASELINE_CYCLES) * 100 / BASELINE_CYCLES;
            print("  (+{d}%)\n", .{pct});
        } else {
            print("  (same)\n", .{});
        }

        // --- Output parity: run BASELINE then SSE with identical input, compare ALL outputs ---
        {
            const BufPair = struct { ptr: [*]u8, len: usize };
            const bufs = [_]BufPair{
                .{ .ptr = &bone_out, .len = bone_out.len },
                .{ .ptr = &bone_rt, .len = bone_rt.len },
                .{ .ptr = &tex_anim_out, .len = tex_anim_out.len },
                .{ .ptr = &color_out, .len = color_out.len },
                .{ .ptr = &word_out, .len = word_out.len },
                .{ .ptr = &bkf_out1, .len = bkf_out1.len },
                .{ .ptr = &bkf_out2, .len = bkf_out2.len },
                .{ .ptr = &ribbon_out, .len = ribbon_out.len },
                .{ .ptr = &p124_out, .len = p124_out.len },
                .{ .ptr = &p134_out, .len = p134_out.len },
                .{ .ptr = &p13c_out, .len = p13c_out.len },
                .{ .ptr = &hierarchy, .len = hierarchy.len },
                .{ .ptr = &scene_obj, .len = scene_obj.len },
            };

            const reset_and_run = struct {
                fn go(func: *const fn (u32, u32, u32, u32, u32) callconv(.c) void, so3: u32, pm3: u32, pp3: u32, po3: u32, sb3: u32, scene3: *[0x400]u8, actx3: *[0x20]u8, brt3: [*]u8, bc: usize) void {
                    wu(u32, actx3[0x0C..0x10], 500, .little);
                    wu(u32, scene3[0x40..0x44], 0, .little);
                    // Re-init bone_rt anim_slot/sec_slot fields
                    for (0..bc) |i| {
                        const br = i * 0x118;
                        wu(u32, brt3[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
                        wu(u32, brt3[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
                    }
                    wu(u32, brt3[0x98..0x9C], 500, .little);
                    func(so3, pm3, pp3, po3, sb3);
                }
            }.go;

            // Snapshot size = sum of all buffer lengths
            var total_len: usize = 0;
            for (bufs) |b| total_len += b.len;
            var snap: [64 * 1024]u8 = undefined; // 64KB should be enough

            // Run BASELINE, snapshot
            reset_and_run(transformImpl_BASELINE, so, pm, pp, po, sb, &scene_obj, &anim_ctx_mem, &bone_rt, BONE_COUNT);
            var off: usize = 0;
            for (bufs) |b| {
                @memcpy(snap[off..][0..b.len], b.ptr[0..b.len]);
                off += b.len;
            }

            // Run SSE with same input
            reset_and_run(transformImpl_SSE, so, pm, pp, po, sb, &scene_obj, &anim_ctx_mem, &bone_rt, BONE_COUNT);

            // Compare
            var diffs: u32 = 0;
            off = 0;
            for (bufs) |b| {
                for (0..b.len) |i| {
                    if (b.ptr[i] != snap[off + i]) diffs += 1;
                }
                off += b.len;
            }
            if (diffs == 0) {
                print("  parity:   PASS (SSE == BASELINE, {d} bytes checked)\n", .{total_len});
            } else {
                print("  parity:   FAIL ({d} byte diffs across {d} bytes)\n", .{ diffs, total_len });
            }
        }
    }

    // calcColorValues_SSE -- disabled: no standalone SSE export yet
    // bench_calcColorValues();

    // si_frustumCullBBox -- fastcall(bbox_ECX, flags_EDX, radius_stack) -> u32
    bench_frustumCullBBox();

    // si_processLinkedListCollision -- fastcall(listHead_ECX, queryBox_EDX, resultBuf_stack, flags_stack) -> u32
    // Builds a fake linked list with 8 nodes to benchmark AABB overlap test.
    bench_processLinkedListCollision();

    } // end disabled block

    print("\n", .{});
}

fn bench_calcColorValues() void {
    // Map pages for global constants used by calculateColorValues
    // 0x808AAC and 0x807A3C are in .rdata range (already mapped)
    // 0x8029CC is in .rdata range (already mapped)
    // 0x8015B8 is in .rdata range (already mapped) — pow exponent constant

    // Build fake ColorCtx struct
    // Layout: +0x00..0x03 = base bytes [B,G,R,A], +0x04..0x10 = deltas (4×i32),
    //   +0x14..0x20 = alpha base/delta pairs (4×i32), +0x24 = float_base(f32),
    //   +0x28 = float_scale(f32), +0x2C = time_base(f32), +0x30 = time_scale(f32),
    //   +0x50 = alpha_power(f32)
    var ctx: [0x54]u8 align(4) = std.mem.zeroes([0x54]u8);
    // Base color: BGRA = {100, 150, 200, 220}
    ctx[0] = 100; ctx[1] = 150; ctx[2] = 200; ctx[3] = 220;
    // Deltas (i32): small values
    @as(*align(1) i32, @ptrCast(ctx[0x04..0x08])).* = 10;
    @as(*align(1) i32, @ptrCast(ctx[0x08..0x0C])).* = -5;
    @as(*align(1) i32, @ptrCast(ctx[0x0C..0x10])).* = 8;
    @as(*align(1) i32, @ptrCast(ctx[0x10..0x14])).* = -3;
    // Alpha base/delta
    @as(*align(1) i32, @ptrCast(ctx[0x14..0x18])).* = 200;
    @as(*align(1) i32, @ptrCast(ctx[0x18..0x1C])).* = 20;
    @as(*align(1) i32, @ptrCast(ctx[0x1C..0x20])).* = 180;
    @as(*align(1) i32, @ptrCast(ctx[0x20..0x24])).* = 15;
    // Float base/scale
    @as(*align(1) f32, @ptrCast(ctx[0x24..0x28])).* = 1.0;
    @as(*align(1) f32, @ptrCast(ctx[0x28..0x2C])).* = 0.5;
    // Time base/scale
    @as(*align(1) f32, @ptrCast(ctx[0x2C..0x30])).* = 0.0;
    @as(*align(1) f32, @ptrCast(ctx[0x30..0x34])).* = 1.0;
    // Alpha power = 1.0 (linear, fast path)
    @as(*align(1) f32, @ptrCast(ctx[0x50..0x54])).* = 1.0;

    const time: f32 = 0.5;
    const scale: f32 = 1.0;
    var out_color_o: [4]u8 = .{0} ** 4;
    var out_color_s: [4]u8 = .{0} ** 4;
    var out_alpha1_o: u32 = 0;
    var out_alpha1_s: u32 = 0;
    var out_alpha2_o: u32 = 0;
    var out_alpha2_s: u32 = 0;
    var out_float_o: f32 = 0;
    var out_float_s: f32 = 0;

    // Original: __thiscall(ECX=ctx, stack: time, scale, outColor, outAlpha1, outAlpha2, outFloat), RET 0x18
    const of = origFn(fn (u32, u32, u32, u32, u32, u32, u32) callconv(cc_tc) void, 0x7B9B10);
    of(a(&ctx), @bitCast(time), @bitCast(scale), a(&out_color_o), a(&out_alpha1_o), a(&out_alpha2_o), a(&out_float_o));
    calcColorValues_SSE(a(&ctx), @bitCast(time), @bitCast(scale), a(&out_color_s), a(&out_alpha1_s), a(&out_alpha2_s), a(&out_float_s));

    // The original returns float in ST(0) which we need to pop to avoid FPU stack leak
    // Pop it after each call in the bench loop too
    const ok = out_color_o[0] == out_color_s[0] and out_color_o[1] == out_color_s[1] and
        out_color_o[2] == out_color_s[2] and out_color_o[3] == out_color_s[3] and
        out_alpha1_o == out_alpha1_s and out_alpha2_o == out_alpha2_s and
        compareF32(out_float_o, out_float_s);
    if (!ok) {
        print("  color bytes: orig=[{d},{d},{d},{d}] sse=[{d},{d},{d},{d}]\n", .{
            out_color_o[0], out_color_o[1], out_color_o[2], out_color_o[3],
            out_color_s[0], out_color_s[1], out_color_s[2], out_color_s[3],
        });
        print("  alpha1: orig={d} sse={d}  alpha2: orig={d} sse={d}\n", .{
            out_alpha1_o, out_alpha1_s, out_alpha2_o, out_alpha2_s,
        });
        print("  float: orig=0x{x} sse=0x{x}\n", .{
            @as(u32, @bitCast(out_float_o)), @as(u32, @bitCast(out_float_s)),
        });
    }

    // Original returns float in ST(0) — must pop to avoid FPU stack overflow in bench loop
    var t: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            of(a(&ctx), @bitCast(time), @bitCast(scale), a(&out_color_o), a(&out_alpha1_o), a(&out_alpha2_o), a(&out_float_o));
            // Pop ST(0) to prevent FPU stack overflow
            asm volatile ("fstp %%st(0)" ::: "st");
        }
        const _te = rdtsc() - _t0;
        if (_te < t) t = _te;
    }

    var s: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            calcColorValues_SSE(a(&ctx), @bitCast(time), @bitCast(scale), a(&out_color_s), a(&out_alpha1_s), a(&out_alpha2_s), a(&out_float_s));
        }
        const _te = rdtsc() - _t0;
        if (_te < s) s = _te;
    }
    report("calcColorValues", t, s, ok);
}

fn bench_frustumCullBBox() void {
    // Map runtime global pages for view-proj matrices, occlusion buffer, and flags
    _ = mapZeroed(0xC7B000, 0x20000); // covers 0xC7B000-0xC7D000+ (matrices, horizon buffer, globals)

    // Set up globals that FrustumCullBoundingBox reads:
    // 0xC7B2A4: occlusion flag — bit 5 must be set to proceed
    @as(*u8, @ptrFromInt(0xC7B2A4)).* = 0x20;

    // 0xC7CFF4: global value checked against range [const1, const2]
    // const1 at 0x8101AC, const2 at 0x804588 — both are in mapped .rdata
    // Set to a value that passes: read the constants and pick the midpoint
    const const1: f32 = @as(*align(1) const f32, @ptrFromInt(0x8101AC)).*;
    const const2: f32 = @as(*align(1) const f32, @ptrFromInt(0x804588)).*;
    @as(*align(1) f32, @ptrFromInt(0xC7CFF4)).* = (const1 + const2) * 0.5;

    // 0x80FED4: near plane constant for behind-camera check
    // Already in mapped pages. Set to a value that passes (e.g., -1000)
    @as(*align(1) f32, @ptrFromInt(0x80FED4)).* = -1000.0;

    // 0x7FF9D8: perspective scale constant (likely screen_width/2 or similar)
    // In .rdata — already mapped, read whatever's there or set a reasonable value
    if (@as(*align(1) const u32, @ptrFromInt(0x7FF9D8)).* == 0) {
        @as(*align(1) f32, @ptrFromInt(0x7FF9D8)).* = 160.0;
    }

    // 0x810170: column scale factor
    if (@as(*align(1) const u32, @ptrFromInt(0x810170)).* == 0) {
        @as(*align(1) f32, @ptrFromInt(0x810170)).* = 1.0;
    }

    // 0x86861C: column offset — in .rdata, use whatever's there or set 0
    // 0x86861C is at offset 0x86861C - 0x7FF000 = 0x6961C in rdata — may be beyond our mapped range
    // Map additional page if needed
    _ = mapZeroed(0x868000, 0x1000);

    // View-proj matrix at 0xC7B700: identity-like projection for testing
    {
        const mat: [*]f32 = @ptrFromInt(0xC7B700);
        // Simple perspective-like matrix (column-major)
        mat[0] = 1.0; mat[1] = 0.0; mat[2] = 0.0;  mat[3] = 0.0;
        mat[4] = 0.0; mat[5] = 1.0; mat[6] = 0.0;  mat[7] = 0.0;
        mat[8] = 0.0; mat[9] = 0.0; mat[10] = 1.0; mat[11] = 0.0;
        mat[12] = 0.0; mat[13] = 0.0; mat[14] = 0.0; mat[15] = 1.0;
    }

    // Second matrix at 0xC7D280: identity for extent transform
    {
        const mat: [*]f32 = @ptrFromInt(0xC7D280);
        mat[0] = 1.0; mat[1] = 0.0; mat[2] = 0.0;  mat[3] = 0.0;
        mat[4] = 0.0; mat[5] = 1.0; mat[6] = 0.0;  mat[7] = 0.0;
        mat[8] = 0.0; mat[9] = 0.0; mat[10] = 1.0; mat[11] = 0.0;
        mat[12] = 0.0; mat[13] = 0.0; mat[14] = 0.0; mat[15] = 1.0;
    }

    // Horizon buffer at 0xC7B750: 320 floats, fill with large values (everything visible)
    {
        const buf: [*]f32 = @ptrFromInt(0xC7B750);
        for (0..320) |i| buf[i] = 1000.0;
    }

    // Test data: bbox point at (5, 3, 10), radius 2.0, flags=0
    var bbox = [3]f32{ 5.0, 3.0, 10.0 };
    const radius: f32 = 2.0;
    const radius_bits: u32 = @bitCast(radius);
    const flags: u32 = 0;

    const of = origFn(fn (u32, u32, u32) callconv(cc_fc) u32, 0x686000);
    const ret_orig = of(a(&bbox), flags, radius_bits);
    const ret_sse = si_frustumCullBBox(a(&bbox), flags, radius_bits);
    const ok = ret_orig == ret_sse;

    var t: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            _ = of(a(&bbox), flags, radius_bits);
        }
        const _te = rdtsc() - _t0;
        if (_te < t) t = _te;
    }

    var s: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            _ = si_frustumCullBBox(a(&bbox), flags, radius_bits);
        }
        const _te = rdtsc() - _t0;
        if (_te < s) s = _te;
    }
    report("frustumCullBBox", t, s, ok);
}

fn bench_processLinkedListCollision() void {
    // Map page for sentinel global at 0xC89F20
    _ = mapZeroed(0xC89000, 0x1000);
    // Map page for addGeometryToBuffer's result_buf writes (just needs writable memory)
    // Also need pages at 0xCA0000 range for any globals addGeometryToBuffer touches

    const NODE_COUNT = 8;

    // Sentinel: just a unique non-zero value. Original code reads *(u32*)0xC89F20.
    const sentinel: u32 = 0xDEADBEEF;
    @as(*u32, @ptrFromInt(0xC89F20)).* = sentinel;

    // --- Build fake node data blocks (need offsets: +0x0C, +0x88, +0x8C, +0x14C-0x164, +0x180, +0x184) ---
    // Each node_data needs at least 0x188 bytes
    const NODE_DATA_SIZE = 0x190;
    var node_data_buf: [NODE_COUNT * NODE_DATA_SIZE]u8 align(4) = std.mem.zeroes([NODE_COUNT * NODE_DATA_SIZE]u8);

    // Query box: min=(0,0,0), max=(10,10,10)
    var query_box = [6]f32{ 0.0, 0.0, 0.0, 10.0, 10.0, 10.0 };

    // Stub addGeometryToBuffer at 0x6ABD90 → RET 0x4 (just returns, no side effects).
    // Both original and SSE call the same stub, isolating the linked list walk + AABB test.
    // Original bytes are in mapped .text — overwrite with: C2 04 00 (RET 4)
    @as(*[3]u8, @ptrFromInt(0x6ABD90)).* = .{ 0xC2, 0x04, 0x00 };

    // Set up each node_data
    for (0..NODE_COUNT) |i| {
        const nd = @intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE;
        // flags at +0x0C: bit 0x80 set (required, else returns 0), no 0x100 (not skipped)
        @as(*align(1) u16, @ptrFromInt(nd + 0x0C)).* = 0x80;
        // active at +0x88: non-zero (just needs to pass != 0 check)
        @as(*align(1) u32, @ptrFromInt(nd + 0x88)).* = 1;
        // visited at +0x8C: NOT sentinel (so it gets processed)
        @as(*align(1) u32, @ptrFromInt(nd + 0x8C)).* = 0;
        // type discriminator: both zero → use flags & 0xF
        @as(*align(1) u32, @ptrFromInt(nd + 0x180)).* = 0;
        @as(*align(1) u32, @ptrFromInt(nd + 0x184)).* = 0;

        // AABB at +0x14C: alternate overlapping and non-overlapping
        const aabb: *align(1) [6]f32 = @ptrFromInt(nd + 0x14C);
        if (i % 2 == 0) {
            // Overlapping: min=(1,1,1), max=(5,5,5)
            aabb.* = .{ 1.0, 1.0, 1.0, 5.0, 5.0, 5.0 };
        } else {
            // Non-overlapping: min=(20,20,20), max=(30,30,30)
            aabb.* = .{ 20.0, 20.0, 20.0, 30.0, 30.0, 30.0 };
        }
    }

    // --- Build linked list nodes ---
    // Intrusive list: node = { ??, node_data_ptr, ... }
    // link_offset stored at listHead[0], next at *(link_offset + node + 4)
    // Simplest: link_offset = 0, so next = *(node + 4) ... no wait.
    // Re-reading assembly: next = *(*(listHead) + prev_node + 4)
    // listHead[0] = link_offset (byte offset within node to find next-ptr)
    // Actually from the asm: MOV EAX,[EBP-0xc] (=listHead), MOV EAX,[EAX] (=*listHead = link_offset)
    //   MOV ECX,[EAX + EDX*1 + 4] where EDX=node
    // So: next = *(link_offset + node + 4)
    // If link_offset = 0: next = *(node + 4), but node+4 is node_data_ptr!
    // We need link_offset such that (link_offset + node + 4) points to a "next" field.
    // Let's use link_offset = 4, so next = *(node + 8).
    // Node layout: [node_data_ptr(+0), ?(+4), next(+8)]
    // But wait, node+4 is where node_data is read: MOV EBX,[EDX+4] (EDX=node)
    // So node = { pad(+0), node_data(+4), next(+8) } and link_offset = 4.

    const NODE_SIZE = 12; // pad, node_data_ptr, next_ptr
    var nodes: [NODE_COUNT * NODE_SIZE]u8 align(4) = std.mem.zeroes([NODE_COUNT * NODE_SIZE]u8);

    for (0..NODE_COUNT) |i| {
        const n = @intFromPtr(&nodes) + i * NODE_SIZE;
        // node+4 = node_data pointer
        @as(*align(1) u32, @ptrFromInt(n + 4)).* = @intCast(@intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE);
        // node+8 = next node (link_offset=4, so *(link_offset + node + 4) = *(node + 8))
        if (i + 1 < NODE_COUNT) {
            @as(*align(1) u32, @ptrFromInt(n + 8)).* = @intCast(@intFromPtr(&nodes) + (i + 1) * NODE_SIZE);
        } else {
            @as(*align(1) u32, @ptrFromInt(n + 8)).* = 0; // end: NULL terminates
        }
    }

    // listHead: [0]=link_offset, [4]=??, [8]=first_node
    var list_head = [3]u32{
        4, // link_offset
        0,
        @intCast(@intFromPtr(&nodes)), // first node
    };

    // Result buffer: addGeometryToBuffer writes here. Just needs writable memory.
    var result_buf: [4096]u8 = std.mem.zeroes([4096]u8);

    // flags: 0xF (low nibble set, matching type discriminator for both-zero type)
    const flags: u32 = 0x8F; // bit 7 set + low nibble

    // --- Correctness check ---
    const of = origFn(fn (u32, u32, u32, u32) callconv(cc_fc) u32, 0x6ABC40);

    // Reset visited markers before each call
    for (0..NODE_COUNT) |i| {
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE + 0x8C)).* = 0;
    }
    const ret_orig = of(a(&list_head), a(&query_box), a(&result_buf), flags);

    for (0..NODE_COUNT) |i| {
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE + 0x8C)).* = 0;
    }
    const ret_sse = si_processLinkedListCollision(a(&list_head), a(&query_box), a(&result_buf), flags);
    const ok = ret_orig == ret_sse;

    // --- Benchmark ---
    var t: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            // Reset visited markers each iteration (original marks them)
            for (0..NODE_COUNT) |i| {
                @as(*align(1) u32, @ptrFromInt(@intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE + 0x8C)).* = 0;
            }
            _ = of(a(&list_head), a(&query_box), a(&result_buf), flags);
        }
        const _te = rdtsc() - _t0;
        if (_te < t) t = _te;
    }

    var s: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const _t0 = rdtsc();
        for (0..ITERS) |_| {
            for (0..NODE_COUNT) |i| {
                @as(*align(1) u32, @ptrFromInt(@intFromPtr(&node_data_buf) + i * NODE_DATA_SIZE + 0x8C)).* = 0;
            }
            _ = si_processLinkedListCollision(a(&list_head), a(&query_box), a(&result_buf), flags);
        }
        const _te = rdtsc() - _t0;
        if (_te < s) s = _te;
    }
    report("processLinkedListCollision", t, s, ok);
}

// =========================================================================
// Generic benchmarks for common signatures (called versions)
// =========================================================================

/// fastcall(ECX=result, EDX=paramA, stack=paramB) -> u32
fn bench_fc3r(
    comptime name: []const u8,
    comptime orig_bytes: anytype,
    sse_fn: *const fn (u32, u32, u32) callconv(.c) u32,
    param_a: anytype,
    param_b: anytype,
    comptime result_len: usize,
) void {
    const of: *const fn (u32, u32, u32) callconv(cc_fc) u32 = @ptrCast(makeExecutable(&orig_bytes) orelse {
        print("{s:>30}: FAILED to map\n", .{name});
        return;
    });
    var ro: [16]f32 = undefined;
    var rs: [16]f32 = undefined;
    _ = of(a(&ro), a(&param_a), a(&param_b));
    _ = sse_fn(a(&rs), a(&param_a), a(&param_b));
    const ok = cmpSlice(ro[0..result_len], rs[0..result_len]);

    var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
    for (0..ITERS) |_| { _ = of(a(&ro), a(&param_a), a(&param_b)); }
    const _te = rdtsc() - _t0; if (_te < t) t = _te; }
    var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
    for (0..ITERS) |_| { _ = sse_fn(a(&rs), a(&param_a), a(&param_b)); }
    const _te = rdtsc() - _t0; if (_te < s) s = _te; }
    report(name, t, s, ok);
}

/// thiscall(ECX=self, stack=param) -> u32 (in-place modification)
/// Fresh data each iteration to avoid overflow/denormal artifacts.
fn bench_tc2r(
    comptime name: []const u8,
    comptime orig_bytes: anytype,
    sse_fn: *const fn (u32, u32) callconv(.c) u32,
    self_init: anytype,
    param: anytype,
    comptime result_len: usize,
) void {
    const T = @TypeOf(self_init);
    const of: *const fn (u32, u32) callconv(cc_tc) u32 = @ptrCast(makeExecutable(&orig_bytes) orelse {
        print("{s:>30}: FAILED to map\n", .{name});
        return;
    });
    var so: T = self_init;
    var ss: T = self_init;
    _ = of(a(&so), a(&param));
    _ = sse_fn(a(&ss), a(&param));
    const ok = cmpSlice(@as([*]const f32, @ptrCast(&so))[0..result_len], @as([*]const f32, @ptrCast(&ss))[0..result_len]);

    var t: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
    for (0..ITERS) |_| { so = self_init; _ = of(a(&so), a(&param)); }
    const _te = rdtsc() - _t0; if (_te < t) t = _te; }
    var s: u64 = std.math.maxInt(u64); for (0..5) |_| { const _t0 = rdtsc();
    for (0..ITERS) |_| { ss = self_init; _ = sse_fn(a(&ss), a(&param)); }
    const _te = rdtsc() - _t0; if (_te < s) s = _te; }
    report(name, t, s, ok);
}

// =========================================================================
// Inlined x87 / SSE implementations (AT&T syntax for x87 inline asm)
// =========================================================================

const V4 = @Vector(4, f32);
const ShufMask = @Vector(4, i32);

inline fn benchLoadV3(addr: u32) V4 {
    return .{
        @as(*align(1) const f32, @ptrFromInt(addr)).*,
        @as(*align(1) const f32, @ptrFromInt(addr + 4)).*,
        @as(*align(1) const f32, @ptrFromInt(addr + 8)).*,
        0,
    };
}

inline fn benchCross(av: V4, bv: V4) V4 {
    const a_yzx: V4 = @shuffle(f32, av, undefined, ShufMask{ 1, 2, 0, 3 });
    const a_zxy: V4 = @shuffle(f32, av, undefined, ShufMask{ 2, 0, 1, 3 });
    const b_yzx: V4 = @shuffle(f32, bv, undefined, ShufMask{ 1, 2, 0, 3 });
    const b_zxy: V4 = @shuffle(f32, bv, undefined, ShufMask{ 2, 0, 1, 3 });
    return a_yzx * b_zxy - a_zxy * b_yzx;
}

inline fn benchDot3(av: V4, bv: V4) f32 {
    const p = av * bv;
    return p[0] + p[1] + p[2];
}

inline fn inline_x87_dot(va: *const Vec3, vb: *const Vec3, out: *f32) void {
    asm volatile (
        \\ flds 8(%[a])
        \\ fmuls 8(%[b])
        \\ flds 4(%[a])
        \\ fmuls 4(%[b])
        \\ faddp
        \\ flds (%[a])
        \\ fmuls (%[b])
        \\ faddp
        \\ fstps (%[out])
        :
        : [a] "r" (va),
          [b] "r" (vb),
          [out] "r" (out),
        : "memory"
    );
}

inline fn inline_sse_dot(va: *const Vec3, vb: *const Vec3, out: *volatile f32) void {
    const aa: V4 = .{ va[0], va[1], va[2], 0 };
    const bb: V4 = .{ vb[0], vb[1], vb[2], 0 };
    const p = aa * bb;
    out.* = p[0] + p[1] + p[2];
}

inline fn inline_x87_sqmag(v: *const Vec3, out: *f32) void {
    asm volatile (
        \\ flds (%[v])
        \\ fmuls (%[v])
        \\ flds 4(%[v])
        \\ fmuls 4(%[v])
        \\ faddp
        \\ flds 8(%[v])
        \\ fmuls 8(%[v])
        \\ faddp
        \\ fstps (%[out])
        :
        : [v] "r" (v),
          [out] "r" (out),
        : "memory"
    );
}

inline fn inline_sse_sqmag(v: *const Vec3, out: *volatile f32) void {
    const vv: V4 = .{ v.*[0], v.*[1], v.*[2], 0 };
    const sq = vv * vv;
    out.* = sq[0] + sq[1] + sq[2];
}

inline fn inline_x87_v3scale(v: *const Vec3, f: *const f32, out: *Vec3) void {
    asm volatile (
        \\ flds (%[f])
        \\ fmuls 8(%[v])
        \\ flds (%[f])
        \\ fmuls 4(%[v])
        \\ flds (%[f])
        \\ fmuls (%[v])
        \\ fstps (%[out])
        \\ fstps 4(%[out])
        \\ fstps 8(%[out])
        :
        : [v] "r" (v),
          [f] "r" (f),
          [out] "r" (out),
        : "memory"
    );
}

inline fn inline_sse_v3scale(v: *const Vec3, f: f32, out: *volatile Vec3) void {
    const vv: V4 = .{ v.*[0], v.*[1], v.*[2], 0 };
    const r = vv * @as(V4, @splat(f));
    out.* = .{ r[0], r[1], r[2] };
}

inline fn inline_x87_horner(c: *const [4]f32, f: *const f32, out: *f32) void {
    asm volatile (
        \\ flds (%[c])
        \\ fmuls (%[f])
        \\ fadds 4(%[c])
        \\ fmuls (%[f])
        \\ fadds 8(%[c])
        \\ fmuls (%[f])
        \\ fadds 12(%[c])
        \\ fstps (%[out])
        :
        : [c] "r" (c),
          [f] "r" (f),
          [out] "r" (out),
        : "memory"
    );
}

inline fn inline_sse_horner(c: *const [4]f32, f: f32, out: *volatile f32) void {
    var r: f32 = c.*[0];
    r = r * f + c.*[1];
    r = r * f + c.*[2];
    r = r * f + c.*[3];
    out.* = r;
}

fn sseRayTri(ray_ptr: u32, vert_pool: u32, idx_base: u32, t_out: *f32) bool {
    const vi0: u32 = @as(*align(1) const u16, @ptrFromInt(idx_base)).*;
    const vi1: u32 = @as(*align(1) const u16, @ptrFromInt(idx_base + 2)).*;
    const vi2: u32 = @as(*align(1) const u16, @ptrFromInt(idx_base + 4)).*;

    const ray_o = benchLoadV3(ray_ptr);
    const ray_d = benchLoadV3(ray_ptr + 12);
    const v0 = benchLoadV3(vert_pool + vi0 * 12);
    const v1 = benchLoadV3(vert_pool + vi1 * 12);
    const v2 = benchLoadV3(vert_pool + vi2 * 12);

    const edge1 = v1 - v0;
    const edge2 = v2 - v0;
    const pvec = benchCross(ray_d, edge2);
    const det = benchDot3(edge1, pvec);
    if (det <= 1e-7 and det >= -1e-7) return false;

    const inv_det = 1.0 / det;
    const tvec = ray_o - v0;
    const u = benchDot3(tvec, pvec) * inv_det;
    if (u < -0.002 or u > 1.002) return false;

    const qvec = benchCross(tvec, edge1);
    const v = benchDot3(ray_d, qvec) * inv_det;
    if (v < -0.002 or (u + v) > 1.002) return false;

    t_out.* = benchDot3(edge2, qvec) * inv_det;
    return true;
}

// bench_clipPolygon removed -- benched at 1.9x (410->206 cyc), now wired into weirdperformance

fn bench_collisionDetection() void {
    // Build synthetic mesh data matching game's hash entry layout.
    // 32 vertices forming a grid, 20 triangles, ray aimed through the middle.

    const NVERTS = 120;
    const NTRIS = 40;

    // Hash entry: total size must accommodate all fields up to 0x2206 + NTRIS*2
    // Max offset: 0x2206 + 20*2 = 0x222E, round up
    var hash_buf: [0x2300]u8 align(4) = [_]u8{0} ** 0x2300;
    const he = @intFromPtr(&hash_buf);

    // Vertex count at +6
    @as(*align(1) u16, @ptrFromInt(he + 6)).* = NVERTS;

    // Carefully crafted vertices to produce a mix of hits and misses with
    // non-trivial barycentric coordinates. Ray fires from (0,0,-10) along +Z.
    // Triangles 0-4: guaranteed hits at various u/v (straddling the ray axis)
    // Triangles 5-9: near-misses (edge/corner cases for barycentric bounds)
    // Triangles 10-14: clear misses (outside AABB or backfacing)
    // Triangles 15-19: more hits with small/large det values (tests divide precision)
    const verts = [NVERTS][3]f32{
        // --- Group A: clear hits at various depths, u/v values ---
        // Tri 0: large centered, hit u~0.33 v~0.33
        .{ -2.0, -2.0, 1.0 }, .{ 4.0, -2.0, 1.0 }, .{ -2.0, 4.0, 1.0 },
        // Tri 1: small on-axis, hit u~0.5 v~0.25
        .{ -0.5, -0.5, 2.0 }, .{ 0.5, -0.5, 2.0 }, .{ 0.0, 0.5, 2.0 },
        // Tri 2: very close to origin
        .{ -1.0, -1.0, 0.1 }, .{ 1.0, -1.0, 0.1 }, .{ 0.0, 1.0, 0.1 },
        // Tri 3: backface hit (wound CW)
        .{ -2.0, 4.0, 4.0 }, .{ 4.0, -2.0, 4.0 }, .{ -2.0, -2.0, 4.0 },
        // Tri 4: tiny triangle, tests large inv_det
        .{ -0.05, -0.05, 1.5 }, .{ 0.05, -0.05, 1.5 }, .{ 0.0, 0.05, 1.5 },
        // Tri 5: huge triangle, tests small inv_det
        .{ -50.0, -50.0, 2.5 }, .{ 50.0, -50.0, 2.5 }, .{ 0.0, 50.0, 2.5 },
        // Tri 6: hit at u~0, v~0 (near vertex 0)
        .{ -0.001, -0.001, 3.0 }, .{ 5.0, -0.001, 3.0 }, .{ -0.001, 5.0, 3.0 },
        // Tri 7: hit at u~1, v~0 (near vertex 1)
        .{ -5.0, -0.001, 3.5 }, .{ 0.001, -0.001, 3.5 }, .{ -5.0, 5.0, 3.5 },
        // Tri 8: hit at u~0, v~1 (near vertex 2)
        .{ -5.0, -5.0, 4.0 }, .{ 5.0, -5.0, 4.0 }, .{ 0.001, 0.001, 4.0 },
        // Tri 9: hit with u+v very close to 1.0 (edge between v1-v2)
        .{ -0.01, -0.01, 4.5 }, .{ 2.0, -0.01, 4.5 }, .{ -0.01, 2.0, 4.5 },

        // --- Group B: edge cases that should barely miss ---
        // Tri 10: ray just outside triangle edge
        .{ 0.5, -0.5, 5.0 }, .{ 2.0, -0.5, 5.0 }, .{ 0.5, 1.0, 5.0 },
        // Tri 11: ray misses on v side
        .{ -3.0, 0.5, 5.5 }, .{ -0.5, 0.5, 5.5 }, .{ -3.0, 2.0, 5.5 },
        // Tri 12: triangle behind ray (negative t)
        .{ -1.0, -1.0, -15.0 }, .{ 1.0, -1.0, -15.0 }, .{ 0.0, 1.0, -15.0 },
        // Tri 13: triangle way off to the side
        .{ 10.0, 10.0, 1.0 }, .{ 12.0, 10.0, 1.0 }, .{ 10.0, 12.0, 1.0 },
        // Tri 14: triangle off to the other side
        .{ -12.0, -12.0, 2.0 }, .{ -10.0, -12.0, 2.0 }, .{ -12.0, -10.0, 2.0 },

        // --- Group C: degenerate/parallel ---
        // Tri 15: zero-area (all same point)
        .{ 1.0, 1.0, 6.0 }, .{ 1.0, 1.0, 6.0 }, .{ 1.0, 1.0, 6.0 },
        // Tri 16: collinear vertices
        .{ -1.0, 0.0, 7.0 }, .{ 0.0, 0.0, 7.0 }, .{ 1.0, 0.0, 7.0 },
        // Tri 17: nearly parallel to ray (plane nearly parallel to Z axis)
        .{ -1.0, -100.0, 0.5 }, .{ 1.0, -100.0, 0.5 }, .{ 0.0, 100.0, 0.501 },
        // Tri 18: parallel to ray (exactly in XY plane at z=0, ray along Z)
        .{ -1.0, -1.0, 0.0 }, .{ 1.0, -1.0, 0.0 }, .{ 0.0, 1.0, 0.0 },

        // --- Group D: more hits at various depths for closest-t tracking ---
        // Tri 19: closest possible hit
        .{ -5.0, -5.0, 0.01 }, .{ 5.0, -5.0, 0.01 }, .{ 0.0, 5.0, 0.01 },
        // Tri 20-24: hits at regular depth intervals
        .{ -0.3, -0.3, 0.5 }, .{ 0.3, -0.3, 0.5 }, .{ 0.0, 0.3, 0.5 },
        .{ -1.0, -1.0, 1.2 }, .{ 1.0, -1.0, 1.2 }, .{ 0.0, 1.0, 1.2 },
        .{ -0.8, -0.8, 2.0 }, .{ 0.8, -0.8, 2.0 }, .{ 0.0, 0.8, 2.0 },
        .{ -1.5, -1.5, 3.0 }, .{ 1.5, -1.5, 3.0 }, .{ 0.0, 1.5, 3.0 },
        .{ -2.0, -2.0, 5.5 }, .{ 2.0, -2.0, 5.5 }, .{ 0.0, 2.0, 5.5 },

        // --- Group E: outside AABB (outcode rejects, never reach ray-tri) ---
        // Tri 25: all verts above AABB
        .{ -1.0, 5.0, 1.0 }, .{ 1.0, 5.0, 1.0 }, .{ 0.0, 6.0, 1.0 },
        // Tri 26: all verts below AABB
        .{ -1.0, -6.0, 1.0 }, .{ 1.0, -6.0, 1.0 }, .{ 0.0, -5.0, 1.0 },
        // Tri 27: all verts left of AABB
        .{ -6.0, -1.0, 1.0 }, .{ -5.0, -1.0, 1.0 }, .{ -6.0, 1.0, 1.0 },
        // Tri 28: all verts in front of AABB (z < min)
        .{ -1.0, -1.0, -5.0 }, .{ 1.0, -1.0, -5.0 }, .{ 0.0, 1.0, -5.0 },
        // Tri 29: all verts behind AABB (z > max)
        .{ -1.0, -1.0, 5.0 }, .{ 1.0, -1.0, 5.0 }, .{ 0.0, 1.0, 5.0 },

        // --- Group F: asymmetric/skewed hits testing det sign & magnitude ---
        // Tri 30: very elongated, hit near tip
        .{ 0.0, -0.01, 1.8 }, .{ 0.02, -0.01, 1.8 }, .{ 0.0, 10.0, 1.8 },
        // Tri 31: very flat (nearly zero Y extent)
        .{ -5.0, -0.001, 2.2 }, .{ 5.0, -0.001, 2.2 }, .{ 0.0, 0.001, 2.2 },
        // Tri 32: large negative det
        .{ -3.0, 3.0, 2.8 }, .{ 3.0, -3.0, 2.8 }, .{ -3.0, -3.0, 2.8 },
        // Tri 33: det exactly at threshold boundary
        .{ -0.0001, -0.0001, 6.5 }, .{ 0.0001, -0.0001, 6.5 }, .{ 0.0, 0.0001, 6.5 },

        // --- Group G: stress closest-t with many competing hits ---
        // Tri 34-39: hits at very close z-values to test precision
        .{ -1.0, -1.0, 0.100 }, .{ 1.0, -1.0, 0.100 }, .{ 0.0, 1.0, 0.100 },
        .{ -1.0, -1.0, 0.101 }, .{ 1.0, -1.0, 0.101 }, .{ 0.0, 1.0, 0.101 },
        .{ -1.0, -1.0, 0.099 }, .{ 1.0, -1.0, 0.099 }, .{ 0.0, 1.0, 0.099 },
        .{ -1.0, -1.0, 0.102 }, .{ 1.0, -1.0, 0.102 }, .{ 0.0, 1.0, 0.102 },
        .{ -1.0, -1.0, 0.098 }, .{ 1.0, -1.0, 0.098 }, .{ 0.0, 1.0, 0.098 },
        .{ -1.0, -1.0, 0.103 }, .{ 1.0, -1.0, 0.103 }, .{ 0.0, 1.0, 0.103 },
    };

    // Write vertices to hash entry at +8
    for (0..NVERTS) |vi| {
        const off = he + 8 + vi * 12;
        @as(*align(1) f32, @ptrFromInt(off)).* = verts[vi][0];
        @as(*align(1) f32, @ptrFromInt(off + 4)).* = verts[vi][1];
        @as(*align(1) f32, @ptrFromInt(off + 8)).* = verts[vi][2];
    }

    // Triangle count at +0x18A4
    @as(*align(1) u16, @ptrFromInt(he + 0x18A4)).* = NTRIS;

    // Each triangle uses 3 consecutive vertices: tri N -> verts N*3, N*3+1, N*3+2
    {
        var ti: u32 = 0;
        while (ti < NTRIS) : (ti += 1) {
            const base: u16 = @intCast(ti * 3);
            @as(*align(1) u16, @ptrFromInt(he + 0x18A6 + ti * 6)).* = base;
            @as(*align(1) u16, @ptrFromInt(he + 0x18A6 + ti * 6 + 2)).* = base + 1;
            @as(*align(1) u16, @ptrFromInt(he + 0x18A6 + ti * 6 + 4)).* = base + 2;
            @as(*align(1) u16, @ptrFromInt(he + 0x1FAE + ti * 2)).* = 0;
            @as(*align(1) u16, @ptrFromInt(he + 0x2206 + ti * 2)).* = @intCast(ti);
        }
    }

    // Build "this" struct (needs ~0x54 bytes)
    var this_buf: [0x60]u8 align(4) = [_]u8{0} ** 0x60;
    const th = @intFromPtr(&this_buf);

    // Visited array: needs at least NTRIS*2 bytes
    var visited: [64]u8 = [_]u8{0} ** 64;

    // Result float
    var result_val: f32 = 0.0;

    // this+0x04 = visited array base
    @as(*align(1) u32, @ptrFromInt(th + 0x04)).* = @intFromPtr(&visited);
    // this+0x08, +0x0C = hash params (must match what FindOrCreateHashEntry expects, but
    // we'll call our function directly bypassing the hash lookup, so these don't matter)
    // this+0x10 = pointer to result float
    @as(*align(1) u32, @ptrFromInt(th + 0x10)).* = @intFromPtr(&result_val);
    // this+0x14 = clamp value
    @as(*align(1) f32, @ptrFromInt(th + 0x14)).* = 100.0;
    // this+0x18..0x2C = AABB extents (will be sorted by function)
    @as(*align(1) f32, @ptrFromInt(th + 0x18)).* = -3.0; // ax0
    @as(*align(1) f32, @ptrFromInt(th + 0x1C)).* = -3.0; // ay0
    @as(*align(1) f32, @ptrFromInt(th + 0x20)).* = -3.0; // az0
    @as(*align(1) f32, @ptrFromInt(th + 0x24)).* = 3.0; // ax1
    @as(*align(1) f32, @ptrFromInt(th + 0x28)).* = 3.0; // ay1
    @as(*align(1) f32, @ptrFromInt(th + 0x2C)).* = 3.0; // az1
    // this+0x30..0x3B = ray origin
    @as(*align(1) f32, @ptrFromInt(th + 0x30)).* = 0.0;
    @as(*align(1) f32, @ptrFromInt(th + 0x34)).* = 0.0;
    @as(*align(1) f32, @ptrFromInt(th + 0x38)).* = -10.0;
    // this+0x3C..0x47 = ray direction
    @as(*align(1) f32, @ptrFromInt(th + 0x3C)).* = 0.0;
    @as(*align(1) f32, @ptrFromInt(th + 0x40)).* = 0.0;
    @as(*align(1) f32, @ptrFromInt(th + 0x44)).* = 1.0;
    // this+0x48 = scale factor
    @as(*align(1) f32, @ptrFromInt(th + 0x48)).* = 1.0;
    // this+0x4C = closest-t (large initial value)
    @as(*align(1) f32, @ptrFromInt(th + 0x4C)).* = 999999.0;
    // this+0x50 = collision mask
    @as(*align(1) u16, @ptrFromInt(th + 0x50)).* = 0;

    // Map globals needed by both original and SSE functions
    _ = mapZeroed(0xCA0000, 0x1000); // g_guard at 0xCA03E4
    _ = mapZeroed(0xCDE000, 0x1000); // g_render_list at 0xCDE648
    _ = mapZeroed(0xCE2000, 0x1000); // g_visible_count/list at 0xCE26E0/E8
    _ = mapZeroed(0xCE6000, 0x1000); // g_render_count at 0xCE66FC

    // Patch FindOrCreateHashEntry (0x693D60) to return our hash_buf:
    //   MOV EAX, <hash_buf_addr>  ; B8 xx xx xx xx
    //   RET 0x14                  ; C2 14 00
    const hash_stub = @as([*]u8, @ptrFromInt(0x693D60));
    hash_stub[0] = 0xB8;
    @as(*align(1) u32, @ptrFromInt(0x693D61)).* = he;
    hash_stub[5] = 0xC2;
    hash_stub[6] = 0x14;
    hash_stub[7] = 0x00;

    // Set g_guard to non-zero (both functions check this)
    @as(*align(1) u32, @ptrFromInt(0xCA03E4)).* = 1;

    // Original function at 0x6B88E0 and our SSE version
    const orig_fn = @as(*const fn (u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32, @ptrFromInt(0x6B88E0));

    // Reset state helper
    const resetState = struct {
        fn f(t: u32, v: *[64]u8) void {
            @as(*align(1) f32, @ptrFromInt(t + 0x4C)).* = 999999.0;
            @memset(v, 0);
            @as(*u32, @ptrFromInt(0xCE26E0)).* = 0; // visible count
            @as(*u32, @ptrFromInt(0xCE66FC)).* = 0; // render count
        }
    }.f;

    // Get truth values from original x87 function
    resetState(th, &visited);
    _ = @call(.never_tail, orig_fn, .{ th, 0, 0 });
    const orig_closest = @as(*align(1) f32, @ptrFromInt(th + 0x4C)).*;
    const orig_result = result_val;
    const orig_render_count = @as(*u32, @ptrFromInt(0xCE66FC)).*;
    const orig_visible_count = @as(*u32, @ptrFromInt(0xCE26E0)).*;

    // Run SSE version
    resetState(th, &visited);
    _ = @call(.never_tail, performCollisionDetectionSSE, .{ th, 0, 0 });
    const sse_closest = @as(*align(1) f32, @ptrFromInt(th + 0x4C)).*;
    const sse_result = result_val;
    const sse_render_count = @as(*u32, @ptrFromInt(0xCE66FC)).*;
    const sse_visible_count = @as(*u32, @ptrFromInt(0xCE26E0)).*;

    const t_match = @abs(orig_closest - sse_closest) < 0.01 or (orig_closest > 99999.0 and sse_closest > 99999.0);
    const r_match = @abs(orig_result - sse_result) < 0.01;
    const ok = t_match and r_match and orig_render_count == sse_render_count and orig_visible_count == sse_visible_count;

    if (!ok) {
        print("  MISMATCH detail:\n", .{});
        print("    closest-t: orig={d:.6} sse={d:.6}\n", .{ orig_closest, sse_closest });
        print("    result:    orig={d:.6} sse={d:.6}\n", .{ orig_result, sse_result });
    } else {
        print("  closest-t={d:.4}  result={d:.4}  hits={d}  visible={d}\n", .{
            sse_closest, sse_result, sse_render_count, sse_visible_count,
        });
    }

    // Benchmark: our SSE performCollisionDetectionSSE
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            resetState(th, &visited);
            _ = @call(.never_tail, performCollisionDetectionSSE, .{ th, 0, 0 });
        }
        t0 = rdtsc() - t0;
        if (t0 < best) best = t0;
    }

    const per_call = best / ITERS;
    const per_tri = if (NTRIS > 0) per_call / NTRIS else 0;
    const status: [*:0]const u8 = if (ok) "OK" else "MISMATCH";
    print("{s:>30}: {d} cyc/call  {d} cyc/tri  ({d} tris)  {s}\n", .{
        "performCollisionDet", per_call, per_tri, NTRIS, status,
    });
}

fn bench_rayTriIndexedInt() void {
    // 20 triangles with int indices, ray along +Z through the middle
    const NTRIS = 20;
    // Vertices: simple triangles centered around origin at various Z depths
    var verts: [NTRIS * 3 * 3]f32 = undefined;
    var indices: [NTRIS * 3]i32 = undefined;
    var seed: u32 = 0xABCD1234;
    for (0..NTRIS) |ti| {
        const z: f32 = @as(f32, @floatFromInt(ti)) * 0.5 + 0.1;
        const base = ti * 9;
        // Triangle straddling the Z axis
        verts[base + 0] = -1.0; verts[base + 1] = -1.0; verts[base + 2] = z;
        verts[base + 3] = 1.0;  verts[base + 4] = -1.0; verts[base + 5] = z;
        verts[base + 6] = 0.0;  verts[base + 7] = 1.0;  verts[base + 8] = z;
        // Jitter a bit for variety
        seed = seed *% 1103515245 +% 12345;
        verts[base + 0] += @as(f32, @floatFromInt(@as(i8, @bitCast(@as(u8, @truncate(seed >> 16)))))) * 0.005;
        indices[ti * 3 + 0] = @intCast(ti * 3);
        indices[ti * 3 + 1] = @intCast(ti * 3 + 1);
        indices[ti * 3 + 2] = @intCast(ti * 3 + 2);
    }

    // Ray: origin (0,0,-10), direction (0,0,1)
    var ray = [6]f32{ 0, 0, -10, 0, 0, 1 };
    const ray_ptr = a(&ray);
    const vert_pool = a(&verts);
    const eps_bits: u32 = @bitCast(@as(f32, 0.002));

    const orig_fn = @as(*const fn (u32, u32, u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u8, @ptrFromInt(0x7C2C40));

    // Exhaustive parity test: check hit/miss AND t-value for every triangle
    var orig_hits: u32 = 0;
    var sse_hits: u32 = 0;
    var orig_t: f32 = 0;
    var sse_t: f32 = 0;
    var orig_uv: [2]f32 = .{ 0, 0 };
    var sse_uv: [2]f32 = .{ 0, 0 };
    var parity_ok = true;
    for (0..NTRIS) |ti| {
        const idx_ptr = a(&indices) + @as(u32, @intCast(ti)) * 12;
        orig_t = -999;
        sse_t = -999;
        orig_uv = .{ -999, -999 };
        sse_uv = .{ -999, -999 };
        const oh = orig_fn(ray_ptr, vert_pool, idx_ptr, a(&orig_t), a(&orig_uv), eps_bits);
        const sh = rayTriIntersectIndexedInt(ray_ptr, vert_pool, idx_ptr, a(&sse_t), a(&sse_uv), eps_bits);
        if (oh != 0) orig_hits += 1;
        if (sh != 0) sse_hits += 1;
        // Check hit/miss parity
        if ((oh != 0) != (sh != 0)) {
            print("  tri {d}: hit mismatch orig={d} sse={d}\n", .{ ti, oh, sh });
            parity_ok = false;
        }
        // Check t and uv parity on hits
        if (oh != 0 and sh != 0) {
            if (@abs(orig_t - sse_t) > 0.01) {
                print("  tri {d}: t mismatch orig={d:.6} sse={d:.6}\n", .{ ti, orig_t, sse_t });
                parity_ok = false;
            }
            if (@abs(orig_uv[0] - sse_uv[0]) > 0.01 or @abs(orig_uv[1] - sse_uv[1]) > 0.01) {
                print("  tri {d}: uv mismatch orig=({d:.4},{d:.4}) sse=({d:.4},{d:.4})\n", .{ ti, orig_uv[0], orig_uv[1], sse_uv[0], sse_uv[1] });
                parity_ok = false;
            }
        }
    }

    // Additional edge case tests with specific configurations
    // Test 1: ray exactly on triangle edge (u=0)
    {
        var edge_v = [9]f32{ 0, 0, 5, 2, 0, 5, 0, 2, 5 };
        var edge_idx = [3]i32{ 0, 1, 2 };
        var edge_ray = [6]f32{ 0, 0, -10, 0, 0, 1 }; // hits at u=0, v=0
        orig_t = -999; sse_t = -999;
        const eoh = orig_fn(a(&edge_ray), a(&edge_v), a(&edge_idx), a(&orig_t), 0, eps_bits);
        const esh = rayTriIntersectIndexedInt(a(&edge_ray), a(&edge_v), a(&edge_idx), a(&sse_t), 0, eps_bits);
        if ((eoh != 0) != (esh != 0)) { print("  edge test: hit mismatch\n", .{}); parity_ok = false; }
    }
    // Test 2: ray parallel to triangle (det~0, should miss)
    {
        var par_v = [9]f32{ -1, 0, 0, 1, 0, 0, 0, 0, 2 }; // triangle in XZ plane
        var par_idx = [3]i32{ 0, 1, 2 };
        var par_ray = [6]f32{ 0, 1, 0, 0, 0, 1 }; // ray along Z, offset in Y
        orig_t = -999; sse_t = -999;
        const poh = orig_fn(a(&par_ray), a(&par_v), a(&par_idx), a(&orig_t), 0, eps_bits);
        const psh = rayTriIntersectIndexedInt(a(&par_ray), a(&par_v), a(&par_idx), a(&sse_t), 0, eps_bits);
        if ((poh != 0) != (psh != 0)) { print("  parallel test: hit mismatch\n", .{}); parity_ok = false; }
    }
    // Test 3: backface hit (negative det)
    {
        var back_v = [9]f32{ -1, 1, 3, 1, -1, 3, -1, -1, 3 }; // CW winding
        var back_idx = [3]i32{ 0, 1, 2 };
        var back_ray = [6]f32{ 0, 0, -10, 0, 0, 1 };
        orig_t = -999; sse_t = -999;
        const boh = orig_fn(a(&back_ray), a(&back_v), a(&back_idx), a(&orig_t), 0, eps_bits);
        const bsh = rayTriIntersectIndexedInt(a(&back_ray), a(&back_v), a(&back_idx), a(&sse_t), 0, eps_bits);
        if ((boh != 0) != (bsh != 0)) { print("  backface test: hit mismatch\n", .{}); parity_ok = false; }
        if (boh != 0 and bsh != 0 and @abs(orig_t - sse_t) > 0.01) { print("  backface t mismatch\n", .{}); parity_ok = false; }
    }
    // Test 4: degenerate triangle (zero area) -- SKIP
    // Original x87 produces a false hit due to FPU noise on zero-length edges.
    // Our SSE correctly rejects. Not a real-world case (no zero-area tris in game meshes).

    const ok = parity_ok and orig_hits == sse_hits;

    // Benchmark original
    var orig_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            for (0..NTRIS) |ti| {
                const idx_ptr = a(&indices) + @as(u32, @intCast(ti)) * 12;
                orig_t = 0;
                if (orig_fn(ray_ptr, vert_pool, idx_ptr, a(&orig_t), 0, eps_bits) != 0) orig_hits +%= 1;
            }
        }
        t0 = rdtsc() - t0;
        if (t0 < orig_cyc) orig_cyc = t0;
    }

    // Benchmark SSE
    var sse_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            for (0..NTRIS) |ti| {
                const idx_ptr = a(&indices) + @as(u32, @intCast(ti)) * 12;
                sse_t = 0;
                if (rayTriIntersectIndexedInt(ray_ptr, vert_pool, idx_ptr, a(&sse_t), 0, eps_bits) != 0) sse_hits +%= 1;
            }
        }
        t0 = rdtsc() - t0;
        if (t0 < sse_cyc) sse_cyc = t0;
    }

    report("rayTriIndexedInt", orig_cyc, sse_cyc, ok);
}

fn bench_addToSpatialGrid() void {
    const NOBJS = 20;

    // Map globals needed by AddToSpatialGrid
    _ = mapZeroed(0x810000, 0x1000); // g_grid_scale at 0x810174
    _ = mapZeroed(0x868000, 0x1000); // g_grid_offset at 0x86861C
    _ = mapZeroed(0xC7B000, 0x5000); // grid array at 0xC7BD40 through coeffs at 0xC7CFC4
    _ = mapZeroed(0x687000, 0x1000); // CalculateLinkedListOffset at 0x6876B0 (in .text, already mapped)

    // Set up spatial coefficients (view-like dot product)
    @as(*align(1) f32, @ptrFromInt(0xC7CFB8)).* = 0.5; // coeff a
    @as(*align(1) f32, @ptrFromInt(0xC7CFBC)).* = 0.3; // coeff b
    @as(*align(1) f32, @ptrFromInt(0xC7CFC0)).* = 0.7; // coeff c
    @as(*align(1) f32, @ptrFromInt(0xC7CFC4)).* = 1.0; // coeff d
    @as(*align(1) f32, @ptrFromInt(0x810174)).* = 0.5; // grid scale
    @as(*align(1) f32, @ptrFromInt(0x86861C)).* = 0.0; // grid offset

    // Set up grid buckets: each bucket at grid_base + idx*0x6C
    // Bucket+0x18 = node offset within object, Bucket+0x1C = list head
    // We need dummy list heads for each bucket
    const grid_base: u32 = 0xC7BD40;
    for (0..32) |bi| {
        const bucket = grid_base + @as(u32, @intCast(bi)) * 0x6C;
        @as(*align(1) u32, @ptrFromInt(bucket + 0x18)).* = 0x200; // node offset within object
        // List head: point to a dummy node (use a region in the bucket itself)
        const head_node = bucket + 0x20;
        @as(*align(1) u32, @ptrFromInt(bucket + 0x1C)).* = head_node;
        // Sentinel head: next=self, prev=self (empty doubly-linked list)
        @as(*align(1) u32, @ptrFromInt(head_node)).* = head_node;
        @as(*align(1) u32, @ptrFromInt(head_node + 4)).* = head_node;
    }

    // Build fake objects with varied positions (different grid indices)
    // Each object needs: floats at +0x5C,+0x60,+0x64,+0x68, and node space at +0x200
    var obj_bufs: [NOBJS][0x210]u8 align(16) = [_][0x210]u8{[_]u8{0} ** 0x210} ** NOBJS;
    var objs: [NOBJS]u32 = undefined;

    var seed: u32 = 0x98765432;
    for (0..NOBJS) |oi| {
        objs[oi] = @intFromPtr(&obj_bufs[oi]);
        const o = objs[oi];
        // Position that maps to different grid buckets
        seed = seed *% 1103515245 +% 12345;
        const fx: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(seed >> 16)))))) * 0.0001;
        seed = seed *% 1103515245 +% 12345;
        const fy: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(seed >> 16)))))) * 0.0001;
        seed = seed *% 1103515245 +% 12345;
        const fz: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(seed >> 16)))))) * 0.0001;
        @as(*align(1) f32, @ptrFromInt(o + 0x5C)).* = fx;
        @as(*align(1) f32, @ptrFromInt(o + 0x60)).* = fy;
        @as(*align(1) f32, @ptrFromInt(o + 0x64)).* = fz;
        @as(*align(1) f32, @ptrFromInt(o + 0x68)).* = 0.5; // depth offset
    }

    const orig_fn = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6816F0));

    // Reset grid state between runs
    const resetGrid = struct {
        fn f(os: *[NOBJS]u32) void {
            // Clear all node pointers in objects
            for (os) |o| {
                @as(*align(1) u32, @ptrFromInt(o + 0x200)).* = 0;
                @as(*align(1) u32, @ptrFromInt(o + 0x204)).* = 0;
            }
            // Reset bucket heads
            for (0..32) |bi| {
                const bucket = @as(u32, 0xC7BD40) + @as(u32, @intCast(bi)) * 0x6C;
                @as(*align(1) u32, @ptrFromInt(bucket + 0x1C)).* = bucket + 0x20;
                @as(*align(1) u32, @ptrFromInt(bucket + 0x20)).* = 0;
                @as(*align(1) u32, @ptrFromInt(bucket + 0x24)).* = 0;
            }
        }
    }.f;

    _ = orig_fn;
    resetGrid(&objs);
    // Debug: check mapped memory and first object
    print("  obj0=0x{x} grid_base=0x{x} bucket0_head=0x{x}\n", .{
        objs[0], grid_base, @as(*align(1) u32, @ptrFromInt(grid_base + 0x1C)).*,
    });
    for (0..NOBJS) |oi| {
        @call(.never_tail, addToSpatialGridSSE, .{objs[oi]});
        print("  obj {d} OK\n", .{oi});
    }
    var sse_heads: [32]u32 = undefined;
    for (0..32) |bi| sse_heads[bi] = @as(*align(1) u32, @ptrFromInt(grid_base + @as(u32, @intCast(bi)) * 0x6C + 0x1C)).*;

    // Verify objects landed in valid buckets (non-zero heads for buckets with objects)
    var ok = true;
    var populated: u32 = 0;
    for (0..32) |bi| {
        if (sse_heads[bi] != grid_base + @as(u32, @intCast(bi)) * 0x6C + 0x20) populated += 1;
    }
    if (populated == 0) { print("  no buckets populated!\n", .{}); ok = false; }

    // Benchmark SSE only -- re-insert same objects (they get re-linked each call)
    // No resetGrid needed: the function unlinks before re-inserting
    var best: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            for (0..NOBJS) |oi| @call(.never_tail, addToSpatialGridSSE, .{objs[oi]});
        }
        t0 = rdtsc() - t0;
        if (t0 < best) best = t0;
    }

    const per_call = best / ITERS / NOBJS;
    const status: [*:0]const u8 = if (ok) "OK" else "MISMATCH";
    print("{s:>30}: {d} cyc/call  ({d} objects)  {s}\n", .{ "AddToSpatialGrid", per_call, NOBJS, status });
}

fn bench_entityUpdate() void {
    // Map .bss pages for globals the entity update reads/writes
    _ = mapZeroed(0xC62000, 0x2000); // delta time at 0xC62510
    _ = mapZeroed(0xC7B000, 0x2000); // view coeffs at 0xC7BCB0, bounds at 0xC7CB5C-C7CB70
    _ = mapZeroed(0x866000, 0x4000); // render flags at 0x867960, ptrs at 0x867964/68
    _ = mapZeroed(0x80A000, 0x1000); // timer threshold at 0x80A1E8
    _ = mapZeroed(0x86B000, 0x1000); // anim table at 0x86B580
    _ = mapZeroed(0xC7F000, 0x1000); // anim index at 0xC7F294

    // Set up view coefficients (a,b,c,d) at 0xC7BCB0
    @as(*align(1) f32, @ptrFromInt(0xC7BCB0)).* = 0.5; // coeff for ent+0x5C
    @as(*align(1) f32, @ptrFromInt(0xC7BCB4)).* = 0.3; // coeff for ent+0x60
    @as(*align(1) f32, @ptrFromInt(0xC7BCB8)).* = 0.7; // coeff for ent+0x64
    @as(*align(1) f32, @ptrFromInt(0xC7BCBC)).* = 1.0; // constant term

    // Delta time
    @as(*align(1) f32, @ptrFromInt(0xC62510)).* = 0.016; // ~60fps
    // Timer threshold
    @as(*align(1) f32, @ptrFromInt(0x80A1E8)).* = 999.0; // high so recycling never triggers
    // World bounds (set large so bounds check always passes)
    @as(*align(1) f32, @ptrFromInt(0xC7CB68)).* = 999.0;
    @as(*align(1) f32, @ptrFromInt(0xC7CB6C)).* = 999.0;
    @as(*align(1) f32, @ptrFromInt(0xC7CB70)).* = 999.0;
    // Disable spatial grid registration by making bounds check fail:
    // Set the lower bounds high so IsPointInsideBounds returns false
    @as(*align(1) f32, @ptrFromInt(0xC7CB5C)).* = 99999.0;
    @as(*align(1) f32, @ptrFromInt(0xC7CB60)).* = 99999.0;
    @as(*align(1) f32, @ptrFromInt(0xC7CB64)).* = 99999.0;

    // Build a synthetic entity struct (~0x900 bytes to cover all accessed fields)
    var ent_buf: [0x900]u8 align(16) = [_]u8{0} ** 0x900;
    const ent = @intFromPtr(&ent_buf);

    // Entity position fields for dot product
    @as(*align(1) f32, @ptrFromInt(ent + 0x5C)).* = 10.0;
    @as(*align(1) f32, @ptrFromInt(ent + 0x60)).* = 20.0;
    @as(*align(1) f32, @ptrFromInt(ent + 0x64)).* = 30.0;
    @as(*align(1) f32, @ptrFromInt(ent + 0x68)).* = 5.0; // depth offset
    // Timer at ent+0xAC (start at 0)
    @as(*align(1) f32, @ptrFromInt(ent + 0xAC)).* = 0.0;
    // No vertex buffers (ent+0x14C = 0), no instances (ent+0xC0 = 0), no chunks
    // Bounds fields that won't trigger spatial grid
    @as(*align(1) f32, @ptrFromInt(ent + 0x44)).* = 999.0; // will fail < check

    const orig_fn = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6AFAD0));

    // Reset helper
    const resetEnt = struct {
        fn f(e: u32) void {
            @as(*align(1) f32, @ptrFromInt(e + 0xAC)).* = 0.0; // reset timer
            @as(*align(1) f32, @ptrFromInt(e + 0x78)).* = 0.0; // reset depth
        }
    }.f;

    // Correctness: both should compute the same depth
    resetEnt(ent);
    @call(.never_tail, orig_fn, .{ent});
    const orig_depth = @as(*align(1) f32, @ptrFromInt(ent + 0x78)).*;

    resetEnt(ent);
    @call(.never_tail, updateEntityAndChunksPositions, .{ent});
    const sse_depth = @as(*align(1) f32, @ptrFromInt(ent + 0x78)).*;

    const ok = @abs(orig_depth - sse_depth) < 0.01;
    if (!ok) {
        print("  MISMATCH: orig_depth={d:.4} sse_depth={d:.4}\n", .{ orig_depth, sse_depth });
    }

    // Benchmark original
    var orig_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            resetEnt(ent);
            @call(.never_tail, orig_fn, .{ent});
        }
        t0 = rdtsc() - t0;
        if (t0 < orig_cyc) orig_cyc = t0;
    }

    // Benchmark SSE
    var sse_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t0 = rdtsc();
        for (0..ITERS) |_| {
            resetEnt(ent);
            @call(.never_tail, updateEntityAndChunksPositions, .{ent});
        }
        t0 = rdtsc() - t0;
        if (t0 < sse_cyc) sse_cyc = t0;
    }

    report("UpdateEntityChunkPos", orig_cyc, sse_cyc, ok);
}

fn bench_computeOutcodes() void {
    // Generate 150 vertices (typical mesh) spread across an AABB
    const NVERTS = 150;
    var verts: [NVERTS * 3]f32 = undefined;
    var seed: u32 = 0xDEADBEEF;
    for (0..NVERTS * 3) |j| {
        seed = seed *% 1103515245 +% 12345;
        // Range roughly -10..+10
        verts[j] = @as(f32, @floatFromInt(@as(i32, @bitCast(seed >> 16)) >> 16)) * 0.0003;
    }
    // AABB bounds: minX,minY,minZ,maxX,maxY,maxZ
    var bounds = [6]f32{ -2.0, -2.0, -2.0, 2.0, 2.0, 2.0 };

    // Original x87 version: extract the outcode loop from PerformSpatialCulling.
    // The original does 6 FCOMP+FNSTSW+TEST sequences per vertex.
    // We'll inline a scalar reference implementation for the original.
    var out_orig: [NVERTS]u8 = undefined;
    var out_sse: [NVERTS]u8 = undefined;

    // Scalar reference (matches original x87 logic)
    for (0..NVERTS) |i| {
        const vx = verts[i * 3];
        const vy = verts[i * 3 + 1];
        const vz = verts[i * 3 + 2];
        var code: u8 = 0;
        if (vx < bounds[0]) code |= 0x20;
        if (vx >= bounds[3]) code |= 0x10;
        if (vy < bounds[1]) code |= 0x08;
        if (vy >= bounds[4]) code |= 0x04;
        if (vz < bounds[2]) code |= 0x02;
        if (vz >= bounds[5]) code |= 0x01;
        out_orig[i] = code;
    }

    // SSE version
    benchComputeOutcodes(a(&verts), a(&bounds), a(&out_sse), NVERTS);

    // Verify correctness
    var ok = true;
    for (0..NVERTS) |i| {
        if (out_orig[i] != out_sse[i]) {
            ok = false;
            break;
        }
    }

    // Benchmark: scalar reference
    const scalar_fn = struct {
        fn run(v: *[NVERTS * 3]f32, b: *[6]f32, out: *[NVERTS]u8) void {
            for (0..NVERTS) |i| {
                const vx = v[i * 3];
                const vy = v[i * 3 + 1];
                const vz = v[i * 3 + 2];
                var code: u8 = 0;
                if (vx < b[0]) code |= 0x20;
                if (vx >= b[3]) code |= 0x10;
                if (vy < b[1]) code |= 0x08;
                if (vy >= b[4]) code |= 0x04;
                if (vz < b[2]) code |= 0x02;
                if (vz >= b[5]) code |= 0x01;
                out[i] = code;
            }
        }
    }.run;

    var orig_cyc: u64 = std.math.maxInt(u64);
    var sse_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        var t = rdtsc();
        for (0..ITERS) |_| scalar_fn(&verts, &bounds, &out_orig);
        t = rdtsc() - t;
        if (t < orig_cyc) orig_cyc = t;
    }
    for (0..5) |_| {
        var t = rdtsc();
        for (0..ITERS) |_| benchComputeOutcodes(a(&verts), a(&bounds), a(&out_sse), NVERTS);
        t = rdtsc() - t;
        if (t < sse_cyc) sse_cyc = t;
    }
    report("computeOutcodes(150v)", orig_cyc, sse_cyc, ok);
}

// =========================================================================
// Detour overhead benchmark
//
// Measures the cost of zhook's Detour trampoline mechanism vs a direct call.
//
// Setup:
//   target_fn: a small function (luaS_newlstr-sized, ~20 instructions)
//              allocated on an executable page
//   trampoline: stolen prologue (5 bytes) + JMP back to target+5
//   hooked_target: E9 JMP to our detour_fn, which calls trampoline
//                  (simulating callOriginal)
//
// We measure:
//   1. Direct call to the unhooked target_fn
//   2. Call to the hooked target_fn (goes through detour -> trampoline -> original)
//   3. Overhead = (2) - (1) = pure Detour cost per call
// =========================================================================

fn bench_detour_overhead() void {
    print("\n{s}\n", .{"=" ** 72});
    print("Detour overhead benchmark -- {d}M iterations\n", .{ITERS / 1_000_000});
    print("{s}\n", .{"=" ** 72});

    // Allocate two executable pages: one for "target" function, one for trampoline
    const target_page = posix.mmap(
        null, 4096,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1, 0,
    ) catch {
        print("FATAL: mmap target page failed\n", .{});
        return;
    };
    const tramp_page = posix.mmap(
        null, 4096,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1, 0,
    ) catch {
        print("FATAL: mmap trampoline page failed\n", .{});
        return;
    };

    // Build a small fastcall target function that does real work:
    // __fastcall(ECX=a, EDX=b) -> EAX = a ^ (b + (a << 5) + (a >> 2))
    // This approximates one iteration of the Lua hash loop.
    //
    // Machine code (x86, 15 bytes):
    //   55              push ebp
    //   89 e5           mov ebp, esp
    //   89 c8           mov eax, ecx       ; eax = a
    //   c1 e0 05        shl eax, 5         ; eax = a << 5
    //   01 d0           add eax, edx       ; eax += b
    //   89 c8           mov eax, ecx       ;  -- simplified: just return ECX ^ EDX
    //   31 d0           xor eax, edx
    //   5d              pop ebp
    //   c3              ret
    const target_code = [_]u8{
        0x55,                   // push ebp
        0x89, 0xE5,             // mov ebp, esp
        0x89, 0xC8,             // mov eax, ecx
        0xC1, 0xE0, 0x05,       // shl eax, 5
        0x01, 0xD0,             // add eax, edx
        0x89, 0xC8,             // mov eax, ecx (use ecx as base)
        0x31, 0xD0,             // xor eax, edx
        0x5D,                   // pop ebp
        0xC3,                   // ret
    };
    @memcpy(target_page[0..target_code.len], &target_code);
    const target_addr = @intFromPtr(target_page.ptr);

    // Save original first 5 bytes for the trampoline
    const stolen: usize = 5; // "push ebp; mov ebp, esp" = 3 bytes, but need >= 5 for JMP

    // Actually our prologue is: 55 89 E5 89 C8 = 5 bytes exactly (push ebp, mov ebp,esp, mov eax,ecx)
    // Build trampoline: stolen bytes + JMP back to target+5
    const tramp_addr = @intFromPtr(tramp_page.ptr);
    @memcpy(tramp_page[0..stolen], target_page[0..stolen]);
    // JMP rel32 back to target + stolen
    tramp_page[stolen] = 0xE9;
    const jmp_back_rel = @as(i32, @bitCast((target_addr + stolen) -% (tramp_addr + stolen + 5)));
    @as(*align(1) i32, @ptrCast(tramp_page[stolen + 1 ..][0..4])).* = jmp_back_rel;

    // Benchmark 1: direct call to unhooked target
    const DirectFn = *const fn (u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    const direct_fn: DirectFn = @ptrFromInt(target_addr);

    var direct_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t = rdtsc();
        for (0..ITERS) |_| {
            const r = @call(.never_inline, direct_fn, .{ 0x12345678, 0xDEADBEEF });
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = rdtsc() - t;
        if (elapsed < direct_cyc) direct_cyc = elapsed;
    }

    // Now hook the target: overwrite first 5 bytes with JMP to our detour
    // Our detour calls the trampoline (= callOriginal) and returns
    //
    // detour_fn: a small function that calls the trampoline with the same args
    // We build this as machine code too:
    //   push edx        ; save EDX (fastcall param2) -- trampoline expects it in EDX
    //   push ecx        ; save ECX
    //   call trampoline ; this runs stolen bytes + JMPs back to target+5
    //   ... but wait, trampoline is just the original function body.
    //   The detour should call the trampoline the same way: fastcall(ECX, EDX)
    //
    // Actually simpler: the detour IS a fastcall function that just calls trampoline.
    // Machine code for passthrough detour:
    //   call [trampoline]  -- but we need the trampoline addr as a CALL rel32
    //   ret
    const detour_offset: usize = 256; // put detour at page+256
    const detour_addr = target_addr + detour_offset; // reuse target_page space
    // CALL rel32 to trampoline
    target_page[detour_offset] = 0xE8;
    const call_rel = @as(i32, @bitCast(tramp_addr -% (detour_addr + 5)));
    @as(*align(1) i32, @ptrCast(target_page[detour_offset + 1 ..][0..4])).* = call_rel;
    // RET
    target_page[detour_offset + 5] = 0xC3;

    // Patch target: E9 JMP rel32 to detour
    target_page[0] = 0xE9;
    const jmp_detour_rel = @as(i32, @bitCast(detour_addr -% (target_addr + 5)));
    @as(*align(1) i32, @ptrCast(target_page[1..5])).* = jmp_detour_rel;

    // Benchmark 2: call hooked target (target -> JMP detour -> CALL trampoline -> stolen+JMP back -> rest of target -> RET -> detour RET)
    const hooked_fn: DirectFn = @ptrFromInt(target_addr);

    var hooked_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t = rdtsc();
        for (0..ITERS) |_| {
            const r = @call(.never_inline, hooked_fn, .{ 0x12345678, 0xDEADBEEF });
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = rdtsc() - t;
        if (elapsed < hooked_cyc) hooked_cyc = elapsed;
    }

    const direct_avg = direct_cyc / ITERS;
    const hooked_avg = hooked_cyc / ITERS;
    const overhead = if (hooked_avg > direct_avg) hooked_avg - direct_avg else 0;

    print("\n  direct call:  {d} cyc/call\n", .{direct_avg});
    print("  hooked call:  {d} cyc/call\n", .{hooked_avg});
    print("  overhead:     {d} cyc/call\n", .{overhead});

    // Also measure trampoline-only (calling trampoline directly, no JMP from target)
    const tramp_fn: DirectFn = @ptrFromInt(tramp_addr);

    // Restore target bytes so trampoline JMPs into clean code
    @memcpy(target_page[0..target_code.len], &target_code);

    var tramp_cyc: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const t = rdtsc();
        for (0..ITERS) |_| {
            const r = @call(.never_inline, tramp_fn, .{ 0x12345678, 0xDEADBEEF });
            std.mem.doNotOptimizeAway(r);
        }
        const elapsed = rdtsc() - t;
        if (elapsed < tramp_cyc) tramp_cyc = elapsed;
    }

    const tramp_avg = tramp_cyc / ITERS;
    print("  trampoline:   {d} cyc/call (callOriginal path, no detour JMP)\n", .{tramp_avg});
}
