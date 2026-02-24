//! D3D9 vtable hooks for outline rendering.
//!
//! Patches IDirect3DDevice9 vtable entries for EndScene, DrawIndexedPrimitive,
//! and Reset via the dummy-device technique (shared vtable across all devices).
//!
//! - **EndScene**: per-frame object scan, stencil clear, shader creation.
//! - **DIP**: three-pass stencil-based outline when flagged by DrawBatchProj.
//! - **Reset**: forces D24S8 depth/stencil format for 8 stencil bits.

const std = @import("std");
const hook = @import("hook");
const types = @import("types.zig");
const tracker = @import("tracker.zig");
const model_hook = @import("model_hook.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

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
    const f: *const fn (*anyopaque) callconv(sc) i32 = @ptrFromInt(vt(obj)[idx]);
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

/// True until the first EndScene verifies (and if needed, forces) D24S8 format.
var need_force_reset: bool = true;

// =============================================================================
// Outline shader resources (created on first use)
// =============================================================================

var outline_vs: ?*anyopaque = null; // IDirect3DVertexShader9*
var outline_ps: ?*anyopaque = null; // IDirect3DPixelShader9*
var outline_decl: ?*anyopaque = null; // IDirect3DVertexDeclaration9*
var shaders_attempted: bool = false;

// D3DXAssembleShader function pointer (loaded dynamically)
const D3DXAssembleShaderFn = *const fn (
    [*]const u8, // pSrcData
    u32, // SrcDataLen
    ?*anyopaque, // pDefines
    ?*anyopaque, // pInclude
    u32, // Flags
    *?*anyopaque, // ppShader (ID3DXBuffer**)
    *?*anyopaque, // ppErrorMsgs (ID3DXBuffer**)
) callconv(sc) i32;

// =============================================================================
// EndScene hook
// =============================================================================

fn hkEndScene(device: *anyopaque) callconv(sc) i32 {
    // One-time: check if depth/stencil surface has stencil bits.
    // Because D3D9 hooks are installed after engine init (deferred), we miss
    // the initial Reset. If the surface lacks stencil, force a Reset now.
    if (need_force_reset) {
        need_force_reset = false;
        forceD24S8IfNeeded(device);
    }

    // Per-frame: scan objects for outline tracking
    tracker.scanObjects();

    // Clear stencil for next frame
    if (tracker.enabled and tracker.hasTargets()) {
        // IDirect3DDevice9::Clear(0, NULL, D3DCLEAR_STENCIL, 0, 1.0, 0)
        deviceClear(device, types.D3DCLEAR_STENCIL);
    }

    // Reset per-frame flags
    model_hook.test_outline_stencil = false;
    model_hook.rendering_unit = false;
    model_hook.rendering_outline = false;
    model_hook.current_model = 0;

    // Call original EndScene
    const f: *const fn (*anyopaque) callconv(sc) i32 = @ptrFromInt(orig_endscene);
    return f(device);
}

// =============================================================================
// Reset hook — force D24S8 depth/stencil format
// =============================================================================

fn hkReset(device: *anyopaque, pp: *types.D3DPRESENT_PARAMETERS) callconv(sc) i32 {
    // If auto depth-stencil is enabled, force D24S8 format
    if (pp.EnableAutoDepthStencil != 0) {
        const fmt = pp.AutoDepthStencilFormat;
        if (fmt != types.D3DFMT_D24S8 and fmt != types.D3DFMT_D24FS8 and
            fmt != types.D3DFMT_D24X4S4 and fmt != types.D3DFMT_D15S1)
        {
            pp.AutoDepthStencilFormat = types.D3DFMT_D24S8;
        }
    }

    // Release shaders (device state lost on reset)
    releaseShaders();

    const f: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(sc) i32 = @ptrFromInt(orig_reset);
    return f(device, pp);
}

// =============================================================================
// DrawIndexedPrimitive hook — three-pass outline rendering
// =============================================================================

fn hkDIP(
    device: *anyopaque,
    prim_type: u32,
    base_vtx: i32,
    min_vtx: u32,
    num_verts: u32,
    start_idx: u32,
    prim_count: u32,
) callconv(sc) i32 {
    const OrigDIP = *const fn (*anyopaque, u32, i32, u32, u32, u32, u32) callconv(sc) i32;
    const origFn: OrigDIP = @ptrFromInt(orig_dip);

    // ---- Outline rendering path ----
    if (model_hook.rendering_outline) {
        const model_ptr = model_hook.current_model;
        const color = tracker.getModelColor(model_ptr) orelse
            return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
        const category = tracker.getModelCategory(model_ptr);

        // Try to ensure outline shaders exist
        if (!shaders_attempted) ensureShaders(device);

        // If shaders are not available, render normally
        if (outline_vs == null or outline_ps == null) {
            return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
        }

        // --- Save render state ---
        const saved_vs = deviceGetPtr(device, types.VT.GetVertexShader);
        const saved_ps = deviceGetPtr(device, types.VT.GetPixelShader);
        const saved_decl = deviceGetPtr(device, types.VT.GetVertexDeclaration);
        const saved_cull = deviceGetRS(device, types.D3DRS.CULLMODE);
        const saved_ablend = deviceGetRS(device, types.D3DRS.ALPHABLENDENABLE);
        const saved_zenable = deviceGetRS(device, types.D3DRS.ZENABLE);
        const saved_zfunc = deviceGetRS(device, types.D3DRS.ZFUNC);
        const saved_colorwr = deviceGetRS(device, types.D3DRS.COLORWRITEENABLE);
        const saved_stencil_en = deviceGetRS(device, types.D3DRS.STENCILENABLE);
        const saved_stencil_fn = deviceGetRS(device, types.D3DRS.STENCILFUNC);
        const saved_stencil_ref = deviceGetRS(device, types.D3DRS.STENCILREF);
        const saved_stencil_mask = deviceGetRS(device, types.D3DRS.STENCILMASK);
        const saved_stencil_wmask = deviceGetRS(device, types.D3DRS.STENCILWRITEMASK);
        const saved_stencil_pass = deviceGetRS(device, types.D3DRS.STENCILPASS);

        // Save VS constants c251-c252 (we overwrite these)
        var saved_c251: [4]f32 = undefined;
        var saved_c252: [4]f32 = undefined;
        deviceGetVSConstF(device, 251, &saved_c251);
        deviceGetVSConstF(device, 252, &saved_c252);

        // Save PS constant c0 (we overwrite for outline color)
        var saved_ps_c0: [4]f32 = undefined;
        deviceGetPSConstF(device, 0, &saved_ps_c0);

        // ========== PASS 1: Mark body in stencil (no color write) ==========
        deviceSetRS(device, types.D3DRS.STENCILENABLE, 1);
        deviceSetRS(device, types.D3DRS.STENCILFUNC, types.D3DCMP_ALWAYS);
        deviceSetRS(device, types.D3DRS.STENCILREF, types.STENCIL_BIT_BODY);
        deviceSetRS(device, types.D3DRS.STENCILMASK, 0xFF);
        deviceSetRS(device, types.D3DRS.STENCILWRITEMASK, types.STENCIL_BIT_BODY);
        deviceSetRS(device, types.D3DRS.STENCILPASS, types.D3DSTENCILOP_REPLACE);
        deviceSetRS(device, types.D3DRS.STENCILFAIL, types.D3DSTENCILOP_KEEP);
        deviceSetRS(device, types.D3DRS.STENCILZFAIL, types.D3DSTENCILOP_KEEP);
        deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0); // stencil only
        _ = origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
        deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, 0x0F);

        // ========== PASS 2: Draw enlarged outline ==========
        // Set outline shaders
        deviceSetPtr(device, types.VT.SetVertexShader, outline_vs.?);
        if (outline_decl) |d| deviceSetPtr(device, types.VT.SetVertexDeclaration, d);
        deviceSetPtr(device, types.VT.SetPixelShader, outline_ps.?);

        // Cull front faces → only back faces of the enlarged model visible
        deviceSetRS(device, types.D3DRS.CULLMODE, types.D3DCULL_CCW);
        deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, 0);

        // Stencil: draw only where body bit is NOT set, write outline bit
        deviceSetRS(device, types.D3DRS.STENCILENABLE, 1);
        deviceSetRS(device, types.D3DRS.STENCILFUNC, types.D3DCMP_EQUAL);
        deviceSetRS(device, types.D3DRS.STENCILREF, types.STENCIL_BIT_OUTLINE);
        deviceSetRS(device, types.D3DRS.STENCILMASK, types.STENCIL_BIT_BODY);
        deviceSetRS(device, types.D3DRS.STENCILWRITEMASK, types.STENCIL_BIT_OUTLINE);
        deviceSetRS(device, types.D3DRS.STENCILPASS, types.D3DSTENCILOP_REPLACE);
        deviceSetRS(device, types.D3DRS.STENCILFAIL, types.D3DSTENCILOP_KEEP);
        deviceSetRS(device, types.D3DRS.STENCILZFAIL, types.D3DSTENCILOP_KEEP);

        // Depth: dead players through walls (no Z), others respect depth
        if (category == .dead_player) {
            deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_FALSE);
        } else {
            deviceSetRS(device, types.D3DRS.ZENABLE, types.D3DZB_TRUE);
            deviceSetRS(device, types.D3DRS.ZFUNC, types.D3DCMP_LESSEQUAL);
        }

        // Set VS constants: c251 = (765, 1, 0, 0), c252 = pixel scale
        const c251 = [4]f32{ 765.0, 1.0, 0.0, 0.0 };
        deviceSetVSConstF(device, 251, &c251);

        var vp: types.D3DVIEWPORT9 = .{};
        deviceGetViewport(device, &vp);
        const pixels = tracker.getOutlinePixels(category);
        const c252 = [4]f32{
            pixels * 2.0 / @as(f32, @floatFromInt(@max(vp.Width, 1))),
            pixels * 2.0 / @as(f32, @floatFromInt(@max(vp.Height, 1))),
            0.0,
            0.0,
        };
        deviceSetVSConstF(device, 252, &c252);

        // PS c0 = outline colour (ARGB → float4 RGBA)
        const ps_color = [4]f32{
            @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(color & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0,
        };
        deviceSetPSConstF(device, 0, &ps_color);

        _ = origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);

        // ========== PASS 3: Restore state, draw normal model on top ==========
        deviceSetPtrOrNull(device, types.VT.SetVertexShader, saved_vs);
        deviceSetPtrOrNull(device, types.VT.SetVertexDeclaration, saved_decl);
        deviceSetPtrOrNull(device, types.VT.SetPixelShader, saved_ps);
        deviceSetRS(device, types.D3DRS.CULLMODE, saved_cull);
        deviceSetRS(device, types.D3DRS.ALPHABLENDENABLE, saved_ablend);
        deviceSetRS(device, types.D3DRS.ZENABLE, saved_zenable);
        deviceSetRS(device, types.D3DRS.ZFUNC, saved_zfunc);
        deviceSetRS(device, types.D3DRS.COLORWRITEENABLE, saved_colorwr);
        deviceSetRS(device, types.D3DRS.STENCILENABLE, saved_stencil_en);
        deviceSetRS(device, types.D3DRS.STENCILFUNC, saved_stencil_fn);
        deviceSetRS(device, types.D3DRS.STENCILREF, saved_stencil_ref);
        deviceSetRS(device, types.D3DRS.STENCILMASK, saved_stencil_mask);
        deviceSetRS(device, types.D3DRS.STENCILWRITEMASK, saved_stencil_wmask);
        deviceSetRS(device, types.D3DRS.STENCILPASS, saved_stencil_pass);
        deviceSetVSConstF(device, 251, &saved_c251);
        deviceSetVSConstF(device, 252, &saved_c252);
        deviceSetPSConstF(device, 0, &saved_ps_c0);

        if (saved_vs) |p| comRelease(p);
        if (saved_ps) |p| comRelease(p);
        if (saved_decl) |p| comRelease(p);

        return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
    }

    // ---- Stencil-test path for non-outline units (prevent covering outlines) ----
    if (model_hook.test_outline_stencil and model_hook.rendering_unit) {
        const saved_en = deviceGetRS(device, types.D3DRS.STENCILENABLE);
        const saved_fn2 = deviceGetRS(device, types.D3DRS.STENCILFUNC);
        const saved_ref2 = deviceGetRS(device, types.D3DRS.STENCILREF);
        const saved_mask2 = deviceGetRS(device, types.D3DRS.STENCILMASK);
        const saved_pass2 = deviceGetRS(device, types.D3DRS.STENCILPASS);

        deviceSetRS(device, types.D3DRS.STENCILENABLE, 1);
        deviceSetRS(device, types.D3DRS.STENCILFUNC, types.D3DCMP_EQUAL);
        deviceSetRS(device, types.D3DRS.STENCILREF, 0x00);
        deviceSetRS(device, types.D3DRS.STENCILMASK, types.STENCIL_BIT_OUTLINE);
        deviceSetRS(device, types.D3DRS.STENCILPASS, types.D3DSTENCILOP_KEEP);
        deviceSetRS(device, types.D3DRS.STENCILFAIL, types.D3DSTENCILOP_KEEP);
        deviceSetRS(device, types.D3DRS.STENCILZFAIL, types.D3DSTENCILOP_KEEP);

        const hr = origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);

        deviceSetRS(device, types.D3DRS.STENCILENABLE, saved_en);
        deviceSetRS(device, types.D3DRS.STENCILFUNC, saved_fn2);
        deviceSetRS(device, types.D3DRS.STENCILREF, saved_ref2);
        deviceSetRS(device, types.D3DRS.STENCILMASK, saved_mask2);
        deviceSetRS(device, types.D3DRS.STENCILPASS, saved_pass2);
        return hr;
    }

    // ---- Normal path ----
    return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
}

