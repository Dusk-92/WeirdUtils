//! WeirdPerformance 2.4-B GC safe-sweep companion.
//!
//! A/B contract:
//!   A = validated WeirdPerformance 2.4-A binary, unchanged.
//!   B = the exact same 2.4-A binary + this companion DLL.
//!
//! This companion only changes Lua GC behavior: WoW's native mark/udata/string
//! work is kept, while the rootgc sweep is split into bounded chunks.
//!
//! Target: WoW 1.12.1 build 5875, x86 only.

const std = @import("std");
const hook = @import("zhook");
const WINAPI = std.builtin.CallingConvention.winapi;

const LUA_COLLECT_GARBAGE_ADDR: usize = 0x6F7340;
const LUA_CLOSE_ADDR: usize = 0x6F6EF0;
const BIRTH_MARK_ADDR: usize = 0x6F7B37;

const GS_ROOTGC: u32 = 0x10;
const GS_ROOTUDATA: u32 = 0x14;
const GS_GCTHRESHOLD: u32 = 0x24;
const GS_TOTALBYTES: u32 = 0x28;
const OBJ_NEXT: u32 = 0;

const CHUNK_SIZE: u32 = 50_000;
const BATCH_HEADROOM: u32 = 128 * 1024;

// Crash logs for the supported client show 0x00400000..0x00D2B000.
const EXPECTED_IMAGE_BASE: usize = 0x00400000;
const EXPECTED_IMAGE_SIZE: u32 = 0x0092B000;

const CollectFn = fn (u32) callconv(X86_FASTCALL) void;
const LuaCloseFn = fn (u32) callconv(X86_FASTCALL) void;
const SweepAllFn = fn (u32, u32) callconv(X86_FASTCALL) void;
const RemoveObjectsFn = fn (u32, u32, u32) callconv(X86_FASTCALL) u32;

const lua_gc_full_collection: *const CollectFn = @ptrFromInt(0x6F73E0);
const lua_gc_shrink_memory: *const CollectFn = @ptrFromInt(0x6F7370);
const luaCallUserDataGC: *const CollectFn = @ptrFromInt(0x6F7080);
const lua_gc_sweep_all_lists: *const SweepAllFn = @ptrFromInt(0x6F72F0);
const lua_gc_remove_objects: *const RemoveObjectsFn = @ptrFromInt(0x6F7210);

var collect_hook: hook.Detour(CollectFn) = .{};
var lua_close_hook: hook.Detour(LuaCloseFn) = .{};

var installed = false;
var in_gc = false;
var closing_lua = false;

var sweeping = false;
var swept_head: u32 = 0;
var swept_tail: u32 = 0;
var unswept_rest: u32 = 0;
var saved_g: u32 = 0;

var birth_mark_owned = false;
var birth_mark_original: u8 = 0;

inline fn readU8(addr: usize) u8 {
    return @as(*volatile const u8, @ptrFromInt(addr)).*;
}

inline fn readU16(addr: usize) u16 {
    return @as(*volatile const u16, @ptrFromInt(addr)).*;
}

inline fn readU32(addr: u32) u32 {
    return @as(*volatile const u32, @ptrFromInt(addr)).*;
}

inline fn readU32usize(addr: usize) u32 {
    return @as(*volatile const u32, @ptrFromInt(addr)).*;
}

inline fn writeU32(addr: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = value;
}

inline fn getGlobalState(L: u32) u32 {
    return readU32(L + 0x10);
}

fn validateClient() bool {
    if (readU16(EXPECTED_IMAGE_BASE) != 0x5A4D) return false; // MZ

    const pe_off = readU32usize(EXPECTED_IMAGE_BASE + 0x3C);
    const pe = EXPECTED_IMAGE_BASE + pe_off;
    if (readU32usize(pe) != 0x00004550) return false; // PE\0\0
    if (readU16(pe + 4) != 0x014C) return false; // IMAGE_FILE_MACHINE_I386
    if (readU16(pe + 24) != 0x010B) return false; // PE32 optional header

    const image_size = readU32usize(pe + 24 + 56);
    return image_size == EXPECTED_IMAGE_SIZE;
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

    const current = readU8(BIRTH_MARK_ADDR);
    if (current != 0x00) return false;

    birth_mark_original = current;
    const patch = [1]u8{0x01};
    hook.writeProtected(BIRTH_MARK_ADDR, &patch);

    if (readU8(BIRTH_MARK_ADDR) != 0x01) return false;
    birth_mark_owned = true;
    return true;
}

