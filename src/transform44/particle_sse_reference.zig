//! particle_sse — SSE replacements for WoW 1.12.1 particle rendering pipeline.
//!
//! Compiled as a separate ReleaseFast unit (same pattern as bone_sse.zig / clip_sse.zig).
//! Functions are exported and called via `extern fn` from transform44.zig detour hooks.
//!
//! Assembly references: decompiled/asm_RenderParticleSprites.txt,
//!   decomp_RenderParticleSprites.c, decomp_particle_helpers.c
//!
//! Faithful recreation of RenderParticleSprites (0x7B2A50, 2688 bytes).
//! Every section verified against assembly. Optimization comes later —
//! first priority is byte-identical output.

const std = @import("std");
const V4 = @Vector(4, f32);
const CC = std.builtin.CallingConvention;
const TC: CC = .{ .x86_thiscall = .{} };
const FC: CC = .{ .x86_fastcall = .{} };

inline fn rf32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}
inline fn ri32(addr: u32) i32 {
    return @as(*align(1) const i32, @ptrFromInt(addr)).*;
}
inline fn ru8(addr: u32) u8 {
    return @as(*const u8, @ptrFromInt(addr)).*;
}
inline fn ru16(addr: u32) u16 {
    return @as(*align(1) const u16, @ptrFromInt(addr)).*;
}
inline fn ru32(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}
inline fn wf32(addr: u32, val: f32) void {
    @as(*align(1) f32, @ptrFromInt(addr)).* = val;
}
inline fn wu32(addr: u32, val: u32) void {
    @as(*align(1) u32, @ptrFromInt(addr)).* = val;
}
inline fn wu8(addr: u32, val: u8) void {
    @as(*u8, @ptrFromInt(addr)).* = val;
}

// =============================================================================
// Emitter struct offsets (this = ECX = ParticleSystemRenderer*)
// Assembly-derived from [edi+N] references in asm_RenderParticleSprites.txt
// =============================================================================
const E = struct {
    const uvCoordScale: u32 = 0x0C; // shift count for texture V index
    const texScaleU: u32 = 0x10; // texture U scale factor
    const texScaleV: u32 = 0x14; // texture V scale factor
    const colorCtxBase: u32 = 0xBC; // base of color/orientation data array
    const rotation_offset: u32 = 0x18C; // rotation angle scale
    const particle_count_mask: u32 = 0x19C; // mask for particle index extraction
    const orientation_base: u32 = 0x1A8; // orientation data ptr
    const flags: u32 = 0x1AC; // rendering flags (u32)
    const particle_size: u32 = 0x1B0; // base particle size
    const visibility: u32 = 0x1B4; // visibility threshold
    const alpha_scale: u32 = 0x1B8; // alpha scale offset
    const alpha_value: u32 = 0x1C0; // alpha value
    const extra_scale: u32 = 0x264; // additional scale factor
    const rotation_axis: u32 = 0x284; // rotation axis vec3 (for 3D rotation path)
    const tail_distance: u32 = 0xB4; // tail particle max distance
};

// =============================================================================
// Global addresses
// =============================================================================
const G = struct {
    const float_1_0: u32 = 0x7FF9D8; // 1.0f
    const zero_threshold: u32 = 0x7FFD74; // 0.0f (collision plane zero)
    const max_particle_size: u32 = 0x7FFE58; // max clamp for particle size
    const rounding_magic: u32 = 0x8029CC; // float-to-byte magic number
    const depth_buffer: u32 = 0xCF58F0; // g_particleDepthBuffer (128 floats)
    const world_matrix: u32 = 0xCF5B68; // g_worldMatrix (4x4)
    const light_dir_x: u32 = 0xCF5878; // g_lightDirectionX
    const light_dir_y: u32 = 0xCF587C; // g_lightDirectionY
    const light_dir_z: u32 = 0xCF5880; // g_lightDirectionZ
    // Billboard vertex offset lookup tables (4 vertices × {x,y} = 8 floats each table)
    const billboard_offsets_x: u32 = 0x87D714; // g_billboardVertexOffsetsX (stride 8 per vertex)
    const billboard_offsets_y: u32 = 0x87D718; // g_billboardVertexOffsetsY
    // 3D billboard offset table (4 vertices × {x,y,z} = 12 floats)
    const billboard_3d: u32 = 0x87D738; // g_transformedVertex table (stride 8 per vertex for 2D ref)
    const billboard_3d_base: u32 = 0xCF5B30; // secondary 3D table base (-4/0/+4 indexed)
    // Sprite texture offset lookup (4 vertices × {u,v})
    const sprite_tex_u: u32 = 0x87D72C; // texture U offsets (stride 8)
    const sprite_tex_v: u32 = 0x87D730; // texture V offsets (stride 8)
    // Tail particle texture data
    const tail_tex_u0: u32 = 0x87D744; // tail tex offsets per vertex
    const tail_tex_v0: u32 = 0x87D748;
    const tail_tex_u1: u32 = 0x87D74C;
    const tail_tex_v1: u32 = 0x87D750;
    const tail_threshold: u32 = 0x80C744; // minimum velocity squared for tail rendering
};