// =============================================================================
// Device helper wrappers (stdcall COM vtable calls)
// =============================================================================

fn deviceSetRS(dev: *anyopaque, state: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32) callconv(sc) i32 = @ptrFromInt(vt(dev)[types.VT.SetRenderState]);
    _ = f(dev, state, value);
}

fn deviceGetRS(dev: *anyopaque, state: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, *u32) callconv(sc) i32 = @ptrFromInt(vt(dev)[types.VT.GetRenderState]);
    _ = f(dev, state, &val);
    return val;
}

fn deviceSetPtr(dev: *anyopaque, idx: usize, ptr: *anyopaque) void {
    const f: *const fn (*anyopaque, *anyopaque) callconv(sc) i32 = @ptrFromInt(vt(dev)[idx]);
    _ = f(dev, ptr);
}

fn deviceGetPtr(dev: *anyopaque, idx: usize) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    const f: *const fn (*anyopaque, *?*anyopaque) callconv(sc) i32 = @ptrFromInt(vt(dev)[idx]);
    _ = f(dev, &ptr);
    return ptr;
}

/// Set a COM pointer, handling the null case by passing 0 via raw write.
fn deviceSetPtrOrNull(dev: *anyopaque, idx: usize, ptr: ?*anyopaque) void {
    if (ptr) |p| {
        deviceSetPtr(dev, idx, p);
    } else {
        // COM method expects a pointer param; pass NULL (0) via asm to avoid
        // Zig's "no null in *anyopaque" constraint.
        const func_addr = vt(dev)[idx];
        asm volatile (
            \\push $0
            \\push %[self]
            \\call *%[func]
            :
            : [self] "r" (@intFromPtr(dev)),
              [func] "r" (func_addr),
            : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true }
        );
    }
}

