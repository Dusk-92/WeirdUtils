//! transform44 — render pipeline profiling & M2 bone transform optimization
//!
//! Hooks 5 functions in the render/update pipeline to measure per-frame costs:
//!
//!   executeSceneRenderPass (0x708900) — top-level render pass dispatch
//!   renderFrame            (0x707680) — per-model render (calls transformMatrix4x4)
//!   transformMatrix4x4     (0x714260) — per-model bone transform engine (17703 bytes)
//!   RenderTextureQuads     (0x76FB00) — batched quad rendering
//!   CMovement::Process     (0x616620) — per-unit movement update
//!
//! Stats are dumped every DUMP_FRAMES render passes (~2s at 60fps).

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
// Profiling state — unified dump every DUMP_FRAMES render passes
// =============================================================================

const DUMP_FRAMES: u32 = 180;

var prof = ProfState{};
var t44_depth: u32 = 0; // recursion depth — survives resets

const ProfState = struct {
    // Frame counter (incremented by executeSceneRenderPass)
    frames: u32 = 0,

    // transformMatrix4x4 (0x714260)
    t44_calls: u32 = 0,
    t44_early: u32 = 0,
    t44_cycles: u64 = 0,
    t44_bones: u64 = 0,
    t44_max_bones: u32 = 0,
    t44_max_depth: u32 = 0,

    // renderFrame (0x707680)
    rf_calls: u32 = 0,
    rf_cycles: u64 = 0,

    // executeSceneRenderPass (0x708900)
    erp_calls: u32 = 0,
    erp_cycles: u64 = 0,

    // RenderTextureQuads (0x76FB00)
    rtq_calls: u32 = 0,
    rtq_cycles: u64 = 0,
    rtq_items: u64 = 0,

    // CMovement::ProcessUnitMovementUpdate (0x616620)
    mov_calls: u32 = 0,
    mov_cycles: u64 = 0,
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
// __thiscall(ECX=SceneObject*, stack: Matrix4x4* ×4)
// Fastcall mapping: ECX=this, EDX=unused, stack: mat1, mat2, mat3, mat4
// RET 0x10
// =============================================================================

const TransformFn = fn (u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
var transform_hook: hook.Detour(TransformFn) = .{};

fn transformDetour(this: u32, edx: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();

    // Check sync gate — predict early exit
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
        const model_hdr = hook.readMem(u32, this + 0x2C);
        if (model_hdr != 0) {
            bone_count = hook.readMem(u32, model_hdr + 0x34);
        }
    }

    t44_depth += 1;
    if (t44_depth > prof.t44_max_depth) prof.t44_max_depth = t44_depth;

    transform_hook.callOriginal(.{ this, edx, mat1, mat2, mat3, mat4 });

    t44_depth -= 1;
    const elapsed = rdtsc() - start;
    prof.t44_cycles +|= elapsed;
    prof.t44_calls += 1;
    if (is_early) prof.t44_early += 1;
    prof.t44_bones +|= bone_count;
    if (bone_count > prof.t44_max_bones) prof.t44_max_bones = bone_count;
}

// =============================================================================
// Hook: renderFrame (0x707680)
// __thiscall(ECX=this, stack: float* cameraPosition)
// Fastcall mapping: ECX=this, EDX=unused, stack: cameraPos
// RET 0x4
// =============================================================================

const RenderFrameFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var render_frame_hook: hook.Detour(RenderFrameFn) = .{};

fn renderFrameDetour(this: u32, edx: u32, camera_pos: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();
    const ret = render_frame_hook.callOriginal(.{ this, edx, camera_pos });
    prof.rf_cycles +|= rdtsc() - start;
    prof.rf_calls += 1;
    return ret;
}

// =============================================================================
// Hook: executeSceneRenderPass (0x708900)
// __thiscall(ECX=scene, stack: renderPassIndex) — Ghidra labels __stdcall but
// prologue does MOV ESI,ECX (saves this). RET 0x4.
// Fastcall mapping: ECX=this, EDX=unused, stack: passIndex
// =============================================================================

const ExecRenderPassFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var exec_render_pass_hook: hook.Detour(ExecRenderPassFn) = .{};

fn execRenderPassDetour(this: u32, edx: u32, pass_index: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();
    const ret = exec_render_pass_hook.callOriginal(.{ this, edx, pass_index });
    prof.erp_cycles +|= rdtsc() - start;
    prof.erp_calls += 1;

    // Use render pass as frame boundary for dump trigger
    prof.frames += 1;
    if (prof.frames >= DUMP_FRAMES) {
        dumpStats();
    }
    return ret;
}

// =============================================================================
// Hook: RenderTextureQuads (0x76FB00)
// __fastcall(ECX=RenderBatch*) — no stack params, RET
// RenderBatch+0xC = item_count
// =============================================================================

const RenderQuadsFn = fn (u32, u32) callconv(hook.cc.fastcall) void;
var render_quads_hook: hook.Detour(RenderQuadsFn) = .{};

fn renderQuadsDetour(batch: u32, edx: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Read item count before call (batch+0xC)
    const items: u32 = if (batch != 0) hook.readMem(u32, batch + 0xC) else 0;
    const start = rdtsc();
    render_quads_hook.callOriginal(.{ batch, edx });
    prof.rtq_cycles +|= rdtsc() - start;
    prof.rtq_calls += 1;
    prof.rtq_items +|= items;
}

// =============================================================================
// Hook: CMovement::ProcessUnitMovementUpdate (0x616620)
// __thiscall(ECX=this, stack: timeNow(u32), lastUpdate(u32))
// RET 0x8 (2 stack params)
// Fastcall mapping: ECX=this, EDX=unused, stack: timeNow, lastUpdate
// =============================================================================

const MovementFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) void;
var movement_hook: hook.Detour(MovementFn) = .{};

