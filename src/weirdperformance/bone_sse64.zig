//! f64-intermediate port of transformMatrix4x4 (0x714260).
//!
//! Mirrors bone_sse.zig but holds intermediate bone matrices as [16]f64 and
//! runs all matrix-math operations in double precision, only narrowing to f32
//! when writing into the bone output buffer in game memory.
//!
//! Rounding profile matches the original x87 implementation: load f32, compute
//! in extended precision (here 53-bit mantissa f64 vs x87 64-bit mantissa —
//! indistinguishable once truncated to f32), store f32 once at the end.
//!
//! Interpolation, keyframe search, billboard math, ftol, and game-callback
//! helpers are imported from bone_sse since they produce f32 scalars that
//! widen implicitly when multiplied with f64 matrices.
//!
//! Compiled ReleaseFast with AVX enabled. Uses @Vector(4, f64) for SIMD
//! matrix multiplies on ymm registers.

const bone_sse = @import("bone_sse.zig");

const V4d = @Vector(4, f64);

// =============================================================================
// Imports from bone_sse — constants, memory helpers, interp/billboard helpers
// =============================================================================

const SO = bone_sse.SO;
const BR = bone_sse.BR;
const BD = bone_sse.BD;
const AD = bone_sse.AD;
const InterpResult = bone_sse.InterpResult;

const ru32 = bone_sse.ru32;
const ri32 = bone_sse.ri32;
const rf32 = bone_sse.rf32;
const ru16 = bone_sse.ru16;
const ri16 = bone_sse.ri16;
const ru8 = bone_sse.ru8;
const wu32 = bone_sse.wu32;
const wf32 = bone_sse.wf32;
const wu16 = bone_sse.wu16;
const wu8 = bone_sse.wu8;
const fbits = bone_sse.fbits;
const ufloat = bone_sse.ufloat;

const normalizeVec3 = bone_sse.normalizeVec3;
const normalizeVec3InPlace = bone_sse.normalizeVec3InPlace;
const crossVec3 = bone_sse.crossVec3;

const canReuseInterp = bone_sse.canReuseInterp;
const findInterpIdx = bone_sse.findInterpIdx;
const interpAnimKFCached = bone_sse.interpAnimKFCached;
const interpVec3TrackCached = bone_sse.interpVec3TrackCached;
const callFtol = bone_sse.callFtol;
const callVec3SqMag = bone_sse.callVec3SqMag;
const fastMod = bone_sse.fastMod;

const texAnimLoop = bone_sse.texAnimLoop;
const colorAnimLoop = bone_sse.colorAnimLoop;
const wordAnimLoop = bone_sse.wordAnimLoop;
const boneKeyframeLoop = bone_sse.boneKeyframeLoop;
const particleLoops = bone_sse.particleLoops;
// NOTE: we do NOT import bone_sse.attachmentRecursion — that version recurses
// into bone_sse.transformImpl_SSE (f32) directly, which would force attached
// child models onto the f32 path while the parent is f64. We reimplement it
// below so attachment recursion stays inside bone_sse64's f64 pipeline.

// =============================================================================
// f64 memory helpers
// =============================================================================

inline fn rf64(addr: u32) f64 {
    return @floatCast(rf32(addr));
}

inline fn wf32_narrow(addr: u32, v: f64) void {
    wf32(addr, @floatCast(v));
}

inline fn loadV4d(addr: u32) V4d {
    return V4d{ rf64(addr), rf64(addr + 4), rf64(addr + 8), rf64(addr + 12) };
}

inline fn storeV4d(addr: u32, v: V4d) void {
    wf32(addr + 0, @floatCast(v[0]));
    wf32(addr + 4, @floatCast(v[1]));
    wf32(addr + 8, @floatCast(v[2]));
    wf32(addr + 12, @floatCast(v[3]));
}

// =============================================================================
// f64 matrix operations
// =============================================================================

/// 4x4 matrix multiply: dst = a * b. Memory-to-memory with f64 intermediates.
inline fn matMul4x4_64(dst: u32, a: u32, b: u32) void {
    const b0 = loadV4d(b);
    const b1 = loadV4d(b + 16);
    const b2 = loadV4d(b + 32);
    const b3 = loadV4d(b + 48);
    const a0 = loadV4d(a);
    const a1 = loadV4d(a + 16);
    const a2 = loadV4d(a + 32);
    const a3 = loadV4d(a + 48);
    const rows = [4]V4d{ a0, a1, a2, a3 };

    inline for (0..4) |i| {
        const s0: V4d = @splat(rows[i][0]);
        const s1: V4d = @splat(rows[i][1]);
        const s2: V4d = @splat(rows[i][2]);
        const s3: V4d = @splat(rows[i][3]);
        const row = s0 * b0 + s1 * b1 + s2 * b2 + s3 * b3;
        const off: u32 = @intCast(i * 16);
        storeV4d(dst + off, row);
    }
}

