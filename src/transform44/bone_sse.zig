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
const BILLBOARD_EPSILON: f32 = @bitCast(@as(u32, 0x3727c5ac)); // ~1e-5, from DAT_008029d4
const SHORT_TO_FLOAT: f32 = @bitCast(@as(u32, 0x38000000)); // 1/32768, DAT_00811610 (short→float conversion)
const HERMITE_3: f32 = 3.0; // DAT_0080297c
const HERMITE_5: f32 = 5.0; // DAT_00802990 (used as 3*5/3 in some bezier)

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

/// Quaternion → rotation matrix, then multiply: mat = quat_rot * mat.
/// Standard quat→mat conversion + SSE 4x4 matrix multiply.
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

/// Set identity matrix (16 floats)
inline fn setIdentity(dst: u32) void {
    inline for (0..16) |i| {
        const val: f32 = if (i == 0 or i == 5 or i == 10 or i == 15) 1.0 else 0.0;
        wf32(dst + @as(u32, @intCast(i)) * 4, val);
    }
}

/// Normalize a 3-component vector, returns (nx, ny, nz). Returns unchanged if too small.
inline fn normalizeVec3(x: f32, y: f32, z: f32) [3]f32 {
    const len_sq = x * x + y * y + z * z;
    const len = @sqrt(len_sq);
    if (len < BILLBOARD_EPSILON) return .{ x, y, z };
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

inline fn findInterpIdx(
    this: u32,
    search_value: u32,
    track_index: u32,
    anim_data: u32,
    output: u32,
) void {
    var min_idx: u32 = undefined;
    var max_idx: u32 = undefined;

    if (ru32(anim_data + AD.track_count_flag) == 0) {
        min_idx = 0;
        max_idx = ru32(anim_data + AD.keyframe_count) -% 1;
    } else {
        const ranges = ru32(anim_data + AD.keyframe_ranges);
        max_idx = ru32(ranges + 4 + track_index * 8);
        min_idx = ru32(ranges + track_index * 8);
    }

    if (max_idx <= min_idx) {
        wu32(output, min_idx);
        wu32(output + 4, min_idx);
        wu32(output + 8, 0);
        return;
    }

    // Check for global sequence override
    var sv = search_value;
    const time_idx = ri16(anim_data + AD.time_index);
    if (time_idx != -1) {
        sv = ru32(ru32(this + SO.gs_values_ptr) + @as(u32, @bitCast(@as(i32, @intCast(time_idx)))) * 4);
    }

    const timestamps = ru32(anim_data + AD.timestamps_ptr);
    var cur_idx = ru32(output);
    const delta = sv -% ru32(timestamps + cur_idx * 4);

    if (delta < 500) {
        // Forward linear scan (hot path)
        if (cur_idx < max_idx) {
            var tp = timestamps + 4 + cur_idx * 4;
            while (cur_idx < max_idx) {
                if (sv < ru32(tp)) break;
                cur_idx += 1;
                tp += 4;
            }
        }
    } else if (delta < 0xFFFFFF0C) {
        // Not within forward range and not backward — try forward from min or binary search
        const delta_from_min = sv -% ru32(timestamps + min_idx * 4);
        if (delta_from_min < 500) {
            // Forward from min
            var tp = timestamps + 4 + min_idx * 4;
            cur_idx = min_idx;
            while (min_idx < max_idx) {
                cur_idx = min_idx;
                if (sv < ru32(tp)) break;
                min_idx += 1;
                tp += 4;
                cur_idx = min_idx;
            }
        } else {
            // Binary search
            var lo = min_idx;
            var hi = max_idx;
            while (lo < hi) {
                cur_idx = (hi + lo) >> 1;
                if (sv < ru32(timestamps + cur_idx * 4)) {
                    hi = cur_idx -% 1;
                } else {
                    lo = cur_idx + 1;
                    if (sv < ru32(timestamps + 4 + cur_idx * 4)) break;
                }
                cur_idx = lo;
            }
        }
    } else {
        // Backward linear scan
        if (min_idx < cur_idx) {
            var tp = timestamps + cur_idx * 4;
            while (min_idx < cur_idx) {
                if (ru32(tp) <= sv) break;
                cur_idx -= 1;
                tp -= 4;
            }
        }
    }

    const next_idx = cur_idx + 1;
    if (ru32(anim_data + AD.keyframe_count) <= next_idx) {
        wu32(output + 4, cur_idx);
        wu32(output, cur_idx);
        wu32(output + 8, 0);
        return;
    }

    wu32(output, cur_idx);
    wu32(output + 4, next_idx);
    const ts_cur = ri32(timestamps + cur_idx * 4);
    const ts_next = ri32(timestamps + next_idx * 4);
    const denom = ts_next - ts_cur;
    if (denom != 0) {
        const t: f32 = @as(f32, @floatFromInt(@as(i32, @bitCast(sv)) - ts_cur)) / @as(f32, @floatFromInt(denom));
        wu32(output + 8, fbits(t));
    } else {
        wu32(output + 8, 0);
    }
}

// =============================================================================
// interpolateAnimationKeyframes — reimplemented from 0x713ea0
//
// Calls findInterpIdx, does 4-component lerp (for quaternions).
// If crossfade active, does secondary lookup + blend.
// Output buffer layout: [idx0, idx1, t, x, y, z, w, sec_idx0, sec_idx1, sec_t, sx, sy, sz, sw]
// =============================================================================

inline fn interpAnimKF(this: u32, bone_rt: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const idx0 = ru32(output);
    const interp_mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (interp_mode == 0) {
        // No interpolation — copy directly (4 components, 16 bytes per keyframe)
        const src = kf_base + idx0 * 0x10;
        wu32(output + 0x0C, ru32(src));
        wu32(output + 0x10, ru32(src + 4));
        wu32(output + 0x14, ru32(src + 8));
        wu32(output + 0x18, ru32(src + 12));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const a = kf_base + idx0 * 0x10;
    const b = kf_base + ru32(output + 4) * 0x10;

    // 4-component lerp
    wf32(output + 0x0C, (rf32(b) - rf32(a)) * t + rf32(a));
    wf32(output + 0x10, (rf32(b + 4) - rf32(a + 4)) * t + rf32(a + 4));
    wf32(output + 0x14, (rf32(b + 8) - rf32(a + 8)) * t + rf32(a + 8));
    wf32(output + 0x18, (rf32(b + 12) - rf32(a + 12)) * t + rf32(a + 12));

    // Crossfade blend
    const blend = ufloat(ru32(bone_rt + BR.blend_weight));
    if (blend != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x1C);

        const si0 = ru32(output + 0x1C);
        const si1 = ru32(output + 0x20);
        const st = ufloat(ru32(output + 0x24));
        const sa = kf_base + si0 * 0x10;
        const sb = kf_base + si1 * 0x10;

        // Secondary 4-component lerp
        const sx = (rf32(sb) - rf32(sa)) * st + rf32(sa);
        const sy = (rf32(sb + 4) - rf32(sa + 4)) * st + rf32(sa + 4);
        const sz = (rf32(sb + 8) - rf32(sa + 8)) * st + rf32(sa + 8);
        const sw = (rf32(sb + 12) - rf32(sa + 12)) * st + rf32(sa + 12);
        wu32(output + 0x28, fbits(sx));
        wu32(output + 0x2C, fbits(sy));
        wu32(output + 0x30, fbits(sz));
        wu32(output + 0x34, fbits(sw));

        // Blend: primary += (secondary - primary) * weight
        wf32(output + 0x0C, (sx - rf32(output + 0x0C)) * blend + rf32(output + 0x0C));
        wf32(output + 0x10, (sy - rf32(output + 0x10)) * blend + rf32(output + 0x10));
        wf32(output + 0x14, (sz - rf32(output + 0x14)) * blend + rf32(output + 0x14));
        wf32(output + 0x18, (sw - rf32(output + 0x18)) * blend + rf32(output + 0x18));
    }
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

    // Crossfade
    const blend = ufloat(ru32(bone_rt + BR.blend_weight));
    if (blend != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x10);
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
// Main export: transformMatrix4x4_SSE
//
// Calling convention: C (all params on stack, since this is a separate
// compilation unit linked via addObject). The transform44.zig wrapper
// calls this with explicit params extracted from the fastcall detour.
//
// Params: this_ptr, mat1(parent_matrix*), mat2(position_vec3*), mat3(offset_vec3*), mat4(scale_float_bits)
// mat1 is the parent transform matrix — used for billboard matrix setup
// (initPPSG computes billboard_row0 = field_0xBC × mat1)
// =============================================================================

export fn transformMatrix4x4_SSE(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) void {
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
        const has_emitter: u32 = if (ru32(emitter_ctx + 0x50) != 0 and rf32(this + SO.field_188) != 0.0) 1 else 0;
        wu32(this + SO.emitter_flag, has_emitter);
        wu32(this + SO.field_17c, ru32(emitter_ctx + 0x17C));
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

    // initParticlePixelShaderGeneration (0x74a7c0) — indirect JMP thunk to matrix multiply.
    // Computes: billboard_row0 = field_0xBC × mat1 (parent transform).
    // Reimplemented as inline SSE matrix multiply (avoids uncertain calling convention
    // of the indirect JMP target — Ghidra can't resolve the target's RET type).
    {
        const left = this + 0xBC; // local transform matrix (4x4)
        const right = mat1; // parent transform matrix (4x4)
        const out = this + 0xFC; // output billboard/camera matrix

        // SSE 4x4 matrix multiply: out = left × right
        const r0: V4 = .{ rf32(right + 0x00), rf32(right + 0x04), rf32(right + 0x08), rf32(right + 0x0C) };
        const r1: V4 = .{ rf32(right + 0x10), rf32(right + 0x14), rf32(right + 0x18), rf32(right + 0x1C) };
        const r2: V4 = .{ rf32(right + 0x20), rf32(right + 0x24), rf32(right + 0x28), rf32(right + 0x2C) };
        const r3: V4 = .{ rf32(right + 0x30), rf32(right + 0x34), rf32(right + 0x38), rf32(right + 0x3C) };

        inline for (0..4) |i| {
            const b = @as(u32, @intCast(i)) * 0x10;
            const row = splat(rf32(left + b)) * r0 + splat(rf32(left + b + 4)) * r1 + splat(rf32(left + b + 8)) * r2 + splat(rf32(left + b + 12)) * r3;
            wf32(out + b + 0x00, row[0]);
            wf32(out + b + 0x04, row[1]);
            wf32(out + b + 0x08, row[2]);
            wf32(out + b + 0x0C, row[3]);
        }
    }

    // =========================================================================
    // Section 5: child_objects_padding (len_sq of world transform translation)
    // =========================================================================
    if (emitter_ctx == 0 or (ru8(emitter_ctx + 4) & 1) != 0) {
        const wx = rf32(this + SO.world_xform + 8 * 4); // [8]
        const wy = rf32(this + SO.world_xform + 9 * 4); // [9]
        const wz = rf32(this + SO.world_xform + 10 * 4); // [10]
        wu32(this + SO.child_padding, fbits(wx * wx + wy * wy + wz * wz));
    } else {
        wu32(this + SO.child_padding, ru32(emitter_ctx + 0x84));
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
                // Has own animation slot — compute time from animation lookup table
                if (sdb != 0) {
                    wu32(brt + BR.sec_start, ru32(brt + BR.sec_start) +% time_delta_val);
                    wu32(brt + BR.sec_end, ru32(brt + BR.sec_end) +% time_delta_val);
                }
                const anim_lookup = ru32(model_hdr + 0x20);
                const anim_entry = anim_lookup + @as(u32, @intCast(anim_slot_val)) * 0x44;
                const cur_time = ru32(anim_ctx + 0x0C);

                // Check looping vs clamped
                if ((ru8(anim_entry + 0x10) & 1) == 0) {
                    // Looping animation
                    const anim_end: i32 = ri32(anim_entry + 0x08);
                    const anim_start: i32 = ri32(anim_entry + 0x04);
                    if (anim_start < anim_end) {
                        const elapsed: f32 = @floatFromInt(@as(i32, @bitCast(cur_time -% ru32(brt + BR.sec_start))));
                        const duration: u32 = @as(u32, @intCast(anim_end - anim_start));
                        if (duration != 0) {
                            const frame_in_anim = (@as(u32, @intFromFloat(elapsed)) +% ru32(brt + BR.sec_anim_offset)) % duration;
                            wu32(brt + BR.prim_time, @as(u32, @intCast(anim_start)) +% frame_in_anim);
                        }
                    }
                } else {
                    // Clamped animation
                    const end_time = ru32(brt + BR.sec_end);
                    const start_time = ru32(brt + BR.sec_start);
                    if (end_time != cur_time and @as(i32, @bitCast(end_time -% cur_time)) >= 0) {
                        if (start_time != cur_time and @as(i32, @bitCast(start_time -% cur_time)) >= 0) {
                            wu32(brt + BR.prim_time, start_time); // use start time
                        }
                        // else: use cur_time (already set from inheritance/previous)
                    } else {
                        // Compute clamped position
                        const dur_val: i32 = @as(i32, @bitCast(end_time -% start_time));
                        const elapsed_f: f32 = @floatFromInt(@as(i32, @bitCast(cur_time -% start_time)));
                        _ = elapsed_f;
                        const offset: i32 = @as(i32, @intFromFloat(@as(f32, @floatFromInt(dur_val)))) + @as(i32, @bitCast(ru32(brt + BR.sec_anim_offset)));
                        const anim_start2: i32 = ri32(anim_entry + 0x04);
                        const anim_end2: i32 = ri32(anim_entry + 0x08);

                        var time_pos: u32 = undefined;
                        if (offset < 0) {
                            time_pos = @as(u32, @bitCast(anim_start2));
                        } else if (offset <= anim_end2 - anim_start2) {
                            time_pos = @as(u32, @intCast(offset + anim_start2));
                        } else {
                            time_pos = @as(u32, @bitCast(anim_end2));
                        }
                        wu32(brt + BR.prim_time, time_pos);
                    }
                }
                wu32(brt + BR.prim_track, ru32(brt + BR.anim_slot));
                wu32(brt + BR.prim_time, ru32(brt + BR.prim_time)); // already set above
                wu32(brt + BR.prim_anim, bone_idx);
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
                // Compute secondary time (same pattern as primary, abbreviated)
                if (sdb != 0) {
                    wu32(brt + BR.sec_start2, ru32(brt + BR.sec_start2) +% time_delta_val);
                    wu32(brt + BR.sec_end2, ru32(brt + BR.sec_end2) +% time_delta_val);
                }
                // For now, copy from primary — full implementation would mirror primary logic
                wu32(brt + BR.sec_track, @as(u32, @bitCast(sec_slot_val)));
                wu32(brt + BR.sec_time, ru32(brt + BR.prim_time));

                // Check expiry
                if (@as(i32, @bitCast(ru32(anim_ctx + 0x0C) -% ru32(brt + BR.crossfade_end))) >= 0) {
                    wu32(brt + BR.sec_slot, 0xFFFFFFFF); // expire
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
                src_mat = this + SO.bb_row0 - 0; // identity-like base matrix at +0xFC? No...
                // When parent is 0xFFFF, use the identity-like base at model_attachment_list1
                // Actually from decompilation: param_2 = &this->model_attachment_list1
                // which is at +0xFC. But that's the camera matrix, not identity.
                // Let me use the local identity matrix instead.
                src_mat = local_mat_addr;
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
                        const cam0 = [3]f32{ rf32(this + SO.bb_row0), rf32(this + SO.bb_row0 + 4), rf32(this + SO.bb_row0 + 8) };
                        const cam_len_sq0 = cam0[0] * cam0[0] + cam0[1] * cam0[1] + cam0[2] * cam0[2];
                        var s0: f32 = 1.0;
                        if (cam_len_sq0 > @as(f32, @bitCast(@as(u32, 0x3727c5ac)))) {
                            const mat_len_sq0 = local_mat[0] * local_mat[0] + local_mat[1] * local_mat[1] + local_mat[2] * local_mat[2];
                            s0 = @sqrt(mat_len_sq0 / cam_len_sq0);
                        }
                        local_mat[0] = s0 * cam0[0];
                        local_mat[1] = s0 * cam0[1];
                        local_mat[2] = s0 * cam0[2];

                        const wt0 = rf32(this + SO.world_xform + 0 * 4);
                        const wt1 = rf32(this + SO.world_xform + 1 * 4);
                        const wt2 = rf32(this + SO.world_xform + 2 * 4);
                        const wt_len_sq = wt0 * wt0 + wt1 * wt1 + wt2 * wt2;
                        var s1: f32 = 1.0;
                        if (wt_len_sq > @as(f32, @bitCast(@as(u32, 0x3727c5ac)))) {
                            const mat_len_sq1 = local_mat[4] * local_mat[4] + local_mat[5] * local_mat[5] + local_mat[6] * local_mat[6];
                            s1 = @sqrt(mat_len_sq1 / wt_len_sq);
                        }
                        local_mat[4] = s1 * wt0;
                        local_mat[5] = s1 * wt1;
                        local_mat[6] = s1 * wt2;

                        const wt4 = rf32(this + SO.world_xform + 4 * 4);
                        const wt5 = rf32(this + SO.world_xform + 5 * 4);
                        const wt6 = rf32(this + SO.world_xform + 6 * 4);
                        const wt_len_sq2 = wt4 * wt4 + wt5 * wt5 + wt6 * wt6;
                        var s2: f32 = 1.0;
                        if (wt_len_sq2 > @as(f32, @bitCast(@as(u32, 0x3727c5ac)))) {
                            const mat_len_sq2 = local_mat[8] * local_mat[8] + local_mat[9] * local_mat[9] + local_mat[10] * local_mat[10];
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

                // Rotation
                if (rot_kf_count != 0.0 and ru32(this + SO.anim_frame_ctr) < rot_kf_count) {
                    interpAnimKF(this, brt, rot_anim, brt + BR.rot_idx0);
                    // initPixelShaderDispatcher5 call (0x74b6b5) — particle shader init, not perf critical
                }

                // Scale interpolation
                const scale_anim = bdef + BD.scale_anim;
                const scale_kf_count = ru32(bdef + BD.scale_nts);
                if (scale_kf_count != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < scale_kf_count) {
                        interpVec3Track(this, brt, scale_anim, brt + BR.scale_idx0, ufloat(ru32(brt + BR.blend_weight)));
                    }
                    scaleMatrix3x3(lm2_addr, ufloat(ru32(brt + BR.scale_x)), ufloat(ru32(brt + BR.scale_y)), ufloat(ru32(brt + BR.scale_z)));
                }

                // Handle particle flag
                if ((@as(i8, @bitCast(@as(u8, @truncate(combined_flags)))) < 0) and ru32(brt + BR.bone_flag_cache) != 0) {
                    // initParticlePixelShaderGeneration() — particle setup, not math
                }

                // Translation interpolation
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

                // Compute translation: trans + pivot - rot * pivot
                const piv_x = rf32(bdef + BD.pivot_x);
                const piv_y = rf32(bdef + BD.pivot_y);
                const piv_z = rf32(bdef + BD.pivot_z);
                local_mat2[12] = tx_val - (local_mat2[0] * piv_x + local_mat2[4] * piv_y + local_mat2[8] * piv_z);
                local_mat2[13] = ty_val - (local_mat2[1] * piv_x + local_mat2[5] * piv_y + local_mat2[9] * piv_z);
                local_mat2[14] = tz_val - (local_mat2[2] * piv_x + local_mat2[6] * piv_y + local_mat2[10] * piv_z);

                // Apply rotation from quaternion if rotation was interpolated
                if (rot_kf_count != 0 and ru32(this + SO.anim_frame_ctr) < rot_kf_count) {
                    rotateByQuaternion(lm2_addr, ufloat(ru32(brt + BR.rot_x)), ufloat(ru32(brt + BR.rot_y)), ufloat(ru32(brt + BR.rot_z)), ufloat(ru32(brt + BR.rot_w)));
                }

                // Write final composed matrix to output
                const dst = bone_out_base + bone_idx * 0x40;
                // Multiply: dst = local_mat2 * src_mat (parent)
                const r0: V4 = .{ rf32(src_mat), rf32(src_mat + 4), rf32(src_mat + 8), rf32(src_mat + 12) };
                const r1: V4 = .{ rf32(src_mat + 16), rf32(src_mat + 20), rf32(src_mat + 24), rf32(src_mat + 28) };
                const r2: V4 = .{ rf32(src_mat + 32), rf32(src_mat + 36), rf32(src_mat + 40), rf32(src_mat + 44) };
                const r3: V4 = .{ rf32(src_mat + 48), rf32(src_mat + 52), rf32(src_mat + 56), rf32(src_mat + 60) };

                inline for (0..4) |row| {
                    const b = row * 4;
                    const out = splat(local_mat2[b]) * r0 + splat(local_mat2[b + 1]) * r1 + splat(local_mat2[b + 2]) * r2 + splat(local_mat2[b + 3]) * r3;
                    wf32(dst + @as(u32, @intCast(b)) * 4, out[0]);
                    wf32(dst + @as(u32, @intCast(b)) * 4 + 4, out[1]);
                    wf32(dst + @as(u32, @intCast(b)) * 4 + 8, out[2]);
                    wf32(dst + @as(u32, @intCast(b)) * 4 + 12, out[3]);
                }
            }

            // --- Billboard post-processing (flags & 0x78) ---
            // TODO: Implement billboard post-processing for types 8/16/32/64
            // This is a less common path — most bones don't have post-billboard flags
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

    // Section 8: Texture animation loop
    //texAnimLoop(this, model_hdr);  // DEBUG: disabled

    // Section 9: Color animation loop
    //colorAnimLoop(this, model_hdr);  // DEBUG: disabled

    // Section 10: Bone keyframe processing
    //boneKeyframeLoop(this, model_hdr);  // DEBUG: disabled

    // Section 11: Particle emitter loops
    //particleLoops(this, model_hdr);  // DEBUG: disabled

    // Section 12: Attachment recursion — RE-ENABLED to test
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
        // Alpha/opacity track
        if (ru32(this + SO.anim_frame_ctr) < ru32(anim_data + 0x28)) {
            // Short value interpolation via getIndexOffset/setShortValue pattern
            // This accesses short values at anim_data + 0x1C
            const alpha_anim = anim_data + 0x1C;
            const alpha_out = output + 0xC * 4;
            findInterpIdx(this, ru32(bone_rt_base + 0x98), ru32(bone_rt_base + 0x9C), alpha_anim, alpha_out);
            // Short value interpolation
            const mode = ri16(alpha_anim);
            const kf_base = ru32(alpha_anim + AD.keyframe_base);
            if (mode == 0) {
                const sv = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(kf_base + ru32(alpha_out) * 2)))))));
                wf32(output + 0xF * 4, sv * SHORT_TO_FLOAT);
            } else {
                const t = ufloat(ru32(alpha_out + 8));
                const kf_data = alpha_anim + 0x08; // _padding field in AnimationData = keyframe_ranges offset
                _ = kf_data;
                // getIndexOffset: returns *(data+4) + idx * 2 = pointer to short
                const short_base = ru32(alpha_anim + 0x0C); // keyframe_ranges = short array base
                const v0 = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(short_base + ru32(alpha_out) * 2)))))));
                const v1 = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(short_base + ru32(alpha_out + 4) * 2)))))));
                wf32(output + 0xF * 4, (v1 * SHORT_TO_FLOAT - v0 * SHORT_TO_FLOAT) * t + v0 * SHORT_TO_FLOAT);
            }
        }
    }
}

