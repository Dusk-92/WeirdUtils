//! SSE-optimized collision math — compiled ReleaseFast even in Debug builds.
//!
//! Functions are exported and called via `extern fn` from the Debug transform44 module.
//! This separation is required because Zig module imports inherit the parent's optimization
//! level, so only a separate `addObject(.{ .optimize = .ReleaseFast })` gets real SSE codegen.

const V4 = @Vector(4, f32);

const CLIP_EPSILON: f32 = @bitCast(@as(u32, 0x3ab60b61)); // +0.00139, global at 0x80dfec
const MOVEMENT_EPSILON: f32 = @bitCast(@as(u32, 0x35800000)); // 9.54e-7, global at 0x8026bc

pub fn clipPolygonToSinglePlane(plane_addr: u32, poly_addr: u32, attrib_bits: u32) callconv(.{ .x86_fastcall = .{} }) void {
    const plane: [*]const f32 = @ptrFromInt(plane_addr);
    const poly: [*]f32 = @ptrFromInt(poly_addr);
    const new_attrib: f32 = @bitCast(attrib_bits);

    // Vertex count at poly+0xF0 (byte offset 240, float offset 60)
    const count_ptr: *align(1) u32 = @ptrCast(poly + 60);
    const n = count_ptr.*;
    if (n == 0) return;

    // Load plane as 4-wide vector for SSE dot product
    const pv: @Vector(4, f32) = .{ plane[0], plane[1], plane[2], plane[3] };

    // --- Phase 1: Compute signed distances ---
    var dists: [15]f32 = undefined;
    var min_dist: f32 = @bitCast(@as(u32, 0x7f7fffff)); // FLT_MAX
    var max_dist: f32 = @bitCast(@as(u32, 0xff7fffff)); // -FLT_MAX

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = i * 3;
        const v: @Vector(4, f32) = .{ poly[b], poly[b + 1], poly[b + 2], 1.0 };
        const d = -@reduce(.Add, v * pv);
        dists[i] = d;
        if (d < min_dist) min_dist = d;
        if (d > max_dist) max_dist = d;
    }

    // --- Phase 2: Early exits (exact same thresholds as original) ---
    if (min_dist > -CLIP_EPSILON) return; // all inside
    if (max_dist < CLIP_EPSILON) {
        count_ptr.* = 0; // all outside
        return;
    }

    // --- Phase 3: Copy polygon to local buffers ---
    const attribs: [*]f32 = poly + 45; // +0xB4
    var tmp_v: [15 * 3]f32 = undefined;
    var tmp_a: [15]f32 = undefined;
    for (0..n * 3) |j| tmp_v[j] = poly[j];
    for (0..n) |j| tmp_a[j] = attribs[j];

    // --- Phase 4: Sutherland-Hodgman edge walk ---
    var out: u32 = 0;
    var prev: u32 = n - 1;
    var pd = dists[prev];

    i = 0;
    while (i < n) : (i += 1) {
        const cd = dists[i];

        if (pd >= 0.0) {
            if (cd >= 0.0) {
                emit(poly, attribs, &out, (tmp_v[i * 3 ..]).ptr, tmp_a[i]);
            } else {
                if (pd > CLIP_EPSILON) {
                    lerp(poly, attribs, &out, (tmp_v[prev * 3 ..]).ptr, (tmp_v[i * 3 ..]).ptr, pd / (cd - pd), new_attrib);
                }
            }
        } else {
            if (cd >= 0.0) {
                if (cd > CLIP_EPSILON) {
                    lerp(poly, attribs, &out, (tmp_v[prev * 3 ..]).ptr, (tmp_v[i * 3 ..]).ptr, pd / (cd - pd), new_attrib);
                }
                emit(poly, attribs, &out, (tmp_v[i * 3 ..]).ptr, tmp_a[i]);
            }
        }

        prev = i;
        pd = cd;
    }

    count_ptr.* = if (out >= 3) out else 0;
}

