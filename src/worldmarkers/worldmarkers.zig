//! Client-side world marker system
//!
//! Manages up to 5 colored markers placed at world positions.
//! Uses CreateEntityInstance_WithAttachment (0x6707c0) for entity lifecycle.
//! Markers persist across zone transitions via MarkerDef definitions.
//! Entities are respawned automatically when the player approaches within 200y.
//!
//! Lua API (globals):
//!   WorldMarker(index, x, y, z)     - place marker at coordinates
//!   WorldMarker(index, "unit")      - place marker at unit's position
//!   WorldMarker(index)              - place marker at cursor terrain position
//!   ClearWorldMarker(index)         - remove specific marker (1-5)
//!   ClearWorldMarker()              - remove all markers
//!   CanSetWorldMarkers()            - returns 1 if leader/assist, nil otherwise
//!
//! Lua API (WorldMarkers table - internal, used by addon):
//!   WorldMarkers.SetMarkerDef(i, x, y, z, area, sender)
//!   WorldMarkers.ClearMarkerDef([index,] sender)
//!   WorldMarkers.GetMarkerDef(index) - returns x, y, z, areaId or nil

const std = @import("std");
const hook = @import("zhook");
const lua = @import("../lua.zig");
const o = @import("offsets.zig");
const offsets = @import("../offsets.zig");
const wow = @import("../wow.zig");
const logging = @import("../logging.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
extern "kernel32" fn GetTickCount() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "worldmarkers";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

/// True if this DLL instance owns the world markers hooks and Lua API is safe to use.
pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Constants
// =============================================================================

const NUM_MARKERS = 5;
const MARKER_Z_OFFSET: f32 = 2.0;

// M2 animation IDs for Raid_UI_FX models (not standard Birth/Death)
const ANIM_STAND: u32 = 0; // 4000ms grow-in (bones scale from 1x to full)
const ANIM_HOLD: u32 = 158; // sustained idle at full scale (loops)
const ANIM_DECAY: u32 = 159; // 666ms shrink-out
const DECAY_DURATION_MS: u32 = 650; // slightly over 666ms to ensure animation completes

const MODEL_PATHS = [NUM_MARKERS][*:0]const u8{
    "Spells\\Raid_UI_FX_Cyan.m2", // 1 - Blue Square
    "Spells\\Raid_UI_FX_Green.m2", // 2 - Green Triangle
    "Spells\\Raid_UI_FX_Purple.m2", // 3 - Purple Diamond
    "Spells\\Raid_UI_FX_Red.m2", // 4 - Red Cross
    "Spells\\Raid_UI_FX_Yellow.m2", // 5 - Yellow Star
};

// =============================================================================
// Types
// =============================================================================

pub const Vec3 = wow.Vec3;

// =============================================================================
// State
// =============================================================================

/// Persistent marker definition - survives zone transitions.
const MarkerDef = struct {
    pos: Vec3,
    area_id: u32,
    active: bool,
};
const EMPTY_DEF: MarkerDef = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .area_id = 0, .active = false };

/// Marker definitions persist across zone transitions (NOT cleared in worldCleanupDetour).
var marker_defs: [NUM_MARKERS]MarkerDef = .{EMPTY_DEF} ** NUM_MARKERS;

/// Transient entity state - cleared on zone transition / teardown.
var marker_entities: [NUM_MARKERS]?*anyopaque = .{null} ** NUM_MARKERS;
var marker_created_tick: [NUM_MARKERS]u32 = .{0} ** NUM_MARKERS;
var hold_queued: [NUM_MARKERS]bool = .{false} ** NUM_MARKERS;

// Proximity respawn constants
const RESPAWN_DISTANCE_SQ: f32 = 200.0 * 200.0;

// Throttle timers for respawn checks
var last_respawn_tick: u32 = 0;
const RESPAWN_CHECK_INTERVAL_MS: u32 = 1000;
var last_zombie_tick: u32 = 0;
const ZOMBIE_CHECK_INTERVAL_MS: u32 = 3000;

