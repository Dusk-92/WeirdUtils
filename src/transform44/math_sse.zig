//! SSE math polyfill — replaces x87 FPU functions with SSE equivalents.
//!
//! Compiled ReleaseFast even in Debug builds (separate compilation unit).
//! Each function replaces a game x87 implementation identified from UnitXP's
//! polyfill.cpp and libSiliconPatch's export table.
//!
//! Reference sources:
//!   UnitXP:  reference/UnitXP_SP3/polyfill.cpp (scalar double intermediates)
//!   Silicon: /tmp/TurtleSilicon/winerosetta/libSiliconPatch.dll (closed source, symbols only)
//!
//! Our approach: @Vector(4, f32) SSE intrinsics where beneficial, scalar for simple ops.

const V4 = @Vector(4, f32);

// MSVC CRT — linked from the WoW process
extern fn sinf(f32) f32;
extern fn cosf(f32) f32;

// =============================================================================
// Memory access helpers (same as clip_sse.zig / bone_sse.zig)
// =============================================================================

inline fn rf32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}
inline fn wf32(addr: u32, v: f32) void {
    @as(*align(1) f32, @ptrFromInt(addr)).* = v;
}
inline fn splat(v: f32) V4 {
    return @splat(v);
}

/// Load 3 floats from addr into a V4 (4th element = 0)
inline fn loadV3(addr: u32) V4 {
    const p: [*]align(1) const f32 = @ptrFromInt(addr);
    return .{ p[0], p[1], p[2], 0 };
}

/// Store 3 floats from V4 to addr
inline fn storeV3(addr: u32, v: V4) void {
    const p: [*]align(1) f32 = @ptrFromInt(addr);
    p[0] = v[0];
    p[1] = v[1];
    p[2] = v[2];
}

/// Dot product of two V4 (first 3 components only)
inline fn dot3(va: V4, vb: V4) f32 {
    const prod = va * vb;
    return prod[0] + prod[1] + prod[2];
}

// =============================================================================
// Vector-Matrix multiplies (0x7BCA80, 0x7BCAE0, 0x7BCB40)
//
// The game has three variants of vec/quat * matrix multiply, all using x87 FPU.
// UnitXP replaces with double intermediates. We use SSE broadcast-multiply-add.
//
// Reference: polyfill.cpp lines 35-61 (detoured_operator_multiply_1/2/3)
// =============================================================================

/// 0x7BCA80: result = vec3 * mat4 (column-major: result[i] = dot(vec, mat_col_i) + mat[3][i])
/// __fastcall(ECX=result, EDX=vec3, stack: mat4*), RET 0x4
export fn vecMulMat4_ColMajor(result: u32, vec: u32, mat: u32) u32 {
    const vx = rf32(vec);
    const vy = rf32(vec + 4);
    const vz = rf32(vec + 8);
    wf32(result, vx * rf32(mat) + vy * rf32(mat + 0x10) + vz * rf32(mat + 0x20) + rf32(mat + 0x30));
    wf32(result + 4, vx * rf32(mat + 0x04) + vy * rf32(mat + 0x14) + vz * rf32(mat + 0x24) + rf32(mat + 0x34));
    wf32(result + 8, vx * rf32(mat + 0x08) + vy * rf32(mat + 0x18) + vz * rf32(mat + 0x28) + rf32(mat + 0x38));
    return result;
}

/// 0x7BCAE0: result = mat4 * vec3 (row-major: result[i] = dot(mat_row_i, vec) + mat[i][3])
/// __fastcall(ECX=result, EDX=mat4, stack: vec3*), RET 0x4
export fn matMulVec3_RowMajor(result: u32, mat: u32, vec: u32) u32 {
    const vx = rf32(vec);
    const vy = rf32(vec + 4);
    const vz = rf32(vec + 8);
    wf32(result, rf32(mat) * vx + rf32(mat + 0x04) * vy + rf32(mat + 0x08) * vz + rf32(mat + 0x0C));
    wf32(result + 4, rf32(mat + 0x10) * vx + rf32(mat + 0x14) * vy + rf32(mat + 0x18) * vz + rf32(mat + 0x1C));
    wf32(result + 8, rf32(mat + 0x20) * vx + rf32(mat + 0x24) * vy + rf32(mat + 0x28) * vz + rf32(mat + 0x2C));
    return result;
}

