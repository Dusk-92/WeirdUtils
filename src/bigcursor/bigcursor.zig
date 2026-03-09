//! Big cursor module.
//!
//! Hooks IDirect3DDevice9::SetCursorProperties to upscale the hardware cursor
//! using the hqx pixel-art scaling algorithm, then sets an enlarged Win32 cursor
//! via CreateIconIndirect (bypassing D3D9's 32x32 limit).
//!
//! Supports fractional scales (e.g. 1.5x): hqx to next integer, then bilinear
//! downsample to exact target size.

const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");
const mod_mutex = @import("../mutex.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };

pub const module_name: [*:0]const u8 = "bigcursor";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

// =============================================================================
// File logging (survives crashes — console closes too fast)
// =============================================================================

extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, template: ?*anyopaque) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn WriteFile(handle: *anyopaque, buf: [*]const u8, len: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn FlushFileBuffers(handle: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(WINAPI) i32;

const INVALID_HANDLE: usize = 0xFFFFFFFF;
var g_logfile: ?*anyopaque = null;

fn logInit() void {
    const h = CreateFileA("bigcursor_debug.log", 0x40000000, 1, null, 2, 0x80, null); // GENERIC_WRITE, FILE_SHARE_READ, CREATE_ALWAYS, NORMAL
    if (h) |handle| {
        if (@intFromPtr(handle) != INVALID_HANDLE) {
            g_logfile = handle;
        }
    }
}

fn logDeinit() void {
    if (g_logfile) |h| {
        _ = CloseHandle(h);
        g_logfile = null;
    }
}

fn log(msg: []const u8) void {
    con.print(msg);
    if (g_logfile) |h| {
        _ = WriteFile(h, msg.ptr, @intCast(msg.len), null, null);
        _ = FlushFileBuffers(h);
    }
}

fn logFmt(comptime f: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, f, args) catch return;
    log(msg);
}

// =============================================================================
// Scale2x — edge-aware pixel-art 2x upscaler (EPX/AdvMAME2x)
//
// For each pixel P with neighbors A(up) B(right) C(left) D(down):
//   E0 = (C==A && C!=D && A!=B) ? A : P    E1 = (A==B && A!=C && B!=D) ? B : P
//   E2 = (D==C && D!=B && C!=A) ? C : P    E3 = (B==D && B!=A && D!=C) ? D : P
// =============================================================================

fn scale2x(src: [*]const u32, src_w: u32, src_h: u32, dst: [*]u32, dst_w: u32) void {
    for (0..src_h) |jj| {
        const j: u32 = @intCast(jj);
        for (0..src_w) |ii| {
            const i: u32 = @intCast(ii);
            const p = src[j * src_w + i];
            const a = if (j > 0) src[(j - 1) * src_w + i] else p;
            const b = if (i < src_w - 1) src[j * src_w + i + 1] else p;
            const c = if (i > 0) src[j * src_w + i - 1] else p;
            const d = if (j < src_h - 1) src[(j + 1) * src_w + i] else p;

            const oy = j * 2;
            const ox = i * 2;
            dst[oy * dst_w + ox] = if (c == a and c != d and a != b) a else p;
            dst[oy * dst_w + ox + 1] = if (a == b and a != c and b != d) b else p;
            dst[(oy + 1) * dst_w + ox] = if (d == c and d != b and c != a) c else p;
            dst[(oy + 1) * dst_w + ox + 1] = if (b == d and b != a and d != c) d else p;
        }
    }
}

// =============================================================================
// Scale3x — edge-aware pixel-art 3x upscaler (AdvMAME3x)
//
// Neighbors: A(up) B(right) C(left) D(down) + diagonals
// Uses same edge detection as Scale2x, extended to 3x3 output block.
// =============================================================================

fn scale3x(src: [*]const u32, src_w: u32, src_h: u32, dst: [*]u32, dst_w: u32) void {
    for (0..src_h) |jj| {
        const j: u32 = @intCast(jj);
        for (0..src_w) |ii| {
            const i: u32 = @intCast(ii);
            const idx = j * src_w + i;
            const e = src[idx]; // center pixel (P)
            const b = if (j > 0) src[idx - src_w] else e; // up
            const h = if (j < src_h - 1) src[idx + src_w] else e; // down
            const d = if (i > 0) src[idx - 1] else e; // left
            const f = if (i < src_w - 1) src[idx + 1] else e; // right
            const a = if (j > 0 and i > 0) src[idx - src_w - 1] else e;
            const c = if (j > 0 and i < src_w - 1) src[idx - src_w + 1] else e;
            const g = if (j < src_h - 1 and i > 0) src[idx + src_w - 1] else e;
            const ii_ = if (j < src_h - 1 and i < src_w - 1) src[idx + src_w + 1] else e;

            const oy = j * 3;
            const ox = i * 3;

            if (b != h and d != f) {
                dst[oy * dst_w + ox] = if (d == b) d else e;
                dst[oy * dst_w + ox + 1] = if (d == b and e != c or b == f and e != a) b else e;
                dst[oy * dst_w + ox + 2] = if (b == f) f else e;
                dst[(oy + 1) * dst_w + ox] = if (d == b and e != g or d == h and e != a) d else e;
                dst[(oy + 1) * dst_w + ox + 1] = e;
                dst[(oy + 1) * dst_w + ox + 2] = if (b == f and e != ii_ or h == f and e != c) f else e;
                dst[(oy + 2) * dst_w + ox] = if (d == h) d else e;
                dst[(oy + 2) * dst_w + ox + 1] = if (d == h and e != ii_ or h == f and e != g) h else e;
                dst[(oy + 2) * dst_w + ox + 2] = if (h == f) f else e;
            } else {
                dst[oy * dst_w + ox] = e;
                dst[oy * dst_w + ox + 1] = e;
                dst[oy * dst_w + ox + 2] = e;
                dst[(oy + 1) * dst_w + ox] = e;
                dst[(oy + 1) * dst_w + ox + 1] = e;
                dst[(oy + 1) * dst_w + ox + 2] = e;
                dst[(oy + 2) * dst_w + ox] = e;
                dst[(oy + 2) * dst_w + ox + 1] = e;
                dst[(oy + 2) * dst_w + ox + 2] = e;
            }
        }
    }
}

// =============================================================================
// Win32 externs
// =============================================================================

extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new_prot: u32, old_prot: *u32) callconv(WINAPI) i32;

