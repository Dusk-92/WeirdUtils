//! WoW model rendering pipeline hooks.
//!
//! Hooks three WoW functions to integrate outline rendering:
//!  - CM2SceneRenderDraw  - reorders batches so outline targets render last.
//!  - CM2Model_ManageRenderListNode - classifies models on render-list add.
//!  - CM2Scene_DrawBatchProjected - flags the DIP hook for outline rendering.
//!
//! Calling conventions:
//!  - RenderDraw & ManageRender use callconv(.x86_thiscall) - direct native detours.
//!  - DrawBatchProj uses a callconv(.naked) entry point because Zig 0.15 has a
//!    codegen bug with callconv(.x86_fastcall) that generates wrong ret instructions
//!    for functions with ≤2 register params.  The naked wrapper bridges to a cdecl
//!    implementation function.

const std = @import("std");
const hook = @import("zhook");
const api = @import("outline.zig");
const o = @import("offsets.zig");
const types = @import("types.zig");
const tracker = @import("tracker.zig");
const d3d9_hook = @import("d3d9_hook.zig");
const wow = @import("../wow.zig");

// =============================================================================
// Calling convention constants
// =============================================================================


// =============================================================================
// Hook state
// =============================================================================

const RenderDrawFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) void;
const ManageRenderFn = fn (u32, u32) callconv(hook.cc.thiscall) void;
const DrawBatchFn = fn (u32) callconv(hook.cc.thiscall) void;

var render_draw_hook: hook.Detour(RenderDrawFn) = .{};
var manage_render_hook: hook.Detour(ManageRenderFn) = .{};
var draw_batch_hook: hook.Detour(DrawBatchFn) = .{};

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

// =============================================================================
// Batch reordering
// =============================================================================

const MAX_REORDER = 1024;
var reordered_indices: [MAX_REORDER]i32 = undefined;

// =============================================================================
// CM2SceneRenderDraw hook
// =============================================================================
// __thiscall(this, viewMatrix, batchData, batchIndices, batchCount)
// Native thiscall detour - no thunk needed.
//
// Reorders batch indices into 3 groups:
//   1. Game objects/doodads - render first, write depth so outlines respect them
//   2. Outline targets - render second, DIP hook writes stencil against depth
//   3. Other players, gear, NPCs - render last, draw over targets normally
//
// This gives outlines that are occluded by world/WMO/game objects but show
// through other players and gear (since those aren't in depth when stencil
// is written). The outline composites on top of everything in EndScene.

fn renderDrawDetour(this: u32, view_matrix: u32, batch_data: u32, batch_indices: u32, batch_count: u32) callconv(hook.cc.thiscall) void {
    // One-time: install D3D9 hooks now that the game is actively rendering.
    if (d3d9_deferred_pending) {
        d3d9_deferred_pending = false;
        api.initD3D9Deferred();
    }

    // Skip reordering if nothing to outline or too many batches
    if (!tracker.enabled or !tracker.hasTargets() or batch_count == 0 or batch_count > MAX_REORDER) {
        render_draw_hook.callOriginal(.{ this, view_matrix, batch_data, batch_indices, batch_count });
        return;
    }

    const indices: [*]i32 = @ptrFromInt(batch_indices);

    // Pass 1: count outline targets and game objects for partitioning
    var outline_count: u32 = 0;
    var game_obj_count: u32 = 0;
    for (0..batch_count) |i| {
        const idx_u: u32 = @bitCast(indices[i]);
        const model_ptr = hook.readMem(u32, batch_data +% idx_u *% 0x40 +% 4);
        if (model_ptr != 0) {
            if (tracker.findOutlineEntry(model_ptr) != null) {
                outline_count += 1;
            } else if (tracker.isGameObjectModel(model_ptr)) {
                game_obj_count += 1;
            }
        }
    }

    if (outline_count == 0) {
        render_draw_hook.callOriginal(.{ this, view_matrix, batch_data, batch_indices, batch_count });
        return;
    }

    // Pass 2: 3-way partition:
    //   [0 .. game_obj_count)           → game objects (write depth first)
    //   [game_obj_count .. +outline)    → outline targets (stencil against depth)
    //   [remainder ..]                  → other players, gear, NPCs
    var go_pos: u32 = 0;
    var outline_pos: u32 = game_obj_count;
    var rest_pos: u32 = game_obj_count + outline_count;
    for (0..batch_count) |i| {
        const batch_idx = indices[i];
        const idx_u: u32 = @bitCast(batch_idx);
        const model_ptr = hook.readMem(u32, batch_data +% idx_u *% 0x40 +% 4);
        if (model_ptr != 0 and tracker.findOutlineEntry(model_ptr) != null) {
            reordered_indices[outline_pos] = batch_idx;
            outline_pos += 1;
        } else if (model_ptr != 0 and tracker.isGameObjectModel(model_ptr)) {
            reordered_indices[go_pos] = batch_idx;
            go_pos += 1;
        } else {
            reordered_indices[rest_pos] = batch_idx;
            rest_pos += 1;
        }
    }

    // Write reordered indices back to game's array in-place
    for (0..batch_count) |i| {
        indices[i] = reordered_indices[i];
    }

    render_draw_hook.callOriginal(.{ this, view_matrix, batch_data, batch_indices, batch_count });
}

