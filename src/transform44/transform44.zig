//! transform44 — render pipeline profiling & M2 bone transform optimization
//!
//! Hooks 6 functions in the render/update pipeline to measure per-frame costs:
//!
//!   executeSceneRenderPass (0x708900) — top-level render pass dispatch
//!   renderFrame            (0x707680) — per-model render (calls transformMatrix4x4)
//!   transformMatrix4x4     (0x714260) — per-model bone transform engine (17703 bytes)
//!   RenderTextureQuads     (0x76FB00) — batched quad rendering
//!   CMovement::Process     (0x616620) — per-unit movement update
//!   blit_hub               (0x5a4f60) — pixel transfer dispatch (CPU-side blitting)
//!
//! Stats are dumped every DUMP_FRAMES render passes (~2s at 60fps).

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");
const timer_fix = @import("timer_fix.zig");
extern fn clipPolygonToSinglePlane(u32, u32, u32) void;
extern fn buildTrianglePlanes(u32, u32, u32, u32, u32) u32;
extern fn rayTriangleIntersection(u32, u32, u32, u32, u32, u32) u32;
extern fn rotateMatrixByAxisAngle(u32, u32, u32, u32) void;
extern fn multiplyMatrix4x4(u32, u32, u32) u32;
extern fn transformImpl_SSE(u32, u32, u32, u32, u32) callconv(.c) void;
extern fn calcColorValues_SSE(u32, u32, u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
extern fn renderParticleSprites_SSE(u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
extern fn resetParticleCache() void;
extern var stride_info: [8]u32; // exported from particle_sse.zig
var stride_dumped: bool = false;

/// Thiscall wrapper for the SSE implementation. Lives here (baseline SSE2 unit)
/// so LLVM can't inline transformImpl_SSE's alignment into the thiscall frame.
fn transformMatrix4x4_SSE(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
    transformImpl_SSE(this, mat1, mat2, mat3, mat4);
}
extern fn transformMatrix4x4_REF(u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
extern var bisect_stop_section: u32;

pub const module_name: [*:0]const u8 = "transform44";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Profiling state — unified dump every DUMP_FRAMES render passes
// =============================================================================

const DUMP_FRAMES: u64 = 450; // ~7.5s at 60fps (frame-count fallback)
const DUMP_CYCLES: u64 = 3_000_000_000 * 8; // ~8s at ~3GHz (time-based primary)

var prof = ProfState{};
var t44_depth: u64 = 0; // recursion depth — survives resets
var dbg_dump_count: u32 = 0; // DEBUG: limit bone matrix dumps
var dbg_orig_done: bool = false; // DEBUG: run original once
var dbg_ref_this: u32 = 0; // DEBUG: target for REF overwrite
var last_frame_tsc: u64 = 0; // frame-to-frame TSC for total frame time

// A/B testing: alternate between baseline (original) and custom (optimized) code paths.
// Flips every DUMP_FRAMES so each dump period is purely one mode.
pub var ab_use_custom: bool = false;

// Gate for non-transform A/B hooks. Set false to isolate transform44 SSE testing.
const AB_OTHER_HOOKS = false;
var diag_cmp_count: u32 = 0;
export var original_trampoline: u32 = 0; // DEBUG: expose trampoline for REF passthrough test

// Teardown guard: set true when CleanupWorldAndEntities fires.
// During teardown, SceneObject data may be partially freed — our SSE code
// must not process it. Falls back to original function which the game
// controls. NOTE: binary patching (instead of hooking) would avoid this
// issue entirely since the patched code IS the original entry point.
var teardown_active: bool = false;


// Persistent blit totals per A/B mode — NOT reset each dump period.
// Accumulates across all dump periods so rare blits still show up.
var blit_total_baseline: BlitAccum = .{};
var blit_total_custom: BlitAccum = .{};

const BlitAccum = struct {
    calls: u64 = 0,
    cycles: u64 = 0,
};

const ProfState = struct {
    // Frame timing jitter tracking
    frame_min_cycles: u64 = std.math.maxInt(u64),
    frame_max_cycles: u64 = 0,
    // Frame counter (incremented by executeSceneRenderPass)
    frames: u64 = 0,
    // Total frame-to-frame wall cycles (sum of inter-frame deltas)
    wall_cycles: u64 = 0,

    // transformMatrix4x4 (0x714260)
    t44_calls: u64 = 0,
    t44_early: u64 = 0,
    t44_cycles: u64 = 0,
    t44_bones: u64 = 0,
    t44_max_bones: u64 = 0,
    t44_max_depth: u64 = 0,

    // renderFrame (0x707680)
    rf_calls: u64 = 0,
    rf_cycles: u64 = 0,

    // executeSceneRenderPass (0x708900)
    erp_calls: u64 = 0,
    erp_cycles: u64 = 0,

    // RenderTextureQuads (0x76FB00)
    rtq_calls: u64 = 0,
    rtq_cycles: u64 = 0,
    rtq_items: u64 = 0,

    // CMovement::ProcessUnitMovementUpdate (0x616620)
    mov_calls: u64 = 0,
    mov_cycles: u64 = 0,

    // --- Perf-identified hotspots ---
    clip_calls: u64 = 0, // ClipPolygonToSinglePlane (0x6318c0) 3.95%
    clip_cycles: u64 = 0,
    glyph_calls: u64 = 0, // GetOrCreateCharacterGlyph (0x5ca2d0) 3.65%
    glyph_cycles: u64 = 0,
    glyph_hits: u64 = 0, // shadow cache hits (custom mode only)
    glyph_misses: u64 = 0, // shadow cache misses (custom mode only)
    particle_calls: u64 = 0, // RenderParticleSprites (0x7b2a50) 1.73%
    particle_cycles: u64 = 0,
    collision_calls: u64 = 0, // processLinkedListCollision (0x6abc40) 1.57%
    collision_cycles: u64 = 0,
    entpos_calls: u64 = 0, // UpdateEntityAndChunksPositions (0x6afad0) 1.18%
    entpos_cycles: u64 = 0,
    layers_calls: u64 = 0, // renderAllFrameLayers (0x765650) 1.15%
    layers_cycles: u64 = 0,
    textvb_calls: u64 = 0, // RenderTextToVertexBuffer (0x5ccbe0) 1.07%
    textvb_cycles: u64 = 0,
    complexgeo_calls: u64 = 0, // RenderComplexGeometry (0x58a3d0) 1.02%
    complexgeo_cycles: u64 = 0,
    entbounds_calls: u64 = 0, // updateEntitiesInBounds (0x6c1f70) 0.93%
    entbounds_cycles: u64 = 0,
    textctr_calls: u64 = 0, // updateTextFrameCounter (0x5cdf40) 0.88%
    textctr_cycles: u64 = 0,
    spatial_calls: u64 = 0, // AddToSpatialGrid (0x6816f0) 0.66%
    spatial_cycles: u64 = 0,
    raytri_calls: u64 = 0, // ray_triangle_intersection_indexed_ushort (0x7c29f0) 0.65%
    raytri_cycles: u64 = 0,
    linkedlist_calls: u64 = 0, // ManageLinkedListNode (0x710b90) 0.64%
    linkedlist_cycles: u64 = 0,
    color_calls: u64 = 0, // calculateColorValues (0x7b9b10) 0.63%
    color_cycles: u64 = 0,
    setvec_calls: u64 = 0, // SetVector3 (0x686640) 0.61%
    setvec_cycles: u64 = 0,
    cull_calls: u64 = 0, // PerformSpatialCulling (0x6b8c60) 0.59%
    cull_cycles: u64 = 0,
    colldet_calls: u64 = 0, // performCollisionDetection (0x6b88e0) 0.59%
    colldet_cycles: u64 = 0,
    activep_calls: u64 = 0, // ProcessActiveParticles (0x7b5a10) 0.55%
    activep_cycles: u64 = 0,
    cbiter_calls: u64 = 0, // CallbackIterator (0x404130) 0.53%
    cbiter_cycles: u64 = 0,
    findguid_calls: u64 = 0, // FindObjectByGUID (0x464890) 0.50%
    findguid_cycles: u64 = 0,
    raytri2_calls: u64 = 0, // RayTriangleIntersection (0x632700) 0.49%
    raytri2_cycles: u64 = 0,
    drawbatch_calls: u64 = 0, // DrawBatchProj (0x70cb30) 0.48%
    drawbatch_cycles: u64 = 0,
    findlua_calls: u64 = 0, // FindLuaFunction (0x702000) 0.47%
    findlua_cycles: u64 = 0,
    spritequad_calls: u64 = 0, // RenderSpriteQuads (0x5a0f50) 0.44%
    spritequad_cycles: u64 = 0,
    scenenode_calls: u64 = 0, // renderSceneNode (0x718960) 0.44%
    scenenode_cycles: u64 = 0,
    terrain_calls: u64 = 0, // generateTerrainChunk (0x6cffc0) 0.44%
    terrain_cycles: u64 = 0,
    d3dtex_calls: u64 = 0, // D3D_SetTexture (0x593840) 0.43%
    d3dtex_cycles: u64 = 0,
    bboxchk_calls: u64 = 0, // checkBoundingBoxIntersection (0x6b8b70) 0.42%
    bboxchk_cycles: u64 = 0,
    rotmat_calls: u64 = 0, // rotateMatrixByAxisAngle (0x7bdd60) — unresolved callee hotspot
    rotmat_cycles: u64 = 0,
    triplane_calls: u64 = 0, // BuildTrianglePlanes (0x632460)
    triplane_cycles: u64 = 0,
    partsetup_calls: u64 = 0, // SetupParticleRendering (0x7b3d20)
    partsetup_cycles: u64 = 0,
    matmul_calls: u64 = 0, // multiplyMatrix4x4 (0x7bc6a0)
    matmul_cycles: u64 = 0,
    textline_calls: u64 = 0, // renderTextLine (0x5ce0c0)
    textline_cycles: u64 = 0,
};

// =============================================================================
// Glyph shadow cache — direct-mapped, bypasses game's 4-bucket hash table.
// Key: (font_ptr, char_code, param2). O(1) lookup, no pointer chasing.
// =============================================================================

const GLYPH_CACHE_SHIFT = 12;
const GLYPH_CACHE_SIZE = 1 << GLYPH_CACHE_SHIFT; // 4096 entries
const GLYPH_CACHE_MASK = GLYPH_CACHE_SIZE - 1;

const GlyphCacheEntry = struct {
    font_ptr: u32 = 0,
    char_code: u32 = 0,
    param2: u32 = 0,
    width_bits: u32 = 0, // f32 stored as u32 bits
};

var glyph_cache: [GLYPH_CACHE_SIZE]GlyphCacheEntry = [_]GlyphCacheEntry{.{}} ** GLYPH_CACHE_SIZE;

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}


// =============================================================================
// Hook: transformMatrix4x4 (0x714260)
// __thiscall(ECX=SceneObject*, stack: Matrix4x4* ×4)
// RET 0x10
// =============================================================================

const TransformFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) void;
var transform_hook: hook.Detour(TransformFn) = .{};

// --- Comprehensive memory comparison diagnostic ---
const DIAG_MAX: u32 = 5; // compare first N non-early-exit calls
var diag_count: u32 = 0;
// Snapshot buffer: 128KB static for original's state
var diag_buf: [128 * 1024]u8 align(4) = undefined;

fn diagSnapshot(dst: []u8, src: u32, len: u32) void {
    const s: [*]const u8 = @ptrFromInt(src);
    @memcpy(dst[0..len], s[0..len]);
}

fn diagCompare(label: [*:0]const u8, snap: []const u8, live: u32, len: u32) void {
    const l: [*]const u8 = @ptrFromInt(live);
    var diffs: u32 = 0;
    var first_off: u32 = 0;
    var first_orig: u32 = 0;
    var first_ref: u32 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (snap[i] != l[i]) {
            if (diffs == 0) {
                first_off = i;
                first_orig = snap[i];
                first_ref = l[i];
            }
            diffs += 1;
        }
    }
    if (diffs > 0) {
        log.fmt("  DIFF {s}: {d} bytes differ, first at +0x{x:0>4} orig=0x{x:0>2} ref=0x{x:0>2}", .{ label, diffs, first_off, first_orig, first_ref });
        // Also dump first 4 dword-aligned diffs for context
        var shown: u32 = 0;
        i = 0;
        while (i + 3 < len and shown < 8) : (i += 4) {
            const so = @as(u32, snap[i]) | (@as(u32, snap[i + 1]) << 8) | (@as(u32, snap[i + 2]) << 16) | (@as(u32, snap[i + 3]) << 24);
            const sr = @as(u32, l[i]) | (@as(u32, l[i + 1]) << 8) | (@as(u32, l[i + 2]) << 16) | (@as(u32, l[i + 3]) << 24);
            if (so != sr) {
                log.fmt("    +0x{x:0>4}: orig=0x{x:0>8} ref=0x{x:0>8}", .{ i, so, sr });
                shown += 1;
            }
        }
    }
}

