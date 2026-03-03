//! Client-side world marker system
//!
//! Manages up to 5 colored markers placed at world positions.
//! Uses CreateEntityInstance_WithAttachment (0x6707c0) for entity lifecycle.
//! Markers persist across zone transitions via MarkerDef definitions.
//! Entities are respawned automatically when the player approaches within 200y.
//!
//! Lua API:
//!   WorldMarker(index, x, y, z)     — place marker at coordinates
//!   WorldMarker(index, "unit")      — place marker at unit's position
//!   WorldMarker(index)              — place marker at cursor terrain position
//!   ClearWorldMarker(index)         — remove specific marker (1-5)
//!   ClearWorldMarker()              — remove all markers
//!   SetMarkerDef(i, x, y, z, area) — store definition (no immediate spawn)
//!   ClearMarkerDef([index])         — clear definition (and entity)
//!   GetMarkerDef(index)             — returns x, y, z, areaId or nil

const std = @import("std");
const hook = @import("zhook");
const lua = @import("../lua.zig");
const o = @import("offsets.zig");
const wow = @import("../outline/wow.zig");
const con = @import("../console.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
extern "kernel32" fn GetTickCount() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

/// True if this DLL instance owns the markers hooks and Lua API is safe to use.
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

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

// =============================================================================
// State
// =============================================================================

/// Persistent marker definition — survives zone transitions.
const MarkerDef = struct {
    pos: Vec3,
    area_id: u32,
    active: bool,
};
const EMPTY_DEF: MarkerDef = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .area_id = 0, .active = false };

/// Marker definitions persist across zone transitions (NOT cleared in worldCleanupDetour).
var marker_defs: [NUM_MARKERS]MarkerDef = .{EMPTY_DEF} ** NUM_MARKERS;

/// Transient entity state — cleared on zone transition / teardown.
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

const fc = std.builtin.CallingConvention{ .x86_fastcall = .{} };
const sc = std.builtin.CallingConvention{ .x86_stdcall = .{} };

// =============================================================================
// Permission check — leader or raid officer required
// =============================================================================

/// Get local player GUID via GetPlayerGUID (0x468550).
/// __fastcall(), no params, returns EAX(low):EDX(high).
fn getPlayerGUID() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("call *%[func]"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [func] "r" (o.FN_GET_PLAYER_GUID),
        : .{ .ecx = true, .memory = true, .cc = true });
    return (@as(u64, hi) << 32) | lo;
}

/// Look up a player name from the name cache by GUID.
/// Calls RetrieveNPCDataFromCache — __thiscall(ECX=cache), 6 stack params, RET 0x18.
fn getNameFromGUID(guid_lo: u32, guid_hi: u32) ?[*:0]const u8 {
    if (guid_lo == 0 and guid_hi == 0) return null;
    var name_buf: [2]u32 = .{ 0, 0 };
    const stack_args = [6]u32{
        guid_lo,
        guid_hi,
        @intFromPtr(&name_buf),
        0, 0, 0,
    };
    const result: u32 = asm volatile (
        \\ push 20(%[a])
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, o.NAME_CACHE_OBJ)),
          [a] "r" (&stack_args),
          [func] "r" (@as(u32, o.FN_NAME_CACHE_LOOKUP)),
        : .{ .edx = true, .memory = true, .cc = true });
    return if (result != 0) @ptrFromInt(result) else null;
}

/// Check if the local player has permission to place/clear markers.
/// Uses direct memory reads — no Lua state required.
/// Requires: party leader, raid leader, or raid officer (assist).
fn canSetMarkers() bool {
    const player_guid = getPlayerGUID();
    if (player_guid == 0) return false;
    const player_lo: u32 = @truncate(player_guid);
    const player_hi: u32 = @truncate(player_guid >> 32);

    const raid_count = hook.readMem(u32, o.RAID_MEMBER_COUNT);
    if (raid_count > 0) {
        // Raid: check if player is leader or has rank > 0 (officer/assist)
        const count = @min(raid_count, 40);
        for (0..count) |i| {
            const entry = hook.readMem(u32, o.RAID_ROSTER_ARRAY + i * 4);
            if (entry == 0 or entry < 0x10000) continue;
            const guid_lo = hook.readMem(u32, entry);
            const guid_hi = hook.readMem(u32, entry + 4);
            if (guid_lo == player_lo and guid_hi == player_hi) {
                return hook.readMem(i32, entry + o.ROSTER_ENTRY_RANK) > 0;
            }
        }
        return false;
    }

    // Party: check if player is the leader
    const leader_lo = hook.readMem(u32, o.LEADER_GUID);
    const leader_hi = hook.readMem(u32, o.LEADER_GUID + 4);
    if (leader_lo == 0 and leader_hi == 0) return false;
    return player_lo == leader_lo and player_hi == leader_hi;
}

