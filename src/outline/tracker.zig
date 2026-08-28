//! Per-frame model tracking for the outline system.
//!
//! Maintains fixed-size arrays of tracked object pointers (target, raid marks,
//! dead players) and the per-frame set of outline model entries.
//! All state is single-threaded (main WoW thread) - no synchronisation needed.
//!
//! Model classification uses forward mapping: scanObjects stores object pointers
//! from the object manager, then classifyModel (ManageRenderListNode) reads the
//! model's back-pointers (model+0x28, model+0x3C0) and compares them against
//! known object pointers.  No dereferencing of unknown memory - just value
//! comparison against the object manager's validated set.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const wow = @import("../wow.zig");
const o = @import("offsets.zig");
const types = @import("types.zig");

// =============================================================================
// Tracking limits
// =============================================================================

const MAX_TRACKED_OBJS = 128;
const MAX_OUTLINE_MODELS = 256;

// =============================================================================
// Tracked object set (populated by scanObjects from the object manager)
// =============================================================================
// Stores obj_ptr + category for entities we want to outline.
// classifyModel matches model back-pointers against these - no pointer chasing.

const TrackedObj = struct {
    obj_ptr: u32,
    category: types.ModelCategory,
    raid_mark: u8,
};

var tracked_objs: [MAX_TRACKED_OBJS]TrackedObj = undefined;
pub var tracked_obj_count: usize = 0;

// =============================================================================
// Per-frame outline model set (populated by ManageRenderListNode hook)
// =============================================================================

var frame_outlines: [MAX_OUTLINE_MODELS]types.OutlineEntry = undefined;
var frame_outline_count: usize = 0;

// =============================================================================
// Per-frame game object tracking (for render ordering - game objects first)
// =============================================================================
// Game object M2 models need to render before outline targets so their depth
// is in the buffer when stencil marks are written. Tracked separately from
// outline entries since game objects don't get outlines.

const MAX_GAME_OBJ_MODELS = 256;

var game_obj_ptrs: [MAX_TRACKED_OBJS]u32 = undefined;
var game_obj_ptr_count: usize = 0;

var game_obj_models: [MAX_GAME_OBJ_MODELS]u32 = undefined;
var game_obj_model_count: usize = 0;

// =============================================================================
// Global enable flag
// =============================================================================

pub var enabled: bool = true;

// =============================================================================
// Public query API
// =============================================================================

/// Look up a model pointer in the per-frame outline set.
pub fn findOutlineEntry(model_ptr: u32) ?*const types.OutlineEntry {
    for (frame_outlines[0..frame_outline_count]) |*entry| {
        if (entry.model_ptr == model_ptr) return entry;
    }
    return null;
}

/// Check if any outline targets are tracked this frame.
pub fn hasTargets() bool {
    return tracked_obj_count > 0;
}

/// Get the outline colour for a model, or null if not tracked.
pub fn getModelColor(model_ptr: u32) ?u32 {
    const entry = findOutlineEntry(model_ptr) orelse return null;
    return switch (entry.category) {
        .target => types.COLOR_TARGET,
        .raid_marked => if (entry.raid_mark > 0 and entry.raid_mark <= 8)
            types.RAID_MARK_COLORS[entry.raid_mark]
        else
            types.COLOR_DEAD_PLAYER,
        .dead_player => types.COLOR_DEAD_PLAYER,
        .none => null,
    };
}

/// Get the outline category for a model.
pub fn getModelCategory(model_ptr: u32) types.ModelCategory {
    const entry = findOutlineEntry(model_ptr) orelse return .none;
    return entry.category;
}

/// Check if a model belongs to a game object (for render ordering).
pub fn isGameObjectModel(model_ptr: u32) bool {
    for (game_obj_models[0..game_obj_model_count]) |m| {
        if (m == model_ptr) return true;
    }
    return false;
}

/// Get screen-space outline thickness in pixels for a category.
pub fn getOutlinePixels(cat: types.ModelCategory) f32 {
    return switch (cat) {
        .target => types.OUTLINE_PIXELS_TARGET,
        .raid_marked => types.OUTLINE_PIXELS_RAID_MARK,
        .dead_player => types.OUTLINE_PIXELS_DEAD_PLAYER,
        .none => 0,
    };
}

// =============================================================================
// Per-frame model registration (called from ManageRenderListNode hook)
// =============================================================================

