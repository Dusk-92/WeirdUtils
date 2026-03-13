//! Shared D3D9 device helpers for direct vtable calls.
//!
//! Bypasses the game's GxDevice abstraction layer for modules that need
//! direct IDirect3DDevice9 access (outline, transform44, etc).

const hook = @import("zhook");
const offsets = @import("offsets.zig");

// Re-export D3D9 constants and types from outline/types.zig
pub const types = @import("outline/types.zig");

// =============================================================================
// Device discovery
// =============================================================================

/// Get the game's IDirect3DDevice9* from the GxDevice global.
pub fn getDevice() ?*anyopaque {
    const gx_device = hook.readMem(u32, offsets.GX_DEVICE_PTR);
    if (gx_device == 0) return null;
    const d3d_device = hook.readMem(u32, gx_device + offsets.GX_DEVICE_D3D_OFFSET);
    if (d3d_device == 0) return null;
    return @ptrFromInt(d3d_device);
}

// =============================================================================
// COM vtable helper
// =============================================================================

pub inline fn vt(obj: *anyopaque) [*]usize {
    return @ptrFromInt(hook.readMem(u32, @intFromPtr(obj)));
}

// =============================================================================
// Device call wrappers
// =============================================================================

pub fn setRenderState(dev: *anyopaque, state: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetRenderState]);
    _ = f(dev, state, value);
}

pub fn getRenderState(dev: *anyopaque, state: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, *u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.GetRenderState]);
    _ = f(dev, state, &val);
    return val;
}

pub fn setTexture(dev: *anyopaque, stage: u32, tex: ?*anyopaque) void {
    const f: *const fn (*anyopaque, u32, ?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetTexture]);
    _ = f(dev, stage, tex);
}

pub fn getTexture(dev: *anyopaque, stage: u32) ?*anyopaque {
    var tex: ?*anyopaque = null;
    const f: *const fn (*anyopaque, u32, *?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.GetTexture]);
    _ = f(dev, stage, &tex);
    return tex;
}

pub fn setFVF(dev: *anyopaque, fvf: u32) void {
    const f: *const fn (*anyopaque, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetFVF]);
    _ = f(dev, fvf);
}

pub fn setTextureStageState(dev: *anyopaque, stage: u32, state_type: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetTextureStageState]);
    _ = f(dev, stage, state_type, value);
}

pub fn setSamplerState(dev: *anyopaque, sampler: u32, state_type: u32, value: u32) void {
    const f: *const fn (*anyopaque, u32, u32, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetSamplerState]);
    _ = f(dev, sampler, state_type, value);
}

pub fn getSamplerState(dev: *anyopaque, sampler: u32, state_type: u32) u32 {
    var val: u32 = 0;
    const f: *const fn (*anyopaque, u32, u32, *u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetSamplerState]);
    _ = f(dev, sampler, state_type, &val);
    return val;
}

pub fn setVertexShader(dev: *anyopaque, shader: ?*anyopaque) void {
    const f: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetVertexShader]);
    _ = f(dev, shader);
}

pub fn setPixelShader(dev: *anyopaque, shader: ?*anyopaque) void {
    const f: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetPixelShader]);
    _ = f(dev, shader);
}

pub fn drawPrimitiveUP(dev: *anyopaque, prim_type: u32, prim_count: u32, data: *const anyopaque, stride: u32) void {
    const f: *const fn (*anyopaque, u32, u32, *const anyopaque, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.DrawPrimitiveUP]);
    _ = f(dev, prim_type, prim_count, data, stride);
}

pub fn setStreamSource(dev: *anyopaque, stream: u32, vb: ?*anyopaque, offset: u32, stride: u32) void {
    const f: *const fn (*anyopaque, u32, ?*anyopaque, u32, u32) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetStreamSource]);
    _ = f(dev, stream, vb, offset, stride);
}

pub fn setIndices(dev: *anyopaque, ib: ?*anyopaque) void {
    const f: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.SetIndices]);
    _ = f(dev, ib);
}

pub fn getViewport(dev: *anyopaque, vp_out: *types.D3DVIEWPORT9) void {
    const f: *const fn (*anyopaque, *types.D3DVIEWPORT9) callconv(hook.cc.stdcall) i32 = @ptrFromInt(vt(dev)[types.VT.GetViewport]);
    _ = f(dev, vp_out);
}
