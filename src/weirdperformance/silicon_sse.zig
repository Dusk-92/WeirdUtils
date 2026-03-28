//! SSE math implementations for silicon module.
//!
//! Pure math functions extracted from silicon.zig for standalone compilation.
//! Used by both the DLL (via silicon.zig wrappers) and the bench harness.
//! All functions use C ABI (export fn) — callers handle CC translation.
//!
//! Compiled with SSE4.1+FMA+AVX. Uses @Vector(4, f32) and @mulAdd throughout.

const std = @import("std");
const V4 = @Vector(4, f32);
const CC = std.builtin.CallingConvention;
const TC: CC = .{ .x86_thiscall = .{} };
const FC: CC = .{ .x86_fastcall = .{} };
const SC: CC = .{ .x86_stdcall = .{} };

inline fn loadV4(ptr: u32) V4 {
    return @as(*align(1) const V4, @ptrFromInt(ptr)).*;
}

inline fn loadV3_1(ptr: u32) V4 {
    const p: [*]const f32 = @ptrFromInt(ptr);
    return V4{ p[0], p[1], p[2], 1.0 };
}

inline fn dot3v(a: V4, b: V4) f32 {
    return @mulAdd(f32, a[2], b[2], @mulAdd(f32, a[1], b[1], a[0] * b[0]));
}

inline fn dot4v(a: V4, b: V4) f32 {
    return @mulAdd(f32, a[3], b[3], @mulAdd(f32, a[2], b[2], @mulAdd(f32, a[1], b[1], a[0] * b[0])));
}

/// Fast reciprocal via vrcpss + Newton-Raphson. ~5 cycles, ~23-bit accuracy (vs vdivss ~14 cycles).
inline fn fastRecip(x: f32) f32 {
    var rcp: f32 = undefined;
    // vrcpss: 12-bit approximation of 1/x
    rcp = asm ("vrcpss %[x], %[x], %[rcp]"
        : [rcp] "=x" (-> f32),
        : [x] "x" (x),
    );
    // Newton-Raphson: rcp = rcp * (2 - x * rcp)
    return rcp * @mulAdd(f32, -x, rcp, 2.0);
}

/// Round float to nearest integer via cvtss2si (uses MXCSR rounding mode, default = round-to-nearest).
/// Single instruction, replaces @round + @intFromFloat (~6 instructions).
inline fn cvtss2si(x: f32) i32 {
    return asm ("vcvtss2si %[x], %[out]"
        : [out] "=r" (-> i32),
        : [x] "x" (x),
    );
}

// --- 0x4549C0: normalizeVec3 (137K/7.5s) ---
// Naked thiscall: ECX=vec, [ESP+4]=length_bits. RET 4. Original: 38 bytes.
// rcpss + NR for fast reciprocal, then 3 multiplies.
pub fn si_normalizeVec3() callconv(.naked) void {
    asm volatile (
        // xmm0 = 1.0 / length (via rcpss + Newton-Raphson)
        \\vmovss 4(%%esp), %%xmm0
        \\vrcpss %%xmm0, %%xmm0, %%xmm1
        \\vmulss %%xmm1, %%xmm0, %%xmm2
        \\vaddss %%xmm1, %%xmm1, %%xmm0
        \\vfnmadd231ss %%xmm1, %%xmm2, %%xmm0
        // xmm0 = refined 1/length. Multiply 3 components.
        \\vmulss (%%ecx), %%xmm0, %%xmm1
        \\vmovss %%xmm1, (%%ecx)
        \\vmulss 4(%%ecx), %%xmm0, %%xmm1
        \\vmovss %%xmm1, 4(%%ecx)
        \\vmulss 8(%%ecx), %%xmm0, %%xmm1
        \\vmovss %%xmm1, 8(%%ecx)
        \\ret $4
    );
}

