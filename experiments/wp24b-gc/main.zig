//! WeirdPerformance 2.4-B GC companion experiment.
//! Load alongside the validated WeirdPerformance 2.4-A DLL.
//! The only experimental delta is Lua GC rootgc sweeping.

const std = @import("std");
const hook = @import("zhook");
const WINAPI = std.os.windows.WINAPI;

const ENGINE_INIT_ADDR: usize = 0x46A400;
const PLAYER_LOAD_SCRIPT_FUNCTIONS_ADDR: usize = 0x490250;
const CGGAMEUI_SHUTDOWN_ADDR: usize = 0x490BD0;
const LUA_COLLECT_GARBAGE_ADDR: usize = 0x6F7340;
const BIRTH_MARK_ADDR: usize = 0x6F7B37;

const GS_ROOTGC: u32 = 0x10;
const GS_ROOTUDATA: u32 = 0x14;
const GS_GCTHRESHOLD: u32 = 0x24;
const GS_TOTALBYTES: u32 = 0x28;
const OBJ_NEXT: u32 = 0;

const CHUNK_SIZE: u32 = 50_000;
const BATCH_HEADROOM: u32 = 128 * 1024;

const VoidStdcallFn = fn () callconv(hook.cc.stdcall) void;
const CollectFn = fn (u32) callconv(hook.cc.fastcall) void;
const SweepAllFn = fn (u32, u32) callconv(hook.cc.fastcall) void;
const RemoveObjectsFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;

const lua_gc_full_collection: *const CollectFn = @ptrFromInt(0x6F73E0);
const lua_gc_shrink_memory: *const CollectFn = @ptrFromInt(0x6F7370);
const luaCallUserDataGC: *const CollectFn = @ptrFromInt(0x6F7080);
const lua_gc_sweep_all_lists: *const SweepAllFn = @ptrFromInt(0x6F72F0);
const lua_gc_remove_objects: *const RemoveObjectsFn = @ptrFromInt(0x6F7210);

var engine_init_hook: hook.Detour(VoidStdcallFn) = .{};
var player_load_hook: hook.Detour(VoidStdcallFn) = .{};
var shutdown_hook: hook.Detour(VoidStdcallFn) = .{};
var collect_hook: hook.Detour(CollectFn) = .{};

var runtime_installed = false;
var experiment_enabled = false;
var restart_pending = true;
var in_gc = false;

var sweeping = false;
var swept_head: u32 = 0;
var swept_tail: u32 = 0;
var unswept_rest: u32 = 0;
var saved_g: u32 = 0;
var birth_mark_owned = false;

inline fn readU8(addr: usize) u8 {
    return @as(*volatile const u8, @ptrFromInt(addr)).*;
}
inline fn readU32(addr: u32) u32 {
    return @as(*volatile const u32, @ptrFromInt(addr)).*;
}
inline fn writeU32(addr: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = value;
}
inline fn getGlobalState(L: u32) u32 {
    return readU32(L + 0x10);
}

fn findNth(head: u32, n: u32) struct { obj: u32, count: u32 } {
    var obj = head;
    var i: u32 = 0;
    while (obj != 0 and i < n) : (i += 1) {
        const next = readU32(obj + OBJ_NEXT);
        if (next == 0) return .{ .obj = 0, .count = i + 1 };
        obj = next;
    }
    return .{ .obj = obj, .count = i };
}

fn findTail(head: u32) u32 {
    var obj = head;
    if (obj == 0) return 0;
    while (true) {
        const next = readU32(obj + OBJ_NEXT);
        if (next == 0) return obj;
        obj = next;
    }
}

fn acquireBirthMark() bool {
    if (birth_mark_owned) return readU8(BIRTH_MARK_ADDR) == 0x01;
    if (readU8(BIRTH_MARK_ADDR) != 0x00) return false;
    const patch = [1]u8{0x01};
    hook.writeProtected(BIRTH_MARK_ADDR, &patch);
    if (readU8(BIRTH_MARK_ADDR) != 0x01) return false;
    birth_mark_owned = true;
    return true;
}

fn releaseBirthMark() void {
    if (!birth_mark_owned) return;
    if (readU8(BIRTH_MARK_ADDR) == 0x01) {
        const patch = [1]u8{0x00};
        hook.writeProtected(BIRTH_MARK_ADDR, &patch);
    }
    birth_mark_owned = false;
}

fn resetSweepState() void {
    sweeping = false;
    swept_head = 0;
    swept_tail = 0;
    unswept_rest = 0;
    saved_g = 0;
    releaseBirthMark();
}

fn reconnectSweep() void {
    if (!sweeping or saved_g == 0) {
        resetSweepState();
        return;
    }

    const g = saved_g;
    var tail = findTail(readU32(g + GS_ROOTGC));

    if (unswept_rest != 0) {
        if (tail != 0) writeU32(tail + OBJ_NEXT, unswept_rest)
        else writeU32(g + GS_ROOTGC, unswept_rest);
        tail = findTail(unswept_rest);
    }

    if (swept_head != 0) {
        if (tail != 0) writeU32(tail + OBJ_NEXT, swept_head)
        else writeU32(g + GS_ROOTGC, swept_head);
    }
    resetSweepState();
}