fn deviceSetVSConstF(dev: *anyopaque, start: u32, data: *const [4]f32) void {
    const f: *const fn (*anyopaque, u32, *const [4]f32, u32) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetVertexShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceGetVSConstF(dev: *anyopaque, start: u32, data: *[4]f32) void {
    const f: *const fn (*anyopaque, u32, *[4]f32, u32) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetVertexShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceSetPSConstF(dev: *anyopaque, start: u32, data: *const [4]f32) void {
    const f: *const fn (*anyopaque, u32, *const [4]f32, u32) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.SetPixelShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceGetPSConstF(dev: *anyopaque, start: u32, data: *[4]f32) void {
    const f: *const fn (*anyopaque, u32, *[4]f32, u32) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetPixelShaderConstantF]);
    _ = f(dev, start, data, 1);
}

fn deviceGetViewport(dev: *anyopaque, vp: *types.D3DVIEWPORT9) void {
    const f: *const fn (*anyopaque, *types.D3DVIEWPORT9) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.GetViewport]);
    _ = f(dev, vp);
}

fn deviceClear(dev: *anyopaque, flags: u32) void {
    // Clear(count, rects, flags, color, z, stencil)
    const f: *const fn (*anyopaque, u32, ?*anyopaque, u32, u32, f32, u32) callconv(sc) i32 =
        @ptrFromInt(vt(dev)[types.VT.Clear]);
    _ = f(dev, 0, null, flags, 0, 1.0, 0);
}