/// 0x7BCB40: result = quat4 * mat4 (4-component: result[i] = dot(quat, mat_col_i))
/// __fastcall(ECX=result, EDX=quat4, stack: mat4*), RET 0x4
/// Reference: polyfill.cpp line 55-61
export fn quatMulMat4(result: u32, quat: u32, mat: u32) u32 {
    const q: V4 = .{ rf32(quat), rf32(quat + 4), rf32(quat + 8), rf32(quat + 12) };
    inline for (0..4) |i| {
        const col_off = @as(u32, @intCast(i)) * 4;
        const c: V4 = .{ rf32(mat + col_off), rf32(mat + 0x10 + col_off), rf32(mat + 0x20 + col_off), rf32(mat + 0x30 + col_off) };
        wf32(result + col_off, @reduce(.Add, q * c));
    }
    return result;
}

// =============================================================================
// Vector scalar operations (0x5F8CF0, 0x5132F0)
//
// Reference: polyfill.cpp lines 117-132
// =============================================================================

/// 0x5F8CF0: result = vec3 * scalar
/// __fastcall(ECX=result, EDX=vec3, stack: factor_float), RET 0x4
export fn vec3MulScalar(result: u32, vec: u32, factor_bits: u32) u32 {
    storeV3(result, loadV3(vec) * splat(@bitCast(factor_bits)));
    return result;
}

/// 0x5132F0: self *= scalar (in-place)
/// __thiscall(ECX=self, stack: factor_float), RET 0x4
export fn vec3MulAssign(self: u32, factor_bits: u32) u32 {
    const f: f32 = @bitCast(factor_bits);
    wf32(self, rf32(self) * f);
    wf32(self + 4, rf32(self + 4) * f);
    wf32(self + 8, rf32(self + 8) * f);
    return self;
}

// =============================================================================
// Matrix operations (0x7BDC40, 0x7BDCA0, 0x7BDD00, 0x7BDFC0)
//
// ApplyTranslation and ScaleMatrix are already reimplemented inline in bone_sse.zig.
// These standalone hooks catch calls from OUTSIDE transformMatrix4x4.
//
// Reference: polyfill.cpp lines 134-218
// =============================================================================

/// 0x7BDC40: Apply translation through rotation matrix (in-place)
/// mat[3][j] += dot(mat[col_j], translation) for j=0,1,2
/// __thiscall(ECX=mat4x4, stack: vec3*), RET 0x4
/// Reference: polyfill.cpp line 136, also bone_sse.zig applyTranslation()
export fn applyTranslationMatrix(mat: u32, vec: u32) u32 {
    const tx = rf32(vec);
    const ty = rf32(vec + 4);
    const tz = rf32(vec + 8);
    wf32(mat + 0x30, tx * rf32(mat) + ty * rf32(mat + 0x10) + tz * rf32(mat + 0x20) + rf32(mat + 0x30));
    wf32(mat + 0x34, tx * rf32(mat + 0x04) + ty * rf32(mat + 0x14) + tz * rf32(mat + 0x24) + rf32(mat + 0x34));
    wf32(mat + 0x38, tx * rf32(mat + 0x08) + ty * rf32(mat + 0x18) + tz * rf32(mat + 0x28) + rf32(mat + 0x38));
    return vec; // original returns param_1 (vec ptr)
}

/// 0x7BDCA0: Scale 3x3 rotation portion by per-axis scale vector
/// row0 *= scale.x, row1 *= scale.y, row2 *= scale.z
/// __thiscall(ECX=mat4x4, stack: vec3*), RET 0x4
/// Reference: polyfill.cpp line 146, also bone_sse.zig scaleMatrix3x3()
export fn scaleMatrix3x3ByVector(mat: u32, vec: u32) u32 {
    const sx = rf32(vec);
    const sy = rf32(vec + 4);
    const sz = rf32(vec + 8);
    // Row 0
    wf32(mat, rf32(mat) * sx);
    wf32(mat + 0x04, rf32(mat + 0x04) * sx);
    wf32(mat + 0x08, rf32(mat + 0x08) * sx);
    // Row 1
    wf32(mat + 0x10, rf32(mat + 0x10) * sy);
    wf32(mat + 0x14, rf32(mat + 0x14) * sy);
    wf32(mat + 0x18, rf32(mat + 0x18) * sy);
    // Row 2
    wf32(mat + 0x20, rf32(mat + 0x20) * sz);
    wf32(mat + 0x24, rf32(mat + 0x24) * sz);
    wf32(mat + 0x28, rf32(mat + 0x28) * sz);
    return vec;
}