// --- 0x7BAE60: mulMat3x4 ---
// out = A * B (3x4 layout: 3x3 rotation + 3 translation)
// Layout: [r0c0 r0c1 r0c2 | r1c0 r1c1 r1c2 | r2c0 r2c1 r2c2 | tx ty tz]
// V4 per row: broadcast b[row*3+k], multiply with a's columns, accumulate.
pub fn si_mulMat3x4(out: u32, a_ptr: u32, b_ptr: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const aa: [*]const f32 = @ptrFromInt(a_ptr);
    const b: [*]const f32 = @ptrFromInt(b_ptr);

    // a is row-major 3x3. a[0..2] = row 0, a[3..5] = row 1, a[6..8] = row 2.
    // The formula: dst[row*3+col] = a[col]*b[row*3] + a[col+3]*b[row*3+1] + a[col+6]*b[row*3+2]
    // This means: for each output row, we broadcast b's row elements and dot with a's "columns"
    // a's "column k" is {a[k], a[k+3], a[k+6]} — that's picking one element from each of a's rows.

    // Load a's columns (stride 3)
    const ac0 = V4{ aa[0], aa[3], aa[6], aa[9] };  // col 0 of a (+ translation x)
    const ac1 = V4{ aa[1], aa[4], aa[7], aa[10] }; // col 1 of a (+ translation y)
    const ac2 = V4{ aa[2], aa[5], aa[8], aa[11] }; // col 2 of a (+ translation z)

    // Rotation: 3 output rows
    inline for (0..3) |row| {
        const br0: V4 = @splat(b[row * 3]);
        const br1: V4 = @splat(b[row * 3 + 1]);
        const br2: V4 = @splat(b[row * 3 + 2]);
        const result = @mulAdd(V4, ac2, br2, @mulAdd(V4, ac1, br1, ac0 * br0));
        dst[row * 3] = result[0];
        dst[row * 3 + 1] = result[1];
        dst[row * 3 + 2] = result[2];
    }

    // Translation: dst[9+i] = a_trans dot b_col_i + b_trans[i]
    // = ac0[3]*b[i] + ac1[3]*b[i+3] + ac2[3]*b[i+6] + b[9+i]
    // Using the V4 approach: broadcast b elements, same ac columns, take lane 3 + add b_trans
    // Translation: scalar @mulAdd (b's columns don't align for V4)
    inline for (0..3) |col| {
        dst[9 + col] = @mulAdd(f32, aa[11], b[col + 6], @mulAdd(f32, aa[10], b[col + 3], @mulAdd(f32, aa[9], b[col], b[9 + col])));
    }

    return out;
}

// --- 0x7BDDB0: rotateMatByQuat ---
// builds rotation matrix from quaternion, multiplies with existing 4x4 matrix
// Uses V4 for the matrix multiply (same pattern as bone_sse)
pub fn si_rotateMatByQuat(mat: u32, quat: u32) callconv(TC) u32 {
    const q: [*]const f32 = @ptrFromInt(quat);
    const x = q[0]; const y = q[1]; const z = q[2]; const w = q[3];
    const x2 = x + x; const y2 = y + y; const z2 = z + z;
    const xx = x * x2; const xy = x * y2; const xz = x * z2;
    const yy = y * y2; const yz = y * z2; const zz = z * z2;
    const wx = w * x2; const wy = w * y2; const wz = w * z2;

    const q0 = V4{ 1.0 - (yy + zz), xy + wz, xz - wy, 0 };
    const q1 = V4{ xy - wz, 1.0 - (xx + zz), yz + wx, 0 };
    const q2 = V4{ xz + wy, yz - wx, 1.0 - (xx + yy), 0 };

    const m: [*]f32 = @ptrFromInt(mat);
    const m0 = V4{ m[0], m[1], m[2], m[3] };
    const m1 = V4{ m[4], m[5], m[6], m[7] };
    const m2 = V4{ m[8], m[9], m[10], m[11] };
    const m3 = V4{ m[12], m[13], m[14], m[15] };

    inline for ([_]struct { q: V4, off: u32 }{ .{ .q = q0, .off = 0 }, .{ .q = q1, .off = 4 }, .{ .q = q2, .off = 8 } }) |r| {
        const row = @mulAdd(V4, @as(V4, @splat(r.q[2])), m2, @mulAdd(V4, @as(V4, @splat(r.q[1])), m1, @as(V4, @splat(r.q[0])) * m0));
        m[r.off] = row[0]; m[r.off + 1] = row[1]; m[r.off + 2] = row[2]; m[r.off + 3] = row[3];
    }
    // Row 3 unchanged (identity row)
    m[12] = m3[0]; m[13] = m3[1]; m[14] = m3[2]; m[15] = m3[3];
    return mat;
}

// --- 0x7BB860: createRotMat3x4 ---
// Rodrigues rotation matrix, 3x4 layout. Uses @mulAdd for all 9 entries.
pub fn si_createRotMat3x4(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) callconv(FC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0]; var y = ax[1]; var z = ax[2];
    if (is_normalized == 0) {
        const len = @sqrt(@mulAdd(f32, z, z, @mulAdd(f32, y, y, x * x)));
        if (len > 1.0e-20) { const inv = 1.0 / len; x *= inv; y *= inv; z *= inv; }
    }
    const angle: f32 = @bitCast(angle_bits);
    // x87 FSINCOS: single instruction computes both sin and cos
    // FSINCOS tested at 148cy — x87 microcode is slow on modern CPUs.
    // Library sinf+cosf (~35cy each = 70cy total) is 2x faster.
    const c = @cos(angle); const s = @sin(angle); const t = 1.0 - c;
    m[0] = @mulAdd(f32, t * x, x, c);    m[1] = @mulAdd(f32, s, z, t * x * y); m[2] = @mulAdd(f32, -s, y, t * x * z);
    m[3] = @mulAdd(f32, -s, z, t * x * y); m[4] = @mulAdd(f32, t * y, y, c);   m[5] = @mulAdd(f32, s, x, t * y * z);
    m[6] = @mulAdd(f32, s, y, t * x * z); m[7] = @mulAdd(f32, -s, x, t * y * z); m[8] = @mulAdd(f32, t * z, z, c);
    m[9] = 0; m[10] = 0; m[11] = 0;
    return out;
}