// =============================================================================
// CM2Model_ManageRenderListNode hook
// =============================================================================
// __thiscall(model_ECX, addToList_stack)
// Native thiscall detour - no thunk needed.

fn manageRenderDetour(model: u32, add_to_list: u32) callconv(hook.cc.thiscall) void {
    // Classify the model when it's being ADDED to the render list
    if (add_to_list == 1 and model != 0 and tracker.enabled and tracker.hasTargets()) {
        tracker.classifyModel(model);
    }

    manage_render_hook.callOriginal(.{ model, add_to_list });
}

// =============================================================================
// CM2Scene_DrawBatchProjected hook
// =============================================================================
// __fastcall(renderContext_ECX)
//
// Uses a naked entry point because Zig 0.15's x86_fastcall codegen generates
// wrong ret instructions for functions with ≤2 register params.  The naked
// function bridges fastcall → cdecl and calls the implementation function.

fn drawBatchProjDetour(ctx: u32) callconv(hook.cc.thiscall) void {
    // Fast path: no tracking enabled or nothing tracked → just call original
    if (!tracker.enabled or !tracker.hasTargets()) {
        draw_batch_hook.callOriginal(.{ctx});
        return;
    }

    const model_ptr = if (wow.isValidPtr(ctx +% @as(u32, @intCast(o.RENDER_CONTEXT_MODEL_OFFSET))))
        hook.readMem(u32, ctx + o.RENDER_CONTEXT_MODEL_OFFSET)
    else
        0;

    const entry = if (model_ptr != 0) tracker.findOutlineEntry(model_ptr) else null;

    if (entry != null) {
        // This batch is an outline target - signal the DIP hook
        rendering_outline = true;
        current_model = model_ptr;

        draw_batch_hook.callOriginal(.{ctx});

        rendering_outline = false;
        current_model = 0;
    } else {
        draw_batch_hook.callOriginal(.{ctx});
    }
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn installHooks() bool {
    if (render_draw_hook.attach(o.FN_CM2SCENE_RENDER_DRAW, &renderDrawDetour) != .ok)
        return false;

    if (manage_render_hook.attach(o.FN_CM2MODEL_MANAGE_RENDER_LIST, &manageRenderDetour) != .ok)
        return false;

    if (draw_batch_hook.attach(o.FN_DRAW_BATCH_PROJ, &drawBatchProjDetour) != .ok)
        return false;

    return true;
}

pub fn removeHooks() void {
    draw_batch_hook.detach();
    manage_render_hook.detach();
    render_draw_hook.detach();
}