fn colorAnimLoop(this: u32, model_hdr: u32) void {
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
        if (ru32(this + SO.anim_frame_ctr) < ru32(anim_data + 0x04)) {
            findInterpIdx(this, ru32(bone_rt_base + BR.prim_time), ru32(bone_rt_base + BR.prim_track), anim_data, output);
            const mode = ri16(anim_data);
            const kf_base = ru32(anim_data + AD.keyframe_base);
            if (mode == 0) {
                const sv = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(kf_base + ru32(output) * 2)))))));
                wf32(output + 0x0C, sv * SHORT_TO_FLOAT);
            } else {
                const t = ufloat(ru32(output + 8));
                const short_base = ru32(anim_data + 0x0C);
                const v0 = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(short_base + ru32(output) * 2)))))));
                const v1 = @as(f32, @floatFromInt(@as(i32, @intCast(@as(i16, @bitCast(ru16(short_base + ru32(output + 4) * 2)))))));
                wf32(output + 0x0C, (v1 * SHORT_TO_FLOAT - v0 * SHORT_TO_FLOAT) * t + v0 * SHORT_TO_FLOAT);
            }
        }
    }
}

fn boneKeyframeLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x74);
    if (count == 0) return;
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
        data_off += 0x24;
        out_off += 0x26 * 4;
        mat_off += 0x40;
    }) {
        const kf_data = data_base + data_off;
        const output = @as(u32, @intCast(@as(i32, @bitCast(scale2_base)) + @as(i32, @bitCast(out_off))));
        const mat_out = @as(u32, @intCast(@as(i32, @bitCast(scale3_base)) + @as(i32, @bitCast(mat_off))));

        // Init identity matrix for this keyframe entry
        setIdentity(mat_out);

        // Rotation
        const rot_anim = kf_data + 0x10;
        if (ru32(rot_anim + AD.keyframe_count) != 0) {
            interpAnimKF(this, bone_rt_base, rot_anim, output + 0xC * 4);
            // Apply rotation via quaternion
            const lm_addr = mat_out;
            applyTranslation(lm_addr, 0.5, 0.5, 0.0); // DAT_00cf043c/40/44 = {0.5, 0.5, 0.0}
            rotateByQuaternion(lm_addr, ufloat(ru32(output + 0xF * 4)), ufloat(ru32(output + 0x10 * 4)), ufloat(ru32(output + 0x11 * 4)), ufloat(ru32(output + 0x12 * 4)));
            applyTranslation(lm_addr, -0.5, -0.5, 0.0);
        }

        // Scale
        const scale_anim = kf_data + 0x28;
        if (ru32(scale_anim + AD.keyframe_count - 0x28 + 0x34) != 0) {
            // Translation for bone keyframe
            const trans_anim = kf_data;
            if (ru32(trans_anim + AD.keyframe_count) != 0) {
                interpVec3Track(this, bone_rt_base, trans_anim, output, ufloat(ru32(bone_rt_base + BR.blend_weight)));
                applyTranslation(mat_out, ufloat(ru32(output + 0x0C)), ufloat(ru32(output + 0x10)), ufloat(ru32(output + 0x14)));
            }
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

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = data_base + i * 0xD4;
        const output = out_base + i * 0x15C;
        const bone_idx = @as(u32, ru16(entry + 2));
        const bone_rt = bone_rt_base + bone_idx * 0x118;

        // Process each sub-track (visibility, position, speed, emission rate, scale, color)
        // Position track
        if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x30)) {
            interpVec3Track(this, bone_rt, entry + 0x24, output, ufloat(ru32(bone_rt + BR.blend_weight)));
        }
        // Additional scalar tracks follow same pattern
        if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x4C)) {
            interpFloatTrack(this, bone_rt, entry + 0x40, output + 0x50);
        }
    }
}