// --- 0x6329E0: distanceToPlane (525K/7.5s) ---
// __fastcall(ECX=point, EDX=plane, stack=direction), returns f64 via ST(0), RET 0x4.
pub fn si_distanceToPlane(point: u32, plane: u32, direction: u32) callconv(FC) f64 {
    const p: [*]const f32 = @ptrFromInt(point);
    const pl: [*]const f32 = @ptrFromInt(plane);
    const dir: [*]const f32 = @ptrFromInt(direction);
    const dot1 = @mulAdd(f32, p[2], pl[2], @mulAdd(f32, p[1], pl[1], @mulAdd(f32, p[0], pl[0], pl[3])));
    const dot2 = @mulAdd(f32, dir[2], pl[2], @mulAdd(f32, dir[1], pl[1], dir[0] * pl[0]));
    if (@abs(dot2) < 1.0e-20) return 0.0;
    return @as(f64, dot1) / @as(f64, dot2);
}


// --- 0x686C20: classifyPointFrustum (3.2M/7.5s) ---
// Tests point against 6 frustum planes, produces 6-bit bitmask.
// Scalar @mulAdd dot4 per plane — the FMA chain has best throughput for this pattern.
// Tried: V4 batch 4 planes (gather kills it), V4 hsum (shuffle overhead kills it).
pub fn si_classifyPointFrustum(planes_ptr: u32, point: u32, out_mask: u32) callconv(TC) u32 {
    const mask: *u32 = @ptrFromInt(out_mask);
    const pt = loadV3_1(point);
    var bits: u32 = 0;
    inline for (0..6) |i| {
        const pl = loadV4(planes_ptr + i * 16);
        const dist = dot4v(pt, pl);
        // Branchless: extract sign bit via bit cast
        bits |= (@as(u32, @bitCast(dist)) >> 31) << i;
    }
    mask.* = bits;
    return planes_ptr;
}

// --- 0x6DC5A0: checkBoxLineIntersect (2.7M/7.5s) ---
// Slab AABB test. Branchless min/max for t0/t1 swap and tmin/tmax accumulation.
pub fn si_checkBoxLineIntersect(box_ptr: u32, line_start: u32, line_end: u32) callconv(FC) u32 {
    const bmin: [*]const f32 = @ptrFromInt(box_ptr);
    const bmax: [*]const f32 = @ptrFromInt(box_ptr + 0xC);
    const start: [*]const f32 = @ptrFromInt(line_start);
    const end_pt: [*]const f32 = @ptrFromInt(line_end);
    var tmin: f32 = 0.0;
    var tmax: f32 = 1.0;
    inline for (0..3) |i| {
        const dir = end_pt[i] - start[i];
        if (@abs(dir) < 1.0e-20) {
            if (start[i] < bmin[i] or start[i] > bmax[i]) return 0;
        } else {
            const inv_dir = 1.0 / dir;
            const ta = (bmin[i] - start[i]) * inv_dir;
            const tb = (bmax[i] - start[i]) * inv_dir;
            // Branchless swap: vminss/vmaxss instead of compare+branch
            tmin = @max(tmin, @min(ta, tb));
            tmax = @min(tmax, @max(ta, tb));
            if (tmin > tmax) return 0;
        }
    }
    return 1;
}