extern "gdi32" fn CreateBitmap(w: i32, h: i32, planes: u32, bpp: u32, bits: ?*const anyopaque) callconv(WINAPI) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(WINAPI) i32;

extern "user32" fn CreateIconIndirect(info: *IconInfo) callconv(WINAPI) ?*anyopaque;
extern "user32" fn DestroyCursor(cursor: *anyopaque) callconv(WINAPI) i32;
extern "user32" fn SetCursor(cursor: ?*anyopaque) callconv(WINAPI) ?*anyopaque;

const IconInfo = extern struct {
    fIcon: i32 = 0,
    xHotspot: u32 = 0,
    yHotspot: u32 = 0,
    hbmMask: ?*anyopaque = null,
    hbmColor: ?*anyopaque = null,
};

// =============================================================================
// WoW CVar API (1.12.1 build 5875)
// =============================================================================

const CVAR_LOOKUP: usize = 0x0063DEC0;

// RegisterCVar: __fastcall(ECX=name, EDX=help, stack: unk1, default, callback, category, unk2, unk3)
const RegisterCVarFn = *const fn ([*:0]const u8, u32, u32, [*:0]const u8, u32, u32, u32, u32) callconv(fc) u32;
const registerCVar: RegisterCVarFn = @ptrFromInt(0x0063DB90);

const CVAR_NAME = "cursorScale";

