//! Shared types, enums, and D3D9 constants for the outline subsystem.

const std = @import("std");

// =============================================================================
// Model categories
// =============================================================================

pub const ModelCategory = enum(u8) {
    none = 0,
    target = 1,
    raid_marked = 2,
    dead_player = 3,
};

// =============================================================================
// WoW object types
// =============================================================================

pub const ObjectType = enum(u32) {
    null_obj = 0,
    item = 1,
    container = 2,
    unit = 3,
    player = 4,
    game_object = 5,
    dynamic_object = 6,
    corpse = 7,
    _,
};

// =============================================================================
// Outline model entry (per-frame tracking)
// =============================================================================

pub const OutlineEntry = struct {
    model_ptr: u32,
    category: ModelCategory,
    /// 1-8 for raid marks, 0 otherwise.
    raid_mark: u8,
};

// =============================================================================
// Outline colours — D3DCOLOR ARGB format (0xAARRGGBB)
// =============================================================================

/// Dead player / corpse outline (cyan).
pub const COLOR_DEAD_PLAYER: u32 = 0xFF00FFFF;

/// Current target outline (golden amber).
pub const COLOR_TARGET: u32 = 0xFFFFC800;

/// Raid mark colours, indexed 0-8. Index 0 = fallback cyan.
pub const RAID_MARK_COLORS = [9]u32{
    0xFF00FFFF, // 0: fallback
    0xFFFFFF00, // 1: Star — Yellow
    0xFFFF8000, // 2: Circle — Orange
    0xFFCC44FF, // 3: Diamond — Purple
    0xFF00FF00, // 4: Triangle — Green
    0xFFC0C0FF, // 5: Moon — Silver/Pale Blue
    0xFF4040FF, // 6: Square — Blue
    0xFFFF2828, // 7: Cross — Soft Red
    0xFFFFF5DC, // 8: Skull — Bone White
};

// =============================================================================
// Screen-space outline thickness (pixels)
// =============================================================================

pub const OUTLINE_PIXELS_TARGET: f32 = 2.25;
pub const OUTLINE_PIXELS_RAID_MARK: f32 = 1.5;
pub const OUTLINE_PIXELS_DEAD_PLAYER: f32 = 2.5;

// =============================================================================
// Stencil bit definitions
// =============================================================================

pub const STENCIL_BIT_BODY: u32 = 0x01;
pub const STENCIL_BIT_OUTLINE: u32 = 0x02;

// =============================================================================
// D3D9 Render State IDs (D3DRENDERSTATETYPE)
// =============================================================================

pub const D3DRS = struct {
    pub const ZENABLE: u32 = 7;
    pub const FILLMODE: u32 = 8;
    pub const ZWRITEENABLE: u32 = 14;
    pub const SRCBLEND: u32 = 19;
    pub const DESTBLEND: u32 = 20;
    pub const CULLMODE: u32 = 22;
    pub const ZFUNC: u32 = 23;
    pub const ALPHABLENDENABLE: u32 = 27;
    pub const STENCILENABLE: u32 = 52;
    pub const STENCILFAIL: u32 = 53;
    pub const STENCILZFAIL: u32 = 54;
    pub const STENCILPASS: u32 = 55;
    pub const STENCILFUNC: u32 = 56;
    pub const STENCILREF: u32 = 57;
    pub const STENCILMASK: u32 = 58;
    pub const STENCILWRITEMASK: u32 = 59;
    pub const TEXTUREFACTOR: u32 = 60;
    pub const COLORWRITEENABLE: u32 = 168;
    pub const DEPTHBIAS: u32 = 195;
};

// =============================================================================
// D3D9 comparison / stencil-op / cull / depth constants
// =============================================================================

pub const D3DCMP_ALWAYS: u32 = 8;
pub const D3DCMP_EQUAL: u32 = 3;
pub const D3DCMP_LESSEQUAL: u32 = 4;

pub const D3DSTENCILOP_KEEP: u32 = 1;
pub const D3DSTENCILOP_REPLACE: u32 = 3;

pub const D3DCULL_CW: u32 = 2;
pub const D3DCULL_CCW: u32 = 3;

pub const D3DZB_FALSE: u32 = 0;
pub const D3DZB_TRUE: u32 = 1;

pub const D3DCLEAR_STENCIL: u32 = 4;

// =============================================================================
// D3D9 texture stage state IDs
// =============================================================================

