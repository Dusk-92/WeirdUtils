//! SSE math implementations for silicon module.
//!
//! Pure math functions extracted from silicon.zig for standalone compilation.
//! Used by both the DLL (via silicon.zig wrappers) and the bench harness.
//! All functions use C ABI (export fn) — callers handle CC translation.
//!
//! Functions that depend on game state (globals, hook trampolines, game structs)
//! remain in silicon.zig and are not benchmarkable in isolation.

const std = @import("std");

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
export fn si_mulMat3x4(out: u32, a_ptr: u32, b_ptr: u32) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const a: [*]const f32 = @ptrFromInt(a_ptr);
    const b: [*]const f32 = @ptrFromInt(b_ptr);
    inline for (0..3) |row| {
        inline for (0..3) |col| {
            dst[row * 3 + col] = a[col] * b[row * 3] + a[col + 3] * b[row * 3 + 1] + a[col + 6] * b[row * 3 + 2];
        }
    }
    inline for (0..3) |col| {
        dst[9 + col] = a[col] * b[9] + a[col + 3] * b[10] + a[col + 6] * b[11] + a[9 + col];
    }
    return out;
}

// --- 0x7BDDB0: rotateMatByQuat ---
// builds rotation matrix from quaternion, multiplies with existing 4x4 matrix
export fn si_rotateMatByQuat(mat: u32, quat: u32) u32 {
    const m: [*]f32 = @ptrFromInt(mat);
    const q: [*]const f32 = @ptrFromInt(quat);
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;
    var r: [16]f32 = undefined;
    r[0] = 1.0 - (yy + zz); r[1] = xy + wz;           r[2] = xz - wy;           r[3] = 0;
    r[4] = xy - wz;          r[5] = 1.0 - (xx + zz);   r[6] = yz + wx;           r[7] = 0;
    r[8] = xz + wy;          r[9] = yz - wx;           r[10] = 1.0 - (xx + yy);  r[11] = 0;
    r[12] = 0;               r[13] = 0;                r[14] = 0;                r[15] = 1;
    var tmp: [16]f32 = undefined;
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            tmp[row * 4 + col] = r[row * 4] * m[col] + r[row * 4 + 1] * m[4 + col] + r[row * 4 + 2] * m[8 + col] + r[row * 4 + 3] * m[12 + col];
        }
    }
    inline for (0..16) |i| { m[i] = tmp[i]; }
    return mat;
}

// --- 0x7BB860: createRotMat3x4 ---
// Rodrigues rotation matrix, 3x4 layout (3x3 rot + zero translation)
export fn si_createRotMat3x4(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0]; var y = ax[1]; var z = ax[2];
    if (is_normalized == 0) {
        const len = @sqrt(x * x + y * y + z * z);
        if (len > 1.0e-20) { const inv = 1.0 / len; x *= inv; y *= inv; z *= inv; }
    }
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle); const s = @sin(angle); const t = 1.0 - c;
    m[0] = t * x * x + c;   m[1] = t * x * y + s * z; m[2] = t * x * z - s * y;
    m[3] = t * x * y - s * z; m[4] = t * y * y + c;   m[5] = t * y * z + s * x;
    m[6] = t * x * z + s * y; m[7] = t * y * z - s * x; m[8] = t * z * z + c;
    m[9] = 0; m[10] = 0; m[11] = 0;
    return out;
}

// --- 0x6329E0: distanceToPlane (525K/7.5s) ---
// (dot(point,normal)+d) / dot(direction,normal)
export fn si_distanceToPlane(point: u32, plane: u32, direction: u32) f64 {
    const p: [*]const f32 = @ptrFromInt(point);
    const pl: [*]const f32 = @ptrFromInt(plane);
    const dir: [*]const f32 = @ptrFromInt(direction);
    const dot1 = p[0] * pl[0] + p[1] * pl[1] + p[2] * pl[2] + pl[3];
    const dot2 = dir[0] * pl[0] + dir[1] * pl[1] + dir[2] * pl[2];
    if (@abs(dot2) < 1.0e-20) return 0.0;
    return @floatCast(dot1 / dot2);
}

// --- 0x686C20: classifyPointFrustum (3.2M/7.5s) ---
// tests point against 6 frustum planes, produces 6-bit bitmask
export fn si_classifyPointFrustum(planes_ptr: u32, point: u32, out_mask: u32) u32 {
    const p: [*]const f32 = @ptrFromInt(point);
    const mask: *u32 = @ptrFromInt(out_mask);
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const px = p[0]; const py = p[1]; const pz = p[2];
    var bits: u32 = 0;
    inline for (0..6) |i| {
        const pl = planes + i * 4;
        const dist = px * pl[0] + py * pl[1] + pz * pl[2] + pl[3];
        if (dist < 0) bits |= (@as(u32, 1) << @intCast(i));
    }
    mask.* = bits;
    return planes_ptr;
}