// =============================================================================
// Force D24S8 depth/stencil on first EndScene (deferred hooks miss initial Reset)
// =============================================================================

fn hasStencilBits(fmt: u32) bool {
    return fmt == types.D3DFMT_D24S8 or fmt == types.D3DFMT_D24FS8 or
        fmt == types.D3DFMT_D24X4S4 or fmt == types.D3DFMT_D15S1;
}

fn forceD24S8IfNeeded(device: *anyopaque) void {
    // GetDepthStencilSurface(ppSurface)
    var pDS: ?*anyopaque = null;
    const getDS: *const fn (*anyopaque, *?*anyopaque) callconv(sc) i32 =
        @ptrFromInt(vt(device)[types.VT.GetDepthStencilSurface]);
    if (getDS(device, &pDS) < 0) return;
    const ds = pDS orelse return;
    defer comRelease(ds);

    // IDirect3DSurface9::GetDesc — vtable index 12
    // (IUnknown 0-2, IDirect3DResource9 3-10, GetContainer 11, GetDesc 12)
    var desc: types.D3DSURFACE_DESC = .{};
    const getDesc: *const fn (*anyopaque, *types.D3DSURFACE_DESC) callconv(sc) i32 =
        @ptrFromInt(vt(ds)[12]);
    if (getDesc(ds, &desc) < 0) return;

    if (hasStencilBits(desc.Format)) return; // already good

    // Get current present parameters from swap chain 0
    // GetSwapChain(0, ppSwapChain)
    var pSwap: ?*anyopaque = null;
    const getSC: *const fn (*anyopaque, u32, *?*anyopaque) callconv(sc) i32 =
        @ptrFromInt(vt(device)[types.VT.GetSwapChain]);
    if (getSC(device, 0, &pSwap) < 0) return;
    const swap = pSwap orelse return;
    defer comRelease(swap);

    // IDirect3DSwapChain9::GetPresentParameters — vtable index 9
    var pp: types.D3DPRESENT_PARAMETERS = .{};
    const getPP: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(sc) i32 =
        @ptrFromInt(vt(swap)[9]);
    if (getPP(swap, &pp) < 0) return;

    // Force D24S8 and reset
    pp.AutoDepthStencilFormat = types.D3DFMT_D24S8;
    pp.EnableAutoDepthStencil = 1;

    // Release shaders before reset (device state lost)
    releaseShaders();

    // Call Reset through our hook (which also enforces D24S8)
    const resetFn: *const fn (*anyopaque, *types.D3DPRESENT_PARAMETERS) callconv(sc) i32 =
        @ptrFromInt(vt(device)[types.VT.Reset]);
    _ = resetFn(device, &pp);
}