// --- 0x6869C0: testOBBFrustum ---
// Tests OBB against 6 frustum planes. Uses V4 for corner transform and plane test.
pub fn si_testOBBFrustum(planes_ptr: u32, aabb_ptr: u32, rot_ptr: u32, trans_ptr: u32) callconv(TC) u32 {
    const aabb: [*]const f32 = @ptrFromInt(aabb_ptr);
    const rot: [*]const f32 = @ptrFromInt(rot_ptr);
    const t: [*]const f32 = @ptrFromInt(trans_ptr);

    // Rotation columns as V4 (xyz + 0 for w)
    const rc0 = V4{ rot[0], rot[1], rot[2], 0 };
    const rc1 = V4{ rot[3], rot[4], rot[5], 0 };
    const rc2 = V4{ rot[6], rot[7], rot[8], 0 };
    const tv = V4{ t[0], t[1], t[2], 1.0 };

    // AABB extents
    const mn = [3]f32{ aabb[0], aabb[1], aabb[2] };
    const mx = [3]f32{ aabb[3], aabb[4], aabb[5] };

    // Build 8 corners as V4 (xyz + 1.0 for plane dot w/ d term)
    var corners: [8]V4 = undefined;
    inline for (0..8) |i| {
        const lx: f32 = if (i & 1 != 0) mx[0] else mn[0];
        const ly: f32 = if (i & 2 != 0) mx[1] else mn[1];
        const lz: f32 = if (i & 4 != 0) mx[2] else mn[2];
        corners[i] = @mulAdd(V4, @as(V4, @splat(lz)), rc2, @mulAdd(V4, @as(V4, @splat(ly)), rc1, @mulAdd(V4, @as(V4, @splat(lx)), rc0, tv)));
    }

    // Extract x/y/z/w components across corners for batched plane tests
    // Group A: corners 0-3, Group B: corners 4-7
    const cx_a = V4{ corners[0][0], corners[1][0], corners[2][0], corners[3][0] };
    const cy_a = V4{ corners[0][1], corners[1][1], corners[2][1], corners[3][1] };
    const cz_a = V4{ corners[0][2], corners[1][2], corners[2][2], corners[3][2] };

    const cx_b = V4{ corners[4][0], corners[5][0], corners[6][0], corners[7][0] };
    const cy_b = V4{ corners[4][1], corners[5][1], corners[6][1], corners[7][1] };
    const cz_b = V4{ corners[4][2], corners[5][2], corners[6][2], corners[7][2] };

    // Test each plane: compute 4 dots at a time, branchless sign check
    inline for (0..6) |p| {
        const pl = loadV4(planes_ptr + p * 16);
        const pnx: V4 = @splat(pl[0]);
        const pny: V4 = @splat(pl[1]);
        const pnz: V4 = @splat(pl[2]);
        const pd: V4 = @splat(pl[3]);

        // 4 dots for corners 0-3
        const da = @mulAdd(V4, cz_a, pnz, @mulAdd(V4, cy_a, pny, @mulAdd(V4, cx_a, pnx, pd)));
        // 4 dots for corners 4-7
        const db = @mulAdd(V4, cz_b, pnz, @mulAdd(V4, cy_b, pny, @mulAdd(V4, cx_b, pnx, pd)));

        // All outside if all 8 distances are negative
        // Branchless: extract sign bits via comparison
        const neg_a = da < @as(V4, @splat(@as(f32, 0)));
        const neg_b = db < @as(V4, @splat(@as(f32, 0)));
        const mask_a: u4 = @bitCast(neg_a);
        const mask_b: u4 = @bitCast(neg_b);
        if (mask_a == 0xF and mask_b == 0xF) return 0;
    }
    return 3;
}

// --- 0x686B80: testSphereFrustum (375K/7.5s) ---
// Zig thiscall: naked asm tested at 10cy (vhaddps slow), Zig dot4v at 8cy.
pub fn si_testSphereFrustum(planes_ptr: u32, sphere: u32) callconv(TC) u32 {
    const s: [*]const f32 = @ptrFromInt(sphere);
    const center = V4{ s[0], s[1], s[2], 1.0 };
    const r = s[3];
    inline for (0..6) |i| {
        const pl = loadV4(planes_ptr + i * 16);
        if (dot4v(center, pl) < -r) return 0;
    }
    return 3;
}


// --- 0x7C0570: quatSlerp ---
// V4 for final blend, @mulAdd for dot product
pub fn si_quatSlerp(out: u32, a_ptr: u32, t_bits: u32, b_ptr: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const av = loadV4(a_ptr);
    const bv = loadV4(b_ptr);
    const tt: f32 = @bitCast(t_bits);
    var dot_val = dot4v(av, bv);
    var sign: f32 = 1.0;
    if (dot_val < 0) { dot_val = -dot_val; sign = -1.0; }
    var s0: f32 = undefined;
    var s1: f32 = undefined;
    if (dot_val > 0.9995) {
        s0 = 1.0 - tt;
        s1 = tt * sign;
    } else {
        const theta = std.math.acos(dot_val);
        const sin_theta = @sin(theta);
        const inv_sin = 1.0 / sin_theta;
        s0 = @sin((1.0 - tt) * theta) * inv_sin;
        s1 = @sin(tt * theta) * inv_sin * sign;
    }
    const result = @mulAdd(V4, @as(V4, @splat(s1)), bv, @as(V4, @splat(s0)) * av);
    dst[0] = result[0]; dst[1] = result[1]; dst[2] = result[2]; dst[3] = result[3];
    return out;
}

// --- 0x699330: isPointInsideBounds (1.7M/7.5s) ---
// __fastcall(ECX=a, EDX=b), returns u32.
pub fn si_isPointInsideBounds(a: u32, b: u32) callconv(FC) u32 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    if (vb[0] <= va[0] and vb[1] <= va[1] and vb[2] <= va[2]) return 1;
    return 0;
}

