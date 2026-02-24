//! Per-frame model tracking for the outline system.
//!
//! Maintains fixed-size arrays of tracked object pointers (target, raid marks,
//! dead players) and the per-frame set of outline model entries.
//! All state is single-threaded (main WoW thread) — no synchronisation needed.
//!
//! Model classification uses forward mapping: scanObjects stores object pointers
//! from the object manager, then classifyModel (ManageRenderListNode) reads the
//! model's back-pointers (model+0x28, model+0x3C0) and compares them against
//! known object pointers.  No dereferencing of unknown memory — just value
//! comparison against the object manager's validated set.

const hook = @import("hook");
const wow = @import("wow.zig");
const o = @import("offsets.zig");
const types = @import("types.zig");

// =============================================================================
// Tracking limits
// =============================================================================

const MAX_TRACKED_OBJS = 128;
const MAX_UNIT_OBJS = 512;
const MAX_OUTLINE_MODELS = 256;

// =============================================================================
// Tracked object set (populated by scanObjects from the object manager)
// =============================================================================
// Stores obj_ptr + category for entities we want to outline.
// classifyModel matches model back-pointers against these — no pointer chasing.

const TrackedObj = struct {
    obj_ptr: u32,
    category: types.ModelCategory,
    raid_mark: u8,
};

var tracked_objs: [MAX_TRACKED_OBJS]TrackedObj = undefined;
pub var tracked_obj_count: usize = 0;

// All unit/player object pointers for stencil occlusion detection.
var unit_obj_ptrs: [MAX_UNIT_OBJS]u32 = .{0} ** MAX_UNIT_OBJS;
var unit_obj_count: usize = 0;

// =============================================================================
// Per-frame outline model set (populated by ManageRenderListNode hook)
// =============================================================================

var frame_outlines: [MAX_OUTLINE_MODELS]types.OutlineEntry = undefined;
var frame_outline_count: usize = 0;

// Per-frame unit model cache (model pointers belonging to units).
var frame_unit_models: [MAX_UNIT_OBJS]u32 = .{0} ** MAX_UNIT_OBJS;
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

/// Classify a model by comparing its back-pointers against known object pointers.
/// Safe: only reads from the model struct (which WoW just handed us via the
/// ManageRenderListNode __thiscall), then compares values — never dereferences
/// the back-pointer values as pointers.
pub fn classifyModel(model_ptr: u32) void {
    if (model_ptr == 0 or !enabled) return;

    // Read the model's back-pointers to its owning game object.
    // Safe reads: the model struct is guaranteed valid — WoW is calling
    // ManageRenderListNode on it right now.  We read u32 values and
    // compare them; we never dereference these values as pointers.
    const owner_direct = hook.readMem(u32, model_ptr + o.MODEL_OWNER_DIRECT);
    const owner_callback = hook.readMem(u32, model_ptr + o.MODEL_OWNER_CALLBACK);

    // Match against tracked outline objects (target, raid marks, dead players).
    // Priority is implicit in insertion order: target first, then raid marks,
    // then dead players — first match wins.
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

    // Match against all unit/player objects for stencil occlusion.
    if (unit_obj_count > 0 and frame_unit_model_count < MAX_UNIT_OBJS) {
        for (unit_obj_ptrs[0..unit_obj_count]) |uptr| {
            if (owner_callback == uptr or owner_direct == uptr) {
                addUnitModel(model_ptr);
                break;
            }
        }
    }
}

fn addUnitModel(model_ptr: u32) void {
    if (frame_unit_model_count >= MAX_UNIT_OBJS) return;
    for (frame_unit_models[0..frame_unit_model_count]) |m| {
        if (m == model_ptr) return;
    }
    frame_unit_models[frame_unit_model_count] = model_ptr;
    frame_unit_model_count += 1;
}

fn addOutlineEntry(model_ptr: u32, cat: types.ModelCategory, mark: u8) void {
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

/// Scan all visible objects and build the tracked object pointer sets.
/// Stores object pointers directly so classifyModel can match model
/// back-pointers without any pointer dereferencing.
pub fn scanObjects() void {
    // Clear per-frame sets
    frame_outline_count = 0;
    frame_unit_model_count = 0;
    tracked_obj_count = 0;
    unit_obj_count = 0;

    if (!wow.isInGame()) return;
    const local_player = wow.getLocalPlayer();
    if (local_player == 0) return;

    // Cache raid target GUIDs
    wow.cacheRaidTargets();

    // Resolve target to object pointer (highest priority — added first)
    const target_guid = wow.getTargetGUID();
    if (target_guid != 0) {
        const target_obj = wow.getObjectByGUID(target_guid);
        if (target_obj != 0) {
            addTrackedObj(target_obj, .target, 0);
        }
    }

    // Iterate all visible objects
    var obj = wow.objectFirst();
    while (obj != 0) : (obj = wow.objectNext(obj)) {
        const obj_type = wow.getObjectType(obj);
        const guid = wow.getObjectGUID(obj);
        if (guid == 0) continue;

        switch (obj_type) {
            .player => {
                addUnitObjPtr(obj);

                if (wow.isUnitDead(obj) and wow.isUnitFriendly(obj, local_player)) {
                    addTrackedObj(obj, .dead_player, 0);
                }
                const mark = wow.getRaidMarkForGUID(guid);
                if (mark != 0) addTrackedObj(obj, .raid_marked, mark);
            },
            .unit => {
                addUnitObjPtr(obj);

                const mark = wow.getRaidMarkForGUID(guid);
                if (mark != 0) addTrackedObj(obj, .raid_marked, mark);
            },
            .corpse => {
                // Track the corpse object itself — its model's back-pointer
                // (model+0x28) should point back to this corpse object.
                if (!wow.isSkeletonCorpse(obj)) {
                    addTrackedObj(obj, .dead_player, 0);
                }
            },
            else => {},
        }
    }
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
}

fn addUnitObjPtr(obj_ptr: u32) void {
    if (obj_ptr == 0 or unit_obj_count >= MAX_UNIT_OBJS) return;
    unit_obj_ptrs[unit_obj_count] = obj_ptr;
    unit_obj_count += 1;
}