// --- 0x6DC5A0: checkBoxLineIntersect (2.7M/7.5s) ---
// slab-method AABB-line intersection
export fn si_checkBoxLineIntersect(box_ptr: u32, line_start: u32, line_end: u32) u32 {
    const bmin: [*]const f32 = @ptrFromInt(box_ptr);
    const bmax: [*]const f32 = @ptrFromInt(box_ptr + 0xC);
    const start: [*]const f32 = @ptrFromInt(line_start);
    const end: [*]const f32 = @ptrFromInt(line_end);
    var tmin: f32 = 0.0;
    var tmax: f32 = 1.0;
    inline for (0..3) |i| {
        const dir = end[i] - start[i];
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
// tests oriented bounding box against 6 frustum planes
export fn si_testOBBFrustum(planes_ptr: u32, aabb_ptr: u32, rot_ptr: u32, trans_ptr: u32) u32 {
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const aabb: [*]const f32 = @ptrFromInt(aabb_ptr);
    const rot: [*]const f32 = @ptrFromInt(rot_ptr);
    const trans: [*]const f32 = @ptrFromInt(trans_ptr);
    const min2 = [3]f32{ aabb[0], aabb[1], aabb[2] };
    const max2 = [3]f32{ aabb[3], aabb[4], aabb[5] };
    var corners: [8][3]f32 = undefined;
    inline for (0..8) |i| {
        const lx = if (i & 1 != 0) max2[0] else min2[0];
        const ly = if (i & 2 != 0) max2[1] else min2[1];
        const lz = if (i & 4 != 0) max2[2] else min2[2];
        corners[i][0] = rot[0] * lx + rot[3] * ly + rot[6] * lz + trans[0];
        corners[i][1] = rot[1] * lx + rot[4] * ly + rot[7] * lz + trans[1];
        corners[i][2] = rot[2] * lx + rot[5] * ly + rot[8] * lz + trans[2];
    }
    inline for (0..6) |p| {
        const pl = planes + p * 4;
        var all_outside = true;
        inline for (0..8) |c| {
            const dist = corners[c][0] * pl[0] + corners[c][1] * pl[1] + corners[c][2] * pl[2] + pl[3];
            if (dist >= 0) all_outside = false;
        }
        if (all_outside) return 0;
    }
    return 3;
}

// --- 0x686B80: testSphereFrustum (375K/7.5s) ---
export fn si_testSphereFrustum(planes_ptr: u32, sphere: u32) u32 {
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const s: [*]const f32 = @ptrFromInt(sphere);
    const cx = s[0]; const cy = s[1]; const cz = s[2]; const r = s[3];
    inline for (0..6) |i| {
        const pl = planes + i * 4;
        const dist = cx * pl[0] + cy * pl[1] + cz * pl[2] + pl[3];
        if (dist < -r) return 0;
    }
    return 3;
}

// --- 0x7C0570: quatSlerp ---
export fn si_quatSlerp(out: u32, a_ptr: u32, t_bits: u32, b_ptr: u32) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const a: [*]const f32 = @ptrFromInt(a_ptr);
    const b_raw: [*]const f32 = @ptrFromInt(b_ptr);
    const t: f32 = @bitCast(t_bits);
    var dot_val = a[0] * b_raw[0] + a[1] * b_raw[1] + a[2] * b_raw[2] + a[3] * b_raw[3];
    var sign: f32 = 1.0;
    if (dot_val < 0) { dot_val = -dot_val; sign = -1.0; }
    var s0: f32 = undefined;
    var s1: f32 = undefined;
    if (dot_val > 0.9995) {
        s0 = 1.0 - t;
        s1 = t * sign;
    } else {
        const theta = std.math.acos(dot_val);
        const sin_theta = @sin(theta);
        const inv_sin = 1.0 / sin_theta;
        s0 = @sin((1.0 - t) * theta) * inv_sin;
        s1 = @sin(t * theta) * inv_sin * sign;
    }
    dst[0] = s0 * a[0] + s1 * b_raw[0];
    dst[1] = s0 * a[1] + s1 * b_raw[1];
    dst[2] = s0 * a[2] + s1 * b_raw[2];
    dst[3] = s0 * a[3] + s1 * b_raw[3];
    return out;
}

// --- 0x699330: isPointInsideBounds (1.7M/7.5s) ---
export fn si_isPointInsideBounds(a: u32, b: u32) u32 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    if (vb[0] <= va[0] and vb[1] <= va[1] and vb[2] <= va[2]) return 1;
    return 0;
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
export fn si_transposeMat4x4(src: u32, dst: u32) u32 {
    const s: [*]const f32 = @ptrFromInt(src);
    const d: [*]f32 = @ptrFromInt(dst);
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            d[row * 4 + col] = s[col * 4 + row];
        }
    }
    return src;
}

