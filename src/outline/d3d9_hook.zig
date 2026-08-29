//! D3D9 vtable hooks for outline rendering.
//!
//! Patches IDirect3DDevice9 vtable entries for EndScene, DrawIndexedPrimitive,
//! and Reset via the game's existing device (shared vtable across all devices).
//!
//! - **EndScene**: per-frame object scan, JFA pipeline for outline compositing.
//! - **DIP**: caches outline-target draws for EndScene replay; writes stencil
//!   marks where models pass the terrain depth test (stencil=1 = visible).
//! - **Reset**: forces D24S8 depth/stencil format, releases resources.
//!
//! Batch reordering in model_hook.zig partitions M2 batches into 3 groups:
//! game objects first (write depth), then outline targets (DIP hook writes
//! stencil against that depth), then other players/gear/NPCs. Outlines are
//! occluded by world/WMO/game objects but show through other players.

const std = @import("std");
const hook = @import("zhook");
const types = @import("types.zig");
const tracker = @import("tracker.zig");
const model_hook = @import("model_hook.zig");

const WINAPI = std.builtin.CallingConvention.winapi;

// =============================================================================
// Windows / D3D9 externs
// =============================================================================

extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;

// =============================================================================
// COM helper: read vtable pointer, call method by index
// =============================================================================

inline fn vt(obj: *anyopaque) [*]usize {
    return @ptrFromInt(hook.readMem(u32, @intFromPtr(obj)));
}

/// Call a COM method that takes only (self) and returns HRESULT.
fn comCall0(obj: *anyopaque, idx: usize) i32 {
    const f: *const fn (*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(obj)[idx]);
    return f(obj);
}

/// Release a COM object.
fn comRelease(obj: *anyopaque) void {
    _ = comCall0(obj, types.VT.Release);
}

// =============================================================================
// Saved original vtable function pointers
// =============================================================================

var orig_endscene: usize = 0;
var orig_dip: usize = 0;
var orig_reset: usize = 0;
var d3d9_vtable: ?[*]usize = null;
var hooks_installed: bool = false;

// Sticky diagnostics for the in-game OutlineDebug() command.
pub var debug_endscene_seen: bool = false;
pub var debug_dip_seen: bool = false;
pub var debug_outline_dip_seen: bool = false;
pub var debug_cached_draw_seen: bool = false;
pub var debug_translucent_skipped_seen: bool = false;
pub var debug_state_block_seen: bool = false;
pub var debug_outer_state_restore_seen: bool = false;
pub var debug_additive_skipped_seen: bool = false;
pub var debug_shaders_ready_seen: bool = false;
pub var debug_resources_ready_seen: bool = false;
pub var debug_pipeline_entered_seen: bool = false;
pub var debug_pipeline_ready_seen: bool = false;
pub var debug_shader_stage: u32 = 0;
pub var debug_resource_stage: u32 = 0;
pub var debug_shader_assemble_hr: i32 = 0;
pub var debug_shader_create_hr: i32 = 0;
pub var debug_texture_create_hr: i32 = 0;
pub var debug_shader_error_text: [160]u8 = [_]u8{0} ** 160;

pub fn hooksInstalled() bool {
    return hooks_installed;
}

pub const LiveHookState = struct {
    vtable_found: bool = false,
    same_vtable: bool = false,
    endscene_ours: bool = false,
    dip_ours: bool = false,
    reset_ours: bool = false,
    endscene_ptr: usize = 0,
    dip_ptr: usize = 0,
    reset_ptr: usize = 0,
};

/// Read the game's current D3D9 vtable and verify whether our entries are
/// still installed. This is intentionally queried on demand from OutlineDebug.
pub fn getLiveHookState() LiveHookState {
    const cur = getD3D9VTable() orelse return .{};
    var out: LiveHookState = .{ .vtable_found = true };
    out.same_vtable = if (d3d9_vtable) |saved| @intFromPtr(saved) == @intFromPtr(cur) else false;
    out.endscene_ptr = cur[types.VT.EndScene];
    out.dip_ptr = cur[types.VT.DrawIndexedPrimitive];
    out.reset_ptr = cur[types.VT.Reset];
    out.endscene_ours = out.endscene_ptr == @intFromPtr(&hkEndScene);
    out.dip_ours = out.dip_ptr == @intFromPtr(&hkDIP);
    out.reset_ours = out.reset_ptr == @intFromPtr(&hkReset);
    return out;
}

pub var debug_late_rehook_attempted: bool = false;
pub var debug_late_rehook_succeeded: bool = false;

/// DEBUG15: re-apply the D3D9 hooks on demand after the client is fully loaded.
/// If the current entries are no longer ours, chain whatever is there now as
/// the new originals, then patch the three entries again.
pub fn lateRehookIfLost() bool {
    debug_late_rehook_attempted = true;

    const cur = getD3D9VTable() orelse return false;
    d3d9_vtable = cur;

    const ours_end = @intFromPtr(&hkEndScene);
    const ours_dip = @intFromPtr(&hkDIP);
    const ours_reset = @intFromPtr(&hkReset);

    if (cur[types.VT.EndScene] != ours_end) {
        if (!patchVtableEntry(cur, types.VT.EndScene, ours_end, &orig_endscene)) return false;
    }
    if (cur[types.VT.DrawIndexedPrimitive] != ours_dip) {
        if (!patchVtableEntry(cur, types.VT.DrawIndexedPrimitive, ours_dip, &orig_dip)) return false;
    }
    if (cur[types.VT.Reset] != ours_reset) {
        if (!patchVtableEntry(cur, types.VT.Reset, ours_reset, &orig_reset)) return false;
    }

    hooks_installed = true;
    const live = getLiveHookState();
    debug_late_rehook_succeeded = live.endscene_ours and live.dip_ours and live.reset_ours;
    return debug_late_rehook_succeeded;
}

/// True until the first EndScene verifies (and if needed, forces) D24S8 format.
var need_force_reset: bool = false;
pub var debug_stencil_ready: bool = false;
pub var debug_stencil_format: u32 = 0;
pub var debug_stencil_reset_hr: i32 = 0;

pub fn requestStencilCheck() void {
    // DEBUG23: intentionally disabled. Forcing IDirect3DDevice9::Reset on this
    // client can hang the render thread while audio/game logic keeps running.
    need_force_reset = false;
}

// =============================================================================
// Shader resources
// =============================================================================

var outline_ps: ?*anyopaque = null; // flat-color PS (solid silhouettes)
var outline_alpha_ps: ?*anyopaque = null; // texture-alpha-aware silhouette PS
var outline_rgb_ps: ?*anyopaque = null; // additive/modulated texture coverage PS
var material_mask_ps: ?*anyopaque = null; // exact-material scratch -> binary mask
var jfa_init_ps: ?*anyopaque = null; // JFA seed init PS
var jfa_prop_ps: ?*anyopaque = null; // JFA propagation PS
var jfa_decode_ps: ?*anyopaque = null; // JFA decode + composite PS
var debug_sil_ps: ?*anyopaque = null; // debug: composite silhouette directly
var shaders_attempted: bool = false;

// Debug: set to true to skip JFA and composite raw silhouette RT to backbuffer.
// Used to diagnose whether banding artifacts originate in the silhouette (Phase 1
// replay / stale VB) or in the JFA pipeline (Phase 2 shader bug).
const DEBUG_SHOW_SILHOUETTE = false;

// D3DXAssembleShader function pointer (loaded dynamically)
const D3DXAssembleShaderFn = *const fn (
    [*]const u8, // pSrcData
    u32, // SrcDataLen
    ?*anyopaque, // pDefines
    ?*anyopaque, // pInclude
    u32, // Flags
    *?*anyopaque, // ppShader (ID3DXBuffer**)
    *?*anyopaque, // ppErrorMsgs (ID3DXBuffer**)
) callconv(hook.cc.stdcall) i32;

// =============================================================================
// Render target resources
// =============================================================================

var rt_material_tex: ?*anyopaque = null; // A8R8G8B8 exact-material scratch
var rt_material_surf: ?*anyopaque = null;
var rt_silhouette_tex: ?*anyopaque = null; // A8R8G8B8 normalized silhouette mask
var rt_silhouette_surf: ?*anyopaque = null;
var rt_jfa_a_tex: ?*anyopaque = null; // G16R16F JFA ping texture
var rt_jfa_a_surf: ?*anyopaque = null;
var rt_jfa_b_tex: ?*anyopaque = null; // G16R16F JFA pong texture
var rt_jfa_b_surf: ?*anyopaque = null;
var resource_width: u32 = 0;
var resource_height: u32 = 0;

// =============================================================================
// Per-frame flags
// =============================================================================

var frame_has_outlines: bool = false;
var silhouette_cleared: bool = false;