inline fn emit(poly: [*]f32, attribs: [*]f32, out: *u32, v: [*]const f32, a: f32) void {
    const o = out.*;
    const b = o * 3;
    poly[b] = v[0];
    poly[b + 1] = v[1];
    poly[b + 2] = v[2];
    attribs[o] = a;
    out.* = o + 1;
}

inline fn lerp(poly: [*]f32, attribs: [*]f32, out: *u32, p: [*]const f32, c: [*]const f32, t: f32, a: f32) void {
    const o = out.*;
    const b = o * 3;
    // intersection = prev - (curr - prev) * t
    poly[b] = p[0] - (c[0] - p[0]) * t;
    poly[b + 1] = p[1] - (c[1] - p[1]) * t;
    poly[b + 2] = p[2] - (c[2] - p[2]) * t;
    attribs[o] = a;
    out.* = o + 1;
}

// =============================================================================
// BuildTrianglePlanes (0x632460)
// __fastcall(ECX=vertices, EDX=triangle_indices(byte*),
//            stack: plane_normal*, offset_vector*, output_planes*)
// Returns: int (1=ok, 0=degenerate)
//
// Builds 4 clipping planes from a triangle + offset:
//   planes[0..2]: edge planes (perpendicular to triangle, one per edge)
//   planes[3]:    cap plane (from plane_normal, offset by offset_vector)
// =============================================================================

pub fn buildTrianglePlanes(verts_addr: u32, indices_addr: u32, normal_addr: u32, offset_addr: u32, out_addr: u32) u32 {
    const verts: [*]const f32 = @ptrFromInt(verts_addr);
    const indices: [*]const u8 = @ptrFromInt(indices_addr);
    const plane_normal: [*]const f32 = @ptrFromInt(normal_addr);
    const offset_vec: [*]const f32 = @ptrFromInt(offset_addr);
    const output: [*]f32 = @ptrFromInt(out_addr);

    const ofs = loadV3(offset_vec);

    // Load 3 triangle vertices
    var tv: [3]V4 = undefined;
    for (0..3) |i| {
        const idx = @as(u32, indices[i]) * 3;
        tv[i] = loadV3(verts + idx);
    }

    // Edge tables: for edge i, v0=i, v1=next, v2=opposite
    const next = [3]u8{ 1, 2, 0 };
    const opp = [3]u8{ 2, 0, 1 };

    // Build 3 edge planes
    for (0..3) |i| {
        const v0 = tv[i];
        const v1 = tv[next[i]];
        const v2 = tv[opp[i]];
        const offset_v = v0 + ofs; // offset vertex

        // Check for degenerate triangle: cross(offset_vec, v1 - v0)
        const edge = v1 - v0;
        const check_normal = cross3(ofs, edge);
        if (dot3(check_normal, check_normal) < MOVEMENT_EPSILON) return 0;

        // Calculate plane from 3 points (v0, v1, offset_v)
        const e1 = offset_v - v0; // = offset_vec
        const e2 = v1 - v0; // = edge
        var normal = cross3(e2, e1);
        const len_sq = dot3(normal, normal);
        const inv_len: V4 = @splat(1.0 / @sqrt(len_sq));
        normal = normal * inv_len;
        const d = -dot3(normal, v0);

        // Check orientation: if opposite vertex is on positive side, negate
        const to_v2 = v2 - v0;
        const plane_idx = i * 4;
        if (dot3(to_v2, normal) > 0.0) {
            output[plane_idx + 0] = -normal[0];
            output[plane_idx + 1] = -normal[1];
            output[plane_idx + 2] = -normal[2];
            output[plane_idx + 3] = -d;
        } else {
            output[plane_idx + 0] = normal[0];
            output[plane_idx + 1] = normal[1];
            output[plane_idx + 2] = normal[2];
            output[plane_idx + 3] = d;
        }
    }

    // 4th plane: cap plane from plane_normal
    const pn = loadV3(plane_normal);
    const cap_point = tv[0] + ofs;
    output[12] = plane_normal[0];
    output[13] = plane_normal[1];
    output[14] = plane_normal[2];
    output[15] = -dot3(pn, cap_point);

    return 1;
}