// Entities playing their Decay animation before destruction.
// Cleaned up every frame by tickAnimations (via OnWorldUpdate hook).
const MAX_DESPAWNING = 8;
const DespawningEntity = struct {
    entity: *anyopaque,
    start_tick: u32,
};
var despawning: [MAX_DESPAWNING]?DespawningEntity = .{null} ** MAX_DESPAWNING;

// =============================================================================
// Permission check - leader or raid officer required
// =============================================================================

// =============================================================================
// Battleground detection
// =============================================================================

/// Check if the current map is a battleground by reading Map.dbc mapType.
/// Uses: ObjMgr+0xCC → mapId, then Map.dbc[mapId] → row, row+0x04 → mapType.
fn isInBattleground() bool {
    return wow.isInBattleground();
}

// =============================================================================
// Permission check - leader or raid officer required
// =============================================================================

/// Check if the local player has permission to place/clear markers.
/// Uses direct memory reads - no Lua state required.
/// Requires: party leader, raid leader, or raid officer (assist).
fn canSetMarkers() bool {
    const player_guid = wow.getPlayerGUID();
    if (player_guid == 0) return false;

    const raid_count = hook.readMem(u32, o.RAID_MEMBER_COUNT);
    if (raid_count > 0) {
        // Raid: check if player is leader or has rank > 0 (officer/assist)
        const count = @min(raid_count, 40);
        for (0..count) |i| {
            const entry = hook.readMem(u32, o.RAID_ROSTER_ARRAY + i * 4);
            if (entry == 0 or entry < 0x10000) continue;
            if (wow.readGUID(entry) == player_guid) {
                return hook.readMem(i32, entry + o.ROSTER_ENTRY_RANK) > 0;
            }
        }
        return false;
    }

    // Party: check if player is the leader
    const leader_guid = wow.readGUID(o.LEADER_GUID);
    return leader_guid != 0 and player_guid == leader_guid;
}

/// Check if a named sender has permission (leader or raid officer).
/// Used to authenticate incoming addon messages - sender name comes from
/// CHAT_MSG_ADDON arg4 (server-verified, can't be spoofed).
fn senderHasPermission(sender: [*:0]const u8) bool {
    const sender_span = std.mem.span(sender);
    if (sender_span.len == 0) return false;

    const raid_count = hook.readMem(u32, o.RAID_MEMBER_COUNT);
    if (raid_count > 0) {
        // Raid: find sender in roster, check rank > 0
        const count = @min(raid_count, 40);
        for (0..count) |i| {
            const entry = hook.readMem(u32, o.RAID_ROSTER_ARRAY + i * 4);
            if (entry == 0 or entry < 0x10000) continue;
            const rank = hook.readMem(i32, entry + o.ROSTER_ENTRY_RANK);
            if (rank <= 0) continue; // skip non-officers
            const name_ptr = wow.getNameByGUID(wow.readGUID(entry));
            if (std.mem.eql(u8, std.mem.span(name_ptr), sender_span)) {
                return true;
            }
        }
        return false;
    }

    // Party: check if sender is the leader
    const leader_guid = wow.readGUID(o.LEADER_GUID);
    if (leader_guid == 0) return false;
    const leader_name = wow.getNameByGUID(leader_guid);
    return std.mem.eql(u8, std.mem.span(leader_name), sender_span);
}

// =============================================================================
// Position helpers
// =============================================================================

pub fn getUnitPosition(unit: u32) Vec3 {
    return wow.getUnitPosition(unit);
}

/// Resolve a unit ID string ("player", "target", etc.) to a world position.
fn resolveUnitPosition(unit_id: [*:0]const u8) ?Vec3 {
    const guid = wow.unitGUID(unit_id);
    if (guid == 0) return null;
    const obj = wow.getObjectByGUID(guid);
    if (obj == 0) return null;
    const pos = getUnitPosition(obj);
    if (pos.x == 0 and pos.y == 0 and pos.z == 0) return null;
    return pos;
}

