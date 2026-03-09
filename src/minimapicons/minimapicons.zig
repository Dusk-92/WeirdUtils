//! Minimap NPC tracking icons module.
//!
//! Adds NPC type tracking to the minimap (flight masters, innkeepers, mailboxes, etc.)
//! by hooking the minimap's object enumeration and blip rendering pipeline.
//!
//! Hooks:
//!   ObjectEnumProc (0x4EAA90) — intercepts per-object minimap callback, checks NPC flags
//!   RenderObjectBlips (0x4EBC00) — draws custom blip textures after default blips
//!   ClntObjMgrEnumVisibleObjects (0x468380) — clears tracked data at start of each cycle
//!
//! Lua API:
//!   SetObjectTypeBlip(typeName [, texturePath [, scale]]) — enable/disable NPC tracking
//!
//! Based on VanillaHelpers (reference/VanillaHelpers/src/Blips.cpp).

const std = @import("std");
const hook = @import("zhook");
const lua = @import("../lua.zig");
const con = @import("../console.zig");
const mod_mutex = @import("../mutex.zig");

const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };

pub const module_name: [*:0]const u8 = "minimapicons";

// =============================================================================
// WoW 1.12.1 addresses
// =============================================================================

const ADDR = struct {
    // Hooked functions
    const ObjectEnumProc: usize = 0x4EAA90;
    const RenderObjectBlips: usize = 0x4EBC00;
    const EnumVisibleObjects: usize = 0x468380;

    // Called functions
    const WorldPosToMinimapCoords: usize = 0x4EAA30;
    const TextureCreate: usize = 0x449D90;
    const TextureGetGxTex: usize = 0x44ACF0;
    const GxRsSet: usize = 0x589E80;
    const GxPrimLockVertexPtrs: usize = 0x58A2A0;
    const GxPrimDrawElements: usize = 0x58A2E0;
    const GxPrimUnlockVertexPtrs: usize = 0x58A340;
    const GetObjectByGUID: usize = 0x464870;
    const CGxTexFlagsInit: usize = 0x58A980;
    const CStatusDestructor: usize = 0x419E30;

    // Static data
    const BlipVertices: usize = 0xBC8230; // 4x C3Vector
    const BlipNormal: usize = 0xBC829C; // C3Vector
    const BlipTexCoords: usize = 0xBC77F0; // TexCoord (4x C2Vector)
    const BlipVertIndices: usize = 0x807A2C; // 4x u16
    const CStatusVftable: usize = 0x7FFA10;

    // Object struct offsets
    const OBJ_VTABLE: usize = 0x00;
    const OBJ_DATA: usize = 0x08; // m_data — update fields descriptor (starts at field 0)
    const OBJ_TYPE: usize = 0x14; // m_objectType
    const OBJ_CREATURE_CACHE: usize = 0xB30; // ptr to creature cache entry

    // Creature cache entry offsets (name[0..3] at +0x00..+0x0C, subname at +0x10)
    const CACHE_SUBNAME: usize = 0x10; // char* subname/title (e.g. "Druid Trainer")

    // Descriptor field byte offsets (absolute_field_index * 4 from m_data)
    const DESC_ENTRY: usize = 0x03 * 4; // OBJECT_FIELD_ENTRY
    const DESC_NPC_FLAGS: usize = 0x93 * 4; // UNIT_NPC_FLAGS = OBJECT_END + 0x8D
    const DESC_GO_TYPE: usize = 0x15 * 4; // GAMEOBJECT_TYPE_ID
    const DESC_SUMMONEDBY: usize = 0x0C * 4; // UNIT_FIELD_SUMMONEDBY (GUID, 8 bytes)
    const DESC_FACTIONTEMPLATE: usize = 0x23 * 4; // UNIT_FIELD_FACTIONTEMPLATE
    const DESC_GO_FLAGS: usize = 0x09 * 4; // GAMEOBJECT_FLAGS

    // Function addresses
    const ClntObjMgrGetActivePlayer: usize = 0x468550;
    const UnitReaction: usize = 0x6061E0;

    // MINIMAPINFO struct offsets
    const MI_POS: usize = 0x0C; // C3Vector
    const MI_RADIUS: usize = 0x18;
    const MI_LAYOUT_SCALE: usize = 0x1C;
    const MI_FRAME: usize = 0x20;

    // CGMinimapFrame: FrameScriptPart at +0x24, its vtable[7] = GetUnkScale
    const FRAME_SCRIPT_PART: usize = 0x24;

    // Vtable indices
    const VT_GET_POSITION: usize = 5 * 4;
};

// NPC flags
const NPC_FLAG_VENDOR: u32 = 0x00000004;
const NPC_FLAG_FLIGHTMASTER: u32 = 0x00000008;
const NPC_FLAG_TRAINER: u32 = 0x00000010;
const NPC_FLAG_INNKEEPER: u32 = 0x00000080;
const NPC_FLAG_BANKER: u32 = 0x00000100;
const NPC_FLAG_BATTLEMASTER: u32 = 0x00000800;
const NPC_FLAG_AUCTIONEER: u32 = 0x00001000;
const NPC_FLAG_STABLEMASTER: u32 = 0x00002000;
const NPC_FLAG_REPAIR: u32 = 0x00004000;

const GO_TYPE_MAILBOX: u32 = 19;
const GO_FLAG_NO_INTERACT: u32 = 0x10;

const OBJ_TYPE_UNIT: u32 = 3;
const OBJ_TYPE_GAMEOBJECT: u32 = 5;

// =============================================================================
// Types
// =============================================================================

const C2Vector = extern struct { x: f32, y: f32 };
const C3Vector = extern struct { x: f32, y: f32, z: f32 };
const CImVector = extern struct { b: u8, g: u8, r: u8, a: u8 };