/// Read CVar integer value (tenths: 15 = 1.5x). Returns f32 scale.
fn readCVarScaleInit() f32 {
    const cvar_ptr = hook.fastcall(u32, CVAR_LOOKUP, @intFromPtr(@as([*:0]const u8, CVAR_NAME)), @as(u32, 0));
    if (cvar_ptr == 0) return g_scale_f;
    // CVar struct: integer value at offset +40 bytes (10 pointer-sized fields)
    const val = hook.readMem(i32, cvar_ptr + 40);
    if (val >= 10 and val <= 40) {
        return @as(f32, @floatFromInt(val)) / 10.0;
    }
    return g_scale_f;
}

// =============================================================================
// D3D9 vtable indices
// =============================================================================

const VT_SetCursorProperties: usize = 10;
const VT_ShowCursor: usize = 12;

// IDirect3DSurface9 vtable
const SVT_GetDesc: usize = 12;
const SVT_LockRect: usize = 13;
const SVT_UnlockRect: usize = 14;

// D3D9 constants
const D3DFMT_A8R8G8B8: u32 = 21;

// Game's GxDevice → IDirect3DDevice9 pointer chain
const GX_DEVICE_PTR: usize = 0xC0ED38;
const GX_DEVICE_D3D_OFFSET: usize = 0x38A8;

// =============================================================================
// COM helpers
// =============================================================================

inline fn vtbl(obj: *anyopaque) [*]usize {
    return @ptrFromInt(hook.readMem(u32, @intFromPtr(obj)));
}

// =============================================================================
// State
// =============================================================================

var d3d9_vtable: ?[*]usize = null;
var orig_set_cursor_props: usize = 0;
var orig_show_cursor: usize = 0;
var hooks_installed: bool = false;

var g_scale_f: f32 = 1.2; // fractional scale (1.0 = off, 1.2 = default, etc.)
var g_hcursor: ?*anyopaque = null; // current enlarged HCURSOR
var g_cursor_visible: bool = false;

// Simple pixel hash cache for ~10 distinct WoW cursor bitmaps.
// Cache key includes scale so changing scale invalidates.
const MAX_CACHE = 16;
const CacheEntry = struct {
    hash: u64 = 0,
    hcursor: ?*anyopaque = null,
    valid: bool = false,
};
var g_cache: [MAX_CACHE]CacheEntry = [_]CacheEntry{.{}} ** MAX_CACHE;
var g_cache_count: u32 = 0;

// =============================================================================
// FNV-1a hash for cursor pixel data (includes scale in hash)
// =============================================================================

fn hashPixels(data: [*]const u8, len: usize, scale_bits: u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    // Mix scale into hash so different scales produce different cache keys
    h ^= scale_bits;
    h *%= 0x100000001b3;
    for (data[0..len]) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

// =============================================================================
// Surface helpers
// =============================================================================

const D3DLOCKED_RECT = extern struct {
    Pitch: i32 = 0,
    pBits: ?[*]u8 = null,
};

const D3DSURFACE_DESC = extern struct {
    Format: u32 = 0,
    Type: u32 = 0,
    Usage: u32 = 0,
    Pool: u32 = 0,
    MultiSampleType: u32 = 0,
    MultiSampleQuality: u32 = 0,
    Width: u32 = 0,
    Height: u32 = 0,
};

fn surfaceGetDesc(surface: *anyopaque, desc: *D3DSURFACE_DESC) i32 {
    const f: *const fn (*anyopaque, *D3DSURFACE_DESC) callconv(sc) i32 = @ptrFromInt(vtbl(surface)[SVT_GetDesc]);
    return f(surface, desc);
}

fn surfaceLockRect(surface: *anyopaque, locked: *D3DLOCKED_RECT, rect: ?*anyopaque, flags: u32) i32 {
    const f: *const fn (*anyopaque, *D3DLOCKED_RECT, ?*anyopaque, u32) callconv(sc) i32 = @ptrFromInt(vtbl(surface)[SVT_LockRect]);
    return f(surface, locked, rect, flags);
}

fn surfaceUnlockRect(surface: *anyopaque) i32 {
    const f: *const fn (*anyopaque) callconv(sc) i32 = @ptrFromInt(vtbl(surface)[SVT_UnlockRect]);
    return f(surface);
}

// =============================================================================
// Bilinear resampler (downsample hqx output to exact target size)
// =============================================================================

fn lerpChannel(a: u32, b: u32, c: u32, d: u32, fx: f32, fy: f32) u8 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    const fc_: f32 = @floatFromInt(c);
    const fd: f32 = @floatFromInt(d);
    const val = fa * (1.0 - fx) * (1.0 - fy) + fb * fx * (1.0 - fy) + fc_ * (1.0 - fx) * fy + fd * fx * fy;
    return @intFromFloat(@min(@max(val, 0.0), 255.0));
}

