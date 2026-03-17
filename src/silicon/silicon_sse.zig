//! SSE math implementations for silicon module.
//!
//! Pure math functions extracted from silicon.zig for standalone compilation.
//! Used by both the DLL (via silicon.zig wrappers) and the bench harness.
//! All functions use C ABI (export fn) — callers handle CC translation.
//!
//! Compiled with SSE4.1+FMA+AVX. Uses @Vector(4, f32) and @mulAdd throughout.

const std = @import("std");
const V4 = @Vector(4, f32);

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

// --- 0x4549C0: normalizeVec3 (137K/7.5s) ---
// divides vec3 by given length
export fn si_normalizeVec3(vec: u32, length_bits: u32) void {
    const v: [*]f32 = @ptrFromInt(vec);
    const length: f32 = @bitCast(length_bits);
    const scale = 1.0 / length;
    v[0] *= scale;
    v[1] *= scale;
    v[2] *= scale;
}

// --- 0x7BAE60: mulMat3x4 ---
// out = A * B (3x4 layout: 3x3 rotation + 3 translation)
// Layout: [r0c0 r0c1 r0c2 | r1c0 r1c1 r1c2 | r2c0 r2c1 r2c2 | tx ty tz]
// V4 per row: broadcast b[row*3+k], multiply with a's columns, accumulate.
export fn si_mulMat3x4(out: u32, a_ptr: u32, b_ptr: u32) u32 {
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
export fn si_rotateMatByQuat(mat: u32, quat: u32) u32 {
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
export fn si_createRotMat3x4(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0]; var y = ax[1]; var z = ax[2];
    if (is_normalized == 0) {
        const len = @sqrt(@mulAdd(f32, z, z, @mulAdd(f32, y, y, x * x)));
        if (len > 1.0e-20) { const inv = 1.0 / len; x *= inv; y *= inv; z *= inv; }
    }
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle); const s = @sin(angle); const t = 1.0 - c;
    m[0] = @mulAdd(f32, t * x, x, c);    m[1] = @mulAdd(f32, s, z, t * x * y); m[2] = @mulAdd(f32, -s, y, t * x * z);
    m[3] = @mulAdd(f32, -s, z, t * x * y); m[4] = @mulAdd(f32, t * y, y, c);   m[5] = @mulAdd(f32, s, x, t * y * z);
    m[6] = @mulAdd(f32, s, y, t * x * z); m[7] = @mulAdd(f32, -s, x, t * y * z); m[8] = @mulAdd(f32, t * z, z, c);
    m[9] = 0; m[10] = 0; m[11] = 0;
    return out;
}

// --- 0x6329E0: distanceToPlane (525K/7.5s) ---
// Original: __fastcall(ECX=point, EDX=plane, stack[0]=direction), returns ST(0), RET 0x4.
// (dot(point,normal)+d) / dot(direction,normal). 70 bytes, 14cy.
// Naked FMA version: 2 dot products via vfmadd + vdivss, transfer to ST(0).
export fn si_distanceToPlane() callconv(.naked) void {
    // ECX=point, EDX=plane, [ESP+4]=direction. Return ST(0), RET 0x4.
    asm volatile (
        // dot1 = p[0]*pl[0] + p[1]*pl[1] + p[2]*pl[2] + pl[3]
        \\vmovss (%%ecx), %%xmm0
        \\vmulss (%%edx), %%xmm0, %%xmm0
        \\vmovss 4(%%ecx), %%xmm1
        \\vfmadd231ss 4(%%edx), %%xmm1, %%xmm0
        \\vmovss 8(%%ecx), %%xmm1
        \\vfmadd231ss 8(%%edx), %%xmm1, %%xmm0
        \\vaddss 12(%%edx), %%xmm0, %%xmm0
        // dot2 = dir[0]*pl[0] + dir[1]*pl[1] + dir[2]*pl[2]
        \\mov 4(%%esp), %%eax
        \\vmovss (%%eax), %%xmm2
        \\vmulss (%%edx), %%xmm2, %%xmm2
        \\vmovss 4(%%eax), %%xmm1
        \\vfmadd231ss 4(%%edx), %%xmm1, %%xmm2
        \\vmovss 8(%%eax), %%xmm1
        \\vfmadd231ss 8(%%edx), %%xmm1, %%xmm2
        // result = dot1 / dot2 (skip epsilon check for speed — game tolerates it)
        \\vdivss %%xmm2, %%xmm0, %%xmm0
        // Transfer to ST(0)
        \\sub $4, %%esp
        \\vmovss %%xmm0, (%%esp)
        \\flds (%%esp)
        \\add $4, %%esp
        \\ret $4
    );
}