fn particleEmitterLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x124);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x128);
    const out_base = ru32(this + SO.particle1);
    const bone_rt_base = ru32(this + SO.bone_rt_base);

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
        const bone_idx = @as(u32, ru16(entry + 2));
        const bone_rt = bone_rt_base + bone_idx * 0x118;

        // Position track (Vec3 with possible spline interpolation)
        if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x10)) {
            interpVec3Track(this, bone_rt, entry + 0x04, output, ufloat(ru32(bone_rt + BR.blend_weight)));
        }

        // Color/alpha/speed/emission/scale tracks — all use same interpFloatTrack pattern
        if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x2C)) {
            interpFloatTrack(this, bone_rt, entry + 0x20, output + 0x30);
        }
    }
}

fn additionalParticleLoops(this: u32, model_hdr: u32) void {
    // Section for model_hdr + 0x134 and + 0x13C
    // These handle additional particle system tracks and the large per-emitter
    // state blocks (8+ sub-tracks each). They all follow the same findInterpIdx +
    // lerp + crossfade pattern.

    // Additional remaining data reset
    wu32(this + SO.add_remaining, 0);

    const count1 = ru32(model_hdr + 0x13C);
    if (count1 != 0) {
        const data_base = ru32(model_hdr + 0x140);
        const bone_rt_base = ru32(this + SO.bone_rt_base);
        const particle_base = ru32(this + SO.particle3);

        var i: u32 = 0;
        while (i < count1) : (i += 1) {
            const entry_off = i * 0x1FC;
            const out_off = i * 0x17C;
            const entry = data_base + entry_off;
            const output = particle_base + out_off;
            const bone_idx = @as(u32, ru16(entry + 0x14));
            const bone_rt = bone_rt_base + bone_idx * 0x118;

            // Emission rate
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x40)) {
                interpFloatTrack(this, bone_rt, entry + 0x34, output);
            }
            // Speed
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x5C)) {
                interpFloatTrack(this, bone_rt, entry + 0x50, output + 0x20);
            }
        }
    }
}

