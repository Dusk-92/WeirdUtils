//! Pure Zig SSE/FMA implementation of transformMatrix4x4 (0x714260).
//!
//! Zero calls to game functions except:
//!   - 0x409AEF: one-time global init (atexit registration)
//!   - 0x7B5F60: IsParticleBufferEmpty (reads game state we can't replicate)
//!   - 0x714260: recursive call for child SceneObjects (goes through hook)
//!
//! Compiled with SSE4.1 + FMA + AVX for this compilation unit only.
//! Uses @mulAdd for FMA, @Vector(4, f32) for SIMD matrix ops.

const V4 = @Vector(4, f32);

// =============================================================================
// SceneObject field offsets — assembly-verified from [EBX+N] in transformMatrix4x4
// =============================================================================

const SO = struct {
    const model_data_ptr: u32 = 0x010;
    const anim_ctx_ptr: u32 = 0x02C;
    const model_ctr_ptr: u32 = 0x030;
    const sync_value: u32 = 0x040;
    const search_data_base: u32 = 0x04C;
    const emitter_flag: u32 = 0x050;
    const gs_values_ptr: u32 = 0x064;
    const gs_time_base: u32 = 0x068;
    const child_padding: u32 = 0x084;
    const anim_frame_ctr: u32 = 0x08C;
    const bone_rt_base: u32 = 0x090;
    const bone_out_ptr: u32 = 0x094;
    const tex_anim_out: u32 = 0x0A0;
    const color_anim_out: u32 = 0x0A8;
    const scale1: u32 = 0x0AC;
    const scale2: u32 = 0x0B0;
    const scale3: u32 = 0x0B4;
    const bb_row0: u32 = 0x0FC;
    const world_xform: u32 = 0x10C;
    const field_17c: u32 = 0x17C;
    const field_180: u32 = 0x180;
    const field_184: u32 = 0x184;
    const field_188: u32 = 0x188;
    const field_18c: u32 = 0x18C;
    const field_190: u32 = 0x190;
    const render_scale_x: u32 = 0x194;
    const render_scale_y: u32 = 0x198;
    const render_scale_z: u32 = 0x19C;
    const world_pos: u32 = 0x1A0;
    const render_pri: u32 = 0x1AC;
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

const BR = struct {
    const trans_idx0: u32 = 0x00;
    const trans_idx1: u32 = 0x04;
    const trans_t: u32 = 0x08;
    const trans_x: u32 = 0x0C;
    const trans_y: u32 = 0x10;
    const trans_z: u32 = 0x14;
    const trans2_idx0: u32 = 0x18;
    const trans2_idx1: u32 = 0x1C;
    const trans2_t: u32 = 0x20;
    const trans2_x: u32 = 0x24;
    const trans2_y: u32 = 0x28;
    const trans2_z: u32 = 0x2C;
    const rot_idx0: u32 = 0x30;
    const rot_idx1: u32 = 0x34;
    const rot_t: u32 = 0x38;
    const rot_x: u32 = 0x3C;
    const rot_y: u32 = 0x40;
    const rot_z: u32 = 0x44;
    const rot_w: u32 = 0x48;
    const rot2_idx0: u32 = 0x4C;
    const rot2_idx1: u32 = 0x50;
    const rot2_t: u32 = 0x54;
    const rot2_x: u32 = 0x58;
    const rot2_y: u32 = 0x5C;
    const rot2_z: u32 = 0x60;
    const rot2_w: u32 = 0x64;
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
    const prim_time: u32 = 0x98;
    const prim_track: u32 = 0x9C;
    const prim_anim: u32 = 0xA0;
    const anim_slot: u32 = 0xA4;
    const sec_start: u32 = 0xA8;
    const sec_end: u32 = 0xAC;
    const time_scale: u32 = 0xB0;
    const sec_anim_offset: u32 = 0xB8;
    const sec_time: u32 = 0xC4;
    const sec_track: u32 = 0xC8;
    const sec_slot: u32 = 0xD0;
    const sec_start2: u32 = 0xD4;
    const sec_end2: u32 = 0xD8;
    const sec_offset2: u32 = 0xE4;
    const flags2: u32 = 0xF4;
    const crossfade_end: u32 = 0x100;
    const crossfade_inv: u32 = 0x104;
    const crossfade_weight: u32 = 0x108;
    const blend_weight: u32 = 0x10C;
    const bone_flag_cache: u32 = 0xF0;
};

const AD = struct {
    const interp_mode: u32 = 0x00;
    const time_index: u32 = 0x02;
    const track_count_flag: u32 = 0x04;
    const keyframe_ranges: u32 = 0x08;
    const keyframe_count: u32 = 0x0C;
    const timestamps_ptr: u32 = 0x10;
    const nvalues: u32 = 0x14;
    const keyframe_base: u32 = 0x18;
};

const BD = struct {
    const key_id: u32 = 0x00;
    const flags: u32 = 0x04;
    const parent_bone: u32 = 0x08;
    const trans_anim: u32 = 0x0C;
    const trans_nts: u32 = 0x18;
    const rot_anim: u32 = 0x28;
    const rot_nts: u32 = 0x34;
    const scale_anim: u32 = 0x44;
    const scale_nts: u32 = 0x50;
    const pivot_x: u32 = 0x60;
    const pivot_y: u32 = 0x64;
    const pivot_z: u32 = 0x68;
};

// Runtime constants read from game memory (patched at startup)
fn getShortToFloat() f32 {
    return rf32(0x00811610);
}
fn getBillboardEpsilon() f32 {
    return rf32(0x008029d4);
}

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
// Math helpers — pure Zig with @Vector and @mulAdd for FMA
// =============================================================================

inline fn splat(v: f32) V4 {
    return @splat(v);
}

/// Load 4 floats from memory as V4
inline fn loadV4(addr: u32) V4 {
    return .{ rf32(addr), rf32(addr + 4), rf32(addr + 8), rf32(addr + 12) };
}

/// Store V4 to memory
inline fn storeV4(addr: u32, v: V4) void {
    wf32(addr, v[0]);
    wf32(addr + 4, v[1]);
    wf32(addr + 8, v[2]);
    wf32(addr + 12, v[3]);
}

/// 3-component lerp using FMA: a + (b - a) * t
inline fn lerpVec3(a_addr: u32, b_addr: u32, t: f32) [3]f32 {
    return .{
        @mulAdd(f32, rf32(b_addr) - rf32(a_addr), t, rf32(a_addr)),
        @mulAdd(f32, rf32(b_addr + 4) - rf32(a_addr + 4), t, rf32(a_addr + 4)),
        @mulAdd(f32, rf32(b_addr + 8) - rf32(a_addr + 8), t, rf32(a_addr + 8)),
    };
}

/// Vec3 squared magnitude (replaces game's 0x4549F0)
inline fn vec3SqMag(addr: u32) f32 {
    const x = rf32(addr);
    const y = rf32(addr + 4);
    const z = rf32(addr + 8);
    return @mulAdd(f32, z, z, @mulAdd(f32, y, y, x * x));
}

/// Vec3 squared magnitude from floats
inline fn vec3SqMagF(x: f32, y: f32, z: f32) f32 {
    return @mulAdd(f32, z, z, @mulAdd(f32, y, y, x * x));
}

/// Scale 3x3 rotation portion of row-major 4x4: Row N *= scale[N]
inline fn scaleMatrix3x3(mat: u32, sx: f32, sy: f32, sz: f32) void {
    wf32(mat + 0x00, rf32(mat + 0x00) * sx);
    wf32(mat + 0x04, rf32(mat + 0x04) * sx);
    wf32(mat + 0x08, rf32(mat + 0x08) * sx);
    wf32(mat + 0x10, rf32(mat + 0x10) * sy);
    wf32(mat + 0x14, rf32(mat + 0x14) * sy);
    wf32(mat + 0x18, rf32(mat + 0x18) * sy);
    wf32(mat + 0x20, rf32(mat + 0x20) * sz);
    wf32(mat + 0x24, rf32(mat + 0x24) * sz);
    wf32(mat + 0x28, rf32(mat + 0x28) * sz);
}

/// Scale 3x3 rotation from a vec3 pointer in memory
inline fn scaleMatrix3x3FromPtr(mat: u32, vec3_ptr: u32) void {
    scaleMatrix3x3(mat, rf32(vec3_ptr), rf32(vec3_ptr + 4), rf32(vec3_ptr + 8));
}

/// Apply translation: mat[3] += mat * t (dot product per column)
inline fn applyTranslation(mat: u32, tx: f32, ty: f32, tz: f32) void {
    wf32(mat + 0x30, @mulAdd(f32, tz, rf32(mat + 0x20), @mulAdd(f32, ty, rf32(mat + 0x10), @mulAdd(f32, tx, rf32(mat + 0x00), rf32(mat + 0x30)))));
    wf32(mat + 0x34, @mulAdd(f32, tz, rf32(mat + 0x24), @mulAdd(f32, ty, rf32(mat + 0x14), @mulAdd(f32, tx, rf32(mat + 0x04), rf32(mat + 0x34)))));
    wf32(mat + 0x38, @mulAdd(f32, tz, rf32(mat + 0x28), @mulAdd(f32, ty, rf32(mat + 0x18), @mulAdd(f32, tx, rf32(mat + 0x08), rf32(mat + 0x38)))));
}

/// Apply translation from vec3 pointer in memory
inline fn applyTranslationFromPtr(mat: u32, vec3_ptr: u32) void {
    applyTranslation(mat, rf32(vec3_ptr), rf32(vec3_ptr + 4), rf32(vec3_ptr + 8));
}

/// Quaternion → rotation matrix: OVERWRITES mat (does not multiply)
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
    wf32(mat + 0x00, 1.0 - (yy2 + zz2));
    wf32(mat + 0x04, xy2 + wz2);
    wf32(mat + 0x08, xz2 - wy2);
    wf32(mat + 0x0C, 0);
    wf32(mat + 0x10, xy2 - wz2);
    wf32(mat + 0x14, 1.0 - (xx2 + zz2));
    wf32(mat + 0x18, yz2 + wx2);
    wf32(mat + 0x1C, 0);
    wf32(mat + 0x20, xz2 + wy2);
    wf32(mat + 0x24, yz2 - wx2);
    wf32(mat + 0x28, 1.0 - (xx2 + yy2));
    wf32(mat + 0x2C, 0);
    wf32(mat + 0x30, 0);
    wf32(mat + 0x34, 0);
    wf32(mat + 0x38, 0);
    wf32(mat + 0x3C, 1);
}