fn bilinearResample(
    src: [*]const u32,
    src_w: u32,
    src_h: u32,
    dst: [*]u32,
    dst_w: u32,
    dst_h: u32,
) void {
    const sw_f: f32 = @floatFromInt(src_w);
    const sh_f: f32 = @floatFromInt(src_h);
    const dw_f: f32 = @floatFromInt(dst_w);
    const dh_f: f32 = @floatFromInt(dst_h);

    for (0..dst_h) |dy| {
        const sy_f = (@as(f32, @floatFromInt(dy)) + 0.5) * sh_f / dh_f - 0.5;
        const sy_floor = @max(sy_f, 0.0);
        const sy0: u32 = @intFromFloat(sy_floor);
        const sy1 = @min(sy0 + 1, src_h - 1);
        const fy = sy_f - @as(f32, @floatFromInt(sy0));

        for (0..dst_w) |dx| {
            const sx_f = (@as(f32, @floatFromInt(dx)) + 0.5) * sw_f / dw_f - 0.5;
            const sx_floor = @max(sx_f, 0.0);
            const sx0: u32 = @intFromFloat(sx_floor);
            const sx1 = @min(sx0 + 1, src_w - 1);
            const fx = sx_f - @as(f32, @floatFromInt(sx0));

            const c00 = src[sy0 * src_w + sx0];
            const c10 = src[sy0 * src_w + sx1];
            const c01 = src[sy1 * src_w + sx0];
            const c11 = src[sy1 * src_w + sx1];

            const b = lerpChannel(c00 & 0xFF, c10 & 0xFF, c01 & 0xFF, c11 & 0xFF, fx, fy);
            const g = lerpChannel((c00 >> 8) & 0xFF, (c10 >> 8) & 0xFF, (c01 >> 8) & 0xFF, (c11 >> 8) & 0xFF, fx, fy);
            const r = lerpChannel((c00 >> 16) & 0xFF, (c10 >> 16) & 0xFF, (c01 >> 16) & 0xFF, (c11 >> 16) & 0xFF, fx, fy);
            const a = lerpChannel((c00 >> 24) & 0xFF, (c10 >> 24) & 0xFF, (c01 >> 24) & 0xFF, (c11 >> 24) & 0xFF, fx, fy);

            dst[dy * dst_w + dx] = @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
        }
    }
}

// =============================================================================
// Create enlarged Win32 cursor from BGRA pixel data
// =============================================================================

// Static buffers — single-threaded D3D9 calls, no contention.
var s_src_buf: [32 * 32]u32 = undefined;
var s_scaled_buf: [128 * 128]u32 = undefined; // Scale2x/3x output
var s_dst_buf: [128 * 128]u32 = undefined; // final output (after bilinear)
var s_mask_buf: [128 * 128 / 8]u8 = undefined;