// --- 0x749280: calculateSinCos ---
pub fn si_calculateSinCos(angle_bits: u32, out_sin: u32, out_cos: u32) callconv(SC) void {
    const angle: f32 = @bitCast(angle_bits);
    const sp: *f32 = @ptrFromInt(out_sin);
    const cp: *f32 = @ptrFromInt(out_cos);
    sp.* = @sin(angle);
    cp.* = @cos(angle);
}

// --- 0x7BE5B0: createZRotMat3x3 ---
pub fn si_createZRotMat3x3(out: u32, angle_bits: u32) callconv(TC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle); const s = @sin(angle);
    m[0] = c;  m[1] = s;  m[2] = 0;
    m[3] = -s; m[4] = c;  m[5] = 0;
    m[6] = 0;  m[7] = 0;  m[8] = 1;
    return out;
}

// --- 0x7BCEF0: transposeMat4x4 ---
// Naked thiscall: ECX=src, [ESP+4]=dst. RET 4. Original: 156 bytes.
// SSE unpacklo/unpackhi transpose: 4 loads + 4 shuffles + 4 stores.
pub fn si_transposeMat4x4() callconv(.naked) void {
    asm volatile (
        \\mov 4(%%esp), %%eax
        // Load 4 rows from src (ECX)
        \\vmovups (%%ecx), %%xmm0
        \\vmovups 16(%%ecx), %%xmm1
        \\vmovups 32(%%ecx), %%xmm2
        \\vmovups 48(%%ecx), %%xmm3
        // Transpose via unpacklo/unpackhi
        \\vunpcklps %%xmm1, %%xmm0, %%xmm4
        \\vunpckhps %%xmm1, %%xmm0, %%xmm5
        \\vunpcklps %%xmm3, %%xmm2, %%xmm6
        \\vunpckhps %%xmm3, %%xmm2, %%xmm7
        // Combine into final columns
        \\vmovlhps %%xmm6, %%xmm4, %%xmm0
        \\vmovhlps %%xmm4, %%xmm6, %%xmm1
        \\vmovlhps %%xmm7, %%xmm5, %%xmm2
        \\vmovhlps %%xmm5, %%xmm7, %%xmm3
        // Store to dst (EAX)
        \\vmovups %%xmm0, (%%eax)
        \\vmovups %%xmm1, 16(%%eax)
        \\vmovups %%xmm2, 32(%%eax)
        \\vmovups %%xmm3, 48(%%eax)
        // Return src in EAX
        \\mov %%ecx, %%eax
        \\ret $4
    );
}

// --- 0x7BB420: mulMat3x4InPlace ---
// this = this * matB. V4 columns loaded upfront, write directly back (no tmp needed).
pub fn si_mulMat3x4InPlace(mat_a: u32, mat_b: u32) callconv(TC) u32 {
    const a: [*]f32 = @ptrFromInt(mat_a);
    const b: [*]const f32 = @ptrFromInt(mat_b);

    // Load everything into locals to eliminate aliasing
    const ac0 = V4{ a[0], a[3], a[6], a[9] };
    const ac1 = V4{ a[1], a[4], a[7], a[10] };
    const ac2 = V4{ a[2], a[5], a[8], a[11] };
    const b_local: [12]f32 = .{ b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11] };

    // Rotation: write directly back to a
    inline for (0..3) |row| {
        const br0: V4 = @splat(b_local[row * 3]);
        const br1: V4 = @splat(b_local[row * 3 + 1]);
        const br2: V4 = @splat(b_local[row * 3 + 2]);
        const result = @mulAdd(V4, ac2, br2, @mulAdd(V4, ac1, br1, ac0 * br0));
        a[row * 3] = result[0];
        a[row * 3 + 1] = result[1];
        a[row * 3 + 2] = result[2];
    }

    // Translation
    inline for (0..3) |col| {
        a[9 + col] = @mulAdd(f32, ac2[3], b_local[col + 6], @mulAdd(f32, ac1[3], b_local[col + 3], @mulAdd(f32, ac0[3], b_local[col], b_local[9 + col])));
    }

    return mat_a;
}

// --- 0x6720F0: normalizeVec3InPlace ---
// sqrt + reciprocal. 14cy (2.2x). rsqrt+NR tested at 15cy — no gain, compiler's
// vsqrtss+vdivss pipeline is already optimal for scalar inverse sqrt.
pub fn si_normalizeVec3InPlace(vec: u32) callconv(TC) void {
    const v: [*]f32 = @ptrFromInt(vec);
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len > 1.0e-20) {
        const inv = 1.0 / len;
        v[0] *= inv;
        v[1] *= inv;
        v[2] *= inv;
    }
}

// --- 0x71BC70: addVec3ToAccumulator (136K/7.5s) ---
// thiscall(ECX=this, stack=vec). Scale is a global at 0x81207C, NOT a parameter.
pub fn si_addVec3ToAccumulator(this: u32, vec: u32) callconv(TC) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const v: [*]const f32 = @ptrFromInt(vec);
    const scale: f32 = @as(*const f32, @ptrFromInt(0x81207C)).*;
    obj[21] += v[0];
    obj[22] += v[1];
    obj[23] += v[2];
    obj[33] = @mulAdd(f32, v[0], scale, obj[33]);
    obj[42] = @mulAdd(f32, v[1], scale, obj[42]);
    obj[51] = @mulAdd(f32, v[2], scale, obj[51]);
}