/// Build rotation matrix from quaternion at memory address
inline fn buildRotationMatrixFromPtr(mat: u32, quat_ptr: u32) void {
    buildRotationMatrix(mat, rf32(quat_ptr), rf32(quat_ptr + 4), rf32(quat_ptr + 8), rf32(quat_ptr + 12));
}

/// 4x4 matrix multiply: dst = a * b (row-major). Safe for dst==a or dst==b.
/// Uses FMA: 4 broadcasts + 1 mul + 3 FMA per row = 16 ops total.
fn matMul4x4(dst: u32, a: u32, b: u32) void {
    const b0 = loadV4(b);
    const b1 = loadV4(b + 0x10);
    const b2 = loadV4(b + 0x20);
    const b3 = loadV4(b + 0x30);
    // Pre-load all of A in case dst aliases a
    var a_rows: [4]V4 = undefined;
    inline for (0..4) |i| {
        a_rows[i] = loadV4(a + @as(u32, @intCast(i)) * 0x10);
    }
    inline for (0..4) |i| {
        const row = @mulAdd(V4, splat(a_rows[i][3]), b3, @mulAdd(V4, splat(a_rows[i][2]), b2, @mulAdd(V4, splat(a_rows[i][1]), b1, splat(a_rows[i][0]) * b0)));
        storeV4(dst + @as(u32, @intCast(i)) * 0x10, row);
    }
}

/// Quaternion → rotation matrix, then multiply: mat = quat_rot * mat
inline fn rotateByQuaternion(mat: u32, qx: f32, qy: f32, qz: f32, qw: f32) void {
    var tmp: [64]u8 align(16) = undefined;
    const tmp_addr = @intFromPtr(&tmp);
    buildRotationMatrix(tmp_addr, qx, qy, qz, qw);
    matMul4x4(mat, tmp_addr, mat);
}

/// Rotate matrix by quaternion at memory address
inline fn rotateByQuaternionFromPtr(mat: u32, quat_ptr: u32) void {
    rotateByQuaternion(mat, rf32(quat_ptr), rf32(quat_ptr + 4), rf32(quat_ptr + 8), rf32(quat_ptr + 12));
}

/// Copy 16 floats (4x4 matrix)
inline fn copyMat4(dst: u32, src: u32) void {
    inline for (0..4) |i| {
        storeV4(dst + @as(u32, @intCast(i)) * 0x10, loadV4(src + @as(u32, @intCast(i)) * 0x10));
    }
}

/// Set identity matrix
inline fn setIdentity(dst: u32) void {
    storeV4(dst, .{ 1, 0, 0, 0 });
    storeV4(dst + 0x10, .{ 0, 1, 0, 0 });
    storeV4(dst + 0x20, .{ 0, 0, 1, 0 });
    storeV4(dst + 0x30, .{ 0, 0, 0, 1 });
}

/// Normalize vec3 in memory. Returns unchanged if length < epsilon.
inline fn normalizeVec3InPlace(addr: u32) void {
    const sq = vec3SqMag(addr);
    const len = @sqrt(sq);
    if (@abs(len) >= getBillboardEpsilon()) {
        const inv = 1.0 / len;
        wf32(addr, rf32(addr) * inv);
        wf32(addr + 4, rf32(addr + 4) * inv);
        wf32(addr + 8, rf32(addr + 8) * inv);
    }
}

/// Float truncation (replaces game's __ftol at 0x40A2B0)
inline fn ftol(delta: i32, scale_addr: u32) i32 {
    const f = @as(f32, @floatFromInt(delta)) * rf32(scale_addr);
    // @intFromFloat truncates toward zero, matching MSVC __ftol
    return @intFromFloat(f);
}

// =============================================================================
// Interpolation — pure Zig reimplementations
// =============================================================================

/// findInterpIdx: temporal-coherence keyframe search.
/// Reimplements game function at 0x713D50 (334 bytes).
/// Reads anim_data for timestamps/ranges, searches for bracket, computes t.
/// output[0] = lower idx (also cached position), [1] = upper idx, [2] = t bits.
fn findInterpIdx(this: u32, search_value: u32, track_index: u32, anim_data: u32, output: u32) void {
    const n_ranges = ru32(anim_data + AD.track_count_flag);
    const n_timestamps = ru32(anim_data + AD.keyframe_count);
    const ts_base = ru32(anim_data + AD.timestamps_ptr);

    // Global sequence override
    const time_idx = ri16(anim_data + AD.time_index);
    const search: u32 = if (time_idx >= 0) blk: {
        const gs_vals = ru32(this + SO.gs_values_ptr);
        break :blk ru32(gs_vals + @as(u32, @intCast(time_idx)) * 4);
    } else search_value;

    // Determine range for this track
    var range_start: u32 = 0;
    var range_count: u32 = n_timestamps;
    if (n_ranges != 0 and n_ranges > track_index) {
        const ranges = ru32(anim_data + AD.keyframe_ranges);
        range_start = ru32(ranges + track_index * 8);
        range_count = ru32(ranges + track_index * 8 + 4);
    }

    if (range_count == 0) return;
    if (range_count == 1) {
        wu32(output, range_start);
        wu32(output + 4, range_start);
        wu32(output + 8, 0);
        return;
    }

    const last = range_start + range_count - 1;
    const first_ts = ru32(ts_base + range_start * 4);
    const last_ts = ru32(ts_base + last * 4);

    if (search <= first_ts) {
        wu32(output, range_start);
        wu32(output + 4, range_start);
        wu32(output + 8, 0);
        return;
    }
    if (search >= last_ts) {
        wu32(output, last);
        wu32(output + 4, last);
        wu32(output + 8, 0);
        return;
    }

    // Temporal coherence: start from cached index
    var idx = ru32(output);
    if (idx < range_start or idx >= last) idx = range_start;

    // Forward scan (hot path — animations advance forward)
    if (ru32(ts_base + idx * 4) <= search) {
        while (idx < last and ru32(ts_base + (idx + 1) * 4) <= search) {
            idx += 1;
        }
    } else {
        // Backward scan
        while (idx > range_start and ru32(ts_base + idx * 4) > search) {
            idx -= 1;
        }
    }

    // Compute interpolation factor
    const ts_lo = ru32(ts_base + idx * 4);
    const ts_hi = ru32(ts_base + (idx + 1) * 4);
    const t: f32 = if (ts_hi > ts_lo)
        @as(f32, @floatFromInt(search - ts_lo)) / @as(f32, @floatFromInt(ts_hi - ts_lo))
    else
        0.0;

    wu32(output, idx);
    wu32(output + 4, idx + 1);
    wu32(output + 8, @bitCast(t));
}

