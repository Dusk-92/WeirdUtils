//! SSE-optimized transformMatrix4x4 reimplementation.
//!
//! Full standalone replacement for the 17703-byte bone transform engine at 0x714260.
//! Compiled ReleaseFast even in Debug builds (separate compilation unit pattern).
//! All helper functions (findInterpolationIndices, interpolateAnimationKeyframes,
//! scaleMatrix3x3ByVector, ApplyTranslationMatrix, rotateMatrixByQuaternion) are
//! reimplemented inline — no calls back to original game code.
//!
//! Only external call: the original transformMatrix4x4 via the hook's callOriginal
//! for attachment recursion (the detour auto-dispatches to this SSE version).

const V4 = @Vector(4, f32);











// =============================================================================
// SceneObject field offsets — assembly-verified from [EBX+N] in transformMatrix4x4
// =============================================================================

const SO = struct {
    const model_data_ptr: u32 = 0x010;
    const anim_ctx_ptr: u32 = 0x02C; // +0xC=timestamp, +0x10=sync_value
    const model_ctr_ptr: u32 = 0x030; // +0x130=M2 header
    const sync_value: u32 = 0x040;
    const search_data_base: u32 = 0x04C; // prev timestamp for delta
    const emitter_flag: u32 = 0x050;
    const gs_values_ptr: u32 = 0x064; // pointer to global sequence value array
    const gs_time_base: u32 = 0x068; // subtracted from timestamp for GS
    const child_padding: u32 = 0x084;
    const anim_frame_ctr: u32 = 0x08C;
    const bone_rt_base: u32 = 0x090; // array of 0x118-byte bone runtime structs
    const bone_out_ptr: u32 = 0x094; // output bone matrices
    const tex_anim_out: u32 = 0x0A0;
    const color_anim_out: u32 = 0x0A8;
    const scale1: u32 = 0x0AC;
    const scale2: u32 = 0x0B0;
    const scale3: u32 = 0x0B4;
    const bb_row0: u32 = 0x0FC; // billboard matrix row 0 (camera forward)
    const world_xform: u32 = 0x10C; // float[16] world transform
    const field_17c: u32 = 0x17C;
    const field_180: u32 = 0x180;
    const field_184: u32 = 0x184;
    const field_188: u32 = 0x188;
    const field_18c: u32 = 0x18C;
    const field_190: u32 = 0x190;
    const render_scale_x: u32 = 0x194;
    const render_scale_y: u32 = 0x198;
    const render_scale_z: u32 = 0x19C;
    const world_pos: u32 = 0x1A0; // Vec3 (passed as param_3 to children)
    const render_pri: u32 = 0x1AC; // Vec3 (passed as param_4 to children)
    const hierarchy_ptr: u32 = 0x1C8;
    const emitter_ctx: u32 = 0x1CC;
    const field_1d8: u32 = 0x1D8;
    const hierarchy_idx: u32 = 0x1DC;
    const field_200: u32 = 0x200;
    const particle1: u32 = 0x3C4;
    const particle2: u32 = 0x3C8;
    const particle3: u32 = 0x3D0;
    const particle4: u32 = 0x3D4;
    const add_remaining: u32 = 0x3D8;
};

// Bone runtime struct offsets (within 0x118-byte per-bone runtime)
const BR = struct {
    // Translation interpolation state
    const trans_idx0: u32 = 0x00; // [0] lower keyframe index
    const trans_idx1: u32 = 0x04; // [1] upper keyframe index
    const trans_t: u32 = 0x08; // [2] interpolation factor (float bits)
    const trans_x: u32 = 0x0C; // [3] interpolated translation X
    const trans_y: u32 = 0x10; // [4] Y
    const trans_z: u32 = 0x14; // [5] Z
    // Secondary translation (crossfade)
    const trans2_idx0: u32 = 0x18;
    const trans2_idx1: u32 = 0x1C;
    const trans2_t: u32 = 0x20;
    const trans2_x: u32 = 0x24;
    const trans2_y: u32 = 0x28;
    const trans2_z: u32 = 0x2C;
    // Scale interpolation state (at puVar20 + 0x1a = offset 0x68)
    const scale_idx0: u32 = 0x68;
    const scale_idx1: u32 = 0x6C;
    const scale_t: u32 = 0x70;
    const scale_x: u32 = 0x74;
    const scale_y: u32 = 0x78;
    const scale_z: u32 = 0x7C;
    const scale2_idx0: u32 = 0x80;
    const scale2_idx1: u32 = 0x84;
    const scale2_t: u32 = 0x88;
    const scale2_x: u32 = 0x8C;
    const scale2_y: u32 = 0x90;
    const scale2_z: u32 = 0x94;
    // Primary animation time range
    const prim_time: u32 = 0x98; // puVar20[0x26]
    const prim_track: u32 = 0x9C; // puVar20[0x27]
    const prim_anim: u32 = 0xA0; // puVar20[0x28]
    const anim_slot: u32 = 0xA4; // puVar20[0x29] - animation slot index
    // Secondary animation time range (crossfade)
    const sec_start: u32 = 0xA8; // puVar20[0x2a]
    const sec_end: u32 = 0xAC; // puVar20[0x2b]
    const time_scale: u32 = 0xB0; // puVar20[0x2c] — float scale for FILD*FMUL→__ftol time conversion
    const sec_anim_offset: u32 = 0xB8; // puVar20[0x2e]
    // Rotation interpolation (interpolateAnimationKeyframes output at +0xC*4 = 0x30)
    const rot_idx0: u32 = 0x30;
    const rot_idx1: u32 = 0x34;
    const rot_t: u32 = 0x38;
    const rot_x: u32 = 0x3C;
    const rot_y: u32 = 0x40;
    const rot_z: u32 = 0x44;
    const rot_w: u32 = 0x48;
    // Secondary rotation
    const rot2_idx0: u32 = 0x4C;
    const rot2_idx1: u32 = 0x50;
    const rot2_t: u32 = 0x54;
    const rot2_x: u32 = 0x58;
    const rot2_y: u32 = 0x5C;
    const rot2_z: u32 = 0x60;
    const rot2_w: u32 = 0x64;
    // Secondary time range
    const sec_time: u32 = 0xC4; // puVar20[0x31]
    const sec_track: u32 = 0xC8; // puVar20[0x32]
    const sec_slot: u32 = 0xD0; // puVar20[0x34]
    const sec_start2: u32 = 0xD4; // puVar20[0x35]
    const sec_end2: u32 = 0xD8; // puVar20[0x36]
    const sec_offset2: u32 = 0xE4; // puVar20[0x39]
    // Flags and weights
    const flags2: u32 = 0xF4; // puVar20[0x3d]
    const crossfade_end: u32 = 0x100; // puVar20[0x40]
    const crossfade_inv: u32 = 0x104; // puVar20[0x41]
    const crossfade_weight: u32 = 0x108; // puVar20[0x42]
    const blend_weight: u32 = 0x10C; // puVar20[0x43] - blend weight for crossfade
    const bone_flag_cache: u32 = 0xF0; // puVar20[0x3c]
};

// OldAnimationBlock struct offsets (28 bytes = 0x1C per track in v256 M2)
// Layout verified from M2 format + decompilation cross-reference:
//   pMVar23->m31 (bone_def+0x34) = rot block+0x0C = nTimestamps (gates rotation)
//   pMVar23->m12 (bone_def+0x18) = trans block+0x0C = nTimestamps (gates translation)
//   pMVar23[1].m10 (bone_def+0x50) = scale block+0x0C = nTimestamps (gates scale)
const AD = struct {
    const interp_mode: u32 = 0x00; // u16: interpolation mode (0=none, 1=lerp)
    const time_index: u32 = 0x02; // i16: global sequence index (-1 = none)
    const track_count_flag: u32 = 0x04; // nRanges: 0 = single track
    const keyframe_ranges: u32 = 0x08; // ofsRanges: ptr to per-track range pairs
    const keyframe_count: u32 = 0x0C; // nTimestamps: total keyframe count
    const timestamps_ptr: u32 = 0x10; // ofsTimestamps: ptr to timestamp array
    const nvalues: u32 = 0x14; // nValues: number of value entries
    const keyframe_base: u32 = 0x18; // ofsValues: ptr to keyframe data
};

// M2CompBone struct offsets (0x6C = 108 bytes per bone in v256 model)
// Layout: 12 bytes fixed header + 3x28 byte OldAnimationBlock tracks + 12 bytes pivot
// Track order: translation, rotation, scale (standard M2 order)
const BD = struct {
    const key_id: u32 = 0x00; // i32: key bone ID
    const flags: u32 = 0x04; // u32: bone flags (billboard type in bits 0-6, etc.)
    const parent_bone: u32 = 0x08; // i16 at low bytes, submesh_id u16 at high bytes
    // Translation OldAnimationBlock (28 bytes, +0x0C to +0x27)
    const trans_anim: u32 = 0x0C;
    const trans_nts: u32 = 0x18; // nTimestamps — gates translation interpolation
    // Rotation OldAnimationBlock (28 bytes, +0x28 to +0x43)
    const rot_anim: u32 = 0x28;
    const rot_nts: u32 = 0x34; // nTimestamps — gates rotation interpolation
    // Scale OldAnimationBlock (28 bytes, +0x44 to +0x5F)
    const scale_anim: u32 = 0x44;
    const scale_nts: u32 = 0x50; // nTimestamps — gates scale interpolation
    // Pivot point (12 bytes, +0x60 to +0x6B)
    const pivot_x: u32 = 0x60;
    const pivot_y: u32 = 0x64;
    const pivot_z: u32 = 0x68;
};

// Game constants
const ZERO_F: f32 = 0.0;
const ONE_F: f32 = 1.0;
const THREE_F: f32 = 3.0;
// getBillboardEpsilon(): read from game memory (runtime 0x34800000, NOT static 0x3727c5ac from Ghidra)
fn getBillboardEpsilon() f32 {
    return rf32(0x008029d4);
}
// getShortToFloat(): read from game memory at 0x00811610 (runtime value is 0x38000100 = 1/32767,
// NOT the static 0x38000000 = 1/32768 from Ghidra). The game patches this at startup.
fn getShortToFloat() f32 {
    return rf32(0x00811610);
}
const HERMITE_3: f32 = 3.0; // DAT_0080297c
// getHermite5(): runtime value is 0x40c00000 (6.0), NOT static 0x40a00000 (5.0) from Ghidra
fn getHermite5() f32 {
    return rf32(0x00802990);
}

// MSVC CRT sin/cos — linked from the WoW process
extern fn sinf(f32) f32;
extern fn cosf(f32) f32;

// Original transformMatrix4x4 for recursive attachment calls.
// The hook's detour will auto-dispatch to our SSE version.
const OrigTransformFn = *const fn (u32, u32, u32, u32, u32) callconv(.c) void;

// =============================================================================
// Memory access helpers
// =============================================================================

inline fn ru32(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}
inline fn ri32(addr: u32) i32 {
    return @as(*align(1) const i32, @ptrFromInt(addr)).*;
}
inline fn rf32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}
inline fn ru16(addr: u32) u16 {
    return @as(*align(1) const u16, @ptrFromInt(addr)).*;
}
inline fn ri16(addr: u32) i16 {
    return @as(*align(1) const i16, @ptrFromInt(addr)).*;
}
inline fn ru8(addr: u32) u8 {
    return @as(*const u8, @ptrFromInt(addr)).*;
}

inline fn wu32(addr: u32, v: u32) void {
    @as(*align(1) u32, @ptrFromInt(addr)).* = v;
}
inline fn wf32(addr: u32, v: f32) void {
    @as(*align(1) f32, @ptrFromInt(addr)).* = v;
}
inline fn wu16(addr: u32, v: u16) void {
    @as(*align(1) u16, @ptrFromInt(addr)).* = v;
}
inline fn wu8(addr: u32, v: u8) void {
    @as(*u8, @ptrFromInt(addr)).* = v;
}

inline fn fbits(v: f32) u32 {
    return @bitCast(v);
}
inline fn ufloat(v: u32) f32 {
    return @bitCast(v);
}

// =============================================================================
// Math helpers — using @Vector(4, f32) for SSE
// =============================================================================

inline fn splat(v: f32) V4 {
    return @splat(v);
}

/// 3-component lerp: a + (b - a) * t. Keyframes are 12 bytes (3 floats) apart.
inline fn lerpVec3(a_addr: u32, b_addr: u32, t: f32) [3]f32 {
    const ax = rf32(a_addr);
    const ay = rf32(a_addr + 4);
    const az = rf32(a_addr + 8);
    const bx = rf32(b_addr);
    const by = rf32(b_addr + 4);
    const bz = rf32(b_addr + 8);
    return .{
        (bx - ax) * t + ax,
        (by - ay) * t + ay,
        (bz - az) * t + az,
    };
}

/// Blend primary and secondary results: primary + (secondary - primary) * weight
inline fn blendVec3(primary: [3]f32, secondary: [3]f32, weight: f32) [3]f32 {
    return .{
        (secondary[0] - primary[0]) * weight + primary[0],
        (secondary[1] - primary[1]) * weight + primary[1],
        (secondary[2] - primary[2]) * weight + primary[2],
    };
}

/// Scale 3x3 rotation portion of a row-major 4x4 matrix by per-axis scale.
/// Row 0 *= scale.x, Row 1 *= scale.y, Row 2 *= scale.z
inline fn scaleMatrix3x3(mat: u32, sx: f32, sy: f32, sz: f32) void {
    // Row 0 (offsets 0x00, 0x04, 0x08)
    wf32(mat + 0x00, rf32(mat + 0x00) * sx);
    wf32(mat + 0x04, rf32(mat + 0x04) * sx);
    wf32(mat + 0x08, rf32(mat + 0x08) * sx);
    // Row 1 (offsets 0x10, 0x14, 0x18)
    wf32(mat + 0x10, rf32(mat + 0x10) * sy);
    wf32(mat + 0x14, rf32(mat + 0x14) * sy);
    wf32(mat + 0x18, rf32(mat + 0x18) * sy);
    // Row 2 (offsets 0x20, 0x24, 0x28)
    wf32(mat + 0x20, rf32(mat + 0x20) * sz);
    wf32(mat + 0x24, rf32(mat + 0x24) * sz);
    wf32(mat + 0x28, rf32(mat + 0x28) * sz);
}