// --- 0x71BF60: addToColorAccumulator (10K/7.5s) ---
// Naked thiscall: ECX=this, [ESP+4]=color_ptr. RET 4. Original: 34 bytes.
// 3 SSE adds at this+0x6C from color[0..2].
pub fn si_addToColorAccumulator() callconv(.naked) void {
    asm volatile (
        \\mov 4(%%esp), %%eax
        \\vmovss (%%eax), %%xmm0
        \\vaddss 0x6C(%%ecx), %%xmm0, %%xmm0
        \\vmovss %%xmm0, 0x6C(%%ecx)
        \\vmovss 4(%%eax), %%xmm0
        \\vaddss 0x70(%%ecx), %%xmm0, %%xmm0
        \\vmovss %%xmm0, 0x70(%%ecx)
        \\vmovss 8(%%eax), %%xmm0
        \\vaddss 0x74(%%ecx), %%xmm0, %%xmm0
        \\vmovss %%xmm0, 0x74(%%ecx)
        \\ret $4
    );
}

// --- 0x7B7A80: packParticleColor (2K/7.5s) ---
// V4 multiply + clamp, then packed round+convert via @Vector(4, i32) for all channels at once.
pub fn si_packParticleColor(obj: u32, r_bits: u32, g_bits: u32, b_bits: u32) callconv(TC) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const out: *align(1) u32 = @ptrCast(base + 0x12C);
    const alpha = base[0x12F];
    const rgb = V4{ @bitCast(r_bits), @bitCast(g_bits), @bitCast(b_bits), 0 } * @as(V4, @splat(@as(f32, 255.0)));
    const clamped = @min(@max(rgb, @as(V4, @splat(@as(f32, 0.0)))), @as(V4, @splat(@as(f32, 255.0))));
    // Packed round + convert: single roundps + cvtps2dq (SSE4.1)
    const rounded = @round(clamped);
    const ints: @Vector(4, i32) = @intFromFloat(rounded);
    out.* = @as(u32, alpha) << 24 | @as(u32, @intCast(ints[0])) << 16 | @as(u32, @intCast(ints[1])) << 8 | @as(u32, @intCast(ints[2]));
}

// --- 0x7B7B10: setParticleAlpha (2K/7.5s) ---
// Naked fastcall: ECX=obj, [ESP+4]=alpha_bits. RET 4.
// Clamp alpha*255 to [0,255], write byte to obj+0x12F.
pub fn si_setParticleAlpha() callconv(.naked) void {
    asm volatile (
        \\vmovss 4(%%esp), %%xmm0
        \\mov $0x437F0000, %%eax
        \\vmovd %%eax, %%xmm1
        \\vmulss %%xmm1, %%xmm0, %%xmm0
        \\vxorps %%xmm2, %%xmm2, %%xmm2
        \\vmaxss %%xmm2, %%xmm0, %%xmm0
        \\vminss %%xmm1, %%xmm0, %%xmm0
        \\vcvtss2si %%xmm0, %%eax
        \\mov %%al, 0x12F(%%ecx)
        \\ret $4
    );
}


// --- 0x40A2B0: __ftol ---
// Drop-in binary replacement. Input: ST(0). Output: EAX:EDX (i64).
// SSE3 FISTTP: truncate directly from x87 (9 bytes, replaces 39-byte original)
pub fn si_ftol() callconv(.naked) void {
    asm volatile (
        \\sub $8, %%esp
        \\fisttpll (%%esp)
        \\pop %%eax
        \\pop %%edx
        \\ret
    );
}

// --- 0x602630: vec3Dot (31K/7.5s) ---
// __fastcall(ECX=a, EDX=b), returns f64 via ST(0).
pub fn si_vec3Dot(a: u32, b: u32) callconv(FC) f64 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    return @floatCast(@mulAdd(f32, va[2], vb[2], @mulAdd(f32, va[1], vb[1], va[0] * vb[0])));
}

// --- 0x686820: translateBoundingVol ---
// @mulAdd for plane distances. Scalar corner adds (stride 3 — V4 unaligned tested, slower).
pub fn si_translateBoundingVol(this: u32, offset: u32) callconv(TC) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const off: [*]const f32 = @ptrFromInt(offset);
    const dx = off[0]; const dy = off[1]; const dz = off[2];
    inline for (0..8) |i| {
        const base = 24 + i * 3;
        obj[base] += dx;
        obj[base + 1] += dy;
        obj[base + 2] += dz;
    }
    inline for (0..6) |i| {
        const base = i * 4;
        obj[base + 3] -= @mulAdd(f32, obj[base + 2], dz, @mulAdd(f32, obj[base + 1], dy, obj[base] * dx));
    }
    obj[48] += dx; obj[49] += dy; obj[50] += dz;
    obj[51] += dx; obj[52] += dy; obj[53] += dz;
}