/// Quaternion keyframe interpolation (replaces game's 0x713EA0).
/// Reads CompQuat (4×i16, 8 bytes per keyframe), converts to float, lerps.
/// Writes: output[0..2]=indices/t, output[3..6]=qx/qy/qz/qw, output[7..13]=secondary.
fn interpAnimKF(this: u32, bone_rt: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);
    const s2f = getShortToFloat();

    if (mode == 0) {
        const src = kf_base + ru32(output) * 8;
        inline for (0..4) |i| {
            wf32(output + 0x0C + @as(u32, @intCast(i)) * 4, @as(f32, @floatFromInt(@as(i32, ri16(src + @as(u32, @intCast(i)) * 2)))) * s2f);
        }
        return;
    }

    // Lerp (mode 1+)
    const t = ufloat(ru32(output + 8));
    const src0 = kf_base + ru32(output) * 8;
    const src1 = kf_base + ru32(output + 4) * 8;
    inline for (0..4) |i| {
        const off: u32 = @intCast(i * 2);
        const a = @as(f32, @floatFromInt(@as(i32, ri16(src0 + off)))) * s2f;
        const b = @as(f32, @floatFromInt(@as(i32, ri16(src1 + off)))) * s2f;
        wf32(output + 0x0C + @as(u32, @intCast(i)) * 4, @mulAdd(f32, b - a, t, a));
    }

    // Crossfade
    const bw = ufloat(ru32(bone_rt + BR.blend_weight));
    if (bw != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x1C);
        const st = ufloat(ru32(output + 0x24));
        const ssrc0 = kf_base + ru32(output + 0x1C) * 8;
        const ssrc1 = kf_base + ru32(output + 0x20) * 8;
        inline for (0..4) |i| {
            const off: u32 = @intCast(i * 2);
            const a = @as(f32, @floatFromInt(@as(i32, ri16(ssrc0 + off)))) * s2f;
            const b = @as(f32, @floatFromInt(@as(i32, ri16(ssrc1 + off)))) * s2f;
            const sec = @mulAdd(f32, b - a, st, a);
            wf32(output + 0x28 + @as(u32, @intCast(i)) * 4, sec);
            const pri = rf32(output + 0x0C + @as(u32, @intCast(i)) * 4);
            wf32(output + 0x0C + @as(u32, @intCast(i)) * 4, @mulAdd(f32, sec - pri, bw, pri));
        }
    }
}

/// Vec3 track interpolation (12 bytes/kf) with crossfade.
inline fn interpVec3Track(this: u32, bone_rt: u32, anim_data: u32, output: u32, blend_weight: f32) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (mode == 0) {
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

    if (blend_weight != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x18);
        const st = ufloat(ru32(output + 0x20));
        const sa = kf_base + ru32(output + 0x18) * 0xC;
        const sb = kf_base + ru32(output + 0x1C) * 0xC;
        const sec = lerpVec3(sa, sb, st);
        wu32(output + 0x24, fbits(sec[0]));
        wu32(output + 0x28, fbits(sec[1]));
        wu32(output + 0x2C, fbits(sec[2]));
        inline for (0..3) |i| {
            const off: u32 = @intCast(i * 4);
            const pri = ufloat(ru32(output + 0x0C + off));
            wf32(output + 0x0C + off, @mulAdd(f32, sec[i] - pri, blend_weight, pri));
        }
    }
}

/// Float track interpolation (4 bytes/kf) with crossfade.
inline fn interpFloatTrack(this: u32, bone_rt: u32, anim_data: u32, output: u32, blend_weight: f32) void {
    findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);

    const mode = ri16(anim_data + AD.interp_mode);
    const kf_base = ru32(anim_data + AD.keyframe_base);

    if (mode == 0) {
        wu32(output + 0x0C, ru32(kf_base + ru32(output) * 4));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const va = rf32(kf_base + ru32(output) * 4);
    const vb = rf32(kf_base + ru32(output + 4) * 4);
    wf32(output + 0x0C, @mulAdd(f32, vb - va, t, va));

    if (blend_weight != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), anim_data, output + 0x10);
        const st = ufloat(ru32(output + 0x18));
        const sa = rf32(kf_base + ru32(output + 0x10) * 4);
        const sb = rf32(kf_base + ru32(output + 0x14) * 4);
        const sec = @mulAdd(f32, sb - sa, st, sa);
        wu32(output + 0x1C, fbits(sec));
        const pri = ufloat(ru32(output + 0x0C));
        wf32(output + 0x0C, @mulAdd(f32, sec - pri, blend_weight, pri));
    }
}

/// Hermite basis functions
inline fn hermiteBasis(t: f32) struct { h1: f32, h2: f32, h3: f32, h4: f32 } {
    const t2 = t * t;
    const t3 = t2 * t;
    return .{
        .h1 = @mulAdd(f32, 2, t3, @mulAdd(f32, -3, t2, 1)),
        .h2 = @mulAdd(f32, t3, 1, @mulAdd(f32, -2, t2, t)),
        .h3 = @mulAdd(f32, -2, t3, 3 * t2),
        .h4 = t3 - t2,
    };
}

/// Bezier (Bernstein) basis functions
inline fn bezierBasis(t: f32) struct { b0: f32, b1: f32, b2: f32, b3: f32 } {
    const u = 1.0 - t;
    const t2 = t * t;
    const u_sq = u * u;
    return .{ .b0 = u_sq * u, .b1 = 3 * u_sq * t, .b2 = 3 * u * t2, .b3 = t2 * t };
}

/// Vec3 track with 36-byte keyframes (pos+tangents), modes 0-3 + crossfade.
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
            wf32(output + 0x0C + off, @mulAdd(f32, h.h4, rf32(kf_b + 0x0C + off), @mulAdd(f32, h.h3, rf32(kf_b + off), @mulAdd(f32, h.h2, rf32(kf_a + 0x18 + off), h.h1 * rf32(kf_a + off)))));
        }
    } else if (mode == 2) {
        const bz = bezierBasis(t);
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            const off = i * 4;
            wf32(output + 0x0C + off, @mulAdd(f32, bz.b3, rf32(kf_b + off), @mulAdd(f32, bz.b2, rf32(kf_b + 0x0C + off), @mulAdd(f32, bz.b1, rf32(kf_a + 0x18 + off), bz.b0 * rf32(kf_a + off)))));
        }
    } else {} // Unknown mode: skip primary, fall through to crossfade

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
                wf32(output + 0x24 + off, @mulAdd(f32, h.h4, rf32(skf_b + 0x0C + off), @mulAdd(f32, h.h3, rf32(skf_b + off), @mulAdd(f32, h.h2, rf32(skf_a + 0x18 + off), h.h1 * rf32(skf_a + off)))));
            }
        } else if (smode == 2) {
            const bz = bezierBasis(st);
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                const off = i * 4;
                wf32(output + 0x24 + off, @mulAdd(f32, bz.b3, rf32(skf_b + off), @mulAdd(f32, bz.b2, rf32(skf_b + 0x0C + off), @mulAdd(f32, bz.b1, rf32(skf_a + 0x18 + off), bz.b0 * rf32(skf_a + off)))));
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
            wf32(output + 0x0C + off, @mulAdd(f32, sec - pri, blend, pri));
        }
    }
}

/// Float track with 12-byte keyframes (value+tangents), modes 0-3 + crossfade.
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
        wf32(output + 0x0C, @mulAdd(f32, rf32(kf_b) - rf32(kf_a), t, rf32(kf_a)));
    } else if (mode == 3) {
        const h = hermiteBasis(t);
        wf32(output + 0x0C, @mulAdd(f32, h.h4, rf32(kf_b + 0x04), @mulAdd(f32, h.h3, rf32(kf_b), @mulAdd(f32, h.h2, rf32(kf_a + 0x08), h.h1 * rf32(kf_a)))));
    } else if (mode == 2) {
        const bz = bezierBasis(t);
        wf32(output + 0x0C, @mulAdd(f32, bz.b3, rf32(kf_b), @mulAdd(f32, bz.b2, rf32(kf_b + 0x04), @mulAdd(f32, bz.b1, rf32(kf_a + 0x08), bz.b0 * rf32(kf_a)))));
    } else {} // Unknown mode: fall through to crossfade

    const blend = rf32(bone_rt_base + BR.blend_weight);
    if (blend != 0.0 and ri16(anim_data + AD.time_index) == -1) {
        findInterpIdx(this, ru32(bone_rt_base + BR.sec_time), ru32(bone_rt_base + BR.sec_track), anim_data, output + 0x10);
        const st = ufloat(ru32(output + 0x18));
        const skf_a = kf_base + ru32(output + 0x10) * 12;
        const skf_b = kf_base + ru32(output + 0x14) * 12;
        const smode = ri16(anim_data + AD.interp_mode);
        var sec: f32 = undefined;
        if (smode == 1) {
            sec = @mulAdd(f32, rf32(skf_b) - rf32(skf_a), st, rf32(skf_a));
        } else if (smode == 3) {
            const h = hermiteBasis(st);
            sec = @mulAdd(f32, h.h4, rf32(skf_b + 0x04), @mulAdd(f32, h.h3, rf32(skf_b), @mulAdd(f32, h.h2, rf32(skf_a + 0x08), h.h1 * rf32(skf_a))));
        } else if (smode == 2) {
            const bz = bezierBasis(st);
            sec = @mulAdd(f32, bz.b3, rf32(skf_b), @mulAdd(f32, bz.b2, rf32(skf_b + 0x04), @mulAdd(f32, bz.b1, rf32(skf_a + 0x08), bz.b0 * rf32(skf_a))));
        } else {
            sec = rf32(skf_a);
        }
        wf32(output + 0x1C, sec);
        const pri = rf32(output + 0x0C);
        wf32(output + 0x0C, @mulAdd(f32, sec - pri, blend, pri));
    }
}