/// Apply translation through rotation matrix:
///   mat[3][0] += dot(mat[0], t)
///   mat[3][1] += dot(mat[1], t)
///   mat[3][2] += dot(mat[2], t)
inline fn applyTranslation(mat: u32, tx: f32, ty: f32, tz: f32) void {
    wf32(mat + 0x30, tx * rf32(mat + 0x00) + ty * rf32(mat + 0x10) + tz * rf32(mat + 0x20) + rf32(mat + 0x30));
    wf32(mat + 0x34, tx * rf32(mat + 0x04) + ty * rf32(mat + 0x14) + tz * rf32(mat + 0x24) + rf32(mat + 0x34));
    wf32(mat + 0x38, tx * rf32(mat + 0x08) + ty * rf32(mat + 0x18) + tz * rf32(mat + 0x28) + rf32(mat + 0x38));
}

/// Quaternion → rotation matrix: OVERWRITES mat with the rotation matrix.
/// Matches the original game function at 0x74B6BB which writes directly
/// without multiplying by existing matrix contents.
/// Used in the bone loop where the matrix starts as identity.
inline fn buildRotationMatrix(mat: u32, qx: f32, qy: f32, qz: f32, qw: f32) void {
    const xx2 = qx * (qx + qx);
    const xy2 = qx * (qy + qy);
    const xz2 = qx * (qz + qz);
    const yy2 = qy * (qy + qy);
    const yz2 = qy * (qz + qz);
    const zz2 = qz * (qz + qz);
    const wx2 = qw * (qx + qx);
    const wy2 = qw * (qy + qy);
    const wz2 = qw * (qz + qz);

    // Row 0
    wf32(mat + 0x00, 1.0 - (yy2 + zz2));
    wf32(mat + 0x04, xy2 + wz2);
    wf32(mat + 0x08, xz2 - wy2);
    wf32(mat + 0x0C, 0);
    // Row 1
    wf32(mat + 0x10, xy2 - wz2);
    wf32(mat + 0x14, 1.0 - (xx2 + zz2));
    wf32(mat + 0x18, yz2 + wx2);
    wf32(mat + 0x1C, 0);
    // Row 2
    wf32(mat + 0x20, xz2 + wy2);
    wf32(mat + 0x24, yz2 - wx2);
    wf32(mat + 0x28, 1.0 - (xx2 + yy2));
    wf32(mat + 0x2C, 0);
    // Row 3 (translation = zero, w = 1)
    wf32(mat + 0x30, 0);
    wf32(mat + 0x34, 0);
    wf32(mat + 0x38, 0);
    wf32(mat + 0x3C, 1);
}

/// Quaternion → rotation matrix, then multiply: mat = quat_rot * mat.
/// Standard quat→mat conversion + SSE 4x4 matrix multiply.
/// Used in bone keyframe processing where matrix already has content.
inline fn rotateByQuaternion(mat: u32, qx: f32, qy: f32, qz: f32, qw: f32) void {
    const xx2 = qx * (qx + qx);
    const xy2 = qx * (qy + qy);
    const xz2 = qx * (qz + qz);
    const yy2 = qy * (qy + qy);
    const yz2 = qy * (qz + qz);
    const zz2 = qz * (qz + qz);
    const wx2 = qw * (qx + qx);
    const wy2 = qw * (qy + qy);
    const wz2 = qw * (qz + qz);

    // Rotation matrix from quaternion (row-major)
    const rot: [16]f32 = .{
        1.0 - (yy2 + zz2), xy2 + wz2,         xz2 - wy2,         0,
        xy2 - wz2,         1.0 - (xx2 + zz2), yz2 + wx2,         0,
        xz2 + wy2,         yz2 - wx2,         1.0 - (xx2 + yy2), 0,
        0,                  0,                  0,                  1,
    };

    // SSE matrix multiply: result = rot * mat
    var tmp: [16]f32 = undefined;
    const r0: V4 = .{ rf32(mat + 0x00), rf32(mat + 0x04), rf32(mat + 0x08), rf32(mat + 0x0C) };
    const r1: V4 = .{ rf32(mat + 0x10), rf32(mat + 0x14), rf32(mat + 0x18), rf32(mat + 0x1C) };
    const r2: V4 = .{ rf32(mat + 0x20), rf32(mat + 0x24), rf32(mat + 0x28), rf32(mat + 0x2C) };
    const r3: V4 = .{ rf32(mat + 0x30), rf32(mat + 0x34), rf32(mat + 0x38), rf32(mat + 0x3C) };

    inline for (0..4) |i| {
        const b = i * 4;
        const out = splat(rot[b]) * r0 + splat(rot[b + 1]) * r1 + splat(rot[b + 2]) * r2 + splat(rot[b + 3]) * r3;
        tmp[b] = out[0];
        tmp[b + 1] = out[1];
        tmp[b + 2] = out[2];
        tmp[b + 3] = out[3];
    }

    // Copy back
    inline for (0..16) |i| {
        wf32(mat + @as(u32, @intCast(i)) * 4, tmp[i]);
    }
}

/// Copy 16 floats (4x4 matrix)
inline fn copyMat4(dst: u32, src: u32) void {
    comptime var i: u32 = 0;
    inline while (i < 64) : (i += 4) {
        wu32(dst + i, ru32(src + i));
    }
}

/// 4x4 matrix multiply: dst = a * b (row-major). Safe for dst==a or dst==b.
/// Uses f64 intermediates for precision. Scalar — no alignment requirements.
fn matMul4x4(dst: u32, a: u32, b: u32) void {
    var m: [16]f64 = undefined;
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            const i = row * 4 + col;
            m[i] = @as(f64, rf32(a + @as(u32, @intCast(row)) * 16)) * @as(f64, rf32(b + @as(u32, @intCast(col)) * 4)) +
                @as(f64, rf32(a + @as(u32, @intCast(row)) * 16 + 4)) * @as(f64, rf32(b + @as(u32, @intCast(col)) * 4 + 16)) +
                @as(f64, rf32(a + @as(u32, @intCast(row)) * 16 + 8)) * @as(f64, rf32(b + @as(u32, @intCast(col)) * 4 + 32)) +
                @as(f64, rf32(a + @as(u32, @intCast(row)) * 16 + 12)) * @as(f64, rf32(b + @as(u32, @intCast(col)) * 4 + 48));
        }
    }
    inline for (0..16) |i| {
        wf32(dst + @as(u32, @intCast(i)) * 4, @floatCast(m[i]));
    }
}

/// Set identity matrix (16 floats)
inline fn setIdentity(dst: u32) void {
    inline for (0..16) |i| {
        const val: f32 = if (i == 0 or i == 5 or i == 10 or i == 15) 1.0 else 0.0;
        wf32(dst + @as(u32, @intCast(i)) * 4, val);
    }
}

/// Normalize a 3-component vector in memory at addr.
/// Calls game's vec3 squared magnitude (0x4549F0), then sqrt, epsilon check, divide.
/// Assembly pattern: CALL 0x4549F0 → FSQRT → FABS → FCOMP → FLD1 → FDIVRP → FMUL×3
inline fn normalizeVec3InPlace(addr: u32) void {
    const sq_mag = callVec3SqMag(addr);
    const len = @sqrt(sq_mag);
    if (@abs(len) >= getBillboardEpsilon()) {
        const inv = 1.0 / len;
        wf32(addr, rf32(addr) * inv);
        wf32(addr + 4, rf32(addr + 4) * inv);
        wf32(addr + 8, rf32(addr + 8) * inv);
    }
}

/// Normalize a 3-component vector, returns (nx, ny, nz). Returns unchanged if too small.
/// Writes vec3 to stack local and calls game's vec3 squared magnitude (0x4549F0).
inline fn normalizeVec3(x: f32, y: f32, z: f32) [3]f32 {
    var v: [3]f32 = .{ x, y, z };
    const sq_mag = callVec3SqMag(@intFromPtr(&v));
    const len = @sqrt(sq_mag);
    if (len < getBillboardEpsilon()) return .{ x, y, z };
    const inv = 1.0 / len;
    return .{ x * inv, y * inv, z * inv };
}

/// Cross product of two 3-component vectors
inline fn crossVec3(ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32) [3]f32 {
    return .{
        ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx,
    };
}

// =============================================================================
// findInterpolationIndices — reimplemented from 0x713d50 (334 bytes)
//
// Three-tier search with temporal coherence:
// 1. Forward linear scan (hot path, 1-4 iterations typical)
// 2. Backward linear scan (negative delta)
// 3. Binary search (fallback)
//
// Output: indices[0] = lower index, [1] = upper index, [2] = interpolation t (float bits)
// =============================================================================

/// findInterpIdx: temporal-coherence keyframe search.
/// Reimplementation of game function at 0x713D50 (334 bytes).
/// Assembly-verified against t44_helpers_asm.txt.
fn findInterpIdx(this: u32, search_value: u32, track_index: u32, anim_data: u32, output: u32) void {
    const n_ranges = ru32(anim_data + AD.track_count_flag);

    // Range selection: [start, last] not [start, count]
    var range_start: u32 = undefined;
    var range_last: u32 = undefined;
    if (n_ranges != 0) {
        const ranges = ru32(anim_data + AD.keyframe_ranges);
        range_last = ru32(ranges + track_index * 8 + 4);
        range_start = ru32(ranges + track_index * 8);
    } else {
        range_last = ru32(anim_data + AD.keyframe_count) -% 1;
        range_start = 0;
    }

    if (range_start >= range_last) {
        wu32(output, range_start);
        wu32(output + 4, range_start);
        wu32(output + 8, 0);
        return;
    }

    // Global sequence override: CMP AX,0xFFFF
    const time_idx_raw = ri16(anim_data + AD.time_index);
    const search: u32 = if (time_idx_raw != -1) blk: {
        const gs_vals = ru32(this + SO.gs_values_ptr);
        break :blk ru32(gs_vals + @as(u32, @intCast(@as(u16, @bitCast(time_idx_raw)))) * 4);
    } else search_value;

    const ts_base = ru32(anim_data + AD.timestamps_ptr);
    const cached = ru32(output);
    const ts_cached = ru32(ts_base + cached * 4);
    const delta: u32 = search -% ts_cached;

    var result: u32 = undefined;

    if (delta < 0x1F4) {
        // Forward scan from cached
        result = cached;
        if (result < range_last) {
            var ptr = ts_base + result * 4 + 4;
            while (ru32(ptr) <= search) {
                result += 1;
                ptr += 4;
                if (result >= range_last) break;
            }
        }
    } else if (delta >= 0xFFFFFE0C) {
        // Backward scan from cached
        result = cached;
        if (result > range_start) {
            var ptr = ts_base + result * 4;
            while (ru32(ptr) > search) {
                result -= 1;
                ptr -= 4;
                if (result <= range_start) break;
            }
        }
    } else {
        // Check delta from range_start
        const ts_first = ru32(ts_base + range_start * 4);
        const delta_first: u32 = search -% ts_first;
        if (delta_first < 0x1F4) {
            result = range_start;
            var ptr = ts_base + range_start * 4 + 4;
            while (ru32(ptr) <= search) {
                result += 1;
                ptr += 4;
                if (result >= range_last) break;
            }
        } else {
            // Binary search
            var lo = range_start;
            var hi = range_last;
            while (lo < hi) {
                const mid = (hi +% lo) >> 1;
                if (search < ru32(ts_base + mid * 4)) {
                    hi = mid -% 1;
                } else {
                    if (search < ru32(ts_base + mid * 4 + 4)) {
                        lo = mid;
                        break;
                    }
                    lo = mid + 1;
                }
            }
            result = lo;
        }
    }

    // Post-search: bounds check against total keyframe_count
    const kf_count = ru32(anim_data + AD.keyframe_count);
    const next = result + 1;

    if (next >= kf_count) {
        wu32(output, result);
        wu32(output + 4, result);
        wu32(output + 8, 0);
        return;
    }

    // Interpolation factor: FILD qword / FIDIV dword
    const ts_lo = ru32(ts_base + result * 4);
    const ts_hi = ru32(ts_base + next * 4);
    const numer = search -% ts_lo;
    const denom = ts_hi -% ts_lo;
    const t: f32 = @floatCast(@as(f64, @floatFromInt(@as(i64, numer))) / @as(f64, @floatFromInt(@as(i32, @bitCast(denom)))));

    wu32(output, result);
    wu32(output + 4, next);
    wu32(output + 8, @bitCast(t));
}

// =============================================================================
// interpolateAnimationKeyframes — reimplemented from 0x713ea0
//
// Calls findInterpIdx, does 4-component lerp (for quaternions).
// If crossfade active, does secondary lookup + blend.
// Output buffer layout: [idx0, idx1, t, x, y, z, w, sec_idx0, sec_idx1, sec_t, sx, sy, sz, sw]
// =============================================================================

/// Quaternion keyframe interpolation — replaces game's 0x713EA0.
/// Assembly-verified: stride 16 (SHL EAX,4), values are 4×float, not CompQuat.
inline fn interpAnimKF(this: u32, bone_rt: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);
    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (mode == 0) {
        const src = kf_base + ru32(output) * 16;
        wu32(output + 0x0C, ru32(src));
        wu32(output + 0x10, ru32(src + 4));
        wu32(output + 0x14, ru32(src + 8));
        wu32(output + 0x18, ru32(src + 12));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const src0 = kf_base + ru32(output) * 16;
    const src1 = kf_base + ru32(output + 4) * 16;
    inline for (0..4) |i| {
        const off: u32 = @intCast(i * 4);
        const a = rf32(src0 + off);
        const b = rf32(src1 + off);
        wf32(output + 0x0C + off, (b - a) * t + a);
    }

    // Crossfade
    if (rf32(bone_rt + BR.blend_weight) != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x1C);
        const st = ufloat(ru32(output + 0x24));
        const ssrc0 = kf_base + ru32(output + 0x1C) * 16;
        const ssrc1 = kf_base + ru32(output + 0x20) * 16;
        inline for (0..4) |i| {
            const off: u32 = @intCast(i * 4);
            const a = rf32(ssrc0 + off);
            const b = rf32(ssrc1 + off);
            wf32(output + 0x28 + off, (b - a) * st + a);
        }
        // Blend: primary = primary + (secondary - primary) * weight
        const bw = rf32(bone_rt + BR.blend_weight);
        inline for (0..4) |i| {
            const off: u32 = @intCast(i * 4);
            const pri = rf32(output + 0x0C + off);
            const sec = rf32(output + 0x28 + off);
            wf32(output + 0x0C + off, (sec - pri) * bw + pri);
        }
    }
}

