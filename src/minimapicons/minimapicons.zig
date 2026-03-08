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
    const QueryMapObjIDs: usize = 0x670540;
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
    const OBJ_WORLD_DATA: usize = 0xE0; // m_worldData (CWorld*)
    const OBJ_CREATURE_CACHE: usize = 0xB30; // ptr to creature cache entry

    // Creature cache entry offsets (name[0..3] at +0x00..+0x0C, subname at +0x10)
    const CACHE_SUBNAME: usize = 0x10; // char* subname/title (e.g. "Druid Trainer")

    // Descriptor field byte offsets (absolute_field_index * 4 from m_data)
    const DESC_NPC_FLAGS: usize = 0x93 * 4; // UNIT_NPC_FLAGS = OBJECT_END + 0x8D
    const DESC_GO_TYPE: usize = 0x15 * 4; // GAMEOBJECT_TYPE_ID

    // MINIMAPINFO struct offsets
    const MI_WMO_ID: usize = 0x04;
    const MI_MAP_OBJ_ID: usize = 0x08;
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
    gray: bool,
};

const FILTER_MAX = 32;

const FlagEntry = struct {
    flag: u32 = 0,
    blip: Blip = .{ .texture = 0, .scale = 1.0 },
    active: bool = false,
    filter: [FILTER_MAX]u8 = .{0} ** FILTER_MAX, // include: subname must contain
    filter_len: u8 = 0,
    exclude: [FILTER_MAX]u8 = .{0} ** FILTER_MAX, // exclude: subname must NOT contain
    exclude_len: u8 = 0,

    fn hasFilter(self: *const FlagEntry) bool {
        return self.filter_len > 0 or self.exclude_len > 0;
    }

    fn matchesSubName(self: *const FlagEntry, subname: [*:0]const u8) bool {
        if (self.filter_len > 0 and !containsInsensitive(subname, self.filter[0..self.filter_len]))
            return false;
        if (self.exclude_len > 0 and containsInsensitive(subname, self.exclude[0..self.exclude_len]))
            return false;
        return true;
    }

    fn filtersEqual(self: *const FlagEntry, inc: []const u8, exc: []const u8) bool {
        return sliceEqual(self.filter[0..self.filter_len], inc) and
            sliceEqual(self.exclude[0..self.exclude_len], exc);
    }

    fn sliceEqual(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
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
const MAX_BLIPS = 128;
const MAX_TEXTURES = 16;

var g_flag_tracking: [MAX_FLAG_ENTRIES]FlagEntry = .{FlagEntry{}} ** MAX_FLAG_ENTRIES;
var g_go_tracking: [MAX_GO_ENTRIES]GoTypeEntry = .{GoTypeEntry{}} ** MAX_GO_ENTRIES;
var g_blips: [MAX_BLIPS]TrackedBlip = undefined;
var g_blip_count: u32 = 0;
var g_tex_cache: [MAX_TEXTURES]TextureEntry = .{TextureEntry{}} ** MAX_TEXTURES;
var g_tex_cache_count: u32 = 0;
var g_default_tex_flags: u32 = 0;

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
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
    return pos;
}

fn queryMapObjIDs(world_data: u32) struct { wmo_id: u32, map_obj_id: u32 } {
    if (!isValidPtr(world_data)) return .{ .wmo_id = 0, .map_obj_id = 0 };
    var wmo_id: u32 = 0;
    var map_obj_id: u32 = 0;
    var group_num: u32 = 0;
    // __fastcall(world_ECX, &wmoID_EDX, &mapObjID, &groupNum) — RET 0x8
    asm volatile (
        \\push %[group]
        \\push %[map]
        \\call *%[func]
        :
        : [_] "{ecx}" (world_data),
          [_] "{edx}" (@intFromPtr(&wmo_id)),
          [map] "r" (@intFromPtr(&map_obj_id)),
          [group] "r" (@intFromPtr(&group_num)),
          [func] "r" (@as(u32, ADDR.QueryMapObjIDs)),
        : .{ .eax = true, .memory = true, .cc = true });
    return .{ .wmo_id = wmo_id, .map_obj_id = map_obj_id };
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
        : .{ .edx = true, .memory = true, .cc = true });
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
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
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
        : .{ .memory = true, .cc = true });

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
        : .{ .eax = true, .edx = true, .memory = true, .cc = true });
    return flags;
}

// =============================================================================
// Blip drawing (port of VanillaHelpers DrawMinimapTexture)
// =============================================================================

