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
const inflate_hook = @import("inflate_hook.zig");

pub const module_name: [*:0]const u8 = "performance";

// Provide malloc/free for libdeflate's default allocator (linked without libc).
// Use game's Storm memory manager:
//   ReallocMemory (0x646320): __stdcall(ptr, size, filename, line, flags) → ptr
//     When ptr=NULL, acts as malloc via AllocateBufferWithPowerOfTwo.
//   FreeMemory (0x646430): __stdcall(ptr, filename, line) → always returns 1
const gameRealloc: *const fn (u32, u32, u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) ?*anyopaque = @ptrFromInt(0x646320);
const gameFree: *const fn (u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) u32 = @ptrFromInt(0x646430);

export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    return gameRealloc(0, @intCast(size), 0, 0, 0);
}

export fn free(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| _ = gameFree(@intFromPtr(p), 0, 0);
}

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

var frame_counter: u32 = 0;

fn worldUpdateDetour(frame_count: u32) callconv(hook.cc.fastcall) void {
    resetParticleCache();
    world_update_hook.callOriginal(.{frame_count});
    // Dump inflate stats every ~450 frames (~7.5s at 60fps)
    frame_counter +|= 1;
    if (frame_counter >= 450) {
        inflate_hook.dumpStats();
        frame_counter = 0;
    }
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
// Silicon SSE JMP patches — binary patches at game function addresses
// =============================================================================

const sse = struct {
    extern fn si_normalizeVec3() callconv(.naked) void;
    extern fn si_mulMat3x4(u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    extern fn si_rotateMatByQuat(u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_createRotMat3x4(u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    extern fn si_classifyPointFrustum(u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_checkBoxLineIntersect(u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    extern fn si_testOBBFrustum(u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_testSphereFrustum(u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_quatSlerp(u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    extern fn si_calculateSinCos(u32, u32, u32) callconv(.{ .x86_stdcall = .{} }) void;
    extern fn si_createZRotMat3x3(u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_transposeMat4x4() callconv(.naked) void;
    extern fn si_mulMat3x4InPlace(u32, u32) callconv(.{ .x86_thiscall = .{} }) u32;
    extern fn si_normalizeVec3InPlace(u32) callconv(.{ .x86_thiscall = .{} }) void;
    extern fn si_addVec3ToAccumulator(u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
    extern fn si_addToColorAccumulator() callconv(.naked) void;
    extern fn si_packParticleColor(u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
    extern fn si_setParticleAlpha() callconv(.naked) void;
    extern fn si_ftol() callconv(.naked) void;
    extern fn si_translateBoundingVol(u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
    extern fn si_processLinkedListCollision(u32, u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
    extern fn si_frustumCullBBox(u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) u32;
};

const PatchEntry = struct {
    target: u32,
    replacement: u32,
    name: [*:0]const u8,
    direct_size: u8 = 0,
};

fn patchJmp(target: u32, replacement: u32) void {
    const rel = @as(i32, @bitCast(replacement -% target -% 5));
    var patch = [5]u8{ 0xE9, 0, 0, 0, 0 };
    @as(*align(1) i32, @ptrCast(patch[1..5])).* = rel;
    hook.writeProtected(target, &patch);
}

fn patchDirect(target: u32, src: [*]const u8, size: usize) void {
    hook.writeProtected(target, src[0..size]);
}

fn installPatches() u32 {
    const patches = [_]PatchEntry{
        .{ .target = 0x4549C0, .replacement = @intFromPtr(&sse.si_normalizeVec3), .name = "normalizeVec3" },
        .{ .target = 0x7BAE60, .replacement = @intFromPtr(&sse.si_mulMat3x4), .name = "mulMat3x4" },
        .{ .target = 0x7BDDB0, .replacement = @intFromPtr(&sse.si_rotateMatByQuat), .name = "rotateMatByQuat" },
        .{ .target = 0x7BB860, .replacement = @intFromPtr(&sse.si_createRotMat3x4), .name = "createRotMat3x4" },
        .{ .target = 0x686C20, .replacement = @intFromPtr(&sse.si_classifyPointFrustum), .name = "classifyPointFrustum" },
        .{ .target = 0x6DC5A0, .replacement = @intFromPtr(&sse.si_checkBoxLineIntersect), .name = "checkBoxLineIntersect" },
        .{ .target = 0x6869C0, .replacement = @intFromPtr(&sse.si_testOBBFrustum), .name = "testOBBFrustum" },
        .{ .target = 0x686B80, .replacement = @intFromPtr(&sse.si_testSphereFrustum), .name = "testSphereFrustum" },
        .{ .target = 0x7C0570, .replacement = @intFromPtr(&sse.si_quatSlerp), .name = "quatSlerp" },
        .{ .target = 0x749280, .replacement = @intFromPtr(&sse.si_calculateSinCos), .name = "calculateSinCos" },
        .{ .target = 0x7BE5B0, .replacement = @intFromPtr(&sse.si_createZRotMat3x3), .name = "createZRotMat3x3" },
        .{ .target = 0x7BCEF0, .replacement = @intFromPtr(&sse.si_transposeMat4x4), .name = "transposeMat4x4", .direct_size = 64 },
        .{ .target = 0x7BB420, .replacement = @intFromPtr(&sse.si_mulMat3x4InPlace), .name = "mulMat3x4InPlace" },
        .{ .target = 0x6720F0, .replacement = @intFromPtr(&sse.si_normalizeVec3InPlace), .name = "normalizeVec3InPlace" },
        .{ .target = 0x71BC70, .replacement = @intFromPtr(&sse.si_addVec3ToAccumulator), .name = "addVec3ToAccumulator" },
        .{ .target = 0x71BF60, .replacement = @intFromPtr(&sse.si_addToColorAccumulator), .name = "addToColorAccumulator" },
        .{ .target = 0x7B7A80, .replacement = @intFromPtr(&sse.si_packParticleColor), .name = "packParticleColor" },
        .{ .target = 0x7B7B10, .replacement = @intFromPtr(&sse.si_setParticleAlpha), .name = "setParticleAlpha" },
        .{ .target = 0x40A2B0, .replacement = @intFromPtr(&sse.si_ftol), .name = "__ftol", .direct_size = 9 },
        .{ .target = 0x686820, .replacement = @intFromPtr(&sse.si_translateBoundingVol), .name = "translateBoundingVol" },
        .{ .target = 0x6ABC40, .replacement = @intFromPtr(&sse.si_processLinkedListCollision), .name = "processLinkedListCollision" },
        .{ .target = 0x686000, .replacement = @intFromPtr(&sse.si_frustumCullBBox), .name = "frustumCullBBox" },
    };

    var count: u32 = 0;
    for (patches) |p| {
        if (p.direct_size > 0) {
            patchDirect(p.target, @ptrFromInt(p.replacement), p.direct_size);
        } else {
            patchJmp(p.target, p.replacement);
        }
        count += 1;
    }
    return count;
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

    // Silicon SSE binary patches
    const patched = installPatches();

    // libdeflate inflate comparison hook
    if (inflate_hook.install(log)) installed += 1;

    log.fmt("performance: {d} hooks, {d} patches installed\n", .{ installed, patched });
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        inflate_hook.dumpStats();
        inflate_hook.remove();
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