fn createEnlargedCursor(
    src_pixels: [*]const u8,
    src_pitch: u32,
    src_w: u32,
    src_h: u32,
    hotspot_x: u32,
    hotspot_y: u32,
    scale_f: f32,
) ?*anyopaque {
    // Compute final target dimensions
    const dst_w: u32 = @intFromFloat(@as(f32, @floatFromInt(src_w)) * scale_f);
    const dst_h: u32 = @intFromFloat(@as(f32, @floatFromInt(src_h)) * scale_f);

    if (dst_w > 128 or dst_h > 128 or dst_w < 1 or dst_h < 1) return null;
    if (src_w > 32 or src_h > 32) return null;

    // Pick smallest scale factor that covers the target: 2x, 3x, or 2x+2x=4x
    const int_factor: u32 = if (scale_f <= 2.0) 2 else if (scale_f <= 3.0) 3 else 4;
    const scaled_w = src_w * int_factor;
    const scaled_h = src_h * int_factor;
    const needs_resample = (dst_w != scaled_w or dst_h != scaled_h);

    // Copy source pixels to contiguous buffer (surface pitch may differ from width*4)
    const src_row_bytes = src_w * 4;
    for (0..src_h) |y| {
        const src_row = src_pixels + y * src_pitch;
        const dst_row: [*]u8 = @ptrCast(&s_src_buf[y * src_w]);
        @memcpy(dst_row[0..src_row_bytes], src_row[0..src_row_bytes]);
    }

    // Run edge-aware pixel-art upscaler
    switch (int_factor) {
        2 => scale2x(&s_src_buf, src_w, src_h, &s_scaled_buf, scaled_w),
        3 => scale3x(&s_src_buf, src_w, src_h, &s_scaled_buf, scaled_w),
        4 => {
            // 4x = two passes of Scale2x
            scale2x(&s_src_buf, src_w, src_h, &s_dst_buf, src_w * 2);
            scale2x(&s_dst_buf, src_w * 2, src_h * 2, &s_scaled_buf, scaled_w);
        },
        else => return null,
    }

    // Bilinear resample to exact target size if needed
    const final_pixels: [*]u32 = if (needs_resample) blk: {
        bilinearResample(&s_scaled_buf, scaled_w, scaled_h, &s_dst_buf, dst_w, dst_h);
        break :blk &s_dst_buf;
    } else &s_scaled_buf;

    // Create Win32 cursor via CreateIconIndirect
    const mask_bytes = dst_w * dst_h / 8;
    @memset(s_mask_buf[0..mask_bytes], 0xFF);

    const hbm_mask = CreateBitmap(@intCast(dst_w), @intCast(dst_h), 1, 1, &s_mask_buf) orelse return null;
    const hbm_color = CreateBitmap(@intCast(dst_w), @intCast(dst_h), 1, 32, final_pixels) orelse {
        _ = DeleteObject(hbm_mask);
        return null;
    };

    const hot_x: u32 = @intFromFloat(@as(f32, @floatFromInt(hotspot_x)) * scale_f);
    const hot_y: u32 = @intFromFloat(@as(f32, @floatFromInt(hotspot_y)) * scale_f);
    var info = IconInfo{
        .fIcon = 0,
        .xHotspot = hot_x,
        .yHotspot = hot_y,
        .hbmMask = hbm_mask,
        .hbmColor = hbm_color,
    };

    const hcursor = CreateIconIndirect(&info);

    _ = DeleteObject(hbm_mask);
    _ = DeleteObject(hbm_color);

    return hcursor;
}

// =============================================================================
// Cache management
// =============================================================================

fn cacheLookup(pixel_hash: u64) ?*anyopaque {
    for (&g_cache) |*entry| {
        if (entry.valid and entry.hash == pixel_hash)
            return entry.hcursor;
    }
    return null;
}

fn cacheInsert(pixel_hash: u64, hcursor: *anyopaque) void {
    var idx: u32 = g_cache_count;
    if (idx >= MAX_CACHE) {
        if (g_cache[0].hcursor) |old| _ = DestroyCursor(old);
        for (0..MAX_CACHE - 1) |i| g_cache[i] = g_cache[i + 1];
        idx = MAX_CACHE - 1;
    } else {
        g_cache_count += 1;
    }
    g_cache[idx] = .{ .hash = pixel_hash, .hcursor = hcursor, .valid = true };
}