// =============================================================================
// Cached draw calls for EndScene replay (avoids double-DIP in hook)
// =============================================================================
// Instead of drawing silhouettes inside the DIP hook (which corrupts WoW's
// internal rendering state), we cache draw parameters and replay them in
// EndScene before the JFA pipeline. This matches the C reference approach.

const MAX_CACHED_DRAWS = 32;
const MAX_VS_CONST_REGS = 256;

const CachedDraw = struct {
    // Draw call parameters
    prim_type: u32 = 0,
    base_vtx: i32 = 0,
    min_vtx: u32 = 0,
    num_verts: u32 = 0,
    start_idx: u32 = 0,
    prim_count: u32 = 0,
    // GPU state (AddRef'd COM objects - released after replay)
    vb: ?*anyopaque = null,
    vb_offset: u32 = 0,
    vb_stride: u32 = 0,
    ib: ?*anyopaque = null,
    vertex_decl: ?*anyopaque = null,
    vertex_shader: ?*anyopaque = null,
    tex: [4]?*anyopaque = .{ null, null, null, null },
    pixel_shader: ?*anyopaque = null,
    state_block: ?*anyopaque = null,
    alpha_op: [4]u32 = .{ 1, 1, 1, 1 },
    alpha_arg1: [4]u32 = .{ 0, 0, 0, 0 },
    alpha_arg2: [4]u32 = .{ 0, 0, 0, 0 },
    alpha_test_enable: u32 = 0,
    alpha_ref: u32 = 0,
    alpha_func: u32 = types.D3DCMP_ALWAYS,
    alpha_blend_enable: u32 = 0,
    src_blend: u32 = types.D3DBLEND_ONE,
    dst_blend: u32 = types.D3DBLEND_ZERO,
    // Per-model outline info
    color: u32 = 0,
    category: types.ModelCategory = .none,
    // VS constants (bone matrices, world/view/proj) - copied by value
    vs_consts: [MAX_VS_CONST_REGS][4]f32 = undefined,
};

var cached_draws: [MAX_CACHED_DRAWS]CachedDraw = [_]CachedDraw{.{}} ** MAX_CACHED_DRAWS;
var cached_draw_count: u32 = 0;

// =============================================================================
// Fullscreen quad vertex (pretransformed + 1 texcoord)
// =============================================================================

const QuadVertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    rhw: f32,
    u: f32,
    v: f32,
};

// =============================================================================
// Device helper wrappers (stdcall COM vtable calls)
// =============================================================================

fn deviceSetRS(dev: *anyopaque, state: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetRenderState]);
    _ = f(dev, state, value);
}

fn deviceGetRS(dev: *anyopaque, state: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, *u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.GetRenderState]);
    _ = f(dev, state, &val);
    return val;
}

fn deviceSetPtr(dev: *anyopaque, idx: usize, ptr: *anyopaque) void {
    const f: *const fn (*anyopaque, *anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[idx]);
    _ = f(dev, ptr);
}

fn deviceGetPtr(dev: *anyopaque, idx: usize) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    const f: *const fn (*anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[idx]);
    _ = f(dev, &ptr);
    return ptr;
}

/// Set a COM pointer, handling null via optional pointer (ABI-equivalent to passing 0).
fn deviceSetPtrOrNull(dev: *anyopaque, idx: usize, ptr: ?*anyopaque) void {
    const f: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[idx]);
    _ = @call(.never_tail, f, .{ dev, ptr });
}

fn deviceSetPSConstF(dev: *anyopaque, start: u32, data: *const [4]f32) void {
    const f: *const fn (*anyopaque, u32, *const [4]f32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetPixelShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceGetPSConstF(dev: *anyopaque, start: u32, data: *[4]f32) void {
    const f: *const fn (*anyopaque, u32, *[4]f32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetPixelShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceGetViewport(dev: *anyopaque, vp_out: *types.D3DVIEWPORT9) void {
    const f: *const fn (*anyopaque, *types.D3DVIEWPORT9) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetViewport]);
    _ = f(dev, vp_out);
}

fn deviceSetViewport(dev: *anyopaque, vp_in: *const types.D3DVIEWPORT9) void {
    const f: *const fn (*anyopaque, *const types.D3DVIEWPORT9) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetViewport]);
    _ = f(dev, vp_in);
}

fn deviceSetRenderTarget(dev: *anyopaque, idx: u32, surf: *anyopaque) void {
    const f: *const fn (*anyopaque, u32, *anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetRenderTarget]);
    _ = f(dev, idx, surf);
}

fn deviceGetRenderTarget(dev: *anyopaque, idx: u32) ?*anyopaque {
    var surf: ?*anyopaque = null;
    const f: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetRenderTarget]);
    _ = f(dev, idx, &surf);
    return surf;
}

fn deviceSetTexture(dev: *anyopaque, stage: u32, tex: ?*anyopaque) void {
    const f: *const fn (*anyopaque, u32, ?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetTexture]);
    _ = @call(.never_tail, f, .{ dev, stage, tex });
}

fn deviceGetTSS(dev: *anyopaque, stage: u32, state_type: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, u32, *u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetTextureStageState]);
    _ = f(dev, stage, state_type, &val);
    return val;
}

fn deviceSetTSS(dev: *anyopaque, stage: u32, state_type: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetTextureStageState]);
    _ = f(dev, stage, state_type, value);
}

fn deviceCreateStateBlock(dev: *anyopaque) ?*anyopaque {
    var out: ?*anyopaque = null;
    const f: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.CreateStateBlock]);
    if (f(dev, types.D3DSBT_ALL, &out) < 0) return null;
    return out;
}

fn stateBlockApply(sb: *anyopaque) bool {
    // IDirect3DStateBlock9 vtable:
    // 0 QI, 1 AddRef, 2 Release, 3 GetDevice, 4 Capture, 5 Apply.
    // DEBUG28/29 accidentally called Capture here, so no captured state was
    // ever restored. Use the real Apply slot.
    const f: *const fn (*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(sb)[5]);
    return f(sb) >= 0;
}

fn deviceSetFVF(dev: *anyopaque, fvf: u32) void {
    const f: *const fn (*anyopaque, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetFVF]);
    _ = f(dev, fvf);
}

fn deviceGetSamplerState(dev: *anyopaque, sampler: u32, state_type: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, u32, *u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetSamplerState]);
    _ = f(dev, sampler, state_type, &val);
    return val;
}

fn deviceSetSamplerState(dev: *anyopaque, sampler: u32, state_type: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetSamplerState]);
    _ = f(dev, sampler, state_type, value);
}

fn deviceGetStreamSource(dev: *anyopaque, stream: u32, vb_out: *?*anyopaque, offset_out: *u32, stride_out: *u32) void {
    const f: *const fn (*anyopaque, u32, *?*anyopaque, *u32, *u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetStreamSource]);
    _ = f(dev, stream, vb_out, offset_out, stride_out);
}

fn deviceSetStreamSource(dev: *anyopaque, stream: u32, vb: ?*anyopaque, offset: u32, stride: u32) void {
    const f: *const fn (*anyopaque, u32, ?*anyopaque, u32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetStreamSource]);
    _ = @call(.never_tail, f, .{ dev, stream, vb, offset, stride });
}

fn deviceGetTexture(dev: *anyopaque, stage: u32) ?*anyopaque {
    var tex: ?*anyopaque = null;
    const f: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetTexture]);
    _ = f(dev, stage, &tex);
    return tex;
}

fn deviceGetIndices(dev: *anyopaque) ?*anyopaque {
    var ib: ?*anyopaque = null;
    const f: *const fn (*anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetIndices]);
    _ = f(dev, &ib);
    return ib;
}

fn deviceSetIndices(dev: *anyopaque, ib: ?*anyopaque) void {
    const f: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetIndices]);
    _ = @call(.never_tail, f, .{ dev, ib });
}

fn deviceGetVSConstF(dev: *anyopaque, start: u32, data: [*][4]f32, count: u32) void {
    const f: *const fn (*anyopaque, u32, [*][4]f32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetVertexShaderConstantF]);
    _ = f(dev, start, data, count);
}

fn deviceSetVSConstF(dev: *anyopaque, start: u32, data: [*]const [4]f32, count: u32) void {
    const f: *const fn (*anyopaque, u32, [*]const [4]f32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetVertexShaderConstantF]);
    _ = f(dev, start, data, count);
}

fn deviceDrawPrimitiveUP(dev: *anyopaque, prim_type: u32, prim_count: u32, data: *const anyopaque, stride: u32) void {
    const f: *const fn (*anyopaque, u32, u32, *const anyopaque, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.DrawPrimitiveUP]);
    _ = f(dev, prim_type, prim_count, data, stride);
}