/// Check if a named sender has permission (leader or raid officer).
/// Used to authenticate incoming addon messages — sender name comes from
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
            const guid_lo = hook.readMem(u32, entry);
            const guid_hi = hook.readMem(u32, entry + 4);
            const name = getNameFromGUID(guid_lo, guid_hi) orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), sender_span)) {
                return true;
            }
        }
        return false;
    }

    // Party: check if sender is the leader
    const leader_lo = hook.readMem(u32, o.LEADER_GUID);
    const leader_hi = hook.readMem(u32, o.LEADER_GUID + 4);
    if (leader_lo == 0 and leader_hi == 0) return false;
    const leader_name = getNameFromGUID(leader_lo, leader_hi) orelse return false;
    return std.mem.eql(u8, std.mem.span(leader_name), sender_span);
}

/// Check if a named sender is in the group (any rank).
/// Weaker than senderHasPermission — used for sync relay (SF) where the
/// sender is just echoing stored data, not issuing a command.
fn senderInGroup(sender: [*:0]const u8) bool {
    const sender_span = std.mem.span(sender);
    if (sender_span.len == 0) return false;

    const raid_count = hook.readMem(u32, o.RAID_MEMBER_COUNT);
    if (raid_count > 0) {
        // Raid: find sender anywhere in roster (any rank)
        const count = @min(raid_count, 40);
        for (0..count) |i| {
            const entry = hook.readMem(u32, o.RAID_ROSTER_ARRAY + i * 4);
            if (entry == 0 or entry < 0x10000) continue;
            const guid_lo = hook.readMem(u32, entry);
            const guid_hi = hook.readMem(u32, entry + 4);
            const name = getNameFromGUID(guid_lo, guid_hi) orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), sender_span)) {
                return true;
            }
        }
        return false;
    }

    // Party: check if sender is any party member
    for (0..4) |i| {
        const guid_lo = hook.readMem(u32, o.PARTY_MEMBER_GUIDS + i * 8);
        const guid_hi = hook.readMem(u32, o.PARTY_MEMBER_GUIDS + i * 8 + 4);
        if (guid_lo == 0 and guid_hi == 0) continue;
        const name = getNameFromGUID(guid_lo, guid_hi) orelse continue;
        if (std.mem.eql(u8, std.mem.span(name), sender_span)) {
            return true;
        }
    }
    return false;
}

// =============================================================================
// Position helpers
// =============================================================================

pub fn getUnitPosition(unit: u32) Vec3 {
    if (unit == 0) return .{ .x = 0, .y = 0, .z = 0 };

    const movement = hook.readMem(u32, unit + o.UNIT_MOVEMENT_OFFSET);
    if (movement == 0 or movement < 0x10000) return .{ .x = 0, .y = 0, .z = 0 };

    return .{
        .x = hook.readMem(f32, movement + o.MOVEMENT_POS_X),
        .y = hook.readMem(f32, movement + o.MOVEMENT_POS_Y),
        .z = hook.readMem(f32, movement + o.MOVEMENT_POS_Z),
    };
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

/// Get the terrain position under the mouse cursor by calling UpdateHitTest.
/// This performs a camera-through-cursor raycast and stores the result at
/// worldFrame+0x350. Safe to call from Lua callbacks (saves/restores matrices).
fn getCursorTerrainPosition() ?Vec3 {
    const world_frame = hook.readMem(u32, o.PTR_WORLD_FRAME);
    if (world_frame == 0 or world_frame < 0x10000) return null;

    // Zero the intersection point before raycasting so we can detect "no hit"
    // (HitTestPoint returns 0 for both "terrain hit" and "no hit" in normal mode —
    // WorldIntersectionTest returns gameStateFlags & 1, which is 0 outside AoE targeting.
    // On a real hit the coords are overwritten; on sky/no-hit they stay zeroed.)
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_X)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Y)).* = 0;
    @as(*align(1) u32, @ptrFromInt(world_frame + o.WF_HIT_TERRAIN_Z)).* = 0;

    // UpdateHitTest — __fastcall(ECX=worldFrame)
    hook.fastcall(void, o.FN_UPDATE_HIT_TEST, world_frame, 0);

    const x = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_X);
    const y = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Y);
    const z = hook.readMem(f32, world_frame + o.WF_HIT_TERRAIN_Z);

    if (x == 0 and y == 0 and z == 0) return null;

    return .{ .x = x, .y = y, .z = z };
}