fn drawMinimapTexture(texture: u32, pos: C2Vector, scale: f32, gray: bool) void {
    if (texture == 0) return;

    const color: CImVector = if (gray)
        .{ .b = 0xB0, .g = 0xB0, .r = 0xB0, .a = 0xFF }
    else
        .{ .b = 0xFF, .g = 0xFF, .r = 0xFF, .a = 0xFF };

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

    // TextureGetGxTex: __fastcall(texture_ECX, flag_EDX, status*_stack) → CGxTex*
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
        : .{ .memory = true, .cc = true });

    if (!status.ok() or gx_tex == 0) return;

    // GxRsSet(GxRs_Texture0=23, gxTex)
    const gxRsSet: *const fn (u32, u32) callconv(fc) void = @ptrFromInt(ADDR.GxRsSet);
    gxRsSet(23, gx_tex);

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
        : .{ .eax = true, .memory = true, .cc = true });

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
    const obj = getObjectByGUID(guid_lo, guid_hi);
    if (obj == 0 or !isValidPtr(obj)) return false;

    const obj_type = getObjectType(obj);

    if (obj_type == OBJ_TYPE_UNIT) {
        const npc_flags = getNpcFlags(obj);
        if (npc_flags == 0) return false;

        // Match entries by NPC flag + subname filter. Include filters take
        // priority over exclude-only filters, which take priority over unfiltered.
        // Within each tier, higher flag value = higher priority.
        const subname = getCreatureSubName(obj);

        var best_priority: u8 = 0; // 0=none, 1=unfiltered, 2=exclude-only, 3=include
        var best_flag: u32 = 0;
        var best_blip: Blip = .{ .texture = 0, .scale = 1.0 };

        for (&g_flag_tracking) |*entry| {
            if (!entry.active) continue;
            if (npc_flags & entry.flag == 0) continue;

            const priority: u8 = if (entry.filter_len > 0)
                3
            else if (entry.exclude_len > 0)
                2
            else
                1;

            if (priority < best_priority) continue;
            if (priority == best_priority and entry.flag <= best_flag) continue;

            // Check subname match
            if (entry.hasFilter()) {
                if (subname) |sn| {
                    if (!entry.matchesSubName(sn)) continue;
                } else continue; // no subname available, can't match filters
            }

            best_priority = priority;
            best_flag = entry.flag;
            best_blip = entry.blip;
        }

        if (best_flag != 0) {
            trackObject(info, obj, best_blip);
            return true;
        }
    } else if (obj_type == OBJ_TYPE_GAMEOBJECT) {
        const go_type = getGoType(obj);
        for (&g_go_tracking) |*entry| {
            if (!entry.active) continue;
            if (entry.go_type == go_type) {
                trackObject(info, obj, entry.blip);
                return true;
            }
        }
    }

    return false;
}

fn trackObject(info: u32, obj: u32, blip: Blip) void {
    if (g_blip_count >= MAX_BLIPS) return;

    // WMO indoor/outdoor filtering
    const info_wmo = hook.readMem(u32, info + ADDR.MI_WMO_ID);
    const info_map = hook.readMem(u32, info + ADDR.MI_MAP_OBJ_ID);
    const world_data = hook.readMem(u32, obj + ADDR.OBJ_WORLD_DATA);

    var is_different_area = false;
    if (isValidPtr(world_data)) {
        const ids = queryMapObjIDs(world_data);
        // Hide outside blips when player is inside a WMO (replicating original behavior)
        if (info_wmo != 0 and (ids.wmo_id != info_wmo or ids.map_obj_id != info_map))
            return;
        is_different_area = (ids.wmo_id != info_wmo);
    }

    const pos = getObjectPosition(obj) orelse return;

    const cur = C3Vector{
        .x = hook.readMem(f32, info + ADDR.MI_POS),
        .y = hook.readMem(f32, info + ADDR.MI_POS + 4),
        .z = hook.readMem(f32, info + ADDR.MI_POS + 8),
    };
    const radius = hook.readMem(f32, info + ADDR.MI_RADIUS);
    const layout_scale = hook.readMem(f32, info + ADDR.MI_LAYOUT_SCALE);
    const unk_scale = getFrameUnkScale(info);

    var minimap_pos: C2Vector = undefined;
    worldPosToMinimapCoords(&minimap_pos, cur, radius, pos.x, pos.y, layout_scale, unk_scale);

    g_blips[g_blip_count] = .{
        .pos = minimap_pos,
        .blip = blip,
        .gray = is_different_area,
    };
    g_blip_count += 1;
}