/// Classify a model by comparing its back-pointers against known object pointers.
/// Safe: only reads from the model struct (which WoW just handed us via the
/// ManageRenderListNode __thiscall), then compares values - never dereferences
/// the back-pointer values as pointers.
pub fn classifyModel(model_ptr: u32) void {
    if (model_ptr == 0 or !enabled) return;

    // Read the model's back-pointers to its owning game object.
    const owner_direct = hook.readMem(u32, model_ptr + o.MODEL_OWNER_DIRECT);
    const owner_callback = hook.readMem(u32, model_ptr + o.MODEL_OWNER_CALLBACK);

    // Match against tracked outline objects (target, raid marks, dead players).
    if (tracked_obj_count > 0 and frame_outline_count < MAX_OUTLINE_MODELS) {
        if (findOutlineEntry(model_ptr) == null) {
            for (tracked_objs[0..tracked_obj_count]) |tracked| {
                if (owner_callback == tracked.obj_ptr or owner_direct == tracked.obj_ptr) {
                    addOutlineEntry(model_ptr, tracked.category, tracked.raid_mark);
                    break;
                }
            }
        }
    }

    // Match against game object pointers (for render ordering).
    if (game_obj_ptr_count > 0 and game_obj_model_count < MAX_GAME_OBJ_MODELS) {
        for (game_obj_ptrs[0..game_obj_ptr_count]) |go_ptr| {
            if (owner_callback == go_ptr or owner_direct == go_ptr) {
                // Deduplicate
                var found = false;
                for (game_obj_models[0..game_obj_model_count]) |m| {
                    if (m == model_ptr) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    game_obj_models[game_obj_model_count] = model_ptr;
                    game_obj_model_count += 1;
                }
                break;
            }
        }
    }
}

fn addOutlineEntry(model_ptr: u32, cat: types.ModelCategory, mark: u8) void {
    if (frame_outline_count >= MAX_OUTLINE_MODELS) return;
    frame_outlines[frame_outline_count] = .{
        .model_ptr = model_ptr,
        .category = cat,
        .raid_mark = mark,
    };
    frame_outline_count += 1;

    // Diagnostic: count classified models by category
    switch (cat) {
        .target => {
            diag.classify_target += 1;
            debug_target_model_seen = true;
        },
        .raid_marked => diag.classify_raid_mark += 1,
        .dead_player => diag.classify_dead_player += 1,
        .none => {},
    }
}

// =============================================================================
// Per-frame scan (called from EndScene)
// =============================================================================

/// Scan all visible objects and build the tracked object pointer sets.
/// Stores object pointers directly so classifyModel can match model
/// back-pointers without any pointer dereferencing.
pub fn scanObjects() void {
    debug_scan_called_seen = true;
    const gen = @atomicRmw(u32, &debug_scan_generation, .Add, 1, .seq_cst) + 1;
    const published_at = @atomicLoad(u32, &debug_publish_scan_generation, .seq_cst);
    if (published_at != 0 and gen > published_at) {
        debug_scan_after_publish_seen = true;
    }

    // Clear per-frame sets
    frame_outline_count = 0;
    tracked_obj_count = 0;
    game_obj_ptr_count = 0;
    game_obj_model_count = 0;
    resetDiag();

    // DEBUG10: EndScene must not call WoW object/game functions. On this client
    // those functions only behave correctly from the Lua/main-thread context.
    // Consume atomically published object pointers captured by OutlineDebug().
    const local_player = @atomicLoad(u32, &debug_pinned_player_obj, .seq_cst);
    if (local_player != 0) debug_pin_player_consumed_seen = true;
    if (local_player != 0 and game_obj_ptr_count < MAX_TRACKED_OBJS) {
        game_obj_ptrs[game_obj_ptr_count] = local_player;
        game_obj_ptr_count += 1;
    }

    const target_obj = @atomicLoad(u32, &debug_pinned_target_obj, .seq_cst);
    if (target_obj != 0) {
        debug_pin_target_consumed_seen = true;
        addTrackedObj(target_obj, .target, 0);
    }

    // Secondary categories (raid marks/dead players/game objects) are disabled
    // in this diagnostic build until the target-only path is proven stable.
}

fn addTrackedObj(obj_ptr: u32, cat: types.ModelCategory, mark: u8) void {
    if (obj_ptr == 0 or tracked_obj_count >= MAX_TRACKED_OBJS) return;
    // Deduplicate; higher priority (lower enum value) wins
    for (tracked_objs[0..tracked_obj_count]) |*existing| {
        if (existing.obj_ptr == obj_ptr) {
            if (@intFromEnum(cat) < @intFromEnum(existing.category)) {
                existing.category = cat;
                existing.raid_mark = mark;
            }
            return;
        }
    }
    tracked_objs[tracked_obj_count] = .{
        .obj_ptr = obj_ptr,
        .category = cat,
        .raid_mark = mark,
    };
    tracked_obj_count += 1;

    // Diagnostic: count tracked objects by category
    switch (cat) {
        .target => {
            diag.scan_targets += 1;
            debug_target_seen = true;
        },
        .raid_marked => diag.scan_raid_marks += 1,
        .dead_player => diag.scan_dead_players += 1,
        .none => {},
    }
}