// =============================================================================
// rayTriangleIntersection (0x7c29f0)
// Möller-Trumbore ray-triangle intersection test
// __fastcall(ECX=ray[6], EDX=verts_base, stack: indices_u16[3], out_dist*, out_bary*, tolerance)
// Returns: 1 = hit, 0 = miss
// =============================================================================

pub fn rayTriangleIntersection(
    ray_addr: u32,
    verts_addr: u32,
    indices_addr: u32,
    out_dist_addr: u32,
    out_bary_addr: u32,
    tolerance_bits: u32,
) u32 {
    const ray: [*]const f32 = @ptrFromInt(ray_addr);
    const verts: [*]const f32 = @ptrFromInt(verts_addr);
    const indices: [*]const u16 = @ptrFromInt(indices_addr);
    const tolerance: f32 = @bitCast(tolerance_bits);

    const neg_tol = -tolerance;
    const one_plus_tol = 1.0 + tolerance;

    // Load vertex positions via indices (each vertex = 3 floats, stride = 12 bytes)
    const idx0: u32 = @as(u32, indices[0]) * 3;
    const idx1: u32 = @as(u32, indices[1]) * 3;
    const idx2: u32 = @as(u32, indices[2]) * 3;

    const v0 = loadV3(verts + idx0);
    const v1 = loadV3(verts + idx1);
    const v2 = loadV3(verts + idx2);

    // Ray: origin at ray[0..3], direction at ray[3..6]
    const origin = loadV3(ray);
    const dir = loadV3(ray + 3);

    // Möller-Trumbore algorithm
    const edge1 = v1 - v0;
    const edge2 = v2 - v0;
    const h = cross3(dir, edge2);
    const det = dot3(edge1, h);

    // Determinant thresholds from WoW binary (both 0.0 at compile time = two-sided test)
    const det_neg = @as(*const f32, @ptrFromInt(0x0081d9bc)).*;
    const det_pos = @as(*const f32, @ptrFromInt(0x0080e2e4)).*;

    if (det > det_neg and det < det_pos) return 0;

    const inv_det = 1.0 / det;

    // Barycentric u
    const s = origin - v0;
    const u_val = dot3(s, h) * inv_det;
    if (u_val < neg_tol or u_val > one_plus_tol) return 0;

    // Barycentric v
    const q = cross3(s, edge1);
    const v_val = dot3(dir, q) * inv_det;
    if (v_val < neg_tol or (u_val + v_val) > one_plus_tol) return 0;

    // Intersection distance t
    const t = dot3(edge2, q) * inv_det;

    if (out_dist_addr != 0) {
        @as(*f32, @ptrFromInt(out_dist_addr)).* = t;
    }
    if (out_bary_addr != 0) {
        const bary: [*]f32 = @ptrFromInt(out_bary_addr);
        bary[0] = u_val;
        bary[1] = v_val;
    }

    return 1;
}

// =============================================================================
// multiplyMatrix4x4 (0x7bc6a0)
// SSE replacement for 542 bytes of x87 FPU matrix multiply.
// __fastcall(ECX=result, EDX=left, stack: right), RET 0x4
// Row-major: result[i][j] = sum(left[i][k] * right[k][j], k=0..3)
// Returns result pointer (EAX = result_addr).
// =============================================================================

pub fn multiplyMatrix4x4(result_addr: u32, left_addr: u32, right_addr: u32) u32 {
    const result: [*]f32 = @ptrFromInt(result_addr);
    const left: [*]const f32 = @ptrFromInt(left_addr);
    const right: [*]const f32 = @ptrFromInt(right_addr);

    // Load all 4 rows of right matrix
    const r0: V4 = .{ right[0], right[1], right[2], right[3] };
    const r1: V4 = .{ right[4], right[5], right[6], right[7] };
    const r2: V4 = .{ right[8], right[9], right[10], right[11] };
    const r3: V4 = .{ right[12], right[13], right[14], right[15] };

    // For each row of left, broadcast-multiply-add against right rows
    inline for (0..4) |i| {
        const b = i * 4;
        const out = splat4(left[b]) * r0 + splat4(left[b + 1]) * r1 + splat4(left[b + 2]) * r2 + splat4(left[b + 3]) * r3;
        storeV4(result + b, out);
    }

    return result_addr;
}