// =============================================================================
// Game function pointers (called from RenderParticleSprites)
// =============================================================================

/// calculateParticleColorAndScale (0x7B9B10)
/// __thiscall(ECX=colorCtx, stack: time, scale, outColor, outAlpha1, outAlpha2, outFloat)
const calcColorFn = *const fn (u32, u32, u32, u32, u32, u32, u32) callconv(TC) void;
const calcColor: calcColorFn = @ptrFromInt(0x7B9B10);

/// UpdateLightingOffset / setupRenderState (0x58A230)
/// __cdecl() → returns ptr (used to check [ret+0x1C])
const setupRenderFn = *const fn () callconv(.{ .x86_stdcall = .{} }) u32;
const setupRender: setupRenderFn = @ptrFromInt(0x58A230);

/// transformVector3ByMatrix4x4 (0x7BCA80)
/// __fastcall(ECX=out, EDX=vec3, stack=mat4x4ptr), RET 0x4
const transformVec3Fn = *const fn (u32, u32, u32) callconv(FC) u32;
const transformVec3: transformVec3Fn = @ptrFromInt(0x7BCA80);

/// createAxisAngleRotationMatrix3x3 (0x7BE490)
/// __fastcall(ECX=outMat9, EDX=axisVec3, stack=angle_f32, isNormalized_char), RET 0x8
/// Note: angle is passed as f32 bits on stack, isNormalized as u32 (char in low byte)
const createRotMatFn = *const fn (u32, u32, u32, u32) callconv(FC) u32;
const createRotMat: createRotMatFn = @ptrFromInt(0x7BE490);

/// transformVector4ByMatrix4x4 (0x7BCB40)
/// __fastcall(ECX=out, EDX=vec3, stack=mat4x4ptr), RET 0x4
const transformVec4Fn = *const fn (u32, u32, u32) callconv(FC) u32;
const transformVec4: transformVec4Fn = @ptrFromInt(0x7BCB40);

// =============================================================================
// VertexBuffers struct — the vertexBuffers parameter
// =============================================================================
// vertexBuffers is a float** (array of pointers):
//   [0] = vertexPos ptr    (3 floats per vertex: x,y,z)
//   [1] = normalPtr        (3 floats: light direction)
//   [2] = colorPtr         (1 u32: packed BGRA color)
//   [3] = texCoordPtr      (2 floats: u,v)
//   [4] = vertexStride     (bytes to advance vertex ptr)
//   [5] = normalStride     (bytes to advance normal ptr)
//   [6] = colorStride      (bytes to advance color ptr)
//   [7] = texCoordStride   (bytes to advance texcoord ptr)
//   [8] = vertexCount      (incremented per vertex emitted)
const VB = struct {
    const pos: u32 = 0;
    const normal: u32 = 4;
    const color: u32 = 8;
    const texcoord: u32 = 12;
    const pos_stride: u32 = 16;
    const normal_stride: u32 = 20;
    const color_stride: u32 = 24;
    const texcoord_stride: u32 = 28;
    const count: u32 = 32;
};