/// Get the world position under the mouse cursor via UpdateHitTest.
/// For terrain/WMO hits (type 0), uses the intersection point directly.
/// For object hits (type 2), re-raycasts with terrain-only flags (0) to get
/// the terrain position behind the object, since object intersection coords
/// are unreliable and GOs lack a movement struct for position lookup.
fn getCursorTerrainPosition() ?Vec3 {
    const world_frame = hook.readMem(u32, o.PTR_WORLD_FRAME);
    if (world_frame == 0 or world_frame < 0x10000) return null;

    // Zero the intersection point before raycasting so we can detect "no hit"
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_X)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Y)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Z)).* = 0;

    // UpdateHitTest - __fastcall(ECX=worldFrame)
    hook.call(fn (u32) callconv(hook.cc.fastcall) void, o.FN_UPDATE_HIT_TEST, .{world_frame});

    const hit_type = hook.readMem(u32, world_frame + o.WF_HIT_TYPE);

    if (hit_type == 2) {
        // Object hit — re-raycast with flags=0 (terrain/WMO only) to get the
        // terrain position behind the object.
        const ray_start: u32 = world_frame + o.WF_RAY_START;
        const ray_end: u32 = world_frame + o.WF_RAY_END;

        // WorldIntersectionTest: __thiscall(ECX=worldFrame, rayStart*, rayEnd*, flags, hitResult*)
        // HitTestResult is 0x34 bytes; hit position Vec3 at +0x08.
        var result_buf = [_]u8{0} ** 0x34;
        const result_ptr = @intFromPtr(&result_buf);

        _ = hook.call(
            fn (u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) u32,
            o.FN_WORLD_INTERSECTION_TEST,
            .{ world_frame, ray_start, ray_end, @as(u32, 0), result_ptr },
        );

        const tx = @as(*align(1) const f32, @ptrFromInt(result_ptr + 0x08)).*;
        const ty = @as(*align(1) const f32, @ptrFromInt(result_ptr + 0x0C)).*;
        const tz = @as(*align(1) const f32, @ptrFromInt(result_ptr + 0x10)).*;

        log.fmt("hitTest: object hit, terrain re-raycast pos={d:.1},{d:.1},{d:.1}\n", .{ tx, ty, tz });

        if (tx == 0 and ty == 0 and tz == 0) return null;
        return .{ .x = tx, .y = ty, .z = tz };
    }

    const x = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_X);
    const y = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Y);
    const z = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Z);

    log.fmt("hitTest: type={d} pos={d:.1},{d:.1},{d:.1}\n", .{ hit_type, x, y, z });

    if (x == 0 and y == 0 and z == 0) return null;

    return .{ .x = x, .y = y, .z = z };
}

// =============================================================================
// Game function wrappers
// =============================================================================

/// CreateEntityInstance_WithAttachment - __fastcall, RET 0x14.
fn createEntityInstance(path: [*:0]const u8, pos: *[3]f32, facing: f32, flags: u32, update_now: u32) ?*anyopaque {
    const result = hook.call(fn ([*:0]const u8, *[3]f32, f32, u32, u32, u32, u32) callconv(hook.cc.fastcall) u32, o.FN_CREATE_ENTITY_INSTANCE, .{
        path, pos, facing, flags, update_now, 0, 0,
    });
    return if (result != 0) @ptrFromInt(result) else null;
}

/// CleanupEntity_ProcessAttachments - __fastcall(ECX=entity), no stack params.
fn cleanupEntity(obj: *anyopaque) void {
    hook.call(fn (*anyopaque) callconv(hook.cc.fastcall) void, o.FN_CLEANUP_ENTITY, .{obj});
}

// =============================================================================
// Animation
// =============================================================================