fn transformDetour(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(hook.cc.thiscall) void {
    const start = rdtsc();

    const model_data = hook.readMem(u32, this + 0x10);
    var is_early = false;
    var bone_count: u32 = 0;
    if (model_data == 0) {
        is_early = true;
    } else {
        const anim_ctx = hook.readMem(u32, this + 0x2C);
        if (anim_ctx != 0) {
            const sync_val = hook.readMem(u32, this + 0x40);
            const anim_sync = hook.readMem(u32, anim_ctx + 0x10);
            if (sync_val == anim_sync) is_early = true;
        }
        const model_ctr = hook.readMem(u32, this + 0x30);
        if (model_ctr != 0) {
            const model_hdr = hook.readMem(u32, model_ctr + 0x130);
            if (model_hdr != 0) {
                bone_count = hook.readMem(u32, model_hdr + 0x34);
            }
        }
    }

    t44_depth +|= 1;
    if (t44_depth > prof.t44_max_depth) prof.t44_max_depth = t44_depth;

    if (teardown_active) {
        transform_hook.callOriginal(.{ this, mat1, mat2, mat3, mat4 });
    } else {
        transformMatrix4x4_SSE(this, mat1, mat2, mat3, mat4);
    }

    t44_depth -|= 1;
    const elapsed = rdtsc() - start;
    prof.t44_cycles +|= elapsed;
    prof.t44_calls +|= 1;
    if (is_early) prof.t44_early +|= 1;
    prof.t44_bones +|= bone_count;
    if (bone_count > prof.t44_max_bones) prof.t44_max_bones = bone_count;
}

// =============================================================================
// Hook: renderFrame (0x707680)
// __thiscall(ECX=this, stack: float* cameraPosition)
// Fastcall mapping: ECX=this, EDX=unused, stack: cameraPos
// RET 0x4
// =============================================================================

const RenderFrameFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var render_frame_hook: hook.Detour(RenderFrameFn) = .{};

fn renderFrameDetour(this: u32, edx: u32, camera_pos: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();
    const ret = render_frame_hook.callOriginal(.{ this, edx, camera_pos });
    prof.rf_cycles +|= rdtsc() - start;
    prof.rf_calls +|= 1;
    return ret;
}

// =============================================================================
// Hook: executeSceneRenderPass (0x708900)
// __thiscall(ECX=scene, stack: renderPassIndex) — Ghidra labels __stdcall but
// prologue does MOV ESI,ECX (saves this). RET 0x4.
// Fastcall mapping: ECX=this, EDX=unused, stack: passIndex
// =============================================================================

const ExecRenderPassFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var exec_render_pass_hook: hook.Detour(ExecRenderPassFn) = .{};

fn execRenderPassDetour(this: u32, edx: u32, pass_index: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const now = rdtsc();
    const ret = exec_render_pass_hook.callOriginal(.{ this, edx, pass_index });
    prof.erp_cycles +|= rdtsc() - now;
    prof.erp_calls +|= 1;

    return ret;
}

// =============================================================================
// Hook: OnWorldUpdate (0x482EA0)
// __fastcall(ECX=frame_count) — fires exactly once per game frame.
// Used as the true frame counter for profiling dumps and A/B testing,
// instead of executeSceneRenderPass which fires multiple times per frame.
// =============================================================================

const WorldUpdateFn = fn (u32) callconv(hook.cc.fastcall) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

fn worldUpdateDetour(frame_count: u32) callconv(hook.cc.fastcall) void {
    resetParticleCache(); // Clear per-frame caches before rendering
    const now = rdtsc();
    if (last_frame_tsc != 0) {
        const delta = now - last_frame_tsc;
        prof.wall_cycles +|= delta;
        if (delta < prof.frame_min_cycles) prof.frame_min_cycles = delta;
        if (delta > prof.frame_max_cycles) prof.frame_max_cycles = delta;
    }
    last_frame_tsc = now;

    world_update_hook.callOriginal(.{frame_count});

    prof.frames +|= 1;
    if (prof.frames >= DUMP_FRAMES or prof.wall_cycles >= DUMP_CYCLES) {
        dumpStats();
    }
}

// =============================================================================
// Hook: World_HandleLogoutCleanup (0x491180)
// Fires at the START of the logout/disconnect cleanup sequence, BEFORE any
// model data is freed. Sets teardown_active flag so our SSE code falls back
// to the original function during the entire cleanup chain.
// NOTE: binary patching instead of hooking would avoid this issue entirely.
// =============================================================================

const TeardownFn = fn () callconv(.{ .x86_stdcall = .{} }) void;
var teardown_hook: hook.Detour(TeardownFn) = .{};

fn teardownDetour() callconv(.{ .x86_stdcall = .{} }) void {
    teardown_active = true;
    teardown_hook.callOriginal(.{});
    teardown_active = false;
}

// =============================================================================
// Hook: RenderTextureQuads (0x76FB00)
// __fastcall(ECX=RenderBatch*) — no stack params, RET
//
// RenderBatch layout (assembly-verified):
//   +0x0C = item_count (u32)
//   +0x10 = items_ptr  (RenderItem*)
//   +0x18 = text_data   (void*, passed to DrawString if non-null)
//   +0x24 = callback_list (linked list, iterated after render)
//
// RenderItem layout (0x1C = 28 bytes per item, assembly-verified):
//   +0x00 = texture          (ptr, primary texture — SetTexture stage 0x17)
//   +0x04 = vertices         (float* xyz, stride 0x0C = 3 floats, 4 verts per quad)
//   +0x08 = textureCoords    (float* uv, stride 0x08 = 2 floats, 4 verts per quad)
//   +0x0C = renderState      (int, passed to SetRenderState(7, val))
//   +0x10 = additionalData   (ptr, secondary vertex data — can be NULL)
//   +0x14 = dataStride       (int, stride for additionalData)
//   +0x18 = secondaryTexture (ptr, SetTexture stage 0x3F)
//
// Original inner loop: per-item SetTexture + SetRenderState +
//   InitializeRenderingPipeline + RenderVertexBuffer + EmptyRenderFunction
//   = 5 GxDevice calls per quad. Batching by texture reduces draw calls.
//
// Key globals:
//   0xCF4CF4 = g_defaultTexCoord
//   0x878CDC = g_quadVertexIndices (6 u16: 0,1,2, 0,2,3)
// =============================================================================

const RenderQuadsFn = fn (u32, u32) callconv(hook.cc.fastcall) void;
var render_quads_hook: hook.Detour(RenderQuadsFn) = .{};

const MAX_BATCH_QUADS = 256;
const ITEM_SIZE: u32 = 0x1C; // 28 bytes per RenderItem

// Sort key for grouping by (texture, renderState, secondaryTexture)
const SortEntry = struct {
    texture: u32,
    render_state: u32,
    secondary_tex: u32,
    has_additional: bool,
    index: u16,

    fn lessThan(a: SortEntry, b: SortEntry) bool {
        if (a.texture != b.texture) return a.texture < b.texture;
        if (a.render_state != b.render_state) return a.render_state < b.render_state;
        return a.secondary_tex < b.secondary_tex;
    }

    fn sameGroup(a: SortEntry, b: SortEntry) bool {
        return a.texture == b.texture and
            a.render_state == b.render_state and
            a.secondary_tex == b.secondary_tex;
    }
};
var sort_entries: [MAX_BATCH_QUADS]SortEntry = undefined;

// Batched vertex data: contiguous xyz and uv buffers for multi-quad draw calls
var batch_xyz: [MAX_BATCH_QUADS * 4 * 3]f32 = undefined; // 4 verts * 3 floats per quad
var batch_uv: [MAX_BATCH_QUADS * 4 * 2]f32 = undefined; // 4 verts * 2 floats per quad

// Pre-computed index buffer: quad Q uses verts Q*4..Q*4+3, triangles (0,1,2)(0,2,3)
const batch_indices = blk: {
    var idx: [MAX_BATCH_QUADS * 6]u16 = undefined;
    for (0..MAX_BATCH_QUADS) |q| {
        const base: u16 = @intCast(q * 4);
        idx[q * 6 + 0] = base;
        idx[q * 6 + 1] = base + 1;
        idx[q * 6 + 2] = base + 2;
        idx[q * 6 + 3] = base;
        idx[q * 6 + 4] = base + 2;
        idx[q * 6 + 5] = base + 3;
    }
    break :blk idx;
};

// ---- GxDevice wrapper calls (assembly-verified calling conventions) ----
// All route through the GxDevice at global 0xC0ED38.

// BeginRender/EndRender: thiscall thunks, load ECX from global, JMP to vtable method
inline fn gxBeginRender() void {
    hook.call(fn () callconv(.c) void, 0x589f40, .{});
}
inline fn gxEndRender() void {
    hook.call(fn () callconv(.c) void, 0x589f50, .{});
}
// SetRenderState: fastcall(ECX=stateId, EDX=value), plain RET
// SetTexture:     fastcall(ECX=stage, EDX=texturePtr), plain RET
const GxFastcall2 = fn (u32, u32) callconv(hook.cc.fastcall) void;
inline fn gxSetRenderState(state_id: u32, value: u32) void {
    hook.call(GxFastcall2, 0x589e60, .{ state_id, value });
}
inline fn gxSetTexture(stage: u32, texture: u32) void {
    hook.call(GxFastcall2, 0x589e80, .{ stage, texture });
}
// InitializeRenderingPipeline: fastcall(ECX=vertCount, EDX=vertsPtr, 11 stack), RET 0x2c
// Stores vertCount to global [0xC0ED2C] which RenderVertexBuffer reads.
const GxInitPipelineFn = fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
const GX_DEFAULT_TEXCOORD: u32 = 0xCF4CF4;

// RenderVertexBuffer: fastcall(ECX=primType, EDX=vertCount, stack: indicesPtr), RET 0x4
const GxRenderVBFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
const GX_QUAD_INDICES: u32 = 0x878CDC; // game's {0,1,2,0,2,3}

fn renderQuadsDetour(batch_ptr: u32, edx: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const item_count: u32 = if (batch_ptr != 0) hook.readMem(u32, batch_ptr + 0xC) else 0;
    const start = rdtsc();

    // RTQ batching tested: sort-only (Approach A) and GxDevice draw-call batching
    // (Approach B) both showed 0% improvement. Bottleneck is inside GxDevice/D3D9
    // internals (vertex buffer mgmt, proxy state machine), not per-call overhead.
    // Batching code preserved below for future work. See RESEARCH.md for details.
    render_quads_hook.callOriginal(.{ batch_ptr, edx });

    prof.rtq_cycles +|= rdtsc() - start;
    prof.rtq_calls +|= 1;
    prof.rtq_items +|= item_count;
}

/// Batch UI quads by (texture, renderState, secondaryTexture) groups.
/// Groups with no additionalData get a single draw call per group.
/// Groups with additionalData render individually through GxDevice wrappers.
fn renderQuadsBatched(batch_ptr: u32, item_count: u32) void {
    const items_base = hook.readMem(u32, batch_ptr + 0x10);
    if (items_base == 0) {
        render_quads_hook.callOriginal(.{ batch_ptr, 0 });
        return;
    }

    // Build sort entries with full grouping key
    for (0..item_count) |i| {
        const item_addr = items_base + @as(u32, @intCast(i)) * ITEM_SIZE;
        const rs = hook.readMem(u32, item_addr + 0x0C);
        const additional = hook.readMem(u32, item_addr + 0x10);
        sort_entries[i] = .{
            .texture = hook.readMem(u32, item_addr),
            .render_state = if (additional != 0 and rs < 2) 2 else rs,
            .secondary_tex = hook.readMem(u32, item_addr + 0x18),
            .has_additional = additional != 0,
            .index = @intCast(i),
        };
    }

    // Insertion sort by (texture, render_state, secondary_tex)
    const entries = sort_entries[0..item_count];
    for (1..entries.len) |ii| {
        const key = entries[ii];
        var j: usize = ii;
        while (j > 0 and SortEntry.lessThan(key, entries[j - 1])) {
            entries[j] = entries[j - 1];
            j -= 1;
        }
        entries[j] = key;
    }

    // Render through GxDevice wrappers
    gxBeginRender();
    gxSetRenderState(0x0E, 0);
    gxSetRenderState(0x0F, 0);
    gxSetRenderState(0x10, 0);
    gxSetRenderState(0x12, 0);

    var last_tex: u32 = 0xFFFFFFFF;
    var i: u32 = 0;
    while (i < item_count) {
        const gs = i; // group start
        var ge = gs + 1; // group end
        while (ge < item_count and SortEntry.sameGroup(entries[ge], entries[gs])) {
            ge += 1;
        }

        // Set primary texture (skip if same as last group)
        if (entries[gs].texture != last_tex) {
            gxSetTexture(0x17, entries[gs].texture);
            last_tex = entries[gs].texture;
        }
        // Set render state
        if (entries[gs].render_state != 0x0B) {
            gxSetRenderState(7, entries[gs].render_state);
        }
        // Set secondary texture
        gxSetTexture(0x3F, entries[gs].secondary_tex);

        // Check if all items in group lack additionalData (batchable)
        var can_batch = true;
        for (gs..ge) |gi| {
            if (entries[gi].has_additional) {
                can_batch = false;
                break;
            }
        }

        if (can_batch and ge - gs > 1) {
            // BATCHED: build contiguous xyz/uv buffers, single draw call
            var verts: u32 = 0;
            for (gs..ge) |gi| {
                const idx = entries[gi].index;
                const item_addr = items_base + @as(u32, idx) * ITEM_SIZE;
                const xyz_ptr = hook.readMem(u32, item_addr + 0x04);
                const uv_ptr = hook.readMem(u32, item_addr + 0x08);

                if (xyz_ptr != 0) {
                    const src_xyz: [*]const f32 = @ptrFromInt(xyz_ptr);
                    @memcpy(batch_xyz[verts * 3 ..][0..12], src_xyz[0..12]);
                }
                if (uv_ptr != 0) {
                    const src_uv: [*]const f32 = @ptrFromInt(uv_ptr);
                    @memcpy(batch_uv[verts * 2 ..][0..8], src_uv[0..8]);
                }
                verts += 4;
            }

            hook.call(GxInitPipelineFn, 0x58a2a0, .{
                verts, @intFromPtr(&batch_xyz), // ECX=vertCount, EDX=xyzPtr
                @as(u32, 0x0C), GX_DEFAULT_TEXCOORD, @as(u32, 0), // stride, defaultTC, 0
                @as(u32, 0), @as(u32, 0), // no additionalData
                @as(u32, 0), @as(u32, 0), // zeros (skipped by forwarder)
                @intFromPtr(&batch_uv), @as(u32, 8), // uvPtr, uvStride
                @as(u32, 0), @as(u32, 0), // trailing zeros
            });
            hook.call(GxRenderVBFn, 0x58a2e0, .{
                @as(u32, 4), // D3DPT_TRIANGLELIST
                verts, // vertex count
                @intFromPtr(&batch_indices), // index buffer
            });
            hook.call(fn () callconv(.c) void, 0x58a340, .{}); // EmptyRenderFunction
        } else {
            // INDIVIDUAL: per-item draw calls through GxDevice wrappers
            for (gs..ge) |gi| {
                const idx = entries[gi].index;
                const item_addr = items_base + @as(u32, idx) * ITEM_SIZE;
                const xyz_ptr = hook.readMem(u32, item_addr + 0x04);
                const uv_ptr = hook.readMem(u32, item_addr + 0x08);
                const additional = hook.readMem(u32, item_addr + 0x10);
                const add_stride = hook.readMem(u32, item_addr + 0x14);

                hook.call(GxInitPipelineFn, 0x58a2a0, .{
                    @as(u32, 4), xyz_ptr, // 4 verts, xyz data
                    @as(u32, 0x0C), GX_DEFAULT_TEXCOORD, @as(u32, 0),
                    additional, add_stride,
                    @as(u32, 0), @as(u32, 0),
                    uv_ptr, @as(u32, 8),
                    @as(u32, 0), @as(u32, 0),
                });
                hook.call(GxRenderVBFn, 0x58a2e0, .{
                    @as(u32, 4), @as(u32, 4), GX_QUAD_INDICES,
                });
                hook.call(fn () callconv(.c) void, 0x58a340, .{});
            }
        }

        i = ge;
    }

    gxEndRender();

    // Handle text_data (DrawString at 0x5c1ef0)
    const text_data = hook.readMem(u32, batch_ptr + 0x18);
    if (text_data != 0) {
        hook.call(fn (u32) callconv(hook.cc.fastcall) void, 0x5c1ef0, .{text_data});
    }

    // Walk callback linked list
    var node = hook.readMem(u32, batch_ptr + 0x24);
    if (node & 1 != 0) node = 0;
    while (node != 0 and node & 1 == 0) {
        const cb: *const fn () callconv(.c) void = @ptrFromInt(hook.readMem(u32, node + 8));
        cb();
        node = hook.readMem(u32, node + 4);
    }
}

// =============================================================================
// Hook: CMovement::ProcessUnitMovementUpdate (0x616620)
// __thiscall(ECX=this, stack: timeNow(u32), lastUpdate(u32))
// RET 0x8 (2 stack params)
// Fastcall mapping: ECX=this, EDX=unused, stack: timeNow, lastUpdate
// =============================================================================

const MovementFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
var movement_hook: hook.Detour(MovementFn) = .{};

fn movementDetour(this: u32, edx: u32, time_now: u32, last_update: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();
    movement_hook.callOriginal(.{ this, edx, time_now, last_update });
    prof.mov_cycles +|= rdtsc() - start;
    prof.mov_calls +|= 1;
}

// =============================================================================
// Hook: interpolateAnimationKeyframes (0x713ea0)
// __fastcall(ECX=animObj, EDX=animState, stack: keyframeData*, outputBuffer*)
// RET 0x8 (2 stack params)
//
// Called per-bone from transformMatrix4x4 for rotation/scale tracks.
// Calls findInterpolationIndices, then does 4-component x87 lerp.
// Our SSE path replaces the x87 lerp with @Vector(4, f32) ops.
//
// outputBuffer layout (written by this function):
//   +0x00 = lower keyframe index (u32)  }
//   +0x04 = upper keyframe index (u32)  } filled by findInterpolationIndices
//   +0x08 = interpolation factor t (f32)}
//   +0x0C = lerp result (4 floats)      } filled by lerp
//   +0x1C = secondary indices (crossfade)} filled by 2nd findInterpolationIndices
//   +0x28 = secondary lerp result       } filled by 2nd lerp
// =============================================================================

const InterpKfFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
var interp_kf_hook: hook.Detour(InterpKfFn) = .{};

// findInterpolationIndices: __thiscall(ECX=animObj, stack: p1, p2, kfData, outBuf)
// RET 0x10 (4 stack params). Fastcall: ECX=animObj, EDX=unused, 4 stack.
const FindInterpIdxFn = fn (u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

fn interpKfDetour(anim_obj: u32, anim_state: u32, kf_data: u32, out_buf: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // SSE interp disabled — hook overhead exceeds savings (see perf analysis)
    interp_kf_hook.callOriginal(.{ anim_obj, anim_state, kf_data, out_buf });
}

noinline fn interpKfSSE(anim_obj: u32, anim_state: u32, kf_data: u32, out_buf: u32) void {
    @setRuntimeSafety(false);

    // Step 1: call findInterpolationIndices (original game function)
    const p1 = hook.readMem(u32, anim_state + 0x98);
    const p2 = hook.readMem(u32, anim_state + 0x9C);
    hook.call(FindInterpIdxFn, 0x713d50, .{ anim_obj, 0, p1, p2, kf_data, out_buf });

    // Step 2: read results
    const lower = hook.readMem(u32, out_buf);
    const flag = hook.readMem(u16, kf_data); // keyframeData[0]: 0 = single keyframe

    const kf_base = hook.readMem(u32, kf_data + 0x18);

    if (flag == 0) {
        // Single keyframe: direct copy to outBuf+0xC (no interpolation)
        const src: [*]const u32 = @ptrFromInt(kf_base + lower * 16);
        const dst: [*]u32 = @ptrFromInt(out_buf + 0xC);
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
        return;
    }

    // Step 3: SSE 4-component lerp — result = a + (b - a) * t
    const upper = hook.readMem(u32, out_buf + 4);
    const t: f32 = @bitCast(hook.readMem(u32, out_buf + 8));

    const a_ptr: [*]const f32 = @ptrFromInt(kf_base + lower * 16);
    const b_ptr: [*]const f32 = @ptrFromInt(kf_base + upper * 16);

    const a: @Vector(4, f32) = a_ptr[0..4].*;
    const b: @Vector(4, f32) = b_ptr[0..4].*;
    const tv: @Vector(4, f32) = @splat(t);
    const result = a + (b - a) * tv;

    const dst: [*]f32 = @ptrFromInt(out_buf + 0xC);
    dst[0..4].* = @as([4]f32, result);

    // Step 4: check crossfade condition
    const const_zero: f32 = @bitCast(hook.readMem(u32, 0x7ffd74));
    const blend_weight: f32 = @bitCast(hook.readMem(u32, anim_state + 0x10C));
    if (blend_weight == const_zero) return;

    const time_idx = hook.readMem(u16, kf_data + 2);
    if (time_idx != 0xFFFF) return;

    // Step 5: secondary findInterpolationIndices + SSE lerp for crossfade
    const p3 = hook.readMem(u32, anim_state + 0xC4);
    const p4 = hook.readMem(u32, anim_state + 0xC8);
    hook.call(FindInterpIdxFn, 0x713d50, .{ anim_obj, 0, p3, p4, kf_data, out_buf + 0x1C });

    const lower2 = hook.readMem(u32, out_buf + 0x1C);
    const upper2 = hook.readMem(u32, out_buf + 0x20);
    const t2: f32 = @bitCast(hook.readMem(u32, out_buf + 0x24));

    const a2_ptr: [*]const f32 = @ptrFromInt(kf_base + lower2 * 16);
    const b2_ptr: [*]const f32 = @ptrFromInt(kf_base + upper2 * 16);

    const a2: @Vector(4, f32) = a2_ptr[0..4].*;
    const b2: @Vector(4, f32) = b2_ptr[0..4].*;
    const t2v: @Vector(4, f32) = @splat(t2);
    const result2 = a2 + (b2 - a2) * t2v;

    const dst2: [*]f32 = @ptrFromInt(out_buf + 0x28);
    dst2[0..4].* = @as([4]f32, result2);

    // Step 6: blend result1 toward result2 by blend_weight
    const wv: @Vector(4, f32) = @splat(blend_weight);
    const blended = result + (result2 - result) * wv;
    dst[0..4].* = @as([4]f32, blended);
}

// =============================================================================
// Perf-identified hotspot hooks — timing-only wrappers.
// Generated from perf.data.perfparser analysis (July 2025).
//
// Convention mapping for Detour (all use fastcall ABI):
//   thiscall RET 0    → Fn2 (ECX=this, EDX=unused)
//   thiscall RET 0x4  → Fn3 (ECX=this, EDX=unused, 1 stack)
//   thiscall RET 0x8  → Fn4 (ECX=this, EDX=unused, 2 stack)
//   thiscall RET 0xC  → Fn5
//   thiscall RET 0x18 → Fn8
//   thiscall RET 0x20 → Fn10
//   stdcall  RET 0x4  → Fn3 (ECX=p1, EDX=p2, 1 stack) — but no this
//   stdcall  RET 0x8  → Fn4
//   stdcall  RET 0x10 → Fn6
//   stdcall  RET 0x24 → Fn11
// =============================================================================

// Function type aliases by param count (all fastcall, return ?*anyopaque to preserve EAX)
const Fn2 = fn (u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn3 = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn4 = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn5 = fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn8v = fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn6 = fn (u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn10 = fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
const Fn11 = fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;

// Hook variables
var clip_hook: hook.Detour(Fn3) = .{}; // ClipPolygonToSinglePlane: stdcall RET 0x4
var glyph_hook: hook.Detour(Fn4) = .{}; // GetOrCreateCharacterGlyph: stdcall RET 0x8
var particle_hook: hook.Detour(Fn4) = .{}; // RenderParticleSprites: thiscall RET 0x8
var collision_hook: hook.Detour(Fn4) = .{}; // processLinkedListCollision: thiscall RET 0x8
var entpos_hook: hook.Detour(Fn2) = .{}; // UpdateEntityAndChunksPositions: thiscall RET
var layers_hook: hook.Detour(Fn3) = .{}; // renderAllFrameLayers: thiscall RET 0x4
var textvb_hook: hook.Detour(Fn8v) = .{}; // RenderTextToVertexBuffer: thiscall RET 0x18
var complexgeo_hook: hook.Detour(Fn11) = .{}; // RenderComplexGeometry: stdcall RET 0x24
var entbounds_hook: hook.Detour(Fn3) = .{}; // updateEntitiesInBounds: thiscall RET 0x4
var textctr_hook: hook.Detour(Fn2) = .{}; // updateTextFrameCounter: thiscall RET
var spatial_hook: hook.Detour(Fn2) = .{}; // AddToSpatialGrid: thiscall RET
var raytri_hook: hook.Detour(Fn6) = .{}; // ray_triangle_intersection_indexed_ushort: stdcall RET 0x10
var linkedlist_hook: hook.Detour(Fn3) = .{}; // ManageLinkedListNode: thiscall RET 0x4
var color_hook: hook.Detour(Fn8v) = .{}; // calculateColorValues: thiscall RET 0x18
var setvec_hook: hook.Detour(Fn2) = .{}; // SetVector3: thiscall RET
var cull_hook: hook.Detour(Fn4) = .{}; // PerformSpatialCulling: thiscall RET 0x8
var colldet_hook: hook.Detour(Fn4) = .{}; // performCollisionDetection: thiscall RET 0x8
var activep_hook: hook.Detour(Fn4) = .{}; // ProcessActiveParticles: stdcall RET 0x8
var cbiter_hook: hook.Detour(Fn6) = .{}; // CallbackIterator: stdcall RET 0x10
var findguid_hook: hook.Detour(Fn4) = .{}; // FindObjectByGUID: stdcall RET 0x8, returns ptr
var raytri2_hook: hook.Detour(Fn10) = .{}; // RayTriangleIntersection: thiscall RET 0x20
var drawbatch_hook: hook.Detour(Fn2) = .{}; // DrawBatchProj: thiscall RET
var findlua_hook: hook.Detour(Fn3) = .{}; // FindLuaFunction: stdcall RET 0x4, returns ptr
var spritequad_hook: hook.Detour(Fn5) = .{}; // RenderSpriteQuads: thiscall RET 0xc
var scenenode_hook: hook.Detour(Fn2) = .{}; // renderSceneNode: thiscall RET
var terrain_hook: hook.Detour(Fn2) = .{}; // generateTerrainChunk: thiscall RET
var d3dtex_hook: hook.Detour(Fn4) = .{}; // D3D_SetTexture: thiscall RET 0x8
var bboxchk_hook: hook.Detour(Fn4) = .{}; // checkBoundingBoxIntersection: stdcall RET 0x8
var rotmat_hook: hook.Detour(Fn5) = .{}; // rotateMatrixByAxisAngle: thiscall RET 0xc
var triplane_hook: hook.Detour(Fn5) = .{}; // BuildTrianglePlanes: thiscall RET 0xc
var partsetup_hook: hook.Detour(Fn3) = .{}; // SetupParticleRendering: thiscall RET 0x4
var matmul_hook: hook.Detour(Fn3) = .{}; // multiplyMatrix4x4: fastcall RET 0x4
var textline_hook: hook.Detour(Fn6) = .{}; // renderTextLine: thiscall RET 0x10

// --- Detour functions (timing-only pass-through) ---

fn clipDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const s = rdtsc();
    if (AB_OTHER_HOOKS and ab_use_custom) {
        clipPolygonToSinglePlane(a, b, c);
        prof.clip_cycles +|= rdtsc() - s;
        prof.clip_calls +|= 1;
        return null; // original is void — EAX not read by callers
    }
    const ret = clip_hook.callOriginal(.{ a, b, c });
    prof.clip_cycles +|= rdtsc() - s;
    prof.clip_calls +|= 1;
    return ret;
}
fn glyphDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const s = rdtsc();

    if (ab_use_custom) {
        // a=ECX=FontObject*, b=EDX=unused, c=charCode, d=param2
        // Fast integer mix — golden ratio hash. Murmur2 was overkill for 3 integer keys.
        const hash = ((a ^ c *% 0x9E3779B9) ^ d) & GLYPH_CACHE_MASK;
        const entry = &glyph_cache[hash];

        if (entry.font_ptr == a and entry.char_code == c and entry.param2 == d) {
            // Cache hit — load cached width into ST(0) for caller
            asm volatile ("flds (%[p])"
                :: [p] "r" (&entry.width_bits)
            );
            prof.glyph_hits +|= 1;
            prof.glyph_cycles +|= rdtsc() - s;
            prof.glyph_calls +|= 1;
            return null; // EAX unused by callers, they read ST(0)
        }

        // Cache miss — call original (sets ST(0)), then capture the result
        const ret = glyph_hook.callOriginal(.{ a, b, c, d });

        // Read ST(0) without popping — original's float return is still on FPU stack
        var width_bits: u32 = undefined;
        asm volatile ("fsts (%[p])"
            :: [p] "r" (&width_bits)
        );

        entry.* = .{
            .font_ptr = a,
            .char_code = c,
            .param2 = d,
            .width_bits = width_bits,
        };

        prof.glyph_misses +|= 1;
        prof.glyph_cycles +|= rdtsc() - s;
        prof.glyph_calls +|= 1;
        return ret;
    }

    // BASELINE: just call original, measure cycles
    const ret = glyph_hook.callOriginal(.{ a, b, c, d });
    prof.glyph_cycles +|= rdtsc() - s;
    prof.glyph_calls +|= 1;
    return ret;
}
fn particleDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    // a=ECX(emitter), b=EDX(unused), c=particleData, d=vertexBuffers
    const s = rdtsc();
    if (ab_use_custom) {
        const result = renderParticleSprites_SSE(a, c, d);
        prof.particle_cycles +|= rdtsc() - s;
        prof.particle_calls +|= 1;
        return @ptrFromInt(result);
    }
    const ret = particle_hook.callOriginal(.{ a, b, c, d });
    prof.particle_cycles +|= rdtsc() - s;
    prof.particle_calls +|= 1;
    return ret;
}
fn collisionDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = collision_hook.callOriginal(.{ a, b, c, d });
    prof.collision_cycles +|= rdtsc() - s;
    prof.collision_calls +|= 1;
    return ret;
}
fn entposDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = entpos_hook.callOriginal(.{ a, b });
    prof.entpos_cycles +|= rdtsc() - s;
    prof.entpos_calls +|= 1;
    return ret;
}
fn layersDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = layers_hook.callOriginal(.{ a, b, c });
    prof.layers_cycles +|= rdtsc() - s;
    prof.layers_calls +|= 1;
    return ret;
}
fn textvbDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = textvb_hook.callOriginal(.{ a, b, c, d, e, f, g, h });
    prof.textvb_cycles +|= rdtsc() - s;
    prof.textvb_calls +|= 1;
    return ret;
}
fn complexgeoDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32, i: u32, j: u32, k: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = complexgeo_hook.callOriginal(.{ a, b, c, d, e, f, g, h, i, j, k });
    prof.complexgeo_cycles +|= rdtsc() - s;
    prof.complexgeo_calls +|= 1;
    return ret;
}
fn entboundsDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = entbounds_hook.callOriginal(.{ a, b, c });
    prof.entbounds_cycles +|= rdtsc() - s;
    prof.entbounds_calls +|= 1;
    return ret;
}
fn textctrDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = textctr_hook.callOriginal(.{ a, b });
    prof.textctr_cycles +|= rdtsc() - s;
    prof.textctr_calls +|= 1;
    return ret;
}
fn spatialDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = spatial_hook.callOriginal(.{ a, b });
    prof.spatial_cycles +|= rdtsc() - s;
    prof.spatial_calls +|= 1;
    return ret;
}
fn raytriDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const s = rdtsc();
    if (AB_OTHER_HOOKS and ab_use_custom) {
        const ret = rayTriangleIntersection(a, b, c, d, e, f);
        prof.raytri_cycles +|= rdtsc() - s;
        prof.raytri_calls +|= 1;
        return @ptrFromInt(ret);
    }
    const ret = raytri_hook.callOriginal(.{ a, b, c, d, e, f });
    prof.raytri_cycles +|= rdtsc() - s;
    prof.raytri_calls +|= 1;
    return ret;
}
fn linkedlistDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = linkedlist_hook.callOriginal(.{ a, b, c });
    prof.linkedlist_cycles +|= rdtsc() - s;
    prof.linkedlist_calls +|= 1;
    return ret;
}
fn colorDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    // a=ECX(ctx), b=EDX(unused), c=time, d=scale, e=outColor, f=outAlpha1, g=outAlpha2, h=outFloat
    const s = rdtsc();
    // SSE replacement benches at 10.7x but no in-game gain — dominated by L1 cache misses
    // on scattered ColorCtx structs. Fix: inline into full RenderParticleSprites replacement.
    const ret = color_hook.callOriginal(.{ a, b, c, d, e, f, g, h });
    prof.color_cycles +|= rdtsc() - s;
    prof.color_calls +|= 1;
    return ret;
}
fn setvecDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = setvec_hook.callOriginal(.{ a, b });
    prof.setvec_cycles +|= rdtsc() - s;
    prof.setvec_calls +|= 1;
    return ret;
}
fn cullDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = cull_hook.callOriginal(.{ a, b, c, d });
    prof.cull_cycles +|= rdtsc() - s;
    prof.cull_calls +|= 1;
    return ret;
}
fn colldetDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = colldet_hook.callOriginal(.{ a, b, c, d });
    prof.colldet_cycles +|= rdtsc() - s;
    prof.colldet_calls +|= 1;
    return ret;
}
fn activepDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = activep_hook.callOriginal(.{ a, b, c, d });
    prof.activep_cycles +|= rdtsc() - s;
    prof.activep_calls +|= 1;
    return ret;
}
fn cbiterDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = cbiter_hook.callOriginal(.{ a, b, c, d, e, f });
    prof.cbiter_cycles +|= rdtsc() - s;
    prof.cbiter_calls +|= 1;
    return ret;
}
fn findguidDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = findguid_hook.callOriginal(.{ a, b, c, d });
    prof.findguid_cycles +|= rdtsc() - s;
    prof.findguid_calls +|= 1;
    return ret;
}
fn raytri2Detour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, h: u32, i: u32, j: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = raytri2_hook.callOriginal(.{ a, b, c, d, e, f, g, h, i, j });
    prof.raytri2_cycles +|= rdtsc() - s;
    prof.raytri2_calls +|= 1;
    return ret;
}
fn drawbatchDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = drawbatch_hook.callOriginal(.{ a, b });
    prof.drawbatch_cycles +|= rdtsc() - s;
    prof.drawbatch_calls +|= 1;
    return ret;
}
fn findluaDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = findlua_hook.callOriginal(.{ a, b, c });
    prof.findlua_cycles +|= rdtsc() - s;
    prof.findlua_calls +|= 1;
    return ret;
}
fn spritequadDetour(a: u32, b: u32, c: u32, d: u32, e: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = spritequad_hook.callOriginal(.{ a, b, c, d, e });
    prof.spritequad_cycles +|= rdtsc() - s;
    prof.spritequad_calls +|= 1;
    return ret;
}
fn scenenodeDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = scenenode_hook.callOriginal(.{ a, b });
    prof.scenenode_cycles +|= rdtsc() - s;
    prof.scenenode_calls +|= 1;
    return ret;
}
fn terrainDetour(a: u32, b: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = terrain_hook.callOriginal(.{ a, b });
    prof.terrain_cycles +|= rdtsc() - s;
    prof.terrain_calls +|= 1;
    return ret;
}
fn d3dtexDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = d3dtex_hook.callOriginal(.{ a, b, c, d });
    prof.d3dtex_cycles +|= rdtsc() - s;
    prof.d3dtex_calls +|= 1;
    return ret;
}
fn bboxchkDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = bboxchk_hook.callOriginal(.{ a, b, c, d });
    prof.bboxchk_cycles +|= rdtsc() - s;
    prof.bboxchk_calls +|= 1;
    return ret;
}
fn rotmatDetour(a: u32, b: u32, c: u32, d: u32, e: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const s = rdtsc();
    if (AB_OTHER_HOOKS and ab_use_custom) {
        // thiscall: a=ECX=matrix, b=EDX=unused, c=angle, d=axis_ptr, e=is_unit
        rotateMatrixByAxisAngle(a, c, d, e);
        prof.rotmat_cycles +|= rdtsc() - s;
        prof.rotmat_calls +|= 1;
        return null; // void function, EAX not read by callers
    }
    const ret = rotmat_hook.callOriginal(.{ a, b, c, d, e });
    prof.rotmat_cycles +|= rdtsc() - s;
    prof.rotmat_calls +|= 1;
    return ret;
}
fn triplaneDetour(a: u32, b: u32, c: u32, d: u32, e: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const s = rdtsc();
    if (AB_OTHER_HOOKS and ab_use_custom) {
        const ret = buildTrianglePlanes(a, b, c, d, e);
        prof.triplane_cycles +|= rdtsc() - s;
        prof.triplane_calls +|= 1;
        return @ptrFromInt(ret);
    }
    const ret = triplane_hook.callOriginal(.{ a, b, c, d, e });
    prof.triplane_cycles +|= rdtsc() - s;
    prof.triplane_calls +|= 1;
    return ret;
}
fn partsetupDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = partsetup_hook.callOriginal(.{ a, b, c });
    prof.partsetup_cycles +|= rdtsc() - s;
    prof.partsetup_calls +|= 1;
    return ret;
}
fn matmulDetour(a: u32, b: u32, c: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });
    const s = rdtsc();
    if (AB_OTHER_HOOKS and ab_use_custom) {
        // fastcall: a=ECX=result, b=EDX=left, c=right
        const ret = multiplyMatrix4x4(a, b, c);
        prof.matmul_cycles +|= rdtsc() - s;
        prof.matmul_calls +|= 1;
        return @ptrFromInt(ret);
    }
    const ret = matmul_hook.callOriginal(.{ a, b, c });
    prof.matmul_cycles +|= rdtsc() - s;
    prof.matmul_calls +|= 1;
    return ret;
}
fn textlineDetour(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const s = rdtsc();
    const ret = textline_hook.callOriginal(.{ a, b, c, d, e, f });
    prof.textline_cycles +|= rdtsc() - s;
    prof.textline_calls +|= 1;
    return ret;
}