fn hasActiveTracking() bool {
    for (&g_flag_tracking) |*entry| {
        if (entry.active) return true;
    }
    for (&g_go_tracking) |*entry| {
        if (entry.active) return true;
    }
    return false;
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
    if (hasActiveTracking()) {
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

    // Draw our custom blips after the original ones
    for (0..g_blip_count) |i| {
        drawMinimapTexture(
            g_blips[i].blip.texture,
            g_blips[i].pos,
            g_blips[i].blip.scale,
            g_blips[i].gray,
        );
    }
}

// ClntObjMgrEnumVisibleObjects: __fastcall(callback ECX, context EDX)
const EnumVisFn = fn (u32, u32) callconv(fc) i32;
var enum_vis_hook: hook.Detour(EnumVisFn) = .{};

fn enumVisibleObjectsDetour(callback: u32, context: u32) callconv(fc) i32 {
    // Clear tracked blips when the minimap's own callback is about to enumerate
    if (callback == ADDR.ObjectEnumProc) {
        g_blip_count = 0;
    }
    return enum_vis_hook.callOriginal(.{ callback, context });
}

// =============================================================================
// Lua API
// =============================================================================

// SetObjectTypeBlip(typeName [, texturePath [, scale [, includeFilter [, excludeFilter]]]])
pub fn luaSetObjectTypeBlip(L: lua.State) callconv(fc) i32 {
    if (!lua.isstring(L, 1)) {
        lua.luaError(L, "Usage: SetObjectTypeBlip(type [, texture [, scale [, include [, exclude]]]])");
        return 0;
    }

    const type_name = lua.tostring(L, 1) orelse return 0;

    const mapping = findTypeMapping(type_name) orelse {
        lua.luaError(L, "Unknown type. Use: auctioneer, banker, battlemaster, flightmaster, innkeeper, repair, stablemaster, trainer, vendor, mailbox");
        return 0;
    };

    // Parse optional include filter (arg 4) and exclude filter (arg 5)
    var inc_buf: [FILTER_MAX]u8 = .{0} ** FILTER_MAX;
    var inc_len: u8 = 0;
    var exc_buf: [FILTER_MAX]u8 = .{0} ** FILTER_MAX;
    var exc_len: u8 = 0;
    if (lua.isstring(L, 4)) {
        if (lua.tostring(L, 4)) |f| {
            while (inc_len < FILTER_MAX and f[inc_len] != 0) : (inc_len += 1) {
                inc_buf[inc_len] = f[inc_len];
            }
        }
    }
    if (lua.isstring(L, 5)) {
        if (lua.tostring(L, 5)) |f| {
            while (exc_len < FILTER_MAX and f[exc_len] != 0) : (exc_len += 1) {
                exc_buf[exc_len] = f[exc_len];
            }
        }
    }

    if (!lua.isstring(L, 2)) {
        // Disable tracking for this type + filter combo
        if (mapping.is_go_type) {
            for (&g_go_tracking) |*entry| {
                if (entry.active and entry.go_type == mapping.value) {
                    entry.active = false;
                    break;
                }
            }
        } else {
            for (&g_flag_tracking) |*entry| {
                if (entry.active and entry.flag == mapping.value and
                    entry.filtersEqual(inc_buf[0..inc_len], exc_buf[0..exc_len]))
                {
                    entry.active = false;
                    break;
                }
            }
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

    if (mapping.is_go_type) {
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
    } else {
        // Match by flag + include/exclude combo
        for (&g_flag_tracking) |*entry| {
            if (entry.active and entry.flag == mapping.value and
                entry.filtersEqual(inc_buf[0..inc_len], exc_buf[0..exc_len]))
            {
                entry.blip = blip;
                return 0;
            }
        }
        // Add new entry
        for (&g_flag_tracking) |*entry| {
            if (!entry.active) {
                entry.* = .{
                    .flag = mapping.value,
                    .blip = blip,
                    .active = true,
                    .filter = inc_buf,
                    .filter_len = inc_len,
                    .exclude = exc_buf,
                    .exclude_len = exc_len,
                };
                return 0;
            }
        }
    }

    return 0;
}

const TypeMapping = struct { is_go_type: bool, value: u32 };

fn findTypeMapping(name: [*:0]const u8) ?TypeMapping {
    const T = struct { n: []const u8, m: TypeMapping };
    const table = [_]T{
        .{ .n = "auctioneer", .m = .{ .is_go_type = false, .value = NPC_FLAG_AUCTIONEER } },
        .{ .n = "banker", .m = .{ .is_go_type = false, .value = NPC_FLAG_BANKER } },
        .{ .n = "battlemaster", .m = .{ .is_go_type = false, .value = NPC_FLAG_BATTLEMASTER } },
        .{ .n = "flightmaster", .m = .{ .is_go_type = false, .value = NPC_FLAG_FLIGHTMASTER } },
        .{ .n = "innkeeper", .m = .{ .is_go_type = false, .value = NPC_FLAG_INNKEEPER } },
        .{ .n = "repair", .m = .{ .is_go_type = false, .value = NPC_FLAG_REPAIR } },
        .{ .n = "stablemaster", .m = .{ .is_go_type = false, .value = NPC_FLAG_STABLEMASTER } },
        .{ .n = "trainer", .m = .{ .is_go_type = false, .value = NPC_FLAG_TRAINER } },
        .{ .n = "vendor", .m = .{ .is_go_type = false, .value = NPC_FLAG_VENDOR } },
        .{ .n = "mailbox", .m = .{ .is_go_type = true, .value = GO_TYPE_MAILBOX } },
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

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        enum_vis_hook.detach();
        render_blips_hook.detach();
        enum_proc_hook.detach();

        for (&g_flag_tracking) |*entry| entry.active = false;
        for (&g_go_tracking) |*entry| entry.active = false;
        g_blip_count = 0;

        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
