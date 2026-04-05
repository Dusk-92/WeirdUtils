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
const timer_fix = @import("timer_fix.zig");
const filecache = @import("filecache.zig");

pub const module_name: [*:0]const u8 = "weirdperformance";

// malloc/free for libdeflate provided by stubs/game_alloc.c (compiled into
// the libdeflate static lib). This avoids exporting malloc/free from the DLL.

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// SSE functions (imported directly to avoid addObject SizeOfImage bloat)
// =============================================================================

const bone_sse = @import("bone_sse.zig");
const particle_sse = @import("particle_sse.zig");
const clip_sse = @import("clip_sse.zig");
const cull_sse = @import("cull_sse.zig");
const silicon_sse = @import("silicon_sse.zig");
const luaalloc = @import("luaalloc.zig");
const luagc = @import("luagc.zig");

const renderParticleSprites_SSE = particle_sse.renderParticleSprites_SSE;
const resetParticleCache = particle_sse.resetParticleCache;

// =============================================================================
// transformMatrix4x4 hook (0x714260)
// =============================================================================

const TransformFn = fn (u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
var transform_hook: hook.Detour(TransformFn) = .{};

// =============================================================================
// ClipPolygonToSinglePlane hook (0x6318C0)
// __fastcall(ECX=plane*, EDX=poly*, stack: attrib_bits), RET 0x4
// 1.9x speedup (410 -> 206 cycles/call), 2.55% of CPU in town
// =============================================================================

const ClipFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
var clip_hook: hook.Detour(ClipFn) = .{};

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
    scale_bits: u32 = 0, // font+0x188 scale factor (changes on resize)
    width_bits: u32 = 0,
};

var glyph_cache: [GLYPH_CACHE_SIZE]GlyphCacheEntry = [_]GlyphCacheEntry{.{}} ** GLYPH_CACHE_SIZE;

const GlyphFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var glyph_hook: hook.Detour(GlyphFn) = .{};

fn glyphDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const scale_bits = hook.readMem(u32, a + 0x188);
    const hash = ((a ^ c *% 0x9E3779B9) ^ d ^ scale_bits) & GLYPH_CACHE_MASK;
    const entry = &glyph_cache[hash];

    if (entry.font_ptr == a and entry.char_code == c and entry.param2 == d and entry.scale_bits == scale_bits) {
        asm volatile ("flds (%[p])"
            :
            : [p] "r" (&entry.width_bits),
        );
        return null;
    }

    const ret = glyph_hook.callOriginal(.{ a, b, c, d });

    var width_bits: u32 = undefined;
    asm volatile ("fsts (%[p])"
        :
        : [p] "r" (&width_bits),
    );

    entry.* = .{
        .font_ptr = a,
        .char_code = c,
        .param2 = d,
        .scale_bits = scale_bits,
        .width_bits = width_bits,
    };

    return ret;
}

// =============================================================================
// FindObjectByGUID cache (0x464890) — direct-mapped, validate-on-hit
// =============================================================================

const FindGuidFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var findguid_hook: hook.Detour(FindGuidFn) = .{};

const GUID_CACHE_BITS = 12;
const GUID_CACHE_SIZE = 1 << GUID_CACHE_BITS;
const GUID_CACHE_MASK = GUID_CACHE_SIZE - 1;
const GuidCacheEntry = struct { guid_lo: u32 = 0, guid_hi: u32 = 0, result: u32 = 0 };
var guid_cache: [GUID_CACHE_SIZE]GuidCacheEntry = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;

// MoveObjectToDeletedList: stdcall(guidLow, guidHigh), RET 0x8
// Same fastcall(4) Detour mapping as FindObjectByGUID
const ObjDeleteFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var obj_delete_hook: hook.Detour(ObjDeleteFn) = .{};

fn objDeleteDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    // Let original run first (it calls FindObjectByGUID internally, which re-caches).
    // Then evict, so the stale entry is removed after the original is done.
    const ret = obj_delete_hook.callOriginal(.{ a, b, c, d });
    const idx = (c ^ d) & GUID_CACHE_MASK;
    const entry = &guid_cache[idx];
    if (entry.guid_lo == c and entry.guid_hi == d) {
        entry.* = .{};
    }
    return ret;
}