// =============================================================================
// Hook: blit_hub (0x5a4f60)
// __fastcall(ECX=int* vec2size, EDX=unknownFuncIndex,
//   stack: srcAddr, srcStep, srcFormat, dstAddr, dstStep, dstFormat)
// RET 0x18 (6 stack params)
// Assembly-verified: PUSH EBP; MOV EBP,ESP; MOV ESI,EDX; MOV EDI,ECX; RET 0x18
// =============================================================================

const BlitHubFn = fn (u32, u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
const BlitHubPtr = *const BlitHubFn;
var blit_hub_hook: hook.Detour(BlitHubFn) = .{};
var unitxp_blit: ?BlitHubPtr = null; // UnitXP's detour, captured before clobber

fn blitMemcpy(w: u32, h: u32, src: u32, src_pitch: u32, dst: u32, dst_pitch: u32, pixel_size: u32) void {
    const row_bytes = w * pixel_size;
    if (src_pitch == dst_pitch and row_bytes == src_pitch) {
        // Contiguous -- single memcpy
        const total = w * h * pixel_size;
        const s: [*]const u8 = @ptrFromInt(src);
        const d: [*]u8 = @ptrFromInt(dst);
        @memcpy(d[0..total], s[0..total]);
    } else {
        // Row-by-row
        var s = src;
        var d = dst;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const sp: [*]const u8 = @ptrFromInt(s);
            const dp: [*]u8 = @ptrFromInt(d);
            @memcpy(dp[0..row_bytes], sp[0..row_bytes]);
            s += src_pitch;
            d += dst_pitch;
        }
    }
}