/// 4x4 multiply: dst_mem = a_local * b_mem. Left operand is [16]f64 local.
inline fn matMul4x4Local_64(dst: u32, a: [16]f64, b: u32) void {
    const b0 = loadV4d(b);
    const b1 = loadV4d(b + 16);
    const b2 = loadV4d(b + 32);
    const b3 = loadV4d(b + 48);

    const rows = [4]V4d{
        V4d{ a[0], a[1], a[2], a[3] },
        V4d{ a[4], a[5], a[6], a[7] },
        V4d{ a[8], a[9], a[10], a[11] },
        V4d{ a[12], a[13], a[14], a[15] },
    };

    inline for (0..4) |i| {
        const s0: V4d = @splat(rows[i][0]);
        const s1: V4d = @splat(rows[i][1]);
        const s2: V4d = @splat(rows[i][2]);
        const s3: V4d = @splat(rows[i][3]);
        const row = s0 * b0 + s1 * b1 + s2 * b2 + s3 * b3;
        const off: u32 = @intCast(i * 16);
        storeV4d(dst + off, row);
    }
}

/// In-place f64 multiply: a = a * b_mem. Returns new [16]f64.
inline fn matMul4x4InPlace_64(a: [16]f64, b: u32) [16]f64 {
    const b0 = loadV4d(b);
    const b1 = loadV4d(b + 16);
    const b2 = loadV4d(b + 32);
    const b3 = loadV4d(b + 48);

    const rows = [4]V4d{
        V4d{ a[0], a[1], a[2], a[3] },
        V4d{ a[4], a[5], a[6], a[7] },
        V4d{ a[8], a[9], a[10], a[11] },
        V4d{ a[12], a[13], a[14], a[15] },
    };

    var result: [16]f64 = undefined;
    inline for (0..4) |i| {
        const s0: V4d = @splat(rows[i][0]);
        const s1: V4d = @splat(rows[i][1]);
        const s2: V4d = @splat(rows[i][2]);
        const s3: V4d = @splat(rows[i][3]);
        const row = s0 * b0 + s1 * b1 + s2 * b2 + s3 * b3;
        result[i * 4 + 0] = row[0];
        result[i * 4 + 1] = row[1];
        result[i * 4 + 2] = row[2];
        result[i * 4 + 3] = row[3];
    }
    return result;
}

/// Quaternion → 4x4 rotation matrix as f64 local. Identity last row/col.
inline fn buildRotationMatrix_64(qx: f64, qy: f64, qz: f64, qw: f64) [16]f64 {
    const xx2 = qx * (qx + qx);
    const xy2 = qx * (qy + qy);
    const xz2 = qx * (qz + qz);
    const yy2 = qy * (qy + qy);
    const yz2 = qy * (qz + qz);
    const zz2 = qz * (qz + qz);
    const wx2 = qw * (qx + qx);
    const wy2 = qw * (qy + qy);
    const wz2 = qw * (qz + qz);

    return [16]f64{
        1.0 - (yy2 + zz2), xy2 + wz2,         xz2 - wy2,         0.0,
        xy2 - wz2,         1.0 - (xx2 + zz2), yz2 + wx2,         0.0,
        xz2 + wy2,         yz2 - wx2,         1.0 - (xx2 + yy2), 0.0,
        0.0,               0.0,               0.0,               1.0,
    };
}

/// Copy a 4x4 matrix in game memory (bit-exact, no precision change).
inline fn copyMat4(dst: u32, src: u32) void {
    inline for (0..8) |i| {
        const off = @as(u32, @intCast(i)) * 8;
        @as(*u64, @ptrFromInt(dst + off)).* = @as(*const u64, @ptrFromInt(src + off)).*;
    }
}

// =============================================================================
// Attachment recursion — f64 version that re-enters transformImpl_SSE64 for
// child scene objects. Mirrors bone_sse.attachmentRecursion exactly except
// it calls our f64 implementation for child transforms.
// =============================================================================

