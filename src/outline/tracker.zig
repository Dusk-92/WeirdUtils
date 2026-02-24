//! Per-frame model tracking for the outline system.
//!
//! Maintains fixed-size arrays for dead-player GUIDs, raid-marked GUIDs,
//! the current target, and the per-frame set of outline model entries.
//! All state is single-threaded (main WoW thread) — no synchronisation needed.

const hook = @import("hook");
const wow = @import("wow.zig");
const o = @import("offsets.zig");
const types = @import("types.zig");

// =============================================================================
// Tracking limits
// =============================================================================

const MAX_DEAD_GUIDS = 64;
const MAX_RAID_MARKS = 8;
const MAX_OUTLINE_MODELS = 256;
const MAX_UNIT_MODELS = 512;

// =============================================================================
// Persistent tracking (survives across frames until scan refresh)
// =============================================================================

var dead_guids: [MAX_DEAD_GUIDS]u64 = .{0} ** MAX_DEAD_GUIDS;
var dead_guid_count: usize = 0;

var raid_mark_guids: [MAX_RAID_MARKS]u64 = .{0} ** MAX_RAID_MARKS;
var raid_mark_indices: [MAX_RAID_MARKS]u8 = .{0} ** MAX_RAID_MARKS;
var raid_mark_count: usize = 0;

var target_guid_val: u64 = 0;

// =============================================================================
// Per-frame outline model set (populated by ManageRenderListNode hook)
// =============================================================================

var frame_outlines: [MAX_OUTLINE_MODELS]types.OutlineEntry = undefined;
var frame_outline_count: usize = 0;

// =============================================================================
// Per-frame unit model cache (populated by ManageRenderListNode hook)
// =============================================================================
// Caches which model pointers belong to units (players/NPCs), so DrawBatchProj
// can check unit status without raw pointer chasing through model structs.
// This mirrors the C++ g_modelToOwner hashmap approach.

var frame_unit_models: [MAX_UNIT_MODELS]u32 = .{0} ** MAX_UNIT_MODELS;
var frame_unit_model_count: usize = 0;

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
    return dead_guid_count > 0 or raid_mark_count > 0 or target_guid_val != 0;
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

/// Get screen-space outline thickness in pixels for a category.
pub fn getOutlinePixels(cat: types.ModelCategory) f32 {
    return switch (cat) {
        .target => types.OUTLINE_PIXELS_TARGET,
        .raid_marked => types.OUTLINE_PIXELS_RAID_MARK,
        .dead_player => types.OUTLINE_PIXELS_DEAD_PLAYER,
        .none => 0,
    };
}

/// Check if a model was classified as a unit (player/NPC) this frame.
/// Used by DrawBatchProj to decide stencil testing without raw pointer chasing.
pub fn isUnitModel(model_ptr: u32) bool {
    if (model_ptr == 0) return false;
    for (frame_unit_models[0..frame_unit_model_count]) |m| {
        if (m == model_ptr) return true;
    }
    return false;
}

// =============================================================================
// Per-frame model registration (called from ManageRenderListNode hook)
// =============================================================================

/// Try to classify a model and add it to the per-frame outline set.
/// Also caches unit status for stencil occlusion in DrawBatchProj.
pub fn classifyModel(model_ptr: u32) void {
    if (model_ptr == 0 or !enabled) return;

    // Try to resolve the owning game object
    const owner = wow.resolveModelOwner(model_ptr);
    if (owner == 0) return;

    // Cache unit status for stencil occlusion (regardless of outline status)
    const obj_type = wow.getObjectType(owner);
    if (obj_type == .unit or obj_type == .player) {
        addUnitModel(model_ptr);
    }

    // Already tracked as outline this frame?
    if (frame_outline_count >= MAX_OUTLINE_MODELS) return;
    if (findOutlineEntry(model_ptr) != null) return;

    const guid = wow.getObjectGUID(owner);
    if (guid == 0) return;

    // Priority 1: current target
    if (guid == target_guid_val and target_guid_val != 0) {
        addEntry(model_ptr, .target, 0);
        return;
    }

    // Priority 2: raid mark
    for (raid_mark_guids[0..raid_mark_count], raid_mark_indices[0..raid_mark_count]) |rg, ri| {
        if (rg == guid) {
            addEntry(model_ptr, .raid_marked, ri);
            return;
        }
    }

    // Priority 3: dead friendly player
    for (dead_guids[0..dead_guid_count]) |dg| {
        if (dg == guid) {
            addEntry(model_ptr, .dead_player, 0);
            return;
        }
    }
}