/// Emit one vertex: write position, normal (light dir), color, texcoord, advance pointers.
inline fn emitVertex(vb: u32, px: f32, py: f32, pz: f32, color: u32, tu: f32, tv: f32) void {
    // Position
    const pos_ptr = ru32(vb + VB.pos);
    wf32(pos_ptr, px);
    wf32(pos_ptr + 4, py);
    wf32(pos_ptr + 8, pz);
    // Normal (light direction — global, same for all particles)
    const norm_ptr = ru32(vb + VB.normal);
    wu32(norm_ptr, ru32(G.light_dir_x));
    wu32(norm_ptr + 4, ru32(G.light_dir_y));
    wu32(norm_ptr + 8, ru32(G.light_dir_z));
    // Color
    wu32(ru32(vb + VB.color), color);
    // Texcoords
    const tc_ptr = ru32(vb + VB.texcoord);
    wf32(tc_ptr, tu);
    wf32(tc_ptr + 4, tv);
    // Advance pointers and increment count
    wu32(vb + VB.count, ru32(vb + VB.count) + 1);
    wu32(vb + VB.pos, ru32(vb + VB.pos) + ru32(vb + VB.pos_stride));
    wu32(vb + VB.normal, ru32(vb + VB.normal) + ru32(vb + VB.normal_stride));
    wu32(vb + VB.color, ru32(vb + VB.color) + ru32(vb + VB.color_stride));
    wu32(vb + VB.texcoord, ru32(vb + VB.texcoord) + ru32(vb + VB.texcoord_stride));
}