fn findguidDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    // stdcall(2): c=guidLow, d=guidHigh (a,b unused fastcall reg args)
    const idx = (c ^ d) & GUID_CACHE_MASK;
    const entry = &guid_cache[idx];

    // No pointer validation needed -- cache is flushed every frame
    if (entry.guid_lo == c and entry.guid_hi == d and entry.result != 0) {
        return @ptrFromInt(entry.result);
    }

    const ret = findguid_hook.callOriginal(.{ a, b, c, d });
    const result = @intFromPtr(ret);
    if (result != 0) {
        entry.* = .{ .guid_lo = c, .guid_hi = d, .result = result };
    } else {
        // Object not found -- clear cache entry to prevent stale hits
        entry.* = .{};
    }
    return ret;
}

// =============================================================================
// DestroyObjectManager hook (0x467700) — flush GUID cache before teardown
// =============================================================================

var destroy_objmgr_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

fn destroyObjMgrDetour() callconv(hook.cc.stdcall) void {
    guid_cache = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;
    destroy_objmgr_hook.callOriginal(.{});
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
}


// =============================================================================
// SSE JMP patches — binary patches at game function addresses
// =============================================================================

// cull_sse.zig
const performSpatialCulling = cull_sse.performSpatialCulling;
const performCollisionDetectionSSE = cull_sse.performCollisionDetectionSSE;
const rayTriIntersectIndexedInt = cull_sse.rayTriIntersectIndexedInt;

// silicon_sse.zig
const sse = silicon_sse;

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
        .{ .target = 0x686180, .replacement = @intFromPtr(&sse.si_frustumCullBBox8), .name = "frustumCullBBox8" },
        .{ .target = 0x686940, .replacement = @intFromPtr(&sse.si_testAABBFrustum), .name = "testAABBFrustum" },
        .{ .target = 0x6B8C60, .replacement = @intFromPtr(&performSpatialCulling), .name = "PerformSpatialCulling" },
        .{ .target = 0x6B88E0, .replacement = @intFromPtr(&performCollisionDetectionSSE), .name = "performCollisionDetection" },
        .{ .target = 0x7C2C40, .replacement = @intFromPtr(&rayTriIntersectIndexedInt), .name = "rayTriIndexedInt" },
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
    if (transform_hook.attach(0x714260, &bone_sse.transformImpl_SSE) == .ok) installed += 1;

    // Frustum clip SSE (1.9x speedup)
    if (clip_hook.attach(0x6318C0, &clip_sse.clipPolygonToSinglePlane) == .ok) installed += 1;

    // Particle rendering SSE
    if (particle_hook.attach(0x7B2A50, &particleDetour) == .ok) installed += 1;

    // Glyph cache
    // Glyph cache removed -- game has internal glyph cache, our hook only sees misses (~30/frame)

    // GUID lookup cache -- A/B testing via transform44
    // if (findguid_hook.attach(0x464890, &findguidDetour) == .ok) installed += 1;
    // if (obj_delete_hook.attach(0x464920, &objDeleteDetour) == .ok) installed += 1;

    // GUID cache disabled for now
    // if (destroy_objmgr_hook.attach(0x467700, &destroyObjMgrDetour) == .ok) installed += 1;

    // Per-frame cache reset
    if (world_update_hook.attach(0x482EA0, &worldUpdateDetour) == .ok) installed += 1;

    // Silicon SSE binary patches
    _ = installPatches();

    // MPQ file cache
    if (filecache.install()) installed += 1;

    // libdeflate inflate replacement
    if (inflate_hook.install()) installed += 1;

    // Lua slab allocator replacement
    // installed += luaalloc.install(); // disabled for testing

    // GC phase profiler
    installed += luagc.install();
}

pub fn lateInit() void {
    if (!g_is_hook_owner) return;
    timer_fix.init();
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        luaalloc.dumpStats();
        luagc.dumpStats();
        filecache.remove();
        inflate_hook.remove();
        transform_hook.detach();
        particle_hook.detach();
        // glyph_hook removed
        findguid_hook.detach();
        obj_delete_hook.detach();
        destroy_objmgr_hook.detach();
        world_update_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