fn blitHubDetour(vec2size: u32, func_index: u32, src_addr: u32, src_step: u32, src_fmt: u32, dst_addr: u32, dst_step: u32, dst_fmt: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Ensure blit is initialized (game lazy-inits at 0xC0F558)
    const init_flag: *u32 = @ptrFromInt(0xC0F558);
    if (init_flag.* == 0) {
        hook.call(fn () callconv(hook.cc.fastcall) void, 0x5A4FC0, .{});
        init_flag.* = 1;
    }

    const w = hook.readMem(u32, vec2size);
    const h = hook.readMem(u32, vec2size + 4);

    const start = rdtsc();
    if (ab_use_custom and func_index == 0 and src_fmt == dst_fmt) {
        // CUSTOM: memcpy fast path for matching formats
        switch (src_fmt) {
            1 => { blitMemcpy(w, h, src_addr, src_step, dst_addr, dst_step, 4); },     // ARGB 32bpp
            2, 4 => { blitMemcpy(w, h, src_addr, src_step, dst_addr, dst_step, 2); },  // RGB 16bpp
            5 => { // DXT compressed -- no pitch, w*h*4/8 bytes
                const wc = @max(w, 4);
                const hc = @max(h, 4);
                const len = wc * hc / 2; // 4 bits per pixel
                const s: [*]const u8 = @ptrFromInt(src_addr);
                const d: [*]u8 = @ptrFromInt(dst_addr);
                @memcpy(d[0..len], s[0..len]);
            },
            6, 7 => { // 8bpp formats -- no pitch, w*h bytes
                const wc = @max(w, 4);
                const hc = @max(h, 4);
                const len = wc * hc;
                const s: [*]const u8 = @ptrFromInt(src_addr);
                const d: [*]u8 = @ptrFromInt(dst_addr);
                @memcpy(d[0..len], s[0..len]);
            },
            else => {
                // Unknown format -- fall through to original
                blit_hub_hook.callOriginal(.{ vec2size, func_index, src_addr, src_step, src_fmt, dst_addr, dst_step, dst_fmt });
            },
        }
    } else {
        // BASELINE: original function
        blit_hub_hook.callOriginal(.{ vec2size, func_index, src_addr, src_step, src_fmt, dst_addr, dst_step, dst_fmt });
    }
    const elapsed = rdtsc() - start;
    if (AB_OTHER_HOOKS and ab_use_custom) {
        blit_total_custom.cycles +|= elapsed;
        blit_total_custom.calls +|= 1;
    } else {
        blit_total_baseline.cycles +|= elapsed;
        blit_total_baseline.calls +|= 1;
    }
}