fn attachmentRecursion64(this: u32, model_hdr: u32, bone_out_base: u32, frame_ctr: u32) void {
    @setEvalBranchQuota(50000);
    const hierarchy = ru32(this + SO.hierarchy_ptr);
    if (hierarchy == 0) return;

    const attach_count = ru32(model_hdr + 0x104);
    const attach_data = ru32(model_hdr + 0x108);

    var att_i: u32 = 0;
    var att_off: u32 = 0;
    while (att_i < attach_count) : ({
        att_i += 1;
        att_off += 0x30;
    }) {
        const att_entry = attach_data + att_off;
        if (frame_ctr < ru32(att_entry + 0x20)) {
            const bone_idx = @as(u32, ru16(att_entry + 4));
            const bone_rt = ru32(this + SO.bone_rt_base) + bone_idx * 0x118;
            const anim_data = att_entry + 0x14;
            const att_output = hierarchy + att_i * 0x20;
            const atr = findInterpIdx(this, ru32(bone_rt + 0x98), ru32(bone_rt + 0x9C), anim_data, att_output);
            wu8(att_output + 0x0C, ru8(ru32(anim_data + AD.keyframe_base) + atr.idx0));
        }
    }

    var child = ru32(this + SO.hierarchy_idx);
    while (child != 0) {
        const attach_idx = ru32(child + 0x1D4);

        if (attach_idx != 0xFFFF) {
            const visible = ru8(hierarchy + attach_idx * 0x20 + 0x0C);
            if (visible != 0) {
                const att_entry = attach_data + attach_idx * 0x30;
                const bone_idx = @as(u32, ru16(att_entry + 4));
                const bone_mat = bone_out_base + bone_idx * 0x40;

                // Copy parent bone matrix to local (f32, matches original).
                // The matrix itself is stored f32 in game memory; we preserve
                // that on the wire but widen to f64 for the offset math below.
                var local_1a0: [16]f32 = undefined;
                for (0..16) |fi| {
                    local_1a0[fi] = rf32(bone_mat + @as(u32, @intCast(fi)) * 4);
                }

                // Apply attachment offset translation in f64, narrow on store.
                const ox: f64 = @floatCast(rf32(att_entry + 8));
                const oy: f64 = @floatCast(rf32(att_entry + 0xC));
                const oz: f64 = @floatCast(rf32(att_entry + 0x10));
                const m0x: f64 = @floatCast(local_1a0[0]);
                const m4x: f64 = @floatCast(local_1a0[4]);
                const m8x: f64 = @floatCast(local_1a0[8]);
                const m1x: f64 = @floatCast(local_1a0[1]);
                const m5x: f64 = @floatCast(local_1a0[5]);
                const m9x: f64 = @floatCast(local_1a0[9]);
                const m2x: f64 = @floatCast(local_1a0[2]);
                const m6x: f64 = @floatCast(local_1a0[6]);
                const m10x: f64 = @floatCast(local_1a0[10]);
                local_1a0[12] = @floatCast(@as(f64, @floatCast(local_1a0[12])) + m0x * ox + m4x * oy + m8x * oz);
                local_1a0[13] = @floatCast(@as(f64, @floatCast(local_1a0[13])) + m1x * ox + m5x * oy + m9x * oz);
                local_1a0[14] = @floatCast(@as(f64, @floatCast(local_1a0[14])) + m2x * ox + m6x * oy + m10x * oz);

                // Recurse into the f64 implementation so attachment children stay
                // on the same precision path as the parent.
                transformImpl_SSE64(child, @intFromPtr(&local_1a0), this + SO.world_pos, this + SO.render_pri, ru32(this + SO.render_scale_z));
            }
        }

        child = ru32(child + 0x1E4);
    }
}

// =============================================================================
// Main entry point — f64-intermediate reimplementation.
//
// Follows the same structure as bone_sse.transformImpl_SSE. Per-bone work
// builds local_mat / local_mat2 as [16]f64 and uses the f64 matrix helpers
// above. Non-matrix helpers (interp, billboard, loops) are imported from
// bone_sse — their f32 outputs widen implicitly when used in f64 math.
// Attachment recursion is handled by a local f64 version (above) so child
// scene objects stay on the f64 pipeline.
// =============================================================================