fn releaseBirthMark() void {
    if (!birth_mark_owned) return;

    // Restore only while we still own exactly the byte we installed.
    if (readU8(BIRTH_MARK_ADDR) == 0x01) {
        const patch = [1]u8{birth_mark_original};
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
        if (tail != 0) {
            writeU32(tail + OBJ_NEXT, unswept_rest);
        } else {
            writeU32(g + GS_ROOTGC, unswept_rest);
        }
        tail = findTail(unswept_rest);
    }

    if (swept_head != 0) {
        if (tail != 0) {
            writeU32(tail + OBJ_NEXT, swept_head);
        } else {
            writeU32(g + GS_ROOTGC, swept_head);
        }
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

fn nativeFallback(L: u32) void {
    reconnectSweep();
    collect_hook.callOriginal(.{L});
}

fn collectGarbageDetour(L: u32) callconv(X86_FASTCALL) void {
    if (closing_lua) {
        collect_hook.callOriginal(.{L});
        return;
    }
    if (in_gc) return;
    if (L == 0) return;
    if (readU32(L + 0x60) == 0) return;

    in_gc = true;
    defer in_gc = false;

    const g = getGlobalState(L);
    if (g == 0) {
        collect_hook.callOriginal(.{L});
        return;
    }

    // Never carry private list state into another Lua global_State.
    if (sweeping and g != saved_g) {
        resetSweepState();
        collect_hook.callOriginal(.{L});
        return;
    }

    // If another module changed the birth byte during our split cycle,
    // reconnect immediately and hand this collection back to WoW.
    if (sweeping and (!birth_mark_owned or readU8(BIRTH_MARK_ADDR) != 0x01)) {
        nativeFallback(L);
        return;
    }

    if (!sweeping) {
        // Keep WoW's native mark, userdata sweep, and string sweep.
        lua_gc_full_collection(L);
        _ = lua_gc_remove_objects(L, g + GS_ROOTUDATA, 0);
        lua_gc_sweep_all_lists(L, 0);

        swept_head = 0;
        swept_tail = 0;

        const rootgc_head = readU32(g + GS_ROOTGC);
        const result = findNth(rootgc_head, CHUNK_SIZE);

        // Small rootgc lists remain one-shot, matching native behavior closely.
        if (result.obj == 0) {
            _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
            lua_gc_shrink_memory(L);
            luaCallUserDataGC(L);
            return;
        }

        // If the birth marker is unavailable, do not split this collection.
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

    const rootgc_head = readU32(g + GS_ROOTGC);
    const result = findNth(rootgc_head, CHUNK_SIZE);

    if (result.obj == 0) {
        _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);

        const current_head = readU32(g + GS_ROOTGC);
        if (swept_head != 0) {
            if (current_head != 0) {
                writeU32(swept_tail + OBJ_NEXT, current_head);
            }
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

fn luaCloseDetour(L: u32) callconv(X86_FASTCALL) void {
    // lua_close may run native sweep paths that bypass luaC_collectgarbage.
    // Reconnect every private fragment while the old Lua state is still valid.
    closing_lua = true;
    reconnectSweep();
    in_gc = false;

    lua_close_hook.callOriginal(.{L});

    closing_lua = false;
}

fn install() void {
    if (installed) return;
    if (!validateClient()) return;

    // Transactional install: lua_close guard first, collector second.
    // If the collector cannot attach, roll the close hook back immediately.
    if (lua_close_hook.attach(LUA_CLOSE_ADDR, &luaCloseDetour) != .ok) return;

    if (collect_hook.attach(LUA_COLLECT_GARBAGE_ADDR, &collectGarbageDetour) != .ok) {
        lua_close_hook.detach();
        return;
    }

    installed = true;
}

const version: [*:0]const u8 = "2.4-B1-gc-safe-sweep-abi";

pub export fn WeirdPerformanceGC24B_GetVersion() callconv(.c) [*:0]const u8 {
    return version;
}

pub export fn WeirdPerformanceGC24B_IsActive() callconv(.c) i32 {
    return if (installed) 1 else 0;
}

pub export fn DllMain(
    _: ?*anyopaque,
    reason: u32,
    _: ?*anyopaque,
) callconv(WINAPI) std.os.windows.BOOL {
    if (reason == 1) install();

    // Process-lifetime A/B companion. We intentionally do not hot-unhook
    // detours during process teardown.
    return @enumFromInt(1);
}