// =============================================================================
// Lua API: SetWeatherOverride(type, intensity)
// Calls SetWeatherType (0x67baf0) directly on the global weather object at 0xC6326C.
// __thiscall(ECX=weatherObj, stack: type(int), intensity(float), smoothFade(bool))
// RET 0x0C — assembly-verified: MOV ESI,ECX; RET 0x0C
// type: 0=clear, 1=rain, 2=snow, 3=sandstorm
// intensity: 0.0-1.0
// smoothFade: 1=gradual transition, 0=abrupt (immediate). We use 0.
// =============================================================================

pub fn luaSetWeatherOverride(L: *anyopaque) callconv(.c) u32 {
    const L_ptr = @intFromPtr(L);
    const nargs = hook.call(fn (usize) callconv(hook.cc.fastcall) i32, 0x6F3070, .{L_ptr}); // lua_gettop
    if (nargs < 2) return 0;

    const weather_type: i32 = @intFromFloat(hook.call(fn (usize, i32) callconv(hook.cc.fastcall) f64, 0x6F3620, .{ L_ptr, 1 })); // lua_tonumber
    const intensity: f32 = @floatCast(hook.call(fn (usize, i32) callconv(hook.cc.fastcall) f64, 0x6F3620, .{ L_ptr, 2 }));

    const weather_obj = hook.readMem(u32, 0x00C6326C);
    if (weather_obj == 0) return 0;

    // SetWeatherType: __thiscall(ECX=weatherObj, stack: type, intensity, smoothFade)
    // fastcall mapping: ECX=this, EDX=unused, stack: type, intensity_bits, smoothFade
    const intensity_bits: u32 = @bitCast(intensity);
    hook.call(fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void, 0x67baf0, .{
        weather_obj, 0, @as(u32, @bitCast(weather_type)), intensity_bits, 0,
    });

    return 0;
}