// =============================================================================
// rotateMatrixByAxisAngle (0x7bdd60)
// Builds axis-angle rotation matrix (Rodrigues) then multiplies.
// Replaces 853 bytes of x87 FPU (createAxisAngleRotationMatrix 311B +
// multiplyMatrix4x4 542B) with SSE @Vector math.
// __thiscall(ECX=matrix, stack: angle, axis_ptr, is_unit_flag)
// =============================================================================

pub fn rotateMatrixByAxisAngle(
    matrix_addr: u32,
    angle_bits: u32,
    axis_addr: u32,
    is_unit: u32,
) void {
    const matrix: [*]f32 = @ptrFromInt(matrix_addr);
    const angle: f32 = @bitCast(angle_bits);
    const axis_ptr: [*]const f32 = @ptrFromInt(axis_addr);

    // Load and optionally normalize axis
    var ax = axis_ptr[0];
    var ay = axis_ptr[1];
    var az = axis_ptr[2];

    if (is_unit == 0) {
        const inv_len = 1.0 / @sqrt(ax * ax + ay * ay + az * az);
        ax *= inv_len;
        ay *= inv_len;
        az *= inv_len;
    }

    // Rodrigues rotation matrix (row-major, matching WoW's layout)
    const c = cosf(angle);
    const s = sinf(angle);
    const t = 1.0 - c;

    // Build rotation matrix on stack, then multiply: result = rot * input
    // Row 3 of rotation is {0,0,0,1} so result row 3 = input row 3 (identity).
    // We build the full 4x4 rot matrix and use multiplyMatrix4x4 for the multiply.
    var rot: [16]f32 = .{
        ax * ax * t + c,      ax * ay * t + az * s, ax * az * t - ay * s, 0,
        ax * ay * t - az * s, ay * ay * t + c,      ay * az * t + ax * s, 0,
        ax * az * t + ay * s, ay * az * t - ax * s, az * az * t + c,      0,
        0,                    0,                     0,                     1,
    };

    // result = rot * matrix, but result == matrix so use temp to avoid aliasing
    var tmp: [16]f32 = undefined;
    _ = multiplyMatrix4x4(@intFromPtr(&tmp), @intFromPtr(&rot), matrix_addr);
    matrix[0..16].* = tmp;
}

// MSVC CRT sin/cos — linked from the WoW process
extern fn sinf(f32) f32;
extern fn cosf(f32) f32;

// =============================================================================
// Vector helpers
// =============================================================================

inline fn loadV3(p: [*]const f32) V4 {
    return .{ p[0], p[1], p[2], 0.0 };
}

inline fn dot3(a: V4, b: V4) f32 {
    const p = a * b;
    return p[0] + p[1] + p[2];
}

inline fn cross3(a: V4, b: V4) V4 {
    const a_yzx = @shuffle(f32, a, undefined, [4]i32{ 1, 2, 0, 3 });
    const b_zxy = @shuffle(f32, b, undefined, [4]i32{ 2, 0, 1, 3 });
    const a_zxy = @shuffle(f32, a, undefined, [4]i32{ 2, 0, 1, 3 });
    const b_yzx = @shuffle(f32, b, undefined, [4]i32{ 1, 2, 0, 3 });
    return a_yzx * b_zxy - a_zxy * b_yzx;
}

inline fn splat4(v: f32) V4 {
    return @splat(v);
}

inline fn storeV4(dst: [*]f32, v: V4) void {
    dst[0] = v[0];
    dst[1] = v[1];
    dst[2] = v[2];
    dst[3] = v[3];
}