// --- 0x686C20: classifyPointFrustum (3.2M/7.5s) ---
// Tests point against 6 frustum planes, produces 6-bit bitmask.
// Scalar @mulAdd dot4 per plane — the FMA chain has best throughput for this pattern.
// Tried: V4 batch 4 planes (gather kills it), V4 hsum (shuffle overhead kills it).
export fn si_classifyPointFrustum(planes_ptr: u32, point: u32, out_mask: u32) u32 {
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
// Slab-method AABB-line intersection. Uses @mulAdd for t computation.
export fn si_checkBoxLineIntersect(box_ptr: u32, line_start: u32, line_end: u32) u32 {
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
            var t0 = (bmin[i] - start[i]) * inv_dir;
            var t1 = (bmax[i] - start[i]) * inv_dir;
            if (t0 > t1) { const tmp = t0; t0 = t1; t1 = tmp; }
            if (t0 > tmin) tmin = t0;
            if (t1 < tmax) tmax = t1;
            if (tmin > tmax) return 0;
        }
    }
    return 1;
}

// --- 0x6869C0: testOBBFrustum ---
// Tests OBB against 6 frustum planes. Uses V4 for corner transform and plane test.
export fn si_testOBBFrustum(planes_ptr: u32, aabb_ptr: u32, rot_ptr: u32, trans_ptr: u32) u32 {
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
// Uses V4 dot for plane distance
export fn si_testSphereFrustum(planes_ptr: u32, sphere: u32) u32 {
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
export fn si_quatSlerp(out: u32, a_ptr: u32, t_bits: u32, b_ptr: u32) u32 {
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
// Original: __fastcall(ECX=a, EDX=b), RET. 46 bytes, 6cy.
// Naked SSE: comiss replaces x87 FCOMP+FNSTSW+TEST (3 insns -> 1 insn per compare).
// Binary patch candidate: fits in 46 bytes.
export fn si_isPointInsideBounds() callconv(.naked) void {
    // ECX = a, EDX = b. Return EAX = 1 if b[0..2] <= a[0..2], else 0.
    asm volatile (
        \\vmovss (%%edx), %%xmm0
        \\vucomiss (%%ecx), %%xmm0
        \\ja 1f
        \\vmovss 4(%%edx), %%xmm0
        \\vucomiss 4(%%ecx), %%xmm0
        \\ja 1f
        \\vmovss 8(%%edx), %%xmm0
        \\vucomiss 8(%%ecx), %%xmm0
        \\ja 1f
        \\mov $1, %%eax
        \\ret
        \\1:
        \\xor %%eax, %%eax
        \\ret
    );
}

// --- 0x749280: calculateSinCos ---
export fn si_calculateSinCos(angle_bits: u32, out_sin: u32, out_cos: u32) void {
    const angle: f32 = @bitCast(angle_bits);
    const sp: *f32 = @ptrFromInt(out_sin);
    const cp: *f32 = @ptrFromInt(out_cos);
    sp.* = @sin(angle);
    cp.* = @cos(angle);
}

// --- 0x7BE5B0: createZRotMat3x3 ---
export fn si_createZRotMat3x3(out: u32, angle_bits: u32) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle); const s = @sin(angle);
    m[0] = c;  m[1] = s;  m[2] = 0;
    m[3] = -s; m[4] = c;  m[5] = 0;
    m[6] = 0;  m[7] = 0;  m[8] = 1;
    return out;
}

// --- 0x7BCEF0: transposeMat4x4 ---
// Uses V4 loads + @shuffle for efficient transpose
export fn si_transposeMat4x4(src: u32, dst: u32) u32 {
    const r0 = loadV4(src);
    const r1 = loadV4(src + 16);
    const r2 = loadV4(src + 32);
    const r3 = loadV4(src + 48);

    // Interleave low/high pairs
    const t0 = @shuffle(f32, r0, r1, [4]i32{ 0, -1, 2, -3 }); // r0[0] r1[0] r0[2] r1[2]
    const t1 = @shuffle(f32, r0, r1, [4]i32{ 1, -2, 3, -4 }); // r0[1] r1[1] r0[3] r1[3]
    const t2 = @shuffle(f32, r2, r3, [4]i32{ 0, -1, 2, -3 }); // r2[0] r3[0] r2[2] r3[2]
    const t3 = @shuffle(f32, r2, r3, [4]i32{ 1, -2, 3, -4 }); // r2[1] r3[1] r2[3] r3[3]

    const d: [*]f32 = @ptrFromInt(dst);
    // Final columns
    const c0 = @shuffle(f32, t0, t2, [4]i32{ 0, 1, -1, -2 }); // col 0: r0[0] r1[0] r2[0] r3[0]
    const c1 = @shuffle(f32, t1, t3, [4]i32{ 0, 1, -1, -2 }); // col 1
    const c2 = @shuffle(f32, t0, t2, [4]i32{ 2, 3, -3, -4 }); // col 2
    const c3 = @shuffle(f32, t1, t3, [4]i32{ 2, 3, -3, -4 }); // col 3
    inline for (0..4) |i| { d[i] = c0[i]; }
    inline for (0..4) |i| { d[4 + i] = c1[i]; }
    inline for (0..4) |i| { d[8 + i] = c2[i]; }
    inline for (0..4) |i| { d[12 + i] = c3[i]; }
    return src;
}

// --- 0x7BB420: mulMat3x4InPlace ---
// this = this * matB. V4 columns loaded upfront, write directly back (no tmp needed).
export fn si_mulMat3x4InPlace(mat_a: u32, mat_b: u32) u32 {
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
// Uses rsqrt approximation + Newton-Raphson for fast inverse sqrt
export fn si_normalizeVec3InPlace(vec: u32) void {
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
export fn si_addVec3ToAccumulator(this: u32, vec: u32, scale_addr: u32) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const v: [*]const f32 = @ptrFromInt(vec);
    const scale: f32 = @as(*const f32, @ptrFromInt(scale_addr)).*;
    obj[21] += v[0];
    obj[22] += v[1];
    obj[23] += v[2];
    obj[33] = @mulAdd(f32, v[0], scale, obj[33]);
    obj[42] = @mulAdd(f32, v[1], scale, obj[42]);
    obj[51] = @mulAdd(f32, v[2], scale, obj[51]);
}

// --- 0x71BF60: addToColorAccumulator (10K/7.5s, 0.003ms total) ---
// 3 scalar float adds. At parity with original (9-10cy). Not worth optimizing further.
export fn si_addToColorAccumulator(this: u32, color: u32) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const c: [*]const f32 = @ptrFromInt(color);
    obj[27] += c[0];
    obj[28] += c[1];
    obj[29] += c[2];
}

// --- 0x7B7A80: packParticleColor (2K/7.5s) ---
// V4 multiply + clamp + convert for all 3 channels simultaneously
export fn si_packParticleColor(obj: u32, r_bits: u32, g_bits: u32, b_bits: u32) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const out: *align(1) u32 = @ptrCast(base + 0x12C);
    const alpha = base[0x12F];
    const rgb = V4{ @bitCast(r_bits), @bitCast(g_bits), @bitCast(b_bits), 0 } * @as(V4, @splat(@as(f32, 255.0)));
    const clamped = @min(@max(rgb, @as(V4, @splat(@as(f32, 0.0)))), @as(V4, @splat(@as(f32, 255.0))));
    const rb: u8 = @intFromFloat(@round(clamped[0]));
    const gb: u8 = @intFromFloat(@round(clamped[1]));
    const bb: u8 = @intFromFloat(@round(clamped[2]));
    out.* = @as(u32, alpha) << 24 | @as(u32, rb) << 16 | @as(u32, gb) << 8 | @as(u32, bb);
}