// =============================================================================
// Unified stats dump
// =============================================================================

fn pct(part: u64, total: u64) u64 {
    if (total == 0) return 0;
    return part *| 1000 / total; // tenths of a percent
}

fn dumpStats() void {
    const f = prof.frames;
    if (f == 0) return;

    const wall = prof.wall_cycles;

    // transformMatrix4x4
    const t44_real = prof.t44_calls -| prof.t44_early;
    const t44_avg_bones = if (t44_real > 0) prof.t44_bones / t44_real else 0;

    // Percentages of total frame time (×10 for one decimal place)
    const erp_pct = pct(prof.erp_cycles, wall);
    const rf_pct = pct(prof.rf_cycles, wall);
    const t44_pct = pct(prof.t44_cycles, wall);
    const rtq_pct = pct(prof.rtq_cycles, wall);
    const mov_pct = pct(prof.mov_cycles, wall);

    // @3GHz: cycles / 3_000_000 = ms, cycles / 3_000 = us
    const MS_DIVISOR = 3_000_000;
    const wall_ms = wall / MS_DIVISOR;
    const erp_ms = prof.erp_cycles / MS_DIVISOR;
    const rf_ms = prof.rf_cycles / MS_DIVISOR;
    const t44_ms = prof.t44_cycles / MS_DIVISOR;
    const rtq_ms = prof.rtq_cycles / MS_DIVISOR;
    const mov_ms = prof.mov_cycles / MS_DIVISOR;
    const t44_avg_us = if (t44_real > 0) prof.t44_cycles / t44_real / 3000 else 0;

    const mode: [*:0]const u8 = if (ab_use_custom) "CUSTOM" else "BASELINE";
    // Frame jitter: convert min/max/avg from cycles to tenths-of-ms for one decimal place
    const US10_DIV = 300; // cycles / 300 = tenths of us... no, cycles / 300_000 = tenths of ms
    const TENTH_MS_DIV: u64 = 300_000; // @3GHz: cycles / 300_000 = tenths of ms
    const frame_avg_t = if (f > 0) wall / f / TENTH_MS_DIV else 0;
    const frame_min_t = if (prof.frame_min_cycles != std.math.maxInt(u64)) prof.frame_min_cycles / TENTH_MS_DIV else 0;
    const frame_max_t = prof.frame_max_cycles / TENTH_MS_DIV;
    _ = US10_DIV;

    const bt = if (ab_use_custom) blit_total_custom else blit_total_baseline;

    log.fmt(
        \\[prof:{s}] {d} frames, wall={d}ms, frame: avg={d}.{d}ms min={d}.{d}ms max={d}.{d}ms
        \\
    , .{
        mode, f, wall_ms,
        frame_avg_t / 10, frame_avg_t % 10,
        frame_min_t / 10, frame_min_t % 10,
        frame_max_t / 10, frame_max_t % 10,
    });
    log.fmt(
        \\  ms: erp={d} rf={d} t44={d} rtq={d} mov={d}
        \\  %frame: erp={d}.{d}% rf={d}.{d}% t44={d}.{d}% rtq={d}.{d}% mov={d}.{d}%
        \\  calls/f: erp={d} rf={d} t44={d}({d}skip) rtq={d} mov={d}
        \\  t44: {d}us/work bones={d}/{d} depth={d} | rtq_items/f={d}
        \\  blit: {d}ms/{d}calls
        \\
    , .{
        erp_ms, rf_ms, t44_ms, rtq_ms, mov_ms,
        erp_pct / 10, erp_pct % 10,
        rf_pct / 10,  rf_pct % 10,
        t44_pct / 10, t44_pct % 10,
        rtq_pct / 10, rtq_pct % 10,
        mov_pct / 10, mov_pct % 10,
        prof.erp_calls / f,
        prof.rf_calls / f,
        prof.t44_calls / f,
        prof.t44_early / f,
        prof.rtq_calls / f,
        prof.mov_calls / f,
        t44_avg_us,
        t44_avg_bones, prof.t44_max_bones, prof.t44_max_depth,
        prof.rtq_items / f,
        bt.cycles / MS_DIVISOR, bt.calls,
    });

    // Hotspot table: name, %frame, ms, calls/f
    const HotEntry = struct { name: [*:0]const u8, cycles: u64, calls: u64 };
    const hotspots = [_]HotEntry{
        .{ .name = "clip",       .cycles = prof.clip_cycles,      .calls = prof.clip_calls },
        .{ .name = "glyph",      .cycles = prof.glyph_cycles,     .calls = prof.glyph_calls },
        .{ .name = "particle",   .cycles = prof.particle_cycles,  .calls = prof.particle_calls },
        .{ .name = "collision",  .cycles = prof.collision_cycles,  .calls = prof.collision_calls },
        .{ .name = "entpos",     .cycles = prof.entpos_cycles,    .calls = prof.entpos_calls },
        .{ .name = "layers",     .cycles = prof.layers_cycles,    .calls = prof.layers_calls },
        .{ .name = "textvb",     .cycles = prof.textvb_cycles,    .calls = prof.textvb_calls },
        .{ .name = "complexgeo", .cycles = prof.complexgeo_cycles, .calls = prof.complexgeo_calls },
        .{ .name = "entbounds",  .cycles = prof.entbounds_cycles, .calls = prof.entbounds_calls },
        .{ .name = "textctr",    .cycles = prof.textctr_cycles,   .calls = prof.textctr_calls },
        .{ .name = "spatial",    .cycles = prof.spatial_cycles,   .calls = prof.spatial_calls },
        .{ .name = "raytri",     .cycles = prof.raytri_cycles,    .calls = prof.raytri_calls },
        .{ .name = "linkedlist", .cycles = prof.linkedlist_cycles, .calls = prof.linkedlist_calls },
        .{ .name = "color",      .cycles = prof.color_cycles,     .calls = prof.color_calls },
        .{ .name = "setvec",     .cycles = prof.setvec_cycles,    .calls = prof.setvec_calls },
        .{ .name = "cull",       .cycles = prof.cull_cycles,      .calls = prof.cull_calls },
        .{ .name = "colldet",    .cycles = prof.colldet_cycles,   .calls = prof.colldet_calls },
        .{ .name = "activep",    .cycles = prof.activep_cycles,   .calls = prof.activep_calls },
        .{ .name = "cbiter",     .cycles = prof.cbiter_cycles,    .calls = prof.cbiter_calls },
        .{ .name = "findguid",   .cycles = prof.findguid_cycles,  .calls = prof.findguid_calls },
        .{ .name = "raytri2",    .cycles = prof.raytri2_cycles,   .calls = prof.raytri2_calls },
        .{ .name = "drawbatch",  .cycles = prof.drawbatch_cycles, .calls = prof.drawbatch_calls },
        .{ .name = "findlua",    .cycles = prof.findlua_cycles,   .calls = prof.findlua_calls },
        .{ .name = "spritequad", .cycles = prof.spritequad_cycles, .calls = prof.spritequad_calls },
        .{ .name = "scenenode",  .cycles = prof.scenenode_cycles, .calls = prof.scenenode_calls },
        .{ .name = "terrain",    .cycles = prof.terrain_cycles,   .calls = prof.terrain_calls },
        .{ .name = "d3dtex",     .cycles = prof.d3dtex_cycles,    .calls = prof.d3dtex_calls },
        .{ .name = "bboxchk",    .cycles = prof.bboxchk_cycles,   .calls = prof.bboxchk_calls },
        .{ .name = "rotmat",     .cycles = prof.rotmat_cycles,    .calls = prof.rotmat_calls },
        .{ .name = "triplane",   .cycles = prof.triplane_cycles,  .calls = prof.triplane_calls },
        .{ .name = "partsetup",  .cycles = prof.partsetup_cycles, .calls = prof.partsetup_calls },
        .{ .name = "matmul",     .cycles = prof.matmul_cycles,    .calls = prof.matmul_calls },
        .{ .name = "textline",   .cycles = prof.textline_cycles,  .calls = prof.textline_calls },
    };
    for (hotspots) |h| {
        if (h.calls > 0) {
            const hp = pct(h.cycles, wall);
            const is_micro = std.mem.eql(u8, std.mem.span(h.name), "glyph");
            if (is_micro) {
                log.fmt("  {s}: {d}.{d}% {d}us {d}c/f\n", .{
                    h.name,
                    hp / 10, hp % 10,
                    h.cycles / 3_000,
                    h.calls / f,
                });
            } else {
                log.fmt("  {s}: {d}.{d}% {d}ms {d}c/f\n", .{
                    h.name,
                    hp / 10, hp % 10,
                    h.cycles / MS_DIVISOR,
                    h.calls / f,
                });
            }
        }
    }

    // Glyph cache stats (custom mode only)
    const glyph_total = prof.glyph_hits +| prof.glyph_misses;
    if (glyph_total > 0) {
        const hit_pct = pct(prof.glyph_hits, glyph_total);
        log.fmt("  glyph_cache: {d}.{d}% hit ({d}hit/{d}miss)\n", .{
            hit_pct / 10, hit_pct % 10,
            prof.glyph_hits,
            prof.glyph_misses,
        });
    }

    // Dump particle VB stride info (once)
    if (stride_info[0] != 0 and !stride_dumped) {
        stride_dumped = true;
        log.fmt("  vb_strides: pos={d} norm={d} color={d} tc={d}\n", .{
            stride_info[0], stride_info[1], stride_info[2], stride_info[3],
        });
        log.fmt("  vb_bases: pos=0x{x} norm=0x{x} color=0x{x} tc=0x{x}\n", .{
            stride_info[4], stride_info[5], stride_info[6], stride_info[7],
        });
    }

    // Flip A/B mode
    ab_use_custom = !ab_use_custom;
    diag_cmp_count = 0;
    prof = ProfState{};
}