/// Play an animation on an entity's M2 model render context (entity+0x88).
/// CM2Model__PlayBoneAnimation - __thiscall(ECX=model), RET 0x1c.
fn playAnimation(entity: *anyopaque, anim_id: u32, queue: bool) void {
    const entity_addr = @intFromPtr(entity);
    const model = hook.readMem(u32, entity_addr + 0x88);
    if (model == 0 or model < 0x10000) return;

    hook.call(fn (u32, u32, u32, i32, u32, u32, u32, u32) callconv(hook.cc.thiscall) void, o.FN_PLAY_BONE_ANIMATION, .{
        model, 0xFFFFFFFF, anim_id, -1, 0, @as(u32, @bitCast(@as(f32, 1.0))), 1, @intFromBool(queue),
    });
}

/// Clean up despawning entities whose Decay animation has finished.
fn cleanupDespawning() void {
    const now = GetTickCount();
    for (&despawning) |*slot| {
        if (slot.*) |d| {
            if (now -% d.start_tick >= DECAY_DURATION_MS) {
                cleanupEntity(d.entity);
                slot.* = null;
            }
        }
    }
}

/// Force-cleanup all despawning entities immediately (for shutdown).
fn forceCleanupDespawning() void {
    for (&despawning) |*slot| {
        if (slot.*) |d| {
            cleanupEntity(d.entity);
            slot.* = null;
        }
    }
}

/// Start despawn animation and defer entity destruction.
fn beginDespawn(entity: *anyopaque) void {
    playAnimation(entity, ANIM_DECAY, true);

    // Find a free despawning slot
    for (&despawning) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .entity = entity, .start_tick = GetTickCount() };
            return;
        }
    }
    // All slots full - force-cleanup the oldest and reuse slot 0
    if (despawning[0]) |old| {
        cleanupEntity(old.entity);
    }
    despawning[0] = .{ .entity = entity, .start_tick = GetTickCount() };
}

// =============================================================================
// Marker management
// =============================================================================

/// Place a marker at the given world position. Replaces any existing marker in that slot.
/// Also stores the definition so the marker survives zone transitions.
/// index is 0-based (0..4).
fn placeMarker(index: usize, pos: Vec3) bool {
    if (index >= NUM_MARKERS) return false;

    // Clear existing entity in this slot (but not the def - we're about to overwrite it)
    clearEntity(index);

    // Store persistent definition
    marker_defs[index] = .{
        .pos = pos,
        .area_id = hook.readMem(u32, offsets.ZONE_AREA_ID),
        .active = true,
    };

    return spawnEntity(index, pos);
}

/// Spawn a marker entity without touching marker_defs. Used by both
/// placeMarker (initial placement) and the proximity respawn system.
fn spawnEntity(index: usize, pos: Vec3) bool {
    var position = [3]f32{ pos.x, pos.y, pos.z + MARKER_Z_OFFSET };

    const obj = createEntityInstance(MODEL_PATHS[index], &position, 0.0, 0, 1) orelse {
        log.fmt("failed to create marker {d}\n", .{index + 1});
        return false;
    };

    // UpdateWorldPosition (called by createEntityInstance with updateNow=1) snaps
    // the position to the terrain chunk grid, modifying the position array in place.
    // Re-apply the exact position via SetUnitPositionAndOrientation to override the snap.
    position = [3]f32{ pos.x, pos.y, pos.z + MARKER_Z_OFFSET };
    setUnitPositionAndOrientation(obj, &position, 0.0);

    marker_entities[index] = obj;
    marker_created_tick[index] = GetTickCount();
    hold_queued[index] = false;

    log.fmt("marker {d} spawned at {d:.1}, {d:.1}, {d:.1} @0x{x}\n", .{
        index + 1, pos.x, pos.y, pos.z, @intFromPtr(obj),
    });
    return true;
}

/// SetUnitPositionAndOrientation - __fastcall(ECX=positionData, EDX=pos), 1 stack param.
fn setUnitPositionAndOrientation(entity: *anyopaque, pos: *[3]f32, facing: f32) void {
    hook.call(fn (*anyopaque, *[3]f32, f32) callconv(hook.cc.fastcall) void, 0x698e20, .{ entity, pos, facing });
}