// --- 0x7BB420: mulMat3x4InPlace ---
// this = this * matB
export fn si_mulMat3x4InPlace(mat_a: u32, mat_b: u32) u32 {
    const a: [*]f32 = @ptrFromInt(mat_a);
    const b: [*]const f32 = @ptrFromInt(mat_b);
    var tmp: [12]f32 = undefined;
    inline for (0..3) |row| {
        inline for (0..3) |col| {
            tmp[row * 3 + col] = a[col] * b[row * 3] + a[col + 3] * b[row * 3 + 1] + a[col + 6] * b[row * 3 + 2];
        }
    }
    inline for (0..3) |col| {
        tmp[9 + col] = a[col] * b[9] + a[col + 3] * b[10] + a[col + 6] * b[11] + a[9 + col];
    }
    inline for (0..12) |i| { a[i] = tmp[i]; }
    return mat_a;
}

// --- 0x6720F0: normalizeVec3InPlace ---
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
// Adds vec3 to this+0x54, adds scaled copy (global at 0x81207C) to diagonal at +0x84/+0xA8/+0xCC
export fn si_addVec3ToAccumulator(this: u32, vec: u32, scale_addr: u32) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const v: [*]const f32 = @ptrFromInt(vec);
    const scale: f32 = @as(*const f32, @ptrFromInt(scale_addr)).*;
    obj[21] += v[0];
    obj[22] += v[1];
    obj[23] += v[2];
    obj[33] += v[0] * scale;
    obj[42] += v[1] * scale;
    obj[51] += v[2] * scale;
}

// --- 0x71BF60: addToColorAccumulator (10K/7.5s) ---
// Accumulates color vec3 into this+0x6C (float offset 27)
export fn si_addToColorAccumulator(this: u32, color: u32) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const c: [*]const f32 = @ptrFromInt(color);
    obj[27] += c[0];
    obj[28] += c[1];
    obj[29] += c[2];
}

// --- 0x7B7A80: packParticleColor (2K/7.5s) ---
// Reads alpha at obj+0x12F, packs ARGB into u32 at obj+0x12C
export fn si_packParticleColor(obj: u32, r_bits: u32, g_bits: u32, b_bits: u32) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const out: *align(1) u32 = @ptrCast(base + 0x12C);
    const alpha = base[0x12F];
    const r: f32 = @bitCast(r_bits);
    const g: f32 = @bitCast(g_bits);
    const b: f32 = @bitCast(b_bits);
    const rb: u8 = @intFromFloat(@min(@max(r * 255.0, 0.0), 255.0));
    const gb: u8 = @intFromFloat(@min(@max(g * 255.0, 0.0), 255.0));
    const bb: u8 = @intFromFloat(@min(@max(b * 255.0, 0.0), 255.0));
    out.* = @as(u32, alpha) << 24 | @as(u32, rb) << 16 | @as(u32, gb) << 8 | @as(u32, bb);
}

// --- 0x7B7B10: setParticleAlpha (2K/7.5s) ---
export fn si_setParticleAlpha(obj: u32, alpha_bits: u32) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const alpha: f32 = @bitCast(alpha_bits);
    base[0x12F] = @intFromFloat(@min(@max(alpha * 255.0, 0.0), 255.0));
}

// --- 0x602630: vec3Dot ---
export fn si_vec3Dot(a: u32, b: u32) f64 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    return @floatCast(va[0] * vb[0] + va[1] * vb[1] + va[2] * vb[2]);
}

// --- 0x686820: translateBoundingVol ---
// translates 8 corners, updates plane distances, translates min/max
export fn si_translateBoundingVol(this: u32, offset: u32) void {
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
        obj[base + 3] -= obj[base] * dx + obj[base + 1] * dy + obj[base + 2] * dz;
    }
    obj[48] += dx; obj[49] += dy; obj[50] += dz;
    obj[51] += dx; obj[52] += dy; obj[53] += dz;
}