// =============================================================================
// Install / remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);

    // BINARY PATCH TEST: copy REF's x87 code directly over original at 0x714260.
    // No hook — game calls REF's code at the original address. Return addresses
    // from game function calls will point into game .text, not DLL .text.
    // If renders → game functions check return addresses (anti-cheat).
    // If black → issue is something else entirely.
    const BINARY_PATCH_TEST = false;
    if (BINARY_PATCH_TEST) {
        const ref_addr = @intFromPtr(&transformMatrix4x4_REF);
        const ref_size: u32 = 0x2320; // main function ends at particleLoops start (includes epilogue + FPU stubs)
        const game_addr: u32 = 0x714260;

        // Copy REF's main function over the original (handles VirtualProtect)
        const src: [*]const u8 = @ptrFromInt(ref_addr);
        hook.writeProtected(game_addr, src[0..ref_size]);

        // INT3-fill the remaining original bytes (crash on overrun)
        var cc_buf: [512]u8 = .{0xCC} ** 512;
        const remaining = @as(u32, 17703) - ref_size;
        var filled: u32 = 0;
        while (filled < remaining) {
            const chunk = @min(512, remaining - filled);
            hook.writeProtected(game_addr + ref_size + filled, cc_buf[0..chunk]);
            filled += chunk;
        }

        // Fix up 2 relative CALL (E8) instructions to helper functions.
        // In the DLL, they resolve from ref_addr+site to DLL helper addresses.
        // After copy to game_addr, we recompute the rel32 to reach the same targets.
        const e8_sites = [_]u32{ 0x22CE, 0x22E6 };
        for (e8_sites) |site| {
            // Read the resolved rel32 from DLL copy to get absolute target
            const dll_call_addr = ref_addr + site;
            const target = hook.rel32Target(dll_call_addr);
            // Write new rel32 for the game-address copy
            const game_call_addr = game_addr + site;
            var rel_buf: [4]u8 = undefined;
            hook.writeRel32(&rel_buf, game_call_addr + 1, target);
            hook.writeProtected(game_call_addr + 1, &rel_buf);
        }

        log.fmt("BINARY PATCH: {d} bytes REF@0x{x:0>8} -> 0x{x:0>8}, {d} E8 fixups\n", .{ ref_size, ref_addr, game_addr, e8_sites.len });
    } else {
        _ = transform_hook.attach(0x714260, &transformDetour);
        original_trampoline = @intCast(transform_hook.inner.trampoline);
    }
    _ = teardown_hook.attach(0x491180, &teardownDetour);
    _ = render_frame_hook.attach(0x707680, &renderFrameDetour);
    _ = exec_render_pass_hook.attach(0x708900, &execRenderPassDetour);
    _ = world_update_hook.attach(0x482EA0, &worldUpdateDetour);
    _ = render_quads_hook.attach(0x76FB00, &renderQuadsDetour);
    _ = movement_hook.attach(0x616620, &movementDetour);
    // _ = interp_kf_hook.attach(0x713ea0, &interpKfDetour); // disabled: pure passthrough
    _ = clip_hook.attach(0x6318c0, &clipDetour);
    _ = glyph_hook.attach(0x5ca2d0, &glyphDetour);
    _ = particle_hook.attach(0x7b2a50, &particleDetour);
    _ = collision_hook.attach(0x6abc40, &collisionDetour);
    _ = entpos_hook.attach(0x6afad0, &entposDetour);
    _ = layers_hook.attach(0x765650, &layersDetour);
    _ = textvb_hook.attach(0x5ccbe0, &textvbDetour);
    _ = complexgeo_hook.attach(0x58a3d0, &complexgeoDetour);
    _ = entbounds_hook.attach(0x6c1f70, &entboundsDetour);
    _ = textctr_hook.attach(0x5cdf40, &textctrDetour);
    _ = spatial_hook.attach(0x6816f0, &spatialDetour);
    _ = raytri_hook.attach(0x7c29f0, &raytriDetour);
    _ = linkedlist_hook.attach(0x710b90, &linkedlistDetour);
    _ = color_hook.attach(0x7b9b10, &colorDetour);
    _ = setvec_hook.attach(0x686640, &setvecDetour);
    _ = cull_hook.attach(0x6b8c60, &cullDetour);
    _ = colldet_hook.attach(0x6b88e0, &colldetDetour);
    _ = activep_hook.attach(0x7b5a10, &activepDetour);
    _ = cbiter_hook.attach(0x404130, &cbiterDetour);
    _ = findguid_hook.attach(0x464890, &findguidDetour);
    // _ = raytri2_hook.attach(0x632700, &raytri2Detour);
    _ = drawbatch_hook.attach(0x70cb30, &drawbatchDetour);
    _ = findlua_hook.attach(0x702000, &findluaDetour);
    _ = spritequad_hook.attach(0x5a0f50, &spritequadDetour);
    _ = scenenode_hook.attach(0x718960, &scenenodeDetour);
    _ = terrain_hook.attach(0x6cffc0, &terrainDetour);
    _ = d3dtex_hook.attach(0x593840, &d3dtexDetour);
    _ = bboxchk_hook.attach(0x6b8b70, &bboxchkDetour);
    _ = rotmat_hook.attach(0x7bdd60, &rotmatDetour);
    _ = triplane_hook.attach(0x632460, &triplaneDetour);
    _ = partsetup_hook.attach(0x7b3d20, &partsetupDetour);
    _ = matmul_hook.attach(0x7bc6a0, &matmulDetour);
    _ = textline_hook.attach(0x5ce0c0, &textlineDetour);

    // TSC timer calibration (ported from VanillaFixes)
    timer_fix.init();
    const ti = timer_fix.getInfo();
    if (ti.calibrated) {
        if (ti.orig_freq == 1000) {
            log.fmt("timer_fix: TSC was OFF, enabled with freq {d}\n", .{ti.cal_freq});
        } else {
            log.fmt("timer_fix: recalibrated TSC freq {d} -> {d} ({d}.{d}% drift)\n", .{ ti.orig_freq, ti.cal_freq, ti.diff_pct_x10 / 10, ti.diff_pct_x10 % 10 });
        }
    } else if (ti.cal_freq > 0) {
        log.print("timer_fix: already calibrated, skipping\n");
    }

    // blit_hub installed in lateInit() to clobber UnitXP's hook
    log.print("transform44: 39 profiling hooks installed (blit_hub deferred)\n");
    if (bisect_stop_section != 0) {
        log.fmt("  BISECT MODE: REF stops after section {d}, then original trampoline\n", .{bisect_stop_section});
    }
}