/// Remove only the live entity for a marker slot (def untouched).
/// Used internally before respawn/replacement.
fn clearEntity(index: usize) void {
    if (index >= NUM_MARKERS) return;
    cleanupDespawning();
    if (marker_entities[index]) |existing| {
        beginDespawn(existing);
        marker_entities[index] = null;
        hold_queued[index] = false;
    }
}

/// Remove a specific marker (entity + definition). index is 0-based.
fn clearMarker(index: usize) void {
    if (index >= NUM_MARKERS) return;
    clearEntity(index);
    marker_defs[index] = EMPTY_DEF;
}

/// Remove all markers (entities + definitions).
fn clearAllMarkers() void {
    cleanupDespawning();
    var any = false;
    for (0..NUM_MARKERS) |i| {
        if (marker_entities[i]) |existing| {
            beginDespawn(existing);
            marker_entities[i] = null;
            any = true;
        }
        marker_defs[i] = EMPTY_DEF;
    }
    if (any) log.print("all markers cleared\n");
}

// =============================================================================
// Lua API
// =============================================================================

/// Lua: local x,y,z,areaId = WorldMarker(index [, x, y, z | "unitId"])
///   Returns x,y,z,areaId on success, nil on permission denied, -1 on placement failure.
pub fn luaWorldMarker(L: lua.State) callconv(.c) u32 {
    if (isInBattleground()) {
        lua.pushnumber(L, -2.0);
        return 1;
    }
    if (!canSetMarkers()) {
        log.print("WorldMarker: no permission\n");
        return 0; // nil - addon shows permission message
    }

    const nargs = lua.gettop(L);

    if (nargs < 1 or !lua.isnumber(L, 1)) {
        log.print("WorldMarker: expected index (1-5)\n");
        lua.pushnumber(L, -1.0);
        return 1;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        log.print("WorldMarker: index must be 1-5\n");
        lua.pushnumber(L, -1.0);
        return 1;
    }
    const index: usize = @intCast(raw_index - 1);

    if (nargs >= 4 and lua.isnumber(L, 2)) {
        const x: f32 = @floatCast(lua.tonumber(L, 2));
        const y: f32 = @floatCast(lua.tonumber(L, 3));
        const z: f32 = @floatCast(lua.tonumber(L, 4));
        if (!placeMarker(index, .{ .x = x, .y = y, .z = z })) {
            lua.pushnumber(L, -1.0);
            return 1;
        }
    } else if (nargs >= 2 and lua.isstring(L, 2)) {
        const unit_id = lua.tostring(L, 2) orelse {
            log.print("WorldMarker: invalid unit string\n");
            lua.pushnumber(L, -1.0);
            return 1;
        };
        const pos = resolveUnitPosition(unit_id) orelse {
            log.fmt("WorldMarker: unit '{s}' not found\n", .{std.mem.span(unit_id)});
            lua.pushnumber(L, -1.0);
            return 1;
        };
        if (!placeMarker(index, pos)) {
            lua.pushnumber(L, -1.0);
            return 1;
        }
    } else {
        const pos = getCursorTerrainPosition() orelse {
            log.print("no terrain under cursor\n");
            lua.pushnumber(L, -1.0);
            return 1;
        };
        if (!placeMarker(index, pos)) {
            lua.pushnumber(L, -1.0);
            return 1;
        }
    }

    return pushMarkerDef(L, index);
}