fn deviceCreateTexture(dev: *anyopaque, w: u32, h: u32, levels: u32, usage: u32, fmt: u32, pool: u32, out: *?*anyopaque) i32 {
    const f: *const fn (*anyopaque, u32, u32, u32, u32, u32, u32, *?*anyopaque, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.CreateTexture]);
    const hr = f(dev, w, h, levels, usage, fmt, pool, out, 0);
    if (hr < 0) debug_texture_create_hr = hr;
    return hr;
}

/// Get surface level 0 from a texture. Returns AddRef'd surface or null.
fn textureGetSurfaceLevel(tex: *anyopaque) ?*anyopaque {
    // IDirect3DTexture9::GetSurfaceLevel is vtable index 18
    var surf: ?*anyopaque = null;
    const f: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(tex)[18]);
    if (f(tex, 0, &surf) < 0) return null;
    return surf;
}

/// Clear the current render target to a colour.
fn clearRenderTarget(dev: *anyopaque, color: u32) void {
    const f: *const fn (*anyopaque, u32, ?*anyopaque, u32, u32, f32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(dev)[types.VT.Clear]);
    _ = f(dev, 0, null, types.D3DCLEAR_TARGET, color, 1.0, 0);
}

/// Convert D3DCOLOR ARGB to float4 RGBA.
fn argbToFloat4(argb: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((argb >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((argb >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(argb & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((argb >> 24) & 0xFF)) / 255.0,
    };
}

// =============================================================================
// Terrain depth snapshot
// =============================================================================

// (Terrain DS snapshot removed - DXVK does not support StretchRect for
//  depth-stencil surfaces. Terrain occlusion is achieved via stencil marks
//  written during the DIP hook, when the game's DS already has terrain depth.)

// =============================================================================
// Resource management
// =============================================================================

fn ensureResources(device: *anyopaque) void {
    var vp: types.D3DVIEWPORT9 = .{};
    deviceGetViewport(device, &vp);
    if (vp.Width == 0 or vp.Height == 0) return;
    debug_resource_stage = 1; // viewport valid

    // Check if resources already match current dimensions
    if (vp.Width == resource_width and vp.Height == resource_height and
        rt_material_tex != null and rt_silhouette_tex != null) return;

    // Release old and create new
    releaseResources();
    resource_width = vp.Width;
    resource_height = vp.Height;

    // Exact-material scratch RT (A8R8G8B8)
    if (deviceCreateTexture(device, vp.Width, vp.Height, 1, types.D3DUSAGE_RENDERTARGET, types.D3DFMT_A8R8G8B8, types.D3DPOOL_DEFAULT, &rt_material_tex) < 0) {
        releaseResources();
        return;
    }
    rt_material_surf = textureGetSurfaceLevel(rt_material_tex.?);
    if (rt_material_surf == null) {
        releaseResources();
        return;
    }

    // Normalized silhouette RT (A8R8G8B8)
    if (deviceCreateTexture(device, vp.Width, vp.Height, 1, types.D3DUSAGE_RENDERTARGET, types.D3DFMT_A8R8G8B8, types.D3DPOOL_DEFAULT, &rt_silhouette_tex) < 0) {
        releaseResources();
        return;
    }
    debug_resource_stage = 2; // silhouette texture ready
    rt_silhouette_surf = textureGetSurfaceLevel(rt_silhouette_tex.?);
    if (rt_silhouette_surf == null) {
        releaseResources();
        return;
    }
    debug_resource_stage = 3; // silhouette surface ready

    // JFA A RT (G16R16F)
    if (deviceCreateTexture(device, vp.Width, vp.Height, 1, types.D3DUSAGE_RENDERTARGET, types.D3DFMT_G16R16F, types.D3DPOOL_DEFAULT, &rt_jfa_a_tex) < 0) {
        releaseResources();
        return;
    }
    debug_resource_stage = 4; // JFA A texture ready
    rt_jfa_a_surf = textureGetSurfaceLevel(rt_jfa_a_tex.?);
    if (rt_jfa_a_surf == null) {
        releaseResources();
        return;
    }
    debug_resource_stage = 5; // JFA A surface ready

    // JFA B RT (G16R16F)
    if (deviceCreateTexture(device, vp.Width, vp.Height, 1, types.D3DUSAGE_RENDERTARGET, types.D3DFMT_G16R16F, types.D3DPOOL_DEFAULT, &rt_jfa_b_tex) < 0) {
        releaseResources();
        return;
    }
    debug_resource_stage = 6; // JFA B texture ready
    rt_jfa_b_surf = textureGetSurfaceLevel(rt_jfa_b_tex.?);
    if (rt_jfa_b_surf == null) {
        releaseResources();
        return;
    }
    debug_resource_stage = 7; // all RT surfaces ready

    debug_resources_ready_seen = true;
}

fn releaseResources() void {
    inline for (.{
        &rt_material_surf, &rt_silhouette_surf, &rt_jfa_a_surf, &rt_jfa_b_surf,
    }) |surf_ptr| {
        if (surf_ptr.*) |s| {
            comRelease(s);
            surf_ptr.* = null;
        }
    }
    inline for (.{
        &rt_material_tex, &rt_silhouette_tex, &rt_jfa_a_tex, &rt_jfa_b_tex,
    }) |tex_ptr| {
        if (tex_ptr.*) |t| {
            comRelease(t);
            tex_ptr.* = null;
        }
    }
    resource_width = 0;
    resource_height = 0;
}

// =============================================================================
// Shader source strings
// =============================================================================

/// Flat colour pixel shader - outputs PS constant c0.
const ps_flat_src = "ps_3_0\nmov oC0, c0\n";

/// Texture-alpha-aware silhouette shader.
/// c0 = outline colour/encoded width, c1.x = -coverage threshold.
const ps_alpha_src =
    "ps_3_0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    "texld r0, v0, s0\n" ++
    "add r1, r0.aaaa, c1.xxxx\n" ++
    "texkill r1\n" ++
    "mov oC0, c0\n";

/// Coverage shader for additive/modulated M2 layers where transparency can be
/// encoded as black RGB rather than useful texture alpha.
const ps_rgb_src =
    "ps_3_0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    "texld r0, v0, s0\n" ++
    "max r1.x, r0.r, r0.g\n" ++
    "max r1.x, r1.x, r0.b\n" ++
    "add r1, r1.xxxx, c1.xxxx\n" ++
    "texkill r1\n" ++
    "mov oC0, c0\n";

/// Normalize the exact-material scratch into the uniform outline mask.
/// c0 = outline colour (alpha forced to 1), c1.x = -coverage threshold.
/// Coverage accepts either alpha or RGB, so opaque dark materials and additive
/// effects both survive while untouched transparent pixels remain discarded.
const material_mask_src =
    "ps_3_0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    "texld r0, v0, s0\n" ++
    "max r1.x, r0.r, r0.g\n" ++
    "max r1.x, r1.x, r0.b\n" ++
    "max r1.x, r1.x, r0.a\n" ++
    "add r1, r1.xxxx, c1.xxxx\n" ++
    "texkill r1\n" ++
    "mov oC0, c0\n";

/// JFA init: sample silhouette, output own UV as seed or sentinel (-1,-1).
/// Sentinel must be outside [0,1] UV space so it never wins distance comparisons.
const jfa_init_src =
    "ps_3_0\n" ++
    "def c0, -1.0, -1.0, -0.002, 0.0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    "texld r0, v0, s0\n" ++
    "add r0.x, r0.a, c0.z\n" ++ // alpha - 0.002
    "cmp oC0.xy, r0.x, v0.xy, c0.xy\n" ++ // >= 0 → own UV (seed), < 0 → sentinel
    "mov oC0.zw, c0.ww\n";

/// JFA propagation: 9-tap (self + 8 neighbors), keeps nearest seed.
/// c0.xy = step_size_uv (set per-pass by CPU).
const jfa_prop_src =
    "ps_3_0\n" ++
    "def c1, 0.0, 0.0, 0.0, 0.0\n" ++
    "def c2, -1.0, -1.0, 0.0, 0.0\n" ++
    "def c3, -1.0, 0.0, 0.0, 0.0\n" ++
    "def c4, -1.0, 1.0, 0.0, 0.0\n" ++
    "def c5, 0.0, -1.0, 0.0, 0.0\n" ++
    "def c6, 0.0, 1.0, 0.0, 0.0\n" ++
    "def c7, 1.0, -1.0, 0.0, 0.0\n" ++
    "def c8, 1.0, 0.0, 0.0, 0.0\n" ++
    "def c9, 1.0, 1.0, 0.0, 0.0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    // D3DX on this client only allows one c# register per arithmetic
    // instruction. Copy c0.xy (step size) to a temp once, then combine
    // that temp with c2..c9 in the neighbor MADs.
    "mov r7.xy, c0.xy\n" ++
    // Self sample - initialize best seed and distance
    "texld r0, v0, s0\n" ++
    "sub r2.xy, v0.xy, r0.xy\n" ++
    "dp2add r9.x, r2, r2, c1.x\n" ++ // best dist²
    "mov r8.xy, r0.xy\n" ++ // best seed UV
    // Neighbor (-1,-1) via c2
    "mad r4.xy, c2.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (-1, 0) via c3
    "mad r4.xy, c3.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (-1, 1) via c4
    "mad r4.xy, c4.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (0, -1) via c5
    "mad r4.xy, c5.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (0, 1) via c6
    "mad r4.xy, c6.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (1, -1) via c7
    "mad r4.xy, c7.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (1, 0) via c8
    "mad r4.xy, c8.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Neighbor (1, 1) via c9
    "mad r4.xy, c9.xy, r7.xy, v0.xy\n" ++
    "texld r5, r4, s0\n" ++
    "sub r2.xy, v0.xy, r5.xy\n" ++
    "dp2add r2.z, r2, r2, c1.x\n" ++
    "sub r3.x, r2.z, r9.x\n" ++
    "cmp r8.xy, r3.x, r8.xy, r5.xy\n" ++
    "cmp r9.x, r3.x, r9.x, r2.z\n" ++
    // Output best seed UV
    "mov oC0.xy, r8.xy\n" ++
    "mov oC0.zw, c1.xx\n";

/// V32 POLISH: hard 3px outline, no feather.
/// c0 = (screen_width, screen_height, radius_px=3, 0).
/// The shader squares radius_px and emits a binary 0/1 edge alpha.
const jfa_decode_src =
    "ps_3_0\n" ++
    "def c1, 0.0, 1.0, -0.002, 0.0\n" ++
    "dcl_2d s0\n" ++
    "dcl_2d s1\n" ++
    "dcl_texcoord0 v0\n" ++
    // Nearest seed and pixel-space squared distance.
    "texld r0, v0, s0\n" ++
    "sub r1.xy, v0.xy, r0.xy\n" ++
    "mul r1.xy, r1.xy, c0.xy\n" ++
    "dp2add r1.z, r1, r1, c0.w\n" ++
    // Seed colour.
    "texld r2, r0, s1\n" ++
    // Hard radius test: dist² < radius² => alpha 1, otherwise 0.
    "mov r3.x, c0.z\n" ++
    "mul r3.x, r3.x, r3.x\n" ++
    "sub r3.y, r1.z, r3.x\n" ++
    "mov r6.w, c1.y\n" ++
    "cmp r4.w, r3.y, c0.w, r6.w\n" ++
    // Do not paint over the model interior.
    "texld r5, v0, s1\n" ++
    "add r5.x, r5.a, c1.z\n" ++
    "cmp r4.w, r5.x, c0.w, r4.w\n" ++
    "mov r4.xyz, r2.xyz\n" ++
    "mov oC0, r4\n";

/// Debug: composite silhouette RT directly. Forces alpha to 1.0 where silhouette
/// has any content (alpha >= 0.002), 0.0 elsewhere. Bypasses JFA entirely.
const debug_sil_src =
    "ps_3_0\n" ++
    "def c0, 0.0, 0.0, -0.002, 1.0\n" ++
    "dcl_2d s0\n" ++
    "dcl_texcoord0 v0\n" ++
    "texld r0, v0, s0\n" ++
    "add r1.x, r0.a, c0.z\n" ++ // alpha - 0.002
    "cmp r0.w, r1.x, c0.w, c0.x\n" ++ // >= 0 → 1.0 (opaque), < 0 → 0.0 (transparent)
    "mov oC0, r0\n";

// =============================================================================
// Shader creation
// =============================================================================

fn ensureShaders(device: *anyopaque) void {
    shaders_attempted = true;
    debug_shader_stage = 1; // entered

    const d3dx = LoadLibraryA("d3dx9_43.dll") orelse
        LoadLibraryA("d3dx9_42.dll") orelse
        LoadLibraryA("d3dx9_41.dll") orelse return;
    debug_shader_stage = 2; // D3DX loaded

    const assemble_ptr = GetProcAddress(d3dx, "D3DXAssembleShader") orelse return;
    debug_shader_stage = 3; // assembler found
    const assemble: D3DXAssembleShaderFn = @ptrCast(assemble_ptr);

    // --- Flat-colour PS (for solid silhouettes) ---
    outline_ps = assemblePS(device, assemble, ps_flat_src, ps_flat_src.len) orelse return;

    // --- Alpha-aware silhouette PS (for textured cutout/translucent planes) ---
    outline_alpha_ps = assemblePS(device, assemble, ps_alpha_src, ps_alpha_src.len) orelse {
        releaseShaders();
        return;
    };
    outline_rgb_ps = assemblePS(device, assemble, ps_rgb_src, ps_rgb_src.len) orelse {
        releaseShaders();
        return;
    };
    material_mask_ps = assemblePS(device, assemble, material_mask_src, material_mask_src.len) orelse {
        releaseShaders();
        return;
    };
    debug_shader_stage = 4; // silhouette/material-mask PS variants ready

    // --- JFA Init PS ---
    jfa_init_ps = assemblePS(device, assemble, jfa_init_src, jfa_init_src.len) orelse {
        releaseShaders();
        return;
    };
    debug_shader_stage = 5; // JFA init ready

    // --- JFA Propagation PS ---
    jfa_prop_ps = assemblePS(device, assemble, jfa_prop_src, jfa_prop_src.len) orelse {
        releaseShaders();
        return;
    };
    debug_shader_stage = 6; // JFA propagation ready

    // --- JFA Decode + Composite PS ---
    jfa_decode_ps = assemblePS(device, assemble, jfa_decode_src, jfa_decode_src.len) orelse {
        releaseShaders();
        return;
    };
    debug_shader_stage = 7; // JFA decode ready

    // --- Debug silhouette composite PS (only when diagnostic enabled) ---
    if (DEBUG_SHOW_SILHOUETTE) {
        debug_sil_ps = assemblePS(device, assemble, debug_sil_src, debug_sil_src.len) orelse {
            releaseShaders();
            return;
        };
    }

    debug_shader_stage = 8; // complete
    debug_shaders_ready_seen = true;
}

/// Assemble a pixel shader from source text, create device PS object.
fn captureD3DXError(buf: *anyopaque) void {
    @memset(&debug_shader_error_text, 0);

    const get_ptr: *const fn (*anyopaque) callconv(hook.cc.stdcall) usize =
        @ptrFromInt(vt(buf)[3]);
    const get_size: *const fn (*anyopaque) callconv(hook.cc.stdcall) usize =
        @ptrFromInt(vt(buf)[4]);

    const ptr_val = get_ptr(buf);
    const size = get_size(buf);
    if (ptr_val == 0 or size == 0) return;

    const src_ptr: [*]const u8 = @ptrFromInt(ptr_val);
    const n = @min(size, debug_shader_error_text.len - 1);
    @memcpy(debug_shader_error_text[0..n], src_ptr[0..n]);

    // Make sure the chat string ends cleanly even if the D3DX buffer does not.
    debug_shader_error_text[n] = 0;
}

fn assemblePS(device: *anyopaque, assemble: D3DXAssembleShaderFn, src: [*]const u8, len: usize) ?*anyopaque {
    var code: ?*anyopaque = null;
    var err_buf: ?*anyopaque = null;
    const assemble_hr = assemble(src, @intCast(len), null, null, 0, &code, &err_buf);
    if (assemble_hr < 0 or code == null) {
        debug_shader_assemble_hr = assemble_hr;
        if (err_buf) |e| {
            captureD3DXError(e);
            comRelease(e);
        }
        return null;
    }
    defer comRelease(code.?);
    if (err_buf) |e| comRelease(e);

    // ID3DXBuffer::GetBufferPointer is vtable[3]
    const buf_ptr: *anyopaque = @ptrFromInt(
        @as(*const fn (*anyopaque) callconv(hook.cc.stdcall) usize, @ptrFromInt(vt(code.?)[3]))(code.?),
    );
    var ps_out: ?*anyopaque = null;
    const create: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[types.VT.CreatePixelShader]);
    const create_hr = create(device, buf_ptr, &ps_out);
    if (create_hr < 0) {
        debug_shader_create_hr = create_hr;
        return null;
    }
    return ps_out;
}

fn releaseShaders() void {
    inline for (.{ &outline_ps, &outline_alpha_ps, &outline_rgb_ps, &material_mask_ps, &jfa_init_ps, &jfa_prop_ps, &jfa_decode_ps, &debug_sil_ps }) |ps| {
        if (ps.*) |p| {
            comRelease(p);
            ps.* = null;
        }
    }
    shaders_attempted = false;
}

// =============================================================================
// Fullscreen quad builder
// =============================================================================

fn buildFullscreenQuad(w: u32, h: u32) [4]QuadVertex {
    const fw = @as(f32, @floatFromInt(w));
    const fh = @as(f32, @floatFromInt(h));
    // D3D9 half-pixel offset for pixel-perfect UV mapping
    return .{
        .{ .x = -0.5, .y = -0.5, .z = 0.0, .rhw = 1.0, .u = 0.0, .v = 0.0 },
        .{ .x = fw - 0.5, .y = -0.5, .z = 0.0, .rhw = 1.0, .u = 1.0, .v = 0.0 },
        .{ .x = -0.5, .y = fh - 0.5, .z = 0.0, .rhw = 1.0, .u = 0.0, .v = 1.0 },
        .{ .x = fw - 0.5, .y = fh - 0.5, .z = 0.0, .rhw = 1.0, .u = 1.0, .v = 1.0 },
    };
}

// =============================================================================
// EndScene hook
// =============================================================================

fn hkEndScene(device: *anyopaque) callconv(hook.cc.stdcall) i32 {
    debug_endscene_seen = true;

    // DEBUG23: no forced D3D9 Reset. The client can hang the render thread
    // during Reset, so Outline runs without a stencil dependency.

    // Per-frame: scan objects for outline tracking
    tracker.scanObjects();

    // Run outline pipeline if any draws were cached this frame:
    // Phase 1 (inside runJfaPipeline): replay cached draws → silhouette RT
    // Phase 2: JFA init → propagation → decode+composite → backbuffer
    if (frame_has_outlines) {
        runJfaPipeline(device);
    }

    // Diagnostics: log pipeline stage counts (first 20 active frames)
    tracker.logDiagnostics(cached_draw_count);

    // Safety: release any cached draws that weren't replayed (e.g. missing resources)
    if (cached_draw_count > 0) clearCachedDraws();

    // Reset per-frame flags for next frame
    model_hook.rendering_outline = false;
    model_hook.current_model = 0;
    frame_has_outlines = false;

    // Call original EndScene
    const f: *const fn (*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(orig_endscene);
    return f(device);
}

// =============================================================================
// Reset hook - force D24S8 depth/stencil format, release resources
// =============================================================================

fn hkReset(device: *anyopaque, pp: *types.D3DPRESENT_PARAMETERS) callconv(hook.cc.stdcall) i32 {
    if (pp.EnableAutoDepthStencil != 0) {
        const fmt = pp.AutoDepthStencilFormat;
        if (fmt != types.D3DFMT_D24S8 and fmt != types.D3DFMT_D24FS8 and
            fmt != types.D3DFMT_D24X4S4 and fmt != types.D3DFMT_D15S1)
        {
            pp.AutoDepthStencilFormat = types.D3DFMT_D24S8;
        }
    }

    // Release all resources (device state lost on reset)
    clearCachedDraws();
    releaseShaders();
    releaseResources();

    const f: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(hook.cc.stdcall) i32 = @ptrFromInt(orig_reset);
    return f(device, pp);
}

// =============================================================================
// DrawIndexedPrimitive hook - cache outline draws for EndScene replay
// =============================================================================
// When an outline target is being drawn, we cache the draw parameters and
// current GPU state (VB, IB, vertex decl, VS, VS constants) so they can be
// replayed to the silhouette RT in EndScene. The DIP hook itself does NOT
// modify any device state and calls the original DIP exactly once.
//
// This avoids the "double-DIP" pattern that corrupted WoW's internal
// rendering state (likely GxDevice state cache or batch counters).

fn hkDIP(
    device: *anyopaque,
    prim_type: u32,
    base_vtx: i32,
    min_vtx: u32,
    num_verts: u32,
    start_idx: u32,
    prim_count: u32,
) callconv(hook.cc.stdcall) i32 {
    debug_dip_seen = true;

    const OrigDIP = *const fn (*anyopaque, u32, i32, u32, u32, u32, u32) callconv(hook.cc.stdcall) i32;
    const origFn: OrigDIP = @ptrFromInt(orig_dip);

    // ---- Cache outline draws for EndScene replay ----
    if (model_hook.rendering_outline) {
        debug_outline_dip_seen = true;
        const model_ptr = model_hook.current_model;
        const color = tracker.getModelColor(model_ptr) orelse
            return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
        const category = tracker.getModelCategory(model_ptr);

        // Ensure resources will be available for replay in EndScene
        if (!shaders_attempted) ensureShaders(device);
        ensureResources(device);
        if (outline_ps == null or rt_silhouette_surf == null)
            return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);

        // Cache if room available
        if (cached_draw_count < MAX_CACHED_DRAWS) {
            const idx = cached_draw_count;
            var draw = &cached_draws[idx];

            // Draw parameters
            draw.prim_type = prim_type;
            draw.base_vtx = base_vtx;
            draw.min_vtx = min_vtx;
            draw.num_verts = num_verts;
            draw.start_idx = start_idx;
            draw.prim_count = prim_count;

            // Outline info
            draw.color = color;
            draw.category = category;

            // Capture current GPU state (AddRef COM objects to keep them alive)
            deviceGetStreamSource(device, 0, &draw.vb, &draw.vb_offset, &draw.vb_stride);
            // GetStreamSource AddRef's the VB - we keep the ref until replay
            draw.ib = deviceGetIndices(device);
            // GetIndices AddRef's the IB
            draw.vertex_decl = deviceGetPtr(device, types.VT.GetVertexDeclaration);
            // GetVertexDeclaration AddRef's
            draw.vertex_shader = deviceGetPtr(device, types.VT.GetVertexShader);
            // GetVertexShader AddRef's
            for (0..4) |stage| {
                draw.tex[stage] = deviceGetTexture(device, @intCast(stage));
                draw.alpha_op[stage] = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAOP);
                draw.alpha_arg1[stage] = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG1);
                draw.alpha_arg2[stage] = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG2);
            }
            draw.pixel_shader = deviceGetPtr(device, types.VT.GetPixelShader);
            draw.state_block = deviceCreateStateBlock(device);
            if (draw.state_block != null) debug_state_block_seen = true;
            draw.alpha_test_enable = deviceGetRS(device, types.D3DRS.ALPHATESTENABLE);
            draw.alpha_ref = deviceGetRS(device, types.D3DRS.ALPHAREF);
            draw.alpha_func = deviceGetRS(device, types.D3DRS.ALPHAFUNC);
            draw.alpha_blend_enable = deviceGetRS(device, types.D3DRS.ALPHABLENDENABLE);
            draw.src_blend = deviceGetRS(device, types.D3DRS.SRCBLEND);
            draw.dst_blend = deviceGetRS(device, types.D3DRS.DESTBLEND);

            // Capture VS constants (bone matrices, world/view/proj transforms)
            deviceGetVSConstF(device, 0, &draw.vs_consts, MAX_VS_CONST_REGS);

            cached_draw_count = idx + 1;
            frame_has_outlines = true;
            debug_cached_draw_seen = true;
        }

        // DEBUG23: no stencil writes. Preserve WoW's D3D state and draw once.
        // The cached geometry is replayed later into the silhouette RT.
        return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
    }

    // ---- Normal path ----
    return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
}