// =============================================================================
// Game function call wrappers — replacing reimplementations with actual calls
// =============================================================================

/// Float truncation — replaces game's __ftol at 0x40A2B0.
/// Original: FILD i32 → FMUL f32 → __ftol, all in 80-bit x87 precision.
/// Uses f64 intermediate (53-bit mantissa) to approximate x87's 64-bit.
inline fn callFtol(delta: i32, scale_addr: u32) i32 {
    const f = @as(f64, @floatFromInt(delta)) * @as(f64, rf32(scale_addr));
    return @intFromFloat(f);
}

/// Vec3 squared magnitude — replaces game's 0x4549F0.
inline fn callVec3SqMag(vec3_ptr: u32) f32 {
    const x = rf32(vec3_ptr);
    const y = rf32(vec3_ptr + 4);
    const z = rf32(vec3_ptr + 8);
    return x * x + y * y + z * z;
}

/// Read i16 at keyframe index. Replaces game's getIndexOffset (0x71AFF0) + setShortValue (0x71B010).
/// getIndexOffset returns table[4] + index*2, setShortValue copies a word. Direct read is equivalent.
inline fn readShortViaGame(table: u32, index: u32) i16 {
    const values_ptr = ru32(table + 4);
    return ri16(values_ptr + index * 2);
}

/// Interpolate a Vec3 track (12 bytes per keyframe) with crossfade support.
/// Writes result to output[3..5] (as u32 float bits). Uses output[0..2] for indices/t,
/// and output[6..11] for secondary crossfade state.
inline fn interpVec3Track(
    this: u32,
    bone_rt: u32,
    anim_data: u32,
    output: u32,
    blend_weight: f32,
) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const interp_mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (interp_mode == 0) {
        // No interpolation — copy keyframe directly
        const src = kf_base + ru32(output) * 0xC;
        wu32(output + 0x0C, ru32(src));
        wu32(output + 0x10, ru32(src + 4));
        wu32(output + 0x14, ru32(src + 8));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const a = kf_base + ru32(output) * 0xC;
    const b = kf_base + ru32(output + 4) * 0xC;
    const result = lerpVec3(a, b, t);
    wu32(output + 0x0C, fbits(result[0]));
    wu32(output + 0x10, fbits(result[1]));
    wu32(output + 0x14, fbits(result[2]));

    // Crossfade blend
    if (blend_weight != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x18);
        const st = ufloat(ru32(output + 0x20));
        const sa = kf_base + ru32(output + 0x18) * 0xC;
        const sb = kf_base + ru32(output + 0x1C) * 0xC;
        const sec = lerpVec3(sa, sb, st);
        wu32(output + 0x24, fbits(sec[0]));
        wu32(output + 0x28, fbits(sec[1]));
        wu32(output + 0x2C, fbits(sec[2]));

        // Blend
        const pri_x = ufloat(ru32(output + 0x0C));
        const pri_y = ufloat(ru32(output + 0x10));
        const pri_z = ufloat(ru32(output + 0x14));
        wu32(output + 0x0C, fbits((sec[0] - pri_x) * blend_weight + pri_x));
        wu32(output + 0x10, fbits((sec[1] - pri_y) * blend_weight + pri_y));
        wu32(output + 0x14, fbits((sec[2] - pri_z) * blend_weight + pri_z));
    }
}

/// Interpolate a single float track (4 bytes per keyframe) with crossfade.
/// Writes result to output[3] as float bits.
inline fn interpFloatTrack(
    this: u32,
    bone_rt: u32,
    anim_data: u32,
    output: u32,
    blend_weight: f32,
) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const interp_mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (interp_mode == 0) {
        wu32(output + 0x0C, ru32(kf_base + ru32(output) * 4));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const a = rf32(kf_base + ru32(output) * 4);
    const b = rf32(kf_base + ru32(output + 4) * 4);
    wf32(output + 0x0C, (b - a) * t + a);

    // Crossfade — only for bone loop callers (particles pass 0.0)
    if (blend_weight != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x10);
        const st = ufloat(ru32(output + 0x18));
        const sa = rf32(kf_base + ru32(output + 0x10) * 4);
        const sb = rf32(kf_base + ru32(output + 0x14) * 4);
        const sec = (sb - sa) * st + sa;
        wu32(output + 0x1C, fbits(sec));
        const pri = ufloat(ru32(output + 0x0C));
        wf32(output + 0x0C, (sec - pri) * blend_weight + pri);
    }
}

// =============================================================================
// Hermite/Bezier basis + particle emitter interp helpers
// =============================================================================

inline fn hermiteBasis(t: f32) struct { h1: f32, h2: f32, h3: f32, h4: f32 } {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        .h1 = 2 * t3 - 3 * t2 + 1,
        .h2 = t3 - 2 * t2 + t,
        .h3 = -2 * t3 + 3 * t2,
        .h4 = t3 - t2,
    };
}

inline fn bezierBasis(t: f32) struct { b0: f32, b1: f32, b2: f32, b3: f32 } {
    const u = 1.0 - t;
    const t2 = t * t;
    const u_sq = u * u;
    return .{
        .b0 = u_sq * u,
        .b1 = 3 * u_sq * t,
        .b2 = 3 * u * t2,
        .b3 = t2 * t,
    };
}

fn interpVec3Track36(this: u32, bone_rt_base: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt_base + 0x98), ru32(bone_rt_base + 0x9C), anim_data, output);

    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (mode == 0) {
        const src = kf_base + ru32(output) * 36;
        wu32(output + 0x0C, ru32(src));
        wu32(output + 0x10, ru32(src + 4));
        wu32(output + 0x14, ru32(src + 8));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const kf_a = kf_base + ru32(output) * 36;
    const kf_b = kf_base + ru32(output + 4) * 36;

    if (mode == 1) {
        const result = lerpVec3(kf_a, kf_b, t);
        wu32(output + 0x0C, fbits(result[0]));
        wu32(output + 0x10, fbits(result[1]));
        wu32(output + 0x14, fbits(result[2]));
    } else if (mode == 3) {
        const h = hermiteBasis(t);
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const off = i * 4;
            wf32(output + 0x0C + off, h.h1 * rf32(kf_a + off) + h.h2 * rf32(kf_a + 0x18 + off) + h.h3 * rf32(kf_b + off) + h.h4 * rf32(kf_b + 0x0C + off));
        }
    } else if (mode == 2) {
        const b = bezierBasis(t);
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const off = i * 4;
            wf32(output + 0x0C + off, b.b0 * rf32(kf_a + off) + b.b1 * rf32(kf_a + 0x18 + off) + b.b2 * rf32(kf_b + 0x0C + off) + b.b3 * rf32(kf_b + off));
        }
    } else {} // Unknown mode: skip primary interp, fall through to crossfade (asm 0x716B98: JNZ crossfade_check)

    const blend = rf32(bone_rt_base + BR.blend_weight);
    if (blend != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), anim_data, output + 0x18);

        const st = ufloat(ru32(output + 0x20));
        const skf_a = kf_base + ru32(output + 0x18) * 36;
        const skf_b = kf_base + ru32(output + 0x1C) * 36;
        const smode = ri16(anim_data + AD.interp_mode);

        if (smode == 1) {
            const sec = lerpVec3(skf_a, skf_b, st);
            wu32(output + 0x24, fbits(sec[0]));
            wu32(output + 0x28, fbits(sec[1]));
            wu32(output + 0x2C, fbits(sec[2]));
        } else if (smode == 3) {
            const h = hermiteBasis(st);
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                const off = i * 4;
                wf32(output + 0x24 + off, h.h1 * rf32(skf_a + off) + h.h2 * rf32(skf_a + 0x18 + off) + h.h3 * rf32(skf_b + off) + h.h4 * rf32(skf_b + 0x0C + off));
            }
        } else if (smode == 2) {
            const b = bezierBasis(st);
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                const off = i * 4;
                wf32(output + 0x24 + off, b.b0 * rf32(skf_a + off) + b.b1 * rf32(skf_a + 0x18 + off) + b.b2 * rf32(skf_b + 0x0C + off) + b.b3 * rf32(skf_b + off));
            }
        } else {
            wu32(output + 0x24, ru32(skf_a));
            wu32(output + 0x28, ru32(skf_a + 4));
            wu32(output + 0x2C, ru32(skf_a + 8));
        }

        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const off = i * 4;
            const pri = rf32(output + 0x0C + off);
            const sec = rf32(output + 0x24 + off);
            wf32(output + 0x0C + off, (sec - pri) * blend + pri);
        }
    }
}

fn interpFloatTrack12(this: u32, bone_rt_base: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt_base + 0x98), ru32(bone_rt_base + 0x9C), anim_data, output);

    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (mode == 0) {
        wu32(output + 0x0C, ru32(kf_base + ru32(output) * 12));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const kf_a = kf_base + ru32(output) * 12;
    const kf_b = kf_base + ru32(output + 4) * 12;

    if (mode == 1) {
        const a = rf32(kf_a);
        const b = rf32(kf_b);
        wf32(output + 0x0C, (b - a) * t + a);
    } else if (mode == 3) {
        const h = hermiteBasis(t);
        wf32(output + 0x0C, h.h1 * rf32(kf_a) + h.h2 * rf32(kf_a + 0x08) + h.h3 * rf32(kf_b) + h.h4 * rf32(kf_b + 0x04));
    } else if (mode == 2) {
        const b = bezierBasis(t);
        wf32(output + 0x0C, b.b0 * rf32(kf_a) + b.b1 * rf32(kf_a + 0x08) + b.b2 * rf32(kf_b + 0x04) + b.b3 * rf32(kf_b));
    } else {} // Unknown mode: skip primary interp, fall through to crossfade

    const blend = rf32(bone_rt_base + BR.blend_weight);
    if (blend != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), anim_data, output + 0x10);

        const st = ufloat(ru32(output + 0x18));
        const skf_a = kf_base + ru32(output + 0x10) * 12;
        const skf_b = kf_base + ru32(output + 0x14) * 12;
        const smode = ri16(anim_data + AD.interp_mode);

        var sec: f32 = undefined;
        if (smode == 1) {
            sec = (rf32(skf_b) - rf32(skf_a)) * st + rf32(skf_a);
        } else if (smode == 3) {
            const h = hermiteBasis(st);
            sec = h.h1 * rf32(skf_a) + h.h2 * rf32(skf_a + 0x08) + h.h3 * rf32(skf_b) + h.h4 * rf32(skf_b + 0x04);
        } else if (smode == 2) {
            const bz = bezierBasis(st);
            sec = bz.b0 * rf32(skf_a) + bz.b1 * rf32(skf_a + 0x08) + bz.b2 * rf32(skf_b + 0x04) + bz.b3 * rf32(skf_b);
        } else {
            sec = rf32(skf_a);
        }
        wf32(output + 0x1C, sec);
        const pri = rf32(output + 0x0C);
        wf32(output + 0x0C, (sec - pri) * blend + pri);
    }
}

// =============================================================================
// getInterpolatedFloat — reimplemented from 0x71af20
// Same as interpFloatTrack but uses the bone_rt directly (different register mapping)
// =============================================================================

inline fn getInterpolatedFloat(this: u32, bone_rt_addr: u32, anim_data_short_ptr: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt_addr + 0x98), ru32(bone_rt_addr + 0x9C), anim_data_short_ptr, output);

    const interp_mode = ri16(anim_data_short_ptr);
    const kf_base = ru32(anim_data_short_ptr + 0x18);

    if (interp_mode == 0) {
        wu32(output + 0x0C, ru32(kf_base + ru32(output) * 4));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const a = rf32(kf_base + ru32(output) * 4);
    const b = rf32(kf_base + ru32(output + 4) * 4);
    wf32(output + 0x0C, (b - a) * t + a);

    const blend = rf32(bone_rt_addr + 0x10C);
    if (blend != 0.0 and ri16(anim_data_short_ptr + 2) == -1) {
        findInterpIdx(this, ru32(bone_rt_addr + 0xC4), ru32(bone_rt_addr + 0xC8), anim_data_short_ptr, output + 0x10);
        const st = ufloat(ru32(output + 0x18));
        const sa = rf32(kf_base + ru32(output + 0x10) * 4);
        const sb = rf32(kf_base + ru32(output + 0x14) * 4);
        const sec = (sb - sa) * st + sa;
        wu32(output + 0x1C, fbits(sec));
        const pri = ufloat(ru32(output + 0x0C));
        wf32(output + 0x0C, (sec - pri) * blend + pri);
    }
}

// =============================================================================
// calculateScaledInverseMatrix — reimplemented from 0x7bd820
// Used for billboarding. Transposes 3x3 rotation, scales by 1/scale^2,
// applies inverse translation.
// =============================================================================

