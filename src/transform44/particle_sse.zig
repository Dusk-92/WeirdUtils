//! particle_sse — SSE replacements for WoW 1.12.1 particle rendering pipeline.
//!
//! Compiled as a separate ReleaseFast unit (same pattern as bone_sse.zig / clip_sse.zig).
//! Functions are exported and called via `extern fn` from transform44.zig detour hooks.
//!
//! Assembly references: decompiled/asm_RenderParticleSprites.txt,
//!   asm_calculateColorValues.txt, asm_SetupParticleRendering.txt

const V4 = @Vector(4, f32);
const V4i = @Vector(4, i32);

inline fn rf32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}

inline fn ri32(addr: u32) i32 {
    return @as(*align(1) const i32, @ptrFromInt(addr)).*;
}

inline fn ru8(addr: u32) u8 {
    return @as(*const u8, @ptrFromInt(addr)).*;
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
// calculateColorValues (0x7B9B10)
// =============================================================================
//
// __thiscall(ECX=colorCtx, stack: time, scale, outColor, outAlpha1, outAlpha2, outFloat)
// RET 0x18 (6 stack params)
//
// ColorCtx layout:
//   +0x00..0x03: base color bytes [B, G, R, A] (4 bytes)
//   +0x04: delta_alpha (i32)
//   +0x08: delta_red (i32)
//   +0x0C: delta_green (i32)
//   +0x10: delta_blue (i32)
//   +0x14: alpha1_base (i32)
//   +0x18: alpha1_delta (i32)
//   +0x1C: alpha2_base (i32)
//   +0x20: alpha2_delta (i32)
//   +0x24: float_base (f32)
//   +0x28: float_scale (f32)
//   +0x2C: time_base (f32)
//   +0x30: time_scale (f32)
//   +0x50: alpha_power (f32, 1.0 = linear, else calls pow)
//
// Algorithm:
//   t = (time - ctx.timeBase) * ctx.timeScale * CONST1 + CONST2
//   For each color channel (A,R,G,B):
//     val = (float)delta * t + (float)base_byte
//     alpha channel only: val *= scale
//     val += MAGIC   (float-to-byte trick constant at 0x8029CC)
//     outColor[ch] = (byte)(float_bits >> 14)
//   outFloat = t * ctx.floatScale + ctx.floatBase
//   For alpha outputs:
//     if ctx.alphaPower == 1.0: linear interp
//     else: pow(t * alphaPower, ...) path
//
// The "float bits >> 14" is a classic fast float-to-byte: add a large power-of-2
// magic number so the integer value sits in the mantissa bits, then extract.
// =============================================================================

const CC = std.builtin.CallingConvention;
const TC: CC = .{ .x86_thiscall = .{} };

const std = @import("std");

/// SSE replacement for calculateColorValues.
/// Thiscall: ECX=ctx, stack params: time(f32), scale(f32), outColor(ptr), outAlpha1(ptr), outAlpha2(ptr), outFloat(ptr)
export fn calcColorValues_SSE(
    ctx: u32,
    time_bits: u32,
    scale_bits: u32,
    out_color: u32,
    out_alpha1: u32,
    out_alpha2: u32,
    out_float: u32,
) callconv(TC) void {
    const time: f32 = @bitCast(time_bits);
    const scale: f32 = @bitCast(scale_bits);

    // Step 1: Compute interpolation parameter t
    const t = (time - rf32(ctx + 0x2C)) * rf32(ctx + 0x30) * rf32(0x808AAC) + rf32(0x807A3C);

    // Step 2: Compute 4 color channels
    // Load base bytes and deltas
    const base_a: f32 = @floatFromInt(@as(i32, ru8(ctx + 3)));
    const base_r: f32 = @floatFromInt(@as(i32, ru8(ctx + 2)));
    const base_g: f32 = @floatFromInt(@as(i32, ru8(ctx + 1)));
    const base_b: f32 = @floatFromInt(@as(i32, ru8(ctx + 0)));

    const delta_a: f32 = @floatFromInt(ri32(ctx + 0x04));
    const delta_r: f32 = @floatFromInt(ri32(ctx + 0x08));
    const delta_g: f32 = @floatFromInt(ri32(ctx + 0x0C));
    const delta_b: f32 = @floatFromInt(ri32(ctx + 0x10));

    const magic: f32 = rf32(0x8029CC);

    // Alpha channel: (delta * t + base) * scale + magic
    const alpha_f = @mulAdd(f32, delta_a, t, base_a) * scale + magic;
    // RGB channels: delta * t + base + magic (no scale)
    const red_f = @mulAdd(f32, delta_r, t, base_r) + magic;
    const green_f = @mulAdd(f32, delta_g, t, base_g) + magic;
    const blue_f = @mulAdd(f32, delta_b, t, base_b) + magic;

    // Extract bytes via float-bits >> 14 trick
    const alpha_byte: u8 = @truncate(@as(u32, @bitCast(alpha_f)) >> 14);
    const red_byte: u8 = @truncate(@as(u32, @bitCast(red_f)) >> 14);
    const green_byte: u8 = @truncate(@as(u32, @bitCast(green_f)) >> 14);
    const blue_byte: u8 = @truncate(@as(u32, @bitCast(blue_f)) >> 14);

    // Store color bytes: [B, G, R, A] at outColor
    wu8(out_color + 0, blue_byte);
    wu8(out_color + 1, green_byte);
    wu8(out_color + 2, red_byte);
    wu8(out_color + 3, alpha_byte);

    // Step 3: Float output = t * ctx.floatScale + ctx.floatBase
    wf32(out_float, @mulAdd(f32, t, rf32(ctx + 0x28), rf32(ctx + 0x24)));

    // Step 4: Alpha outputs
    const alpha_power = ru32(ctx + 0x50);
    if (alpha_power == 0x3F800000) {
        // Fast path: alphaPower == 1.0 (linear)
        const a1_val = @mulAdd(f32, @as(f32, @floatFromInt(ri32(ctx + 0x18))), t, @as(f32, @floatFromInt(ri32(ctx + 0x14)))) + magic;
        const a2_val = @mulAdd(f32, @as(f32, @floatFromInt(ri32(ctx + 0x20))), t, @as(f32, @floatFromInt(ri32(ctx + 0x1C)))) + magic;

        wu32(out_alpha1, (@as(u32, @bitCast(a1_val)) >> 14) & 0xFF);
        wu32(out_alpha2, (@as(u32, @bitCast(a2_val)) >> 14) & 0xFF);
    } else {
        // Slow path: pow scaling. Call game's pow function.
        // 0x73F90A: __cdecl pow — takes ST(0)=base, ST(1)=exponent, returns ST(0)
        // t_scaled = pow(t * alphaPower, ???)
        // For now, fall back to scalar computation matching the original exactly.
        const ap: f32 = @bitCast(alpha_power);
        const t_scaled = t * ap;

        // The original calls 0x73F90A with ST(0)=t_scaled, ST(1)=loaded from [0x8015B8] (qword)
        // This is __CIpow (MSVC intrinsic pow) — ST(1)=exponent (from 0x8015B8), ST(0)=base
        // We need the exponent constant. For now use @exp2/@log2 to compute pow.
        // Actually: the original loads FLD qword [0x8015B8] THEN calls __CIpow.
        // __CIpow expects ST(0)=x, ST(1)=y, computes x^y. So: pow(t_scaled, const_at_8015B8).
        // The constant at 0x8015B8 is a f64. We read it and use std.math.pow.
        const exp_val: f64 = @as(*align(1) const f64, @ptrFromInt(0x8015B8)).*;
        const t_pow: f32 = @floatCast(std.math.pow(f64, @as(f64, t_scaled), exp_val));

        const a1_delta: f32 = @floatFromInt(ri32(ctx + 0x18));
        const a1_base: f32 = @floatFromInt(ri32(ctx + 0x14));
        const a1_val = @mulAdd(f32, a1_delta, t_pow, a1_base) + magic;

        const a2_delta: f32 = @floatFromInt(ri32(ctx + 0x20));
        const a2_base: f32 = @floatFromInt(ri32(ctx + 0x1C));
        const a2_val = @mulAdd(f32, a2_delta, t_pow, a2_base) + magic;

        wu32(out_alpha1, (@as(u32, @bitCast(a1_val)) >> 14) & 0xFF);
        wu32(out_alpha2, (@as(u32, @bitCast(a2_val)) >> 14) & 0xFF);
    }
}