/// Lua: local ok = ClearWorldMarker([index])
///   Returns 1 on success, nil on permission denied.
pub fn luaClearWorldMarker(L: lua.State) callconv(.c) u32 {
    if (!canSetMarkers()) {
        log.print("ClearWorldMarker: no permission\n");
        return 0;
    }

    const nargs = lua.gettop(L);
    const lua_type: *const fn (lua.State, i32) callconv(hook.cc.fastcall) i32 = @ptrFromInt(0x6F3400);

    if (nargs == 0 or lua_type(L, 1) == 0) {
        // No args or nil - clear all
        clearAllMarkers();
        lua.pushnumber(L, 1.0);
        return 1;
    }

    if (!lua.isnumber(L, 1)) {
        log.print("ClearWorldMarker: expected index (1-5) or nil\n");
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        log.print("ClearWorldMarker: index must be 1-5\n");
        return 0;
    }

    clearMarker(@intCast(raw_index - 1));
    lua.pushnumber(L, 1.0);
    return 1;
}

// Delay before queuing Hold after Stand starts. Too short (<1s) causes the
// engine's blend logic to accelerate Stand; too long and there's a visible gap.
// 2000ms was empirically determined as the shortest delay that preserves
// Stand's full-speed grow-in animation across all 5 marker colors.
const HOLD_QUEUE_DELAY_MS: u32 = 2000;

/// Per-frame tick (driven by OnWorldUpdate hook).
/// 1. Queue Hold animation after Stand grow-in completes
/// 2. Clean up despawning entities
/// 3. Detect zombie entities (culled by the game) and destroy them
/// 4. Respawn markers near the player from persistent definitions
fn tickAnimations() void {
    const now = GetTickCount();

    cleanupDespawning();

    // Queue Hold animation for freshly-created markers
    for (0..NUM_MARKERS) |i| {
        if (hold_queued[i]) continue;
        const entity = marker_entities[i] orelse continue;
        if (now -% marker_created_tick[i] < HOLD_QUEUE_DELAY_MS) continue;

        playAnimation(entity, ANIM_HOLD, true);
        hold_queued[i] = true;
    }

    // Zombie detection - entity exists but refcount dropped to 1 (culled by game).
    // Check every 3 seconds to avoid per-frame overhead.
    if (now -% last_zombie_tick >= ZOMBIE_CHECK_INTERVAL_MS) {
        last_zombie_tick = now;
        for (0..NUM_MARKERS) |i| {
            const entity = marker_entities[i] orelse continue;
            const addr = @intFromPtr(entity);
            const refcount = hook.readMem(u16, addr + 0x0E);
            if (refcount <= 1) {
                log.fmt("zombie detected [{d}] @0x{x} rc={d}, destroying\n", .{ i + 1, addr, refcount });
                cleanupEntity(entity);
                marker_entities[i] = null;
                hold_queued[i] = false;
            }
        }
    }

    // Proximity respawn - check every ~1 second
    if (now -% last_respawn_tick >= RESPAWN_CHECK_INTERVAL_MS) {
        last_respawn_tick = now;

        const player = wow.getLocalPlayer();
        if (player != 0) {
            const player_pos = getUnitPosition(player);
            if (player_pos.x != 0 or player_pos.y != 0 or player_pos.z != 0) {
                const current_area = hook.readMem(u32, offsets.ZONE_AREA_ID);
                for (0..NUM_MARKERS) |i| {
                    if (!marker_defs[i].active) continue;
                    if (marker_entities[i] != null) continue; // entity alive, skip
                    if (marker_defs[i].area_id != current_area) continue; // wrong zone

                    const dx = player_pos.x - marker_defs[i].pos.x;
                    const dy = player_pos.y - marker_defs[i].pos.y;
                    const dz = player_pos.z - marker_defs[i].pos.z;
                    const dist_sq = dx * dx + dy * dy + dz * dz;

                    if (dist_sq < RESPAWN_DISTANCE_SQ) {
                        log.fmt("respawning [{d}] dist={d:.0}\n", .{ i + 1, @sqrt(dist_sq) });
                        _ = spawnEntity(i, marker_defs[i].pos);
                    }
                }
            }
        }
    }
}