fn cacheClear() void {
    for (&g_cache) |*entry| {
        if (entry.hcursor) |old| _ = DestroyCursor(old);
        entry.* = .{};
    }
    g_cache_count = 0;
}

// =============================================================================
// Hook: IDirect3DDevice9::SetCursorProperties (VT slot 10)
// =============================================================================

fn hkSetCursorProperties(device: *anyopaque, x_hotspot: u32, y_hotspot: u32, cursor_surface: *anyopaque) callconv(sc) i32 {
    const origFn: *const fn (*anyopaque, u32, u32, *anyopaque) callconv(sc) i32 =
        @ptrFromInt(orig_set_cursor_props);

    if (g_scale_f <= 1.0) return origFn(device, x_hotspot, y_hotspot, cursor_surface);

    // Get surface dimensions and format
    var desc: D3DSURFACE_DESC = .{};
    const hr_desc = surfaceGetDesc(cursor_surface, &desc);
    if (hr_desc < 0) return origFn(device, x_hotspot, y_hotspot, cursor_surface);

    if (desc.Format != D3DFMT_A8R8G8B8 or desc.Width > 32 or desc.Height > 32) {
        return origFn(device, x_hotspot, y_hotspot, cursor_surface);
    }

    // Lock source surface to read pixels
    var locked: D3DLOCKED_RECT = .{};
    const hr_lock = surfaceLockRect(cursor_surface, &locked, null, 0x10);
    if (hr_lock < 0) return origFn(device, x_hotspot, y_hotspot, cursor_surface);

    const bits = locked.pBits orelse {
        _ = surfaceUnlockRect(cursor_surface);
        return origFn(device, x_hotspot, y_hotspot, cursor_surface);
    };
    const pitch: u32 = if (locked.Pitch > 0) @intCast(locked.Pitch) else {
        _ = surfaceUnlockRect(cursor_surface);
        return origFn(device, x_hotspot, y_hotspot, cursor_surface);
    };

    // Hash pixel data + scale for cache key
    const data_size = pitch * desc.Height;
    const scale_bits: u32 = @bitCast(g_scale_f);
    const pixel_hash = hashPixels(bits, data_size, scale_bits);

    // Check cache
    if (cacheLookup(pixel_hash)) |cached_cursor| {
        _ = surfaceUnlockRect(cursor_surface);
        g_hcursor = cached_cursor;
        const result = origFn(device, x_hotspot, y_hotspot, cursor_surface);
        if (g_cursor_visible) _ = SetCursor(g_hcursor);
        return result;
    }

    // Run hqx upscale + bilinear downsample
    if (createEnlargedCursor(bits, pitch, desc.Width, desc.Height, x_hotspot, y_hotspot, g_scale_f)) |new_cursor| {
        cacheInsert(pixel_hash, new_cursor);
        g_hcursor = new_cursor;
    }

    _ = surfaceUnlockRect(cursor_surface);

    const result = origFn(device, x_hotspot, y_hotspot, cursor_surface);

    if (g_hcursor != null and g_cursor_visible) {
        _ = SetCursor(g_hcursor);
    }

    return result;
}

// =============================================================================
// Hook: IDirect3DDevice9::ShowCursor (VT slot 12)
// =============================================================================

fn hkShowCursor(device: *anyopaque, bShow: i32) callconv(sc) i32 {
    const origFn: *const fn (*anyopaque, i32) callconv(sc) i32 =
        @ptrFromInt(orig_show_cursor);

    g_cursor_visible = bShow != 0;

    if (g_hcursor != null and g_scale_f > 1.0) {
        // Hide D3D9's 32x32 hardware cursor — we use a Win32 cursor instead
        _ = origFn(device, 0);
        if (g_cursor_visible) {
            _ = SetCursor(g_hcursor);
        } else {
            _ = SetCursor(null);
        }
        return if (g_cursor_visible) 1 else 0;
    }

    return origFn(device, bShow);
}

// =============================================================================
// Lua API: SetCursorScale(n) / GetCursorScale()
// =============================================================================