fn calcScaledInverse(this_mat: u32, out: u32, scale: f32) void {
    // Simple transpose for unit scale
    if (@abs(scale - 1.0) < @as(f32, @bitCast(@as(u32, 0x35800000)))) {
        // Transpose 3x3
        wf32(out + 0x00, rf32(this_mat + 0x00));
        wf32(out + 0x04, rf32(this_mat + 0x10));
        wf32(out + 0x08, rf32(this_mat + 0x20));
        wf32(out + 0x0C, 0);
        wf32(out + 0x10, rf32(this_mat + 0x04));
        wf32(out + 0x14, rf32(this_mat + 0x14));
        wf32(out + 0x18, rf32(this_mat + 0x24));
        wf32(out + 0x1C, 0);
        wf32(out + 0x20, rf32(this_mat + 0x08));
        wf32(out + 0x24, rf32(this_mat + 0x18));
        wf32(out + 0x28, rf32(this_mat + 0x28));
        wf32(out + 0x2C, 0);
        wf32(out + 0x30, 0);
        wf32(out + 0x34, 0);
        wf32(out + 0x38, 0);
        wf32(out + 0x3C, @as(f32, @bitCast(@as(u32, 0x3f800000))));
        // Apply inverse translation
        applyTranslation(out, -rf32(this_mat + 0x30), -rf32(this_mat + 0x34), -rf32(this_mat + 0x38));
        return;
    }

    // Transpose 3x3 portion
    wf32(out + 0x00, rf32(this_mat + 0x00));
    wf32(out + 0x04, rf32(this_mat + 0x10));
    wf32(out + 0x08, rf32(this_mat + 0x20));
    wf32(out + 0x0C, 0);
    wf32(out + 0x10, rf32(this_mat + 0x04));
    wf32(out + 0x14, rf32(this_mat + 0x14));
    wf32(out + 0x18, rf32(this_mat + 0x24));
    wf32(out + 0x1C, 0);
    wf32(out + 0x20, rf32(this_mat + 0x08));
    wf32(out + 0x24, rf32(this_mat + 0x18));
    wf32(out + 0x28, rf32(this_mat + 0x28));
    wf32(out + 0x2C, 0);
    wf32(out + 0x30, 0);
    wf32(out + 0x34, 0);
    wf32(out + 0x38, 0);
    wf32(out + 0x3C, @as(f32, @bitCast(@as(u32, 0x3f800000))));

    // Scale by 1/(scale^2)
    const inv_s2 = 1.0 / (scale * scale);
    scaleMatrix3x3(out, inv_s2, inv_s2, inv_s2);

    // Apply inverse translation
    applyTranslation(out, -rf32(this_mat + 0x30), -rf32(this_mat + 0x34), -rf32(this_mat + 0x38));
}

// =============================================================================
// Main export: transformMatrix4x4_REF
//
// Calling convention: x86_thiscall — matches the original at 0x714260 exactly.
// ECX=this, stack: mat1..mat4, callee cleans RET 0x10.
//
// Params: this_ptr(ECX), mat1(parent_matrix*), mat2(position_vec3*),
//         mat3(offset_vec3*), mat4(scale_float_bits)
// =============================================================================