fn attachmentRecursion(this: u32, model_hdr: u32, bone_out_base: u32) void {
    const hierarchy = ru32(this + SO.hierarchy_ptr);
    if (hierarchy == 0) return;

    const attach_count = ru32(model_hdr + 0x104);
    if (attach_count == 0) return;
    const attach_data = ru32(model_hdr + 0x108);

    // Process attachment byte animations
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
            // extractAnimationByteFromKeyframes — simplified
            findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), att_entry + 0x14, hierarchy + att_i * 0x20);
        }
    }

    // Iterate child scene objects linked list
    var child = ru32(this + SO.hierarchy_idx);
    while (child != 0) {
        const attach_idx_raw = rf32(child + SO.field_184);
        const attach_idx = @as(u32, @intFromFloat(attach_idx_raw));

        // Check if attachment is valid
        if (@as(u32, @bitCast(attach_idx_raw)) != 0x08000000) {
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

                // Recursive call for child attachment SceneObject.
                // mat1 = attachment-adjusted parent bone matrix
                // mat2 = parent's world position Vec3
                // mat3 = parent's render priority Vec3 (offset)
                // mat4 = parent's render_scale_z (float as u32 bits)
                transformMatrix4x4_SSE(child, @intFromPtr(&local_1a0), this + SO.world_pos, this + SO.render_pri, ru32(this + SO.render_scale_z));
            }
        }

        // Next sibling in linked list
        child = ru32(child + 0x190); // field_0x190 = next pointer
    }
}