/// Release AddRef'd COM objects in cached draws and reset count.
fn clearCachedDraws() void {
    for (0..cached_draw_count) |i| {
        var draw = &cached_draws[i];
        if (draw.vb) |obj| {
            comRelease(obj);
            draw.vb = null;
        }
        if (draw.ib) |obj| {
            comRelease(obj);
            draw.ib = null;
        }
        if (draw.vertex_decl) |obj| {
            comRelease(obj);
            draw.vertex_decl = null;
        }
        if (draw.vertex_shader) |obj| {
            comRelease(obj);
            draw.vertex_shader = null;
        }
        if (draw.pixel_shader) |obj| {
            comRelease(obj);
            draw.pixel_shader = null;
        }
        if (draw.state_block) |obj| {
            comRelease(obj);
            draw.state_block = null;
        }
        for (0..4) |stage| {
            if (draw.tex[stage]) |obj| {
                comRelease(obj);
                draw.tex[stage] = null;
            }
        }
    }
    cached_draw_count = 0;
}

// =============================================================================
// JFA pipeline (called from EndScene when outlines exist)
// =============================================================================

fn runJfaPipeline(device: *anyopaque) void {
    debug_pipeline_entered_seen = true;

    // DEBUG29: capture the complete WoW D3D state before any replay/JFA work.
    // The manual save/restore below remains as fallback, but this state block
    // restores states that are easy to miss (extra samplers/TSS, scissor,
    // shaders/constants, streams, declarations, etc.).
    const outer_state = deviceCreateStateBlock(device);
    defer if (outer_state) |sb| {
        if (stateBlockApply(sb)) debug_outer_state_restore_seen = true;
        comRelease(sb);
    };

    // Verify all resources and shaders
    if (rt_material_tex == null or rt_material_surf == null or rt_silhouette_tex == null or rt_jfa_a_surf == null or rt_jfa_b_surf == null) return;
    if (!shaders_attempted) ensureShaders(device);
    if (jfa_init_ps == null or jfa_prop_ps == null or jfa_decode_ps == null) return;
    if (outline_ps == null or material_mask_ps == null or rt_silhouette_surf == null) return;

    debug_pipeline_ready_seen = true;

    var vp: types.D3DVIEWPORT9 = .{};
    deviceGetViewport(device, &vp);
    if (vp.Width == 0 or vp.Height == 0) return;

    // =====================================================================
    // Save ALL state that replay + JFA will modify (manual, no state blocks)
    // =====================================================================

    // COM objects (Get* AddRefs - must Release after restore)
    const saved_rt0 = deviceGetRenderTarget(device, 0);
    const saved_ps = deviceGetPtr(device, types.VT.GetPixelShader);
    const saved_vs = deviceGetPtr(device, types.VT.GetVertexShader);
    const saved_decl = deviceGetPtr(device, types.VT.GetVertexDeclaration);
    const saved_ib = deviceGetIndices(device);
    const saved_tex0 = deviceGetTexture(device, 0);
    const saved_tex1 = deviceGetTexture(device, 1);
    var saved_vb: ?*anyopaque = null;
    var saved_vb_offset: u32 = 0;
    var saved_vb_stride: u32 = 0;
    deviceGetStreamSource(device, 0, &saved_vb, &saved_vb_offset, &saved_vb_stride);

    // Depth-stencil surface
    var saved_ds: ?*anyopaque = null;
    const getDS: *const fn (*anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[types.VT.GetDepthStencilSurface]);
    _ = getDS(device, &saved_ds);

    // Render states
    const saved_zenable = deviceGetRS(device, types.D3DRS.ZENABLE);
    const saved_zwrite = deviceGetRS(device, types.D3DRS.ZWRITEENABLE);
    const saved_zfunc = deviceGetRS(device, types.D3DRS.ZFUNC);
    const saved_ablend = deviceGetRS(device, types.D3DRS.ALPHABLENDENABLE);
    const saved_srcblend = deviceGetRS(device, types.D3DRS.SRCBLEND);
    const saved_dstblend = deviceGetRS(device, types.D3DRS.DESTBLEND);
    const saved_cull = deviceGetRS(device, types.D3DRS.CULLMODE);
    const saved_atest = deviceGetRS(device, types.D3DRS.ALPHATESTENABLE);
    const saved_aref = deviceGetRS(device, types.D3DRS.ALPHAREF);
    const saved_afunc = deviceGetRS(device, types.D3DRS.ALPHAFUNC);
    const saved_tfactor = deviceGetRS(device, types.D3DRS.TEXTUREFACTOR);
    const saved_cwrite = deviceGetRS(device, types.D3DRS.COLORWRITEENABLE);

    const SavedTSS = struct {
        colorop: u32,
        colorarg1: u32,
        alphaop: u32,
        alphaarg1: u32,
        alphaarg2: u32,
    };
    var saved_tss: [4]SavedTSS = undefined;
    for (0..4) |stage| {
        saved_tss[stage] = .{
            .colorop = deviceGetTSS(device, @intCast(stage), types.D3DTSS.COLOROP),
            .colorarg1 = deviceGetTSS(device, @intCast(stage), types.D3DTSS.COLORARG1),
            .alphaop = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAOP),
            .alphaarg1 = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG1),
            .alphaarg2 = deviceGetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG2),
        };
    }

    // Stencil states (Phase 1 reads stencil marks written by DIP hook)
    const saved_stencil_enable = deviceGetRS(device, types.D3DRS.STENCILENABLE);
    const saved_stencil_func = deviceGetRS(device, types.D3DRS.STENCILFUNC);
    const saved_stencil_ref = deviceGetRS(device, types.D3DRS.STENCILREF);
    const saved_stencil_mask = deviceGetRS(device, types.D3DRS.STENCILMASK);
    const saved_stencil_wmask = deviceGetRS(device, types.D3DRS.STENCILWRITEMASK);
    const saved_stencil_pass = deviceGetRS(device, types.D3DRS.STENCILPASS);

    // Sampler states (samplers 0 and 1, 5 states each)
    const SampState = struct { addru: u32, addrv: u32, mag: u32, min: u32, mip: u32 };
    const readSamp = struct {
        fn f(dev: *anyopaque, stage: u32) SampState {
            return .{
                .addru = deviceGetSamplerState(dev, stage, types.D3DSAMP.ADDRESSU),
                .addrv = deviceGetSamplerState(dev, stage, types.D3DSAMP.ADDRESSV),
                .mag = deviceGetSamplerState(dev, stage, types.D3DSAMP.MAGFILTER),
                .min = deviceGetSamplerState(dev, stage, types.D3DSAMP.MINFILTER),
                .mip = deviceGetSamplerState(dev, stage, types.D3DSAMP.MIPFILTER),
            };
        }
    }.f;
    const saved_samp0 = readSamp(device, 0);
    const saved_samp1 = readSamp(device, 1);

    // Shader constants
    var saved_psc0: [4]f32 = .{ 0, 0, 0, 0 };
    deviceGetPSConstF(device, 0, &saved_psc0);
    var saved_vs_consts: [MAX_VS_CONST_REGS][4]f32 = undefined;
    deviceGetVSConstF(device, 0, &saved_vs_consts, MAX_VS_CONST_REGS);

    // =====================================================================
    // Phase 1: Replay cached draws to silhouette RT
    // =====================================================================

    if (cached_draw_count > 0) {
        const origFn: *const fn (*anyopaque, u32, i32, u32, u32, u32, u32) callconv(hook.cc.stdcall) i32 =
            @ptrFromInt(orig_dip);
        const quad = buildFullscreenQuad(vp.Width, vp.Height);

        // Accumulate normalized per-draw coverage into the silhouette mask.
        deviceSetRenderTarget(device, 0, rt_silhouette_surf.?);
        clearRenderTarget(device, 0x00000000);

        for (0..cached_draw_count) |i| {
            const draw = &cached_draws[i];

            // V31 POLISH: don't let additive/emissive passes (spell glows,
            // bloom-like model layers) expand the selection silhouette.
            // Normal alpha-blended materials remain included.
            if (draw.alpha_blend_enable != 0 and draw.dst_blend == types.D3DBLEND_ONE) {
                debug_additive_skipped_seen = true;
                continue;
            }

            // 1) Replay this draw with WoW's exact captured D3D state into a
            // transparent scratch RT. A D3DSBT_ALL state block restores pixel
            // shader, PS constants, textures, samplers, texture stages, blend,
            // alpha-test, vertex state and stream bindings.
            if (draw.state_block) |sb| {
                _ = stateBlockApply(sb);
            }

            // Never rely on D3DSBT_ALL to restore geometry bindings correctly
            // across drivers/wrappers. Rebind the cached draw explicitly.
            deviceSetStreamSource(device, 0, draw.vb, draw.vb_offset, draw.vb_stride);
            deviceSetIndices(device, draw.ib);
            deviceSetPtrOrNull(device, types.VT.SetVertexDeclaration, draw.vertex_decl);
            deviceSetPtrOrNull(device, types.VT.SetVertexShader, draw.vertex_shader);
            deviceSetVSConstF(device, 0, &draw.vs_consts, MAX_VS_CONST_REGS);

            deviceSetRenderTarget(device, 0, rt_material_surf.?);
            deviceSetViewport(device, &vp);
            clearRenderTarget(device, 0x00000000);
            deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_FALSE);
            deviceSetRS(device, types.D3DRS.ZWRITEENABLE, 0);
            deviceSetRS(device, types.D3DRS.STENCILENABLE, 0);
            deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0x0F);

            _ = origFn(device, draw.prim_type, draw.base_vtx, draw.min_vtx, draw.num_verts, draw.start_idx, draw.prim_count);

            // 2) Convert only pixels actually produced by that exact material
            // into the uniform outline mask, preserving the draw/category colour.
            deviceSetRenderTarget(device, 0, rt_silhouette_surf.?);
            deviceSetViewport(device, &vp);
            deviceSetPtrOrNull(device, types.VT.SetDepthStencilSurface, null);
            deviceSetPtrOrNull(device, types.VT.SetVertexShader, null);
            deviceSetFVF(device, types.D3DFVF_XYZRHW | types.D3DFVF_TEX1);
            deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_FALSE);
            deviceSetRS(device, types.D3DRS.ZWRITEENABLE, 0);
            deviceSetRS(device, types.D3DRS.STENCILENABLE, 0);
            deviceSetRS(device, types.D3DRS.ALPHATESTENABLE, 0);
            deviceSetRS(device, types.D3DRS.CULLMODE, types.D3DCULL_NONE);
            deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0x0F);
            deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, 1);
            deviceSetRS(device, types.D3DRS.SRCBLEND, types.D3DBLEND_SRCALPHA);
            deviceSetRS(device, types.D3DRS.DESTBLEND, types.D3DBLEND_INVSRCALPHA);
            deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSU, types.D3DTADDRESS_CLAMP);
            deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSV, types.D3DTADDRESS_CLAMP);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MAGFILTER, types.D3DTEXF_POINT);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MINFILTER, types.D3DTEXF_POINT);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MIPFILTER, types.D3DTEXF_NONE);
            deviceSetTexture(device, 0, rt_material_tex);
            deviceSetPtr(device, types.VT.SetPixelShader, material_mask_ps.?);

            var mask_color = argbToFloat4(draw.color);
            mask_color[3] = 1.0;
            deviceSetPSConstF(device, 0, &mask_color);
            // Trim very faint scratch pixels that otherwise become tiny hooks/noise.
            const threshold: [4]f32 = .{ -0.03, 0.0, 0.0, 0.0 };
            deviceSetPSConstF(device, 1, &threshold);
            deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), @sizeOf(QuadVertex));
        }

        clearCachedDraws();
    }

    // =====================================================================
    // Debug: skip JFA, composite raw silhouette RT to see if banding is
    // in the silhouette (stale VB / replay issue) or the JFA pipeline.
    // =====================================================================
    if (DEBUG_SHOW_SILHOUETTE) {
        if (debug_sil_ps) |dps| {
            if (saved_rt0) |rt| deviceSetRenderTarget(device, 0, rt);
            deviceSetPtrOrNull(device, types.VT.SetDepthStencilSurface, null);
            deviceSetPtrOrNull(device, types.VT.SetVertexShader, null);
            deviceSetFVF(device, types.D3DFVF_XYZRHW | types.D3DFVF_TEX1);
            deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_FALSE);
            deviceSetRS(device, types.D3DRS.ZWRITEENABLE, 0);
            deviceSetRS(device, types.D3DRS.CULLMODE, types.D3DCULL_NONE);
            deviceSetRS(device, types.D3DRS.ALPHATESTENABLE, 0);
            deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0x0F);
            deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, 1);
            deviceSetRS(device, types.D3DRS.SRCBLEND, types.D3DBLEND_SRCALPHA);
            deviceSetRS(device, types.D3DRS.DESTBLEND, types.D3DBLEND_INVSRCALPHA);
            deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSU, types.D3DTADDRESS_CLAMP);
            deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSV, types.D3DTADDRESS_CLAMP);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MAGFILTER, types.D3DTEXF_POINT);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MINFILTER, types.D3DTEXF_POINT);
            deviceSetSamplerState(device, 0, types.D3DSAMP.MIPFILTER, types.D3DTEXF_NONE);
            deviceSetTexture(device, 0, rt_silhouette_tex);
            deviceSetPtr(device, types.VT.SetPixelShader, dps);

            const quad = buildFullscreenQuad(vp.Width, vp.Height);
            deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), @sizeOf(QuadVertex));
        }
        // Skip JFA - jump straight to state restore
    } else {

        // =====================================================================
        // Phase 2: JFA pipeline (silhouette → outline composite)
        // =====================================================================

        deviceSetPtrOrNull(device, types.VT.SetDepthStencilSurface, null);
        deviceSetPtrOrNull(device, types.VT.SetVertexShader, null);
        deviceSetFVF(device, types.D3DFVF_XYZRHW | types.D3DFVF_TEX1);
        deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_FALSE);
        deviceSetRS(device, types.D3DRS.ZWRITEENABLE, 0);
        deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, 0);
        deviceSetRS(device, types.D3DRS.CULLMODE, types.D3DCULL_NONE);
        deviceSetRS(device, types.D3DRS.ALPHATESTENABLE, 0);
        deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0x0F);

        deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSU, types.D3DTADDRESS_CLAMP);
        deviceSetSamplerState(device, 0, types.D3DSAMP.ADDRESSV, types.D3DTADDRESS_CLAMP);
        deviceSetSamplerState(device, 0, types.D3DSAMP.MAGFILTER, types.D3DTEXF_POINT);
        deviceSetSamplerState(device, 0, types.D3DSAMP.MINFILTER, types.D3DTEXF_POINT);
        deviceSetSamplerState(device, 0, types.D3DSAMP.MIPFILTER, types.D3DTEXF_NONE);
        deviceSetSamplerState(device, 1, types.D3DSAMP.ADDRESSU, types.D3DTADDRESS_CLAMP);
        deviceSetSamplerState(device, 1, types.D3DSAMP.ADDRESSV, types.D3DTADDRESS_CLAMP);
        deviceSetSamplerState(device, 1, types.D3DSAMP.MAGFILTER, types.D3DTEXF_POINT);
        deviceSetSamplerState(device, 1, types.D3DSAMP.MINFILTER, types.D3DTEXF_POINT);
        deviceSetSamplerState(device, 1, types.D3DSAMP.MIPFILTER, types.D3DTEXF_NONE);

        const quad = buildFullscreenQuad(vp.Width, vp.Height);
        const qstride: u32 = @sizeOf(QuadVertex);
        const fw = @as(f32, @floatFromInt(@max(vp.Width, 1)));
        const fh = @as(f32, @floatFromInt(@max(vp.Height, 1)));

        // Pass 1: JFA Init (silhouette → JFA_A)
        deviceSetRenderTarget(device, 0, rt_jfa_a_surf.?);
        deviceSetTexture(device, 0, rt_silhouette_tex);
        deviceSetPtr(device, types.VT.SetPixelShader, jfa_init_ps.?);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);

        // JFA Propagation: steps [8, 4, 2, 1] ping-ponging between A and B.
        deviceSetPtr(device, types.VT.SetPixelShader, jfa_prop_ps.?);
        var c0: [4]f32 = undefined;

        // step=8 (JFA_A → JFA_B)
        deviceSetRenderTarget(device, 0, rt_jfa_b_surf.?);
        deviceSetTexture(device, 0, rt_jfa_a_tex);
        c0 = .{ 8.0 / fw, 8.0 / fh, 0.0, 0.0 };
        deviceSetPSConstF(device, 0, &c0);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);

        // step=4 (JFA_B → JFA_A)
        deviceSetRenderTarget(device, 0, rt_jfa_a_surf.?);
        deviceSetTexture(device, 0, rt_jfa_b_tex);
        c0 = .{ 4.0 / fw, 4.0 / fh, 0.0, 0.0 };
        deviceSetPSConstF(device, 0, &c0);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);

        // step=2 (JFA_A → JFA_B)
        deviceSetRenderTarget(device, 0, rt_jfa_b_surf.?);
        deviceSetTexture(device, 0, rt_jfa_a_tex);
        c0 = .{ 2.0 / fw, 2.0 / fh, 0.0, 0.0 };
        deviceSetPSConstF(device, 0, &c0);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);

        // step=1 (JFA_B → JFA_A)
        deviceSetRenderTarget(device, 0, rt_jfa_a_surf.?);
        deviceSetTexture(device, 0, rt_jfa_b_tex);
        c0 = .{ 1.0 / fw, 1.0 / fh, 0.0, 0.0 };
        deviceSetPSConstF(device, 0, &c0);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);

        // Pass 4: Decode + Composite (JFA_A + silhouette → backbuffer)
        if (saved_rt0) |rt| deviceSetRenderTarget(device, 0, rt);
        deviceSetTexture(device, 0, rt_jfa_a_tex);
        deviceSetTexture(device, 1, rt_silhouette_tex);
        // V32 POLISH: hard 3px edge, no feather.
        c0 = [4]f32{ fw, fh, 3.0, 0.0 };
        deviceSetPSConstF(device, 0, &c0);
        deviceSetPtr(device, types.VT.SetPixelShader, jfa_decode_ps.?);
        deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, 1);
        deviceSetRS(device, types.D3DRS.SRCBLEND, types.D3DBLEND_SRCALPHA);
        deviceSetRS(device, types.D3DRS.DESTBLEND, types.D3DBLEND_INVSRCALPHA);
        deviceDrawPrimitiveUP(device, types.D3DPT_TRIANGLESTRIP, 2, @ptrCast(&quad), qstride);
    } // end else (normal JFA path)

    // =====================================================================
    // Restore ALL state
    // =====================================================================

    // Render states
    deviceSetRS(device, types.D3DRS.ZENABLE, saved_zenable);
    deviceSetRS(device, types.D3DRS.ZWRITEENABLE, saved_zwrite);
    deviceSetRS(device, types.D3DRS.ZFUNC, saved_zfunc);
    deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, saved_ablend);
    deviceSetRS(device, types.D3DRS.SRCBLEND, saved_srcblend);
    deviceSetRS(device, types.D3DRS.DESTBLEND, saved_dstblend);
    deviceSetRS(device, types.D3DRS.CULLMODE, saved_cull);
    deviceSetRS(device, types.D3DRS.ALPHATESTENABLE, saved_atest);
    deviceSetRS(device, types.D3DRS.ALPHAREF, saved_aref);
    deviceSetRS(device, types.D3DRS.ALPHAFUNC, saved_afunc);
    deviceSetRS(device, types.D3DRS.TEXTUREFACTOR, saved_tfactor);
    deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, saved_cwrite);
    for (0..4) |stage| {
        deviceSetTSS(device, @intCast(stage), types.D3DTSS.COLOROP, saved_tss[stage].colorop);
        deviceSetTSS(device, @intCast(stage), types.D3DTSS.COLORARG1, saved_tss[stage].colorarg1);
        deviceSetTSS(device, @intCast(stage), types.D3DTSS.ALPHAOP, saved_tss[stage].alphaop);
        deviceSetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG1, saved_tss[stage].alphaarg1);
        deviceSetTSS(device, @intCast(stage), types.D3DTSS.ALPHAARG2, saved_tss[stage].alphaarg2);
    }

    // Stencil states
    deviceSetRS(device, types.D3DRS.STENCILENABLE, saved_stencil_enable);
    deviceSetRS(device, types.D3DRS.STENCILFUNC, saved_stencil_func);
    deviceSetRS(device, types.D3DRS.STENCILREF, saved_stencil_ref);
    deviceSetRS(device, types.D3DRS.STENCILMASK, saved_stencil_mask);
    deviceSetRS(device, types.D3DRS.STENCILWRITEMASK, saved_stencil_wmask);
    deviceSetRS(device, types.D3DRS.STENCILPASS, saved_stencil_pass);

    // Sampler states
    const writeSamp = struct {
        fn f(dev: *anyopaque, stage: u32, s: SampState) void {
            deviceSetSamplerState(dev, stage, types.D3DSAMP.ADDRESSU, s.addru);
            deviceSetSamplerState(dev, stage, types.D3DSAMP.ADDRESSV, s.addrv);
            deviceSetSamplerState(dev, stage, types.D3DSAMP.MAGFILTER, s.mag);
            deviceSetSamplerState(dev, stage, types.D3DSAMP.MINFILTER, s.min);
            deviceSetSamplerState(dev, stage, types.D3DSAMP.MIPFILTER, s.mip);
        }
    }.f;
    writeSamp(device, 0, saved_samp0);
    writeSamp(device, 1, saved_samp1);

    // Shader constants
    deviceSetPSConstF(device, 0, &saved_psc0);
    deviceSetVSConstF(device, 0, &saved_vs_consts, MAX_VS_CONST_REGS);

    // COM objects (restore binding then release our ref)
    if (saved_rt0) |rt| {
        deviceSetRenderTarget(device, 0, rt);
        comRelease(rt);
    } // RT0
    deviceSetPtrOrNull(device, types.VT.SetDepthStencilSurface, saved_ds); // DS
    if (saved_ds) |ds| comRelease(ds);
    deviceSetPtrOrNull(device, types.VT.SetPixelShader, saved_ps); // PS
    if (saved_ps) |p| comRelease(p);
    deviceSetPtrOrNull(device, types.VT.SetVertexShader, saved_vs); // VS
    if (saved_vs) |v| comRelease(v);
    deviceSetPtrOrNull(device, types.VT.SetVertexDeclaration, saved_decl); // Vertex decl
    if (saved_decl) |d| comRelease(d);
    deviceSetStreamSource(device, 0, saved_vb, saved_vb_offset, saved_vb_stride); // VB
    if (saved_vb) |v| comRelease(v);
    deviceSetIndices(device, saved_ib); // IB
    if (saved_ib) |i| comRelease(i);
    deviceSetTexture(device, 0, saved_tex0); // Tex0
    if (saved_tex0) |t| comRelease(t);
    deviceSetTexture(device, 1, saved_tex1); // Tex1
    if (saved_tex1) |t| comRelease(t);
}