// --- 0x7B7B10: setParticleAlpha (2K/7.5s) ---
export fn si_setParticleAlpha(obj: u32, alpha_bits: u32) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const alpha: f32 = @bitCast(alpha_bits);
    base[0x12F] = @intFromFloat(@min(@max(alpha * 255.0, 0.0), 255.0));
}

// --- 0x40A2B0: __ftol ---
// Drop-in binary replacement. Input: ST(0). Output: EAX:EDX (i64).
// SSE3 FISTTP: truncate directly from x87 (9 bytes, replaces 39-byte original)
export fn si_ftol() callconv(.naked) void {
    asm volatile (
        \\sub $8, %%esp
        \\.byte 0xDD, 0x0C, 0x24
        \\pop %%eax
        \\pop %%edx
        \\ret
    );
}

// --- 0x602630: vec3Dot (31K/7.5s, 0.05ms total) ---
// Original: __fastcall(ECX=a, EDX=b), returns ST(0). 21 bytes, 5cy.
// Achieved 0.8x (6cy) via naked FMA — the 1cy gap is the SSE->x87 transfer
// for the ST(0) return that callers expect. DPPS (SSE4.1) is 7-11cy, no better.
// x87 is inherently optimal here: 21 bytes, no domain crossing, pipelined.
// Not worth further optimization at 31K calls — 0.05ms total frame cost.
export fn si_vec3Dot() callconv(.naked) void {
    // ECX = a ptr, EDX = b ptr (fastcall), return in ST(0)
    asm volatile (
        \\vmovss (%%ecx), %%xmm0
        \\vmulss (%%edx), %%xmm0, %%xmm0
        \\vmovss 4(%%ecx), %%xmm1
        \\vfmadd231ss 4(%%edx), %%xmm1, %%xmm0
        \\vmovss 8(%%ecx), %%xmm1
        \\vfmadd231ss 8(%%edx), %%xmm1, %%xmm0
        \\sub $4, %%esp
        \\vmovss %%xmm0, (%%esp)
        \\flds (%%esp)
        \\add $4, %%esp
        \\ret
    );
}

// --- 0x686820: translateBoundingVol ---
// Uses @mulAdd for plane distance updates
export fn si_translateBoundingVol(this: u32, offset: u32) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const off: [*]const f32 = @ptrFromInt(offset);
    const dx = off[0]; const dy = off[1]; const dz = off[2];
    // Translate 8 corners (stride 3, starting at index 24)
    inline for (0..8) |i| {
        const base = 24 + i * 3;
        obj[base] += dx;
        obj[base + 1] += dy;
        obj[base + 2] += dz;
    }
    // Update 6 plane distances: d -= dot(normal, offset)
    inline for (0..6) |i| {
        const base = i * 4;
        obj[base + 3] -= @mulAdd(f32, obj[base + 2], dz, @mulAdd(f32, obj[base + 1], dy, obj[base] * dx));
    }
    // Translate min/max
    obj[48] += dx; obj[49] += dy; obj[50] += dz;
    obj[51] += dx; obj[52] += dy; obj[53] += dz;
}