/// Float interpolation variant for getInterpolatedFloat (0x71AF20).
/// Identical to interpFloatTrack but reads blend from bone_rt+0x10C directly.
inline fn getInterpolatedFloat(this: u32, bone_rt_addr: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt_addr + 0x98), ru32(bone_rt_addr + 0x9C), anim_data, output);
    const mode = ri16(anim_data);
    const kf_base = ru32(anim_data + 0x18);

    if (mode == 0) {
        wu32(output + 0x0C, ru32(kf_base + ru32(output) * 4));
        return;
    }

    const t = ufloat(ru32(output + 8));
    const va = rf32(kf_base + ru32(output) * 4);
    const vb = rf32(kf_base + ru32(output + 4) * 4);
    wf32(output + 0x0C, @mulAdd(f32, vb - va, t, va));

    const blend = rf32(bone_rt_addr + 0x10C);
    if (blend != 0.0 and ri16(anim_data + 2) == -1) {
        findInterpIdx(this, ru32(bone_rt_addr + 0xC4), ru32(bone_rt_addr + 0xC8), anim_data, output + 0x10);
        const st = ufloat(ru32(output + 0x18));
        const sa = rf32(kf_base + ru32(output + 0x10) * 4);
        const sb = rf32(kf_base + ru32(output + 0x14) * 4);
        const sec = @mulAdd(f32, sb - sa, st, sa);
        wu32(output + 0x1C, fbits(sec));
        const pri = ufloat(ru32(output + 0x0C));
        wf32(output + 0x0C, @mulAdd(f32, sec - pri, blend, pri));
    }
}

/// Byte keyframe extraction (replaces game's 0x71AE90).
/// findInterpIdx then reads a byte at keyframe_values[idx0].
fn extractByte(this: u32, bone_rt: u32, anim_data: u32, output: u32) void {
    findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), anim_data, output);
    const kf_values = ru32(anim_data + AD.keyframe_base);
    wu8(output + 0x0C, ru8(kf_values + ru32(output)));
}

/// Short-value interpolation: reads i16 keyframes directly from memory.
fn shortInterpToFloat(anim_data: u32, output: u32) f32 {
    const mode = ri16(anim_data);
    const kf_base = ru32(anim_data + AD.keyframe_base);
    const s2f = getShortToFloat();
    if (mode == 0) {
        return @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output) * 2)))) * s2f;
    } else {
        const t = ufloat(ru32(output + 8));
        const v0 = @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output) * 2)))) * s2f;
        const v1 = @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output + 4) * 2)))) * s2f;
        return @mulAdd(f32, v1 - v0, t, v0);
    }
}

// =============================================================================
// Main export: transformMatrix4x4_SSE
// =============================================================================