const Blip = struct {
    texture: u32, // HTEXTURE__*
    scale: f32,
};

const TrackedBlip = struct {
    pos: C2Vector,
    blip: Blip,
};

const allocator = std.heap.page_allocator;

const FlagEntry = struct {
    flag: u32 = 0,
    blip: Blip = .{ .texture = 0, .scale = 1.0 },
    active: bool = false,
    filter: ?[]u8 = null, // include: subname must contain ANY pipe-delimited segment
    exclude: ?[]u8 = null, // exclude: subname must NOT contain ANY pipe-delimited segment

    fn hasFilter(self: *const FlagEntry) bool {
        return self.filter != null or self.exclude != null;
    }

    /// Match subname against pipe-delimited filter segments.
    /// Include: subname must contain ANY segment (OR).
    /// Exclude: subname must NOT contain ANY segment (OR).
    fn matchesSubName(self: *const FlagEntry, subname: [*:0]const u8) bool {
        if (self.filter) |f| {
            if (!pipeMatchAny(subname, f)) return false;
        }
        if (self.exclude) |e| {
            if (pipeMatchAny(subname, e)) return false;
        }
        return true;
    }

    /// Returns true if haystack contains ANY pipe-delimited segment from pattern.
    fn pipeMatchAny(haystack: [*:0]const u8, pattern: []const u8) bool {
        var start: usize = 0;
        for (pattern, 0..) |c, i| {
            if (c == '|') {
                if (i > start and containsInsensitive(haystack, pattern[start..i]))
                    return true;
                start = i + 1;
            }
        }
        // Last (or only) segment
        if (pattern.len > start and containsInsensitive(haystack, pattern[start..]))
            return true;
        return false;
    }

    fn filtersEqual(self: *const FlagEntry, inc: ?[]const u8, exc: ?[]const u8) bool {
        return sliceEqual(self.filterSlice(), inc) and sliceEqual(self.excludeSlice(), exc);
    }

    fn filterSlice(self: *const FlagEntry) ?[]const u8 {
        return self.filter;
    }

    fn excludeSlice(self: *const FlagEntry) ?[]const u8 {
        return self.exclude;
    }

    fn setFilter(self: *FlagEntry, src: ?[]const u8) void {
        if (self.filter) |old| allocator.free(old);
        self.filter = dupeStr(src);
    }

    fn setExclude(self: *FlagEntry, src: ?[]const u8) void {
        if (self.exclude) |old| allocator.free(old);
        self.exclude = dupeStr(src);
    }

    fn clear(self: *FlagEntry) void {
        if (self.filter) |f| allocator.free(f);
        if (self.exclude) |e| allocator.free(e);
        self.* = .{};
    }

    fn dupeStr(src: ?[]const u8) ?[]u8 {
        const s = src orelse return null;
        if (s.len == 0) return null;
        return allocator.dupe(u8, s) catch return null;
    }

    fn sliceEqual(a: ?[]const u8, b: ?[]const u8) bool {
        const sa = a orelse return b == null or b.?.len == 0;
        const sb = b orelse return sa.len == 0;
        if (sa.len != sb.len) return false;
        for (sa, sb) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
};

const GoTypeEntry = struct {
    go_type: u32 = 0,
    blip: Blip = .{ .texture = 0, .scale = 1.0 },
    active: bool = false,
};

const GoEntryEntry = struct {
    entry_id: u32 = 0,
    blip: Blip = .{ .texture = 0, .scale = 1.0 },
    active: bool = false,
};

const TextureEntry = struct {
    path_hash: u32 = 0,
    handle: u32 = 0,
};

const CStatus = extern struct {
    vftable: u32,
    unk: i32,
    head_next: u32,
    head_prev: u32,
    max_severity: i32,

    fn init(self: *CStatus) void {
        self.vftable = ADDR.CStatusVftable;
        self.unk = 8;
        self.head_next = @intFromPtr(&self.head_next);
        self.head_prev = @intFromPtr(&self.head_next) | 1;
        self.max_severity = 0;
    }

    fn ok(self: *const CStatus) bool {
        return self.max_severity < 2; // < STATUS_ERROR
    }

    fn deinit(self: *CStatus) void {
        const f: *const fn (*CStatus) callconv(tc) void = @ptrFromInt(ADDR.CStatusDestructor);
        f(self);
    }
};

// =============================================================================
// State
// =============================================================================

const MAX_FLAG_ENTRIES = 16;
const MAX_GO_ENTRIES = 4;
const MAX_GO_ID_ENTRIES = 4;
const MAX_BLIPS = 128;
const MAX_TEXTURES = 16;

var g_flag_tracking: [MAX_FLAG_ENTRIES]FlagEntry = .{FlagEntry{}} ** MAX_FLAG_ENTRIES;
var g_go_tracking: [MAX_GO_ENTRIES]GoTypeEntry = .{GoTypeEntry{}} ** MAX_GO_ENTRIES;
var g_go_id_tracking: [MAX_GO_ID_ENTRIES]GoEntryEntry = .{GoEntryEntry{}} ** MAX_GO_ID_ENTRIES;
var g_blips: [MAX_BLIPS]TrackedBlip = undefined;
var g_blip_count: u32 = 0;
var g_has_active_tracking: bool = false;
var g_has_active_unit_tracking: bool = false;
var g_has_active_go_tracking: bool = false;
var g_has_any_filters: bool = false;
var g_active_flag_mask: u32 = 0; // OR of all active flag entry flags
var g_tex_cache: [MAX_TEXTURES]TextureEntry = .{TextureEntry{}} ** MAX_TEXTURES;
var g_tex_cache_count: u32 = 0;
var g_default_tex_flags: u32 = 0;

// GUID → blip result cache. NPC flags/subnames don't change at runtime,
// so a matched GUID always produces the same blip. Cleared when tracking
// config changes (refreshActiveTrackingCache).
const GUID_CACHE_SIZE = 256; // must be power of 2
const GuidCacheEntry = struct {
    guid_lo: u32 = 0,
    guid_hi: u32 = 0,
    blip: Blip = .{ .texture = 0, .scale = 1.0 },
    valid: bool = false, // entry is populated
    matched: bool = false, // true = has blip, false = no match (negative cache)
};
var g_guid_cache: [GUID_CACHE_SIZE]GuidCacheEntry = .{GuidCacheEntry{}} ** GUID_CACHE_SIZE;

fn guidCacheIndex(guid_lo: u32, guid_hi: u32) usize {
    // Simple hash: XOR fold both halves
    return @intCast((guid_lo ^ guid_hi) & (GUID_CACHE_SIZE - 1));
}

fn guidCacheLookup(guid_lo: u32, guid_hi: u32) ?GuidCacheEntry {
    const idx = guidCacheIndex(guid_lo, guid_hi);
    const entry = &g_guid_cache[idx];
    if (entry.valid and entry.guid_lo == guid_lo and entry.guid_hi == guid_hi) {
        return entry.*;
    }
    return null;
}

fn guidCacheStore(guid_lo: u32, guid_hi: u32, blip: ?Blip) void {
    const idx = guidCacheIndex(guid_lo, guid_hi);
    g_guid_cache[idx] = .{
        .guid_lo = guid_lo,
        .guid_hi = guid_hi,
        .blip = blip orelse .{ .texture = 0, .scale = 1.0 },
        .valid = true,
        .matched = blip != null,
    };
}

fn guidCacheClear() void {
    g_guid_cache = .{GuidCacheEntry{}} ** GUID_CACHE_SIZE;
}

// Per-frame minimap info cache (same for all objects in one enumeration cycle)
const MinimapInfoCache = struct {
    cur: C3Vector = .{ .x = 0, .y = 0, .z = 0 },
    radius: f32 = 0,
    layout_scale: f32 = 0,
    unk_scale: f32 = 0,
    valid: bool = false,
};
var g_minimap_info: MinimapInfoCache = .{};
var g_local_player: u32 = 0; // cached per enumeration cycle

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Pointer validation
// =============================================================================

fn isValidPtr(addr: u32) bool {
    return addr >= 0x10000 and addr < 0x7F000000;
}

// =============================================================================
// Object helpers
// =============================================================================

fn getObjectByGUID(guid_lo: u32, guid_hi: u32) u32 {
    if (guid_lo == 0 and guid_hi == 0) return 0;
    return asm volatile (
        \\push %[hi]
        \\push %[lo]
        \\call *%[func]
        : [ret] "={eax}" (-> u32),
        : [lo] "r" (guid_lo),
          [hi] "r" (guid_hi),
          [func] "r" (@as(u32, ADDR.GetObjectByGUID)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
}

fn getObjectType(obj: u32) u32 {
    if (!isValidPtr(obj)) return 0;
    return hook.readMem(u32, obj + ADDR.OBJ_TYPE);
}

fn getDescriptor(obj: u32) u32 {
    if (!isValidPtr(obj)) return 0;
    return hook.readMem(u32, obj + ADDR.OBJ_DATA);
}

fn getNpcFlags(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + ADDR.DESC_NPC_FLAGS);
}

fn getGoType(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + ADDR.DESC_GO_TYPE);
}

fn getCreatureSubName(obj: u32) ?[*:0]const u8 {
    const cache = hook.readMem(u32, obj + ADDR.OBJ_CREATURE_CACHE);
    if (!isValidPtr(cache)) return null;
    const subname_ptr = hook.readMem(u32, cache + ADDR.CACHE_SUBNAME);
    if (!isValidPtr(subname_ptr)) return null;
    const subname: [*:0]const u8 = @ptrFromInt(subname_ptr);
    if (subname[0] == 0) return null;
    return subname;
}

fn getObjectEntry(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + ADDR.DESC_ENTRY);
}

