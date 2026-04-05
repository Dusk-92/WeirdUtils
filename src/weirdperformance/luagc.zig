//! Incremental GC for Lua 5.0.
//!
//! The original stop-the-world GC freezes the game for up to 5 seconds.
//! This module splits the rootgc sweep across multiple GC triggers.
//!
//! Strategy:
//!   1. Mark + udata sweep + string sweep run atomically (mark is fast)
//!   2. Rootgc is split into chunks. Each chunk is swept by the original
//!      lua_gc_remove_objects. After sweeping, surviving objects are moved
//!      to a separate "swept" list so they can't be re-swept.
//!   3. After all chunks are processed, the swept list is reconnected.
//!
//! Birth-mark: binary patch in luaC_link makes new objects born marked=1
//! during sweep so they survive until the next GC cycle.

const hook = @import("zhook");

const GS_ROOTGC = 0x10;
const GS_ROOTUDATA = 0x14;
const GS_GCTHRESHOLD = 0x24;
const GS_TOTALBYTES = 0x28;
const OBJ_NEXT = 0x00;

const CHUNK_SIZE: u32 = 50000;
const BATCH_HEADROOM: u32 = 128 * 1024;

const lua_gc_full_collection: *const fn (u32) callconv(hook.cc.fastcall) void = @ptrFromInt(0x6F73E0);
const lua_gc_shrink_memory: *const fn (u32) callconv(hook.cc.fastcall) void = @ptrFromInt(0x6F7370);
const luaCallUserDataGC: *const fn (u32) callconv(hook.cc.fastcall) void = @ptrFromInt(0x6F7080);
const lua_gc_sweep_all_lists: *const fn (u32, u32) callconv(hook.cc.fastcall) void = @ptrFromInt(0x6F72F0);
const lua_gc_remove_objects: *const fn (u32, u32, u32) callconv(hook.cc.fastcall) u32 = @ptrFromInt(0x6F7210);

var sweeping: bool = false;
var in_gc: bool = false;

// The "already swept" list: objects that survived sweep, detached from rootgc.
// swept_head -> first swept survivor, swept_tail -> last (for O(1) append).
var swept_head: u32 = 0;
var swept_tail: u32 = 0;
var unsept_rest: u32 = 0;
var saved_g: u32 = 0; // global_State for cleanup in remove()

// Per-call timing via rdtsc
inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

const logging = @import("../logging.zig");
var gc_log: logging.Logger = .{};
var gc_log_open: bool = false;

fn logGc(comptime phase: []const u8, cycles: u64, extra: u32) void {
    if (!gc_log_open) {
        gc_log = logging.Logger.openAppend("luagc", .file);
        gc_log_open = true;
    }
    var buf: [128]u8 = undefined;
    const ms = cycles / 3000000; // ~3GHz approx
    const msg = @import("std").fmt.bufPrint(&buf, "{s}: {d}ms ({d}Kcyc) extra={d}\n", .{ phase, ms, cycles / 1000, extra }) catch return;
    gc_log.print(msg);
}

const BIRTH_MARK_ADDR: usize = 0x6F7B37;

fn setBirthMark(marked: bool) void {
    const val = [1]u8{if (marked) 0x01 else 0x00};
    hook.writeProtected(BIRTH_MARK_ADDR, &val);
}

fn readU32(addr: u32) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}

fn writeU32(addr: u32, val: u32) void {
    @as(*u32, @ptrFromInt(addr)).* = val;
}

fn getGlobalState(L: u32) u32 {
    return @as(*const u32, @ptrFromInt(L + 0x10)).*;
}

/// Walk the list from a head pointer, find the Nth object.
/// Returns (obj_addr, count_walked). obj_addr=0 if list shorter than N.
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

/// Find the tail of a singly-linked list (last non-NULL node).
fn findTail(head: u32) u32 {
    var obj = head;
    if (obj == 0) return 0;
    while (readU32(obj + OBJ_NEXT) != 0) {
        obj = readU32(obj + OBJ_NEXT);
    }
    return obj;
}

/// Detach the current rootgc list (after sweep) and append to swept list.
/// Then point rootgc at unsept_rest.
fn detachSweptAndRestore(g: u32) void {
    const current_head = readU32(g + GS_ROOTGC);
    if (current_head != 0) {
        // Append current rootgc (swept survivors) to our swept list
        const tail = findTail(current_head);
        if (swept_head == 0) {
            swept_head = current_head;
            swept_tail = tail;
        } else {
            writeU32(swept_tail + OBJ_NEXT, current_head);
            swept_tail = tail;
        }
    }
    // Point rootgc at the unsept remainder
    writeU32(g + GS_ROOTGC, unsept_rest);
    unsept_rest = 0;
}