export fn transformImpl_SSE(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.c) void {

    @setEvalBranchQuota(50000);
    // =========================================================================
    // Section 1: Entry checks
    // =========================================================================
    if (ru32(this + SO.model_data_ptr) == 0) return;
    const anim_ctx = ru32(this + SO.anim_ctx_ptr);
    if (ru32(this + SO.sync_value) == ru32(anim_ctx + 0x10)) return;


    // =========================================================================
    // Section 2: Emitter setup
    // =========================================================================
    const model_ctr = ru32(this + SO.model_ctr_ptr);
    const model_hdr = ru32(model_ctr + 0x130);
    const emitter_ctx = ru32(this + SO.emitter_ctx);

    if (emitter_ctx != 0) {
        // Assembly 0x71429E-0x7142C1: emitter_ctx+0x50 != 0 AND this+0x1D8 != 0
        const has_emitter: u32 = if (ru32(emitter_ctx + 0x50) != 0 and ru32(this + 0x1D8) != 0) 1 else 0;
        wu32(this + 0x50, has_emitter); // emitter_enable_flag
        wu32(this + 0x17C, ru32(emitter_ctx + 0x17C));
    }

    // =========================================================================
    // Section 3: World position/scale
    // =========================================================================
    const pos_ptr = mat2; // position input Vec3
    const ofs_ptr = mat3; // offset input Vec3
    const scale_f: f32 = @bitCast(mat4); // float scale

    // world_pos = pos * per_axis_scale
    wf32(this + SO.world_pos + 0, rf32(pos_ptr) * rf32(this + SO.field_184));
    wf32(this + SO.world_pos + 4, rf32(this + SO.field_188) * rf32(pos_ptr + 4));
    wf32(this + SO.world_pos + 8, @bitCast(fbits(rf32(this + SO.field_18c) * rf32(pos_ptr + 8))));

    // render_pri = offset + existing fields
    const rp0 = rf32(ofs_ptr) + rf32(this + SO.field_190);
    const rp1 = rf32(this + SO.render_scale_x) + rf32(ofs_ptr + 4);
    const rp2 = rf32(this + SO.render_scale_y) + rf32(ofs_ptr + 8);
    wf32(this + SO.render_pri + 0, rp0);
    wf32(this + SO.render_pri + 4, rp1);
    wf32(this + SO.render_pri + 8, rp2);

    // render_scale_z = scale * field_180
    wf32(this + SO.render_scale_z, scale_f * rf32(this + SO.field_180));

    // =========================================================================
    // Section 4: Global sequence processing
    // =========================================================================
    const gs_count = ru32(model_hdr + 0x14);
    if (gs_count != 0) {
        const gs_durations = ru32(model_hdr + 0x18);
        const gs_values = ru32(this + SO.gs_values_ptr);
        const timestamp = ru32(anim_ctx + 0x0C);
        const time_base = ru32(this + SO.gs_time_base);
        var gi: u32 = 0;
        while (gi < gs_count) : (gi += 1) {
            const dur = ru32(gs_durations + gi * 4);
            if (dur == 0) {
                wu32(gs_values + gi * 4, 0);
            } else {
                wu32(gs_values + gi * 4, (timestamp -% time_base) % dur);
            }
        }
    }

    // initParticlePixelShaderGeneration (0x74a7c0) — matrix multiply via JMP table.
    // Computes: *(this+0xFC) = *(this+0xBC) × mat1
    // Assembly: PUSH mat1, PUSH &0xBC, PUSH &0xFC, CALL 0x74A7C0
    // 0x74A7C0 = JMP [0x876504] → runtime target (0x754A66 SSE version)
    // Must call through 0x74A7C0, NOT 0x7507BB directly.
    matMul4x4(this + 0xFC, this + 0xBC, mat1);

    // =========================================================================
    // Section 5: child_objects_padding (len_sq of world transform translation)
    // Assembly re-reads emitter_ctx from this+0x1CC AFTER matMul (0x7143A0).
    // =========================================================================
    const emitter_ctx_5 = ru32(this + SO.emitter_ctx);
    if (emitter_ctx_5 == 0 or (ru8(emitter_ctx_5 + 4) & 1) != 0) {
        const wx = rf32(this + SO.world_xform + 8 * 4); // [8]
        const wy = rf32(this + SO.world_xform + 9 * 4); // [9]
        const wz = rf32(this + SO.world_xform + 10 * 4); // [10]
        wu32(this + SO.child_padding, fbits(wx * wx + wy * wy + wz * wz));
    } else {
        wu32(this + SO.child_padding, ru32(emitter_ctx_5 + 0x84));
    }

    // =========================================================================
    // Section 6: Identity matrix init + timestamp delta
    // =========================================================================
    var local_mat: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const local_mat_addr = @intFromPtr(&local_mat);

    // Secondary identity (3x4 portion for the second matrix in decompilation)
    var local_mat2: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };

    // Timestamp delta tracking
    // Assembly (0x7143EE-0x71451C): outer guard is this+0x4C != 0 (NOT anim_ctx).
    // If stored value is 0, does NOTHING — never writes, never computes delta.
    // Something else must initialize this+0x4C; we must NOT seed it ourselves.
    var time_delta_val: u32 = 0;
    const sdb = ru32(this + SO.search_data_base);
    if (sdb != 0) {
        const cur_ts = ru32(anim_ctx + 0x0C);
        if (cur_ts != 0) {
            time_delta_val = cur_ts -% sdb;
            wu32(this + SO.search_data_base, cur_ts);
        }
    }

    // =========================================================================
    // Section 7: Main bone loop
    // =========================================================================
    const bone_count = ru32(model_hdr + 0x34);
    const bone_defs = ru32(model_hdr + 0x38);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const bone_out_base = ru32(this + SO.bone_out_ptr);

    if (bone_count != 0) {
        var bone_idx: u32 = 0;
        while (bone_idx < bone_count) : (bone_idx += 1) {
            const bdef = bone_defs + bone_idx * 0x6C;
            const brt = bone_rt_base + bone_idx * 0x118;
            const flags = ru32(bdef + BD.flags);
            const parent_idx_raw: i32 = @as(i32, @intCast(@as(i16, @bitCast(ru16(bdef + BD.parent_bone)))));

            // --- Animation time computation ---
            // (Handle primary and secondary animation slot timing)
            const anim_slot_val = ri32(brt + BR.anim_slot);
            if (anim_slot_val == -1) {
                // Inherit from parent bone
                if (parent_idx_raw >= 0 and @as(u32, @intCast(parent_idx_raw)) < bone_count) {
                    const parent_rt = bone_rt_base + @as(u32, @intCast(parent_idx_raw)) * 0x118;
                    wu32(brt + BR.prim_time, ru32(parent_rt + BR.prim_time));
                    wu32(brt + BR.prim_track, ru32(parent_rt + BR.prim_track));
                    wu32(brt + BR.prim_anim, ru32(parent_rt + BR.prim_anim));
                } else if (bone_idx != 0) {
                    wu32(brt + BR.prim_time, ru32(bone_rt_base + BR.prim_time));
                    wu32(brt + BR.prim_track, ru32(bone_rt_base + BR.prim_track));
                    wu32(brt + BR.prim_anim, ru32(bone_rt_base + BR.prim_anim));
                }
            } else {
                // Has own animation slot — compute time from animation lookup table.
                // Assembly at 0x714561-0x71464E, verified line by line.
                if (ru32(this + 0x4C) != 0) { // search_data_base_ptr != 0
                    // Add time delta to sec_start/sec_end
                    wu32(brt + 0xA8, ru32(brt + 0xA8) +% time_delta_val); // [ESI+0xA8]
                    wu32(brt + 0xAC, ru32(brt + 0xAC) +% time_delta_val); // [ESI+0xAC]
                }

                // anim_entry = anim_lookup_table + anim_slot * 0x44
                const anim_lookup = ru32(model_hdr + 0x20); // [EDX+0x20]
                const anim_entry = anim_lookup + @as(u32, @bitCast(anim_slot_val)) * 0x44;
                const cur_time = ru32(ru32(this + 0x2C) + 0xC); // [EBX+0x2C]+0xC = timestamp

                // Check looping flag: [anim_entry+0x10] & 1
                if ((ru8(anim_entry + 0x10) & 1) == 0) {
                    // Looping: assembly at 0x7145F1-0x714631
                    const anim_end = ru32(anim_entry + 0x08);
                    const anim_start = ru32(anim_entry + 0x04);
                    if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                        // elapsed = (float)(cur_time - sec_start) * time_scale → __ftol
                        const delta = cur_time -% ru32(brt + 0xA8);
                        const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xB0);
                        const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8)) % (anim_end -% anim_start);
                        wu32(brt + 0x98, anim_start +% frame); // prim_time
                    } else {
                        // Assembly 0x714631: MOV EDX,EAX — fallback to anim_start
                        wu32(brt + 0x98, anim_start);
                    }
                } else {
                    // Clamped: assembly at 0x71458E-0x7145E3
                    const sec_end_val = ru32(brt + 0xAC);
                    const sec_start_val = ru32(brt + 0xA8);

                    // Check if sec_end has passed (sec_end - cur_time <= 0 signed)
                    if (sec_end_val != cur_time and @as(i32, @bitCast(sec_end_val -% cur_time)) > 0) {
                        // sec_end hasn't passed yet
                        // Assembly 0x7145E5: clamp cur_time to sec_start if sec_start > cur_time
                        const effective_time = if (@as(i32, @bitCast(sec_start_val -% cur_time)) > 0) sec_start_val else cur_time;
                        // goto looping path
                        const anim_end = ru32(anim_entry + 0x08);
                        const anim_start = ru32(anim_entry + 0x04);
                        if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                            const delta = effective_time -% ru32(brt + 0xA8);
                            const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xB0);
                            const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8)) % (anim_end -% anim_start);
                            wu32(brt + 0x98, anim_start +% frame);
                        } else {
                            wu32(brt + 0x98, anim_start);
                        }
                    } else {
                        // sec_end has passed — compute clamped position
                        // Assembly at 0x71458E-0x7145E3:
                        // delta = (sec_end - sec_start), scaled by [ESI+0xB0]
                        const dur = sec_end_val -% sec_start_val;
                        const ftol_result = callFtol(@as(i32, @bitCast(dur)), brt + 0xB0);
                        const offset = ftol_result + @as(i32, @bitCast(ru32(brt + 0xB8)));

                        if (offset < 0) {
                            // Clamp to anim_start
                            wu32(brt + 0x98, ru32(anim_entry + 0x04));
                        } else {
                            const anim_end_i = @as(i32, @bitCast(ru32(anim_entry + 0x08)));
                            const anim_start_i = @as(i32, @bitCast(ru32(anim_entry + 0x04)));
                            if (offset <= anim_end_i - anim_start_i) {
                                wu32(brt + 0x98, @as(u32, @bitCast(offset + anim_start_i)));
                            } else {
                                // Clamp to anim_end
                                wu32(brt + 0x98, ru32(anim_entry + 0x08));
                            }
                        }
                    }
                }

                // Store results: assembly at 0x714633-0x71464E
                wu32(brt + 0x9C, ru32(brt + 0xA4)); // prim_track = anim_slot
                // prim_time already set above
                wu32(brt + 0xA0, bone_idx); // prim_anim = bone_idx
            }

            // --- Secondary animation time (crossfade target) ---
            // Similar pattern for the secondary/blend animation slot
            const sec_slot_val = ri32(brt + BR.sec_slot);
            if (sec_slot_val == -1) {
                if (parent_idx_raw >= 0 and @as(u32, @intCast(parent_idx_raw)) < bone_count) {
                    const parent_rt = bone_rt_base + @as(u32, @intCast(parent_idx_raw)) * 0x118;
                    wu32(brt + BR.sec_time, ru32(parent_rt + BR.sec_time));
                    wu32(brt + BR.sec_track, ru32(parent_rt + BR.sec_track));
                } else if (bone_idx != 0) {
                    wu32(brt + BR.sec_time, ru32(bone_rt_base + BR.sec_time));
                    wu32(brt + BR.sec_track, ru32(bone_rt_base + BR.sec_track));
                } else {
                    wu32(brt + BR.sec_time, ru32(brt + BR.prim_time));
                    wu32(brt + BR.sec_track, ru32(brt + BR.prim_track));
                }
            } else {
                // Secondary animation slot time computation.
                // Assembly at 0x7146C1-0x7147C3, mirrors primary slot logic.
                if (ru32(this + 0x4C) != 0) { // search_data_base_ptr != 0
                    wu32(brt + 0xD4, ru32(brt + 0xD4) +% time_delta_val); // [ESI+0xD4]
                    wu32(brt + 0xD8, ru32(brt + 0xD8) +% time_delta_val); // [ESI+0xD8]
                }

                const sec_anim_lookup = ru32(model_hdr + 0x20);
                const sec_anim_entry = sec_anim_lookup + @as(u32, @bitCast(sec_slot_val)) * 0x44;
                const sec_cur_time = ru32(ru32(this + 0x2C) + 0xC);

                if ((ru8(sec_anim_entry + 0x10) & 1) == 0) {
                    // Looping
                    const anim_end = ru32(sec_anim_entry + 0x08);
                    const anim_start = ru32(sec_anim_entry + 0x04);
                    if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                        const delta = sec_cur_time -% ru32(brt + 0xD4);
                        const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xDC);
                        const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4)) % (anim_end -% anim_start);
                        wu32(brt + 0xC4, anim_start +% frame); // sec_time
                    } else {
                        wu32(brt + 0xC4, anim_start);
                    }
                } else {
                    // Clamped
                    const sec_end_val = ru32(brt + 0xD8);
                    const sec_start_val = ru32(brt + 0xD4);

                    if (sec_end_val != sec_cur_time and @as(i32, @bitCast(sec_end_val -% sec_cur_time)) > 0) {
                        // Assembly 0x71474B: clamp sec_cur_time to sec_start if sec_start > sec_cur_time
                        const effective_time = if (@as(i32, @bitCast(sec_start_val -% sec_cur_time)) > 0) sec_start_val else sec_cur_time;
                        const anim_end = ru32(sec_anim_entry + 0x08);
                        const anim_start = ru32(sec_anim_entry + 0x04);
                        if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                            const delta = effective_time -% ru32(brt + 0xD4);
                            const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xDC);
                            const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4)) % (anim_end -% anim_start);
                            wu32(brt + 0xC4, anim_start +% frame);
                        } else {
                            wu32(brt + 0xC4, anim_start);
                        }
                    } else {
                        const dur = sec_end_val -% sec_start_val;
                        const ftol_result = callFtol(@as(i32, @bitCast(dur)), brt + 0xDC);
                        const offset = ftol_result + @as(i32, @bitCast(ru32(brt + 0xE4)));

                        if (offset < 0) {
                            wu32(brt + 0xC4, ru32(sec_anim_entry + 0x04));
                        } else {
                            const anim_end_i = @as(i32, @bitCast(ru32(sec_anim_entry + 0x08)));
                            const anim_start_i = @as(i32, @bitCast(ru32(sec_anim_entry + 0x04)));
                            if (offset <= anim_end_i - anim_start_i) {
                                wu32(brt + 0xC4, @as(u32, @bitCast(offset + anim_start_i)));
                            } else {
                                wu32(brt + 0xC4, ru32(sec_anim_entry + 0x08));
                            }
                        }
                    }
                }

                // Store results: assembly at 0x714799-0x7147C3
                wu32(brt + 0xC8, ru32(brt + 0xD0)); // sec_track = sec_slot
                // sec_time already set above

                // Check expiry: if (timestamp - crossfade_end >= 0) expire slot
                if (@as(i32, @bitCast(ru32(ru32(this + 0x2C) + 0xC) -% ru32(brt + 0x100))) >= 0) {
                    wu32(brt + 0xD0, 0xFFFFFFFF); // expire secondary slot
                }
            }

            // --- Blend weight (crossfade Hermite interpolation) ---
            if (ri32(brt + BR.anim_slot) == -1 and ri32(brt + BR.sec_slot) == -1) {
                // Inherit blend weight from parent
                if (parent_idx_raw >= 0 and @as(u32, @intCast(parent_idx_raw)) < bone_count) {
                    wu32(brt + BR.blend_weight, ru32(bone_rt_base + @as(u32, @intCast(parent_idx_raw)) * 0x118 + BR.blend_weight));
                } else if (bone_idx == 0) {
                    wu32(brt + BR.blend_weight, 0); // root bone, no blend
                } else {
                    wu32(brt + BR.blend_weight, ru32(bone_rt_base + BR.blend_weight));
                }
            } else {
                const cf_remaining = ri32(brt + BR.crossfade_end) - ri32(anim_ctx + 0x0C);
                if (cf_remaining < 1 or (ru32(brt + BR.prim_time) == ru32(brt + BR.sec_time) and
                    ru32(brt + BR.prim_track) == ru32(brt + BR.sec_track)))
                {
                    wu32(brt + BR.blend_weight, 0);
                } else {
                    const t_raw = @as(f32, @floatFromInt(cf_remaining)) * ufloat(ru32(brt + BR.crossfade_inv));
                    const t_clamped = if (t_raw < 0.0) @as(f32, 0.0) else if (t_raw > 1.0) @as(f32, 1.0) else t_raw;
                    // Hermite: (3 - 2t) * t^2 * weight
                    const h = (3.0 - 2.0 * t_clamped) * t_clamped * t_clamped * ufloat(ru32(brt + BR.crossfade_weight));
                    wu32(brt + BR.blend_weight, fbits(h));
                }
            }

            // --- Parent bone transform inheritance ---
            const combined_flags: u32 = ru32(brt + BR.flags2) | flags;
            var src_mat: u32 = undefined;

            if (ru16(bdef + BD.parent_bone) == 0xFFFF) {
                src_mat = this + 0xFC;
            } else {
                const parent_out = bone_out_base + @as(u32, @intCast(parent_idx_raw)) * 0x40;
                src_mat = parent_out;

                // Billboard pre-processing (flags & 7)
                if ((combined_flags & 7) != 0) {
                    // Copy parent matrix to local_mat and work from there
                    for (0..16) |i| {
                        local_mat[i] = rf32(parent_out + @as(u32, @intCast(i)) * 4);
                    }

                    // Apply pivot translation
                    const pivot_x = rf32(bdef + BD.pivot_x);
                    const pivot_y = rf32(bdef + BD.pivot_y);
                    const pivot_z = rf32(bdef + BD.pivot_z);

                    // Compute translated position
                    const tx = local_mat[0] * pivot_x + local_mat[4] * pivot_y + local_mat[8] * pivot_z + local_mat[12];
                    const ty = local_mat[1] * pivot_x + local_mat[5] * pivot_y + local_mat[9] * pivot_z + local_mat[13];
                    const tz = local_mat[2] * pivot_x + local_mat[6] * pivot_y + local_mat[10] * pivot_z + local_mat[14];

                    const bb_type = combined_flags & 6;
                    if (bb_type == 2) {
                        // Cylindrical billboard — normalize each column
                        const n0 = normalizeVec3(local_mat[0], local_mat[1], local_mat[2]);
                        local_mat[0] = n0[0];
                        local_mat[1] = n0[1];
                        local_mat[2] = n0[2];
                        const n1 = normalizeVec3(local_mat[4], local_mat[5], local_mat[6]);
                        local_mat[4] = n1[0];
                        local_mat[5] = n1[1];
                        local_mat[6] = n1[2];
                        const n2 = normalizeVec3(local_mat[8], local_mat[9], local_mat[10]);
                        local_mat[8] = n2[0];
                        local_mat[9] = n2[1];
                        local_mat[10] = n2[2];
                    } else if (bb_type == 4) {
                        // Spherical billboard — inherit camera rotation with scale preservation
                        // All sqmag computations MUST call game's vec3SqMag (0x4549F0)
                        const cam0 = [3]f32{ rf32(this + SO.bb_row0), rf32(this + SO.bb_row0 + 4), rf32(this + SO.bb_row0 + 8) };
                        const cam_len_sq0 = callVec3SqMag(this + SO.bb_row0);
                        var s0: f32 = 1.0;
                        if (cam_len_sq0 > rf32(0x0080c5c8)) {
                            var tmp0 = [3]f32{ local_mat[0], local_mat[1], local_mat[2] };
                            const mat_len_sq0 = callVec3SqMag(@intFromPtr(&tmp0));
                            s0 = @sqrt(mat_len_sq0 / cam_len_sq0);
                        }
                        local_mat[0] = s0 * cam0[0];
                        local_mat[1] = s0 * cam0[1];
                        local_mat[2] = s0 * cam0[2];

                        const wt0 = rf32(this + SO.world_xform + 0 * 4);
                        const wt1 = rf32(this + SO.world_xform + 1 * 4);
                        const wt2 = rf32(this + SO.world_xform + 2 * 4);
                        const wt_len_sq = callVec3SqMag(this + SO.world_xform);
                        var s1: f32 = 1.0;
                        if (wt_len_sq > rf32(0x0080c5c8)) {
                            var tmp1 = [3]f32{ local_mat[4], local_mat[5], local_mat[6] };
                            const mat_len_sq1 = callVec3SqMag(@intFromPtr(&tmp1));
                            s1 = @sqrt(mat_len_sq1 / wt_len_sq);
                        }
                        local_mat[4] = s1 * wt0;
                        local_mat[5] = s1 * wt1;
                        local_mat[6] = s1 * wt2;

                        const wt4 = rf32(this + SO.world_xform + 4 * 4);
                        const wt5 = rf32(this + SO.world_xform + 5 * 4);
                        const wt6 = rf32(this + SO.world_xform + 6 * 4);
                        const wt_len_sq2 = callVec3SqMag(this + SO.world_xform + 16);
                        var s2: f32 = 1.0;
                        if (wt_len_sq2 > rf32(0x0080c5c8)) {
                            var tmp2 = [3]f32{ local_mat[8], local_mat[9], local_mat[10] };
                            const mat_len_sq2 = callVec3SqMag(@intFromPtr(&tmp2));
                            s2 = @sqrt(mat_len_sq2 / wt_len_sq2);
                        }
                        local_mat[8] = s2 * wt4;
                        local_mat[9] = s2 * wt5;
                        local_mat[10] = s2 * wt6;
                    } else if (bb_type == 6) {
                        // Full billboard — copy camera rotation directly
                        local_mat[0] = rf32(this + SO.bb_row0);
                        local_mat[1] = rf32(this + SO.bb_row0 + 4);
                        local_mat[2] = rf32(this + SO.bb_row0 + 8);
                        local_mat[4] = rf32(this + SO.world_xform + 0 * 4);
                        local_mat[5] = rf32(this + SO.world_xform + 1 * 4);
                        local_mat[6] = rf32(this + SO.world_xform + 2 * 4);
                        local_mat[8] = rf32(this + SO.world_xform + 4 * 4);
                        local_mat[9] = rf32(this + SO.world_xform + 5 * 4);
                        local_mat[10] = rf32(this + SO.world_xform + 6 * 4);
                    }

                    // Recompute translation: pos - rot * pivot
                    if ((combined_flags & 1) == 0) {
                        local_mat[12] = tx - (local_mat[0] * pivot_x + local_mat[4] * pivot_y + local_mat[8] * pivot_z);
                        local_mat[13] = ty - (local_mat[1] * pivot_x + local_mat[5] * pivot_y + local_mat[9] * pivot_z);
                        local_mat[14] = tz - (local_mat[2] * pivot_x + local_mat[6] * pivot_y + local_mat[10] * pivot_z);
                    } else {
                        local_mat[12] = rf32(this + SO.world_xform + 8 * 4);
                        local_mat[13] = rf32(this + SO.world_xform + 9 * 4);
                        local_mat[14] = rf32(this + SO.world_xform + 10 * 4);
                    }

                    src_mat = local_mat_addr;
                }
            }

            // --- Rotation interpolation ---
            if ((combined_flags & 0x280) == 0) {
                // No rotation animation — just copy parent
                const dst = bone_out_base + bone_idx * 0x40;
                copyMat4(dst, src_mat);
            } else {
                // Reset to identity for composition
                local_mat2 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                const lm2_addr = @intFromPtr(&local_mat2);

                const rot_anim = bdef + BD.rot_anim;
                const rot_kf_count = ru32(bdef + BD.rot_nts);

                // Step 1: Rotation — build rotation matrix from quaternion FIRST.
                // The original at 0x74B6BB overwrites the bone-local matrix with the
                // quaternion rotation matrix (it does NOT multiply — just writes directly).
                // This runs BEFORE scale and translation so the translation offset
                // (pivot - matrix * pivot) uses the correctly rotated matrix.
                if (rot_kf_count != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < rot_kf_count) {
                        interpAnimKF(this, brt, rot_anim, brt + BR.rot_idx0);
                    }
                    buildRotationMatrix(lm2_addr, rf32(brt + BR.rot_x), rf32(brt + BR.rot_y), rf32(brt + BR.rot_z), rf32(brt + BR.rot_w));
                }

                // Step 2: Scale interpolation — applied after rotation
                const scale_anim = bdef + BD.scale_anim;
                const scale_kf_count = ru32(bdef + BD.scale_nts);
                if (scale_kf_count != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < scale_kf_count) {
                        interpVec3Track(this, brt, scale_anim, brt + BR.scale_idx0, ufloat(ru32(brt + BR.blend_weight)));
                    }
                    scaleMatrix3x3(lm2_addr, rf32(brt + BR.scale_x), rf32(brt + BR.scale_y), rf32(brt + BR.scale_z));
                }

                // Conditional multiply: if flag bit 0x80 set AND bone_rt[0xF0] != 0,
                // multiply bone_local by the matrix pointed to by bone_rt[0xF0].
                // Assembly at 0x714F7F-0x714F9C:
                //   TEST CL, CL / JNS skip
                //   MOV EAX, [ESI+0xF0] / TEST EAX, EAX / JZ skip
                //   PUSH EAX (right), PUSH &bone_local (left), PUSH &bone_local (output)
                //   CALL 0x74A7C0 (multiplyMatrix4x4: output = left * right)
                // This is bone_local *= *(bone_rt+0xF0)
                if ((@as(i8, @bitCast(@as(u8, @truncate(combined_flags)))) < 0) and ru32(brt + BR.bone_flag_cache) != 0) {
                    const extra_mat = ru32(brt + BR.bone_flag_cache);
                    matMul4x4(lm2_addr, lm2_addr, extra_mat);
                }

                // Step 3: Translation interpolation
                var tx_val = rf32(bdef + BD.pivot_x);
                var ty_val = rf32(bdef + BD.pivot_y);
                var tz_val = rf32(bdef + BD.pivot_z);

                const trans_anim = bdef + BD.trans_anim;
                const trans_kf_count = ru32(bdef + BD.trans_nts);
                if (trans_kf_count != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < trans_kf_count) {
                        interpVec3Track(this, brt, trans_anim, brt + BR.trans_idx0, ufloat(ru32(brt + BR.blend_weight)));
                    }
                    tx_val += ufloat(ru32(brt + BR.trans_x));
                    ty_val += ufloat(ru32(brt + BR.trans_y));
                    tz_val += ufloat(ru32(brt + BR.trans_z));
                }

                // Step 4: Compute translation offset using the ROTATED+SCALED matrix.
                // translation = (pivot + interp_trans) - bone_local_matrix * pivot
                const piv_x = rf32(bdef + BD.pivot_x);
                const piv_y = rf32(bdef + BD.pivot_y);
                const piv_z = rf32(bdef + BD.pivot_z);
                local_mat2[12] = tx_val - (local_mat2[0] * piv_x + local_mat2[4] * piv_y + local_mat2[8] * piv_z);
                local_mat2[13] = ty_val - (local_mat2[1] * piv_x + local_mat2[5] * piv_y + local_mat2[9] * piv_z);
                local_mat2[14] = tz_val - (local_mat2[2] * piv_x + local_mat2[6] * piv_y + local_mat2[10] * piv_z);

                // Write final composed matrix to output: dst = bone_local * parent
                // Assembly: CALL 0x74A7C0 (JMP table → SSE matmul) at 0x7151BA
                matMul4x4(bone_out_base + bone_idx * 0x40, lm2_addr, src_mat);
            }

            // --- Billboard post-processing (flags & 0x78) ---
            // Assembly at 0x7151F9-0x71594E. Runs for BOTH animated and non-animated paths.
            // Modifies the already-written bone output matrix in-place.
            if ((combined_flags & 0x78) != 0) {
                // pMVar19 = bone_idx * 0x40 (byte offset for output)
                // pfVar12 = bone_out_base + pMVar19 (output matrix ptr)
                const out_off = bone_idx * 0x40;
                const om = bone_out_base + out_off; // output matrix

                // Compute scale lengths — MUST call game's vec3SqMag (0x4549F0), not inline
                // Assembly: LEA ECX,[stack_vec3]; CALL 0x4549F0; FSQRT
                const scale_len0 = @sqrt(callVec3SqMag(om));
                const scale_len1 = @sqrt(callVec3SqMag(om + 0x10));
                const scale_len2 = @sqrt(callVec3SqMag(om + 0x20));

                // Compute translated pivot position through the output matrix
                // local_a8 = pivot * matrix + translation
                const bpx = rf32(bdef + BD.pivot_x);
                const bpy = rf32(bdef + BD.pivot_y);
                const bpz = rf32(bdef + BD.pivot_z);
                const pos_x = bpx * rf32(om) + bpy * rf32(om + 0x10) + bpz * rf32(om + 0x20) + rf32(om + 0x30);
                const pos_y = bpx * rf32(om + 0x04) + bpy * rf32(om + 0x14) + bpz * rf32(om + 0x24) + rf32(om + 0x34);
                const pos_z = bpx * rf32(om + 0x08) + bpy * rf32(om + 0x18) + bpz * rf32(om + 0x28) + rf32(om + 0x38);

                // Switch on billboard post-processing type
                const bb_post = combined_flags & 0x78;
                switch (bb_post) {
                    0x08 => {
                        // Type 8: decompilation lines 657-718
                        // If no pre-billboard (local_1c == 0 i.e. flags & 0x280 was 0):
                        //   set fixed rotation columns
                        // Else: use rotation matrix rows with negated first component, normalize
                        const had_anim = (combined_flags & 0x280) != 0;
                        if (!had_anim) {
                            // Fixed columns: row0={0,0,-1}, row1={1,0,0}, row2={0,1,0}
                            wf32(om, 0);
                            wf32(om + 0x04, 0);
                            wf32(om + 0x08, -1);
                            wf32(om + 0x10, 1);
                            wf32(om + 0x14, 0);
                            wf32(om + 0x18, 0);
                            wf32(om + 0x20, 0);
                            wf32(om + 0x24, 1);
                            wf32(om + 0x28, 0);
                        } else {
                            // Row 0 = {local_e4, local_e0, -local_e8}, normalize
                            const r0x = local_mat2[1]; // local_e4
                            const r0y = local_mat2[2]; // local_e0
                            const r0z = -local_mat2[0]; // -local_e8
                            wf32(om, r0x);
                            wf32(om + 0x04, r0y);
                            wf32(om + 0x08, r0z);
                            const n0 = normalizeVec3InPlace(om);
                            _ = n0;
                            // Row 1 = {local_d4, local_d0, -local_d8}, normalize
                            const r1x = local_mat2[5]; // local_d4
                            const r1y = local_mat2[6]; // local_d0
                            const r1z = -local_mat2[4]; // -local_d8
                            wf32(om + 0x10, r1x);
                            wf32(om + 0x14, r1y);
                            wf32(om + 0x18, r1z);
                            const n1 = normalizeVec3InPlace(om + 0x10);
                            _ = n1;
                            // Row 2 = {local_c4, local_c0, -local_c8}, normalize
                            const r2x = local_mat2[9]; // local_c4
                            const r2y = local_mat2[10]; // local_c0
                            const r2z = -local_mat2[8]; // -local_c8
                            wf32(om + 0x20, r2x);
                            wf32(om + 0x24, r2y);
                            wf32(om + 0x28, r2z);
                            const n2 = normalizeVec3InPlace(om + 0x20);
                            _ = n2;
                        }
                    },
                    0x10 => {
                        // Type 16: normalize row0, set row1={row0.y, -row0.x, 0}, normalize,
                        // row2 = cross(row0, row1)
                        const n0 = normalizeVec3InPlace(om);
                        _ = n0;
                        const r0x = rf32(om);
                        const r0y = rf32(om + 0x04);
                        wf32(om + 0x10, r0y);
                        wf32(om + 0x14, -r0x);
                        wf32(om + 0x18, 0);
                        const n1 = normalizeVec3InPlace(om + 0x10);
                        _ = n1;
                        // row2 = -cross(row0, row1) — assembly uses negated cross product
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x20 => {
                        // Type 32: normalize row1, set row0={-row1.y, row1.x, 0}, normalize,
                        // row2 = -cross(row0, row1)
                        const n1 = normalizeVec3InPlace(om + 0x10);
                        _ = n1;
                        wf32(om, -rf32(om + 0x14));
                        wf32(om + 0x04, rf32(om + 0x10));
                        wf32(om + 0x08, 0);
                        const n0 = normalizeVec3InPlace(om);
                        _ = n0;
                        // row2 = -cross(row0, row1) — assembly uses negated cross product
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x40 => {
                        // Type 64: normalize row2, set row1={row2.y, -row2.x, 0}, normalize,
                        // row0 = cross(row1, row2)
                        normalizeVec3InPlace(om + 0x20);
                        wf32(om + 0x10, rf32(om + 0x24));
                        wf32(om + 0x14, -rf32(om + 0x20));
                        wf32(om + 0x18, 0);
                        normalizeVec3InPlace(om + 0x10);
                        // row0 = cross(row2.y*row1.z - row2.z*row1.y, ...)
                        wf32(om, rf32(om + 0x24) * rf32(om + 0x18) - rf32(om + 0x28) * rf32(om + 0x14));
                        wf32(om + 0x04, rf32(om + 0x28) * rf32(om + 0x10) - rf32(om + 0x20) * rf32(om + 0x18));
                        wf32(om + 0x08, rf32(om + 0x20) * rf32(om + 0x14) - rf32(om + 0x24) * rf32(om + 0x10));
                    },
                    else => {},
                }

                // Apply scale lengths back and recompute translation
                // Assembly at 0x715868-0x71594B
                wf32(om + 0x0C, 0);
                wf32(om + 0x1C, 0);
                wf32(om + 0x2C, 0);
                // Scale each row by its original length
                const r0x_s = rf32(om);
                wf32(om, scale_len0 * r0x_s);
                const r0y_s = rf32(om + 0x04);
                wf32(om + 0x04, scale_len0 * r0y_s);
                const r0z_s = rf32(om + 0x08);
                wf32(om + 0x08, scale_len0 * r0z_s);
                const r1x_s = rf32(om + 0x10);
                wf32(om + 0x10, scale_len1 * r1x_s);
                const r1y_s = rf32(om + 0x14);
                wf32(om + 0x14, scale_len1 * r1y_s);
                const r1z_s = rf32(om + 0x18);
                wf32(om + 0x18, scale_len1 * r1z_s);
                const r2x_s = rf32(om + 0x20);
                wf32(om + 0x20, scale_len2 * r2x_s);
                const r2y_s = rf32(om + 0x24);
                wf32(om + 0x24, scale_len2 * r2y_s);
                const r2z_s = rf32(om + 0x28);
                wf32(om + 0x28, scale_len2 * r2z_s);

                // Recompute translation: pos - scaled_matrix * pivot
                wf32(om + 0x30, pos_x - (scale_len0 * r0x_s * bpx + scale_len1 * r1x_s * bpy + scale_len2 * r2x_s * bpz));
                wf32(om + 0x34, pos_y - (scale_len0 * r0y_s * bpx + scale_len1 * r1y_s * bpy + scale_len2 * r2y_s * bpz));
                wf32(om + 0x38, pos_z - (scale_len0 * r0z_s * bpx + scale_len1 * r1z_s * bpy + scale_len2 * r2z_s * bpz));
                wf32(om + 0x3C, 1.0);
            }
        }
    }

    // =========================================================================
    // Sections 8-11: Post-bone-loop animations
    // These sections handle texture animation, color animation, bone keyframe
    // post-processing, and particle emitters. They follow the same interpolation
    // pattern as the bone loop but operate on different model data arrays.
    //
    // For the initial implementation, we delegate these to the patterns established
    // above. Each section iterates over its respective model array and calls
    // findInterpIdx + lerp + crossfade blend.
    // =========================================================================

    // BISECT: stop after section 7 (bone loop)

    // Section 8: Texture animation loop
    texAnimLoop(this, model_hdr);

    // Section 9: Color animation loop
    colorAnimLoop(this, model_hdr);

    // Section 9b: Word animation loop (assembly 0x715E46-0x715F25)
    // model_hdr+0x6C = count, model_hdr+0x70 = data, output at this+0xAC (SO.scale1)
    // Data stride 0x1C, output stride 0x20. Word copy with crossfade.
    wordAnimLoop(this, model_hdr);

    // Section 10: Bone keyframe processing
    boneKeyframeLoop(this, model_hdr);

    // Section 11: Particle emitter loops
    particleLoops(this, model_hdr);

    // Section 12: Attachment recursion
    attachmentRecursion(this, model_hdr, bone_out_base);

    // =========================================================================
    // Section 13: Sync update
    // =========================================================================
    wu32(this + SO.sync_value, ru32(anim_ctx + 0x10));
}