// Creature entry IDs that should be treated as reagent vendors despite having no subname.
const REAGENT_VENDOR_ENTRIES = [_]u32{
    50041, // Field Repair Bot 75B
};

fn isReagentVendorEntry(entry_id: u32) bool {
    for (REAGENT_VENDOR_ENTRIES) |e| {
        if (e == entry_id) return true;
    }
    return false;
}

fn getGoFlags(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + ADDR.DESC_GO_FLAGS);
}

fn getFactionTemplate(obj: u32) u32 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    return hook.readMem(u32, desc + ADDR.DESC_FACTIONTEMPLATE);
}

fn getSummonedByGUID(obj: u32) u64 {
    const desc = getDescriptor(obj);
    if (!isValidPtr(desc)) return 0;
    const lo = hook.readMem(u32, desc + ADDR.DESC_SUMMONEDBY);
    const hi = hook.readMem(u32, desc + ADDR.DESC_SUMMONEDBY + 4);
    return (@as(u64, hi) << 32) | lo;
}

fn getActivePlayerObject() u32 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("call *%[func]"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [func] "r" (@as(u32, ADDR.ClntObjMgrGetActivePlayer)),
        : .{ .ecx = true, .memory = true, .cc = true });
    const guid_lo = lo;
    const guid_hi = hi;
    if (guid_lo == 0 and guid_hi == 0) return 0;
    return getObjectByGUID(guid_lo, guid_hi);
}

