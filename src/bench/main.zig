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
extern fn si_normalizeVec3(u32, u32) void;
extern fn si_mulMat3x4(u32, u32, u32) u32;
extern fn si_rotateMatByQuat(u32, u32) u32;
extern fn si_createRotMat3x4(u32, u32, u32, u32) u32;
extern fn si_distanceToPlane(u32, u32, u32) f64;
extern fn si_classifyPointFrustum(u32, u32, u32) u32;
extern fn si_checkBoxLineIntersect(u32, u32, u32) u32;
extern fn si_testOBBFrustum(u32, u32, u32, u32) u32;
extern fn si_testSphereFrustum(u32, u32) u32;
extern fn si_quatSlerp(u32, u32, u32, u32) u32;
extern fn si_isPointInsideBounds(u32, u32) u32;
extern fn si_calculateSinCos(u32, u32, u32) void;
extern fn si_createZRotMat3x3(u32, u32) u32;
extern fn si_transposeMat4x4(u32, u32) u32;
extern fn si_mulMat3x4InPlace(u32, u32) u32;
extern fn si_normalizeVec3InPlace(u32) void;
extern fn si_vec3Dot(u32, u32) f64;
extern fn si_translateBoundingVol(u32, u32) void;
extern fn si_addVec3ToAccumulator(u32, u32, u32) void;
extern fn si_addToColorAccumulator(u32, u32) void;
extern fn si_packParticleColor(u32, u32, u32, u32) void;
extern fn si_setParticleAlpha(u32, u32) void;

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

