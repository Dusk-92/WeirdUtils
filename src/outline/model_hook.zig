//! WoW model rendering pipeline hooks.
//!
//! Hooks three WoW functions to integrate outline rendering:
//!  - CM2SceneRenderDraw  — reorders batches so outline targets render first.
//!  - CM2Model_ManageRenderListNode — classifies models on render-list add.
//!  - CM2Scene_DrawBatchProjected — flags the DIP hook for outline rendering.
//!
//! Calling conventions:
//!  - RenderDraw & ManageRender use callconv(.x86_thiscall) — direct native detours.
//!  - DrawBatchProj uses a callconv(.naked) entry point because Zig 0.15 has a
//!    codegen bug with callconv(.x86_fastcall) that generates wrong ret instructions
//!    for functions with ≤2 register params.  The naked wrapper bridges to a cdecl
//!    implementation function.

const std = @import("std");
const hook = @import("hook");
const api = @import("api.zig");
const o = @import("offsets.zig");
const types = @import("types.zig");
const tracker = @import("tracker.zig");
const wow = @import("wow.zig");

// =============================================================================
// Calling convention constants
// =============================================================================

const THISCALL = std.builtin.CallingConvention{ .x86_thiscall = .{} };

// =============================================================================
// Hook state
// =============================================================================

var render_draw_hook: hook.Hook = .{};
var manage_render_hook: hook.Hook = .{};
var draw_batch_hook: hook.Hook = .{};

/// D3D9 hooks are deferred until the first model hook fires, because creating
/// a dummy D3D9 device during engine init corrupts the proxy's state.
var d3d9_deferred_pending: bool = true;

// =============================================================================
// Volatile flags shared with d3d9_hook (read by DIP hook)
// =============================================================================

/// True while DrawBatchProj is rendering an outline-target model.
pub var rendering_outline: bool = false;

/// Model pointer currently being rendered (for colour lookup in DIP).
pub var current_model: u32 = 0;

/// Set after outline targets render; tells DIP to apply stencil test on
/// subsequent unit batches so outlines aren't covered by nearby players.
pub var test_outline_stencil: bool = false;

/// True while the current DrawBatchProj batch is a unit (player/NPC).
pub var rendering_unit: bool = false;

// =============================================================================
// Batch reordering limits
// =============================================================================

const MAX_REORDER = 1024;
var reordered_indices: [MAX_REORDER]i32 = undefined;

// =============================================================================
// CM2SceneRenderDraw hook
// =============================================================================
// __thiscall(this, viewMatrix, batchData, batchIndices, batchCount)
// Native thiscall detour — no thunk needed.

fn renderDrawDetour(this: u32, view_matrix: u32, batch_data: u32, batch_indices: u32, batch_count: u32) callconv(THISCALL) void {
    // One-time: install D3D9 hooks now that the game is actively rendering.
    if (d3d9_deferred_pending) {
        d3d9_deferred_pending = false;
        api.initD3D9Deferred();
    }

    // If outlines disabled or nothing tracked, fast-path to original
    if (!tracker.enabled or !tracker.hasTargets() or batch_count == 0 or
        batch_data == 0 or batch_indices == 0 or batch_count > MAX_REORDER)
    {
        callOrigRenderDraw(this, view_matrix, batch_data, batch_indices, batch_count);
        return;
    }

    // Single pass: partition batches into outline-targets vs normal,
    // keeping relative order within each group.
    var outline_buf: [MAX_REORDER]i32 = undefined;
    var normal_buf: [MAX_REORDER]i32 = undefined;
    var o_count: usize = 0;
    var n_count: usize = 0;

    const indices: [*]const i32 = @ptrFromInt(batch_indices);
    for (0..batch_count) |i| {
        const idx = indices[i];
        const batch_ptr = batch_data +% @as(u32, @bitCast(idx)) *% 0x40;
        const model_ptr = hook.readMem(u32, batch_ptr + 4);

        if (model_ptr != 0 and tracker.findOutlineEntry(model_ptr) != null) {
            outline_buf[o_count] = idx;
            o_count += 1;
        } else {
            normal_buf[n_count] = idx;
            n_count += 1;
        }
    }

    if (o_count == 0) {
        // Nothing to reorder
        callOrigRenderDraw(this, view_matrix, batch_data, batch_indices, batch_count);
        return;
    }

    // Build reordered array: outline targets FIRST (populate stencil), then normals
    var total: usize = 0;
    for (outline_buf[0..o_count]) |v| {
        reordered_indices[total] = v;
        total += 1;
    }
    for (normal_buf[0..n_count]) |v| {
        reordered_indices[total] = v;
        total += 1;
    }

    callOrigRenderDraw(this, view_matrix, batch_data, @intFromPtr(&reordered_indices), @intCast(total));
}