fn luaPushNumber(L_ptr: usize, n: f64) void {
    hook.call(fn (usize, f64) callconv(tc) void, 0x6F3810, .{ L_ptr, n });
}

pub fn luaSetCursorScale(L: *anyopaque) callconv(.c) u32 {
    const L_ptr = @intFromPtr(L);
    const nargs = hook.fastcall(i32, 0x6F3070, L_ptr, @as(u32, 0)); // lua_gettop
    if (nargs < 1) return 0;

    const val: f32 = @floatCast(hook.fastcall(f64, 0x6F3620, L_ptr, @as(i32, 1))); // lua_tonumber
    if (val < 1.0 or val > 4.0) return 0;

    if (val != g_scale_f) {
        g_scale_f = val;
        cacheClear();
        g_hcursor = null;
        logFmt("[bigcursor] scale set to {d:.2}\n", .{g_scale_f});
    }
    return 0;
}

pub fn luaGetCursorScale(L: *anyopaque) callconv(.c) u32 {
    luaPushNumber(@intFromPtr(L), @floatCast(g_scale_f));
    return 1;
}

// =============================================================================
// Vtable patching
// =============================================================================

fn patchVtableEntry(vtable_ptr: [*]usize, idx: usize, new_fn: usize, old_fn: *usize) bool {
    old_fn.* = vtable_ptr[idx];
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0) return false;
    vtable_ptr[idx] = new_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
    return true;
}

fn restoreVtableEntry(vtable_ptr: [*]usize, idx: usize, old_fn: usize) void {
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0) return;
    vtable_ptr[idx] = old_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
}

fn getD3D9VTable() ?[*]usize {
    const gx_device = hook.readMem(u32, GX_DEVICE_PTR);
    if (gx_device == 0) return null;
    const d3d_device = hook.readMem(u32, gx_device + GX_DEVICE_D3D_OFFSET);
    if (d3d_device == 0) return null;
    const vtable_addr = hook.readMem(u32, d3d_device);
    if (vtable_addr == 0) return null;
    return @ptrFromInt(vtable_addr);
}

// =============================================================================
// Late init (called from engineInitDetour when D3D9 device exists)
// =============================================================================

pub fn lateInit() void {
    if (!g_is_hook_owner) return;
    if (hooks_installed) return;

    const vt = getD3D9VTable() orelse {
        con.print("[bigcursor] D3D9 device not available yet\n");
        return;
    };
    d3d9_vtable = vt;

    if (!patchVtableEntry(vt, VT_SetCursorProperties, @intFromPtr(&hkSetCursorProperties), &orig_set_cursor_props)) {
        con.print("[bigcursor] failed to hook SetCursorProperties\n");
        return;
    }
    if (!patchVtableEntry(vt, VT_ShowCursor, @intFromPtr(&hkShowCursor), &orig_show_cursor)) {
        con.print("[bigcursor] failed to hook ShowCursor\n");
        restoreVtableEntry(vt, VT_SetCursorProperties, orig_set_cursor_props);
        return;
    }

    hooks_installed = true;

    // Register CVar for persistence (tenths: 15 = 1.5x, 20 = 2.0x)
    _ = registerCVar(CVAR_NAME, 0, 0, "12", 0, 1, 0, 0);
    g_scale_f = readCVarScaleInit();
    logFmt("[bigcursor] D3D9 hooks installed (scale={d:.1}x)\n", .{g_scale_f});
}

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    logInit();
    log("[bigcursor] Module loaded\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
}

pub fn removeHooks() void {
    if (hooks_installed) {
        if (d3d9_vtable) |vt| {
            if (orig_show_cursor != 0) restoreVtableEntry(vt, VT_ShowCursor, orig_show_cursor);
            if (orig_set_cursor_props != 0) restoreVtableEntry(vt, VT_SetCursorProperties, orig_set_cursor_props);
        }
        hooks_installed = false;
    }

    cacheClear();
    g_hcursor = null;

    if (g_is_hook_owner) {
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
    logDeinit();
}