pub const D3DTSS = struct {
    pub const COLOROP: u32 = 1;
    pub const COLORARG1: u32 = 2;
    pub const ALPHAOP: u32 = 4;
    pub const ALPHAARG1: u32 = 5;
};

pub const D3DTOP_SELECTARG1: u32 = 2;
pub const D3DTA_TFACTOR: u32 = 3;

// =============================================================================
// D3D9 depth/stencil formats
// =============================================================================

pub const D3DFMT_D24S8: u32 = 75;
pub const D3DFMT_D24X4S4: u32 = 79;
pub const D3DFMT_D15S1: u32 = 73;
pub const D3DFMT_D24FS8: u32 = 83;

// =============================================================================
// IDirect3DDevice9 vtable indices
// =============================================================================

pub const VT = struct {
    pub const Release: usize = 2;
    pub const Reset: usize = 16;
    pub const GetSwapChain: usize = 14;
    pub const CreateDepthStencilSurface: usize = 29;
    pub const GetRenderTarget: usize = 38;
    pub const SetDepthStencilSurface: usize = 39;
    pub const GetDepthStencilSurface: usize = 40;
    pub const EndScene: usize = 42;
    pub const Clear: usize = 43;
    pub const SetViewport: usize = 47;
    pub const GetViewport: usize = 48;
    pub const SetRenderState: usize = 57;
    pub const GetRenderState: usize = 58;
    pub const SetTexture: usize = 65;
    pub const SetTextureStageState: usize = 67;
    pub const DrawIndexedPrimitive: usize = 82;
    pub const CreateVertexDeclaration: usize = 86;
    pub const SetVertexDeclaration: usize = 87;
    pub const GetVertexDeclaration: usize = 88;
    pub const CreateVertexShader: usize = 91;
    pub const SetVertexShader: usize = 92;
    pub const GetVertexShader: usize = 93;
    pub const SetVertexShaderConstantF: usize = 94;
    pub const GetVertexShaderConstantF: usize = 95;
    pub const SetStreamSource: usize = 100;
    pub const GetStreamSource: usize = 101;
    pub const SetIndices: usize = 104;
    pub const GetIndices: usize = 105;
    pub const CreatePixelShader: usize = 106;
    pub const SetPixelShader: usize = 107;
    pub const GetPixelShader: usize = 108;
    pub const SetPixelShaderConstantF: usize = 109;
    pub const GetPixelShaderConstantF: usize = 110;
};

// =============================================================================
// D3D9 present parameters (for dummy device creation)
// =============================================================================

pub const D3DPRESENT_PARAMETERS = extern struct {
    BackBufferWidth: u32 = 0,
    BackBufferHeight: u32 = 0,
    BackBufferFormat: u32 = 0,
    BackBufferCount: u32 = 0,
    MultiSampleType: u32 = 0,
    MultiSampleQuality: u32 = 0,
    SwapEffect: u32 = 0,
    hDeviceWindow: u32 = 0,
    Windowed: u32 = 0,
    EnableAutoDepthStencil: u32 = 0,
    AutoDepthStencilFormat: u32 = 0,
    Flags: u32 = 0,
    FullScreen_RefreshRateInHz: u32 = 0,
    PresentationInterval: u32 = 0,
};

// =============================================================================
// D3D9 viewport
// =============================================================================

pub const D3DVIEWPORT9 = extern struct {
    X: u32 = 0,
    Y: u32 = 0,
    Width: u32 = 0,
    Height: u32 = 0,
    MinZ: f32 = 0,
    MaxZ: f32 = 0,
};

// =============================================================================
// D3D9 surface desc (subset)
// =============================================================================

pub const D3DSURFACE_DESC = extern struct {
    Format: u32 = 0,
    Type: u32 = 0,
    Usage: u32 = 0,
    Pool: u32 = 0,
    MultiSampleType: u32 = 0,
    MultiSampleQuality: u32 = 0,
    Width: u32 = 0,
    Height: u32 = 0,
};

// =============================================================================
// Windows structures for dummy device creation
// =============================================================================

pub const WndProc = *const fn (?*anyopaque, u32, usize, usize) callconv(WINAPI) usize;

pub const WNDCLASSEXA = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXA),
    style: u32 = 0,
    lpfnWndProc: ?WndProc = null,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u8 = null,
    lpszClassName: ?[*:0]const u8 = null,
    hIconSm: ?*anyopaque = null,
};

const WINAPI = std.builtin.CallingConvention.winapi;