// =============================================================================
// Diagnostics (per-frame counters, logged from EndScene)
// =============================================================================

pub const Diag = struct {
    // scanObjects counts (how many objects were added to tracked_objs)
    scan_targets: u16 = 0,
    scan_raid_marks: u16 = 0,
    scan_dead_players: u16 = 0,
    // classifyModel counts (how many models matched tracked objects)
    classify_target: u16 = 0,
    classify_raid_mark: u16 = 0,
    classify_dead_player: u16 = 0,
    // Number of frames logged so far
    log_count: u16 = 0,
};

pub var diag: Diag = .{};

// Sticky diagnostics for the debug build. They turn true once the corresponding
// stage has been observed and stay true for the whole process lifetime.
pub var debug_in_world_seen: bool = false;
pub var debug_object_manager_seen: bool = false;
pub var debug_player_guid_seen: bool = false;
pub var debug_local_player_seen: bool = false;
pub var debug_unit_player_guid_seen: bool = false;
pub var debug_unit_player_object_seen: bool = false;
pub var debug_target_guid_seen: bool = false;
pub var debug_target_object_seen: bool = false;
pub var debug_unit_target_guid_seen: bool = false;
pub var debug_unit_target_object_seen: bool = false;
pub var debug_object_scan_seen: bool = false;
pub var debug_scan_called_seen: bool = false;
pub var debug_pin_player_published_seen: bool = false;
pub var debug_pin_target_published_seen: bool = false;
pub var debug_pin_player_consumed_seen: bool = false;
pub var debug_pin_target_consumed_seen: bool = false;
var debug_scan_generation: u32 = 0;
var debug_publish_scan_generation: u32 = 0;
pub var debug_scan_after_publish_seen: bool = false;

// DEBUG9: objects captured explicitly from OutlineDebug() while executing in
// WoW's Lua/main-thread context. This lets us test the render/classification
// path without calling game object lookup functions from D3D9 EndScene.
var debug_pinned_player_obj: u32 = 0;
var debug_pinned_target_obj: u32 = 0;

pub fn setDebugPinnedObjects(player_obj: u32, target_obj: u32) void {
    const gen = @atomicLoad(u32, &debug_scan_generation, .seq_cst);
    @atomicStore(u32, &debug_publish_scan_generation, gen, .seq_cst);
    @atomicStore(u32, &debug_pinned_player_obj, player_obj, .seq_cst);
    @atomicStore(u32, &debug_pinned_target_obj, target_obj, .seq_cst);
    if (player_obj != 0) debug_pin_player_published_seen = true;
    if (target_obj != 0) debug_pin_target_published_seen = true;
    if (player_obj != 0) {
        debug_unit_player_object_seen = true;
        debug_local_player_seen = true;
    }
    if (target_obj != 0) {
        debug_unit_target_object_seen = true;
        debug_target_object_seen = true;
    }
}
pub var debug_target_seen: bool = false;
pub var debug_target_model_seen: bool = false;

var log: logging.Logger = .{};

pub fn initLogger() void {
    log = logging.Logger.open("outline", .console);
}

/// Log diagnostic counters. Called from EndScene.
/// Only logs when outline activity is detected, limited to first 20 events.
pub fn logDiagnostics(cached_draw_count: u32) void {
    const has_activity = diag.scan_targets > 0 or diag.scan_raid_marks > 0 or
        diag.scan_dead_players > 0 or diag.classify_target > 0 or
        diag.classify_raid_mark > 0 or diag.classify_dead_player > 0 or
        cached_draw_count > 0;

    if (!has_activity or diag.log_count >= 20) return;
    diag.log_count += 1;

    log.fmt("scan t={d} r={d} d={d} | classify t={d} r={d} d={d} | cached={d}\n", .{
        diag.scan_targets,
        diag.scan_raid_marks,
        diag.scan_dead_players,
        diag.classify_target,
        diag.classify_raid_mark,
        diag.classify_dead_player,
        cached_draw_count,
    });
}

/// Reset per-frame diagnostic counters. Called at start of scanObjects.
fn resetDiag() void {
    diag.scan_targets = 0;
    diag.scan_raid_marks = 0;
    diag.scan_dead_players = 0;
    diag.classify_target = 0;
    diag.classify_raid_mark = 0;
    diag.classify_dead_player = 0;
}