export fn transformMatrix4x4_SSE(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
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
        const has_emitter: u32 = if (ru32(emitter_ctx + 0x50) != 0 and ru32(this + 0x1D8) != 0) 1 else 0;
        wu32(this + 0x50, has_emitter);
        wu32(this + 0x17C, ru32(emitter_ctx + 0x17C));
    }

    // =========================================================================
    // Section 3: World position/scale
    // =========================================================================
    wf32(this + SO.world_pos + 0, rf32(mat2) * rf32(this + SO.field_184));
    wf32(this + SO.world_pos + 4, rf32(this + SO.field_188) * rf32(mat2 + 4));
    wf32(this + SO.world_pos + 8, rf32(this + SO.field_18c) * rf32(mat2 + 8));

    wf32(this + SO.render_pri + 0, rf32(mat3) + rf32(this + SO.field_190));
    wf32(this + SO.render_pri + 4, rf32(this + SO.render_scale_x) + rf32(mat3 + 4));
    wf32(this + SO.render_pri + 8, rf32(this + SO.render_scale_y) + rf32(mat3 + 8));

    const scale_f: f32 = @bitCast(mat4);
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
            wu32(gs_values + gi * 4, if (dur == 0) 0 else (timestamp -% time_base) % dur);
        }
    }

    // matMul: this+0xFC = this+0xBC × mat1
    matMul4x4(this + 0xFC, this + 0xBC, mat1);

    // =========================================================================
    // Section 5: child_padding (sqmag of world transform translation row)
    // =========================================================================
    const emitter_ctx_5 = ru32(this + SO.emitter_ctx);
    if (emitter_ctx_5 == 0 or (ru8(emitter_ctx_5 + 4) & 1) != 0) {
        wu32(this + SO.child_padding, fbits(vec3SqMag(this + 0x12C)));
    } else {
        wu32(this + SO.child_padding, ru32(emitter_ctx_5 + 0x84));
    }

    // =========================================================================
    // Section 6: Identity matrices + timestamp delta
    // =========================================================================
    var local_mat: [16]f32 align(16) = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const local_mat_addr = @intFromPtr(&local_mat);
    var local_mat2: [16]f32 align(16) = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

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
            const anim_slot_val = ri32(brt + BR.anim_slot);
            if (anim_slot_val == -1) {
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
                if (ru32(this + 0x4C) != 0) {
                    wu32(brt + 0xA8, ru32(brt + 0xA8) +% time_delta_val);
                    wu32(brt + 0xAC, ru32(brt + 0xAC) +% time_delta_val);
                }
                const anim_lookup = ru32(model_hdr + 0x20);
                const anim_entry = anim_lookup + @as(u32, @bitCast(anim_slot_val)) * 0x44;
                const cur_time = ru32(ru32(this + 0x2C) + 0xC);

                if ((ru8(anim_entry + 0x10) & 1) == 0) {
                    const anim_end = ru32(anim_entry + 0x08);
                    const anim_start = ru32(anim_entry + 0x04);
                    if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                        const delta = cur_time -% ru32(brt + 0xA8);
                        const ftol_result = ftol(@as(i32, @bitCast(delta)), brt + 0xB0);
                        const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8)) % (anim_end -% anim_start);
                        wu32(brt + 0x98, anim_start +% frame);
                    } else {
                        wu32(brt + 0x98, anim_start);
                    }
                } else {
                    const sec_end_val = ru32(brt + 0xAC);
                    const sec_start_val = ru32(brt + 0xA8);
                    if (sec_end_val != cur_time and @as(i32, @bitCast(sec_end_val -% cur_time)) > 0) {
                        const effective_time = if (@as(i32, @bitCast(sec_start_val -% cur_time)) > 0) sec_start_val else cur_time;
                        const anim_end = ru32(anim_entry + 0x08);
                        const anim_start = ru32(anim_entry + 0x04);
                        if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                            const delta = effective_time -% ru32(brt + 0xA8);
                            const ftol_result = ftol(@as(i32, @bitCast(delta)), brt + 0xB0);
                            const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8)) % (anim_end -% anim_start);
                            wu32(brt + 0x98, anim_start +% frame);
                        } else {
                            wu32(brt + 0x98, anim_start);
                        }
                    } else {
                        const dur = sec_end_val -% sec_start_val;
                        const ftol_result = ftol(@as(i32, @bitCast(dur)), brt + 0xB0);
                        const offset = ftol_result + @as(i32, @bitCast(ru32(brt + 0xB8)));
                        if (offset < 0) {
                            wu32(brt + 0x98, ru32(anim_entry + 0x04));
                        } else {
                            const anim_end_i = @as(i32, @bitCast(ru32(anim_entry + 0x08)));
                            const anim_start_i = @as(i32, @bitCast(ru32(anim_entry + 0x04)));
                            if (offset <= anim_end_i - anim_start_i) {
                                wu32(brt + 0x98, @as(u32, @bitCast(offset + anim_start_i)));
                            } else {
                                wu32(brt + 0x98, ru32(anim_entry + 0x08));
                            }
                        }
                    }
                }
                wu32(brt + 0x9C, ru32(brt + 0xA4));
                wu32(brt + 0xA0, bone_idx);
            }

            // --- Secondary animation time ---
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
                if (ru32(this + 0x4C) != 0) {
                    wu32(brt + 0xD4, ru32(brt + 0xD4) +% time_delta_val);
                    wu32(brt + 0xD8, ru32(brt + 0xD8) +% time_delta_val);
                }
                const sec_anim_lookup = ru32(model_hdr + 0x20);
                const sec_anim_entry = sec_anim_lookup + @as(u32, @bitCast(sec_slot_val)) * 0x44;
                const sec_cur_time = ru32(ru32(this + 0x2C) + 0xC);

                if ((ru8(sec_anim_entry + 0x10) & 1) == 0) {
                    const anim_end = ru32(sec_anim_entry + 0x08);
                    const anim_start = ru32(sec_anim_entry + 0x04);
                    if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                        const delta = sec_cur_time -% ru32(brt + 0xD4);
                        const ftol_result = ftol(@as(i32, @bitCast(delta)), brt + 0xDC);
                        const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4)) % (anim_end -% anim_start);
                        wu32(brt + 0xC4, anim_start +% frame);
                    } else {
                        wu32(brt + 0xC4, anim_start);
                    }
                } else {
                    const sec_end_val = ru32(brt + 0xD8);
                    const sec_start_val = ru32(brt + 0xD4);
                    if (sec_end_val != sec_cur_time and @as(i32, @bitCast(sec_end_val -% sec_cur_time)) > 0) {
                        const effective_time = if (@as(i32, @bitCast(sec_start_val -% sec_cur_time)) > 0) sec_start_val else sec_cur_time;
                        const anim_end = ru32(sec_anim_entry + 0x08);
                        const anim_start = ru32(sec_anim_entry + 0x04);
                        if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
                            const delta = effective_time -% ru32(brt + 0xD4);
                            const ftol_result = ftol(@as(i32, @bitCast(delta)), brt + 0xDC);
                            const frame = (@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4)) % (anim_end -% anim_start);
                            wu32(brt + 0xC4, anim_start +% frame);
                        } else {
                            wu32(brt + 0xC4, anim_start);
                        }
                    } else {
                        const dur = sec_end_val -% sec_start_val;
                        const ftol_result = ftol(@as(i32, @bitCast(dur)), brt + 0xDC);
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
                wu32(brt + 0xC8, ru32(brt + 0xD0));
                if (@as(i32, @bitCast(ru32(ru32(this + 0x2C) + 0xC) -% ru32(brt + 0x100))) >= 0) {
                    wu32(brt + 0xD0, 0xFFFFFFFF);
                }
            }

            // --- Blend weight ---
            if (ri32(brt + BR.anim_slot) == -1 and ri32(brt + BR.sec_slot) == -1) {
                if (parent_idx_raw >= 0 and @as(u32, @intCast(parent_idx_raw)) < bone_count) {
                    wu32(brt + BR.blend_weight, ru32(bone_rt_base + @as(u32, @intCast(parent_idx_raw)) * 0x118 + BR.blend_weight));
                } else if (bone_idx == 0) {
                    wu32(brt + BR.blend_weight, 0);
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
                    const h = @mulAdd(f32, -2.0, t_clamped, 3.0) * t_clamped * t_clamped * ufloat(ru32(brt + BR.crossfade_weight));
                    wu32(brt + BR.blend_weight, fbits(h));
                }
            }

            // --- Parent bone transform ---
            const combined_flags: u32 = ru32(brt + BR.flags2) | flags;
            var src_mat: u32 = undefined;

            if (ru16(bdef + BD.parent_bone) == 0xFFFF) {
                src_mat = this + 0xFC;
            } else {
                const parent_out = bone_out_base + @as(u32, @intCast(parent_idx_raw)) * 0x40;
                src_mat = parent_out;

                if ((combined_flags & 7) != 0) {
                    for (0..16) |i| {
                        local_mat[i] = rf32(parent_out + @as(u32, @intCast(i)) * 4);
                    }
                    const pivot_x = rf32(bdef + BD.pivot_x);
                    const pivot_y = rf32(bdef + BD.pivot_y);
                    const pivot_z = rf32(bdef + BD.pivot_z);
                    const tx = @mulAdd(f32, local_mat[8], pivot_z, @mulAdd(f32, local_mat[4], pivot_y, @mulAdd(f32, local_mat[0], pivot_x, local_mat[12])));
                    const ty = @mulAdd(f32, local_mat[9], pivot_z, @mulAdd(f32, local_mat[5], pivot_y, @mulAdd(f32, local_mat[1], pivot_x, local_mat[13])));
                    const tz = @mulAdd(f32, local_mat[10], pivot_z, @mulAdd(f32, local_mat[6], pivot_y, @mulAdd(f32, local_mat[2], pivot_x, local_mat[14])));

                    const bb_type = combined_flags & 6;
                    if (bb_type == 2) {
                        normalizeVec3InPlace(local_mat_addr);
                        normalizeVec3InPlace(local_mat_addr + 0x10);
                        normalizeVec3InPlace(local_mat_addr + 0x20);
                    } else if (bb_type == 4) {
                        // Spherical billboard
                        const cam_sq = vec3SqMag(this + SO.bb_row0);
                        var s0: f32 = 1.0;
                        if (cam_sq > rf32(0x0080c5c8)) {
                            s0 = @sqrt(vec3SqMagF(local_mat[0], local_mat[1], local_mat[2]) / cam_sq);
                        }
                        local_mat[0] = s0 * rf32(this + SO.bb_row0);
                        local_mat[1] = s0 * rf32(this + SO.bb_row0 + 4);
                        local_mat[2] = s0 * rf32(this + SO.bb_row0 + 8);

                        const wt_sq = vec3SqMag(this + SO.world_xform);
                        var s1: f32 = 1.0;
                        if (wt_sq > rf32(0x0080c5c8)) {
                            s1 = @sqrt(vec3SqMagF(local_mat[4], local_mat[5], local_mat[6]) / wt_sq);
                        }
                        local_mat[4] = s1 * rf32(this + SO.world_xform);
                        local_mat[5] = s1 * rf32(this + SO.world_xform + 4);
                        local_mat[6] = s1 * rf32(this + SO.world_xform + 8);

                        const wt_sq2 = vec3SqMag(this + SO.world_xform + 16);
                        var s2: f32 = 1.0;
                        if (wt_sq2 > rf32(0x0080c5c8)) {
                            s2 = @sqrt(vec3SqMagF(local_mat[8], local_mat[9], local_mat[10]) / wt_sq2);
                        }
                        local_mat[8] = s2 * rf32(this + SO.world_xform + 16);
                        local_mat[9] = s2 * rf32(this + SO.world_xform + 20);
                        local_mat[10] = s2 * rf32(this + SO.world_xform + 24);
                    } else if (bb_type == 6) {
                        local_mat[0] = rf32(this + SO.bb_row0);
                        local_mat[1] = rf32(this + SO.bb_row0 + 4);
                        local_mat[2] = rf32(this + SO.bb_row0 + 8);
                        local_mat[4] = rf32(this + SO.world_xform);
                        local_mat[5] = rf32(this + SO.world_xform + 4);
                        local_mat[6] = rf32(this + SO.world_xform + 8);
                        local_mat[8] = rf32(this + SO.world_xform + 16);
                        local_mat[9] = rf32(this + SO.world_xform + 20);
                        local_mat[10] = rf32(this + SO.world_xform + 24);
                    }

                    if ((combined_flags & 1) == 0) {
                        local_mat[12] = tx - @mulAdd(f32, local_mat[8], pivot_z, @mulAdd(f32, local_mat[4], pivot_y, local_mat[0] * pivot_x));
                        local_mat[13] = ty - @mulAdd(f32, local_mat[9], pivot_z, @mulAdd(f32, local_mat[5], pivot_y, local_mat[1] * pivot_x));
                        local_mat[14] = tz - @mulAdd(f32, local_mat[10], pivot_z, @mulAdd(f32, local_mat[6], pivot_y, local_mat[2] * pivot_x));
                    } else {
                        local_mat[12] = rf32(this + SO.world_xform + 32);
                        local_mat[13] = rf32(this + SO.world_xform + 36);
                        local_mat[14] = rf32(this + SO.world_xform + 40);
                    }
                    src_mat = local_mat_addr;
                }
            }

            // --- Rotation/Scale/Translation interpolation ---
            if ((combined_flags & 0x280) == 0) {
                copyMat4(bone_out_base + bone_idx * 0x40, src_mat);
            } else {
                local_mat2 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
                const lm2_addr = @intFromPtr(&local_mat2);

                // Rotation
                if (ru32(bdef + BD.rot_nts) != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < ru32(bdef + BD.rot_nts)) {
                        interpAnimKF(this, brt, bdef + BD.rot_anim, brt + BR.rot_idx0);
                    }
                    buildRotationMatrixFromPtr(lm2_addr, brt + BR.rot_x);
                }

                // Scale
                if (ru32(bdef + BD.scale_nts) != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < ru32(bdef + BD.scale_nts)) {
                        interpVec3Track(this, brt, bdef + BD.scale_anim, brt + BR.scale_idx0, ufloat(ru32(brt + BR.blend_weight)));
                    }
                    scaleMatrix3x3FromPtr(lm2_addr, brt + BR.scale_x);
                }

                // Extra matrix multiply
                if ((@as(i8, @bitCast(@as(u8, @truncate(combined_flags)))) < 0) and ru32(brt + BR.bone_flag_cache) != 0) {
                    matMul4x4(lm2_addr, lm2_addr, ru32(brt + BR.bone_flag_cache));
                }

                // Translation
                var tx_val = rf32(bdef + BD.pivot_x);
                var ty_val = rf32(bdef + BD.pivot_y);
                var tz_val = rf32(bdef + BD.pivot_z);
                if (ru32(bdef + BD.trans_nts) != 0) {
                    if (ru32(this + SO.anim_frame_ctr) < ru32(bdef + BD.trans_nts)) {
                        interpVec3Track(this, brt, bdef + BD.trans_anim, brt + BR.trans_idx0, ufloat(ru32(brt + BR.blend_weight)));
                    }
                    tx_val += ufloat(ru32(brt + BR.trans_x));
                    ty_val += ufloat(ru32(brt + BR.trans_y));
                    tz_val += ufloat(ru32(brt + BR.trans_z));
                }

                const piv_x = rf32(bdef + BD.pivot_x);
                const piv_y = rf32(bdef + BD.pivot_y);
                const piv_z = rf32(bdef + BD.pivot_z);
                local_mat2[12] = tx_val - @mulAdd(f32, local_mat2[8], piv_z, @mulAdd(f32, local_mat2[4], piv_y, local_mat2[0] * piv_x));
                local_mat2[13] = ty_val - @mulAdd(f32, local_mat2[9], piv_z, @mulAdd(f32, local_mat2[5], piv_y, local_mat2[1] * piv_x));
                local_mat2[14] = tz_val - @mulAdd(f32, local_mat2[10], piv_z, @mulAdd(f32, local_mat2[6], piv_y, local_mat2[2] * piv_x));

                matMul4x4(bone_out_base + bone_idx * 0x40, lm2_addr, src_mat);
            }

            // --- Billboard post-processing ---
            if ((combined_flags & 0x78) != 0) {
                const om = bone_out_base + bone_idx * 0x40;
                const scale_len0 = @sqrt(vec3SqMag(om));
                const scale_len1 = @sqrt(vec3SqMag(om + 0x10));
                const scale_len2 = @sqrt(vec3SqMag(om + 0x20));

                const bpx = rf32(bdef + BD.pivot_x);
                const bpy = rf32(bdef + BD.pivot_y);
                const bpz = rf32(bdef + BD.pivot_z);
                const pos_x = @mulAdd(f32, bpz, rf32(om + 0x20), @mulAdd(f32, bpy, rf32(om + 0x10), @mulAdd(f32, bpx, rf32(om), rf32(om + 0x30))));
                const pos_y = @mulAdd(f32, bpz, rf32(om + 0x24), @mulAdd(f32, bpy, rf32(om + 0x14), @mulAdd(f32, bpx, rf32(om + 0x04), rf32(om + 0x34))));
                const pos_z = @mulAdd(f32, bpz, rf32(om + 0x28), @mulAdd(f32, bpy, rf32(om + 0x18), @mulAdd(f32, bpx, rf32(om + 0x08), rf32(om + 0x38))));

                const bb_post = combined_flags & 0x78;
                switch (bb_post) {
                    0x08 => {
                        if ((combined_flags & 0x280) == 0) {
                            wf32(om, 0); wf32(om + 0x04, 0); wf32(om + 0x08, -1);
                            wf32(om + 0x10, 1); wf32(om + 0x14, 0); wf32(om + 0x18, 0);
                            wf32(om + 0x20, 0); wf32(om + 0x24, 1); wf32(om + 0x28, 0);
                        } else {
                            wf32(om, local_mat2[1]); wf32(om + 0x04, local_mat2[2]); wf32(om + 0x08, -local_mat2[0]);
                            normalizeVec3InPlace(om);
                            wf32(om + 0x10, local_mat2[5]); wf32(om + 0x14, local_mat2[6]); wf32(om + 0x18, -local_mat2[4]);
                            normalizeVec3InPlace(om + 0x10);
                            wf32(om + 0x20, local_mat2[9]); wf32(om + 0x24, local_mat2[10]); wf32(om + 0x28, -local_mat2[8]);
                            normalizeVec3InPlace(om + 0x20);
                        }
                    },
                    0x10 => {
                        normalizeVec3InPlace(om);
                        wf32(om + 0x10, rf32(om + 0x04)); wf32(om + 0x14, -rf32(om)); wf32(om + 0x18, 0);
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x20 => {
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om, -rf32(om + 0x14)); wf32(om + 0x04, rf32(om + 0x10)); wf32(om + 0x08, 0);
                        normalizeVec3InPlace(om);
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x40 => {
                        normalizeVec3InPlace(om + 0x20);
                        wf32(om + 0x10, rf32(om + 0x24)); wf32(om + 0x14, -rf32(om + 0x20)); wf32(om + 0x18, 0);
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om, rf32(om + 0x24) * rf32(om + 0x18) - rf32(om + 0x28) * rf32(om + 0x14));
                        wf32(om + 0x04, rf32(om + 0x28) * rf32(om + 0x10) - rf32(om + 0x20) * rf32(om + 0x18));
                        wf32(om + 0x08, rf32(om + 0x20) * rf32(om + 0x14) - rf32(om + 0x24) * rf32(om + 0x10));
                    },
                    else => {},
                }

                wf32(om + 0x0C, 0); wf32(om + 0x1C, 0); wf32(om + 0x2C, 0);
                const r0x_s = rf32(om); const r0y_s = rf32(om + 0x04); const r0z_s = rf32(om + 0x08);
                wf32(om, scale_len0 * r0x_s); wf32(om + 0x04, scale_len0 * r0y_s); wf32(om + 0x08, scale_len0 * r0z_s);
                const r1x_s = rf32(om + 0x10); const r1y_s = rf32(om + 0x14); const r1z_s = rf32(om + 0x18);
                wf32(om + 0x10, scale_len1 * r1x_s); wf32(om + 0x14, scale_len1 * r1y_s); wf32(om + 0x18, scale_len1 * r1z_s);
                const r2x_s = rf32(om + 0x20); const r2y_s = rf32(om + 0x24); const r2z_s = rf32(om + 0x28);
                wf32(om + 0x20, scale_len2 * r2x_s); wf32(om + 0x24, scale_len2 * r2y_s); wf32(om + 0x28, scale_len2 * r2z_s);

                wf32(om + 0x30, pos_x - @mulAdd(f32, scale_len2 * r2x_s, bpz, @mulAdd(f32, scale_len1 * r1x_s, bpy, scale_len0 * r0x_s * bpx)));
                wf32(om + 0x34, pos_y - @mulAdd(f32, scale_len2 * r2y_s, bpz, @mulAdd(f32, scale_len1 * r1y_s, bpy, scale_len0 * r0y_s * bpx)));
                wf32(om + 0x38, pos_z - @mulAdd(f32, scale_len2 * r2z_s, bpz, @mulAdd(f32, scale_len1 * r1z_s, bpy, scale_len0 * r0z_s * bpx)));
                wf32(om + 0x3C, 1.0);
            }
        }
    }

    // =========================================================================
    // Sections 8-12: Post-bone-loop animations
    // =========================================================================
    texAnimLoop(this, model_hdr);
    colorAnimLoop(this, model_hdr);
    wordAnimLoop(this, model_hdr);
    boneKeyframeLoop(this, model_hdr);
    particleLoops(this, model_hdr);
    attachmentRecursion(this, model_hdr, bone_out_base);

    // Section 13: Sync update
    wu32(this + SO.sync_value, ru32(anim_ctx + 0x10));
}