// =============================================================================
// Post-bone-loop sections (extracted for readability)
// =============================================================================

fn texAnimLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x54);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x58);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.tex_anim_out);

    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({
        i += 1;
        data_off += 0x38;
        out_off += 0x14 * 4;
    }) {
        const anim_data = data_base + data_off;
        const output = out_base + out_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(data_base + data_off + 0x0C)) {
            interpVec3Track(this, bone_rt_base, anim_data, output, ufloat(ru32(bone_rt_base + BR.blend_weight)));
        }
        // Alpha/opacity track (assembly 0x715AF1-0x715C5E)
        // Gate: anim_data+0x28 (alpha kf count) > anim_frame_ctr
        if (ru32(this + SO.anim_frame_ctr) < ru32(anim_data + 0x28)) {
            const alpha_anim = anim_data + 0x1C;
            // ESI = output + 0x30 in original (alpha output area)
            const alpha_out = output + 0x30;
            findInterpIdx(this, ru32(bone_rt_base + BR.prim_time), ru32(bone_rt_base + BR.prim_track), alpha_anim, alpha_out);
            const mode = ri16(alpha_anim);
            if (mode == 0) {
                // Mode 0: direct short→float copy. Assembly JMPs past crossfade.
                const kf_data = ru32(alpha_anim + 0x18);
                const idx = ru32(alpha_out);
                const sv = @as(f32, @floatFromInt(@as(i32, @as(*align(1) const i16, @ptrFromInt(kf_data + idx * 2)).*)));
                wf32(alpha_out + 0x0C, sv * getShortToFloat());
            } else {
                // Mode != 0: lerp + crossfade
                const primary = shortInterpToFloat(alpha_anim, alpha_out);
                wf32(alpha_out + 0x0C, primary);

                // Crossfade (assembly 0x715BAF-0x715C5E)
                // Only runs for mode != 0 — mode 0 JMPs past this
                const bw = rf32(bone_rt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(alpha_anim + 0x02) == -1) {
                    findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), alpha_anim, alpha_out + 0x10);
                    const secondary = shortInterpToFloat(alpha_anim, alpha_out + 0x10);
                    wf32(alpha_out + 0x1C, secondary);
                    wf32(alpha_out + 0x0C, primary + (secondary - primary) * bw);
                }
            }
        }
    }
}

