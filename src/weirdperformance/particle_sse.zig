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
inline fn loadV4(ptr: u32) V4 {
    return @as(*align(1) const V4, @ptrFromInt(ptr)).*;
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

/// Cached vertex buffer state — avoids re-reading pointer array per vertex.
/// Load once at start, emit vertices via direct pointer math, write back at end.
const VBState = struct {
    pos: u32,
    normal: u32,
    color_ptr: u32,
    texcoord: u32,
    pos_stride: u32,
    normal_stride: u32,
    color_stride: u32,
    texcoord_stride: u32,
    count: u32,
    vb: u32, // base pointer for writeback
    // Cached light direction (same for all vertices)
    light: [3]u32,

    fn load(vb: u32) VBState {
        return .{
            .pos = ru32(vb + VB.pos),
            .normal = ru32(vb + VB.normal),
            .color_ptr = ru32(vb + VB.color),
            .texcoord = ru32(vb + VB.texcoord),
            .pos_stride = ru32(vb + VB.pos_stride),
            .normal_stride = ru32(vb + VB.normal_stride),
            .color_stride = ru32(vb + VB.color_stride),
            .texcoord_stride = ru32(vb + VB.texcoord_stride),
            .count = ru32(vb + VB.count),
            .vb = vb,
            .light = .{ ru32(G.light_dir_x), ru32(G.light_dir_y), ru32(G.light_dir_z) },
        };
    }

    fn emit(s: *VBState, px: f32, py: f32, pz: f32, color: u32, tu: f32, tv: f32) void {
        // Vertex layout is interleaved 24 bytes: xyz(12) + color(4) + uv(8).
        // All strides are 24 except normal (0, shared global).
        // Write contiguously when stride == 24 and layout matches.
        if (s.pos_stride == 24 and s.color_ptr == s.pos + 12 and s.texcoord == s.pos + 16) {
            // Fast path: contiguous 24-byte vertex. V4 store for xyz+color (16 bytes),
            // then 2 scalar stores for uv (8 bytes). Unaligned V4 store via vmovups.
            const xyzc = V4{ px, py, pz, @bitCast(color) };
            @as(*align(1) V4, @ptrFromInt(s.pos)).* = xyzc;
            wf32(s.pos + 16, tu);
            wf32(s.pos + 20, tv);
            s.pos += 24;
            s.color_ptr += 24;
            s.texcoord += 24;
        } else {
            // Fallback: scattered writes
            wf32(s.pos, px);
            wf32(s.pos + 4, py);
            wf32(s.pos + 8, pz);
            wu32(s.color_ptr, color);
            wf32(s.texcoord, tu);
            wf32(s.texcoord + 4, tv);
            s.pos += s.pos_stride;
            s.color_ptr += s.color_stride;
            s.texcoord += s.texcoord_stride;
        }
        // Normal: stride=0 means shared global, write once (handled in writeback)
        if (s.normal_stride != 0) {
            wu32(s.normal, s.light[0]);
            wu32(s.normal + 4, s.light[1]);
            wu32(s.normal + 8, s.light[2]);
            s.normal += s.normal_stride;
        }
        s.count += 1;
    }

    fn writeback(s: *const VBState) void {
        // Write normal once if stride==0 (shared global — same for all vertices)
        if (s.normal_stride == 0) {
            wu32(s.normal, s.light[0]);
            wu32(s.normal + 4, s.light[1]);
            wu32(s.normal + 8, s.light[2]);
        }
        wu32(s.vb + VB.pos, s.pos);
        wu32(s.vb + VB.normal, s.normal);
        wu32(s.vb + VB.color, s.color_ptr);
        wu32(s.vb + VB.texcoord, s.texcoord);
        wu32(s.vb + VB.count, s.count);
    }
};

/// Emit one vertex using the old pointer-chasing path (for code paths not yet converted to VBState).
inline fn emitVertex(vb: u32, px: f32, py: f32, pz: f32, color: u32, tu: f32, tv: f32) void {
    const pos_ptr = ru32(vb + VB.pos);
    wf32(pos_ptr, px);
    wf32(pos_ptr + 4, py);
    wf32(pos_ptr + 8, pz);
    const norm_ptr = ru32(vb + VB.normal);
    wu32(norm_ptr, ru32(G.light_dir_x));
    wu32(norm_ptr + 4, ru32(G.light_dir_y));
    wu32(norm_ptr + 8, ru32(G.light_dir_z));
    wu32(ru32(vb + VB.color), color);
    const tc_ptr = ru32(vb + VB.texcoord);
    wf32(tc_ptr, tu);
    wf32(tc_ptr + 4, tv);
    wu32(vb + VB.count, ru32(vb + VB.count) + 1);
    wu32(vb + VB.pos, ru32(vb + VB.pos) + ru32(vb + VB.pos_stride));
    wu32(vb + VB.normal, ru32(vb + VB.normal) + ru32(vb + VB.normal_stride));
    wu32(vb + VB.color, ru32(vb + VB.color) + ru32(vb + VB.color_stride));
    wu32(vb + VB.texcoord, ru32(vb + VB.texcoord) + ru32(vb + VB.texcoord_stride));
}

// Cached render state — setupRender() returns the same pointer all frame.
// Reset each frame via resetParticleCache() called from the frame hook.
var cached_render_state: u32 = 0;


/// Reset per-frame caches. Call from OnWorldUpdate or executeSceneRenderPass hook.
pub fn resetParticleCache() void {
    cached_render_state = 0;
}


// =============================================================================
// RenderParticleSprites (0x7B2A50)
// __thiscall(ECX=emitter, stack=particleData, vertexBuffers), RET 0x8
// Returns: 0 (culled) or 1 (rendered)
//
// Faithful recreation from assembly + Ghidra decompilation.
// =============================================================================
pub fn renderParticleSprites_SSE(emitter: u32, particle_data: u32, vertex_buffers: u32) callconv(TC) u32 {
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

    // Inline calcColor: compute color, alpha, and sprite scale from colorCtx
    // Original at 0x7B9B10, assembly-verified. Inlined to allow OoO overlap with cache misses.
    const scale_param: f32 = @bitCast(ru32(emitter + E.orientation_base)); // arg2: float scale for alpha
    const time_val: f32 = rf32(pd + 0x1C);

    // t = (time - ctx.timeBase) * ctx.timeScale * CONST1 + CONST2
    const t = (time_val - rf32(color_ctx + 0x2C)) * rf32(color_ctx + 0x30) * rf32(0x808AAC) + rf32(0x807A3C);
    const magic: f32 = rf32(G.rounding_magic);

    // Color channels: (float)delta * t + (float)base [+ magic], extract byte via >>14
    // Alpha (byte 3): scaled by scale_param
    const alpha_f = @mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x04))), t,
        @as(f32, @floatFromInt(@as(i32, ru8(color_ctx + 3))))) * scale_param + magic;
    // Red (byte 2): no scale
    const red_f = @mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x08))), t,
        @as(f32, @floatFromInt(@as(i32, ru8(color_ctx + 2))))) + magic;
    // Green (byte 1):
    const green_f = @mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x0C))), t,
        @as(f32, @floatFromInt(@as(i32, ru8(color_ctx + 1))))) + magic;
    // Blue (byte 0):
    const blue_f = @mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x10))), t,
        @as(f32, @floatFromInt(@as(i32, ru8(color_ctx + 0))))) + magic;

    var color_value: u32 = ((@as(u32, @bitCast(blue_f)) >> 14) & 0xFF) |
        (((@as(u32, @bitCast(green_f)) >> 14) & 0xFF) << 8) |
        (((@as(u32, @bitCast(red_f)) >> 14) & 0xFF) << 16) |
        (((@as(u32, @bitCast(alpha_f)) >> 14) & 0xFF) << 24);

    // Sprite scale: t * ctx.scaleDelta + ctx.scaleBase
    var sprite_scale: f32 = @mulAdd(f32, t, rf32(color_ctx + 0x28), rf32(color_ctx + 0x24));

    // Alpha outputs (color_data1, color_data2) — used for texture index
    var color_data1: u32 = undefined;
    var color_data2: u32 = undefined;
    const alpha_power = ru32(color_ctx + 0x50);
    if (alpha_power == 0x3F800000) {
        // Fast path: alphaPower == 1.0 (linear)
        color_data1 = (@as(u32, @bitCast(@mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x18))), t,
            @as(f32, @floatFromInt(ri32(color_ctx + 0x14)))) + magic)) >> 14) & 0xFF;
        color_data2 = (@as(u32, @bitCast(@mulAdd(f32, @as(f32, @floatFromInt(ri32(color_ctx + 0x20))), t,
            @as(f32, @floatFromInt(ri32(color_ctx + 0x1C)))) + magic)) >> 14) & 0xFF;
    } else {
        // Slow path: pow scaling — fall back to game function call
        calcColor(color_ctx, @bitCast(time_val), @bitCast(ru32(emitter + E.orientation_base)),
            @intFromPtr(&color_value), @intFromPtr(&color_data1), @intFromPtr(&color_data2), @intFromPtr(&sprite_scale));
    }

    // =========================================================================
    // Section 3: Render state setup (asm 0x7B2B46)
    // Cached: the render state pointer doesn't change within a frame.
    // =========================================================================

    const render_state = blk: {
        if (cached_render_state != 0) break :blk cached_render_state;
        const rs = setupRender();
        cached_render_state = rs;
        break :blk rs;
    };

    // =========================================================================
    // Section 4: Color byte swizzle (asm 0x7B2B4B-0x7B2B6E)
    // If render_state[0x1C] == 1, swizzle BGRA → RGBA
    // =========================================================================

    if (ru32(render_state + 0x1C) == 1) {
        const b0: u8 = @truncate(color_value);
        const b1: u8 = @truncate(color_value >> 8);
        const b2: u8 = @truncate(color_value >> 16);
        const b3: u8 = @truncate(color_value >> 24);
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
    // Inline V4 mat*vec3: result = col0*v.x + col1*v.y + col2*v.z + col3
    // =========================================================================

    const pp: [*]const f32 = @ptrFromInt(pd);
    const pvx: V4 = @splat(pp[0]);
    const pvy: V4 = @splat(pp[1]);
    const pvz: V4 = @splat(pp[2]);
    const m: u32 = G.world_matrix;
    const wp = @mulAdd(V4, pvz, loadV4(m + 32), @mulAdd(V4, pvy, loadV4(m + 16), @mulAdd(V4, pvx, loadV4(m), loadV4(m + 48))));
    const world_pos = [3]f32{ wp[0], wp[1], wp[2] };

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
                // Unrolled — inline for lets LLVM schedule stores across vertices.
                {
                    var vs = VBState.load(vb);
                    const wpx = world_pos[0];
                    const wpy = world_pos[1];
                    const wpz = world_pos[2];
                    inline for (0..4) |i| {
                        const off: u32 = @intCast(i * 8);
                        vs.emit(
                            @mulAdd(f32, sprite_scale, rf32(G.billboard_offsets_x + off), wpx),
                            @mulAdd(f32, sprite_scale, rf32(G.billboard_offsets_y + off), wpy),
                            wpz,
                            color_value,
                            @mulAdd(f32, rf32(G.sprite_tex_u + off + 8), tex_scale_u, tex_u_base),
                            @mulAdd(f32, rf32(G.sprite_tex_v + off + 8), tex_scale_v, tex_v_base),
                        );
                    }
                    vs.writeback();
                }
            } else {
                // --- 3D billboard (asm 0x7B2C25-0x7B2D04) ---
                {
                    var vs = VBState.load(vb);
                    const table_base: u32 = G.billboard_3d;
                    const ref_base: u32 = G.billboard_3d_base;
                    var vert: u32 = 0;
                    while (vert < 4) : (vert += 1) {
                        const tbl = ref_base + vert * 12;
                        vs.emit(
                            @mulAdd(f32, sprite_scale, rf32(tbl - 4), world_pos[0]),
                            @mulAdd(f32, sprite_scale, rf32(tbl), world_pos[1]),
                            @mulAdd(f32, sprite_scale, rf32(tbl + 4), world_pos[2]),
                            color_value,
                            @mulAdd(f32, rf32(table_base + vert * 8 - 4), tex_scale_u, tex_u_base),
                            @mulAdd(f32, rf32(table_base + vert * 8), tex_scale_v, tex_v_base),
                        );
                    }
                    vs.writeback();
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

                {
                    var vs = VBState.load(vb);
                    const wpx = world_pos[0];
                    const wpy = world_pos[1];
                    const wpz = world_pos[2];
                    inline for (0..4) |i| {
                        const off: u32 = @intCast(i * 8);
                        const ox = rf32(G.billboard_offsets_x + off);
                        const oy = rf32(G.billboard_offsets_y + off);
                        vs.emit(
                            @mulAdd(f32, ox, scaled_cos, wpx) - oy * scaled_sin,
                            @mulAdd(f32, oy, scaled_cos, @mulAdd(f32, ox, scaled_sin, wpy)),
                            wpz,
                            color_value,
                            @mulAdd(f32, rf32(G.sprite_tex_u + off + 8), tex_scale_u, tex_u_base),
                            @mulAdd(f32, rf32(G.sprite_tex_v + off + 8), tex_scale_v, tex_v_base),
                        );
                    }
                    vs.writeback();
                }
            } else {
                // --- 3D billboard with rotation matrix (asm 0x7B2E00-0x7B2F41) ---
                // Build rotation matrix from axis + angle, then transform each vertex
                var rot_mat: [9]f32 = undefined;
                _ = createRotMat(@intFromPtr(&rot_mat), emitter + E.rotation_axis,
                    @bitCast(rot_angle), 1);

                {
                    var vs = VBState.load(vb);
                    const ref_base: u32 = G.billboard_3d_base;
                    const tex_off_base: u32 = G.billboard_3d;
                    var vert: u32 = 0;
                    while (vert < 4) : (vert += 1) {
                        const tbl = ref_base + vert * 12;
                        const ix = rf32(tbl - 4);
                        const iy = rf32(tbl);
                        const iz = rf32(tbl + 4);
                        // mat3x3 * vec3, scaled, + worldPos
                        vs.emit(
                            @mulAdd(f32, rot_mat[2], iz, @mulAdd(f32, rot_mat[1], iy, rot_mat[0] * ix)) * sprite_scale + world_pos[0],
                            @mulAdd(f32, rot_mat[5], iz, @mulAdd(f32, rot_mat[4], iy, rot_mat[3] * ix)) * sprite_scale + world_pos[1],
                            @mulAdd(f32, rot_mat[8], iz, @mulAdd(f32, rot_mat[7], iy, rot_mat[6] * ix)) * sprite_scale + world_pos[2],
                            color_value,
                            @mulAdd(f32, rf32(tex_off_base + vert * 8 - 4), tex_scale_u, tex_u_base),
                            @mulAdd(f32, rf32(tex_off_base + vert * 8), tex_scale_v, tex_v_base),
                        );
                    }
                    vs.writeback();
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
        // transformVec4 reads 4 components (x,y,z,w) from input - w must be 0.0
        var neg_vel = [4]f32{ neg_vel_x, neg_vel_y, neg_vel_z, 0.0 };
        var transformed_vel: [4]f32 = undefined;
        _ = transformVec4(@intFromPtr(&transformed_vel), @intFromPtr(&neg_vel), G.world_matrix);

        const tx = tail_dist * transformed_vel[0];
        const ty = tail_dist * transformed_vel[1];
        const cos_sq = tx * tx + ty * ty;

        if (cos_sq >= rf32(G.tail_threshold)) {
            // Velocity-based trail: 4 vertices forming a quad along velocity direction
            const vel_z = tail_dist * transformed_vel[2] + world_pos[2];
            const inv_len = sprite_scale / @sqrt(cos_sq);
            const perp_x = tx * inv_len;
            const perp_y = inv_len * ty;

            const tex_su = rf32(emitter + E.texScaleU);
            const tex_sv = rf32(emitter + E.texScaleV);

            var vs = VBState.load(vb);
            vs.emit(world_pos[0] - perp_y, perp_x + world_pos[1], world_pos[2], color_value,
                @mulAdd(f32, rf32(G.sprite_tex_u + 8), tex_su, tail_tex_u),
                @mulAdd(f32, rf32(G.sprite_tex_v + 8), tex_sv, tail_tex_v));
            vs.emit(world_pos[0] + perp_y, world_pos[1] - perp_x, world_pos[2], color_value,
                @mulAdd(f32, rf32(G.sprite_tex_u + 16), tex_su, tail_tex_u),
                @mulAdd(f32, rf32(G.sprite_tex_v + 16), tex_sv, tail_tex_v));
            vs.emit(tx + world_pos[0] - perp_y, ty + world_pos[1] + perp_x, vel_z, color_value,
                @mulAdd(f32, rf32(G.tail_tex_u0), tex_su, tail_tex_u),
                @mulAdd(f32, rf32(G.tail_tex_v0), tex_sv, tail_tex_v));
            vs.emit(tx + world_pos[0] + perp_y, ty + world_pos[1] - perp_x, vel_z, color_value,
                @mulAdd(f32, rf32(G.tail_tex_u1), tex_su, tail_tex_u),
                @mulAdd(f32, rf32(G.tail_tex_v1), tex_sv, tail_tex_v));
            vs.writeback();
            return 1;
        }

        // Fallback: velocity too small for trail, render as flat billboard
        {
            var vs = VBState.load(vb);
            const tex_su = rf32(emitter + E.texScaleU);
            const tex_sv = rf32(emitter + E.texScaleV);
            var loop_off: u32 = 0;
            while (loop_off < 0x20) : (loop_off += 8) {
                vs.emit(
                    @mulAdd(f32, sprite_scale, rf32(G.billboard_offsets_x + loop_off), world_pos[0]),
                    @mulAdd(f32, sprite_scale, rf32(G.billboard_offsets_y + loop_off), world_pos[1]),
                    world_pos[2],
                    color_value,
                    @mulAdd(f32, rf32(G.sprite_tex_u + loop_off + 8), tex_su, tail_tex_u),
                    @mulAdd(f32, rf32(G.sprite_tex_v + loop_off + 8), tex_sv, tail_tex_v),
                );
            }
            vs.writeback();
        }
    }

    return 1;
}

// =============================================================================
// Game function pointers for SetupParticleRendering
// =============================================================================

const SC = std.builtin.CallingConvention;
const StdCall: SC = .{ .x86_stdcall = .{} };

// 0x58B0B0: SetTransformMatrix — __thiscall(ECX=matrixPtr)
const gameSetTransformMatrix: *const fn (u32) callconv(TC) void = @ptrFromInt(0x58B0B0);
// 0x58B050: SetVertexShader — __thiscall(ECX=matrixPtr)
const gameSetVertexShader: *const fn (u32) callconv(TC) void = @ptrFromInt(0x58B050);
// 0x7BC6A0: multiplyMatrix4x4 — __fastcall(ECX=out, EDX=matA, stack=matB), RET 0x4, returns out
const gameMatMul: *const fn (u32, u32, u32) callconv(FC) u32 = @ptrFromInt(0x7BC6A0);
// 0x409AEF: validateMemoryOperation — __thiscall(ECX=ptr)
const gameValidateMem: *const fn (u32) callconv(TC) void = @ptrFromInt(0x409AEF);
// 0x4549F0: vec3SquaredMagnitude — __thiscall(ECX=vec3ptr), returns f64 in ST(0)
// Can't call directly from Zig due to FPU return. Use inline asm.
// All calling conventions verified from assembly at each CALL site.
// 0x589F40: BeginRender — no params visible before call
const gameBeginRender: *const fn () callconv(StdCall) void = @ptrFromInt(0x589F40);
// 0x44ACF0: GetTextureBuffer — __fastcall(ECX=texDataPtr, EDX=0, stack=0), returns ptr in EAX
const gameGetTexture: *const fn (u32, u32, u32) callconv(FC) u32 = @ptrFromInt(0x44ACF0);
// 0x589E80: SetTexture — __fastcall(ECX=slot, EDX=texturePtr)
const gameSetTexture: *const fn (u32, u32) callconv(FC) void = @ptrFromInt(0x589E80);
// 0x589A90: GetDataPointerByIndex — __thiscall(ECX=index), returns ptr
const gameGetDataPtr: *const fn (u32) callconv(TC) u32 = @ptrFromInt(0x589A90);
// 0x58A140: CreateVertexBuffer — __fastcall(ECX=0, EDX=dataPtr, stack=count), returns ptr
const gameCreateVB: *const fn (u32, u32, u32) callconv(FC) u32 = @ptrFromInt(0x58A140);
// 0x58A080: LockVertexBuffer — __thiscall(ECX=vbPtr), returns base offset
const gameLockVB: *const fn (u32) callconv(TC) u32 = @ptrFromInt(0x58A080);
// 0x589AB0: GetMatrixElementPointer — __fastcall(ECX=fmtIndex, EDX=elementIndex), returns ptr
const gameGetMatElem: *const fn (u32, u32) callconv(FC) u32 = @ptrFromInt(0x589AB0);
// 0x7B3A10: RenderParticleSystemSorted — __thiscall(ECX=emitter, stack=vbPtrs)
const gameRenderSorted: *const fn (u32, u32) callconv(TC) void = @ptrFromInt(0x7B3A10);
// 0x58A0A0: UnlockVertexBuffer — __fastcall(ECX=vbPtr, EDX=0)
const gameUnlockVB: *const fn (u32, u32) callconv(FC) void = @ptrFromInt(0x58A0A0);
// 0x58A7C0: DrawPrimitive — __fastcall(ECX=vbPtr, EDX=fmtIndex)
const gameDrawPrim: *const fn (u32, u32) callconv(FC) void = @ptrFromInt(0x58A7C0);
// 0x58A010: IsObjectActiveAndValid — __thiscall(ECX=objPtr), returns bool-like
const gameIsObjValid: *const fn (u32) callconv(TC) u32 = @ptrFromInt(0x58A010);
// 0x7B3C50: BuildIndexBuffer — __thiscall(ECX=emitter, stack=ibPtr, count)
// Actually: PUSH edx(count), PUSH ecx(ibPtr), mov ecx,ebx(emitter), CALL
const gameBuildIB: *const fn (u32, u32, u32) callconv(TC) void = @ptrFromInt(0x7B3C50);
// 0x58A800: SetStreamSource — __thiscall(ECX=ibPtr)
const gameSetStream: *const fn (u32) callconv(TC) void = @ptrFromInt(0x58A800);
// 0x58A830: CallGfxDeviceMethod_Wrapper — __fastcall(ECX=paramsPtr, EDX=param2)
const gameGfxCall: *const fn (u32, u32) callconv(FC) void = @ptrFromInt(0x58A830);
// 0x589F50: EndRender — no params
const gameEndRender: *const fn () callconv(StdCall) void = @ptrFromInt(0x589F50);

// =============================================================================
// Global addresses for SetupParticleRendering
// =============================================================================
const SG = struct {
    const world_matrix: u32 = 0xCF5B68; // g_worldMatrix (64 bytes, 4x4)
    const light_dir_x: u32 = 0xCF5878;
    const light_dir_y: u32 = 0xCF587C;
    const light_dir_z: u32 = 0xCF5880;
    const render_init_flags: u32 = 0xCF58EC;
    const sprite_vertex_template: u32 = 0xCF5AF8; // 4 vertices × 3 floats = 48 bytes
    const billboard_matrix: u32 = 0xCF5888; // 4x4 matrix (64 bytes, 0xCF5888-0xCF58C8)
    const sprite_template_validator: u32 = 0xCF5B28; // for validateMemoryOperation
    const billboard_validator: u32 = 0xCF58E8; // for validateMemoryOperation
    const normal_validator: u32 = 0xCF586C; // for validateMemoryOperation
    const default_normal: u32 = 0xCF5860; // 3 floats
    const max_particle_sprites: u32 = 0xCF5B60; // u32
    const transformed_vertices: u32 = 0xCF5B30; // output of billboard transform (48 bytes)
    const index_buffer_6: u32 = 0xCF5BAC; // ptr to index buffer for field_28==6
    const index_buffer_12: u32 = 0xCF5AF4; // ptr to index buffer for field_28==0xC
    const billboard_epsilon: u32 = 0x8029D4;
};

// =============================================================================
// SetupParticleRendering (0x7B3D20)
// __thiscall(ECX=emitter, stack=viewMatrix), RET 0x4
// viewMatrix can be NULL.
//
// Faithful recreation from Ghidra decompilation + assembly.
// All game function calls preserved, matrix math inlined with V4.
// =============================================================================
pub fn setupParticleRendering_SSE(emitter: u32, view_matrix: u32) callconv(TC) void {
    // =========================================================================
    // Section 1: Identity matrices for render state
    // Optimization: use static identity instead of rebuilding on stack each call.
    // =========================================================================
    // Must be mutable — game functions may write to the matrix pointer
    var identity_a = [16]u32{
        0x3F800000, 0, 0, 0,
        0, 0x3F800000, 0, 0,
        0, 0, 0x3F800000, 0,
        0, 0, 0, 0x3F800000,
    };
    var identity_b = [16]u32{
        0x3F800000, 0, 0, 0,
        0, 0x3F800000, 0, 0,
        0, 0, 0x3F800000, 0,
        0, 0, 0, 0x3F800000,
    };

    gameSetTransformMatrix(@intFromPtr(&identity_a));
    gameSetVertexShader(@intFromPtr(&identity_b));

    // =========================================================================
    // Section 2: Build translation matrix = identity with last row = (-x, -y, -z, 1)
    // =========================================================================
    const neg_x = -rf32(emitter + 0x23C);
    const neg_y = -rf32(emitter + 0x240);
    const neg_z = -rf32(emitter + 0x244);

    var translation = [16]u32{
        0x3F800000, 0, 0, 0,
        0, 0x3F800000, 0, 0,
        0, 0, 0x3F800000, 0,
        @bitCast(neg_x), @bitCast(neg_y), @bitCast(neg_z), 0x3F800000,
    };

    const flags = ru32(emitter + 0x1AC);

    // =========================================================================
    // Section 3: Compute g_worldMatrix based on flags
    // Three paths: flag 0x100 set, flag clear + viewMatrix != NULL, flag clear + NULL
    // =========================================================================
    if ((flags & 0x100) != 0) {
        // Path A: matmul(emitter_matrix × translation), then × identity (= just copy)
        // emitter_matrix at emitter+0x1FC
        var temp: [16]u32 = undefined;
        _ = gameMatMul(@intFromPtr(&temp), emitter + 0x1FC, @intFromPtr(&translation));
        // Original does matmul(result, temp, identity) — identity is a no-op, just copy
        copyMat4x4(SG.world_matrix, @intFromPtr(&temp));
    } else if (view_matrix != 0) {
        // Path B: matmul(viewMatrix × translation), then × identity (= just copy)
        var temp: [16]u32 = undefined;
        _ = gameMatMul(@intFromPtr(&temp), view_matrix, @intFromPtr(&translation));
        copyMat4x4(SG.world_matrix, @intFromPtr(&temp));
    } else {
        // Path C: matmul(translation × identity) = just copy translation
        copyMat4x4(SG.world_matrix, @intFromPtr(&translation));
    }

    // =========================================================================
    // Section 4: Set light direction from identity row 2 = (0, 0, 1)
    // (Original reads from identity matrix on stack; we know it's always (0,0,1))
    // =========================================================================
    // Actually, identity matrix row 2 in the stack layout: the identity at [ebp-0x54]
    // has row 2 = {0, 0, 1, 0} stored at [ebp-0x34, -0x30, -0x2c, -0x28].
    // But this identity was passed to SetVertexShader which may have modified it?
    // No — SetVertexShader just reads it. So light dir = identity[8,9,10] = (0, 0, 1).
    // But wait: assembly shows mov eax,[ebp-0x34]; mov [0xCF5878],eax etc.
    // [ebp-0x34] is identityMatrix.m20 = 0.0, [ebp-0x30] = m21 = 0.0, [ebp-0x2c] = m22 = 1.0
    wu32(SG.light_dir_x, 0); // 0.0
    wu32(SG.light_dir_y, 0); // 0.0
    wu32(SG.light_dir_z, 0x3F800000); // 1.0

    // =========================================================================
    // Section 5: Flag 0x2000 — billboard/3D sprite setup
    // =========================================================================
    if ((flags & 0x2000) != 0) {
        // One-time sprite vertex template initialization
        const init_flags = ru8(SG.render_init_flags);
        if ((init_flags & 1) == 0) {
            wu8(SG.render_init_flags, init_flags | 1);
            // Write 4 sprite vertices: {x, y, z} × 4
            // Vertex 0: (-1, 1, 0), Vertex 1: (-1, -1, 0), Vertex 2: (1, 1, 0), Vertex 3: (1, -1, 0)
            wu32(SG.sprite_vertex_template + 0, 0xBF800000); // -1.0
            wu32(SG.sprite_vertex_template + 4, 0x3F800000); // 1.0
            wu32(SG.sprite_vertex_template + 8, 0); // 0.0
            wu32(SG.sprite_vertex_template + 12, 0xBF800000); // -1.0
            wu32(SG.sprite_vertex_template + 16, 0xBF800000); // -1.0
            wu32(SG.sprite_vertex_template + 20, 0); // 0.0
            wu32(SG.sprite_vertex_template + 24, 0x3F800000); // 1.0
            wu32(SG.sprite_vertex_template + 28, 0x3F800000); // 1.0
            wu32(SG.sprite_vertex_template + 32, 0); // 0.0
            wu32(SG.sprite_vertex_template + 36, 0x3F800000); // 1.0
            wu32(SG.sprite_vertex_template + 40, 0xBF800000); // -1.0
            wu32(SG.sprite_vertex_template + 44, 0); // 0.0
            gameValidateMem(SG.sprite_template_validator);
        }

        // One-time billboard identity matrix initialization
        if ((init_flags & 2) == 0) {
            wu8(SG.render_init_flags, ru8(SG.render_init_flags) | 2);
            // Write identity 4x4 to billboard_matrix
            const bm = SG.billboard_matrix;
            inline for (0..16) |i| {
                const is_diag = (i % 5 == 0 and i < 16);
                wu32(bm + @as(u32, @intCast(i)) * 4, if (is_diag) @as(u32, 0x3F800000) else 0);
            }
            gameValidateMem(SG.billboard_validator);
        }

        // Compute billboard matrix: depends on flag 0x100
        if ((flags & 0x100) == 0) {
            // matmul(emitter+0x1FC, g_worldMatrix) → billboard_matrix
            var temp2: [16]u32 = undefined;
            _ = gameMatMul(@intFromPtr(&temp2), emitter + 0x1FC, SG.world_matrix);
            copyMat4x4(SG.billboard_matrix, @intFromPtr(&temp2));
        } else {
            // Just copy g_worldMatrix → billboard_matrix
            copyMat4x4(SG.billboard_matrix, SG.world_matrix);
        }

        // Transform 4 sprite vertices through billboard matrix
        // 4 vertices × vec3, output to g_transformedVertices
        {
            const bm = SG.billboard_matrix;
            const bm00 = rf32(bm); const bm01 = rf32(bm + 4); const bm02 = rf32(bm + 8);
            const bm10 = rf32(bm + 16); const bm11 = rf32(bm + 20); const bm12 = rf32(bm + 24);
            const bm20 = rf32(bm + 32); const bm21 = rf32(bm + 36); const bm22 = rf32(bm + 40);

            var vi: u32 = 0;
            while (vi < 48) : (vi += 12) {
                const sx = rf32(SG.sprite_vertex_template + vi);
                const sy = rf32(SG.sprite_vertex_template + vi + 4);
                const sz = rf32(SG.sprite_vertex_template + vi + 8);
                wf32(SG.transformed_vertices + vi, @mulAdd(f32, bm20, sz, @mulAdd(f32, bm10, sy, bm00 * sx)));
                wf32(SG.transformed_vertices + vi + 4, @mulAdd(f32, bm21, sz, @mulAdd(f32, bm11, sy, bm01 * sx)));
                wf32(SG.transformed_vertices + vi + 8, @mulAdd(f32, bm22, sz, @mulAdd(f32, bm12, sy, bm02 * sx)));
            }
        }

        // Store billboard matrix row 2 as rotation axis in emitter+0x284
        wf32(emitter + 0x284, rf32(SG.billboard_matrix + 32));
        wf32(emitter + 0x288, rf32(SG.billboard_matrix + 36));
        wf32(emitter + 0x28C, rf32(SG.billboard_matrix + 40));

        // Normalize the rotation axis
        const ax = rf32(emitter + 0x284);
        const ay = rf32(emitter + 0x288);
        const az = rf32(emitter + 0x28C);
        const sq_mag = @mulAdd(f32, az, az, @mulAdd(f32, ay, ay, ax * ax));
        const epsilon = rf32(SG.billboard_epsilon);
        if (@sqrt(sq_mag) >= epsilon) {
            const inv_len = 1.0 / @sqrt(sq_mag);
            wf32(emitter + 0x284, ax * inv_len);
            wf32(emitter + 0x288, ay * inv_len);
            wf32(emitter + 0x28C, az * inv_len);
        }
    }

    // =========================================================================
    // Section 6: Begin render, texture, vertex buffer setup
    // =========================================================================
    gameBeginRender();

    const tex_id = ru32(emitter + 0x1A0);
    const tex_ptr = gameGetTexture(tex_id, 0, 0);
    if (tex_ptr == 0) {
        // No texture — skip to end
        gameEndRender();
        gameSetVertexShader(@intFromPtr(&identity_a));
        return;
    }

    gameSetTexture(0x17, tex_ptr);

    // Compute max particle sprites: 0x4000 / emitter.vertexSize
    const vert_size = ru32(emitter + 0x9C);
    var max_sprites: u32 = 0x4000 / vert_size;
    const emitter_max = ru32(emitter + 0x64);
    if (emitter_max <= max_sprites) {
        max_sprites = emitter_max;
    }
    wu32(SG.max_particle_sprites, max_sprites);

    // Determine vertex format index
    const format_flag = ru32(emitter + 0x194);
    const fmt_index: u32 = if ((format_flag & 1) != 0) 4 else 8;

    const data_ptr = gameGetDataPtr(fmt_index);
    const vb_ptr = gameCreateVB(0, data_ptr, vert_size * max_sprites);
    const vb_base = gameLockVB(vb_ptr);

    // Build vertex buffer pointer array (same layout as RenderParticleSprites expects)
    var vb_ptrs: [9]u32 = undefined;

    // Position pointer
    const pos_elem = gameGetMatElem(fmt_index, 0);
    vb_ptrs[0] = pos_elem + vb_base; // pos ptr
    vb_ptrs[4] = data_ptr; // pos stride

    // Normal pointer
    if ((format_flag & 1) == 0) {
        // No per-vertex normals — use shared default
        const nflags = ru8(SG.render_init_flags);
        if ((nflags & 4) == 0) {
            wu8(SG.render_init_flags, nflags | 4);
            wu32(SG.default_normal, 0);
            wu32(SG.default_normal + 4, 0);
            wu32(SG.default_normal + 8, 0);
            gameValidateMem(SG.normal_validator);
        }
        vb_ptrs[1] = SG.default_normal;
        vb_ptrs[5] = 0; // stride 0 = shared
    } else {
        const norm_elem = gameGetMatElem(fmt_index, 3);
        vb_ptrs[1] = norm_elem + vb_base;
        vb_ptrs[5] = data_ptr;
    }

    // Color pointer
    const color_elem = gameGetMatElem(fmt_index, 4);
    vb_ptrs[2] = color_elem + vb_base;
    vb_ptrs[6] = data_ptr;

    // Texcoord pointer
    const tc_elem = gameGetMatElem(fmt_index, 5);
    vb_ptrs[3] = tc_elem + vb_base;
    vb_ptrs[7] = data_ptr;

    // Count
    vb_ptrs[8] = 0;

    // =========================================================================
    // Section 7: Render particles
    // =========================================================================
    gameRenderSorted(emitter, @intFromPtr(&vb_ptrs));

    gameUnlockVB(vb_ptr, 0);
    gameDrawPrim(vb_ptr, fmt_index);

    // =========================================================================
    // Section 8: Index buffer setup
    // =========================================================================
    const field_28 = ru32(emitter + 0x1C);
    const renders_count = ru32(emitter + 0xA0);
    if (field_28 == 6) {
        var ib = ru32(SG.index_buffer_6);
        if (gameIsObjValid(ib) == 0) {
            gameBuildIB(emitter, ib, renders_count);
            ib = ru32(SG.index_buffer_6);
        }
        gameSetStream(ib);
    } else if (field_28 == 0xC) {
        var ib = ru32(SG.index_buffer_12);
        if (gameIsObjValid(ib) == 0) {
            gameBuildIB(emitter, ib, renders_count);
            ib = ru32(SG.index_buffer_12);
        }
        gameSetStream(ib);
    }

    // =========================================================================
    // Section 9: Final setup
    // =========================================================================
    const renders = ru32(emitter + 0xA0);
    const calc_scale: f32 = @floatFromInt(renders * field_28);
    wf32(emitter + 0x20, calc_scale);

    // CallGfxDeviceMethod_Wrapper — assembly-verified packed layout:
    // [+0x00] u32 = 3              (primitive type)
    // [+0x04] u32 = 0              (start index)
    // [+0x08] u16 = (u16)(field_28 * renders)  (verts per prim)
    // [+0x0A] u16 = 0
    // [+0x0C] u16 = (u16)(vertex_count - 1)    (prim count)
    // fastcall(ECX=&params, EDX=1)
    const calc_int: u16 = @truncate(renders_count * field_28);
    const vertex_count: u32 = vb_ptrs[8];
    const prim_count: u16 = if (vertex_count > 0) @truncate(vertex_count - 1) else 0;
    var gfx_bytes: [14]u8 align(4) = undefined;
    @as(*u32, @ptrCast(gfx_bytes[0..4])).* = 3;
    @as(*u32, @ptrCast(gfx_bytes[4..8])).* = 0;
    @as(*u16, @ptrCast(gfx_bytes[8..10])).* = calc_int;
    @as(*u16, @ptrCast(gfx_bytes[10..12])).* = 0;
    @as(*u16, @ptrCast(gfx_bytes[12..14])).* = prim_count;
    gameGfxCall(@intFromPtr(&gfx_bytes), 1);

    // End render and restore vertex shader
    gameEndRender();
    gameSetVertexShader(@intFromPtr(&identity_a));
}

inline fn copyMat4x4(dst: u32, src: u32) void {
    @as(*align(1) V4, @ptrFromInt(dst)).* = @as(*align(1) const V4, @ptrFromInt(src)).*;
    @as(*align(1) V4, @ptrFromInt(dst + 16)).* = @as(*align(1) const V4, @ptrFromInt(src + 16)).*;
    @as(*align(1) V4, @ptrFromInt(dst + 32)).* = @as(*align(1) const V4, @ptrFromInt(src + 32)).*;
    @as(*align(1) V4, @ptrFromInt(dst + 48)).* = @as(*align(1) const V4, @ptrFromInt(src + 48)).*;
}

// =============================================================================
// RenderSpriteQuads (0x5A0F50)
// __thiscall(ECX=this, stack=spriteData, spriteCount, renderMode), RET 0xC
//
// Optimizations over original:
// 1. Hoisted invariant division out of inner loop (same result every iteration)
// 2. Inlined DisplayMode_CalculateOffset (trivial: table lookup + divide + subtract)
// 3. Cached texture validation bitmask check
// =============================================================================

// Game functions called by RenderSpriteQuads
const sqEmptyStub: *const fn (u32) callconv(.{ .x86_stdcall = .{} }) void = @ptrFromInt(0x590630);
const sqCalcMetrics: *const fn (u32, u32, u32, u32) callconv(TC) void = @ptrFromInt(0x592B00);
const sqGetAdapterInfo: *const fn (u32) callconv(TC) void = @ptrFromInt(0x5A1B20);

// DisplayMode tables (from 0x592C10 disassembly)
const DISPLAY_MODE_DIVISOR_TABLE: u32 = 0x85ACF0;
const DISPLAY_MODE_OFFSET_TABLE: u32 = 0x85AD08;

/// Inlined DisplayMode_CalculateOffset: table[type] divide + subtract
inline fn displayModeOffset(sprite_type: u32, count: u32) u32 {
    const divisor = ru32(DISPLAY_MODE_DIVISOR_TABLE + sprite_type * 4);
    const divided = if (divisor == 1) count else count / divisor;
    return divided -% ru32(DISPLAY_MODE_OFFSET_TABLE + sprite_type * 4);
}

pub fn renderSpriteQuads_SSE(this: u32, sprite_data: u32, sprite_count: u32, render_mode: u32) callconv(TC) void {
    // Early out: this+0xF2C == 0
    if (ru32(this + 0xF2C) == 0) return;

    // =========================================================================
    // Section 1: Texture validation (13 slots)
    // =========================================================================
    const tex_bitmask = ru32(this + 0x27D8);
    const tex_array_base = this + 0x27A4;
    var all_valid: bool = true;

    var slot: u32 = 0;
    while (slot < 13) : (slot += 1) {
        if ((tex_bitmask & (@as(u32, 1) << @truncate(slot))) != 0) {
            const tex_ptr = ru32(tex_array_base + slot * 4);
            if (tex_ptr == 0 or !all_valid or ru8(tex_ptr + 0x1C) == 0 or ru8(tex_ptr + 0x1D) == 0) {
                all_valid = false;
            }
        }
    }

    // Render mode logic
    var should_render: bool = undefined;
    if (render_mode == 0) {
        should_render = all_valid; // mode 0: render if NOT all valid → invert
        // Wait: original does bVar8 = !bVar8 for mode 0, then checks if(bVar8) → early out
        // So: if all_valid → !all_valid = false → don't early out → render
        //     if !all_valid → !all_valid = true → early out → don't render
        // Simplified: render if all_valid
    } else {
        if (!all_valid) {
            sqEmptyStub(0x85C7A8);
            return;
        }
        const extra_ptr = ru32(this + 0x27EC);
        if (ru8(extra_ptr + 0x1C) == 0) {
            sqEmptyStub(0x85C7A8);
            return;
        }
        should_render = ru8(extra_ptr + 0x1D) != 0;
    }

    if (!should_render) {
        sqEmptyStub(0x85C7A8);
        return;
    }

    // =========================================================================
    // Section 2: Setup calls
    // =========================================================================
    sqCalcMetrics(this, sprite_data, sprite_count, render_mode);
    sqGetAdapterInfo(this);

    if (sprite_count == 0) return;

    // =========================================================================
    // Section 3: Inner loop — hoisted invariant division
    // =========================================================================

    // The division this+0x27A4[0]+0x18 / this+0x27A4[0]+0xC is invariant across sprites.
    // Original recomputes it per sprite. We hoist it.
    var base_prim_count: u32 = 0;
    if (ru32(this + 0x24C) == 0) {
        const first_tex = ru32(this + 0x27A4);
        if (first_tex != 0) {
            const numerator = ru32(first_tex + 0x18);
            const denominator = ru32(first_tex + 0x0C);
            if (denominator != 0) {
                base_prim_count = numerator / denominator;
            }
        }
    }

    // D3D device vtable pointer
    const device_ptr = ru32(this + 0x38A8);
    const vtable = ru32(device_ptr);

    // Sprite data stride = 16 bytes, pointer starts at spriteData + 10
    var ptr = sprite_data + 10;
    var remaining = sprite_count;

    while (remaining > 0) : (remaining -= 1) {
        const count: u32 = @as(u32, ru16(ptr - 2)); // [esi-2] = sprite vertex count
        if (count != 0) {
            const sprite_type = ru32(ptr - 10); // [esi-0xA] = type/format index
            const offset = displayModeOffset(sprite_type, count);
            const lookup_val = ru32(0x80A14C + sprite_type * 4);

            if (render_mode == 0) {
                // DrawPrimitive: vtable[0x144](device, lookup, basePrimCount, offset)
                const draw_fn: *const fn (u32, u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) void =
                    @ptrFromInt(ru32(vtable + 0x144));
                draw_fn(device_ptr, lookup_val, base_prim_count, offset);
            } else {
                const start_idx: u32 = @as(u32, ru16(ptr));
                const end_idx: u32 = @as(u32, ru16(ptr + 2));
                const extra_ptr = ru32(this + 0x27EC);
                const extra_offset = (ru32(extra_ptr + 0x18) >> 1) + ru32(ptr - 6);

                // DrawIndexedPrimitive: vtable[0x148](device, lookup, basePrimCount, startIdx, count, extraOffset, offset)
                const draw_fn: *const fn (u32, u32, u32, u32, u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) void =
                    @ptrFromInt(ru32(vtable + 0x148));
                draw_fn(device_ptr, lookup_val, base_prim_count, start_idx, end_idx - start_idx + 1, extra_offset, offset);
            }
        }
        ptr += 16;
    }
}

