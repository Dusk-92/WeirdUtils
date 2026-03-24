//! performance — production SSE replacements with zero profiling overhead.
//!
//! Consolidates all verified permanent optimizations from transform44 and silicon
//! into a single clean module. No rdtsc, no A/B testing, no probe counters.
//!
//! Hooks:
//!   - transformMatrix4x4 (bone SSE, 0x714260)
//!   - RenderParticleSprites (particle SSE, 0x7B2A50)
//!   - GetOrCreateCharacterGlyph (glyph cache, 0x5CA2D0)
//!   - OnWorldUpdate (0x482EA0) — per-frame cache reset
//!
//! JMP patches (via silicon patch table):
//!   - All silicon_sse functions (frustumCull, processLinkedListCollision, ftol, etc.)
//!   are installed by the silicon module — not duplicated here.

const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "performance";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Extern SSE functions (from separate ReleaseFast compilation units)
// =============================================================================

extern fn transformImpl_SSE(u32, u32, u32, u32, u32) callconv(.c) void;
extern fn renderParticleSprites_SSE(u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
extern fn resetParticleCache() void;

// =============================================================================
// transformMatrix4x4 hook (0x714260)
// =============================================================================

fn transformMatrix4x4_SSE(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
    transformImpl_SSE(this, mat1, mat2, mat3, mat4);
}

const TransformFn = fn (u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
var transform_hook: hook.Detour(TransformFn) = .{};
var teardown_active: bool = false;

fn transformDetour(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
    if (teardown_active) {
        transform_hook.callOriginal(.{ this, mat1, mat2, mat3, mat4 });
    } else {
        transformMatrix4x4_SSE(this, mat1, mat2, mat3, mat4);
    }
}

// =============================================================================
// RenderParticleSprites hook (0x7B2A50)
// =============================================================================

const ParticleFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var particle_hook: hook.Detour(ParticleFn) = .{};

fn particleDetour(a: u32, _: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    return @ptrFromInt(renderParticleSprites_SSE(a, c, d));
}

// =============================================================================
// GetOrCreateCharacterGlyph cache (0x5CA2D0)
// =============================================================================

const GLYPH_CACHE_SHIFT = 12;
const GLYPH_CACHE_SIZE = 1 << GLYPH_CACHE_SHIFT;
const GLYPH_CACHE_MASK = GLYPH_CACHE_SIZE - 1;

const GlyphCacheEntry = struct {
    font_ptr: u32 = 0,
    char_code: u32 = 0,
    param2: u32 = 0,
    width_bits: u32 = 0,
};

var glyph_cache: [GLYPH_CACHE_SIZE]GlyphCacheEntry = [_]GlyphCacheEntry{.{}} ** GLYPH_CACHE_SIZE;

const GlyphFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var glyph_hook: hook.Detour(GlyphFn) = .{};

fn glyphDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const hash = ((a ^ c *% 0x9E3779B9) ^ d) & GLYPH_CACHE_MASK;
    const entry = &glyph_cache[hash];

    if (entry.font_ptr == a and entry.char_code == c and entry.param2 == d) {
        asm volatile ("flds (%[p])"
            :: [p] "r" (&entry.width_bits)
        );
        return null;
    }

    const ret = glyph_hook.callOriginal(.{ a, b, c, d });

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

    return ret;
}

// =============================================================================
// OnWorldUpdate hook (0x482EA0) — per-frame cache reset
// =============================================================================

const WorldUpdateFn = fn (u32) callconv(hook.cc.fastcall) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

fn worldUpdateDetour(frame_count: u32) callconv(hook.cc.fastcall) void {
    resetParticleCache();
    world_update_hook.callOriginal(.{frame_count});
}

// =============================================================================
// Teardown hook (0x491180) — protect bone SSE during logout cleanup
// =============================================================================

const TeardownFn = fn () callconv(.{ .x86_stdcall = .{} }) void;
var teardown_hook: hook.Detour(TeardownFn) = .{};

fn teardownDetour() callconv(.{ .x86_stdcall = .{} }) void {
    teardown_active = true;
    teardown_hook.callOriginal(.{});
    teardown_active = false;
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    var installed: u32 = 0;

    // Bone transform SSE
    if (transform_hook.attach(0x714260, &transformDetour) == .ok) installed += 1;

    // Particle rendering SSE
    if (particle_hook.attach(0x7B2A50, &particleDetour) == .ok) installed += 1;

    // Glyph cache
    if (glyph_hook.attach(0x5CA2D0, &glyphDetour) == .ok) installed += 1;

    // Per-frame cache reset
    if (world_update_hook.attach(0x482EA0, &worldUpdateDetour) == .ok) installed += 1;

    // Teardown guard
    if (teardown_hook.attach(0x491180, &teardownDetour) == .ok) installed += 1;

    log.fmt("performance: {d} hooks installed\n", .{installed});
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        transform_hook.detach();
        particle_hook.detach();
        glyph_hook.detach();
        world_update_hook.detach();
        teardown_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