/// Short-value interpolation: reads indices from output, looks up short values, interpolates.
/// Shared by texAnimLoop alpha, colorAnimLoop, and word animation crossfade.
fn shortInterpToFloat(anim_data: u32, output: u32) f32 {
    const mode = ri16(anim_data);
    const table = anim_data + AD.nvalues;
    if (mode == 0) {
        return @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output))))) * getShortToFloat();
    } else {
        const t = ufloat(ru32(output + 8));
        const v1 = @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output + 4)))));
        const v0 = @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output)))));
        return (v1 * getShortToFloat() - v0 * getShortToFloat()) * t + v0 * getShortToFloat();
    }
}

fn colorAnimLoop(this: u32, model_hdr: u32) void {
    // Assembly: model_hdr+0x64 is both entry gate AND loop count
    const count = ru32(model_hdr + 0x64);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x68);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.color_anim_out);

    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({
        i += 1;
        data_off += 0x1C;
        out_off += 0x20;
    }) {
        const anim_data = data_base + data_off;
        const output = out_base + out_off;
        // Gate: anim_data+0x0C (kf count) > anim_frame_ctr
        if (ru32(this + SO.anim_frame_ctr) < ru32(anim_data + 0x0C)) {
            findInterpIdx(this, ru32(bone_rt_base + BR.prim_time), ru32(bone_rt_base + BR.prim_track), anim_data, output);
            const mode = ri16(anim_data);
            if (mode == 0) {
                // Mode 0: direct short→float. Assembly JMPs past crossfade (0x715D05).
                const kf_data = ru32(anim_data + 0x18);
                const idx = ru32(output);
                const sv = @as(f32, @floatFromInt(@as(i32, @as(*align(1) const i16, @ptrFromInt(kf_data + idx * 2)).*)));
                wf32(output + 0x0C, sv * getShortToFloat());
            } else {
                // Mode != 0: lerp + crossfade
                const primary = shortInterpToFloat(anim_data, output);
                wf32(output + 0x0C, primary);

                // Crossfade (assembly 0x715D6B-0x715E1B)
                const bw = rf32(bone_rt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(anim_data + 0x02) == -1) {
                    findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), anim_data, output + 0x10);
                    const secondary = shortInterpToFloat(anim_data, output + 0x10);
                    wf32(output + 0x1C, secondary);
                    wf32(output + 0x0C, primary + (secondary - primary) * bw);
                }
            }
        }
    }
}

fn wordAnimLoop(this: u32, model_hdr: u32) void {
    // Assembly 0x715E46-0x715F25: word/byte animation section
    // model_hdr+0x6C = count, model_hdr+0x70 = data base
    // Output at this+0xAC (SO.scale1), data stride 0x1C, output stride 0x20
    const count = ru32(model_hdr + 0x6C);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x70);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.scale1);

    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({
        i += 1;
        data_off += 0x1C;
        out_off += 0x20;
    }) {
        const anim_data = data_base + data_off;
        const output = out_base + out_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(anim_data + 0x0C)) {
            findInterpIdx(this, ru32(bone_rt_base + BR.prim_time), ru32(bone_rt_base + BR.prim_track), anim_data, output);
            // Word copy: read word from keyframe data via direct indexing
            // Assembly (0x715EA3): MOV AX,[kf_data+idx*2]; MOV [output+0x0C],AX
            const kf_data = ru32(anim_data + 0x18);
            const idx = ru32(output);
            wu16(output + 0x0C, ru16(kf_data + idx * 2));

            // Crossfade (assembly 0x715EB4-0x715EFA)
            // Original: JZ skip if mode==0, then check blend_weight > 0, then time_index == -1
            if (ri16(anim_data) == 0) {
                // mode 0: no crossfade, skip
            } else {
                const bw = rf32(bone_rt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(anim_data + 0x02) == -1) {
                    findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), anim_data, output + 0x10);
                    const sec_idx = ru32(output + 0x10);
                    wu16(output + 0x1C, ru16(kf_data + sec_idx * 2));
                }
            }
        }
    }
}

fn boneKeyframeLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x74);
    if (count == 0) return;

    // One-time global init (assembly 0x715F45-0x715F81)
    // Sets {0.5, 0.5, 0.0} constants at 0xCF043C and calls 0x409AEF
    if ((ru8(0xCF04C4) & 1) == 0) {
        wu8(0xCF04C4, ru8(0xCF04C4) | 1);
        wu32(0xCF043C, 0x3F000000); // 0.5f
        wu32(0xCF0440, 0x3F000000); // 0.5f
        wu32(0xCF0444, 0x00000000); // 0.0f
        // CALL 0x409AEF with arg 0x7187E0 (__cdecl, 1 stack param)
        const initFn: *const fn (u32) callconv(.c) void = @ptrFromInt(0x409AEF);
        initFn(0x7187E0);
    }

    const data_base = ru32(model_hdr + 0x78);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const scale2_base = ru32(this + SO.scale2);
    const scale3_base = ru32(this + SO.scale3);

    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    var mat_off: u32 = 0;
    while (i < count) : ({
        i += 1;
        data_off += 0x54; // assembly at 0x7163A2: ADD EDI, 0x54
        out_off += 0x98; // assembly at 0x7163A5: ADD ESI, 0x98
        mat_off += 0x40; // assembly at 0x715395: ADD EDX, 0x40
    }) {
        const kf_data = data_base + data_off;
        const output = @as(u32, @intCast(@as(i32, @bitCast(scale2_base)) + @as(i32, @bitCast(out_off))));
        const mat_out = @as(u32, @intCast(@as(i32, @bitCast(scale3_base)) + @as(i32, @bitCast(mat_off))));

        // Init identity matrix for this keyframe entry
        setIdentity(mat_out);

        // Rotation: AnimData at kf_entry+0x1C, gate at kf_entry+0x28
        // Assembly at 0x715FDB: CMP [ECX+0x28], 0; AnimData at EDX+0x1C
        if (ru32(kf_data + 0x28) != 0) {
            // Assembly: CALL 0x713EA0 — interpAnimKF
            const interpKF: *const fn (u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x713EA0);
            interpKF(this, bone_rt_base, kf_data + 0x1C, output + 0x30);
            // Assembly: PUSH 0xCF043C, MOV ECX=mat, CALL 0x7BDC40 — applyTranslation
            const applyTrans: *const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x7BDC40);
            applyTrans(mat_out, 0, 0xCF043C);
            // Assembly: PUSH quat_ptr, MOV ECX=mat, CALL 0x7BDDB0 — rotateByQuaternion
            const rotateQuat: *const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x7BDDB0);
            rotateQuat(mat_out, 0, output + 0x3C);
            // Assembly: negate 0xCF043C values to stack, PUSH, CALL 0x7BDC40
            var neg_trans: [3]f32 = .{ -rf32(0xCF043C), -rf32(0xCF0440), -rf32(0xCF0444) };
            applyTrans(mat_out, 0, @intFromPtr(&neg_trans));
        }

        // Scale: AnimData at kf_entry+0x38, gate at kf_entry+0x44
        // Assembly at 0x716052: CMP [ECX+0x44], 0; AnimData at EDX+0x38
        if (ru32(kf_data + 0x44) != 0) {
            interpVec3Track(this, bone_rt_base, kf_data + 0x38, output + 0x68, ufloat(ru32(bone_rt_base + BR.blend_weight)));
            // Assembly: PUSH 0xCF043C, MOV ECX=mat, CALL 0x7BDC40
            const applyTrans2: *const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x7BDC40);
            applyTrans2(mat_out, 0, 0xCF043C);
            // Assembly: PUSH scale_vec, MOV ECX=mat, CALL 0x7BDCA0
            const scaleMat2: *const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x7BDCA0);
            scaleMat2(mat_out, 0, output + 0x74);
            // Assembly: negate, CALL 0x7BDC40
            var neg_trans2: [3]f32 = .{ -rf32(0xCF043C), -rf32(0xCF0440), -rf32(0xCF0444) };
            applyTrans2(mat_out, 0, @intFromPtr(&neg_trans2));
        }

        // Translation: AnimData at kf_entry+0x00, gate at kf_entry+0x0C
        // Assembly at 0x716216: CMP [ECX+0x0C], 0; AnimData at kf_entry+0x00
        if (ru32(kf_data + 0x0C) != 0) {
            interpVec3Track(this, bone_rt_base, kf_data, output, ufloat(ru32(bone_rt_base + BR.blend_weight)));
            // Assembly: PUSH trans_vec, MOV ECX=mat, CALL 0x7BDC40
            const applyTrans3: *const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x7BDC40);
            applyTrans3(mat_out, 0, output + 0x0C);
        }
    }
}

fn particleLoops(this: u32, model_hdr: u32) void {
    // Particle emitters are the largest section (~1000 lines of decompiled C).
    // They follow the same interpolation patterns but with many sub-tracks per emitter.
    // For the initial implementation, we handle the key tracks (position, speed, scale).
    // The remaining tracks (color, alpha, emission rate, etc.) use identical patterns.

    // Ribbon emitters (model_hdr + 0x11C)
    ribbonEmitterLoop(this, model_hdr);

    // Particle emitters (model_hdr + 0x124)
    particleEmitterLoop(this, model_hdr);

    // Additional particle sections (model_hdr + 0x134, 0x13C)
    additionalParticleLoops(this, model_hdr);
}

fn ribbonEmitterLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x11C);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x120);
    const out_base = ru32(this + SO.field_200);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const frame_ctr = ru32(this + SO.anim_frame_ctr);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = data_base + i * 0xD4; // asm 0x716ABC: ADD EDI, 0xD4
        const output = out_base + i * 0x170; // asm 0x716AC2: ADD ESI, 0x170
        const bone_idx = @as(u32, ru16(entry + 2));
        const bone_rt = bone_rt_base + bone_idx * 0x118;

        // ---- Visibility byte animation (asm 0x7163FC-0x7164F2) ----
        if (ru32(output + 0x100) != 0) {
            if (ru32(entry + 0xC4) != 0) {
                findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), entry + 0xB8, output + 0xE0);
                const vis_idx0 = ru32(output + 0xE0);
                const vis_values = ru32(entry + 0xD0); // entry+0xB8+0x18 = AD.keyframe_base
                wu8(output + 0xEC, ru8(vis_values + vis_idx0));
                if (ri16(entry + 0xB8) != 0) {
                    if (rf32(bone_rt + BR.blend_weight) != 0.0 and ri16(entry + 0xBA) == -1) {
                        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), entry + 0xB8, output + 0xF0);
                        wu8(output + 0xFC, ru8(vis_values + ru32(output + 0xF0)));
                    }
                }
            }
        }

        // ---- Visibility gate (asm 0x7164F2-0x716514) ----
        const should_process = blk: {
            if (ru32(output + 0x100) != 0 and ru8(output + 0xEC) != 0) break :blk true;
            if (frame_ctr == 0) break :blk true;
            break :blk false;
        };
        if (!should_process) continue;

        // ---- Track A (float): gate=entry+0x38, AD=entry+0x2C, output+0x30 ----
        if (frame_ctr < ru32(entry + 0x38)) {
            interpFloatTrack(this, bone_rt, entry + 0x2C, output + 0x30, ufloat(ru32(bone_rt + BR.blend_weight)));
        }

        // ---- Track B (Vec3): gate=entry+0x1C, AD=entry+0x10, output+0x00 ----
        if (frame_ctr < ru32(entry + 0x1C)) {
            interpVec3Track(this, bone_rt, entry + 0x10, output, ufloat(ru32(bone_rt + BR.blend_weight)));
            // Post-processing 1 (asm 0x71678A-0x7167CE)
            const scale1 = rf32(output + 0x3C) * rf32(this + SO.render_scale_z);
            wf32(output + 0x134, rf32(output + 0x0C) * scale1);
            wf32(output + 0x138, rf32(output + 0x10) * scale1);
            wf32(output + 0x13C, rf32(output + 0x14) * scale1);
        }

        // ---- Track C (float): gate=entry+0x70, AD=entry+0x64, output+0x80 ----
        if (frame_ctr < ru32(entry + 0x70)) {
            interpFloatTrack(this, bone_rt, entry + 0x64, output + 0x80, ufloat(ru32(bone_rt + BR.blend_weight)));
        }

        // ---- Track D (Vec3): gate=entry+0x54, AD=entry+0x48, output+0x50 ----
        if (frame_ctr < ru32(entry + 0x54)) {
            interpVec3Track(this, bone_rt, entry + 0x48, output + 0x50, ufloat(ru32(bone_rt + BR.blend_weight)));
            // Post-processing 2 (asm 0x716A67-0x716AA6)
            const scale2 = rf32(output + 0x8C) * rf32(this + SO.render_scale_z);
            wf32(output + 0x140, rf32(output + 0x5C) * scale2);
            wf32(output + 0x144, rf32(output + 0x60) * scale2);
            wf32(output + 0x148, rf32(output + 0x64) * scale2);
        }
    }
}

fn particleEmitterLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x124);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x128);
    const out_base = ru32(this + SO.particle1);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const frame_ctr = ru32(this + SO.anim_frame_ctr);

    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({
        i += 1;
        data_off += 0x7C;
        out_off += 0x84;
    }) {
        const entry = data_base + data_off;
        const output = out_base + out_off;

        // Assembly uses bone_rt_base directly (bone 0) — NOT per-entry bone_idx.

        if (frame_ctr < ru32(entry + 0x1C)) {
            interpVec3Track36(this, bone_rt_base, entry + 0x10, output);
        }
        if (frame_ctr < ru32(entry + 0x44)) {
            interpVec3Track36(this, bone_rt_base, entry + 0x38, output + 0x30);
        }
        if (frame_ctr < ru32(entry + 0x6C)) {
            interpFloatTrack12(this, bone_rt_base, entry + 0x60, output + 0x60);
        }
    }
}