// =============================================================================
// Shader creation (loaded dynamically from d3dx9_43.dll)
// =============================================================================

fn ensureShaders(device: *anyopaque) void {
    shaders_attempted = true;

    // Load D3DX9 for shader assembly
    const d3dx = LoadLibraryA("d3dx9_43.dll") orelse
        LoadLibraryA("d3dx9_42.dll") orelse
        LoadLibraryA("d3dx9_41.dll") orelse return;
    const assemble_ptr = GetProcAddress(d3dx, "D3DXAssembleShader") orelse return;
    const assemble: D3DXAssembleShaderFn = @ptrCast(assemble_ptr);

    // --- Vertex shader: screen-space normal extrusion with bone matrices ---
    const vs_src =
        "vs_2_0\n" ++
        "dcl_position v0\n" ++
        "dcl_blendweight v2\n" ++
        "dcl_blendindices v3\n" ++
        "dcl_normal v1\n" ++
        "mul r0.xyz, v3.zyxw, c251.x\n" ++
        "mova a0.xyz, r0\n" ++
        "mul r0, v2.y, c[a0.y + 31]\n" ++
        "mad r0, c[a0.x + 31], v2.z, r0\n" ++
        "mad r0, c[a0.z + 31], v2.x, r0\n" ++
        "dp3 r3.x, r0, v1\n" ++
        "dp4 r4.x, r0, v0\n" ++
        "mul r1, v2.y, c[a0.y + 32]\n" ++
        "mad r1, c[a0.x + 32], v2.z, r1\n" ++
        "mad r1, c[a0.z + 32], v2.x, r1\n" ++
        "dp3 r3.y, r1, v1\n" ++
        "dp4 r4.y, r1, v0\n" ++
        "mul r2, v2.y, c[a0.y + 33]\n" ++
        "mad r2, c[a0.x + 33], v2.z, r2\n" ++
        "mad r2, c[a0.z + 33], v2.x, r2\n" ++
        "dp3 r3.z, r2, v1\n" ++
        "dp4 r4.z, r2, v0\n" ++
        "mov r4.w, c251.y\n" ++
        "nrm r5.xyz, r3\n" ++
        "dp4 r6.x, c2, r4\n" ++
        "dp4 r6.y, c3, r4\n" ++
        "dp4 r6.z, c4, r4\n" ++
        "dp4 r6.w, c5, r4\n" ++
        "mov r5.w, c251.z\n" ++
        "dp4 r7.x, c2, r5\n" ++
        "dp4 r7.y, c3, r5\n" ++
        "mul r8.x, r7.x, r7.x\n" ++
        "mad r8.x, r7.y, r7.y, r8.x\n" ++
        "rsq r8.x, r8.x\n" ++
        "mul r7.xy, r7.xy, r8.xx\n" ++
        "mul r8.xy, r7.xy, c252.xy\n" ++
        "mul r8.xy, r8.xy, r6.ww\n" ++
        "add r6.xy, r6.xy, r8.xy\n" ++
        "mov oPos, r6\n";

    var vs_code: ?*anyopaque = null;
    var vs_err: ?*anyopaque = null;
    if (assemble(vs_src, vs_src.len, null, null, 0, &vs_code, &vs_err) < 0 or vs_code == null) {
        if (vs_err) |e| comRelease(e);
        return;
    }
    defer comRelease(vs_code.?);
    if (vs_err) |e| comRelease(e);

    // Create vertex shader from compiled bytecode
    {
        // ID3DXBuffer::GetBufferPointer is vtable[3], GetBufferSize is vtable[4]
        const buf_ptr: *anyopaque = @ptrFromInt(
            @as(*const fn (*anyopaque) callconv(sc) usize, @ptrFromInt(vt(vs_code.?)[3]))(vs_code.?),
        );
        // CreateVertexShader(pFunction, ppShader)
        const create: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(sc) i32 =
            @ptrFromInt(vt(device)[types.VT.CreateVertexShader]);
        if (create(device, buf_ptr, &outline_vs) < 0) return;
    }

    // --- Pixel shader: solid color from PS constant c0 ---
    const ps_src = "ps_3_0\nmov oC0, c0\n";
    var ps_code: ?*anyopaque = null;
    var ps_err: ?*anyopaque = null;
    if (assemble(ps_src, ps_src.len, null, null, 0, &ps_code, &ps_err) < 0 or ps_code == null) {
        if (ps_err) |e| comRelease(e);
        releaseShaders();
        return;
    }
    defer comRelease(ps_code.?);
    if (ps_err) |e| comRelease(e);

    {
        const buf_ptr: *anyopaque = @ptrFromInt(
            @as(*const fn (*anyopaque) callconv(sc) usize, @ptrFromInt(vt(ps_code.?)[3]))(ps_code.?),
        );
        const create: *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(sc) i32 =
            @ptrFromInt(vt(device)[types.VT.CreatePixelShader]);
        if (create(device, buf_ptr, &outline_ps) < 0) {
            releaseShaders();
            return;
        }
    }

    // --- Vertex declaration matching WoW M2 format ---
    // Position (float3) @ 0, BlendWeight (D3DCOLOR) @ 12, BlendIndices (D3DCOLOR) @ 16, Normal (float3) @ 20
    const D3DDECL_END = [_]u8{ 0xFF, 0, 0, 0, 0, 0, 0, 0 };
    const decl_bytes = [_]u8{
        // stream=0, offset=0, type=2 (FLOAT3), method=0, usage=0 (POSITION), usageIndex=0
        0, 0, 0, 0, 2, 0, 0, 0,
        // stream=0, offset=12, type=4 (D3DCOLOR), method=0, usage=1 (BLENDWEIGHT), usageIndex=0
        0, 0, 12, 0, 4, 0, 1, 0,
        // stream=0, offset=16, type=4 (D3DCOLOR), method=0, usage=2 (BLENDINDICES), usageIndex=0
        0, 0, 16, 0, 4, 0, 2, 0,
        // stream=0, offset=20, type=2 (FLOAT3), method=0, usage=3 (NORMAL), usageIndex=0
        0, 0, 20, 0, 2, 0, 3, 0,
    } ++ D3DDECL_END;

    const create_decl: *const fn (*anyopaque, *const anyopaque, *?*anyopaque) callconv(sc) i32 =
        @ptrFromInt(vt(device)[types.VT.CreateVertexDeclaration]);
    if (create_decl(device, @ptrCast(&decl_bytes), &outline_decl) < 0) {
        releaseShaders();
        return;
    }
}