/// UnitReaction: __thiscall(localPlayer_ECX, unit_stack) -> int (>=4 = friendly).
fn unitReaction(local_player: u32, unit: u32) i32 {
    if (local_player == 0 or unit == 0) return 0;
    return asm volatile (
        \\push %[unit]
        \\call *%[func]
        : [ret] "={eax}" (-> i32),
        : [_] "{ecx}" (local_player),
          [unit] "r" (unit),
          [func] "r" (@as(u32, ADDR.UnitReaction)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
}

/// Check if a unit passes faction/friendliness filters.
/// Returns false (reject) if:
///   - Unit is hostile (reaction < 4)
///   - Unit has an owner whose faction template differs from local player
fn isUnitAllowed(obj: u32, local_player: u32) bool {
    if (local_player == 0) return true; // can't check without player

    // Check hostility via UnitReaction
    const reaction = unitReaction(local_player, obj);
    if (reaction < 4) {
        con.fmt("[minimapicons] unit 0x{x} rejected: hostile (reaction={d}, faction={d})\n", .{ obj, reaction, getFactionTemplate(obj) });
        return false;
    }

    // If unit has a summoner, their faction must match ours
    const summoner_guid = getSummonedByGUID(obj);
    if (summoner_guid != 0) {
        const lo: u32 = @truncate(summoner_guid);
        const hi: u32 = @truncate(summoner_guid >> 32);
        const summoner = getObjectByGUID(lo, hi);
        if (summoner != 0 and isValidPtr(summoner)) {
            const our_faction = getFactionTemplate(local_player);
            const their_faction = getFactionTemplate(summoner);
            con.fmt("[minimapicons] unit 0x{x} summoner 0x{x}: our faction={d} their faction={d}\n", .{ obj, summoner, our_faction, their_faction });
            if (our_faction != 0 and their_faction != 0 and our_faction != their_faction)
                return false;
        }
    }
    return true;
}

/// Check if a game object is interactable (GO_FLAG_NO_INTERACT not set).
fn isGoInteractable(obj: u32) bool {
    const flags = getGoFlags(obj);
    if ((flags & GO_FLAG_NO_INTERACT) != 0) {
        con.fmt("[minimapicons] GO 0x{x} rejected: GO_FLAG_NO_INTERACT (flags=0x{x})\n", .{ obj, flags });
        return false;
    }
    return true;
}

fn containsInsensitive(haystack: [*:0]const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: u32 = 0;
    while (haystack[i] != 0) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            var hc = haystack[i + @as(u32, @intCast(j))];
            if (hc == 0) return false;
            if (hc >= 'A' and hc <= 'Z') hc += 32;
            var nlc = nc;
            if (nlc >= 'A' and nlc <= 'Z') nlc += 32;
            if (hc != nlc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn getObjectPosition(obj: u32) ?C3Vector {
    const vtable = hook.readMem(u32, obj + ADDR.OBJ_VTABLE);
    if (!isValidPtr(vtable)) return null;
    const get_pos_fn = hook.readMem(u32, vtable + ADDR.VT_GET_POSITION);
    if (!isValidPtr(get_pos_fn)) return null;
    var pos: C3Vector = undefined;
    // __thiscall(obj_ECX, &pos_stack) → C3Vector*
    asm volatile (
        \\push %[out]
        \\call *%[func]
        :
        : [_] "{ecx}" (obj),
          [out] "r" (@intFromPtr(&pos)),
          [func] "r" (get_pos_fn),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
    return pos;
}

// =============================================================================
// Minimap coordinate conversion
// =============================================================================

fn worldPosToMinimapCoords(
    out: *C2Vector,
    cur: C3Vector,
    radius: f32,
    world_x: f32,
    world_y: f32,
    layout_scale: f32,
    unk_scale: f32,
) void {
    // WorldPosToMinimapFrameCoords: __fastcall(out_ECX, edx, C3Vector cur, float radius,
    //   float worldX, float worldY, float layoutScale, float unkScale)
    // 8 stack params (32 bytes), callee cleanup
    const args = [8]u32{
        @bitCast(cur.x),
        @bitCast(cur.y),
        @bitCast(cur.z),
        @bitCast(radius),
        @bitCast(world_x),
        @bitCast(world_y),
        @bitCast(layout_scale),
        @bitCast(unk_scale),
    };
    _ = asm volatile (
        \\pushl 28(%[args])
        \\pushl 24(%[args])
        \\pushl 20(%[args])
        \\pushl 16(%[args])
        \\pushl 12(%[args])
        \\pushl 8(%[args])
        \\pushl 4(%[args])
        \\pushl (%[args])
        \\call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@intFromPtr(out)),
          [args] "r" (&args),
          [func] "r" (@as(u32, ADDR.WorldPosToMinimapCoords)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

fn getFrameUnkScale(info: u32) f32 {
    const frame = hook.readMem(u32, info + ADDR.MI_FRAME);
    if (!isValidPtr(frame)) return 1.0;
    const fsp = frame + ADDR.FRAME_SCRIPT_PART;
    const vtable = hook.readMem(u32, fsp);
    if (!isValidPtr(vtable)) return 1.0;
    const fn_addr = hook.readMem(u32, vtable + 7 * 4);
    if (!isValidPtr(fn_addr)) return 1.0;
    // __thiscall(fsp_ECX) → f32 on FPU ST(0)
    return asm volatile (
        \\call *%[func]
        : [ret] "={st}" (-> f32),
        : [_] "{ecx}" (fsp),
          [func] "r" (fn_addr),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Texture management
// =============================================================================

fn simpleHash(s: [*:0]const u8) u32 {
    var h: u32 = 5381;
    var i: u32 = 0;
    while (s[i] != 0) : (i += 1) {
        var c = s[i];
        if (c >= 'A' and c <= 'Z') c += 32;
        h = h *% 33 +% c;
    }
    return h;
}

fn loadTexture(path: [*:0]const u8) u32 {
    const path_hash = simpleHash(path);

    // Check cache
    for (0..g_tex_cache_count) |i| {
        if (g_tex_cache[i].path_hash == path_hash and g_tex_cache[i].handle != 0) {
            return g_tex_cache[i].handle;
        }
    }

    // Initialize default tex flags on first use
    if (g_default_tex_flags == 0) {
        g_default_tex_flags = initTexFlags();
    }

    var status: CStatus = undefined;
    status.init();
    defer status.deinit();

    // TextureCreate: __fastcall(filename_ECX, status_EDX, texFlags, unk1, unk2)
    const texture: u32 = asm volatile (
        \\pushl $1
        \\pushl $0
        \\push %[flags]
        \\call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@intFromPtr(path)),
          [_] "{edx}" (@intFromPtr(&status)),
          [flags] "r" (g_default_tex_flags),
          [func] "r" (@as(u32, ADDR.TextureCreate)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });

    if (!status.ok() or texture == 0) {
        con.print("[minimapicons] Failed to load texture\n");
        return 0;
    }

    if (g_tex_cache_count < MAX_TEXTURES) {
        g_tex_cache[g_tex_cache_count] = .{ .path_hash = path_hash, .handle = texture };
        g_tex_cache_count += 1;
    }

    return texture;
}

fn initTexFlags() u32 {
    var flags: u32 = 0;
    // CGxTexFlags constructor: __thiscall(this, filter=0, wrapU=0, wrapV=0,
    //   forceMipTracking=0, generateMipMaps=0, renderTarget=0, maxAnisotropy=0, unknownFlag=1)
    asm volatile (
        \\pushl $1
        \\pushl $0
        \\pushl $0
        \\pushl $0
        \\pushl $0
        \\pushl $0
        \\pushl $0
        \\pushl $0
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(&flags)),
          [func] "r" (@as(u32, ADDR.CGxTexFlagsInit)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
    return flags;
}

// =============================================================================
// Blip drawing (port of VanillaHelpers DrawMinimapTexture)
// =============================================================================

/// Resolve HTEXTURE to CGxTex* for binding. Returns 0 on failure.
fn getGxTex(texture: u32) u32 {
    var status: CStatus = undefined;
    status.init();
    defer status.deinit();

    const gx_tex: u32 = asm volatile (
        \\push %[status]
        \\call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (texture),
          [_] "{edx}" (@as(u32, 1)),
          [status] "r" (@intFromPtr(&status)),
          [func] "r" (@as(u32, ADDR.TextureGetGxTex)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });

    if (!status.ok()) return 0;
    return gx_tex;
}

/// Draw a single blip quad. Caller must have already bound the texture via GxRsSet.
fn drawMinimapBlip(pos: C2Vector, scale: f32) void {
    const color: CImVector = .{ .b = 0xFF, .g = 0xFF, .r = 0xFF, .a = 0xFF };

    // Scale static blip vertex template by blip scale and offset by minimap position
    var vertices: [4]C3Vector = undefined;
    for (0..4) |i| {
        const src = ADDR.BlipVertices + i * 12;
        vertices[i] = .{
            .x = pos.x + scale * hook.readMem(f32, src),
            .y = pos.y + scale * hook.readMem(f32, src + 4),
            .z = scale * hook.readMem(f32, src + 8),
        };
    }

    // GxPrimLockVertexPtrs(count=4, vertices, vertStride=12, normal, 0, color, 0,
    //   null, 0, texCoords, 8, null, 0)
    const lock_args = [11]u32{
        12, // vertStride
        @as(u32, ADDR.BlipNormal), // normal
        0, // normalStride
        @intFromPtr(&color), // color
        0, // colorStride
        0, // specular (null)
        0, // specularStride
        @as(u32, ADDR.BlipTexCoords), // texCoords
        8, // texStride
        0, // texCoords2 (null)
        0, // tex2Stride
    };
    asm volatile (
        \\pushl 40(%[args])
        \\pushl 36(%[args])
        \\pushl 32(%[args])
        \\pushl 28(%[args])
        \\pushl 24(%[args])
        \\pushl 20(%[args])
        \\pushl 16(%[args])
        \\pushl 12(%[args])
        \\pushl 8(%[args])
        \\pushl 4(%[args])
        \\pushl (%[args])
        \\call *%[func]
        :
        : [_] "{ecx}" (@as(u32, 4)), // count
          [_] "{edx}" (@intFromPtr(&vertices)), // vertices
          [args] "r" (&lock_args),
          [func] "r" (@as(u32, ADDR.GxPrimLockVertexPtrs)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });

    // GxPrimDrawElements(TriangleStrip=4, count=4, indices)
    const drawElements: *const fn (u32, u32, u32) callconv(fc) void = @ptrFromInt(ADDR.GxPrimDrawElements);
    drawElements(4, 4, ADDR.BlipVertIndices);

    // GxPrimUnlockVertexPtrs()
    const unlockPtrs: *const fn () callconv(.c) void = @ptrFromInt(ADDR.GxPrimUnlockVertexPtrs);
    unlockPtrs();
}

// =============================================================================
// Object classification
// =============================================================================

fn checkObject(info: u32, guid_lo: u32, guid_hi: u32) bool {
    // GUID cache stores type classification (NPC flags/subname/GO type -> blip).
    // Dynamic checks (faction, interactability) run every frame, even on cache hits,
    // since these can change as players join/leave groups.
    if (guidCacheLookup(guid_lo, guid_hi)) |cached| {
        if (!cached.matched) return false; // negative cache hit

        // Dynamic checks on cached match
        const obj = getObjectByGUID(guid_lo, guid_hi);
        if (obj == 0 or !isValidPtr(obj)) return false;

        const obj_type = getObjectType(obj);
        if (obj_type == OBJ_TYPE_UNIT) {
            if (!isUnitAllowed(obj, g_local_player)) return false;
        } else if (obj_type == OBJ_TYPE_GAMEOBJECT) {
            if (!isGoInteractable(obj)) return false;
        }

        trackObject(info, guid_lo, guid_hi, cached.blip);
        return true;
    }

    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0 or !isValidPtr(obj)) return false;

    const obj_type = getObjectType(obj);

    if (obj_type == OBJ_TYPE_UNIT and g_has_active_unit_tracking) {
        const npc_flags = getNpcFlags(obj);
        if (npc_flags == 0) {
            guidCacheStore(guid_lo, guid_hi, null);
            return false;
        }

        // Quick bitmask check — skip loop if no active entries match any of this NPC's flags
        if (npc_flags & g_active_flag_mask == 0) {
            guidCacheStore(guid_lo, guid_hi, null);
            return false;
        }

        // Match entries by NPC flag + subname filter. Include filters take
        // priority over exclude-only filters, which take priority over unfiltered.
        // Within each tier, higher flag value = higher priority.
        // Only read subname/entry when filters are active (expensive per-object reads).
        const has_filters = g_has_any_filters;
        const subname = if (has_filters) getCreatureSubName(obj) else @as(?[*:0]const u8, null);
        const is_reagent_override = if (has_filters) isReagentVendorEntry(getObjectEntry(obj)) else false;

        var best_priority: u8 = 0; // 0=none, 1=unfiltered, 2=exclude-only, 3=include
        var best_flag: u32 = 0;
        var best_blip: Blip = .{ .texture = 0, .scale = 1.0 };

        for (&g_flag_tracking) |*entry| {
            if (!entry.active) continue;
            if (npc_flags & entry.flag == 0) continue;

            const priority: u8 = if (entry.filter != null)
                3
            else if (entry.exclude != null)
                2
            else
                1;

            if (priority < best_priority) continue;
            if (priority == best_priority and entry.flag < best_flag) continue;
            if (priority == best_priority and entry.flag == best_flag) continue; // first match wins at same tier

            // Check subname match (entry-ID overrides bypass subname requirement)
            if (entry.hasFilter()) {
                if (subname) |sn| {
                    if (!entry.matchesSubName(sn)) continue;
                } else if (entry.filter != null and is_reagent_override and
                    entry.flag == NPC_FLAG_VENDOR and FlagEntry.pipeMatchAny("Reagent Vendor", entry.filter.?))
                {
                    // NPC has no subname but entry ID is a known reagent vendor
                } else continue;
            }

            best_priority = priority;
            best_flag = entry.flag;
            best_blip = entry.blip;
        }

        if (best_flag != 0) {
            // Classification matched — apply dynamic faction/friendliness check.
            // Not negative-cached: faction can change (group join/leave).
            if (!isUnitAllowed(obj, g_local_player)) return false;

            guidCacheStore(guid_lo, guid_hi, best_blip);
            trackObject(info, guid_lo, guid_hi, best_blip);
            return true;
        }
    } else if (obj_type == OBJ_TYPE_GAMEOBJECT and g_has_active_go_tracking) {
        // Check by specific entry ID first
        const go_entry_id = getObjectEntry(obj);
        for (&g_go_id_tracking) |*entry| {
            if (!entry.active) continue;
            if (entry.entry_id == go_entry_id) {
                if (!isGoInteractable(obj)) return false;
                guidCacheStore(guid_lo, guid_hi, entry.blip);
                trackObject(info, guid_lo, guid_hi, entry.blip);
                return true;
            }
        }
        // Then by gameobject type
        const go_type = getGoType(obj);
        for (&g_go_tracking) |*entry| {
            if (!entry.active) continue;
            if (entry.go_type == go_type) {
                if (!isGoInteractable(obj)) return false;
                guidCacheStore(guid_lo, guid_hi, entry.blip);
                trackObject(info, guid_lo, guid_hi, entry.blip);
                return true;
            }
        }
    }

    guidCacheStore(guid_lo, guid_hi, null);
    return false;
}

fn trackObject(info: u32, guid_lo: u32, guid_hi: u32, blip: Blip) void {
    if (g_blip_count >= MAX_BLIPS) return;

    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0 or !isValidPtr(obj)) return;

    const pos = getObjectPosition(obj) orelse return;

    // Cache minimap info per frame — same for all objects in one enumeration cycle
    if (!g_minimap_info.valid) {
        g_minimap_info = .{
            .cur = .{
                .x = hook.readMem(f32, info + ADDR.MI_POS),
                .y = hook.readMem(f32, info + ADDR.MI_POS + 4),
                .z = hook.readMem(f32, info + ADDR.MI_POS + 8),
            },
            .radius = hook.readMem(f32, info + ADDR.MI_RADIUS),
            .layout_scale = hook.readMem(f32, info + ADDR.MI_LAYOUT_SCALE),
            .unk_scale = getFrameUnkScale(info),
            .valid = true,
        };
    }

    var minimap_pos: C2Vector = undefined;
    worldPosToMinimapCoords(&minimap_pos, g_minimap_info.cur, g_minimap_info.radius, pos.x, pos.y, g_minimap_info.layout_scale, g_minimap_info.unk_scale);

    g_blips[g_blip_count] = .{
        .pos = minimap_pos,
        .blip = blip,
    };
    g_blip_count += 1;
}

fn refreshActiveTrackingCache() void {
    var has_unit = false;
    var has_go = false;
    var has_filters = false;
    var flag_mask: u32 = 0;
    for (&g_flag_tracking) |*entry| {
        if (entry.active) {
            has_unit = true;
            flag_mask |= entry.flag;
            if (entry.hasFilter()) has_filters = true;
        }
    }
    for (&g_go_tracking) |*entry| {
        if (entry.active) has_go = true;
    }
    for (&g_go_id_tracking) |*entry| {
        if (entry.active) has_go = true;
    }
    g_has_active_unit_tracking = has_unit;
    g_has_active_go_tracking = has_go;
    g_has_active_tracking = has_unit or has_go;
    g_has_any_filters = has_filters;
    g_active_flag_mask = flag_mask;

    // Config changed — cached match results may be stale
    guidCacheClear();
}

// =============================================================================
// Hook detours
// =============================================================================

// ObjectEnumProc: __fastcall(MINIMAPINFO* ECX, unused EDX, u64 guid on stack)
// When guid is u64, MSVC fastcall skips EDX and puts the 8 bytes on stack.
// In Zig fastcall with 4 u32 params: ECX=info, EDX=_edx, stack=guid_lo,guid_hi → RET 8.
const EnumProcFn = fn (u32, u32, u32, u32) callconv(fc) i32;
var enum_proc_hook: hook.Detour(EnumProcFn) = .{};

fn objectEnumProcDetour(info: u32, _edx: u32, guid_lo: u32, guid_hi: u32) callconv(fc) i32 {
    if (g_has_active_tracking) {
        if (checkObject(info, guid_lo, guid_hi)) {
            return 1; // Skip original — we draw our own icon
        }
    }
    return enum_proc_hook.callOriginal(.{ info, _edx, guid_lo, guid_hi });
}

// RenderObjectBlips: __thiscall(CGMinimapFrame* ECX, DNInfo* stack)
// Hooked via fastcall with explicit EDX placeholder.
const RenderBlipsFn = fn (u32, u32, u32) callconv(fc) void;
var render_blips_hook: hook.Detour(RenderBlipsFn) = .{};

fn renderObjectBlipsDetour(thisptr: u32, _edx: u32, dn_info: u32) callconv(fc) void {
    render_blips_hook.callOriginal(.{ thisptr, _edx, dn_info });

    const count = g_blip_count;
    if (count == 0) return;

    // Sort blips by texture handle to batch draw calls
    const blips = g_blips[0..count];
    std.mem.sort(TrackedBlip, blips, {}, struct {
        fn lessThan(_: void, a: TrackedBlip, b: TrackedBlip) bool {
            return a.blip.texture < b.blip.texture;
        }
    }.lessThan);

    // Draw batched by texture — one GxRsSet per unique texture
    var i: usize = 0;
    while (i < count) {
        const tex = blips[i].blip.texture;
        if (tex == 0) {
            i += 1;
            continue;
        }

        // Bind texture once for this group
        const gx_tex = getGxTex(tex);
        if (gx_tex == 0) {
            // Skip all blips with this texture
            while (i < count and blips[i].blip.texture == tex) : (i += 1) {}
            continue;
        }

        const gxRsSet: *const fn (u32, u32) callconv(fc) void = @ptrFromInt(ADDR.GxRsSet);
        gxRsSet(23, gx_tex);

        // Draw all blips sharing this texture
        while (i < count and blips[i].blip.texture == tex) : (i += 1) {
            drawMinimapBlip(blips[i].pos, blips[i].blip.scale);
        }
    }
}

// ClntObjMgrEnumVisibleObjects: __fastcall(callback ECX, context EDX)
const EnumVisFn = fn (u32, u32) callconv(fc) i32;
var enum_vis_hook: hook.Detour(EnumVisFn) = .{};

fn enumVisibleObjectsDetour(callback: u32, context: u32) callconv(fc) i32 {
    // Clear tracked blips when the minimap's own callback is about to enumerate
    if (callback == ADDR.ObjectEnumProc) {
        g_blip_count = 0;
        g_minimap_info.valid = false;
        const prev = g_local_player;
        g_local_player = getActivePlayerObject();
        if (g_local_player != prev) {
            con.fmt("[minimapicons] local player: 0x{x} faction={d}\n", .{
                g_local_player,
                if (g_local_player != 0) getFactionTemplate(g_local_player) else @as(u32, 0),
            });
        }
    }
    return enum_vis_hook.callOriginal(.{ callback, context });
}

// =============================================================================
// Lua API
// =============================================================================

/// Read a Lua string arg as a slice (null if absent/empty).
fn luaStringToSlice(L: lua.State, idx: i32) ?[]const u8 {
    if (!lua.isstring(L, idx)) return null;
    const s = lua.tostring(L, idx) orelse return null;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    if (len == 0) return null;
    return s[0..len];
}

// SetObjectTypeBlip(typeName [, texturePath [, scale [, includeFilter [, excludeFilter]]]])
pub fn luaSetObjectTypeBlip(L: lua.State) callconv(fc) i32 {
    defer refreshActiveTrackingCache();

    if (!lua.isstring(L, 1)) {
        lua.luaError(L, "Usage: SetObjectTypeBlip(type [, texture [, scale [, include [, exclude]]]])");
        return 0;
    }

    const type_name = lua.tostring(L, 1) orelse return 0;

    const mapping = findTypeMapping(type_name) orelse {
        lua.luaError(L, "Unknown type. Use: auctioneer, banker, battlemaster, brainwasher, flightmaster, innkeeper, repair, stablemaster, trainer, vendor, mailbox");
        return 0;
    };

    // Parse optional include filter (arg 4) and exclude filter (arg 5) as slices
    const inc = luaStringToSlice(L, 4);
    const exc = luaStringToSlice(L, 5);

    if (!lua.isstring(L, 2)) {
        // Disable tracking for this type + filter combo
        switch (mapping.kind) {
            .go_type => {
                for (&g_go_tracking) |*entry| {
                    if (entry.active and entry.go_type == mapping.value) {
                        entry.active = false;
                        break;
                    }
                }
            },
            .go_entry => {
                for (&g_go_id_tracking) |*entry| {
                    if (entry.active and entry.entry_id == mapping.value) {
                        entry.active = false;
                        break;
                    }
                }
            },
            .npc_flag => {
                for (&g_flag_tracking) |*entry| {
                    if (entry.active and entry.flag == mapping.value and
                        entry.filtersEqual(inc, exc))
                    {
                        entry.clear();
                        break;
                    }
                }
            },
        }
        return 0;
    }

    // Enable tracking with texture
    const tex_path = lua.tostring(L, 2) orelse return 0;
    const texture = loadTexture(tex_path);
    if (texture == 0) {
        lua.luaError(L, "Failed to load texture");
        return 0;
    }

    var scale: f32 = 1.0;
    if (lua.isnumber(L, 3)) {
        scale = @floatCast(lua.tonumber(L, 3));
    }

    const blip = Blip{ .texture = texture, .scale = scale };

    switch (mapping.kind) {
        .go_type => {
            for (&g_go_tracking) |*entry| {
                if (entry.active and entry.go_type == mapping.value) {
                    entry.blip = blip;
                    return 0;
                }
            }
            for (&g_go_tracking) |*entry| {
                if (!entry.active) {
                    entry.* = .{ .go_type = mapping.value, .blip = blip, .active = true };
                    return 0;
                }
            }
        },
        .go_entry => {
            for (&g_go_id_tracking) |*entry| {
                if (entry.active and entry.entry_id == mapping.value) {
                    entry.blip = blip;
                    return 0;
                }
            }
            for (&g_go_id_tracking) |*entry| {
                if (!entry.active) {
                    entry.* = .{ .entry_id = mapping.value, .blip = blip, .active = true };
                    return 0;
                }
            }
        },
        .npc_flag => {
            // Match by flag + include/exclude combo — update existing or add new
            for (&g_flag_tracking) |*entry| {
                if (entry.active and entry.flag == mapping.value and
                    entry.filtersEqual(inc, exc))
                {
                    entry.blip = blip;
                    return 0;
                }
            }
            for (&g_flag_tracking) |*entry| {
                if (!entry.active) {
                    entry.flag = mapping.value;
                    entry.blip = blip;
                    entry.active = true;
                    entry.setFilter(inc);
                    entry.setExclude(exc);
                    return 0;
                }
            }
        },
    }

    return 0;
}

const TypeMapping = struct {
    kind: enum { npc_flag, go_type, go_entry } = .npc_flag,
    value: u32,
};

fn findTypeMapping(name: [*:0]const u8) ?TypeMapping {
    const T = struct { n: []const u8, m: TypeMapping };
    const table = [_]T{
        .{ .n = "auctioneer", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_AUCTIONEER } },
        .{ .n = "banker", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_BANKER } },
        .{ .n = "battlemaster", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_BATTLEMASTER } },
        .{ .n = "flightmaster", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_FLIGHTMASTER } },
        .{ .n = "innkeeper", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_INNKEEPER } },
        .{ .n = "repair", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_REPAIR } },
        .{ .n = "stablemaster", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_STABLEMASTER } },
        .{ .n = "trainer", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_TRAINER } },
        .{ .n = "vendor", .m = .{ .kind = .npc_flag, .value = NPC_FLAG_VENDOR } },
        .{ .n = "mailbox", .m = .{ .kind = .go_type, .value = GO_TYPE_MAILBOX } },
        .{ .n = "brainwasher", .m = .{ .kind = .go_entry, .value = 1000333 } }, // Goblin Brainwashing Device
    };

    for (&table) |*entry| {
        if (strEqlInsensitive(name, entry.n)) return entry.m;
    }
    return null;
}