/// 0x7BDD00: Scale 3x3 rotation portion by uniform scalar
/// __thiscall(ECX=mat4x4, stack: factor_float), RET 0x4
/// Reference: polyfill.cpp line 162
export fn scaleMatrix3x3ByScalar(mat: u32, factor_bits: u32) void {
    const f: f32 = @bitCast(factor_bits);
    inline for ([_]u32{ 0x00, 0x04, 0x08, 0x10, 0x14, 0x18, 0x20, 0x24, 0x28 }) |off| {
        wf32(mat + off, rf32(mat + off) * f);
    }
}

/// 0x7BDFC0: 3x3 matrix multiply: result = A * B (9 elements, row-major)
/// __fastcall(ECX=result, EDX=matA, stack: matB*), RET 0x4
/// Reference: polyfill.cpp line 207
export fn multiply3x3Matrix(result: u32, a: u32, b: u32) u32 {
    // result[row][col] = sum(A[row][k] * B[k][col], k=0..2)
    // 3x3 stored as 3 rows of 3 floats (stride 0x0C per row)
    inline for (0..3) |row| {
        const r = @as(u32, @intCast(row)) * 0x0C;
        inline for (0..3) |col| {
            const c = @as(u32, @intCast(col)) * 4;
            wf32(result + r + c,
                rf32(a + r) * rf32(b + c) +
                    rf32(a + r + 4) * rf32(b + 0x0C + c) +
                    rf32(a + r + 8) * rf32(b + 0x18 + c));
        }
    }
    return result;
}

// =============================================================================
// Rotation matrices (0x7BE490, 0x7BDB00)
//
// 0x7BDD60 (rotateMatrixByAxisAngle 4x4) is already in clip_sse.zig.
// These are related but different entry points.
//
// Reference: polyfill.cpp lines 177-285
// =============================================================================

/// 0x7BE490: Create 3x3 rotation matrix from axis + angle (Rodrigues formula)
/// __fastcall(ECX=result_3x3, EDX=axis_vec3, stack: angle_float, is_unit_bool), RET 0x8
/// Reference: polyfill.cpp line 177
export fn createAxisAngleRotMat3x3(result: u32, axis: u32, angle_bits: u32, is_unit: u32) u32 {
    const angle: f32 = @bitCast(angle_bits);
    var ax = rf32(axis);
    var ay = rf32(axis + 4);
    var az = rf32(axis + 8);
    if (is_unit == 0) {
        const inv = 1.0 / @sqrt(ax * ax + ay * ay + az * az);
        ax *= inv;
        ay *= inv;
        az *= inv;
    }
    const c = cosf(angle);
    const s = sinf(angle);
    const t = 1.0 - c;
    wf32(result, ax * ax * t + c);
    wf32(result + 0x04, ax * ay * t + az * s);
    wf32(result + 0x08, ax * az * t - ay * s);
    wf32(result + 0x0C, ax * ay * t - az * s);
    wf32(result + 0x10, ay * ay * t + c);
    wf32(result + 0x14, ay * az * t + ax * s);
    wf32(result + 0x18, ax * az * t + ay * s);
    wf32(result + 0x1C, ay * az * t - ax * s);
    wf32(result + 0x20, az * az * t + c);
    return result;
}