// =============================================================================
// Game function wrappers
// =============================================================================

/// CreateEntityInstance_WithAttachment — __fastcall, RET 0x14.
fn createEntityInstance(path: [*:0]const u8, pos: *[3]f32, facing: f32, flags: u32, update_now: u32) ?*anyopaque {
    const facing_bits: u32 = @bitCast(facing);
    const stack_args = [5]u32{
        facing_bits,
        flags,
        update_now,
        0,
        0,
    };

    const result: u32 = asm volatile (
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@intFromPtr(path)),
          [_] "{edx}" (@intFromPtr(pos)),
          [a] "r" (&stack_args),
          [func] "r" (o.FN_CREATE_ENTITY_INSTANCE),
        : .{ .memory = true, .cc = true });

    return if (result != 0) @ptrFromInt(result) else null;
}

/// CleanupEntity_ProcessAttachments — __fastcall(ECX=entity), no stack params.
fn cleanupEntity(obj: *anyopaque) void {
    asm volatile ("call *%[func]"
        :
        : [_] "{ecx}" (@intFromPtr(obj)),
          [func] "r" (o.FN_CLEANUP_ENTITY),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Animation
// =============================================================================

/// Play an animation on an entity's M2 model render context (entity+0x88).
/// CM2Model__PlayBoneAnimation — __thiscall(ECX=model), RET 0x1c.
fn playAnimation(entity: *anyopaque, anim_id: u32, queue: bool) void {
    const entity_addr = @intFromPtr(entity);
    const model = hook.readMem(u32, entity_addr + 0x88);
    if (model == 0 or model < 0x10000) return;

    const speed_bits: u32 = @bitCast(@as(f32, 1.0));
    const stack_args = [7]u32{
        0xFFFFFFFF, // boneIndex: all bones
        anim_id,
        @bitCast(@as(i32, -1)), // seqIndex: random
        0, // animData: NULL
        speed_bits, // speed: 1.0
        1, // blendMode: smooth blend
        @intFromBool(queue),
    };

    asm volatile (
        \\ push 24(%[a])
        \\ push 20(%[a])
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        :
        : [_] "{ecx}" (model),
          [a] "r" (&stack_args),
          [func] "r" (o.FN_PLAY_BONE_ANIMATION),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
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
    // All slots full — force-cleanup the oldest and reuse slot 0
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

    // Clear existing entity in this slot (but not the def — we're about to overwrite it)
    clearEntity(index);

    // Store persistent definition
    marker_defs[index] = .{
        .pos = pos,
        .area_id = hook.readMem(u32, o.ZONE_AREA_ID),
        .active = true,
    };

    return spawnEntity(index, pos);
}

/// Spawn a marker entity without touching marker_defs. Used by both
/// placeMarker (initial placement) and the proximity respawn system.
fn spawnEntity(index: usize, pos: Vec3) bool {
    var position = [3]f32{ pos.x, pos.y, pos.z + MARKER_Z_OFFSET };

    const obj = createEntityInstance(MODEL_PATHS[index], &position, 0.0, 0, 1) orelse {
        con.fmt("[markers] failed to create marker {d}\n", .{index + 1});
        return false;
    };

    marker_entities[index] = obj;
    marker_created_tick[index] = GetTickCount();
    hold_queued[index] = false;

    con.fmt("[markers] marker {d} spawned at {d:.1}, {d:.1}, {d:.1} @0x{x}\n", .{
        index + 1, pos.x, pos.y, pos.z, @intFromPtr(obj),
    });
    return true;
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
    if (any) con.print("[markers] all markers cleared\n");
}

// =============================================================================
// Lua API
// =============================================================================

/// Lua: local ok = WorldMarker(index [, x, y, z | "unitId"])
///   Returns 1 on success, nil on permission denied.
pub fn luaWorldMarker(L: lua.State) callconv(.c) u32 {
    if (!canSetMarkers()) {
        con.print("[markers] WorldMarker: no permission\n");
        return 0; // nil — addon shows user message
    }

    const nargs = lua.gettop(L);

    if (nargs < 1 or !lua.isnumber(L, 1)) {
        con.print("[markers] WorldMarker: expected index (1-5)\n");
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        con.print("[markers] WorldMarker: index must be 1-5\n");
        return 0;
    }
    const index: usize = @intCast(raw_index - 1);

    if (nargs >= 4 and lua.isnumber(L, 2)) {
        const x: f32 = @floatCast(lua.tonumber(L, 2));
        const y: f32 = @floatCast(lua.tonumber(L, 3));
        const z: f32 = @floatCast(lua.tonumber(L, 4));
        _ = placeMarker(index, .{ .x = x, .y = y, .z = z });
    } else if (nargs >= 2 and lua.isstring(L, 2)) {
        const unit_id = lua.tostring(L, 2) orelse {
            con.print("[markers] WorldMarker: invalid unit string\n");
            return 0;
        };
        const pos = resolveUnitPosition(unit_id) orelse {
            con.fmt("[markers] WorldMarker: unit '{s}' not found\n", .{std.mem.span(unit_id)});
            return 0;
        };
        _ = placeMarker(index, pos);
    } else {
        const pos = getCursorTerrainPosition() orelse {
            con.print("[markers] no terrain under cursor\n");
            return 0;
        };
        _ = placeMarker(index, pos);
    }

    lua.pushnumber(L, 1.0);
    return 1;
}

/// Lua: local ok = ClearWorldMarker([index])
///   Returns 1 on success, nil on permission denied.
pub fn luaClearWorldMarker(L: lua.State) callconv(.c) u32 {
    if (!canSetMarkers()) {
        con.print("[markers] ClearWorldMarker: no permission\n");
        return 0;
    }

    const nargs = lua.gettop(L);
    const lua_type: *const fn (lua.State, i32) callconv(fc) i32 = @ptrFromInt(0x6F3400);

    if (nargs == 0 or lua_type(L, 1) == 0) {
        // No args or nil — clear all
        clearAllMarkers();
        lua.pushnumber(L, 1.0);
        return 1;
    }

    if (!lua.isnumber(L, 1)) {
        con.print("[markers] ClearWorldMarker: expected index (1-5) or nil\n");
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) {
        con.print("[markers] ClearWorldMarker: index must be 1-5\n");
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

    // Zombie detection — entity exists but refcount dropped to 1 (culled by game).
    // Check every 3 seconds to avoid per-frame overhead.
    if (now -% last_zombie_tick >= ZOMBIE_CHECK_INTERVAL_MS) {
        last_zombie_tick = now;
        for (0..NUM_MARKERS) |i| {
            const entity = marker_entities[i] orelse continue;
            const addr = @intFromPtr(entity);
            const refcount = hook.readMem(u16, addr + 0x0E);
            if (refcount <= 1) {
                con.fmt("[markers] zombie detected [{d}] @0x{x} rc={d}, destroying\n", .{ i + 1, addr, refcount });
                cleanupEntity(entity);
                marker_entities[i] = null;
                hold_queued[i] = false;
            }
        }
    }

    // Proximity respawn — check every ~1 second
    if (now -% last_respawn_tick >= RESPAWN_CHECK_INTERVAL_MS) {
        last_respawn_tick = now;

        const player = wow.getLocalPlayer();
        if (player != 0) {
            const player_pos = getUnitPosition(player);
            if (player_pos.x != 0 or player_pos.y != 0 or player_pos.z != 0) {
                const current_area = hook.readMem(u32, o.ZONE_AREA_ID);
                for (0..NUM_MARKERS) |i| {
                    if (!marker_defs[i].active) continue;
                    if (marker_entities[i] != null) continue; // entity alive, skip
                    if (marker_defs[i].area_id != current_area) continue; // wrong zone

                    const dx = player_pos.x - marker_defs[i].pos.x;
                    const dy = player_pos.y - marker_defs[i].pos.y;
                    const dz = player_pos.z - marker_defs[i].pos.z;
                    const dist_sq = dx * dx + dy * dy + dz * dz;

                    if (dist_sq < RESPAWN_DISTANCE_SQ) {
                        con.fmt("[markers] respawning [{d}] dist={d:.0}\n", .{ i + 1, @sqrt(dist_sq) });
                        _ = spawnEntity(i, marker_defs[i].pos);
                    }
                }
            }
        }
    }
}

/// Lua: SetMarkerDef(index, x, y, z, areaId, senderName)
/// Store a marker definition without immediately spawning. Used by the addon
/// when receiving remote marker data — proximity respawn handles entity creation.
/// senderName is verified against the group roster for leader/officer permission.
pub fn luaSetMarkerDef(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 6) return 0;
    if (!lua.isnumber(L, 1) or !lua.isnumber(L, 2) or !lua.isnumber(L, 3) or !lua.isnumber(L, 4) or !lua.isnumber(L, 5) or !lua.isstring(L, 6)) return 0;

    const sender = lua.tostring(L, 6) orelse return 0;
    if (!senderHasPermission(sender)) {
        con.fmt("[markers] SetMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
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

    con.fmt("[markers] SetMarkerDef [{d}] at {d:.1},{d:.1},{d:.1} area={d}\n", .{ index + 1, x, y, z, area_id });
    return 0;
}

/// Lua: SetMarkerDefSync(index, x, y, z, areaId, senderName)
/// Like SetMarkerDef but for sync relay (SF messages). Two checks:
///   1. Local player must be leader/assist (only they request syncs)
///   2. Sender must be in the group (any rank — they're just relaying data)
pub fn luaSetMarkerDefSync(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 6) return 0;
    if (!lua.isnumber(L, 1) or !lua.isnumber(L, 2) or !lua.isnumber(L, 3) or !lua.isnumber(L, 4) or !lua.isnumber(L, 5) or !lua.isstring(L, 6)) return 0;

    if (!canSetMarkers()) {
        con.print("[markers] SetMarkerDefSync: local player not leader/assist\n");
        return 0;
    }

    const sender = lua.tostring(L, 6) orelse return 0;
    if (!senderInGroup(sender)) {
        con.fmt("[markers] SetMarkerDefSync: sender '{s}' not in group\n", .{std.mem.span(sender)});
        return 0;
    }

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;
    const index: usize = @intCast(raw_index - 1);

    const x: f32 = @floatCast(lua.tonumber(L, 2));
    const y: f32 = @floatCast(lua.tonumber(L, 3));
    const z: f32 = @floatCast(lua.tonumber(L, 4));
    const area_id: u32 = @intFromFloat(lua.tonumber(L, 5));

    clearEntity(index);

    marker_defs[index] = .{
        .pos = .{ .x = x, .y = y, .z = z },
        .area_id = area_id,
        .active = true,
    };

    con.fmt("[markers] SetMarkerDefSync [{d}] at {d:.1},{d:.1},{d:.1} area={d}\n", .{ index + 1, x, y, z, area_id });
    return 0;
}

/// Lua: ClearMarkerDef(senderName) — clear all
/// Lua: ClearMarkerDef(index, senderName) — clear one
/// senderName is verified against the group roster for leader/officer permission.
pub fn luaClearMarkerDef(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 1) return 0;

    if (lua.isstring(L, 1) and (nargs == 1 or !lua.isnumber(L, 1))) {
        // ClearMarkerDef(senderName) — clear all
        const sender = lua.tostring(L, 1) orelse return 0;
        if (!senderHasPermission(sender)) {
            con.fmt("[markers] ClearMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
            return 0;
        }
        clearAllMarkers();
        return 0;
    }

    if (nargs >= 2 and lua.isnumber(L, 1) and lua.isstring(L, 2)) {
        // ClearMarkerDef(index, senderName) — clear one
        const sender = lua.tostring(L, 2) orelse return 0;
        if (!senderHasPermission(sender)) {
            con.fmt("[markers] ClearMarkerDef: sender '{s}' denied\n", .{std.mem.span(sender)});
            return 0;
        }
        const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
        if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;
        clearMarker(@intCast(raw_index - 1));
        return 0;
    }

    return 0;
}

/// Lua: local x, y, z, areaId = GetMarkerDef(index)
/// Returns position and area ID for an active marker def, or nil if inactive.
pub fn luaGetMarkerDef(L: lua.State) callconv(.c) u32 {
    const nargs = lua.gettop(L);
    if (nargs < 1 or !lua.isnumber(L, 1)) return 0;

    const raw_index = @as(i32, @intFromFloat(lua.tonumber(L, 1)));
    if (raw_index < 1 or raw_index > NUM_MARKERS) return 0;
    const index: usize = @intCast(raw_index - 1);

    if (!marker_defs[index].active) return 0;

    lua.pushnumber(L, @floatCast(marker_defs[index].pos.x));
    lua.pushnumber(L, @floatCast(marker_defs[index].pos.y));
    lua.pushnumber(L, @floatCast(marker_defs[index].pos.z));
    lua.pushnumber(L, @floatCast(@as(f64, @floatFromInt(marker_defs[index].area_id))));
    return 4;
}

/// Lua: local ok = CanSetMarkers()
/// Returns 1 if the local player has permission (leader/assist), nil otherwise.
/// Used by the addon for broadcast/sync decisions.
pub fn luaCanSetMarkers(L: lua.State) callconv(.c) u32 {
    if (canSetMarkers()) {
        lua.pushnumber(L, 1.0);
        return 1;
    }
    return 0;
}

/// Lua: local areaId = GetCurrentAreaId()
/// Returns the current zone area ID from the game global.
pub fn luaGetCurrentAreaId(L: lua.State) callconv(.c) u32 {
    const area_id = hook.readMem(u32, o.ZONE_AREA_ID);
    lua.pushnumber(L, @floatCast(@as(f64, @floatFromInt(area_id))));
    return 1;
}

// =============================================================================
// World teardown hook
// =============================================================================

var world_cleanup_hook: hook.Detour(fn () callconv(sc) void) = .{};
var world_update_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

/// OnWorldUpdate hook — per-frame tick while world is active.
/// Drives animation state (Hold queue after Stand, despawn cleanup).
fn worldUpdateDetour(frame: u32) callconv(fc) void {
    tickAnimations();
    world_update_hook.callOriginal(.{frame});
}

/// Pre-hook on CleanupWorldAndEntities (0x66fc40).
/// Destroys all our entities via CleanupEntity_ProcessAttachments before the
/// game's teardown runs — the same pattern every native caller uses (e.g.
/// processCinematicExit, DestroyPathObjectIfPresent). This unlinks them from
/// the WDOODADDEF hash table so the atexit handler never touches freed memory.
fn worldCleanupDetour() callconv(sc) void {
    con.print("[markers] >>> worldCleanupDetour FIRING <<<\n");
    destroyAllEntities();
    world_cleanup_hook.callOriginal(.{});
}

/// Destroy all tracked entities (active markers + despawning).
/// Does NOT clear marker_defs — definitions persist for respawn.
/// Idempotent — safe to call multiple times.
fn destroyAllEntities() void {
    var count: u32 = 0;
    for (&marker_entities, 0..) |*slot, i| {
        if (slot.*) |existing| {
            const addr = @intFromPtr(existing);
            con.fmt("[markers] destroying marker[{d}] @0x{x}\n", .{ i, addr });
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
            con.fmt("[markers] destroying despawn[{d}] @0x{x}\n", .{ i, addr });
            cleanupEntity(d.entity);
            slot.* = null;
            count += 1;
        }
    }

    if (count > 0) {
        con.fmt("[markers] world cleanup: destroyed {d} entities\n", .{count});
    }
}

// =============================================================================
// Install hooks
// =============================================================================

pub fn installHooks() void {
    con.print("[markers] Module loaded\n");

    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\MarkersHook_{d}", .{GetCurrentProcessId()}) catch return;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[markers] Another DLL owns markers (mutex taken), skipping\n");
        return;
    }
    g_is_hook_owner = true;

    // Hook OnWorldUpdate for per-frame animation tick (runs every frame while world is active).
    if (world_update_hook.attach(o.FN_ON_WORLD_UPDATE, &worldUpdateDetour) != .ok) {
        con.print("[markers] FAILED to hook OnWorldUpdate!\n");
    } else {
        con.print("[markers] hooked OnWorldUpdate OK\n");
    }

    // Hook CleanupWorldAndEntities to destroy our entities before world teardown.
    // This fires on map change, logout, AND exit — before heaps are destroyed.
    if (world_cleanup_hook.attach(o.FN_CLEANUP_WORLD_AND_ENTITIES, &worldCleanupDetour) != .ok) {
        con.print("[markers] FAILED to hook CleanupWorldAndEntities!\n");
    } else {
        con.print("[markers] hooked CleanupWorldAndEntities OK\n");
    }
}

/// Called from CGGameUI_Shutdown (logout/exit) — wipes marker definitions.
/// Does NOT touch hooks or mutex. Entities are destroyed separately by
/// worldCleanupDetour which fires after shutdown.
pub fn onShutdown() void {
    for (&marker_defs) |*d| d.* = EMPTY_DEF;
    con.print("[markers] defs cleared (shutdown)\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // destroyAllEntities is idempotent — if worldCleanupDetour already ran,
        // all slots are null and this is a no-op.
        destroyAllEntities();
        world_update_hook.detach();
        world_cleanup_hook.detach();
    }

    if (g_is_hook_owner) {
        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
