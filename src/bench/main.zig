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

fn mapGameConstants() bool {
    const mem = posix.mmap(
        @ptrFromInt(0x007ff000), 4096,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1, 0,
    ) catch return false;
    const p: *f32 = @ptrCast(@alignCast(&mem[0x9d8]));
    p.* = 1.0;
    return true;
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
    if (!mapGameConstants()) {
        print("WARNING: could not map game constants at 0x7ff000\n", .{});
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
        const of: *const fn (u32, u32) callconv(cc_fc) f64 = @ptrCast(makeExecutable(&originals.dotProduct) orelse unreachable);
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