/// 0x7BDB00: Create 4x4 rotation matrix from axis + angle (Rodrigues + identity row/col)
/// __fastcall(ECX=result_4x4, EDX=axis_vec3, stack: angle_float, is_unit_bool), RET 0x8
/// Like 0x7BE490 but outputs 4x4 with identity padding.
/// Reference: polyfill.cpp line 254
export fn createAxisAngleRotMat4x4(result: u32, axis: u32, angle_bits: u32, is_unit: u32) u32 {
    const angle: f32 = @bitCast(angle_bits);
    var ax = rf32(axis);
    var ay = rf32(axis + 4);
    var az = rf32(axis + 8);
    if (is_unit == 0) {
        const inv = 1.0 / @sqrt(ax * ax + ay * ay + az * az);
        ax *= inv;
        ay *= inv;
        az *= inv;
    }
    const c = cosf(angle);
    const s = sinf(angle);
    const t = 1.0 - c;
    wf32(result + 0x00, ax * ax * t + c);
    wf32(result + 0x04, ax * ay * t + az * s);
    wf32(result + 0x08, ax * az * t - ay * s);
    wf32(result + 0x0C, 0);
    wf32(result + 0x10, ax * ay * t - az * s);
    wf32(result + 0x14, ay * ay * t + c);
    wf32(result + 0x18, ay * az * t + ax * s);
    wf32(result + 0x1C, 0);
    wf32(result + 0x20, ax * az * t + ay * s);
    wf32(result + 0x24, ay * az * t - ax * s);
    wf32(result + 0x28, az * az * t + c);
    wf32(result + 0x2C, 0);
    wf32(result + 0x30, 0);
    wf32(result + 0x34, 0);
    wf32(result + 0x38, 0);
    wf32(result + 0x3C, 1);
    return result;
}

// =============================================================================
// Vector math primitives (0x672130, 0x602630, 0x4549F0)
//
// These are called thousands of times per frame from collision, terrain,
// and rendering code. The originals use x87 FPU.
//
// Reference: polyfill.cpp lines 287-462
// =============================================================================

/// 0x672130: Cross product: result = A x B
/// __fastcall(ECX=result, EDX=vecA, stack: vecB*), RET 0x4
/// Reference: polyfill.cpp line 451
export fn crossProduct(result: u32, va: u32, vb: u32) u32 {
    wf32(result, rf32(va + 4) * rf32(vb + 8) - rf32(va + 8) * rf32(vb + 4));
    wf32(result + 4, rf32(va + 8) * rf32(vb) - rf32(va) * rf32(vb + 8));
    wf32(result + 8, rf32(va) * rf32(vb + 4) - rf32(va + 4) * rf32(vb));
    return result;
}

/// 0x602630: Dot product: return A . B (as f64)
/// __fastcall(ECX=vecA, EDX=vecB), plain RET, returns double in ST(0)
/// Reference: polyfill.cpp line 460
export fn dotProduct(va: u32, vb: u32) f64 {
    return dot3(loadV3(va), loadV3(vb));
}

/// 0x4549F0: Squared magnitude of vec3 (returns double in ST(0))
/// __thiscall(ECX=vec3), plain RET
/// Note: Ghidra labels this "emptyFunction" — it's NOT empty, it returns x*x+y*y+z*z
/// Reference: polyfill.cpp line 289
export fn squaredMagnitude(vec: u32) f64 {
    const v = loadV3(vec);
    return dot3(v, v);
}

// 0x699330 removed -- was misidentified as normalize, actually vec3 comparison
// from libSiliconPatch (not UnitXP). Stub lives in src/silicon/silicon.zig.

// =============================================================================
// Polynomial evaluation (0x453620)
//
// Horner's method for evaluating polynomial coefficients.
// Used by animation curves and interpolation.
//
// Reference: polyfill.cpp line 466
// =============================================================================

/// 0x453620: Evaluate polynomial using Horner's method (returns double in ST(0))
/// __fastcall(ECX=degree, EDX=coefficients*, stack: factor_float), RET 0x4
export fn evaluatePolynomial(count: u32, coefficients: u32, factor_bits: u32) f64 {
    const f: f32 = @bitCast(factor_bits);
    var result: f32 = rf32(coefficients);
    var i: u32 = 1;
    while (i <= count) : (i += 1) {
        result = result * f + rf32(coefficients + i * 4);
    }
    return result;
}