fn additionalParticleLoops(this: u32, model_hdr: u32) void {
    // Assembly: model_hdr+0x134 section (asm 0x71763E-0x717D6A)
    // Then additional_remaining reset at 0x717D6F
    // Then model_hdr+0x13C section (asm 0x717D75-0x7185E3)

    // Section 12c: model_hdr+0x134 particle visibility/tracks
    // count=+0x134, data=+0x138, output=this+0x3C8
    // Data stride 0xDC, output stride 0xD0
    // Each entry: bone_idx at +0x04, visibility at +0xCC
    // Sub-tracks: visibility(+0xC0), position(+0x24), alpha(+0x40),
    //   speed(+0x5C), emission(+0x78), scale(+0xA4)
    if (ru32(model_hdr + 0x134) != 0) {
        const count0 = ru32(model_hdr + 0x134);
        const data_base0 = ru32(model_hdr + 0x138);
        const out_base0 = ru32(this + 0x3C8); // SO.particle2
        const bone_rt_base = ru32(this + SO.bone_rt_base);

        var i: u32 = 0;
        var data_off: u32 = 0;
        var out_off: u32 = 0;
        while (i < count0) : ({
            i += 1;
            data_off += 0xDC; // asm 0x717D4D
            out_off += 0xD0; // asm 0x717D53
        }) {
            const entry = data_base0 + data_off;
            const output = out_base0 + out_off;

            // Visibility check: entry+0xCC vs anim_frame_ctr
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xCC)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                // Visibility byte animation at entry+0xC0
                findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), entry + 0xC0, output + 0xB0);
                const vis_mode = ri16(entry + 0xC0);
                if (vis_mode == 0) {
                    wu8(output + 0xBC, ru8(ru32(entry + 0xC0 + 0x18) + ru32(output + 0xB0)));
                } else {
                    wu8(output + 0xBC, ru8(ru32(output + 0xB0) + ru32(entry + 0xD8)));
                    // Crossfade blend for visibility if needed
                    if (rf32(bone_rt + 0x10C) != 0.0 and ri16(entry + 0xC2) == -1) {
                        findInterpIdx(this, ru32(bone_rt + 0xC4), ru32(bone_rt + 0xC8), entry + 0xC0, output + 0xC0);
                        wu8(output + 0xCC, ru8(ru32(output + 0xC0) + ru32(entry + 0xD8)));
                    }
                }
            }

            // Position track: entry+0x24 vs entry+0x30
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x30)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                interpVec3Track(this, bone_rt, entry + 0x24, output, ufloat(ru32(bone_rt + BR.blend_weight)));
            }

            // Alpha track: entry+0x40 vs entry+0x4C
            // Short-value interpolation via game's getIndexOffset/setShortValue
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x4C)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), entry + 0x40, output + 0x30);
                const alpha_mode = ri16(entry + 0x40);
                const table = entry + 0x40 + AD.nvalues;
                if (alpha_mode == 0) {
                    const sv = @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output + 0x30)))));
                    wf32(output + 0x3C, sv * getShortToFloat());
                } else {
                    const t = ufloat(ru32(output + 0x38));
                    const v1 = @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output + 0x34)))));
                    const v0 = @as(f32, @floatFromInt(@as(i32, readShortViaGame(table, ru32(output + 0x30)))));
                    wf32(output + 0x3C, (v1 * getShortToFloat() - v0 * getShortToFloat()) * t + v0 * getShortToFloat());
                }
            }

            // Speed track: entry+0x5C vs entry+0x68
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x68)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                interpFloatTrack(this, bone_rt, entry + 0x5C, output + 0x50, ufloat(ru32(bone_rt + BR.blend_weight)));
            }

            // Emission rate: entry+0x78 vs entry+0x84
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x84)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                interpFloatTrack(this, bone_rt, entry + 0x78, output + 0x70, ufloat(ru32(bone_rt + BR.blend_weight)));
            }

            // Scale track: entry+0xA4 vs entry+0xB0
            // Short value copy via game's getIndexOffset/setShortValue
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xB0)) {
                const bone_idx = @as(u32, ru16(entry + 0x04));
                const bone_rt = bone_rt_base + bone_idx * 0x118;
                findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), entry + 0xA4, output + 0x90);
                const scale_values = ru32(entry + 0xA4 + AD.keyframe_base);
                wu16(output + 0x9C, ru16(scale_values + ru32(output + 0x90) * 2));
                if (ri16(entry + 0xA4) != 0) {
                    if (rf32(bone_rt + 0x10C) != 0.0 and ri16(entry + 0xA6) == -1) {
                        findInterpIdx(this, ru32(bone_rt + 0xC4), ru32(bone_rt + 0xC8), entry + 0xA4, output + 0xA0);
                        wu16(output + 0xAC, ru16(scale_values + ru32(output + 0xA0) * 2));
                    }
                }
            }
        }
    }

    // Additional remaining data reset — between 0x134 and 0x13C sections
    // Assembly at 0x717D6F: MOV [EBX+0x3D8], 0
    wu32(this + 0x3D8, 0);

    // Section 12e: model_hdr+0x13C (largest particle section)
    // count=+0x13C, data=+0x140
    // output1=this+0x3D0, output2=this+0x3D4
    // Data stride 0x1F8, output stride 0x16C
    const count1 = ru32(model_hdr + 0x13C);
    if (count1 != 0) {
        const data_base = ru32(model_hdr + 0x140);
        const bone_rt_base = ru32(this + SO.bone_rt_base);
        const particle_base = ru32(this + 0x3D0); // SO.particle3

        var i: u32 = 0;
        var data_off: u32 = 0;
        var out_off: u32 = 0;
        while (i < count1) : ({
            i += 1;
            data_off += 0x1F8; // asm 0x7185CD
            out_off += 0x16C; // asm 0x7185BA
        }) {
            const entry = data_base + data_off;
            const output = particle_base + out_off;
            const bone_idx = @as(u32, ru16(entry + 0x14));
            const bone_rt = bone_rt_base + bone_idx * 0x118;

            // All tracks from assembly 0x717D90-0x7185E3:
            const particle_ptrs = ru32(this + 0x3D4); // [EBX+0x3D4]
            const local_14 = ru32(particle_ptrs + i * 4); // per-emitter data ptr

            // Visibility: gate=entry+0x1E8, AnimData=entry+0x1DC, output=output+0x140
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x1E8)) {
                findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), entry + 0x1DC, output + 0x140);
                if (ri16(entry + 0x1DC) == 0) {
                    wu8(output + 0x14C, ru8(ru32(entry + 0x1F4) + ru32(output + 0x140)));
                } else {
                    wu8(output + 0x14C, ru8(ru32(output + 0x140) + ru32(entry + 0x1F4)));
                    if (rf32(bone_rt + 0x10C) != 0.0 and ri16(entry + 0x1DE) == -1) {
                        findInterpIdx(this, ru32(bone_rt + 0xC4), ru32(bone_rt + 0xC8), entry + 0x1DC, output + 0x150);
                        wu8(output + 0x15C, ru8(ru32(entry + 0x1F4) + ru32(output + 0x150)));
                    }
                }
            }

            // Emitter active flag: visibility && emitter_enable_flag
            const vis_byte = ru8(output + 0x14C);
            const emitter_active: u32 = if (vis_byte != 0 and ru32(this + 0x50) != 0) 1 else 0;
            wu32(output + 0x160, emitter_active);
            // IsParticleBufferEmpty check
            var buf_active: u32 = 0;
            if (emitter_active != 0) {
                buf_active = 1;
            } else {
                // Call IsParticleBufferEmpty (0x7B5F60)
                // Assembly: MOV ECX,[EBP-0x10]; CALL 0x7B5F60
                // __thiscall(ECX=ptr), plain RET, returns 0 or 1 in EAX
                const isEmptyFn: *const fn (u32) callconv(.{ .x86_fastcall = .{} }) u32 = @ptrFromInt(0x7B5F60);
                if (isEmptyFn(local_14) != 0) {
                    buf_active = 1;
                }
            }
            wu32(output + 0x164, buf_active);
            // OR into additional_remaining
            wu32(this + 0x3D8, ru32(this + 0x3D8) | buf_active);

            // Only process tracks if visible or first frame
            if (vis_byte != 0 or ru32(this + SO.anim_frame_ctr) == 0) {
                // Track 1: emission rate — gate=+0x40, AnimData=+0x34, output=+0x00
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x40)) {
                    interpFloatTrack(this, bone_rt, entry + 0x34, output, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 2: speed — gate=+0x5C, AnimData=+0x50, output=+0x20
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x5C)) {
                    interpFloatTrack(this, bone_rt, entry + 0x50, output + 0x20, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 3: color — gate=+0x78, AnimData=+0x6C, output=+0x40
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x78)) {
                    interpFloatTrack(this, bone_rt, entry + 0x6C, output + 0x40, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 4 — gate=+0x94, AnimData=+0x88, output=+0x60
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x94)) {
                    interpFloatTrack(this, bone_rt, entry + 0x88, output + 0x60, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 5 (Vec3 spline) — gate=+0xB0, AnimData=+0xA4, output=+0x80
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xB0)) {
                    interpFloatTrack(this, bone_rt, entry + 0xA4, output + 0x80, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 6 — gate=+0xCC, AnimData=+0xC0, output=+0xA0
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xCC)) {
                    interpFloatTrack(this, bone_rt, entry + 0xC0, output + 0xA0, ufloat(ru32(bone_rt + BR.blend_weight)));
                }
                // Track 7 — gate=+0xE8, AnimData=+0xDC, output=+0xC0
                // Uses getInterpolatedFloat (0x71AF20)
                // Tracks 7-10: CALL 0x71AF20 — getInterpolatedFloat
                // __fastcall(ECX=this, EDX=bone_rt, stack: anim_data, output)
                const getInterpFloat: *const fn (u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x71AF20);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xE8)) {
                    getInterpFloat(this, bone_rt, entry + 0xDC, output + 0xC0);
                }
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x104)) {
                    getInterpFloat(this, bone_rt, entry + 0xF8, output + 0xE0);
                }
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x120)) {
                    getInterpFloat(this, bone_rt, entry + 0x114, output + 0x100);
                }
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x13C)) {
                    getInterpFloat(this, bone_rt, entry + 0x130, output + 0x120);
                }
            }
        }
    }
}

fn attachmentRecursion(this: u32, model_hdr: u32, bone_out_base: u32) void {
    const hierarchy = ru32(this + SO.hierarchy_ptr);
    if (hierarchy == 0) return;

    // Attachment byte animation loop — skipped when attach_count==0 but
    // child recursion below MUST still run. Original JBE 0x718657 jumps
    // past this loop to the child section, NOT to the function exit.
    const attach_count = ru32(model_hdr + 0x104);
    const attach_data = ru32(model_hdr + 0x108);

    // Process attachment byte animations (only when attach_count > 0)
    var att_i: u32 = 0;
    var att_off: u32 = 0;
    while (att_i < attach_count) : ({
        att_i += 1;
        att_off += 0x30;
    }) {
        const att_entry = attach_data + att_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(att_entry + 0x20)) {
            const bone_idx = @as(u32, ru16(att_entry + 4));
            const bone_rt = ru32(this + SO.bone_rt_base) + bone_idx * 0x118;
            // Assembly: CALL 0x71AE90 — extractAnimationByteFromKeyframes
            // __fastcall(ECX=this, EDX=bone_rt, stack: anim_data, output)
            const extractByte: *const fn (u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x71AE90);
            extractByte(this, bone_rt, att_entry + 0x14, hierarchy + att_i * 0x20);
        }
    }

    // Iterate child scene objects linked list
    var child = ru32(this + SO.hierarchy_idx);
    while (child != 0) {
        // child->attach_idx at +0x1D4 (assembly-verified: MOV EAX,[ECX+0x1D4] at 0x718668)
        const attach_idx = ru32(child + 0x1D4);

        // Check if attachment is valid (0xFFFF = no attachment)
        if (attach_idx != 0xFFFF) {
            const visible = ru8(hierarchy + attach_idx * 0x20 + 0x0C);
            if (visible != 0) {
                const att_entry = attach_data + attach_idx * 0x30;
                const bone_idx = @as(u32, ru16(att_entry + 4));
                const bone_mat = bone_out_base + bone_idx * 0x40;

                // Copy parent bone matrix to local
                var local_1a0: [16]f32 = undefined;
                for (0..16) |fi| {
                    local_1a0[fi] = rf32(bone_mat + @as(u32, @intCast(fi)) * 4);
                }

                // Apply attachment offset translation
                const ox = rf32(att_entry + 8);
                const oy = rf32(att_entry + 0xC);
                const oz = rf32(att_entry + 0x10);
                local_1a0[12] += local_1a0[0] * ox + local_1a0[4] * oy + local_1a0[8] * oz;
                local_1a0[13] += local_1a0[1] * ox + local_1a0[5] * oy + local_1a0[9] * oz;
                local_1a0[14] += local_1a0[2] * ox + local_1a0[6] * oy + local_1a0[10] * oz;

                // Recursive call through 0x714260, matching original's CALL 0x714260.
                // Goes through hook → detour → REF for child SceneObjects.
                const callThrough: *const fn (u32, u32, u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void = @ptrFromInt(0x714260);
                callThrough(child, 0, @intFromPtr(&local_1a0), this + SO.world_pos, this + SO.render_pri, ru32(this + SO.render_scale_z));
            }
        }

        // Next sibling in linked list
        // Assembly-verified: MOV ECX,[ECX+0x1E4] at 0x718764
        child = ru32(child + 0x1E4);
    }
}