// =============================================================================
// Force D24S8 depth/stencil on first EndScene (deferred hooks miss initial Reset)
// =============================================================================

fn hasStencilBits(fmt: u32) bool {
    return fmt == types.D3DFMT_D24S8 or fmt == types.D3DFMT_D24FS8 or
        fmt == types.D3DFMT_D24X4S4 or fmt == types.D3DFMT_D15S1;
}

fn queryStencilFormat(device: *anyopaque) u32 {
    var pDS: ?*anyopaque = null;
    const getDS: *const fn (*anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[types.VT.GetDepthStencilSurface]);
    if (getDS(device, &pDS) < 0) return 0;
    const ds = pDS orelse return 0;

    var desc: types.D3DSURFACE_DESC = .{};
    const getDesc: *const fn (*anyopaque, *types.D3DSURFACE_DESC) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(ds)[12]);
    const hr = getDesc(ds, &desc);
    comRelease(ds);
    if (hr < 0) return 0;
    return desc.Format;
}

fn forceD24S8IfNeeded(device: *anyopaque) bool {
    const current_fmt = queryStencilFormat(device);
    debug_stencil_format = current_fmt;
    if (hasStencilBits(current_fmt)) {
        debug_stencil_ready = true;
        debug_stencil_reset_hr = 0;
        return false;
    }

    var pSwap: ?*anyopaque = null;
    const getSC: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[types.VT.GetSwapChain]);
    if (getSC(device, 0, &pSwap) < 0) return false;
    const swap = pSwap orelse return false;

    var pp: types.D3DPRESENT_PARAMETERS = .{};
    const getPP: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(swap)[9]);
    const pp_hr = getPP(swap, &pp);
    // IMPORTANT: do not hold a swap-chain COM reference across Reset.
    comRelease(swap);
    if (pp_hr < 0) return false;

    pp.AutoDepthStencilFormat = types.D3DFMT_D24S8;
    pp.EnableAutoDepthStencil = 1;

    clearCachedDraws();
    releaseShaders();
    releaseResources();

    const resetFn: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[types.VT.Reset]);
    const reset_hr = resetFn(device, &pp);
    debug_stencil_reset_hr = reset_hr;
    if (reset_hr < 0) {
        debug_stencil_ready = false;
        return false;
    }

    const new_fmt = queryStencilFormat(device);
    debug_stencil_format = new_fmt;
    debug_stencil_ready = hasStencilBits(new_fmt);
    return true;
}