fn addUnitModel(model_ptr: u32) void {
    if (frame_unit_model_count >= MAX_UNIT_MODELS) return;
    // Deduplicate
    for (frame_unit_models[0..frame_unit_model_count]) |m| {
        if (m == model_ptr) return;
    }
    frame_unit_models[frame_unit_model_count] = model_ptr;
    frame_unit_model_count += 1;
}

fn addEntry(model_ptr: u32, cat: types.ModelCategory, mark: u8) void {
    if (frame_outline_count >= MAX_OUTLINE_MODELS) return;
    frame_outlines[frame_outline_count] = .{
        .model_ptr = model_ptr,
        .category = cat,
        .raid_mark = mark,
    };
    frame_outline_count += 1;
}

// =============================================================================
// Per-frame scan (called from EndScene)
// =============================================================================

/// Scan all visible objects and rebuild tracking lists.
pub fn scanObjects() void {
    // Clear per-frame model sets
    frame_outline_count = 0;
    frame_unit_model_count = 0;

    // Clear persistent tracking (rebuilt every frame from scan)
    dead_guid_count = 0;
    raid_mark_count = 0;
    target_guid_val = 0;

    if (!wow.isInGame()) return;
    const local_player = wow.getLocalPlayer();
    if (local_player == 0) return;

    // Cache raid target GUIDs
    wow.cacheRaidTargets();

    // Read target GUID
    target_guid_val = wow.getTargetGUID();

    // Iterate all visible objects
    var obj = wow.objectFirst();
    while (obj != 0) : (obj = wow.objectNext(obj)) {
        const obj_type = wow.getObjectType(obj);
        const guid = wow.getObjectGUID(obj);
        if (guid == 0) continue;

        switch (obj_type) {
            .player => {
                // Dead friendly players → through-wall outline
                if (wow.isUnitDead(obj) and wow.isUnitFriendly(obj, local_player)) {
                    addDeadGUID(guid);
                }
                // Raid marks
                addRaidMarkIfMarked(guid);
            },
            .unit => {
                // Raid marks on NPCs
                addRaidMarkIfMarked(guid);
            },
            .corpse => {
                // Non-skeleton corpses owned by players
                if (!wow.isSkeletonCorpse(obj)) {
                    const owner_guid = wow.getCorpseOwnerGUID(obj);
                    if (owner_guid != 0) addDeadGUID(owner_guid);
                }
            },
            else => {},
        }
    }
}

fn addDeadGUID(guid: u64) void {
    if (guid == 0 or dead_guid_count >= MAX_DEAD_GUIDS) return;
    // Deduplicate
    for (dead_guids[0..dead_guid_count]) |dg| {
        if (dg == guid) return;
    }
    dead_guids[dead_guid_count] = guid;
    dead_guid_count += 1;
}

fn addRaidMarkIfMarked(guid: u64) void {
    const mark = wow.getRaidMarkForGUID(guid);
    if (mark == 0 or raid_mark_count >= MAX_RAID_MARKS) return;
    // Deduplicate
    for (raid_mark_guids[0..raid_mark_count]) |rg| {
        if (rg == guid) return;
    }
    raid_mark_guids[raid_mark_count] = guid;
    raid_mark_indices[raid_mark_count] = mark;
    raid_mark_count += 1;
}