// =============================================================================
// Post-bone-loop section functions
// =============================================================================

fn texAnimLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x54);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x58);
    const brt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.tex_anim_out);
    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({ i += 1; data_off += 0x38; out_off += 0x50; }) {
        const ad = data_base + data_off;
        const output = out_base + out_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(ad + 0x0C)) {
            interpVec3Track(this, brt_base, ad, output, ufloat(ru32(brt_base + BR.blend_weight)));
        }
        if (ru32(this + SO.anim_frame_ctr) < ru32(ad + 0x28)) {
            const alpha_ad = ad + 0x1C;
            const alpha_out = output + 0x30;
            findInterpIdx(this, ru32(brt_base + BR.prim_time), ru32(brt_base + BR.prim_track), alpha_ad, alpha_out);
            const mode = ri16(alpha_ad);
            if (mode == 0) {
                const kf = ru32(alpha_ad + 0x18);
                wf32(alpha_out + 0x0C, @as(f32, @floatFromInt(@as(i32, ri16(kf + ru32(alpha_out) * 2)))) * getShortToFloat());
            } else {
                const primary = shortInterpToFloat(alpha_ad, alpha_out);
                wf32(alpha_out + 0x0C, primary);
                const bw = rf32(brt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(alpha_ad + 0x02) == -1) {
                    findInterpIdx(this, ru32(brt_base + BR.sec_time), ru32(brt_base + BR.sec_track), alpha_ad, alpha_out + 0x10);
                    const secondary = shortInterpToFloat(alpha_ad, alpha_out + 0x10);
                    wf32(alpha_out + 0x1C, secondary);
                    wf32(alpha_out + 0x0C, @mulAdd(f32, secondary - primary, bw, primary));
                }
            }
        }
    }
}