fn collectGarbageDetour(L: u32) callconv(hook.cc.fastcall) void {
    if (in_gc) return;
    if (@as(*const u32, @ptrFromInt(L + 0x60)).* == 0) return;
    in_gc = true;
    defer in_gc = false;

    const g = getGlobalState(L);

    if (!sweeping) {
        // === Atomic: mark + udata sweep + string sweep ===
        const t0 = rdtsc();
        lua_gc_full_collection(L);
        const t1 = rdtsc();
        _ = lua_gc_remove_objects(L, g + GS_ROOTUDATA, 0);
        lua_gc_sweep_all_lists(L, 0);
        const t2 = rdtsc();
        logGc("mark", t1 - t0, 0);
        logGc("udata+str", t2 - t1, 0);

        // Initialize swept list
        swept_head = 0;
        swept_tail = 0;

        // Check if rootgc is short enough to sweep in one go
        const rootgc_head = readU32(g + GS_ROOTGC);
        const result = findNth(rootgc_head, CHUNK_SIZE);
        if (result.obj == 0) {
            // Short list, sweep all at once
            _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
            lua_gc_shrink_memory(L);
            luaCallUserDataGC(L);
            return;
        }

        // Truncate rootgc at the chunk boundary
        unsept_rest = readU32(result.obj + OBJ_NEXT);
        writeU32(result.obj + OBJ_NEXT, 0);

        sweeping = true;
        saved_g = g;
        setBirthMark(true);

        // Sweep the truncated chunk
        const ts0 = rdtsc();
        _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
        detachSweptAndRestore(g);
        logGc("chunk0", rdtsc() - ts0, CHUNK_SIZE);

        const totalbytes = readU32(g + GS_TOTALBYTES);
        writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
        return;
    }

    // === Continue incremental sweep ===
    // rootgc currently points at the unsept portion (+ any new objects at head).
    // New objects born during sweep have marked=1 and will survive.

    const rootgc_head = readU32(g + GS_ROOTGC);
    const result = findNth(rootgc_head, CHUNK_SIZE);

    const tc0 = rdtsc();

    if (result.obj == 0) {
        // Remaining list fits in one sweep -- finish
        _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);

        // Reconnect swept list
        const current_head = readU32(g + GS_ROOTGC);
        if (swept_head != 0) {
            if (current_head != 0) {
                writeU32(swept_tail + OBJ_NEXT, current_head);
            }
            writeU32(g + GS_ROOTGC, swept_head);
        }

        swept_head = 0;
        swept_tail = 0;
        sweeping = false;
        setBirthMark(false);
        logGc("final", rdtsc() - tc0, result.count);

        lua_gc_shrink_memory(L);
        luaCallUserDataGC(L);
        return;
    }

    // Truncate and sweep next chunk
    unsept_rest = readU32(result.obj + OBJ_NEXT);
    writeU32(result.obj + OBJ_NEXT, 0);

    _ = lua_gc_remove_objects(L, g + GS_ROOTGC, 0);
    detachSweptAndRestore(g);
    logGc("chunkN", rdtsc() - tc0, CHUNK_SIZE);

    const totalbytes = readU32(g + GS_TOTALBYTES);
    writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
}

pub fn dumpStats() void {
    if (gc_log_open) {
        gc_log.close();
        gc_log_open = false;
    }
}

const CollectFn = fn (u32) callconv(hook.cc.fastcall) void;
var collect_hook: hook.Detour(CollectFn) = .{};

pub fn install() u32 {
    var installed: u32 = 0;
    if (collect_hook.attach(0x6F7340, &collectGarbageDetour) == .ok) installed += 1;
    return installed;
}

pub fn remove() void {
    if (sweeping and saved_g != 0) {
        // Reconnect: rootgc -> current + unsept + swept
        const g = saved_g;
        var tail = findTail(readU32(g + GS_ROOTGC));
        if (unsept_rest != 0) {
            if (tail != 0) {
                writeU32(tail + OBJ_NEXT, unsept_rest);
                tail = findTail(unsept_rest);
            } else {
                writeU32(g + GS_ROOTGC, unsept_rest);
                tail = findTail(unsept_rest);
            }
        }
        if (swept_head != 0) {
            if (tail != 0) {
                writeU32(tail + OBJ_NEXT, swept_head);
            } else {
                writeU32(g + GS_ROOTGC, swept_head);
            }
        }
        setBirthMark(false);
    }
    collect_hook.detach();
    sweeping = false;
    swept_head = 0;
    swept_tail = 0;
}