fn mapWowSections() bool {
    if (sections_mapped) return true;
    if (!mapFixedSection(TEXT_START, TEXT_SIZE, wow_text_data, true)) return false;
    if (!mapFixedSection(RDATA_START, RDATA_SIZE, wow_rdata_data, false)) return false;
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

// =========================================================================
// Calling convention types for original x87 functions (game binary)
// =========================================================================

const cc_fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const cc_tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };

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
        var t = rdtsc(); for (0..ITERS) |_| { do = tmpl; _ = of(a(&do), fb); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { ds = tmpl; _ = vec3MulAssign(a(&ds), fb); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { mo = tmpl; of(a(&mo), fb); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { ms = tmpl; scaleMatrix3x3ByScalar(a(&ms), fb); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis), ab, 1); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = createAxisAngleRotMat3x3(a(&rs), a(&axis), ab, 1); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis), ab, 1); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = createAxisAngleRotMat4x4(a(&rs), a(&axis), ab, 1); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va), a(&vb)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = dotProduct(a(&va), a(&vb)); } s = rdtsc() - s;
        report("dotProduct", t, s, ok);
    }

    // 14: sqmag -- thiscall(ECX=vec) -> f64
    {
        const v = tv3();
        const of: *const fn (u32) callconv(cc_tc) f64 = @ptrCast(makeExecutable(&originals.squaredMagnitude) orelse unreachable);
        const ov = of(a(&v));
        const sv = squaredMagnitude(a(&v));
        const ok = @abs(ov - sv) < 1e-4;
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&v)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = squaredMagnitude(a(&v)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(3, a(&coeffs), fb); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = evaluatePolynomial(3, a(&coeffs), fb); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { of(a(&ro), a(&p1), a(&p2), a(&p3)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { calculatePlaneNormal(a(&rs), a(&p1), a(&p2), a(&p3)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { bo = .{ 0, 0, 0, 0, 0, 0 }; of(a(&mat), a(&va), a(&vb), a(&box_in), a(&bo)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { bs = .{ 0, 0, 0, 0, 0, 0 }; transformAABox(a(&mat), a(&va), a(&vb), a(&box_in), a(&bs)); } s = rdtsc() - s;
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
        var t = rdtsc();
        for (0..ITERS) |_| inline_x87_dot(&va2, &vb2, &rx);
        t = rdtsc() - t;
        var s = rdtsc();
        for (0..ITERS) |_| inline_sse_dot(&va2, &vb2, &rs);
        s = rdtsc() - s;
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
        var t = rdtsc();
        for (0..ITERS) |_| inline_x87_sqmag(&v, &rx);
        t = rdtsc() - t;
        var s = rdtsc();
        for (0..ITERS) |_| inline_sse_sqmag(&v, &rs);
        s = rdtsc() - s;
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
        var t = rdtsc();
        for (0..ITERS) |_| inline_x87_v3scale(&vec, &factor, &ro);
        t = rdtsc() - t;
        var s = rdtsc();
        for (0..ITERS) |_| inline_sse_v3scale(&vec, factor, &rs2);
        s = rdtsc() - s;
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
        var t = rdtsc();
        for (0..ITERS) |_| inline_x87_horner(&coeffs, &factor, &rx);
        t = rdtsc() - t;
        var s = rdtsc();
        for (0..ITERS) |_| inline_sse_horner(&coeffs, factor, &rs);
        s = rdtsc() - s;
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
        const of: *const fn (u32, u32) callconv(cc_fc) u32 = origFn(fn (u32, u32) callconv(cc_fc) u32, 0x699330);
        const ov = of(a(&va2), a(&vb2));
        const sv = si_isPointInsideBounds(a(&va2), a(&vb2));
        const ok = ov == sv;
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va2), a(&vb2)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_isPointInsideBounds(a(&va2), a(&vb2)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&va2), a(&vb2)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_vec3Dot(a(&va2), a(&vb2)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { vo = tv3(); of(a(&vo)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { vs = tv3(); si_normalizeVec3InPlace(a(&vs)); } s = rdtsc() - s;
        report("normalizeVec3InPlace", t, s, ok);
    }

    // si_distanceToPlane (525K/7.5s) -- fastcall(point_ECX, plane_EDX, dir_stack) -> f64
    {
        const pt = tv3();
        const plane = [4]f32{ 0.0, 1.0, 0.0, -5.0 }; // y=5 plane
        const dir = Vec3{ 0.0, -1.0, 0.0 }; // pointing down
        const of: *const fn (u32, u32, u32) callconv(cc_fc) f64 = origFn(fn (u32, u32, u32) callconv(cc_fc) f64, 0x6329E0);
        const ov = of(a(&pt), a(&plane), a(&dir));
        const sv = si_distanceToPlane(a(&pt), a(&plane), a(&dir));
        const ok = @abs(ov - sv) < 1e-2;
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&pt), a(&plane), a(&dir)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_distanceToPlane(a(&pt), a(&plane), a(&dir)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&box), a(&ls), a(&le)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_checkBoxLineIntersect(a(&box), a(&ls), a(&le)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&pt), a(&mask_o)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_classifyPointFrustum(a(&planes), a(&pt), a(&mask_s)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&sphere)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_testSphereFrustum(a(&planes), a(&sphere)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&src), a(&dst_o)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_transposeMat4x4(a(&src), a(&dst_s)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&qa), tb, a(&qb)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_quatSlerp(a(&rs), a(&qa), tb, a(&qb)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), ab2); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_createZRotMat3x3(a(&rs), ab2); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&ma), a(&mb)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_mulMat3x4(a(&rs), a(&ma), a(&mb)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { mo = tm4(); _ = of(a(&mo), a(&quat2)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { ms = tm4(); _ = si_rotateMatByQuat(a(&ms), a(&quat2)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&ro), a(&axis2), ab2, 1); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_createRotMat3x4(a(&rs), a(&axis2), ab2, 1); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { mo2 = tmpl2; _ = of(a(&mo2), a(&mb2)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { ms2 = tmpl2; _ = si_mulMat3x4InPlace(a(&ms2), a(&mb2)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { vo = tmpl3; of(a(&vo), lb); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { vs = tmpl3; si_normalizeVec3(a(&vs), lb); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { _ = of(a(&planes), a(&aabb), a(&rot), a(&trans)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { _ = si_testOBBFrustum(a(&planes), a(&aabb), a(&rot), a(&trans)); } s = rdtsc() - s;
        report("testOBBFrustum", t, s, ok);
    }

    // si_calculateSinCos -- stdcall(angle_bits, outSin, outCos) -> void
    {
        const ab2: u32 = @bitCast(@as(f32, 1.2345));
        var sin_o: f32 = undefined;
        var cos_o: f32 = undefined;
        var sin_s: f32 = undefined;
        var cos_s: f32 = undefined;
        const cc_sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };
        const of = origFn(fn (u32, u32, u32) callconv(cc_sc) void, 0x749280);
        of(ab2, a(&sin_o), a(&cos_o));
        si_calculateSinCos(ab2, a(&sin_s), a(&cos_s));
        const ok = compareF32(sin_o, sin_s) and compareF32(cos_o, cos_s);
        var t = rdtsc(); for (0..ITERS) |_| { of(ab2, a(&sin_o), a(&cos_o)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { si_calculateSinCos(ab2, a(&sin_s), a(&cos_s)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { of(a(&obj_bench_o), a(&zero_off)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { si_translateBoundingVol(a(&obj_bench_s), a(&zero_off)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), a(&color)); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { si_addToColorAccumulator(a(&obj_s), a(&color)); } s = rdtsc() - s;
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
        var t = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), 0, rb, gb, bb); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { si_packParticleColor(a(&obj_s), rb, gb, bb); } s = rdtsc() - s;
        report("packParticleColor", t, s, ok);
    }

    // si_setParticleAlpha -- fastcall(obj_ECX, unused_EDX, alpha_stack) -> void
    {
        var obj_o: [320]u8 = std.mem.zeroes([320]u8);
        var obj_s: [320]u8 = std.mem.zeroes([320]u8);
        const ab2: u32 = @bitCast(@as(f32, 0.75));
        const of = origFn(fn (u32, u32, u32) callconv(cc_fc) void, 0x7B7B10);
        of(a(&obj_o), 0, ab2);
        si_setParticleAlpha(a(&obj_s), ab2);
        const ok = obj_o[0x12F] == obj_s[0x12F];
        var t = rdtsc(); for (0..ITERS) |_| { of(a(&obj_o), 0, ab2); } t = rdtsc() - t;
        var s = rdtsc(); for (0..ITERS) |_| { si_setParticleAlpha(a(&obj_s), ab2); } s = rdtsc() - s;
        report("setParticleAlpha", t, s, ok);
    }

    // =========================================================================
    // transform44: SSE implementation benchmark
    // =========================================================================
    {
        print("\n{s}\n", .{"-- transform44 (SSE only, 8 bones, 4 animated) --"});
        const T44_ITERS: u64 = 200_000;

        // Synthetic SceneObject with 8 bones: 4 rotation-animated, 2 translation-animated, 4 static
        var scene_obj: [0x400]u8 align(16) = std.mem.zeroes([0x400]u8);
        var anim_ctx_mem: [0x20]u8 = std.mem.zeroes([0x20]u8);
        var model_ctr_mem: [0x140]u8 = std.mem.zeroes([0x140]u8);
        const BONE_COUNT = 8;
        var model_hdr_mem: [0x200]u8 = std.mem.zeroes([0x200]u8);
        var bone_defs: [BONE_COUNT * 0x6C]u8 = std.mem.zeroes([BONE_COUNT * 0x6C]u8);
        var bone_rt: [BONE_COUNT * 0x118]u8 = std.mem.zeroes([BONE_COUNT * 0x118]u8);
        var bone_out: [BONE_COUNT * 0x40]u8 align(16) = std.mem.zeroes([BONE_COUNT * 0x40]u8);
        var parent_mat: [64]u8 align(16) = undefined;
        const ident = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        @memcpy(parent_mat[0..64], std.mem.asBytes(&ident));

        var rot_ts = [2]u32{ 0, 1000 };
        var rot_vals = [8]f32{ 0, 0, 0, 1, 0.383, 0, 0, 0.924 };
        var trans_ts = [2]u32{ 0, 1000 };
        var trans_vals = [6]f32{ 0, 0, 0, 1, 2, 3 };

        const so = @intFromPtr(&scene_obj);
        const wu = std.mem.writeInt;

        wu(u32, scene_obj[0x10..0x14], 1, .little);
        wu(u32, scene_obj[0x2C..0x30], @intFromPtr(&anim_ctx_mem), .little);
        wu(u32, scene_obj[0x30..0x34], @intFromPtr(&model_ctr_mem), .little);
        wu(u32, scene_obj[0x64..0x68], so + 0x300, .little);
        wu(u32, scene_obj[0x90..0x94], @intFromPtr(&bone_rt), .little);
        wu(u32, scene_obj[0x94..0x98], @intFromPtr(&bone_out), .little);
        for ([_]u32{ 0x180, 0x184, 0x188, 0x18C }) |off| {
            wu(u32, scene_obj[off..][0..4], @as(u32, @bitCast(@as(f32, 1.0))), .little);
        }
        @memcpy(scene_obj[0xFC..0x13C], std.mem.asBytes(&ident));
        @memcpy(scene_obj[0xBC..0xFC], std.mem.asBytes(&ident));

        wu(u32, anim_ctx_mem[0x0C..0x10], 500, .little);
        wu(u32, anim_ctx_mem[0x10..0x14], 1, .little);
        wu(u32, model_ctr_mem[0x130..0x134], @intFromPtr(&model_hdr_mem), .little);
        wu(u32, model_hdr_mem[0x34..0x38], BONE_COUNT, .little);
        wu(u32, model_hdr_mem[0x38..0x3C], @intFromPtr(&bone_defs), .little);

        for (0..BONE_COUNT) |i| {
            const bd = i * 0x6C;
            wu(u16, bone_defs[bd + 0x08 ..][0..2], if (i == 0) 0xFFFF else @as(u16, @intCast(i - 1)), .little);
            if (i < 4) {
                wu(u16, bone_defs[bd + 0x28 ..][0..2], 1, .little);
                wu(u16, bone_defs[bd + 0x2A ..][0..2], 0xFFFF, .little);
                wu(u32, bone_defs[bd + 0x34 ..][0..4], 2, .little);
                wu(u32, bone_defs[bd + 0x38 ..][0..4], @intFromPtr(&rot_ts), .little);
                wu(u32, bone_defs[bd + 0x40 ..][0..4], @intFromPtr(&rot_vals), .little);
            }
            if (i < 2) {
                wu(u16, bone_defs[bd + 0x0C ..][0..2], 1, .little);
                wu(u16, bone_defs[bd + 0x0E ..][0..2], 0xFFFF, .little);
                wu(u32, bone_defs[bd + 0x18 ..][0..4], 2, .little);
                wu(u32, bone_defs[bd + 0x1C ..][0..4], @intFromPtr(&trans_ts), .little);
                wu(u32, bone_defs[bd + 0x24 ..][0..4], @intFromPtr(&trans_vals), .little);
            }
            const br = i * 0x118;
            wu(u32, bone_rt[br + 0xA4 ..][0..4], 0xFFFFFFFF, .little);
            wu(u32, bone_rt[br + 0xD0 ..][0..4], 0xFFFFFFFF, .little);
        }
        wu(u32, bone_rt[0x98..0x9C], 500, .little);

        const pos = [3]f32{ 0, 0, 0 };
        const ofs = [3]f32{ 0, 0, 0 };
        const sb: u32 = @bitCast(@as(f32, 1.0));

        const transformImpl_SSE = @extern(*const fn (u32, u32, u32, u32, u32) callconv(.c) void, .{ .name = "transformImpl_SSE" });

        // Warmup
        for (0..1000) |_| {
            wu(u32, scene_obj[0x40..0x44], 0, .little);
            transformImpl_SSE(so, @intFromPtr(&parent_mat), @intFromPtr(&pos), @intFromPtr(&ofs), sb);
        }

        // Benchmark
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| {
            wu(u32, scene_obj[0x40..0x44], 0, .little);
            const t = rdtsc();
            for (0..T44_ITERS) |_| {
                wu(u32, scene_obj[0x40..0x44], 0, .little);
                transformImpl_SSE(so, @intFromPtr(&parent_mat), @intFromPtr(&pos), @intFromPtr(&ofs), sb);
            }
            const elapsed = rdtsc() - t;
            if (elapsed < best) best = elapsed;
        }

        const avg = best / T44_ITERS;
        print("  {d} cycles/call (best of 5 runs, {d}K iterations)\n", .{ avg, T44_ITERS / 1000 });
    }

    print("\n", .{});
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

    var t = rdtsc();
    for (0..ITERS) |_| { _ = of(a(&ro), a(&param_a), a(&param_b)); }
    t = rdtsc() - t;
    var s = rdtsc();
    for (0..ITERS) |_| { _ = sse_fn(a(&rs), a(&param_a), a(&param_b)); }
    s = rdtsc() - s;
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

    var t = rdtsc();
    for (0..ITERS) |_| { so = self_init; _ = of(a(&so), a(&param)); }
    t = rdtsc() - t;
    var s = rdtsc();
    for (0..ITERS) |_| { ss = self_init; _ = sse_fn(a(&ss), a(&param)); }
    s = rdtsc() - s;
    report(name, t, s, ok);
}

// =========================================================================
// Inlined x87 / SSE implementations (AT&T syntax for x87 inline asm)
// =========================================================================

const V4 = @Vector(4, f32);

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
