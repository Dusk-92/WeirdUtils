//! Standalone GUID cache module for isolated testing.
//! Hooks FindObjectByGUID (0x464890) with a per-frame-flushed direct-mapped cache.

const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "guidcache";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

const FindGuidFn = fn (u32, u32, u32, u32) callconv(hook.cc.fastcall) ?*anyopaque;
var findguid_hook: hook.Detour(FindGuidFn) = .{};

const WorldUpdateFn = fn (u32) callconv(hook.cc.fastcall) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

var destroy_objmgr_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

const GUID_CACHE_BITS = 12;
const GUID_CACHE_SIZE = 1 << GUID_CACHE_BITS;
const GUID_CACHE_MASK = GUID_CACHE_SIZE - 1;
const GuidCacheEntry = struct { guid_lo: u32 = 0, guid_hi: u32 = 0, result: u32 = 0 };
var guid_cache: [GUID_CACHE_SIZE]GuidCacheEntry = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;

fn findguidDetour(a: u32, b: u32, c: u32, d: u32) callconv(hook.cc.fastcall) ?*anyopaque {
    const idx = (c ^ d) & GUID_CACHE_MASK;
    const entry = &guid_cache[idx];

    if (entry.guid_lo == c and entry.guid_hi == d and entry.result != 0) {
        return @ptrFromInt(entry.result);
    }

    const ret = findguid_hook.callOriginal(.{ a, b, c, d });
    const result = @intFromPtr(ret);
    if (result != 0) {
        entry.* = .{ .guid_lo = c, .guid_hi = d, .result = result };
    } else {
        entry.* = .{};
    }
    return ret;
}

fn worldUpdateDetour(frame_count: u32) callconv(hook.cc.fastcall) void {
    guid_cache = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;
    world_update_hook.callOriginal(.{frame_count});
}

fn destroyObjMgrDetour() callconv(hook.cc.stdcall) void {
    guid_cache = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;
    destroy_objmgr_hook.callOriginal(.{});
}

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    _ = findguid_hook.attach(0x464890, &findguidDetour);
    _ = world_update_hook.attach(0x482EA0, &worldUpdateDetour);
    _ = destroy_objmgr_hook.attach(0x467700, &destroyObjMgrDetour);
    log.print("guidcache: GUID lookup cache active\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        findguid_hook.detach();
        world_update_hook.detach();
        destroy_objmgr_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}

pub fn onShutdown() void {}