/// Lua: SetMarkerDef(index, x, y, z, areaId, senderName)
/// Store a marker definition without immediately spawning. Used by the addon
/// when receiving remote marker data - proximity respawn handles entity creation.
/// senderName is verified against the group roster for leader/officer permission.
pub fn luaSetMarkerDef(L: lua.State) callconv(.c) u32 {
    if (isInBattleground()) return 0;
    const nargs = lua.gettop(L);
    if (nargs < 6) return 0;
    if (!lua.isnumber(L, 1) or !lua.isnumber(L, 2) or !lua.isnumber(L, 3) or !lua.isnumber(L, 4) or !lua.isnumber(L, 5) or !lua.isstring(L, 6)) return 0;

    const sender = lua.tostring(L, 6) orelse return 0;
    if (!senderHasPermission(sender)) {
        log.fmt("SetMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;
    const index: usize = @intCast(raw_index - 1);

    const x: f32 = @floatCast(lua.tonumber(L, 2));
    const y: f32 = @floatCast(lua.tonumber(L, 3));
    const z: f32 = @floatCast(lua.tonumber(L, 4));
    const area_id: u32 = @intFromFloat(lua.tonumber(L, 5));

    // Clear existing entity if any (will be respawned by proximity check)
    clearEntity(index);

    marker_defs[index] = .{
        .pos = .{ .x = x, .y = y, .z = z },
        .area_id = area_id,
        .active = true,
    };

    log.fmt("SetMarkerDef [{d}] at {d:.1},{d:.1},{d:.1} area={d}\n", .{ index + 1, x, y, z, area_id });
    return 0;
}

/// Lua: ClearMarkerDef(senderName) - clear all
/// Lua: ClearMarkerDef(index, senderName) - clear one
/// senderName is verified against the group roster for leader/officer permission.
pub fn luaClearMarkerDef(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 1) return 0;

    if (lua.isstring(L, 1) and (nargs == 1 or !lua.isnumber(L, 1))) {
        // ClearMarkerDef(senderName) - clear all
        const sender = lua.tostring(L, 1) orelse return 0;
        if (!senderHasPermission(sender)) {
            log.fmt("ClearMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
            return 0;
        }
        clearAllMarkers();
        return 0;
    }

    if (nargs >= 2 and lua.isnumber(L, 1) and lua.isstring(L, 2)) {
        // ClearMarkerDef(index, senderName) - clear one
        const sender = lua.tostring(L, 2) orelse return 0;
        if (!senderHasPermission(sender)) {
            log.fmt("ClearMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
            return 0;
        }
        const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
        if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;
        clearMarker(@intCast(raw_index - 1));
        return 0;
    }

    return 0;
}

/// Push x, y, z, areaId for a marker slot, or return 0 (nil) if inactive.
fn pushMarkerDef(L: lua.State, index: usize) u32 {
    if (!marker_defs[index].active) return 0;

    lua.pushnumber(L, @floatCast(marker_defs[index].pos.x));
    lua.pushnumber(L, @floatCast(marker_defs[index].pos.y));
    lua.pushnumber(L, @floatCast(marker_defs[index].pos.z));
    lua.pushnumber(L, @floatCast(@as(f64, @floatFromInt(marker_defs[index].area_id))));
    return 4;
}

/// Lua: local x, y, z, areaId = GetWorldMarker(index)
/// Returns position and area ID for an active marker, or nil if empty.
pub fn luaGetWorldMarker(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 1 or !lua.isnumber(L, 1)) return 0;

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;

    return pushMarkerDef(L, @intCast(raw_index - 1));
}

/// Lua: local x, y, z, areaId = WorldMarkers.GetMarkerDef(index)
/// Internal alias kept for addon sync protocol compatibility.
pub fn luaGetMarkerDef(L: lua.State) callconv(.c) u32 {
    return luaGetWorldMarker(L);
}

/// Lua: local ok = CanSetWorldMarkers()
/// Returns 1 if the local player has permission (leader/assist), nil otherwise.
/// Used by the addon for broadcast/sync decisions.
pub fn luaCanSetMarkers(L: lua.State) callconv(.c) u32 {
    if (isInBattleground()) return 0;
    if (canSetMarkers()) {
        lua.pushnumber(L, 1.0);
        return 1;
    }
    return 0;
}

// =============================================================================
// World teardown hook
// =============================================================================

var world_cleanup_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};
var world_update_hook: hook.Detour(fn (u32) callconv(hook.cc.fastcall) void) = .{};

/// OnWorldUpdate hook - per-frame tick while world is active.
/// Drives animation state (Hold queue after Stand, despawn cleanup).
fn worldUpdateDetour(frame: u32) callconv(hook.cc.fastcall) void {
    tickAnimations();
    world_update_hook.callOriginal(.{frame});
}

/// Pre-hook on CleanupWorldAndEntities (0x66fc40).
/// Destroys all our entities via CleanupEntity_ProcessAttachments before the
/// game's teardown runs - the same pattern every native caller uses (e.g.
/// processCinematicExit, DestroyPathObjectIfPresent). This unlinks them from
/// the WDOODADDEF hash table so the atexit handler never touches freed memory.
fn worldCleanupDetour() callconv(hook.cc.stdcall) void {
    log.print(">>> worldCleanupDetour FIRING <<<\n");
    destroyAllEntities();
    world_cleanup_hook.callOriginal(.{});
}

/// Destroy all tracked entities (active markers + despawning).
/// Does NOT clear marker_defs - definitions persist for respawn.
/// Idempotent - safe to call multiple times.
fn destroyAllEntities() void {
    var count: u32 = 0;
    for (&marker_entities, 0..) |*slot, i| {
        if (slot.*) |existing| {
            const addr = @intFromPtr(existing);
            log.fmt("destroying marker[{d}] @0x{x}\n", .{ i, addr });
            cleanupEntity(existing);
            slot.* = null;
            count += 1;
        }
    }
    for (&hold_queued) |*h| h.* = false;
    for (&marker_created_tick) |*t| t.* = 0;

    for (&despawning, 0..) |*slot, i| {
        if (slot.*) |d| {
            const addr = @intFromPtr(d.entity);
            log.fmt("destroying despawn[{d}] @0x{x}\n", .{ i, addr });
            cleanupEntity(d.entity);
            slot.* = null;
            count += 1;
        }
    }

    if (count > 0) {
        log.fmt("world cleanup: destroyed {d} entities\n", .{count});
    }
}

// =============================================================================
// Install hooks
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
    log = logging.Logger.open(module_name, .console);

    // Hook OnWorldUpdate for per-frame animation tick (runs every frame while world is active).
    if (world_update_hook.attach(o.FN_ON_WORLD_UPDATE, &worldUpdateDetour) != .ok) {
        log.print("FAILED to hook OnWorldUpdate!\n");
    } else {
        log.print("hooked OnWorldUpdate OK\n");
    }

    // Hook CleanupWorldAndEntities to destroy our entities before world teardown.
    // This fires on map change, logout, AND exit - before heaps are destroyed.
    if (world_cleanup_hook.attach(o.FN_CLEANUP_WORLD_AND_ENTITIES, &worldCleanupDetour) != .ok) {
        log.print("FAILED to hook CleanupWorldAndEntities!\n");
    } else {
        log.print("hooked CleanupWorldAndEntities OK\n");
    }
}

/// Called from CGGameUI_Shutdown (logout/exit) - wipes marker definitions.
/// Does NOT touch hooks or mutex. Entities are destroyed separately by
/// worldCleanupDetour which fires after shutdown.
pub fn onShutdown() void {
    for (&marker_defs) |*d| d.* = EMPTY_DEF;
    log.print("defs cleared (shutdown)\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // destroyAllEntities is idempotent - if worldCleanupDetour already ran,
        // all slots are null and this is a no-op.
        destroyAllEntities();
        world_update_hook.detach();
        world_cleanup_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