fn releaseShaders() void {
    if (outline_vs) |p| {
        comRelease(p);
        outline_vs = null;
    }
    if (outline_ps) |p| {
        comRelease(p);
        outline_ps = null;
    }
    if (outline_decl) |p| {
        comRelease(p);
        outline_decl = null;
    }
    shaders_attempted = false;
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
// D3D9 vtable discovery from game's existing device
// =============================================================================
// Reads the device pointer from WoW's GxDevice global instead of creating a
// dummy device. Creating a dummy device through the d3d9 proxy on the main
// thread corrupts the proxy's internal state and causes model rendering to
// stutter at ~10fps. Reading the existing device avoids this entirely.
//
// Source: UnitXP_SP3 — vanilla1121_gxDevice() / vanilla1121_d3dDevice()
//   gxDevice   = *(uint32_t*)0xC0ED38
//   d3dDevice  = *(void**)(gxDevice + 0x38A8)

const GX_DEVICE_PTR: usize = 0xC0ED38;
const GX_DEVICE_D3D_OFFSET: usize = 0x38A8;

fn getD3D9VTable() ?[*]usize {
    const gx_device = hook.readMem(u32, GX_DEVICE_PTR);
    if (gx_device == 0) return null;

    const d3d_device = hook.readMem(u32, gx_device + GX_DEVICE_D3D_OFFSET);
    if (d3d_device == 0) return null;

    // First dword of the COM object is the vtable pointer
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

    releaseShaders();

    if (d3d9_vtable) |vtbl| {
        if (orig_reset != 0) restoreVtableEntry(vtbl, types.VT.Reset, orig_reset);
        if (orig_dip != 0) restoreVtableEntry(vtbl, types.VT.DrawIndexedPrimitive, orig_dip);
        if (orig_endscene != 0) restoreVtableEntry(vtbl, types.VT.EndScene, orig_endscene);
    }

    hooks_installed = false;
}