fn detachSweptAndRestore(g: u32) void {
    const current_head = readU32(g + GS_ROOTGC);
    if (current_head != 0) {
        const tail = findTail(current_head);
        if (swept_head == 0) {
            swept_head = current_head;
            swept_tail = tail;
        } else {
            writeU32(swept_tail + OBJ_NEXT, current_head);
            swept_tail = tail;
        }
    }
    writeU32(g + GS_ROOTGC, unswept_rest);
    unswept_rest = 0;
}

fn fallbackNative(L: u32) void {
    reconnectSweep();
    collect_hook.callOriginal(.{L});
}

fn collectGarbageDetour(L: u32) callconv(hook.cc.fastcall) void {
    if (in_gc) return;

    if (!experiment_enabled or restart_pending) {
        collect_hook.callOriginal(.{L});
        return;
    }

    if (L == 0) return;
    if (readU32(L + 0x60) == 0) return;

    in_gc = true;
    defer in_gc = false;

    const g = getGlobalState(L);
    if (g == 0) {
        collect_hook.callOriginal(.{L});
        return;
    }

    if (sweeping and (!birth_mark_owned or readU8(BIRTH_MARK_ADDR) != 0x01)) {
        fallbackNative(L);
        return;
    }

    if (!sweeping) {
        lua_gc_full_collection(L);
        _ = lua_gc_remove_objects(L, g + GS_ROOTUDATA, 0);
        lua_gc_sweep_all_lists(L, 0);

        const rootgc_head = readU32(g + GS_ROOTGC);
        const result = findNth(rootgc_head, CHUNK_SIZE);
        if (result.obj == 0) {
            _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
            lua_gc_shrink_memory(L);
            luaCallUserDataGC(L);
            return;
        }

        if (!acquireBirthMark()) {
            _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
            lua_gc_shrink_memory(L);
            luaCallUserDataGC(L);
            return;
        }

        unswept_rest = readU32(result.obj + OBJ_NEXT);
        writeU32(result.obj + OBJ_NEXT, 0);
        sweeping = true;
        saved_g = g;

        _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
        detachSweptAndRestore(g);

        const totalbytes = readU32(g + GS_TOTALBYTES);
        writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
        return;
    }

    if (g != saved_g) {
        // Never dereference bookkeeping belonging to a different/dead Lua state.
        resetSweepState();
        collect_hook.callOriginal(.{L});
        return;
    }

    const rootgc_head = readU32(g + GS_ROOTGC);
    const result = findNth(rootgc_head, CHUNK_SIZE);

    if (result.obj == 0) {
        _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
        const current_head = readU32(g + GS_ROOTGC);
        if (swept_head != 0) {
            if (current_head != 0) writeU32(swept_tail + OBJ_NEXT, current_head);
            writeU32(g + GS_ROOTGC, swept_head);
        }
        resetSweepState();
        lua_gc_shrink_memory(L);
        luaCallUserDataGC(L);
        return;
    }

    unswept_rest = readU32(result.obj + OBJ_NEXT);
    writeU32(result.obj + OBJ_NEXT, 0);
    _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
    detachSweptAndRestore(g);

    const totalbytes = readU32(g + GS_TOTALBYTES);
    writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
}

fn shutdownDetour() callconv(hook.cc.stdcall) void {
    // Runs for /reload and UI teardown. Lock before original Lua cleanup.
    restart_pending = true;
    experiment_enabled = false;
    reconnectSweep();
    shutdown_hook.callOriginal(.{});
}

fn playerLoadDetour() callconv(hook.cc.stdcall) void {
    player_load_hook.callOriginal(.{});
    reconnectSweep();
    restart_pending = false;
    experiment_enabled = true;
}

fn installRuntimeHooks() bool {
    if (runtime_installed) return true;

    // Lifecycle guards first, GC hook last. No partially-installed GC.
    if (shutdown_hook.attach(CGGAMEUI_SHUTDOWN_ADDR, &shutdownDetour) != .ok) return false;
    if (player_load_hook.attach(PLAYER_LOAD_SCRIPT_FUNCTIONS_ADDR, &playerLoadDetour) != .ok) {
        shutdown_hook.detach();
        return false;
    }
    if (collect_hook.attach(LUA_COLLECT_GARBAGE_ADDR, &collectGarbageDetour) != .ok) {
        player_load_hook.detach();
        shutdown_hook.detach();
        return false;
    }

    runtime_installed = true;
    restart_pending = true;
    experiment_enabled = false;
    return true;
}

fn engineInitDetour() callconv(hook.cc.stdcall) void {
    engine_init_hook.callOriginal(.{});
    _ = installRuntimeHooks();
}

fn installBootstrap() void {
    // Supported fixed-base WoW 1.12.1 build family only.
    const image_base = @as(*volatile const u16, @ptrFromInt(0x00400000));
    if (image_base.* != 0x5A4D) return;
    _ = engine_init_hook.attach(ENGINE_INIT_ADDR, &engineInitDetour);
}

const version: [*:0]const u8 = "2.4-B-gc-safe-sweep";

pub export fn WeirdPerformanceGC24B_GetVersion() callconv(.c) [*:0]const u8 {
    return version;
}

pub export fn WeirdPerformanceGC24B_IsActive() callconv(.c) i32 {
    return if (runtime_installed and experiment_enabled and !restart_pending) 1 else 0;
}

pub export fn DllMain(
    _: ?*anyopaque,
    reason: u32,
    _: ?*anyopaque,
) callconv(WINAPI) std.os.windows.BOOL {
    if (reason == 1) installBootstrap();

    // No hot-unhook: this A/B companion is process-lifetime by design.
    return @enumFromInt(1);
}