// --- 0x686000: FrustumCullBoundingBox ---
// Transforms bbox through view-proj matrix, perspective divides, projects to 320-column
// occlusion buffer. Returns 0 (culled) / 2 (visible).
// Original: 380 bytes, 2 calls to mat*vec3 (0x7BCA80), x87 perspective divide, x87 column scan.
// SSE: inline V4 mat*vec3, SSE perspective divide, 4-wide column scan.
// __fastcall(bbox_ECX, flags_EDX, radius_stack), RET 0x4
pub fn si_frustumCullBBox(bbox: u32, flags: u32, radius_bits: u32) callconv(FC) u32 {
    // Early out: global occlusion flag bit 5
    if ((@as(*const u8, @ptrFromInt(0xC7B2A4)).* & 0x20) == 0) return 0;

    // Early out: radius too small
    const radius: f32 = @bitCast(radius_bits);
    const epsilon: f32 = @bitCast(@as(*const u32, @ptrFromInt(0x8029D4)).*);
    if (@abs(radius) < epsilon) return 0;

    // Early out: global value must be in valid range [const1, const2]
    const global_val: f32 = @as(*align(1) const f32, @ptrFromInt(0xC7CFF4)).*;
    if (global_val < @as(*align(1) const f32, @ptrFromInt(0x8101AC)).*) return 0;
    if (global_val > @as(*align(1) const f32, @ptrFromInt(0x804588)).*) return 0;

    // Transform center through view-proj matrix (column-major 4x4 at 0xC7B700)
    // Inlined 0x7BCA80: result = col0*v.x + col1*v.y + col2*v.z + col3
    const bp: [*]const f32 = @ptrFromInt(bbox);
    const vx: V4 = @splat(bp[0]);
    const vy: V4 = @splat(bp[1]);
    const vz: V4 = @splat(bp[2]);

    const m1: u32 = 0xC7B700;
    const center = @mulAdd(V4, vz, loadV4(m1 + 32), @mulAdd(V4, vy, loadV4(m1 + 16), @mulAdd(V4, vx, loadV4(m1), loadV4(m1 + 48))));

    // Transform extent {radius, radius, 0} through matrix at 0xC7D280
    const rv: V4 = @splat(radius);
    const m2: u32 = 0xC7D280;
    // z=0, so skip col2 term
    const extent = @mulAdd(V4, rv, loadV4(m2 + 16), @mulAdd(V4, rv, loadV4(m2), loadV4(m2 + 48)));

    // Behind-camera check (unless flags & 8)
    if ((flags & 0x8) == 0) {
        if (center[2] < @as(*align(1) const f32, @ptrFromInt(0x80FED4)).*) return 0;
    }

    // Perspective divide: inv_w = K * rcpss(center.z) with Newton-Raphson refinement.
    // vrcpss + NR: ~5 cycles vs vdivss ~14 cycles. Column indices only need ~1px accuracy.
    const K: f32 = @as(*align(1) const f32, @ptrFromInt(0x7FF9D8)).*;
    const cz = center[2];
    const inv_w = K * fastRecip(cz);
    const cx = center[0] * inv_w;
    const ex = extent[0] * inv_w;
    const ey = extent[1] * inv_w;
    const depth = @mulAdd(f32, center[1], inv_w, ex);

    // Column projection: convert to 320-column indices
    const col_scale: f32 = @as(*align(1) const f32, @ptrFromInt(0x810170)).*;
    const col_offset: f32 = @as(*align(1) const f32, @ptrFromInt(0x86861C)).*;

    // cvtss2si: round-to-nearest in one instruction (MXCSR default mode).
    // Replaces @round + @intFromFloat which generates vroundss + sign handling (~6 insns).
    var left_col: i32 = cvtss2si(@mulAdd(f32, cx - ey, col_scale, -col_offset));
    left_col += 0xA0;
    var right_col: i32 = cvtss2si(@mulAdd(f32, ey + cx, col_scale, -col_offset));
    right_col += 0xA1;

    // Bounds check — off-screen culling
    if (left_col >= 0x140) return 0; // fully right of screen (320)
    if (right_col < 0) return 0; // fully left of screen
    if (left_col < 0) left_col = 0;
    if (right_col >= 0x140) right_col = 0x13F; // clamp to 319
    if (left_col > right_col) return 2; // degenerate → visible

    // Horizon buffer scan: 320 floats at 0xC7B750
    // If any column's horizon value < depth → culled (return 0)
    // SSE: test 4 columns at once
    const horizon_base: u32 = 0xC7B750;
    var col: u32 = @intCast(left_col);
    const end: u32 = @intCast(right_col);
    const depth_v: V4 = @splat(depth);

    // 4-wide scan
    while (col + 3 <= end) {
        const h = loadV4(horizon_base + col * 4);
        const lt_bits: u4 = @bitCast(h < depth_v);
        if (lt_bits != 0) return 0;
        col += 4;
    }
    // Scalar remainder
    while (col <= end) {
        if (@as(*align(1) const f32, @ptrFromInt(horizon_base + col * 4)).* < depth) return 0;
        col += 1;
    }

    return 2; // visible — survived all columns
}