fn colorAnimLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x64);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x68);
    const brt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.color_anim_out);
    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({ i += 1; data_off += 0x1C; out_off += 0x20; }) {
        const ad = data_base + data_off;
        const output = out_base + out_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(ad + 0x0C)) {
            findInterpIdx(this, ru32(brt_base + BR.prim_time), ru32(brt_base + BR.prim_track), ad, output);
            const mode = ri16(ad);
            if (mode == 0) {
                wf32(output + 0x0C, @as(f32, @floatFromInt(@as(i32, ri16(ru32(ad + 0x18) + ru32(output) * 2)))) * getShortToFloat());
            } else {
                const primary = shortInterpToFloat(ad, output);
                wf32(output + 0x0C, primary);
                const bw = rf32(brt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(ad + 0x02) == -1) {
                    findInterpIdx(this, ru32(brt_base + BR.sec_time), ru32(brt_base + BR.sec_track), ad, output + 0x10);
                    const secondary = shortInterpToFloat(ad, output + 0x10);
                    wf32(output + 0x1C, secondary);
                    wf32(output + 0x0C, @mulAdd(f32, secondary - primary, bw, primary));
                }
            }
        }
    }
}

fn wordAnimLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x6C);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x70);
    const brt_base = ru32(this + SO.bone_rt_base);
    const out_base = ru32(this + SO.scale1);
    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({ i += 1; data_off += 0x1C; out_off += 0x20; }) {
        const ad = data_base + data_off;
        const output = out_base + out_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(ad + 0x0C)) {
            findInterpIdx(this, ru32(brt_base + BR.prim_time), ru32(brt_base + BR.prim_track), ad, output);
            const kf = ru32(ad + 0x18);
            wu16(output + 0x0C, ru16(kf + ru32(output) * 2));
            if (ri16(ad) != 0) {
                const bw = rf32(brt_base + BR.blend_weight);
                if (bw != 0.0 and ri16(ad + 0x02) == -1) {
                    findInterpIdx(this, ru32(brt_base + BR.sec_time), ru32(brt_base + BR.sec_track), ad, output + 0x10);
                    wu16(output + 0x1C, ru16(kf + ru32(output + 0x10) * 2));
                }
            }
        }
    }
}

fn boneKeyframeLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x74);
    if (count == 0) return;
    if ((ru8(0xCF04C4) & 1) == 0) {
        wu8(0xCF04C4, ru8(0xCF04C4) | 1);
        wu32(0xCF043C, 0x3F000000);
        wu32(0xCF0440, 0x3F000000);
        wu32(0xCF0444, 0x00000000);
        const initFn: *const fn (u32) callconv(.c) void = @ptrFromInt(0x409AEF);
        initFn(0x7187E0);
    }
    const data_base = ru32(model_hdr + 0x78);
    const brt_base = ru32(this + SO.bone_rt_base);
    const scale2_base = ru32(this + SO.scale2);
    const scale3_base = ru32(this + SO.scale3);
    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    var mat_off: u32 = 0;
    while (i < count) : ({ i += 1; data_off += 0x54; out_off += 0x98; mat_off += 0x40; }) {
        const kf = data_base + data_off;
        const output = scale2_base + out_off;
        const mat_out = scale3_base + mat_off;
        setIdentity(mat_out);
        if (ru32(kf + 0x28) != 0) {
            interpAnimKF(this, brt_base, kf + 0x1C, output + 0x30);
            applyTranslationFromPtr(mat_out, 0xCF043C);
            rotateByQuaternionFromPtr(mat_out, output + 0x3C);
            applyTranslation(mat_out, -rf32(0xCF043C), -rf32(0xCF0440), -rf32(0xCF0444));
        }
        if (ru32(kf + 0x44) != 0) {
            interpVec3Track(this, brt_base, kf + 0x38, output + 0x68, ufloat(ru32(brt_base + BR.blend_weight)));
            applyTranslationFromPtr(mat_out, 0xCF043C);
            scaleMatrix3x3FromPtr(mat_out, output + 0x74);
            applyTranslation(mat_out, -rf32(0xCF043C), -rf32(0xCF0440), -rf32(0xCF0444));
        }
        if (ru32(kf + 0x0C) != 0) {
            interpVec3Track(this, brt_base, kf, output, ufloat(ru32(brt_base + BR.blend_weight)));
            applyTranslationFromPtr(mat_out, output + 0x0C);
        }
    }
}

fn particleLoops(this: u32, model_hdr: u32) void {
    ribbonEmitterLoop(this, model_hdr);
    particleEmitterLoop(this, model_hdr);
    additionalParticleLoops(this, model_hdr);
}

fn ribbonEmitterLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x11C);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x120);
    const out_base = ru32(this + SO.field_200);
    const brt_base = ru32(this + SO.bone_rt_base);
    const frame_ctr = ru32(this + SO.anim_frame_ctr);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const entry = data_base + i * 0xD4;
        const output = out_base + i * 0x170;
        const bone_idx = @as(u32, ru16(entry + 2));
        const bone_rt = brt_base + bone_idx * 0x118;

        if (ru32(output + 0x100) != 0) {
            if (ru32(entry + 0xC4) != 0) {
                findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), entry + 0xB8, output + 0xE0);
                wu8(output + 0xEC, ru8(ru32(entry + 0xD0) + ru32(output + 0xE0)));
                if (ri16(entry + 0xB8) != 0) {
                    if (rf32(bone_rt + BR.blend_weight) != 0.0 and ri16(entry + 0xBA) == -1) {
                        findInterpIdx(this, ru32(bone_rt + BR.sec_time), ru32(bone_rt + BR.sec_track), entry + 0xB8, output + 0xF0);
                        wu8(output + 0xFC, ru8(ru32(entry + 0xD0) + ru32(output + 0xF0)));
                    }
                }
            }
        }

        const should_process = (ru32(output + 0x100) != 0 and ru8(output + 0xEC) != 0) or frame_ctr == 0;
        if (!should_process) continue;

        if (frame_ctr < ru32(entry + 0x38)) interpFloatTrack(this, bone_rt, entry + 0x2C, output + 0x30, ufloat(ru32(bone_rt + BR.blend_weight)));
        if (frame_ctr < ru32(entry + 0x1C)) {
            interpVec3Track(this, bone_rt, entry + 0x10, output, ufloat(ru32(bone_rt + BR.blend_weight)));
            const s = rf32(output + 0x3C) * rf32(this + SO.render_scale_z);
            wf32(output + 0x134, rf32(output + 0x0C) * s); wf32(output + 0x138, rf32(output + 0x10) * s); wf32(output + 0x13C, rf32(output + 0x14) * s);
        }
        if (frame_ctr < ru32(entry + 0x70)) interpFloatTrack(this, bone_rt, entry + 0x64, output + 0x80, ufloat(ru32(bone_rt + BR.blend_weight)));
        if (frame_ctr < ru32(entry + 0x54)) {
            interpVec3Track(this, bone_rt, entry + 0x48, output + 0x50, ufloat(ru32(bone_rt + BR.blend_weight)));
            const s = rf32(output + 0x8C) * rf32(this + SO.render_scale_z);
            wf32(output + 0x140, rf32(output + 0x5C) * s); wf32(output + 0x144, rf32(output + 0x60) * s); wf32(output + 0x148, rf32(output + 0x64) * s);
        }
    }
}

fn particleEmitterLoop(this: u32, model_hdr: u32) void {
    const count = ru32(model_hdr + 0x124);
    if (count == 0) return;
    const data_base = ru32(model_hdr + 0x128);
    const out_base = ru32(this + SO.particle1);
    const brt_base = ru32(this + SO.bone_rt_base);
    const frame_ctr = ru32(this + SO.anim_frame_ctr);
    var i: u32 = 0;
    var data_off: u32 = 0;
    var out_off: u32 = 0;
    while (i < count) : ({ i += 1; data_off += 0x7C; out_off += 0x84; }) {
        const entry = data_base + data_off;
        const output = out_base + out_off;
        if (frame_ctr < ru32(entry + 0x1C)) interpVec3Track36(this, brt_base, entry + 0x10, output);
        if (frame_ctr < ru32(entry + 0x44)) interpVec3Track36(this, brt_base, entry + 0x38, output + 0x30);
        if (frame_ctr < ru32(entry + 0x6C)) interpFloatTrack12(this, brt_base, entry + 0x60, output + 0x60);
    }
}

