//! transform44 — profiling & optimization of transformMatrix4x4 (0x714260)
//!
//! transformMatrix4x4 is the main per-frame bone transform engine for ALL visible
//! M2 models. 17703 bytes. Called from renderFrame, renderSceneNode,
//! updateAnimationTransform. Recursive for attached child objects (weapons, etc).
//!
//! Phase 1: Profiling instrumentation — measures call frequency, early-exit rate,
//! cycle cost, and bone counts to identify optimization targets.
//!
//! Key inner functions (call counts within transformMatrix4x4):
//!   findInterpolationIndices (0x713d50) — 58 calls, binary/linear keyframe search
//!   interpolateAnimationKeyframes (0x713ea0) — 2 calls, vec4 keyframe lerp
//!   getInterpolatedFloat (0x71af20) — 4 calls, scalar keyframe lerp
//!   getIndexOffset (0x71aff0) — 12 calls, trivial (ptr + idx*2)
//!   setShortValue (0x71b010) — 12 calls, trivial (write u16)
//!   scaleMatrix3x3ByVector (0x7bdca0) — 2 calls, x87 FPU (SSE candidate)
//!   ApplyTranslationMatrix (0x7bdc40) — 5 calls, x87 FPU (SSE candidate)
//!   rotateMatrixByQuaternion (0x7bddb0) — 1 call, builds rot matrix then SSE multiply

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "transform44";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Profiling state
// =============================================================================

const DUMP_INTERVAL: u32 = 500;

var prof = ProfState{};

const ProfState = struct {
    calls: u32 = 0,
    early_exits: u32 = 0,
    cycles: u64 = 0,
    total_bones: u64 = 0,
    max_bones: u32 = 0,
    max_depth: u32 = 0,
    depth: u32 = 0,
};

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
// __thiscall(ECX=SceneObject*, stack: Matrix4x4*, Matrix4x4*, Matrix4x4*, Matrix4x4*)
// RET 0x10 (4 stack params × 4 bytes)
//
// Mapped to fastcall: ECX=this, EDX=unused, stack: mat1, mat2, mat3, mat4
// Stack cleanup is identical (4 stack params = RET 0x10 in both conventions).
// =============================================================================

const TRANSFORM_ADDR: u32 = 0x714260;

const TransformFn = fn (u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;

var transform_hook: hook.Detour(TransformFn) = .{};

fn transformDetour(this: u32, edx: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();

    // Check sync gate — predict whether original will early-exit.
    // Original code: if (this+0x10 == NULL || this+0x40 == *(*(this+0x30)+0x10)) return;
    const model_data = hook.readMem(u32, this + 0x10);
    var is_early = false;
    var bone_count: u32 = 0;
    if (model_data == 0) {
        is_early = true;
    } else {
        const anim_ctx = hook.readMem(u32, this + 0x30);
        if (anim_ctx != 0) {
            const sync_val = hook.readMem(u32, this + 0x40);
            const anim_sync = hook.readMem(u32, anim_ctx + 0x10);
            if (sync_val == anim_sync) is_early = true;
        }
        // Read bone count from model header at this+0x2C -> +0x34
        const model_hdr = hook.readMem(u32, this + 0x2C);
        if (model_hdr != 0) {
            bone_count = hook.readMem(u32, model_hdr + 0x34);
        }
    }

    prof.depth += 1;
    if (prof.depth > prof.max_depth) prof.max_depth = prof.depth;

    transform_hook.callOriginal(.{ this, edx, mat1, mat2, mat3, mat4 });

    prof.depth -= 1;
    const elapsed = rdtsc() - start;
    prof.cycles +|= elapsed;
    prof.calls += 1;
    if (is_early) prof.early_exits += 1;
    prof.total_bones +|= bone_count;
    if (bone_count > prof.max_bones) prof.max_bones = bone_count;

    // Dump stats periodically (only at depth 0 to avoid spam during recursion)
    if (prof.depth == 0 and prof.calls >= DUMP_INTERVAL) {
        dumpStats();
    }
}

fn dumpStats() void {
    const real = prof.calls - prof.early_exits;
    const avg_all = if (prof.calls > 0) prof.cycles / prof.calls else 0;
    const avg_real = if (real > 0) prof.cycles / real else 0;
    const avg_bones = if (real > 0) prof.total_bones / real else 0;
    log.fmt("[prof] {d} calls ({d} work, {d} skip), {d}/{d} cyc avg/work, bones avg={d} max={d}, depth={d}\n", .{
        prof.calls,     real,           prof.early_exits,
        avg_all,        avg_real,       avg_bones,
        prof.max_bones, prof.max_depth,
    });
    // Reset but preserve depth (we're always at depth 0 here)
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
    _ = transform_hook.attach(TRANSFORM_ADDR, &transformDetour);
    log.print("transform44: profiling hook installed at 0x714260\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        transform_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