fn movementDetour(this: u32, edx: u32, time_now: u32, last_update: u32) callconv(hook.cc.fastcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const start = rdtsc();
    movement_hook.callOriginal(.{ this, edx, time_now, last_update });
    prof.mov_cycles +|= rdtsc() - start;
    prof.mov_calls += 1;
}

// =============================================================================
// Unified stats dump
// =============================================================================

fn dumpStats() void {
    const f = prof.frames;
    if (f == 0) return;

    // transformMatrix4x4
    const t44_real = prof.t44_calls - prof.t44_early;
    const t44_avg = if (t44_real > 0) prof.t44_cycles / t44_real else 0;
    const t44_avg_bones = if (t44_real > 0) prof.t44_bones / t44_real else 0;

    // Per-frame averages
    const rf_per_f = prof.rf_calls / f;
    const t44_per_f = prof.t44_calls / f;
    const rtq_per_f = prof.rtq_calls / f;
    const mov_per_f = prof.mov_calls / f;
    const erp_per_f = prof.erp_calls / f;

    // Cycle totals per frame
    const rf_cyc_f = prof.rf_cycles / f;
    const t44_cyc_f = prof.t44_cycles / f;
    const rtq_cyc_f = prof.rtq_cycles / f;
    const mov_cyc_f = prof.mov_cycles / f;
    const erp_cyc_f = prof.erp_cycles / f;

    log.fmt(
        \\[prof] {d} frames | per-frame: erp={d} rf={d} t44={d}({d}skip) rtq={d} mov={d}
        \\  cycles/frame: erp={d}K rf={d}K t44={d}K rtq={d}K mov={d}K
        \\  t44: {d}cyc/work bones_avg={d} max={d} depth={d} | rtq_items/frame={d}
        \\
    , .{
        f,
        erp_per_f,   rf_per_f,    t44_per_f,  prof.t44_early / f,  rtq_per_f,  mov_per_f,
        erp_cyc_f / 1000, rf_cyc_f / 1000, t44_cyc_f / 1000, rtq_cyc_f / 1000, mov_cyc_f / 1000,
        t44_avg,     t44_avg_bones, prof.t44_max_bones, prof.t44_max_depth,
        prof.rtq_items / f,
    });

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
    _ = transform_hook.attach(0x714260, &transformDetour);
    _ = render_frame_hook.attach(0x707680, &renderFrameDetour);
    _ = exec_render_pass_hook.attach(0x708900, &execRenderPassDetour);
    _ = render_quads_hook.attach(0x76FB00, &renderQuadsDetour);
    _ = movement_hook.attach(0x616620, &movementDetour);
    log.print("transform44: 5 profiling hooks installed\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        transform_hook.detach();
        render_frame_hook.detach();
        exec_render_pass_hook.detach();
        render_quads_hook.detach();
        movement_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