// =============================================================================
// Vtable patching helpers
// =============================================================================

extern "kernel32" fn VirtualProtect(
    addr: *anyopaque,
    size: usize,
    new_prot: u32,
    old_prot: *u32,
) callconv(WINAPI) i32;

fn patchVtableEntry(vtable_ptr: [*]usize, idx: usize, new_fn: usize, old_fn: *usize) bool {
    old_fn.* = vtable_ptr[idx];
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0)
        return false;
    vtable_ptr[idx] = new_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
    return true;
}

fn restoreVtableEntry(vtable_ptr: [*]usize, idx: usize, old_fn: usize) void {
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0)
        return;
    vtable_ptr[idx] = old_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
}

// =============================================================================
// D3D9 device / vtable discovery from game's existing device
// =============================================================================

const offsets = @import("../offsets.zig");

fn getD3D9VTable() ?[*]usize {
    const gx_device = hook.readMem(u32, offsets.GX_DEVICE_PTR);
    if (gx_device == 0) return null;

    const d3d_device = hook.readMem(u32, gx_device + offsets.GX_DEVICE_D3D_OFFSET);
    if (d3d_device == 0) return null;

    const vtable_addr = hook.readMem(u32, d3d_device);
    if (vtable_addr == 0) return null;

    return @ptrFromInt(vtable_addr);
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() bool {
    if (hooks_installed) return true;

    const vtable_ptr = getD3D9VTable() orelse return false;
    d3d9_vtable = vtable_ptr;

    if (!patchVtableEntry(vtable_ptr, types.VT.EndScene, @intFromPtr(&hkEndScene), &orig_endscene)) return false;
    if (!patchVtableEntry(vtable_ptr, types.VT.DrawIndexedPrimitive, @intFromPtr(&hkDIP), &orig_dip)) return false;
    if (!patchVtableEntry(vtable_ptr, types.VT.Reset, @intFromPtr(&hkReset), &orig_reset)) return false;

    hooks_installed = true;
    return true;
}

pub fn removeHooks() void {
    if (!hooks_installed) return;

    clearCachedDraws();
    releaseShaders();
    releaseResources();

    if (d3d9_vtable) |vtbl| {
        if (orig_reset != 0) restoreVtableEntry(vtbl, types.VT.Reset, orig_reset);
        if (orig_dip != 0) restoreVtableEntry(vtbl, types.VT.DrawIndexedPrimitive, orig_dip);
        if (orig_endscene != 0) restoreVtableEntry(vtbl, types.VT.EndScene, orig_endscene);
    }

    hooks_installed = false;
}