fn callOrigRenderDraw(this: u32, view_matrix: u32, batch_data: u32, batch_indices: u32, batch_count: u32) void {
    // __thiscall: ECX = this, stack = viewMatrix, batchData, batchIndices, batchCount
    // Callee cleans 16 bytes (4 stack params).
    // Pack args into a struct so we only need one "r" register to address them.
    const args = [4]u32{ view_matrix, batch_data, batch_indices, batch_count };
    asm volatile (
        \\push 12(%[a])
        \\push 8(%[a])
        \\push 4(%[a])
        \\push (%[a])
        \\call *%[func]
        :
        : [_] "{ecx}" (this),
          [a] "r" (&args),
          [func] "r" (render_draw_hook.trampoline),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// CM2Model_ManageRenderListNode hook
// =============================================================================
// __thiscall(model_ECX, addToList_stack)
// Native thiscall detour — no thunk needed.

fn manageRenderDetour(model: u32, add_to_list: u32) callconv(THISCALL) void {
    // Classify the model when it's being ADDED to the render list
    if (add_to_list == 1 and model != 0 and tracker.enabled and tracker.hasTargets()) {
        tracker.classifyModel(model);
    }

    // Call original: __thiscall(model_ECX, addToList_stack)
    asm volatile (
        \\push %[add]
        \\call *%[func]
        :
        : [_] "{ecx}" (model),
          [add] "r" (add_to_list),
          [func] "r" (manage_render_hook.trampoline),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// CM2Scene_DrawBatchProjected hook
// =============================================================================
// __fastcall(renderContext_ECX)
//
// Uses a naked entry point because Zig 0.15's x86_fastcall codegen generates
// wrong ret instructions for functions with ≤2 register params.  The naked
// function bridges fastcall → cdecl and calls the implementation function.

fn drawBatchProjEntry() callconv(.naked) void {
    // __fastcall(ECX): ECX = render context, 0 stack args.
    // Bridge to cdecl: push edx + ecx as args, call impl, cleanup, ret.
    asm volatile (
        \\push %%edx
        \\push %%ecx
        \\call *%%eax
        \\add $8, %%esp
        \\ret
        :
        : [_] "{eax}" (@intFromPtr(&drawBatchProjImpl))
    );
}

fn drawBatchProjImpl(ctx: u32, _edx: u32) callconv(.c) void {
    _ = _edx;

    // Fast path: no tracking enabled or nothing tracked → just call original
    if (!tracker.enabled or !tracker.hasTargets()) {
        callOrigDrawBatch(ctx);
        return;
    }

    const model_ptr = if (wow.isValidPtr(ctx +% @as(u32, @intCast(o.RENDER_CONTEXT_MODEL_OFFSET))))
        hook.readMem(u32, ctx + o.RENDER_CONTEXT_MODEL_OFFSET)
    else
        0;

    const entry = if (model_ptr != 0) tracker.findOutlineEntry(model_ptr) else null;

    if (entry != null) {
        // This batch is an outline target — signal the DIP hook
        rendering_outline = true;
        current_model = model_ptr;

        callOrigDrawBatch(ctx);

        rendering_outline = false;
        current_model = 0;

        // After outline targets render, enable stencil test for subsequent units
        test_outline_stencil = true;
    } else {
        // Normal rendering.  Determine if this is a unit for stencil testing.
        rendering_outline = false;
        current_model = 0;
        rendering_unit = false;

        if (model_ptr != 0) {
            rendering_unit = tracker.isUnitModel(model_ptr);
        }

        callOrigDrawBatch(ctx);

        rendering_unit = false;
    }
}

fn callOrigDrawBatch(ctx: u32) void {
    asm volatile ("call *%[func]"
        :
        : [_] "{ecx}" (ctx),
          [func] "r" (draw_batch_hook.trampoline),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() bool {
    // CM2SceneRenderDraw — native thiscall detour, no thunk needed.
    // Prologue is 9 bytes: PUSH EBP (1) + MOV EBP,ESP (2) + SUB ESP,0x80 (6).
    if (!render_draw_hook.install(
        o.FN_CM2SCENE_RENDER_DRAW,
        9,
        @intFromPtr(&renderDrawDetour),
        &.{},
    )) return false;

    // ManageRenderListNode — native thiscall detour, no thunk needed.
    if (!manage_render_hook.install(
        o.FN_CM2MODEL_MANAGE_RENDER_LIST,
        6,
        @intFromPtr(&manageRenderDetour),
        &.{},
    )) return false;

    // DrawBatchProj — naked entry bridges fastcall → cdecl, no thunk needed.
    if (!draw_batch_hook.install(
        o.FN_DRAW_BATCH_PROJ,
        6,
        @intFromPtr(&drawBatchProjEntry),
        &.{},
    )) return false;

    return true;
}

pub fn removeHooks() void {
    draw_batch_hook.remove();
    manage_render_hook.remove();
    render_draw_hook.remove();
}