// --- 0x6ABC40: processLinkedListCollision ---
// Walks intrusive linked list, per-node AABB overlap test, calls addGeometryToBuffer on hit.
// Original: 329 bytes, 6 x87 FCOMP/FNSTSW comparisons per node.
// SSE: 2 V4 loads + 2 CMPPS + AND + MOVMSK replaces the 6 scalar comparisons.
//
// __fastcall(listHead_ECX, queryBox_EDX, resultBuf_stack, flags_stack), RET 0x8
// addGeometryToBuffer at 0x6ABD90: __fastcall(queryBox_ECX, nodeData_EDX, resultBuf_stack), RET 0x4
// Visited sentinel: *(u32*)0xC89F20
pub fn si_processLinkedListCollision(list_head: u32, query_box: u32, result_buf: u32, flags: u32) callconv(FC) u32 {
    if ((flags & 0xF0000F) == 0) return 1;

    const addGeometryToBuffer: *const fn (u32, u32, u32) callconv(FC) void = @ptrFromInt(0x6ABD90);

    // Load query box min/max as V4 for SSE AABB test
    // queryBox layout: min(+0,+4,+8), max(+0xC,+0x10,+0x14)
    const q_min = loadV4(query_box); // {qmin.x, qmin.y, qmin.z, <garbage>}
    const q_max = loadV4(query_box + 0x0C); // {qmax.x, qmax.y, qmax.z, <garbage>}

    const sentinel = @as(*const u32, @ptrFromInt(0xC89F20)).*;
    const link_offset = @as(*const u32, @ptrFromInt(list_head)).*;

    // First node: listHead[2] (offset +8)
    var node: u32 = @as(*const u32, @ptrFromInt(list_head + 8)).*;

    // Linked list tag bit: bit 0 set = end sentinel
    if (node & 1 != 0 or node == 0) return 1;

    while (node & 1 == 0 and node != 0) {
        const node_data = @as(*const u32, @ptrFromInt(node + 4)).*;
        const prev_node = node;

        // Skip: flags bit 0x100 set
        const node_flags = @as(*const u16, @ptrFromInt(node_data + 0x0C)).*;
        if ((node_flags & 0x100) == 0) {
            // Skip: already visited or null
            const visited = @as(*const u32, @ptrFromInt(node_data + 0x8C)).*;
            const active = @as(*const u32, @ptrFromInt(node_data + 0x88)).*;
            if (visited != sentinel and active != 0) {
                // Type discriminator: pick flag mask
                const type_a = @as(*const u32, @ptrFromInt(node_data + 0x180)).*;
                const type_b = @as(*const u32, @ptrFromInt(node_data + 0x184)).*;
                const mask = if ((type_a | type_b) != 0) flags & 0xF00000 else flags & 0xF;

                if (mask != 0) {
                    // Bit 7 of flags byte: if clear, abort with 0
                    if (@as(i8, @bitCast(@as(u8, @truncate(node_flags)))) >= 0) return 0;

                    // --- SSE AABB overlap test ---
                    // node AABB at node_data+0x14C: min(3 floats), max(3 floats)
                    const n_min = loadV4(node_data + 0x14C); // {nmin.x, nmin.y, nmin.z, <nmax.x>}
                    const n_max = loadV4(node_data + 0x158); // {nmax.x, nmax.y, nmax.z, <garbage>}

                    // Overlap: nodeMin < queryMax AND queryMin <= nodeMax
                    // Compare lane-wise, check low 3 bits of mask
                    const lt_mask = n_min < q_max;
                    const le_mask = q_min <= n_max;
                    const lt_bits: u4 = @bitCast(lt_mask);
                    const le_bits: u4 = @bitCast(le_mask);
                    const bits = lt_bits & le_bits;

                    if ((bits & 0x7) == 0x7) {
                        addGeometryToBuffer(query_box, node_data, result_buf);
                    }

                    // Mark visited
                    @as(*u32, @ptrFromInt(node_data + 0x8C)).* = sentinel;
                }
            }
        }

        // Advance: next = *(node + link_offset + 4)
        // Original: MOV ECX,[EAX + EDX*1 + 4] where EAX=*listHead, EDX=node
        node = @as(*const u32, @ptrFromInt(link_offset + prev_node + 4)).*;
    }

    return 1;
}