fn additionalParticleLoops(this: u32, model_hdr: u32) void {
    // Section 0x134
    if (ru32(model_hdr + 0x134) != 0) {
        const cnt = ru32(model_hdr + 0x134);
        const db = ru32(model_hdr + 0x138);
        const ob = ru32(this + 0x3C8);
        const brt_base = ru32(this + SO.bone_rt_base);
        var i: u32 = 0;
        var doff: u32 = 0;
        var ooff: u32 = 0;
        while (i < cnt) : ({ i += 1; doff += 0xDC; ooff += 0xD0; }) {
            const entry = db + doff;
            const output = ob + ooff;
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xCC)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                findInterpIdx(this, ru32(brt + 0x98), ru32(brt + 0x9C), entry + 0xC0, output + 0xB0);
                if (ri16(entry + 0xC0) == 0) {
                    wu8(output + 0xBC, ru8(ru32(entry + 0xC0 + 0x18) + ru32(output + 0xB0)));
                } else {
                    wu8(output + 0xBC, ru8(ru32(output + 0xB0) + ru32(entry + 0xD8)));
                    if (rf32(brt + 0x10C) != 0.0 and ri16(entry + 0xC2) == -1) {
                        findInterpIdx(this, ru32(brt + 0xC4), ru32(brt + 0xC8), entry + 0xC0, output + 0xC0);
                        wu8(output + 0xCC, ru8(ru32(output + 0xC0) + ru32(entry + 0xD8)));
                    }
                }
            }
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x30)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                interpVec3Track(this, brt, entry + 0x24, output, ufloat(ru32(brt + BR.blend_weight)));
            }
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x4C)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                findInterpIdx(this, ru32(brt + 0x98), ru32(brt + 0x9C), entry + 0x40, output + 0x30);
                const kf_base = ru32(entry + 0x40 + AD.keyframe_base);
                const s2f = getShortToFloat();
                if (ri16(entry + 0x40) == 0) {
                    wf32(output + 0x3C, @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output + 0x30) * 2)))) * s2f);
                } else {
                    const t = ufloat(ru32(output + 0x38));
                    const v0 = @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output + 0x30) * 2)))) * s2f;
                    const v1 = @as(f32, @floatFromInt(@as(i32, ri16(kf_base + ru32(output + 0x34) * 2)))) * s2f;
                    wf32(output + 0x3C, @mulAdd(f32, v1 - v0, t, v0));
                }
            }
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x68)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                interpFloatTrack(this, brt, entry + 0x5C, output + 0x50, ufloat(ru32(brt + BR.blend_weight)));
            }
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x84)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                interpFloatTrack(this, brt, entry + 0x78, output + 0x70, ufloat(ru32(brt + BR.blend_weight)));
            }
            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xB0)) {
                const bi = @as(u32, ru16(entry + 0x04));
                const brt = brt_base + bi * 0x118;
                findInterpIdx(this, ru32(brt + 0x98), ru32(brt + 0x9C), entry + 0xA4, output + 0x90);
                const kf_base = ru32(entry + 0xA4 + AD.keyframe_base);
                wu16(output + 0x9C, ru16(kf_base + ru32(output + 0x90) * 2));
                if (ri16(entry + 0xA4) != 0) {
                    if (rf32(brt + 0x10C) != 0.0 and ri16(entry + 0xA6) == -1) {
                        findInterpIdx(this, ru32(brt + 0xC4), ru32(brt + 0xC8), entry + 0xA4, output + 0xA0);
                        wu16(output + 0xAC, ru16(kf_base + ru32(output + 0xA0) * 2));
                    }
                }
            }
        }
    }

    wu32(this + 0x3D8, 0);

    // Section 0x13C
    const count1 = ru32(model_hdr + 0x13C);
    if (count1 != 0) {
        const db = ru32(model_hdr + 0x140);
        const brt_base = ru32(this + SO.bone_rt_base);
        const pb = ru32(this + 0x3D0);
        var i: u32 = 0;
        var doff: u32 = 0;
        var ooff: u32 = 0;
        while (i < count1) : ({ i += 1; doff += 0x1F8; ooff += 0x16C; }) {
            const entry = db + doff;
            const output = pb + ooff;
            const bi = @as(u32, ru16(entry + 0x14));
            const brt = brt_base + bi * 0x118;
            const pp = ru32(this + 0x3D4);
            const local_14 = ru32(pp + i * 4);

            if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x1E8)) {
                findInterpIdx(this, ru32(brt + 0x98), ru32(brt + 0x9C), entry + 0x1DC, output + 0x140);
                if (ri16(entry + 0x1DC) == 0) {
                    wu8(output + 0x14C, ru8(ru32(entry + 0x1F4) + ru32(output + 0x140)));
                } else {
                    wu8(output + 0x14C, ru8(ru32(output + 0x140) + ru32(entry + 0x1F4)));
                    if (rf32(brt + 0x10C) != 0.0 and ri16(entry + 0x1DE) == -1) {
                        findInterpIdx(this, ru32(brt + 0xC4), ru32(brt + 0xC8), entry + 0x1DC, output + 0x150);
                        wu8(output + 0x15C, ru8(ru32(entry + 0x1F4) + ru32(output + 0x150)));
                    }
                }
            }

            const vis = ru8(output + 0x14C);
            const ea: u32 = if (vis != 0 and ru32(this + 0x50) != 0) 1 else 0;
            wu32(output + 0x160, ea);
            var ba: u32 = 0;
            if (ea != 0) {
                ba = 1;
            } else {
                const isEmptyFn: *const fn (u32) callconv(.{ .x86_fastcall = .{} }) u32 = @ptrFromInt(0x7B5F60);
                if (isEmptyFn(local_14) != 0) ba = 1;
            }
            wu32(output + 0x164, ba);
            wu32(this + 0x3D8, ru32(this + 0x3D8) | ba);

            if (vis != 0 or ru32(this + SO.anim_frame_ctr) == 0) {
                const bw = ufloat(ru32(brt + BR.blend_weight));
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x40)) interpFloatTrack(this, brt, entry + 0x34, output, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x5C)) interpFloatTrack(this, brt, entry + 0x50, output + 0x20, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x78)) interpFloatTrack(this, brt, entry + 0x6C, output + 0x40, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x94)) interpFloatTrack(this, brt, entry + 0x88, output + 0x60, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xB0)) interpFloatTrack(this, brt, entry + 0xA4, output + 0x80, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xCC)) interpFloatTrack(this, brt, entry + 0xC0, output + 0xA0, bw);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0xE8)) getInterpolatedFloat(this, brt, entry + 0xDC, output + 0xC0);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x104)) getInterpolatedFloat(this, brt, entry + 0xF8, output + 0xE0);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x120)) getInterpolatedFloat(this, brt, entry + 0x114, output + 0x100);
                if (ru32(this + SO.anim_frame_ctr) < ru32(entry + 0x13C)) getInterpolatedFloat(this, brt, entry + 0x130, output + 0x120);
            }
        }
    }
}

fn attachmentRecursion(this: u32, model_hdr: u32, bone_out_base: u32) void {
    const hierarchy = ru32(this + SO.hierarchy_ptr);
    if (hierarchy == 0) return;

    const attach_count = ru32(model_hdr + 0x104);
    const attach_data = ru32(model_hdr + 0x108);

    var att_i: u32 = 0;
    var att_off: u32 = 0;
    while (att_i < attach_count) : ({ att_i += 1; att_off += 0x30; }) {
        const att_entry = attach_data + att_off;
        if (ru32(this + SO.anim_frame_ctr) < ru32(att_entry + 0x20)) {
            const bi = @as(u32, ru16(att_entry + 4));
            const brt = ru32(this + SO.bone_rt_base) + bi * 0x118;
            extractByte(this, brt, att_entry + 0x14, hierarchy + att_i * 0x20);
        }
    }

    var child = ru32(this + SO.hierarchy_idx);
    while (child != 0) {
        const attach_idx = ru32(child + 0x1D4);
        if (attach_idx != 0xFFFF) {
            if (ru8(hierarchy + attach_idx * 0x20 + 0x0C) != 0) {
                const att_entry = attach_data + attach_idx * 0x30;
                const bi = @as(u32, ru16(att_entry + 4));
                const bone_mat = bone_out_base + bi * 0x40;
                var local: [16]f32 align(16) = undefined;
                for (0..16) |fi| local[fi] = rf32(bone_mat + @as(u32, @intCast(fi)) * 4);
                const ox = rf32(att_entry + 8);
                const oy = rf32(att_entry + 0xC);
                const oz = rf32(att_entry + 0x10);
                local[12] += @mulAdd(f32, local[8], oz, @mulAdd(f32, local[4], oy, local[0] * ox));
                local[13] += @mulAdd(f32, local[9], oz, @mulAdd(f32, local[5], oy, local[1] * ox));
                local[14] += @mulAdd(f32, local[10], oz, @mulAdd(f32, local[6], oy, local[2] * ox));
                transformMatrix4x4_SSE(child, @intFromPtr(&local), this + SO.world_pos, this + SO.render_pri, ru32(this + SO.render_scale_z));
            }
        }
        child = ru32(child + 0x1E4);
    }
}