// =============================================================================
// RenderParticleSprites (0x7B2A50)
// __thiscall(ECX=emitter, stack=particleData, vertexBuffers), RET 0x8
// Returns: 0 (culled) or 1 (rendered)
//
// Faithful recreation from assembly + Ghidra decompilation.
// =============================================================================
export fn renderParticleSprites_REF(emitter: u32, particle_data: u32, vertex_buffers: u32) callconv(TC) u32 {
    const pd = particle_data; // particleData pointer (float*)
    const vb = vertex_buffers; // vertexBuffers pointer (float**)

    // =========================================================================
    // Section 1: Early-out visibility checks (asm 0x7B2A5E-0x7B2B0B)
    // =========================================================================

    // Check visibility threshold: emitter+0x1B4 < 1.0
    var depth_index: u32 = 0;

    if (rf32(emitter + E.visibility) < rf32(G.float_1_0) or
        rf32(emitter + E.alpha_value) != rf32(G.zero_threshold))
    {
        // Compute clamped particle size
        var clamped_size: f32 = rf32(emitter + E.particle_size) * rf32(pd + 0x1C);
        if (clamped_size < rf32(G.zero_threshold)) {
            clamped_size = rf32(G.zero_threshold);
        } else if (clamped_size >= rf32(G.max_particle_size)) {
            clamped_size = rf32(G.max_particle_size);
        }
        // Float-to-index conversion: add magic, extract bits, combine with particle data hash
        const size_with_magic = clamped_size + rf32(G.rounding_magic);
        depth_index = ((@as(u32, @bitCast(size_with_magic)) >> 14) + (particle_data >> 5)) & 0x7F;
    }

    // Depth buffer cull check
    if (rf32(emitter + E.visibility) < rf32(G.float_1_0) and
        rf32(emitter + E.visibility) < rf32(G.depth_buffer + depth_index * 4))
    {
        return 0;
    }

    // =========================================================================
    // Section 2: Calculate color and scale (asm 0x7B2B0E-0x7B2B41)
    // =========================================================================

    // Compute colorCtx address: emitter + 0xBC + byte(particleData[0x0C]) * 96
    // Assembly: movzx eax,byte[ebx+0xC]; lea ecx,[eax+eax*2]; shl ecx,5; lea ecx,[ecx+edi+0xBC]
    const color_ctx_offset: u32 = @as(u32, ru8(pd + 0x0C)) * 96;
    const color_ctx = emitter + E.colorCtxBase + color_ctx_offset;

    // Read orientation/scale data from emitter+0x1A8 — passed directly as arg2 to calcColor
    const orientation_data = ru32(emitter + E.orientation_base);

    var color_value: u32 = 0;
    var color_data1: u32 = 0;
    var color_data2: u32 = 0;
    var sprite_scale: f32 = undefined;

    // calcColor: __thiscall(ECX=colorCtx, stack: time, orientData, outColor, outAlpha1, outAlpha2, outFloat)
    calcColor(color_ctx, @bitCast(rf32(pd + 0x1C)), orientation_data,
        @intFromPtr(&color_value), @intFromPtr(&color_data1), @intFromPtr(&color_data2), @intFromPtr(&sprite_scale));

    // =========================================================================
    // Section 3: Render state setup (asm 0x7B2B46)
    // =========================================================================

    const render_state = setupRender();

    // =========================================================================
    // Section 4: Color byte swizzle (asm 0x7B2B4B-0x7B2B6E)
    // If render_state[0x1C] == 1, swizzle BGRA → RGBA
    // =========================================================================

    if (ru32(render_state + 0x1C) == 1) {
        const b0: u8 = @truncate(color_value);
        const b1: u8 = @truncate(color_value >> 8);
        const b2: u8 = @truncate(color_value >> 16);
        const b3: u8 = @truncate(color_value >> 24);
        // Swizzle: [B,G,R,A] → [R,B,A,G] (based on asm byte shuffling)
        color_value = @as(u32, b2) | (@as(u32, b0) << 8) | (@as(u32, b3) << 16) | (@as(u32, b1) << 24);
    }

    // =========================================================================
    // Section 5: Alpha/size scaling (asm 0x7B2B71-0x7B2BB1)
    // =========================================================================

    if (rf32(emitter + E.alpha_value) != rf32(G.zero_threshold)) {
        sprite_scale = (rf32(G.depth_buffer + depth_index * 4) * rf32(emitter + E.alpha_value) +
            rf32(emitter + E.alpha_scale)) * sprite_scale;
    }

    // Read full flags as u32 for subsequent checks
    const full_flags = ru32(emitter + E.flags);

    // Extra scale factor if flag 0x200 set
    if ((full_flags & 0x200) != 0) {
        sprite_scale = sprite_scale * rf32(emitter + E.extra_scale);
    }

    // =========================================================================
    // Section 6: Position transform (asm 0x7B2BB4-0x7B2BC3)
    // Transform particle world position through view matrix
    // =========================================================================

    var world_pos: [3]f32 = undefined;
    _ = transformVec3(@intFromPtr(&world_pos), pd, G.world_matrix);

    // =========================================================================
    // Section 7: Branch on flag 0x4 — sprite vs tail rendering
    // =========================================================================

    if ((full_flags & 0x4) == 0) {
        // No sprite rendering — jump to tail check at section 9
    } else {
        // =====================================================================
        // Section 7a: Texture coordinate setup (asm 0x7B2BD5-0x7B2C05)
        // =====================================================================

        const count_mask = ru32(emitter + E.particle_count_mask) - 1;
        const tex_index_raw = color_data1;
        const tex_u_index: f32 = @floatFromInt(count_mask & tex_index_raw);
        const shift_count: u5 = @truncate(ru32(emitter + E.uvCoordScale));
        const tex_v_raw: i32 = @as(i32, @bitCast(tex_index_raw)) >> shift_count;
        const tex_v_index: f32 = @floatFromInt(tex_v_raw);

        const tex_u_base = tex_u_index * rf32(emitter + E.texScaleU);
        const tex_v_base = tex_v_index * rf32(emitter + E.texScaleV);
        const tex_scale_u = rf32(emitter + E.texScaleU);
        const tex_scale_v = rf32(emitter + E.texScaleV);

        // Check rotation angle: if emitter+0x18C == 0.0, no rotation needed
        const has_rotation = rf32(emitter + E.rotation_offset) != rf32(G.zero_threshold);

        if (!has_rotation) {
            // =================================================================
            // Section 8a: No rotation — check 2D vs 3D billboard
            // =================================================================

            if ((full_flags & 0x2000) == 0) {
                // --- 2D billboard (asm 0x7B2D10-0x7B2DD5) ---
                // 4 vertices. Position uses [eax+0x87D714/718], but eax is incremented
                // by 8 BEFORE the Y read and texcoord reads. So texcoords use eax+8.
                // Assembly: eax starts at 0, adds 8 between X and Y reads.
                //   X: [eax+0x87D714], eax+=8, Y: [eax+0x87D710]=[eax_new+0x87D710]
                //   texU: [eax+0x87D72C], texV: [eax+0x87D730] (eax already incremented)
                var loop_off: u32 = 0;
                while (loop_off < 0x20) : (loop_off += 8) {
                    const ox = rf32(G.billboard_offsets_x + loop_off); // [eax+0x87D714]
                    const oy = rf32(G.billboard_offsets_y + loop_off); // [eax+8+0x87D710]
                    const vx = sprite_scale * ox + world_pos[0];
                    const vy = sprite_scale * oy + world_pos[1];
                    // Texcoords use eax+8 offset (eax already incremented in original)
                    const tu = rf32(G.sprite_tex_u + loop_off + 8) * tex_scale_u + tex_u_base;
                    const tv = rf32(G.sprite_tex_v + loop_off + 8) * tex_scale_v + tex_v_base;
                    emitVertex(vb, vx, vy, world_pos[2], color_value, tu, tv);
                }
            } else {
                // --- 3D billboard (asm 0x7B2C25-0x7B2D04) ---
                // 4 vertices, using 3D offset table
                const table_base: u32 = G.billboard_3d;
                const ref_base: u32 = G.billboard_3d_base;
                var vert: u32 = 0;
                while (vert < 4) : (vert += 1) {
                    const tbl = ref_base + vert * 12; // stride 0xC per vertex in ref table
                    const ox = sprite_scale * rf32(tbl - 4);
                    const oy = sprite_scale * rf32(tbl);
                    const oz = sprite_scale * rf32(tbl + 4);
                    const vx = ox + world_pos[0];
                    const vy = oy + world_pos[1];
                    const vz = oz + world_pos[2];

                    const pos_ptr = ru32(vb + VB.pos);
                    wf32(pos_ptr, vx);
                    wf32(pos_ptr + 4, vy);
                    wf32(pos_ptr + 8, vz);
                    const norm_ptr = ru32(vb + VB.normal);
                    wu32(norm_ptr, ru32(G.light_dir_x));
                    wu32(norm_ptr + 4, ru32(G.light_dir_y));
                    wu32(norm_ptr + 8, ru32(G.light_dir_z));
                    wu32(ru32(vb + VB.color), color_value);

                    const tc_ptr = ru32(vb + VB.texcoord);
                    const tu_off: u32 = table_base + vert * 8 - 4; // asm uses stride 8, offset -4
                    const tv_off: u32 = table_base + vert * 8;
                    wf32(tc_ptr, rf32(tu_off) * tex_scale_u + tex_u_base);
                    wf32(tc_ptr + 4, rf32(tv_off) * tex_scale_v + tex_v_base);

                    wu32(vb + VB.count, ru32(vb + VB.count) + 1);
                    wu32(vb + VB.pos, ru32(vb + VB.pos) + ru32(vb + VB.pos_stride));
                    wu32(vb + VB.normal, ru32(vb + VB.normal) + ru32(vb + VB.normal_stride));
                    wu32(vb + VB.color, ru32(vb + VB.color) + ru32(vb + VB.color_stride));
                    wu32(vb + VB.texcoord, ru32(vb + VB.texcoord) + ru32(vb + VB.texcoord_stride));
                }
            }
        } else {
            // =================================================================
            // Section 8b: With rotation
            // =================================================================

            // Compute rotation angle: emitter+0x18C * particleData[7]
            var rot_angle = rf32(emitter + E.rotation_offset) * rf32(pd + 0x1C);

            // Negate if flags indicate (asm 0x7B2DE8-0x7B2DF4)
            const flag_byte: i8 = @bitCast(@as(u8, @truncate(full_flags >> 8)));
            if (flag_byte < 0 and (particle_data & 0x20) != 0) {
                rot_angle = -rot_angle;
            }

            if ((full_flags & 0x2000) == 0) {
                // --- 2D billboard with sin/cos rotation (asm 0x7B2F49-0x7B303B) ---
                const cos_val = @cos(rot_angle);
                const sin_val = @sin(rot_angle);
                const scaled_sin = sin_val * sprite_scale;
                const scaled_cos = cos_val * sprite_scale;

                var loop_off: u32 = 0;
                while (loop_off < 0x20) : (loop_off += 8) {
                    const ox = rf32(G.billboard_offsets_x + loop_off);
                    const oy = rf32(G.billboard_offsets_y + loop_off);
                    // Rotated billboard: x' = ox*cos - oy*sin, y' = oy*cos + ox*sin
                    const vx = @mulAdd(f32, ox, scaled_cos, world_pos[0]) - oy * scaled_sin;
                    const vy = @mulAdd(f32, oy, scaled_cos, @mulAdd(f32, ox, scaled_sin, world_pos[1]));
                    // Texcoords use eax+8 offset (eax incremented before tex reads in original)
                    const tu = rf32(G.sprite_tex_u + loop_off + 8) * tex_scale_u + tex_u_base;
                    const tv = rf32(G.sprite_tex_v + loop_off + 8) * tex_scale_v + tex_v_base;
                    emitVertex(vb, vx, vy, world_pos[2], color_value, tu, tv);
                }
            } else {
                // --- 3D billboard with rotation matrix (asm 0x7B2E00-0x7B2F41) ---
                // Build rotation matrix from axis + angle, then transform each vertex
                var rot_mat: [9]f32 = undefined;
                _ = createRotMat(@intFromPtr(&rot_mat), emitter + E.rotation_axis,
                    @bitCast(rot_angle), 1);

                const ref_base: u32 = G.billboard_3d_base;
                const tex_off_base: u32 = G.billboard_3d; // reused for tex offsets

                var vert: u32 = 0;
                while (vert < 4) : (vert += 1) {
                    const tbl = ref_base + vert * 12;
                    const ix = rf32(tbl - 4);
                    const iy = rf32(tbl);
                    const iz = rf32(tbl + 4);

                    // mat3x3 * vec3
                    const rx = (rot_mat[0] * ix + rot_mat[1] * iy + rot_mat[2] * iz) * sprite_scale;
                    const ry = (rot_mat[3] * ix + rot_mat[4] * iy + rot_mat[5] * iz) * sprite_scale;
                    const rz = (rot_mat[6] * ix + rot_mat[7] * iy + rot_mat[8] * iz) * sprite_scale;

                    const vx = rx + world_pos[0];
                    const vy = ry + world_pos[1];
                    const vz = rz + world_pos[2];

                    const pos_ptr = ru32(vb + VB.pos);
                    wf32(pos_ptr, vx);
                    wf32(pos_ptr + 4, vy);
                    wf32(pos_ptr + 8, vz);
                    const norm_ptr = ru32(vb + VB.normal);
                    wu32(norm_ptr, ru32(G.light_dir_x));
                    wu32(norm_ptr + 4, ru32(G.light_dir_y));
                    wu32(norm_ptr + 8, ru32(G.light_dir_z));
                    wu32(ru32(vb + VB.color), color_value);

                    const tc_ptr = ru32(vb + VB.texcoord);
                    const tu_off: u32 = tex_off_base + vert * 8 - 4;
                    const tv_off: u32 = tex_off_base + vert * 8;
                    wf32(tc_ptr, rf32(tu_off) * tex_scale_u + tex_u_base);
                    wf32(tc_ptr + 4, rf32(tv_off) * tex_scale_v + tex_v_base);

                    wu32(vb + VB.count, ru32(vb + VB.count) + 1);
                    wu32(vb + VB.pos, ru32(vb + VB.pos) + ru32(vb + VB.pos_stride));
                    wu32(vb + VB.normal, ru32(vb + VB.normal) + ru32(vb + VB.normal_stride));
                    wu32(vb + VB.color, ru32(vb + VB.color) + ru32(vb + VB.color_stride));
                    wu32(vb + VB.texcoord, ru32(vb + VB.texcoord) + ru32(vb + VB.texcoord_stride));
                }
            }
        }
    }

    // =========================================================================
    // Section 9: Tail particle rendering (asm 0x7B3041-0x7B34C5)
    // Flag 0x8 in emitter+0x1AC: velocity-based trail
    // =========================================================================

    if ((ru8(emitter + E.flags) & 0x8) != 0) {
        // Tail particles: compute from velocity direction
        const count_mask = ru32(emitter + E.particle_count_mask) - 1;
        const tex_index_raw = color_data2;
        const tex_u_index: f32 = @floatFromInt(count_mask & tex_index_raw);
        const shift_count: u5 = @truncate(ru32(emitter + E.uvCoordScale));
        const tex_v_raw: i32 = @as(i32, @bitCast(tex_index_raw)) >> shift_count;
        const tail_tex_u = tex_u_index * rf32(emitter + E.texScaleU);
        const tail_tex_v: f32 = @as(f32, @floatFromInt(tex_v_raw)) * rf32(emitter + E.texScaleV);

        // Negate velocity vector
        const neg_vel_x: f32 = -rf32(pd + 0x10); // particleData[4]
        const neg_vel_y: f32 = -rf32(pd + 0x14); // particleData[5]
        const neg_vel_z: f32 = -rf32(pd + 0x18); // particleData[6]

        // Get tail distance, clamp by particleData[7] if flag 0x1 set
        var tail_dist: f32 = @bitCast(ru32(emitter + E.tail_distance));
        const tail_flag_byte = ru8(emitter + E.flags + 2); // byte at +0x1AE
        if ((tail_flag_byte & 0x1) != 0 and rf32(pd + 0x1C) < tail_dist) {
            tail_dist = rf32(pd + 0x1C);
        }

        // Transform negated velocity through world matrix
        var neg_vel = [3]f32{ neg_vel_x, neg_vel_y, neg_vel_z };
        var transformed_vel: [4]f32 = undefined;
        _ = transformVec4(@intFromPtr(&transformed_vel), @intFromPtr(&neg_vel), G.world_matrix);

        const tx = tail_dist * transformed_vel[0];
        const ty = tail_dist * transformed_vel[1];
        const cos_sq = tx * tx + ty * ty;

        if (cos_sq >= rf32(G.tail_threshold)) {
            // Velocity-based trail: 4 vertices forming a quad along velocity direction
            const vel_z = tail_dist * transformed_vel[2] + world_pos[2];
            const inv_len = sprite_scale / @sqrt(cos_sq);
            const perp_x = tx * inv_len; // perpendicular to velocity
            const perp_y = inv_len * ty;

            const tex_su = rf32(emitter + E.texScaleU);
            const tex_sv = rf32(emitter + E.texScaleV);

            // Vertex 0: worldPos - perp
            emitVertex(vb, world_pos[0] - perp_y, perp_x + world_pos[1], world_pos[2], color_value,
                rf32(G.sprite_tex_u) * tex_su + tail_tex_u,
                rf32(G.sprite_tex_v) * tex_sv + tail_tex_v);
            // Vertex 1: worldPos + perp
            emitVertex(vb, world_pos[0] + perp_y, world_pos[1] - perp_x, world_pos[2], color_value,
                rf32(G.sprite_tex_u) * tex_su + tail_tex_u,
                rf32(G.sprite_tex_v) * tex_sv + tail_tex_v);
            // Vertex 2: worldPos + vel - perp
            emitVertex(vb, tx + world_pos[0] - perp_y, ty + world_pos[1] + perp_x, vel_z, color_value,
                rf32(G.tail_tex_u0) * tex_su + tail_tex_u,
                rf32(G.tail_tex_v0) * tex_sv + tail_tex_v);
            // Vertex 3: worldPos + vel + perp
            emitVertex(vb, tx + world_pos[0] + perp_y, ty + world_pos[1] - perp_x, vel_z, color_value,
                rf32(G.tail_tex_u1) * tex_su + tail_tex_u,
                rf32(G.tail_tex_v1) * tex_sv + tail_tex_v);

            return 1;
        }

        // Fallback: velocity too small for trail, render as flat billboard
        var loop_off: u32 = 0;
        const tex_su = rf32(emitter + E.texScaleU);
        const tex_sv = rf32(emitter + E.texScaleV);
        while (loop_off < 0x20) : (loop_off += 8) {
            const ox = rf32(G.billboard_offsets_x + loop_off);
            const oy = rf32(G.billboard_offsets_y + loop_off);
            const vx = sprite_scale * ox + world_pos[0];
            const vy = sprite_scale * oy + world_pos[1];
            const tu = rf32(G.sprite_tex_u + loop_off + 8) * tex_su + tail_tex_u;
            const tv = rf32(G.sprite_tex_v + loop_off + 8) * tex_sv + tail_tex_v;
            emitVertex(vb, vx, vy, world_pos[2], color_value, tu, tv);
        }
    }

    return 1;
}