/// Called from engineInitDetour — after UnitXP has hooked blit_hub.
/// Captures UnitXP's detour address, restores original prologue, then hooks.
pub fn lateInit() void {
    if (!g_is_hook_owner) return;

    const BLIT_ADDR = 0x5a4f60;
    const src: [*]const u8 = @ptrFromInt(BLIT_ADDR);

    // If UnitXP hooked it, first byte is E9 (relative JMP)
    if (src[0] == 0xE9) {
        // Decode rel32 target: addr + 5 + *(i32*)(addr+1)
        const rel: i32 = @bitCast(hook.readMem(u32, BLIT_ADDR + 1));
        const target: usize = @intCast(@as(i64, @intCast(BLIT_ADDR + 5)) + rel);
        unitxp_blit = @ptrFromInt(target);
        log.fmt("blit_hub: captured UnitXP detour at 0x{x}\n", .{target});
    }

    // Restore original prologue (from Ghidra disasm), clobbering UnitXP's E9 JMP
    // 55 8B EC A1 58 F5 C0 00 = PUSH EBP; MOV EBP,ESP; MOV EAX,[0xc0f558]
    hook.writeProtected(BLIT_ADDR, &.{ 0x55, 0x8B, 0xEC, 0xA1, 0x58, 0xF5, 0xC0, 0x00 });
    _ = blit_hub_hook.attach(BLIT_ADDR, &blitHubDetour);
    log.print("blit_hub: hooked (true original baseline)\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        transform_hook.detach();
        render_frame_hook.detach();
        exec_render_pass_hook.detach();
        world_update_hook.detach();
        teardown_hook.detach();
        render_quads_hook.detach();
        movement_hook.detach();
        interp_kf_hook.detach();
        clip_hook.detach();
        glyph_hook.detach();
        particle_hook.detach();
        collision_hook.detach();
        entpos_hook.detach();
        layers_hook.detach();
        textvb_hook.detach();
        complexgeo_hook.detach();
        entbounds_hook.detach();
        textctr_hook.detach();
        spatial_hook.detach();
        raytri_hook.detach();
        linkedlist_hook.detach();
        color_hook.detach();
        setvec_hook.detach();
        cull_hook.detach();
        colldet_hook.detach();
        activep_hook.detach();
        cbiter_hook.detach();
        findguid_hook.detach();
        raytri2_hook.detach();
        drawbatch_hook.detach();
        findlua_hook.detach();
        spritequad_hook.detach();
        scenenode_hook.detach();
        terrain_hook.detach();
        d3dtex_hook.detach();
        bboxchk_hook.detach();
        rotmat_hook.detach();
        triplane_hook.detach();
        partsetup_hook.detach();
        matmul_hook.detach();
        textline_hook.detach();
        blit_hub_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