pub fn transformImpl_SSE64(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
    @setEvalBranchQuota(50000);

    // Section 1: Entry checks
    if (ru32(this + SO.model_data_ptr) == 0) return;
    const anim_ctx = ru32(this + SO.anim_ctx_ptr);
    if (ru32(this + SO.sync_value) == ru32(anim_ctx + 0x10)) return;

    // Section 2: Emitter setup
    const model_ctr = ru32(this + SO.model_ctr_ptr);
    const model_hdr = ru32(model_ctr + 0x130);
    const emitter_ctx = ru32(this + SO.emitter_ctx);

    if (emitter_ctx != 0) {
        const has_emitter: u32 = if (ru32(emitter_ctx + 0x50) != 0 and ru32(this + 0x1D8) != 0) 1 else 0;
        wu32(this + 0x50, has_emitter);
        wu32(this + 0x17C, ru32(emitter_ctx + 0x17C));
    }

    // Section 3: World position/scale
    const pos_ptr = mat2;
    const ofs_ptr = mat3;
    const scale_f: f32 = @bitCast(mat4);

    wf32(this + SO.world_pos + 0, rf32(pos_ptr) * rf32(this + SO.field_184));
    wf32(this + SO.world_pos + 4, rf32(this + SO.field_188) * rf32(pos_ptr + 4));
    wf32(this + SO.world_pos + 8, @bitCast(fbits(rf32(this + SO.field_18c) * rf32(pos_ptr + 8))));

    const rp0 = rf32(ofs_ptr) + rf32(this + SO.field_190);
    const rp1 = rf32(this + SO.render_scale_x) + rf32(ofs_ptr + 4);
    const rp2 = rf32(this + SO.render_scale_y) + rf32(ofs_ptr + 8);
    wf32(this + SO.render_pri + 0, rp0);
    wf32(this + SO.render_pri + 4, rp1);
    wf32(this + SO.render_pri + 8, rp2);

    wf32(this + SO.render_scale_z, scale_f * rf32(this + SO.field_180));

    // Section 4: Global sequence processing
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

    // Root matrix multiply (f64 intermediates).
    // Replaces the original initParticlePixelShaderGeneration(0x74a7c0) dispatch.
    matMul4x4_64(this + 0xFC, this + 0xBC, mat1);

    // Section 5: child_objects_padding — compute in f64, narrow on store.
    // May be used as a culling threshold; matching precision keeps boundary
    // conditions stable across frames.
    const emitter_ctx_5 = ru32(this + SO.emitter_ctx);
    if (emitter_ctx_5 == 0 or (ru8(emitter_ctx_5 + 4) & 1) != 0) {
        const wx: f64 = rf64(this + SO.world_xform + 8 * 4);
        const wy: f64 = rf64(this + SO.world_xform + 9 * 4);
        const wz: f64 = rf64(this + SO.world_xform + 10 * 4);
        const len_sq: f32 = @floatCast(wx * wx + wy * wy + wz * wz);
        wu32(this + SO.child_padding, fbits(len_sq));
    } else {
        wu32(this + SO.child_padding, ru32(emitter_ctx_5 + 0x84));
    }

    // Section 6: Identity matrices as f64 locals + timestamp delta
    var local_mat: [16]f64 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };

    var local_mat2: [16]f64 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };

    var time_delta_val: u32 = 0;
    const sdb = ru32(this + SO.search_data_base);
    if (sdb != 0) {
        const cur_ts = ru32(anim_ctx + 0x0C);
        if (cur_ts != 0) {
            time_delta_val = cur_ts -% sdb;
            wu32(this + SO.search_data_base, cur_ts);
        }
    }

    // Section 7: Main bone loop
    const bone_count = ru32(model_hdr + 0x34);
    const bone_defs = ru32(model_hdr + 0x38);
    const bone_rt_base = ru32(this + SO.bone_rt_base);
    const bone_out_base = ru32(this + SO.bone_out_ptr);
    const frame_ctr = ru32(this + SO.anim_frame_ctr);

    if (bone_count != 0) {
        var bone_idx: u32 = 0;
        var bdef = bone_defs;
        var brt = bone_rt_base;
        while (bone_idx < bone_count) : ({
            bone_idx += 1;
            bdef += 0x6C;
            brt += 0x118;
        }) {
            const flags = ru32(bdef + BD.flags);
            const parent_idx_raw: i32 = @as(i32, @intCast(@as(i16, @bitCast(ru16(bdef + BD.parent_bone)))));

            // --- Animation time computation (primary slot) ---
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
                        const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xB0);
                        const frame = fastMod(@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8), anim_end -% anim_start);
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
                            const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xB0);
                            const frame = fastMod(@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xB8), anim_end -% anim_start);
                            wu32(brt + 0x98, anim_start +% frame);
                        } else {
                            wu32(brt + 0x98, anim_start);
                        }
                    } else {
                        const dur = sec_end_val -% sec_start_val;
                        const ftol_result = callFtol(@as(i32, @bitCast(dur)), brt + 0xB0);
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

            // --- Secondary slot ---
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
                        const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xDC);
                        const frame = fastMod(@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4), anim_end -% anim_start);
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
                            const ftol_result = callFtol(@as(i32, @bitCast(delta)), brt + 0xDC);
                            const frame = fastMod(@as(u32, @bitCast(ftol_result)) +% ru32(brt + 0xE4), anim_end -% anim_start);
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
                    const h = (3.0 - 2.0 * t_clamped) * t_clamped * t_clamped * ufloat(ru32(brt + BR.crossfade_weight));
                    wu32(brt + BR.blend_weight, fbits(h));
                }
            }

            // --- Parent bone transform inheritance ---
            const combined_flags: u32 = ru32(brt + BR.flags2) | flags;
            var src_mat: u32 = undefined;

            // Address of local_mat (as if it were a game-memory matrix — since the
            // matMul helpers read from memory, we write local_mat out to a scratch
            // f32 buffer when src_mat aliases it. The billboard path below stores
            // f32-narrowed values into local_mat's address via a scratch buffer.)
            var local_mat_f32: [16]f32 = undefined;
            const local_mat_addr = @intFromPtr(&local_mat_f32);

            if (ru16(bdef + BD.parent_bone) == 0xFFFF) {
                src_mat = this + 0xFC;
            } else {
                const parent_out = bone_out_base + @as(u32, @intCast(parent_idx_raw)) * 0x40;
                src_mat = parent_out;

                if ((combined_flags & 7) != 0) {
                    // Copy parent matrix to local_mat (f64 widen)
                    for (0..16) |i| {
                        local_mat[i] = rf64(parent_out + @as(u32, @intCast(i)) * 4);
                    }

                    const pivot_x: f64 = rf64(bdef + BD.pivot_x);
                    const pivot_y: f64 = rf64(bdef + BD.pivot_y);
                    const pivot_z: f64 = rf64(bdef + BD.pivot_z);

                    // Compute translated position — accumulation order must match
                    // original x87. Row 0 uses (pz + px + py), rows 1/2 use (pz + py + px).
                    const tx = local_mat[8] * pivot_z + local_mat[0] * pivot_x + local_mat[4] * pivot_y + local_mat[12];
                    const ty = local_mat[9] * pivot_z + local_mat[5] * pivot_y + local_mat[1] * pivot_x + local_mat[13];
                    const tz = local_mat[10] * pivot_z + local_mat[6] * pivot_y + local_mat[2] * pivot_x + local_mat[14];

                    const bb_type = combined_flags & 6;
                    const billboard_eps: f64 = @floatCast(rf32(0x008029d4));
                    const cull_eps: f64 = @floatCast(rf32(0x0080c5c8));
                    if (bb_type == 2) {
                        // Cylindrical billboard — normalize columns in f64 to match
                        // x87's extended-precision 1/sqrt pattern. Previous impl went
                        // f32→f32 through normalizeVec3; that diverged from x87 by
                        // up to a ULP per axis, which shifted particle emitter
                        // orientation each camera frame and caused transparency
                        // flicker against ground effects.
                        inline for ([_]u32{ 0, 4, 8 }) |row_off| {
                            const cx = local_mat[row_off];
                            const cy = local_mat[row_off + 1];
                            const cz = local_mat[row_off + 2];
                            const len_sq = cx * cx + cy * cy + cz * cz;
                            const len = @sqrt(len_sq);
                            if (len >= billboard_eps) {
                                const inv = 1.0 / len;
                                local_mat[row_off] = cx * inv;
                                local_mat[row_off + 1] = cy * inv;
                                local_mat[row_off + 2] = cz * inv;
                            }
                        }
                    } else if (bb_type == 4) {
                        // Spherical billboard — inherit camera basis, rescale to
                        // preserve original column length. Keep all intermediates
                        // in f64 matching x87's 80-bit temporaries.
                        inline for ([_]struct { row_off: u32, src_off: u32 }{
                            .{ .row_off = 0, .src_off = SO.bb_row0 },
                            .{ .row_off = 4, .src_off = SO.world_xform },
                            .{ .row_off = 8, .src_off = SO.world_xform + 16 },
                        }) |p| {
                            const src_addr = this + p.src_off;
                            const cam_x: f64 = rf64(src_addr);
                            const cam_y: f64 = rf64(src_addr + 4);
                            const cam_z: f64 = rf64(src_addr + 8);
                            const cam_len_sq = cam_x * cam_x + cam_y * cam_y + cam_z * cam_z;
                            var s: f64 = 1.0;
                            if (cam_len_sq > cull_eps) {
                                const mx = local_mat[p.row_off];
                                const my = local_mat[p.row_off + 1];
                                const mz = local_mat[p.row_off + 2];
                                const mat_len_sq = mx * mx + my * my + mz * mz;
                                s = @sqrt(mat_len_sq / cam_len_sq);
                            }
                            local_mat[p.row_off] = s * cam_x;
                            local_mat[p.row_off + 1] = s * cam_y;
                            local_mat[p.row_off + 2] = s * cam_z;
                        }
                    } else if (bb_type == 6) {
                        local_mat[0] = rf64(this + SO.bb_row0);
                        local_mat[1] = rf64(this + SO.bb_row0 + 4);
                        local_mat[2] = rf64(this + SO.bb_row0 + 8);
                        local_mat[4] = rf64(this + SO.world_xform + 0 * 4);
                        local_mat[5] = rf64(this + SO.world_xform + 1 * 4);
                        local_mat[6] = rf64(this + SO.world_xform + 2 * 4);
                        local_mat[8] = rf64(this + SO.world_xform + 4 * 4);
                        local_mat[9] = rf64(this + SO.world_xform + 5 * 4);
                        local_mat[10] = rf64(this + SO.world_xform + 6 * 4);
                    }

                    // Recompute translation — mirror accumulation order of tx/ty/tz above.
                    if ((combined_flags & 1) == 0) {
                        local_mat[12] = tx - (local_mat[8] * pivot_z + local_mat[0] * pivot_x + local_mat[4] * pivot_y);
                        local_mat[13] = ty - (local_mat[9] * pivot_z + local_mat[5] * pivot_y + local_mat[1] * pivot_x);
                        local_mat[14] = tz - (local_mat[10] * pivot_z + local_mat[6] * pivot_y + local_mat[2] * pivot_x);
                    } else {
                        local_mat[12] = rf64(this + SO.world_xform + 8 * 4);
                        local_mat[13] = rf64(this + SO.world_xform + 9 * 4);
                        local_mat[14] = rf64(this + SO.world_xform + 10 * 4);
                    }

                    // Narrow local_mat to f32 scratch, set src_mat to its address
                    for (0..16) |i| {
                        local_mat_f32[i] = @floatCast(local_mat[i]);
                    }
                    src_mat = local_mat_addr;
                }
            }

            // --- Rotation / Scale / Translation / Final multiply ---
            if ((combined_flags & 0x280) == 0) {
                const dst = bone_out_base + bone_idx * 0x40;
                copyMat4(dst, src_mat);
            } else {
                const rot_anim = bdef + BD.rot_anim;
                const rot_kf_count = ru32(bdef + BD.rot_nts);

                var rot_primary_cache: ?InterpResult = null;

                if (rot_kf_count != 0) {
                    if (frame_ctr < rot_kf_count) {
                        const rot_output = brt + BR.rot_idx0;
                        const r = findInterpIdx(this, ru32(brt + BR.prim_time), ru32(brt + BR.prim_track), rot_anim, rot_output);
                        rot_primary_cache = r;
                        const q = interpAnimKFCached(this, brt, rot_anim, rot_output, r);
                        local_mat2 = buildRotationMatrix_64(q[0], q[1], q[2], q[3]);
                    } else {
                        local_mat2 = buildRotationMatrix_64(rf64(brt + BR.rot_x), rf64(brt + BR.rot_y), rf64(brt + BR.rot_z), rf64(brt + BR.rot_w));
                    }
                } else {
                    local_mat2 = .{
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    };
                }

                // Step 2: Scale interpolation — f64 arithmetic
                const scale_anim = bdef + BD.scale_anim;
                const scale_kf_count = ru32(bdef + BD.scale_nts);
                if (scale_kf_count != 0) {
                    var sx: f64 = undefined;
                    var sy: f64 = undefined;
                    var sz: f64 = undefined;
                    if (frame_ctr < scale_kf_count) {
                        const scale_cache = if (rot_primary_cache != null and canReuseInterp(rot_anim, scale_anim)) rot_primary_cache else null;
                        const s = interpVec3TrackCached(this, brt, scale_anim, brt + BR.scale_idx0, ufloat(ru32(brt + BR.blend_weight)), scale_cache);
                        sx = s[0]; sy = s[1]; sz = s[2];
                    } else {
                        sx = rf64(brt + BR.scale_x); sy = rf64(brt + BR.scale_y); sz = rf64(brt + BR.scale_z);
                    }
                    local_mat2[0] *= sx; local_mat2[1] *= sx; local_mat2[2] *= sx;
                    local_mat2[4] *= sy; local_mat2[5] *= sy; local_mat2[6] *= sy;
                    local_mat2[8] *= sz; local_mat2[9] *= sz; local_mat2[10] *= sz;
                }

                // Conditional bone-flag matrix multiply (f64 in-place)
                if ((@as(i8, @bitCast(@as(u8, @truncate(combined_flags)))) < 0) and ru32(brt + BR.bone_flag_cache) != 0) {
                    local_mat2 = matMul4x4InPlace_64(local_mat2, ru32(brt + BR.bone_flag_cache));
                }

                // Step 3: Translation interpolation (f64)
                var tx_val: f64 = rf64(bdef + BD.pivot_x);
                var ty_val: f64 = rf64(bdef + BD.pivot_y);
                var tz_val: f64 = rf64(bdef + BD.pivot_z);

                const trans_anim = bdef + BD.trans_anim;
                const trans_kf_count = ru32(bdef + BD.trans_nts);
                if (trans_kf_count != 0) {
                    if (frame_ctr < trans_kf_count) {
                        const trans_cache = if (rot_primary_cache != null and canReuseInterp(rot_anim, trans_anim)) rot_primary_cache else null;
                        const t = interpVec3TrackCached(this, brt, trans_anim, brt + BR.trans_idx0, ufloat(ru32(brt + BR.blend_weight)), trans_cache);
                        tx_val += @as(f64, t[0]);
                        ty_val += @as(f64, t[1]);
                        tz_val += @as(f64, t[2]);
                    } else {
                        tx_val += rf64(brt + BR.trans_x);
                        ty_val += rf64(brt + BR.trans_y);
                        tz_val += rf64(brt + BR.trans_z);
                    }
                }

                // Step 4: Translation offset using ROTATED+SCALED matrix (f64)
                const piv_x: f64 = rf64(bdef + BD.pivot_x);
                const piv_y: f64 = rf64(bdef + BD.pivot_y);
                const piv_z: f64 = rf64(bdef + BD.pivot_z);
                local_mat2[12] = tx_val - (local_mat2[0] * piv_x + local_mat2[4] * piv_y + local_mat2[8] * piv_z);
                local_mat2[13] = ty_val - (local_mat2[1] * piv_x + local_mat2[5] * piv_y + local_mat2[9] * piv_z);
                local_mat2[14] = tz_val - (local_mat2[2] * piv_x + local_mat2[6] * piv_y + local_mat2[10] * piv_z);

                // Final: dst = bone_local * parent (f64 mul, narrow on store)
                matMul4x4Local_64(bone_out_base + bone_idx * 0x40, local_mat2, src_mat);
            }

            // --- Billboard post-processing (flags & 0x78) ---
            if ((combined_flags & 0x78) != 0) {
                const out_off = bone_idx * 0x40;
                const om = bone_out_base + out_off;

                const scale_len0 = @sqrt(callVec3SqMag(om));
                const scale_len1 = @sqrt(callVec3SqMag(om + 0x10));
                const scale_len2 = @sqrt(callVec3SqMag(om + 0x20));

                const bpx = rf32(bdef + BD.pivot_x);
                const bpy = rf32(bdef + BD.pivot_y);
                const bpz = rf32(bdef + BD.pivot_z);
                // Accumulation order mirrors original x87:
                //   pos_x: px + py + pz + const
                //   pos_y: py + pz + px + const
                //   pos_z: py + pz + px + const
                const pos_x = bpx * rf32(om) + bpy * rf32(om + 0x10) + bpz * rf32(om + 0x20) + rf32(om + 0x30);
                const pos_y = bpy * rf32(om + 0x14) + bpz * rf32(om + 0x24) + bpx * rf32(om + 0x04) + rf32(om + 0x34);
                const pos_z = bpy * rf32(om + 0x18) + bpz * rf32(om + 0x28) + bpx * rf32(om + 0x08) + rf32(om + 0x38);

                const bb_post = combined_flags & 0x78;
                switch (bb_post) {
                    0x08 => {
                        const had_anim = (combined_flags & 0x280) != 0;
                        if (!had_anim) {
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
                            // Row 0 = {local_e4, local_e0, -local_e8}
                            const r0x: f32 = @floatCast(local_mat2[1]);
                            const r0y: f32 = @floatCast(local_mat2[2]);
                            const r0z: f32 = @floatCast(-local_mat2[0]);
                            wf32(om, r0x);
                            wf32(om + 0x04, r0y);
                            wf32(om + 0x08, r0z);
                            normalizeVec3InPlace(om);
                            const r1x: f32 = @floatCast(local_mat2[5]);
                            const r1y: f32 = @floatCast(local_mat2[6]);
                            const r1z: f32 = @floatCast(-local_mat2[4]);
                            wf32(om + 0x10, r1x);
                            wf32(om + 0x14, r1y);
                            wf32(om + 0x18, r1z);
                            normalizeVec3InPlace(om + 0x10);
                            const r2x: f32 = @floatCast(local_mat2[9]);
                            const r2y: f32 = @floatCast(local_mat2[10]);
                            const r2z: f32 = @floatCast(-local_mat2[8]);
                            wf32(om + 0x20, r2x);
                            wf32(om + 0x24, r2y);
                            wf32(om + 0x28, r2z);
                            normalizeVec3InPlace(om + 0x20);
                        }
                    },
                    0x10 => {
                        normalizeVec3InPlace(om);
                        const r0x = rf32(om);
                        const r0y = rf32(om + 0x04);
                        wf32(om + 0x10, r0y);
                        wf32(om + 0x14, -r0x);
                        wf32(om + 0x18, 0);
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x20 => {
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om, -rf32(om + 0x14));
                        wf32(om + 0x04, rf32(om + 0x10));
                        wf32(om + 0x08, 0);
                        normalizeVec3InPlace(om);
                        wf32(om + 0x20, rf32(om + 0x08) * rf32(om + 0x14) - rf32(om + 0x04) * rf32(om + 0x18));
                        wf32(om + 0x24, rf32(om) * rf32(om + 0x18) - rf32(om + 0x08) * rf32(om + 0x10));
                        wf32(om + 0x28, rf32(om + 0x04) * rf32(om + 0x10) - rf32(om) * rf32(om + 0x14));
                    },
                    0x40 => {
                        normalizeVec3InPlace(om + 0x20);
                        wf32(om + 0x10, rf32(om + 0x24));
                        wf32(om + 0x14, -rf32(om + 0x20));
                        wf32(om + 0x18, 0);
                        normalizeVec3InPlace(om + 0x10);
                        wf32(om, rf32(om + 0x24) * rf32(om + 0x18) - rf32(om + 0x28) * rf32(om + 0x14));
                        wf32(om + 0x04, rf32(om + 0x28) * rf32(om + 0x10) - rf32(om + 0x20) * rf32(om + 0x18));
                        wf32(om + 0x08, rf32(om + 0x20) * rf32(om + 0x14) - rf32(om + 0x24) * rf32(om + 0x10));
                    },
                    else => {},
                }

                // Apply scale lengths back and recompute translation
                wf32(om + 0x0C, 0);
                wf32(om + 0x1C, 0);
                wf32(om + 0x2C, 0);
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

                // Accumulation order must match original x87: row0 + row2 + row1
                // (pivot_x, then pivot_z, then pivot_y). f32 addition isn't associative —
                // this ordering is load-bearing for spell-effect z-fighting avoidance.
                wf32(om + 0x30, pos_x - (scale_len0 * r0x_s * bpx + scale_len2 * r2x_s * bpz + scale_len1 * r1x_s * bpy));
                wf32(om + 0x34, pos_y - (scale_len0 * r0y_s * bpx + scale_len2 * r2y_s * bpz + scale_len1 * r1y_s * bpy));
                wf32(om + 0x38, pos_z - (scale_len0 * r0z_s * bpx + scale_len2 * r2z_s * bpz + scale_len1 * r1z_s * bpy));
                wf32(om + 0x3C, 1.0);
            }
        }
    }

    // Sections 8-13: delegated to bone_sse's f32 implementations.
    texAnimLoop(this, model_hdr, frame_ctr);
    colorAnimLoop(this, model_hdr, frame_ctr);
    wordAnimLoop(this, model_hdr, frame_ctr);
    boneKeyframeLoop(this, model_hdr);
    particleLoops(this, model_hdr, frame_ctr);
    attachmentRecursion64(this, model_hdr, bone_out_base, frame_ctr);

    wu32(this + SO.sync_value, ru32(anim_ctx + 0x10));
}