fn strEqlInsensitive(a: [*:0]const u8, b: []const u8) bool {
    for (b, 0..) |bc, i| {
        var ac = a[i];
        if (ac == 0) return false;
        if (ac >= 'A' and ac <= 'Z') ac += 32;
        var blc = bc;
        if (blc >= 'A' and blc <= 'Z') blc += 32;
        if (ac != blc) return false;
    }
    return a[b.len] == 0;
}

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn installHooks() void {
    con.print("[minimapicons] Module loaded\n");

    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    if (enum_proc_hook.attach(ADDR.ObjectEnumProc, &objectEnumProcDetour) != .ok) {
        con.print("[minimapicons] Failed to hook ObjectEnumProc\n");
        return;
    }
    if (render_blips_hook.attach(ADDR.RenderObjectBlips, &renderObjectBlipsDetour) != .ok) {
        con.print("[minimapicons] Failed to hook RenderObjectBlips\n");
        enum_proc_hook.detach();
        return;
    }
    if (enum_vis_hook.attach(ADDR.EnumVisibleObjects, &enumVisibleObjectsDetour) != .ok) {
        con.print("[minimapicons] Failed to hook EnumVisibleObjects\n");
        render_blips_hook.detach();
        enum_proc_hook.detach();
        return;
    }

    con.print("[minimapicons] Hooks installed\n");
}

/// Called from CGGameUI_Shutdown (logout/exit) — frees heap-allocated filter strings.
pub fn onShutdown() void {
    for (&g_flag_tracking) |*entry| entry.clear();
    con.print("[minimapicons] filters freed (shutdown)\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        enum_vis_hook.detach();
        render_blips_hook.detach();
        enum_proc_hook.detach();

        for (&g_flag_tracking) |*entry| entry.active = false;
        for (&g_go_tracking) |*entry| entry.active = false;
        for (&g_go_id_tracking) |*entry| entry.active = false;
        g_blip_count = 0;

        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