// =============================================================================
// Geometry / collision functions (0x637480, 0x6DC470, 0x632830, 0x6329E0, 0x6335D0)
//
// These are collision detection and terrain processing functions.
// The originals use x87 for geometry math.
//
// Reference: polyfill.cpp lines 295-334 (calculatePlaneNormal, transformAABox)
// libSiliconPatch symbols: hook_sub_632830, hook_sub_6329E0, hook_sub_6335D0
// =============================================================================

/// 0x637480: Calculate plane normal from 3 points + normalize
/// __thiscall(ECX=result_plane4, stack: p1*, p2*, p3*), RET 0xC
/// result = {nx, ny, nz, d} where n = normalize(cross(p2-p1, p3-p1)), d = -dot(n, p1)
/// Reference: polyfill.cpp line 297
export fn calculatePlaneNormal(result: u32, p1: u32, p2: u32, p3: u32) void {
    const v1 = loadV3(p1);
    const e1 = loadV3(p2) - v1; // p2 - p1
    const e2 = loadV3(p3) - v1; // p3 - p1
    // cross product: e1 x e2
    const e1_yzx = @shuffle(f32, e1, undefined, [4]i32{ 1, 2, 0, 3 });
    const e1_zxy = @shuffle(f32, e1, undefined, [4]i32{ 2, 0, 1, 3 });
    const e2_yzx = @shuffle(f32, e2, undefined, [4]i32{ 1, 2, 0, 3 });
    const e2_zxy = @shuffle(f32, e2, undefined, [4]i32{ 2, 0, 1, 3 });
    const n = e1_yzx * e2_zxy - e1_zxy * e2_yzx;
    // normalize
    const inv_len = splat(1.0 / @sqrt(dot3(n, n)));
    const nn = n * inv_len;
    // store {nx, ny, nz, d} where d = -dot(n_normalized, p1)
    const p: [*]align(1) f32 = @ptrFromInt(result);
    p[0] = nn[0];
    p[1] = nn[1];
    p[2] = nn[2];
    p[3] = -dot3(nn, v1);
}

/// 0x6DC470: Transform axis-aligned bounding box by 3x3 matrix + translation
/// __fastcall(ECX=mat3x3, EDX=vecA, stack: vecB*, boxIn*, boxOut*), RET 0xC
/// Reference: polyfill.cpp line 312
export fn transformAABox(mat: u32, vec_a: u32, vec_b: u32, box_in: u32, box_out: u32) void {
    const ptrs = [3]u32{ mat, vec_a, vec_b };
    var out = box_out;
    var outer_i: u32 = 0;
    while (outer_i < 3) : ({ outer_i += 1; out += 4; }) {
        var inner_i: u32 = 0;
        while (inner_i < 3) : (inner_i += 1) {
            const mv = rf32(ptrs[inner_i] + outer_i * 4);
            const t1 = mv * rf32(box_in + inner_i * 4);
            const t2 = rf32(box_in + inner_i * 4 + 12) * mv;
            const lo = @min(t1, t2);
            const hi = @max(t1, t2);
            wf32(out, rf32(out) + lo);
            wf32(out + 12, rf32(out + 12) + hi);
        }
    }
}

// =============================================================================
// libSiliconPatch stubs moved to src/silicon/silicon.zig
// See that module for the full catalog of ~200 silicon hooks with addresses.
// =============================================================================

// =============================================================================
// CriticalSection spin count optimization (from UnitXP)
//
// Not a math replacement — sets SpinCount=4000 on critical sections to reduce
// kernel transitions. The game initializes CriticalSections with SpinCount=0,
// causing immediate kernel waits on contention. With SpinCount=4000, the thread
// spins in userspace first, which is faster for short-held locks.
//
// Reference: polyfill.cpp line 474-482
// Implementation: hook EnterCriticalSection, set SpinCount if 0.
// This goes in transform44.zig, not here (not SSE math).
// =============================================================================

// =============================================================================
// Blit optimization (from UnitXP)
//
// Replaces game's REP MOVSQ + REP MOVSB pattern with std::memcpy.
// On modern CPUs with Enhanced REP MOVSB (ERMS), the old split approach
// is slower than a single memcpy which the compiler optimizes.
//
// We already profile blit_hub (0x5A4F60) in transform44.zig.
// To implement: add format-specific fast paths using @memcpy in the detour.
//
// Reference: polyfill.cpp lines 344-435
// =============================================================================
