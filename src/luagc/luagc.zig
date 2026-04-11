//! From-scratch incremental GC for Lua 5.0 (WoW 1.12.1 build 5875).
//!
//! Replaces WoW's stop-the-world mark+sweep with a chunked incremental GC.
//! Each call to luaC_collectgarbage processes one chunk of work (~5000 objects,
//! target <2ms) then yields. A state machine tracks progress across calls:
//!
//!   idle -> marking -> atomic -> sweeping -> sweep_strings -> finalize -> idle
//!
//! The module also owns allocation via a slab allocator (luaalloc.zig).
//!
//! Only two native GC functions are called:
//!   - lua_gc_free_object (0x6F7260): type-dispatch free
//!   - luaCallUserDataGC  (0x6F7080): runs __gc metamethods
//!   - luaC_separateudata (0x6F6FF0): moves dead __gc udata to tmudata
//!
//! Everything else (mark, sweep, string sweep, threshold, marktmu, weak table
//! clearing) is implemented from scratch.
//!
//! ## Tri-color incremental mark
//!   WHITE = marked bit 0 (unprocessed)
//!   GRAY  = in gray stack (pending traversal)
//!   BLACK = marked bit 1 (processed, children traversed)
//!
//! Write barriers on table writes push BLACK tables back to gray during mark.

const std = @import("std");
const offsets = @import("lua_offsets.zig");
const hook = @import("zhook");
const lua = @import("../lua.zig");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");
const luaalloc = @import("luaalloc.zig");

pub const module_name: [*:0]const u8 = "luagc";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

// =============================================================================
// Runtime stats (exposed to Lua via ZGCStats() global function)
// =============================================================================

const Stats = struct {
    cycles_total: u32 = 0,
    mark_steps_last: u32 = 0,
    sweep_steps_last: u32 = 0,
    gray_peak: u32 = 0,
    dead_freed_last: u32 = 0,
    strings_freed_last: u32 = 0,
};

var stats: Stats = .{};

// In-progress counters copied to Stats at cycle end.
var cur_mark_steps: u32 = 0;
var cur_sweep_steps: u32 = 0;
var cur_dead_freed: u32 = 0;
var cur_strings_freed: u32 = 0;

// =============================================================================
// GC State Machine
// =============================================================================

const Phase = enum(u8) {
    /// No collection in progress. Next trigger starts a new cycle.
    idle = 0,
    /// Incremental mark: draining gray stack in chunks.
    marking = 1,
    /// Atomic phase: weak table clear, separateudata, marktmu, final propagate.
    /// Runs to completion in a single call (bounded by tmudata size).
    atomic = 2,
    /// Incremental sweep of rootgc list.
    sweeping = 3,
    /// Incremental sweep of string hash buckets.
    sweep_strings = 4,
    /// Atomic: run __gc finalizers + set threshold. Short.
    finalize = 5,
};

var phase: Phase = .idle;
var saved_L: u32 = 0;
var saved_g: u32 = 0;

/// Objects to process per step. ~5000 = ~2ms target per step.
const CHUNK_SIZE: u32 = 5000;

// =============================================================================
// Gray Stack
// =============================================================================

const GRAY_STACK_SIZE: u32 = 524288; // 2MB, covers 200k object heap
var gray_stack: [GRAY_STACK_SIZE]u32 = undefined;
var gray_count: u32 = 0;

fn grayStackPush(obj: u32) void {
    if (gray_count < GRAY_STACK_SIZE) {
        gray_stack[gray_count] = obj;
        gray_count += 1;
        if (gray_count > stats.gray_peak) stats.gray_peak = gray_count;
    }
}

fn grayStackPop() u32 {
    if (gray_count == 0) return 0;
    gray_count -= 1;
    return gray_stack[gray_count];
}

// =============================================================================
// Gray-Again List (barrier back)
// =============================================================================
//
// During incremental mark, the write barrier does NOT push tables back to the
// main gray stack (that causes livelock under heavy allocation). Instead,
// written-to BLACK tables go on the grayagain list. They're re-traversed once
// during the atomic phase, catching all mutations since their last traversal.
// This matches Lua 5.1's luaC_barrierback / grayagain pattern.

const GRAYAGAIN_SIZE: u32 = 65536;
var grayagain_list: [GRAYAGAIN_SIZE]u32 = undefined;
var grayagain_count: u32 = 0;

fn grayagainAdd(table: u32) void {
    if (grayagain_count < GRAYAGAIN_SIZE) {
        grayagain_list[grayagain_count] = table;
        grayagain_count += 1;
    }
}

// =============================================================================
// Incremental Sweep Cursors
// =============================================================================

/// For rootgc sweep: pointer to the "next" field that points to current obj.
/// This is &(prev->next) or &(g->rootgc). Allows in-place unlinking.
var sweep_prev_next: u32 = 0;

/// For string sweep: current bucket index.
var sweep_string_bucket: u32 = 0;

// =============================================================================
// Weak Table Tracking
// =============================================================================

const WEAK_TABLE_LIST_SIZE: u32 = 4096;
var weak_table_list: [WEAK_TABLE_LIST_SIZE]u32 = undefined;
var weak_table_count: u32 = 0;

fn weakTableListAdd(table: u32) void {
    if (weak_table_count < WEAK_TABLE_LIST_SIZE) {
        weak_table_list[weak_table_count] = table;
        weak_table_count += 1;
    }
}

// =============================================================================
// Bootstrap
// =============================================================================

/// First cycle flag: existing objects from native GC have marked=0 (neither
/// white). On the first cycle, walk all objects and set them to currentwhite
/// so our mark can find them.
var needs_bootstrap: bool = true;

/// Update the string creation birth mark byte to match currentwhite.
/// Strings bypass luaC_link and have their own `MOV byte [EBX+5], 0x00`
/// at 0x6F9DC1. We patch this immediate to currentwhite.
/// Sync birth mark patches for objects that bypass luaC_link.
/// Strings: lua_create_string_object writes marked at 0x6F9DC1.
/// Upvalues: lua_create_open_upvalue writes marked at 0x6F9F48.
fn syncBirthMarks() void {
    var patch = [1]u8{currentwhite};
    hook.writeProtected(offsets.birth_mark_string, &patch);
    hook.writeProtected(offsets.birth_mark_upvalue, &patch);
}

fn bootstrapWhite(g: u32) void {
    // Walk rootgc and set currentwhite, preserving non-color flags.
    // Uses makewhite pattern: (marked & MASKMARKS) | currentwhite
    // This preserves KEYWEAK, VALUEWEAK, FINALIZED, FIXED bits.
    var obj = readU32(g + offsets.GS_rootgc);
    while (obj != 0) {
        writeU8(obj + offsets.OBJ_marked, (readU8(obj + offsets.OBJ_marked) & offsets.MASKMARKS) | currentwhite);
        obj = readU32(obj + offsets.OBJ_next);
    }
    // Walk rootudata
    obj = readU32(g + offsets.GS_rootudata);
    while (obj != 0) {
        writeU8(obj + offsets.OBJ_marked, (readU8(obj + offsets.OBJ_marked) & offsets.MASKMARKS) | currentwhite);
        obj = readU32(obj + offsets.OBJ_next);
    }
    // Walk string hash table
    const hash_array = readU32(g + offsets.GS_strt_hash);
    const bucket_count = readU32(g + offsets.GS_strt_size);
    if (hash_array != 0) {
        var bi: u32 = 0;
        while (bi < bucket_count) : (bi += 1) {
            var s = readU32(hash_array + bi * 4);
            while (s != 0) {
                // Preserve FIXED bit (bit 4), set currentwhite
                const old = readU8(s + offsets.OBJ_marked);
                writeU8(s + offsets.OBJ_marked, (old & (1 << offsets.FIXEDBIT)) | currentwhite);
                s = readU32(s + offsets.OBJ_next);
            }
        }
    }
    // Mainthread (not in rootgc in WoW)
    const mt = readU32(g + offsets.GS_mainthread);
    if (mt != 0) writeU8(mt + offsets.OBJ_marked, currentwhite);

    needs_bootstrap = false;
    log.print("bootstrap: set all objects to currentwhite\n");
}

// =============================================================================
// Re-entrance Guard
// =============================================================================

var in_gc: bool = false;

// =============================================================================
// Forward declarations of native functions
// =============================================================================

const lua_gc_free_object_fn = *const fn (u32, u32) callconv(hook.cc.fastcall) void;
const luaCallUserDataGC_fn = *const fn (u32) callconv(hook.cc.fastcall) void;
const luaC_separateudata_fn = *const fn (u32) callconv(hook.cc.fastcall) void;
const lua_string_hash_resize_fn = *const fn (u32, u32) callconv(hook.cc.fastcall) void;

const native_mark_fn = *const fn (u32) callconv(hook.cc.fastcall) u32; // mark() returns deadmem
const native_sweep_fn = *const fn (u32, u32) callconv(hook.cc.fastcall) void; // luaC_sweep(L, all)
const native_checkSizes_fn = *const fn (u32) callconv(hook.cc.fastcall) void; // checkSizes wraps shrink

const native_free_object: lua_gc_free_object_fn = @ptrFromInt(offsets.lua_gc_free_object);
const native_callGCTM: luaCallUserDataGC_fn = @ptrFromInt(offsets.luaCallUserDataGC);
const native_separateudata: luaC_separateudata_fn = @ptrFromInt(offsets.luaC_separateudata);
const native_string_hash_resize: lua_string_hash_resize_fn = @ptrFromInt(offsets.lua_string_hash_resize);
const native_mark: native_mark_fn = @ptrFromInt(offsets.lua_gc_full_collection);
const native_shrink_memory: native_checkSizes_fn = @ptrFromInt(offsets.lua_gc_shrink_memory);

// =============================================================================
// Utility
// =============================================================================

inline fn readU32(addr: u32) u32 {
    return @as(*const volatile u32, @ptrFromInt(addr)).*;
}

inline fn writeU32(addr: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

inline fn readU8(addr: u32) u8 {
    return @as(*const volatile u8, @ptrFromInt(addr)).*;
}

inline fn writeU8(addr: u32, val: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
}

fn getGlobalState(L: u32) u32 {
    return readU32(L + offsets.L_global);
}

inline fn objType(obj: u32) u8 {
    return readU8(obj + offsets.OBJ_tt);
}

// =============================================================================
// Tri-color system (Lua 5.1 lgc.h port)
// =============================================================================
//
// Colors:
//   WHITE = has a white bit set (WHITE0 or WHITE1). Unprocessed / new.
//   GRAY  = no white bits, no black bit. Found but children not yet processed.
//   BLACK = bit 2 set. Fully traversed.
//
// Two whites: currentwhite alternates between WHITE0 (0x01) and WHITE1 (0x02)
// each cycle. New objects are born with currentwhite. Sweep kills objects
// with "otherwhite" (the previous cycle's white). Objects with currentwhite
// (born during this cycle) or BLACK survive.
//
// This eliminates birth mark entirely: objects born during sweep have
// currentwhite which is NOT otherwhite, so they survive automatically.

/// Current white color bit. Alternates between 0x01 (WHITE0) and 0x02 (WHITE1).
var currentwhite: u8 = 0x01;

/// The dead color for sweep: whichever white ISN'T current.
inline fn otherwhite() u8 {
    return currentwhite ^ offsets.WHITEBITS;
}

/// Is the object white (has either white bit set)?
inline fn isWhite(obj: u32) bool {
    return (readU8(obj + offsets.OBJ_marked) & offsets.WHITEBITS) != 0;
}

/// Is the object black (bit 2 set)?
inline fn isBlack(obj: u32) bool {
    return (readU8(obj + offsets.OBJ_marked) & (1 << offsets.BLACKBIT)) != 0;
}

/// Is the object dead? Has otherwhite set AND is not fixed.
/// Base check from 5.1: `(marked & otherwhite(g) & WHITEBITS)`.
/// WoW extension: FIXED objects (bit 4, luaS_fix) are never dead -- they
/// aren't traversed as roots but must survive (reserved words, tmnames).
inline fn isDead(obj: u32) bool {
    const marked = readU8(obj + offsets.OBJ_marked);
    if ((marked & (1 << offsets.FIXEDBIT)) != 0) return false;
    return (marked & otherwhite() & offsets.WHITEBITS) != 0;
}

/// WHITE -> GRAY: clear both white bits. Object is now gray (pending traversal).
inline fn white2gray(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, readU8(obj + offsets.OBJ_marked) & ~offsets.WHITEBITS);
}

/// GRAY -> BLACK: set the black bit.
inline fn gray2black(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, readU8(obj + offsets.OBJ_marked) | (1 << offsets.BLACKBIT));
}

/// BLACK -> GRAY: clear the black bit. Used for barrier-back (table written to).
inline fn black2gray(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, readU8(obj + offsets.OBJ_marked) & ~@as(u8, 1 << offsets.BLACKBIT));
}

/// Set object to current white, clearing all color bits first.
/// Preserves non-color flags (KEYWEAK, VALUEWEAK, FIXED, FINALIZED).
/// Used by sweep on surviving objects.
inline fn makewhite(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, (readU8(obj + offsets.OBJ_marked) & offsets.MASKMARKS) | currentwhite);
}

/// Mark an object: matches Lua 5.1 reallymarkobject (lgc.c:69-112).
/// Strings just get stringmarked (no gray). Userdata go black immediately.
/// Tables, closures, threads, protos go to gray stack.
fn markObject(obj: u32) bool {
    if (!isWhite(obj)) return false;
    const tt = objType(obj);
    switch (tt) {
        offsets.LUA_TSTRING => {
            // Strings: just clear white bits, don't go to gray (no children)
            stringmark(obj);
            return true;
        },
        offsets.LUA_TUSERDATA => {
            // Userdata: go black immediately, mark metatable inline
            white2gray(obj);
            gray2black(obj);
            const mt = readU32(obj + offsets.UDATA_metatable);
            if (mt != 0) _ = markObject(mt);
            return true;
        },
        else => {
            // Tables, closures, threads, protos: go to gray stack
            white2gray(obj);
            grayStackPush(obj);
            return true;
        },
    }
}

/// For strings: mark by clearing white bits (stringmark). Strings don't
/// go to gray (no children to traverse).
inline fn stringmark(s: u32) void {
    writeU8(s + offsets.OBJ_marked, readU8(s + offsets.OBJ_marked) & ~offsets.WHITEBITS);
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "???";
}

// =============================================================================
// Mark: Traverse One Object's Children
// =============================================================================

// Debug counters per type (reset each cycle)
var dbg_table_count: u32 = 0;
var dbg_closure_count: u32 = 0;
var dbg_thread_count: u32 = 0;
var dbg_proto_count: u32 = 0;
var dbg_udata_count: u32 = 0;
var dbg_other_count: u32 = 0;

/// Pop a gray object, turn it black, and traverse its children.
/// Matches Lua 5.1 propagatemark (lgc.c:277-320).
/// THREADS: never go black. They go to grayagain and stay gray.
/// WEAK TABLES: go back to gray after traversal (black2gray).
fn propagatemark(obj: u32) void {
    const tt = objType(obj);
    switch (tt) {
        offsets.LUA_TTABLE => {
            dbg_table_count += 1;
            gray2black(obj);
            const is_weak = traverseTable(obj);
            if (is_weak) black2gray(obj); // weak tables stay gray
        },
        offsets.LUA_TFUNCTION => {
            dbg_closure_count += 1;
            gray2black(obj);
            traverseClosure(obj);
        },
        offsets.LUA_TTHREAD => {
            // Lua 5.1: threads NEVER go black. After traversal, add to
            // grayagain so the atomic phase re-traverses the stack.
            dbg_thread_count += 1;
            traverseThread(obj);
            grayagainAdd(obj); // stays gray, re-traversed in atomic
        },
        offsets.LUA_TPROTO => {
            dbg_proto_count += 1;
            gray2black(obj);
            traverseProto(obj);
        },
        offsets.LUA_TUSERDATA => {
            // Should not reach here -- userdata goes black in markObject.
            // But handle gracefully.
            dbg_udata_count += 1;
            gray2black(obj);
        },
        else => {
            dbg_other_count += 1;
        },
    }
}

/// Detect __mode on a table's metatable and set KEYWEAK/VALUEWEAK bits.
/// Matches native traversetable behavior (lgc.c:157-170).
///
/// metatable->flags byte (Table+0x06) caches TM presence: if bit 3 (TM_MODE)
/// is set, __mode definitely doesn't exist. If not set, we scan the metatable's
/// hash nodes for a string key matching "__mode".
///
/// TString layout: content at +0x10, length at +0x0C.
fn detectAndSetWeakFlags(table: u32, mt: u32) void {
    // Fast path: check metatable flags cache for TM_MODE (bit 3)
    const mt_flags = readU8(mt + offsets.TABLE_flags);
    if ((mt_flags & 0x08) != 0) return; // TM_MODE cached as absent

    // Scan metatable hash nodes for __mode key
    const mt_node_ptr = readU32(mt + offsets.TABLE_node);
    if (mt_node_ptr == 0) return;
    const mt_lsize = readU8(mt + offsets.TABLE_lsizenode);
    const mt_sizenode: u32 = @as(u32, 1) << @as(u5, @intCast(mt_lsize));

    var mode_str: u32 = 0; // the TString* of the __mode value
    var ni: u32 = 0;
    while (ni < mt_sizenode) : (ni += 1) {
        const node = mt_node_ptr + ni * offsets.NODE_size;
        // Key must be a string (type 4)
        if (readU8(node + offsets.NODE_key_tt) != offsets.LUA_TSTRING) continue;
        // Value must be non-nil
        if (readU8(node + offsets.NODE_value_tt) == 0) continue;

        const key_str = readU32(node + offsets.NODE_key_gcptr);
        if (key_str == 0) continue;

        // Check string content: length must be 6 ("__mode")
        const len = readU32(key_str + 0x0C);
        if (len != 6) continue;

        // Compare content at TString+0x10
        const data: [*]const u8 = @ptrFromInt(key_str + 0x10);
        if (data[0] == '_' and data[1] == '_' and data[2] == 'm' and
            data[3] == 'o' and data[4] == 'd' and data[5] == 'e')
        {
            // Found __mode. Value must be a string.
            if (readU8(node + offsets.NODE_value_tt) != offsets.LUA_TSTRING) break;
            mode_str = readU32(node + offsets.NODE_value_gcptr);
            break;
        }
    }

    // Clear old weak bits, then set based on __mode string content
    var marked = readU8(table + offsets.OBJ_marked);
    marked &= ~(offsets.KEYWEAK | offsets.VALUEWEAK);

    if (mode_str != 0) {
        const mode_len = readU32(mode_str + 0x0C);
        const mode_data: [*]const u8 = @ptrFromInt(mode_str + 0x10);
        var weakkey = false;
        var weakvalue = false;
        var mi: u32 = 0;
        while (mi < mode_len) : (mi += 1) {
            if (mode_data[mi] == 'k') weakkey = true;
            if (mode_data[mi] == 'v') weakvalue = true;
        }
        if (weakkey) marked |= offsets.KEYWEAK;
        if (weakvalue) marked |= offsets.VALUEWEAK;
    }

    writeU8(table + offsets.OBJ_marked, marked);
}

/// Traverse a table's children. Returns true if the table is weak.
/// Matches Lua 5.1 traversetable (lgc.c:158-196).
fn traverseTable(table: u32) bool {
    const mt = readU32(table + offsets.TABLE_metatable);
    if (mt != 0) {
        _ = markObject(mt);
        detectAndSetWeakFlags(table, mt);
    } else {
        // No metatable: clear any stale weak flags from previous cycles.
        // Without this, a table that lost its metatable (setmetatable(t, nil))
        // would keep old KEYWEAK/VALUEWEAK bits and be treated as weak.
        const m = readU8(table + offsets.OBJ_marked);
        if ((m & (offsets.KEYWEAK | offsets.VALUEWEAK)) != 0) {
            writeU8(table + offsets.OBJ_marked, m & ~(offsets.KEYWEAK | offsets.VALUEWEAK));
        }
    }

    const marked = readU8(table + offsets.OBJ_marked);
    const weakkey = (marked & offsets.KEYWEAK) != 0;
    const weakvalue = (marked & offsets.VALUEWEAK) != 0;
    const is_weak = weakkey or weakvalue;

    // 5.1: if both-weak, return early (only metatable marked)
    if (weakkey and weakvalue) {
        if (is_weak) weakTableListAdd(table);
        return true;
    }

    // Array: skip if value-weak
    if (!weakvalue) {
        const array_ptr = readU32(table + offsets.TABLE_array);
        const sizearray = readU32(table + offsets.TABLE_sizearray);
        if (array_ptr != 0) {
            var i: u32 = 0;
            while (i < sizearray) : (i += 1) {
                const tv = array_ptr + i * offsets.TVALUE_size;
                const tt = readU8(tv + offsets.TVALUE_tt);
                if (tt >= offsets.LUA_TSTRING) {
                    const gc = readU32(tv + offsets.TVALUE_gcptr);
                    if (gc != 0) _ = markObject(gc);
                }
            }
        }
    }

    // Hash: condmarkobject(key, !weakkey); condmarkobject(value, !weakvalue)
    const node_ptr = readU32(table + offsets.TABLE_node);
    if (node_ptr == 0) {
        if (is_weak) weakTableListAdd(table);
        return is_weak;
    }
    const lsizenode = readU8(table + offsets.TABLE_lsizenode);
    const sizenode: u32 = @as(u32, 1) << @as(u5, @intCast(lsizenode));

    var ni: u32 = 0;
    while (ni < sizenode) : (ni += 1) {
        const node = node_ptr + ni * offsets.NODE_size;
        const val_tt = readU8(node + offsets.NODE_value_tt);
        if (val_tt == 0) continue; // dead node, skip (5.0 leaves key as-is)

        if (!weakkey) {
            const key_tt = readU8(node + offsets.NODE_key_tt);
            if (key_tt >= offsets.LUA_TSTRING) {
                const key_gc = readU32(node + offsets.NODE_key_gcptr);
                if (key_gc != 0) _ = markObject(key_gc);
            }
        }

        if (!weakvalue) {
            if (val_tt >= offsets.LUA_TSTRING) {
                const val_gc = readU32(node + offsets.NODE_value_gcptr);
                if (val_gc != 0) _ = markObject(val_gc);
            }
        }
    }

    if (is_weak) weakTableListAdd(table);
    return is_weak;
}

/// Traverse closure children. Matches Lua 5.1 traverseclosure (lgc.c:224-238).
fn traverseClosure(cl: u32) void {
    const isC = readU8(cl + offsets.CLOSURE_isC);
    const nups = readU8(cl + offsets.CLOSURE_nupvalues);

    if (isC != 0) {
        var i: u32 = 0;
        while (i < nups) : (i += 1) {
            const tv = cl + offsets.CLOSURE_c_upvals + i * offsets.TVALUE_size;
            const tt = readU8(tv + offsets.TVALUE_tt);
            if (tt >= offsets.LUA_TSTRING) {
                const gc = readU32(tv + offsets.TVALUE_gcptr);
                if (gc != 0) _ = markObject(gc);
            }
        }
    } else {
        // Lua closure: mark env table + proto
        const m1 = readU32(cl + offsets.CLOSURE_lua_mark1);
        if (m1 != 0) _ = markObject(m1);
        const m2 = readU32(cl + offsets.CLOSURE_lua_mark2);
        if (m2 != 0) _ = markObject(m2);

        // Upvalues: 5.1 reallymarkobject for LUA_TUPVAL (lgc.c:83-88):
        //   white2gray(o), markvalue(g, uv->v), if closed: gray2black(o)
        // We must make the upvalue itself non-white so sweep doesn't free it.
        // Don't push to gray stack (upvals have no children to traverse).
        var i: u32 = 0;
        while (i < nups) : (i += 1) {
            const upv = readU32(cl + offsets.CLOSURE_lua_upval_ptrs + i * 4);
            if (upv == 0) continue;

            // Make upvalue non-white (gray) so it survives sweep.
            if (isWhite(upv)) {
                white2gray(upv);
            }

            // Mark the upvalue's held value. Must dereference upval->v (+0x08)
            // which points to the ACTUAL value location:
            //   - Open upvalues: v points into the Lua stack
            //   - Closed upvalues: v points to the inline copy at upval+0x10
            // Reading upval+0x10 directly is WRONG for open upvalues (stale data).
            const v_ptr = readU32(upv + 0x08); // upval->v
            if (v_ptr != 0) {
                const val_tt = readU8(v_ptr + offsets.TVALUE_tt);
                if (val_tt >= offsets.LUA_TSTRING) {
                    const val_gc = readU32(v_ptr + offsets.TVALUE_gcptr);
                    if (val_gc != 0) _ = markObject(val_gc);
                }
            }
        }
    }
}

/// Traverse a thread: globals table + stack slots up to max(top, all ci->top).
fn traverseThread(th: u32) void {
    // Globals table TValue at thread+0x40..+0x48
    const gt_tt = readU8(th + offsets.THREAD_gt_tt);
    if (gt_tt >= offsets.LUA_TSTRING) {
        const gt_gc = readU32(th + offsets.THREAD_gt_gcptr);
        if (gt_gc != 0) _ = markObject(gt_gc);
    }

    // lim = max(L->top, all ci->top)
    var lim: u32 = readU32(th + offsets.THREAD_top);
    const base_ci = readU32(th + offsets.THREAD_base_ci);
    const ci = readU32(th + offsets.THREAD_ci);
    if (base_ci != 0 and ci != 0 and base_ci <= ci) {
        var ca: u32 = base_ci;
        while (ca <= ci) : (ca += 24) {
            const ci_top = readU32(ca + 0x04);
            if (ci_top > lim) lim = ci_top;
        }
    }

    const stack_base = readU32(th + offsets.THREAD_stack);
    const top = readU32(th + offsets.THREAD_top);
    if (stack_base == 0 or top == 0 or stack_base >= top) return;

    // Mark active stack slots: [stack, top)
    var sp: u32 = stack_base;
    while (sp < top) : (sp += offsets.TVALUE_size) {
        const tt = readU8(sp + offsets.TVALUE_tt);
        if (tt >= offsets.LUA_TSTRING) {
            const gc = readU32(sp + offsets.TVALUE_gcptr);
            if (gc != 0) _ = markObject(gc);
        }
    }

    // Nil stale slots above top: [top, lim]
    // Matches native: `for (; o <= lim; o++) setnilvalue(o);`
    // Without this, stale GC pointers from dead call frames keep dead objects alive.
    if (lim > top) {
        sp = top;
        while (sp <= lim) : (sp += offsets.TVALUE_size) {
            writeU32(sp + offsets.TVALUE_tt, 0); // tt = LUA_TNIL
            writeU32(sp + offsets.TVALUE_gcptr, 0); // value = 0
        }
    }
}

/// Traverse proto: source, constants, nested protos, upvalue names, locvars.
fn traverseProto(proto: u32) void {
    const source = readU32(proto + offsets.PROTO_source);
    if (source != 0) stringmark(source);

    // Constants: mark strings, mark non-string collectables
    const k_ptr = readU32(proto + offsets.PROTO_k);
    const sizek = readU32(proto + offsets.PROTO_sizek);
    if (k_ptr != 0) {
        var i: u32 = 0;
        while (i < sizek) : (i += 1) {
            const tv = k_ptr + i * offsets.TVALUE_size;
            const tt = readU8(tv + offsets.TVALUE_tt);
            if (tt == offsets.LUA_TSTRING) {
                const s = readU32(tv + offsets.TVALUE_gcptr);
                if (s != 0) stringmark(s);
            } else if (tt >= offsets.LUA_TSTRING) {
                const gc = readU32(tv + offsets.TVALUE_gcptr);
                if (gc != 0) _ = markObject(gc);
            }
        }
    }

    const upv_ptr = readU32(proto + offsets.PROTO_upvalues);
    const sizeup = readU32(proto + offsets.PROTO_sizeupvalues);
    if (upv_ptr != 0) {
        var i: u32 = 0;
        while (i < sizeup) : (i += 1) {
            const s = readU32(upv_ptr + i * 4);
            if (s != 0) stringmark(s);
        }
    }

    const p_ptr = readU32(proto + offsets.PROTO_p);
    const sizep = readU32(proto + offsets.PROTO_sizep);
    if (p_ptr != 0) {
        var i: u32 = 0;
        while (i < sizep) : (i += 1) {
            const sub = readU32(p_ptr + i * 4);
            if (sub != 0) _ = markObject(sub);
        }
    }

    const lv_ptr = readU32(proto + offsets.PROTO_locvars);
    const sizelv = readU32(proto + offsets.PROTO_sizelocvars);
    if (lv_ptr != 0) {
        var i: u32 = 0;
        while (i < sizelv) : (i += 1) {
            const s = readU32(lv_ptr + i * offsets.LOCVAR_size);
            if (s != 0) stringmark(s);
        }
    }
}

// =============================================================================
// Root Mark
// =============================================================================

/// Mark root set. Matches Lua 5.1 markroot (lgc.c:501-512).
fn markroot(g: u32) void {
    gray_count = 0;
    grayagain_count = 0;
    weak_table_count = 0;

    // defaultmeta
    if (readU8(g + 0x40) >= offsets.LUA_TTABLE) {
        const dm = readU32(g + offsets.GS_defaultmeta);
        if (dm != 0) _ = markObject(dm);
    }

    // registry
    if (readU8(g + 0x30) >= offsets.LUA_TTABLE) {
        const reg = readU32(g + offsets.GS_registry);
        if (reg != 0) _ = markObject(reg);
    }

    // mainthread -- not created via luaC_link (lua_open assigns directly).
    // Ensure it has currentwhite so markObject can find it.
    const mt = readU32(g + offsets.GS_mainthread);
    if (!isWhite(mt)) makewhite(mt);
    _ = markObject(mt);

    // Make global table be traversed before main stack (5.1 line 508)
    const gt_tt = readU8(mt + offsets.THREAD_gt_tt);
    if (gt_tt >= offsets.LUA_TSTRING) {
        const gt_gc = readU32(mt + offsets.THREAD_gt_gcptr);
        if (gt_gc != 0) _ = markObject(gt_gc);
    }

    // current L if different (also may bypass luaC_link)
    if (saved_L != 0 and saved_L != mt) {
        if (!isWhite(saved_L)) makewhite(saved_L);
        _ = markObject(saved_L);
    }
}

// =============================================================================
// Incremental Mark Step
// =============================================================================

/// Process up to CHUNK_SIZE objects from the gray stack.
/// Returns true when gray stack is drained (mark complete).
fn markStep() bool {
    cur_mark_steps += 1;
    var processed: u32 = 0;

    while (gray_count > 0 and processed < CHUNK_SIZE) {
        const obj = grayStackPop();
        if (obj == 0) break;
        propagatemark(obj);
        processed += 1;
    }

    return gray_count == 0;
}

/// Drain the entire gray stack (used in atomic phase).
fn propagateall() void {
    while (gray_count > 0) {
        const obj = grayStackPop();
        if (obj == 0) break;
        propagatemark(obj);
    }
}

// =============================================================================
// Atomic Phase (between mark and sweep)
// =============================================================================
//
// Matches Lua 5.0 lgc.c mark() ordering:
//   1. cleartablevalues(wkv, wv)
//   2. luaC_separateudata(L)
//   3. marktmu
//   4. propagatemarks (drain gray stack from resurrected udata)
//   5. cleartablekeys(wk, wkv) + any newly weak tables

/// Atomic phase. Matches Lua 5.1 atomic() (lgc.c:525-553).
/// This runs to completion in a single call -- no yielding.
fn atomicPhase(L: u32, g: u32) void {
    // (1) Propagate any remaining gray objects
    propagateall();

    // (2) Re-traverse weak tables (push to gray, propagate)
    // In 5.1 this uses g->weak. We use our weak_table_list.
    // Weak tables need re-traversal because they were kept gray.
    var wi: u32 = 0;
    while (wi < weak_table_count) : (wi += 1) {
        const tbl = weak_table_list[wi];
        grayStackPush(tbl);
    }
    propagateall();

    // (3) Mark running thread + metatables (5.1 lines 536-537)
    _ = markObject(saved_L);
    // Mark defaultmeta again
    if (readU8(g + 0x40) >= offsets.LUA_TTABLE) {
        const dm = readU32(g + offsets.GS_defaultmeta);
        if (dm != 0) _ = markObject(dm);
    }
    propagateall();

    // (4) Re-traverse grayagain: barrier-back tables + threads
    // 5.1 lines 539-542: g->gray = g->grayagain; propagateall
    var gi: u32 = 0;
    while (gi < grayagain_count) : (gi += 1) {
        const obj = grayagain_list[gi];
        // Push back to gray for re-traversal
        grayStackPush(obj);
    }
    grayagain_count = 0;
    propagateall();

    // (5) Separate dead userdata with __gc into tmudata
    native_separateudata(L);

    // (6) Re-mark tmudata so their refs survive sweep
    marktmuImpl(g);
    propagateall();

    // (7) Clear weak tables
    atomicClearWeakTables();

    // (8) Flip current white. New objects born after this point get the
    // NEW currentwhite. Sweep will free objects with the OLD white.
    currentwhite = otherwhite();
    syncBirthMarks(); // update string creation to use new white

    weak_table_count = 0;
    grayagain_count = 0;
}

/// Walk tmudata and re-mark each entry so references survive sweep.
fn marktmuImpl(g: u32) void {
    var obj = readU32(g + offsets.GS_tmudata);
    while (obj != 0) {
        // Make white then re-mark (5.1 marktmu: makewhite + reallymarkobject)
        makewhite(obj);
        _ = markObject(obj); // white2gray + push to gray
        obj = readU32(obj + offsets.OBJ_next);
    }
}

/// Clear dead entries from weak tables collected during mark.
fn atomicClearWeakTables() void {
    var i: u32 = 0;
    while (i < weak_table_count) : (i += 1) {
        const table = weak_table_list[i];
        const marked = readU8(table + offsets.OBJ_marked);
        if ((marked & offsets.VALUEWEAK) != 0) clearWeakValues(table);
        if ((marked & offsets.KEYWEAK) != 0) clearWeakKeys(table);
    }
}

/// Clear dead entries from weak-value tables. Matches native cleartablevalues.
/// For hash nodes, uses removekey semantics: nil value + set dead key to TNONE.
fn clearWeakValues(table: u32) void {
    // Array part: just nil dead values
    const array_ptr = readU32(table + offsets.TABLE_array);
    const sizearray = readU32(table + offsets.TABLE_sizearray);
    if (array_ptr != 0) {
        var i: u32 = 0;
        while (i < sizearray) : (i += 1) {
            const tv = array_ptr + i * offsets.TVALUE_size;
            const tt = readU8(tv + offsets.TVALUE_tt);
            if (tt >= offsets.LUA_TSTRING) {
                const gc = readU32(tv + offsets.TVALUE_gcptr);
                if (gc != 0 and isWhite(gc)) {
                    writeU8(tv + offsets.TVALUE_tt, offsets.LUA_TNIL);
                    writeU32(tv + offsets.TVALUE_gcptr, 0);
                }
            }
        }
    }

    // Hash part: removekey -- nil value AND mark collectable keys as TNONE
    const node_ptr = readU32(table + offsets.TABLE_node);
    if (node_ptr == 0) return;
    const lsizenode = readU8(table + offsets.TABLE_lsizenode);
    const sizenode: u32 = @as(u32, 1) << @as(u5, @intCast(lsizenode));

    var ni: u32 = 0;
    while (ni < sizenode) : (ni += 1) {
        const node = node_ptr + ni * offsets.NODE_size;
        const val_tt = readU8(node + offsets.NODE_value_tt);
        if (val_tt < offsets.LUA_TSTRING) continue;
        const val_gc = readU32(node + offsets.NODE_value_gcptr);
        if (val_gc == 0) continue;
        if (isWhite(val_gc)) {
            // removekey: nil value
            writeU8(node + offsets.NODE_value_tt, offsets.LUA_TNIL);
            writeU32(node + offsets.NODE_value_gcptr, 0);
            // removekey: mark collectable key as dead
            const key_tt = readU8(node + offsets.NODE_key_tt);
            if (key_tt >= offsets.LUA_TSTRING) {
                writeU8(node + offsets.NODE_key_tt, offsets.LUA_TNONE);
            }
        }
    }
}

/// Clear dead entries from weak-key tables. Matches native cleartablekeys.
/// Uses removekey semantics: nil value + set dead collectable key to TNONE.
fn clearWeakKeys(table: u32) void {
    const node_ptr = readU32(table + offsets.TABLE_node);
    if (node_ptr == 0) return;
    const lsizenode = readU8(table + offsets.TABLE_lsizenode);
    const sizenode: u32 = @as(u32, 1) << @as(u5, @intCast(lsizenode));

    var ni: u32 = 0;
    while (ni < sizenode) : (ni += 1) {
        const node = node_ptr + ni * offsets.NODE_size;
        const key_tt = readU8(node + offsets.NODE_key_tt);
        if (key_tt < offsets.LUA_TSTRING) continue;
        const key_gc = readU32(node + offsets.NODE_key_gcptr);
        if (key_gc == 0) continue;
        if (isWhite(key_gc)) {
            // removekey: nil value
            writeU8(node + offsets.NODE_value_tt, offsets.LUA_TNIL);
            writeU32(node + offsets.NODE_value_gcptr, 0);
            // removekey: mark collectable key as dead
            writeU8(node + offsets.NODE_key_tt, offsets.LUA_TNONE);
        }
    }
}

// =============================================================================
// From-Scratch Sweep: rootgc (incremental, cursor-based)
// =============================================================================
//
// Walks rootgc in place using a prev_next pointer. For each object:
//   - If marked: clear mark bit, advance cursor (object survives)
//   - If unmarked: unlink from list, call lua_gc_free_object, count freed
//
// No list splitting. sweep_prev_next points to the address of the "next"
// field that leads to the current object (initially &g->rootgc).

fn sweepRootgcStep(L: u32) bool {
    cur_sweep_steps += 1;
    var processed: u32 = 0;

    while (processed < CHUNK_SIZE) {
        const obj = readU32(sweep_prev_next);
        if (obj == 0) return true; // end of list, sweep done

        if (!isDead(obj)) {
            // Alive: set to current white for next cycle.
            // Preserves non-color flags (KEYWEAK, VALUEWEAK, FIXED).
            makewhite(obj);
            sweep_prev_next = obj + offsets.OBJ_next;
        } else {
            // Dead: unlink and free
            const next = readU32(obj + offsets.OBJ_next);
            writeU32(sweep_prev_next, next);
            native_free_object(L, obj);
            cur_dead_freed += 1;
        }
        processed += 1;
    }

    // Bump threshold so GC doesn't re-trigger immediately
    bumpThresholdHeadroom(saved_g);
    return false; // more to sweep
}

// =============================================================================
// From-Scratch Sweep: rootudata (atomic, typically small)
// =============================================================================

fn sweepRootudata(L: u32, g: u32) void {
    var prev_next: u32 = g + offsets.GS_rootudata;
    while (true) {
        const obj = readU32(prev_next);
        if (obj == 0) break;
        if (!isDead(obj)) {
            makewhite(obj);
            prev_next = obj + offsets.OBJ_next;
        } else {
            const next = readU32(obj + offsets.OBJ_next);
            writeU32(prev_next, next);
            native_free_object(L, obj);
            cur_dead_freed += 1;
        }
    }
}

// =============================================================================
// From-Scratch Sweep: string hash table (incremental, chunked by bucket)
// =============================================================================
//
// Walks g->strt.hash[bucket] chains. For each bucket:
//   walk chain, unlink unmarked strings, call lua_gc_free_object.
//   Decrement strt.nuse for each freed string.
// Chunks by processing N buckets per call.

fn sweepStringsStep(L: u32, g: u32) bool {
    cur_sweep_steps += 1;
    const hash_array = readU32(g + offsets.GS_strt_hash);
    const bucket_count = readU32(g + offsets.GS_strt_size);

    if (hash_array == 0 or bucket_count == 0) return true;

    var buckets_done: u32 = 0;
    while (sweep_string_bucket < bucket_count and buckets_done < CHUNK_SIZE) {
        var prev_next: u32 = hash_array + sweep_string_bucket * 4;
        while (true) {
            const obj = readU32(prev_next);
            if (obj == 0) break;
            if (!isDead(obj)) {
                makewhite(obj);
                prev_next = obj + offsets.OBJ_next;
            } else {
                const next = readU32(obj + offsets.OBJ_next);
                writeU32(prev_next, next);
                const nuse = readU32(g + offsets.GS_strt_nuse);
                if (nuse > 0) writeU32(g + offsets.GS_strt_nuse, nuse - 1);
                native_free_object(L, obj);
                cur_strings_freed += 1;
            }
        }
        sweep_string_bucket += 1;
        buckets_done += 1;
    }

    if (sweep_string_bucket >= bucket_count) return true;

    bumpThresholdHeadroom(g);
    return false;
}

// =============================================================================
// Threshold Management
// =============================================================================

/// After sweep: threshold = 2 * totalbytes (matches Lua 5.0 checkSizes).
/// The native formula is `2 * nblocks - deadmem` but deadmem (size of
/// finalized udata) is typically negligible, so 2x is close enough.
fn setFinalThreshold(g: u32) void {
    const totalbytes = readU32(g + offsets.GS_totalbytes);
    writeU32(g + offsets.GS_gcthreshold, totalbytes *| 2);
}

/// Between incremental steps: bump threshold just enough to not retrigger.
fn bumpThresholdHeadroom(g: u32) void {
    const totalbytes = readU32(g + offsets.GS_totalbytes);
    writeU32(g + offsets.GS_gcthreshold, totalbytes + offsets.BATCH_HEADROOM);
}

/// Shrink string table if load factor is low (nuse < size/4).
fn maybeShrinkStringTable(L: u32, g: u32) void {
    const nuse = readU32(g + offsets.GS_strt_nuse);
    const size = readU32(g + offsets.GS_strt_size);
    // Minimum string table size is 32 (MINSTRTABSIZE*2 in Lua 5.0)
    if (nuse < size / 4 and size > 32) {
        native_string_hash_resize(L, size / 2);
    }
}

// =============================================================================
// luaC_collectgarbage Detour -- Incremental State Machine
// =============================================================================

/// Diagnostic modes:
///   0 = our GC (normal)
///   1 = full native passthrough (allocator only)
///   2 = native mark + our sweep (isolates sweep bugs)
///   3 = our mark + native sweep (isolates mark bugs)
const DIAG_MODE: u32 = 0;

fn collectGarbageDetour(L: u32) callconv(hook.cc.fastcall) void {
    if (DIAG_MODE == 1) return collect_hook.callOriginal(.{L});

    if (in_gc) return;
    if (readU32(L + offsets.L_active_check) == 0) return;

    in_gc = true;
    defer in_gc = false;

    const g = getGlobalState(L);

    saved_L = L;
    saved_g = g;

    // Mode 2: native mark + our sweep -- isolates sweep bugs
    if (DIAG_MODE == 2) {
        _ = native_mark(L); // full native mark + atomic (weak clear, separateudata, marktmu)
        // Our sweep
        sweep_prev_next = g + offsets.GS_rootgc;
        var done = false;
        while (!done) done = sweepRootgcStep(L);
        sweepRootudata(L, g);
        sweep_string_bucket = 0;
        done = false;
        while (!done) done = sweepStringsStep(L, g);
        // (birth mark removed -- two-white handles this)
        const mt = readU32(g + offsets.GS_mainthread);
        makewhite(mt);
        maybeShrinkStringTable(L, g);
        setFinalThreshold(g);
        native_callGCTM(L);
        return;
    }

    // Mode 3: our mark + native sweep -- isolates mark bugs
    if (DIAG_MODE == 3) {
        // Our mark + atomic
        gray_count = 0;
        weak_table_count = 0;
        markroot(g);
        while (gray_count > 0) {
            const obj = grayStackPop();
            if (obj == 0) break;
            propagatemark(obj);
        }
        atomicPhase(L, g);
        // Native sweep + checkSizes + callGCTM
        const native_sweep: *const fn (u32, u32) callconv(hook.cc.fastcall) void = @ptrFromInt(offsets.lua_gc_sweep_all_lists);
        _ = native_sweep; // sweepstrings only
        // Use the individual native sweep functions
        const sweeplist_fn = *const fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
        const native_sweeplist: sweeplist_fn = @ptrFromInt(offsets.lua_gc_remove_objects);
        const native_sweepstrings: *const fn (u32, u32) callconv(hook.cc.fastcall) void = @ptrFromInt(offsets.lua_gc_sweep_all_lists);
        _ = native_sweeplist(L, g + offsets.GS_rootudata, 0);
        native_sweepstrings(L, 0);
        _ = native_sweeplist(L, g + offsets.GS_rootgc, 0);
        const mt = readU32(g + offsets.GS_mainthread);
        makewhite(mt);
        native_shrink_memory(L);
        native_callGCTM(L);
        return;
    }

    // Mode 4: our mark + our atomic + our sweep, but all-at-once (no state machine)
    // Tests whether the state machine itself is the bug.
    if (DIAG_MODE == 4) {
        gray_count = 0;
        weak_table_count = 0;
        markroot(g);
        while (gray_count > 0) {
            const obj = grayStackPop();
            if (obj == 0) break;
            propagatemark(obj);
        }
        atomicPhase(L, g);
        sweep_prev_next = g + offsets.GS_rootgc;
        var done = false;
        while (!done) done = sweepRootgcStep(L);
        sweepRootudata(L, g);
        sweep_string_bucket = 0;
        done = false;
        while (!done) done = sweepStringsStep(L, g);
        // (birth mark removed -- two-white handles this)
        const mt = readU32(g + offsets.GS_mainthread);
        makewhite(mt);
        if (saved_L != 0 and saved_L != mt) makewhite(saved_L);
        maybeShrinkStringTable(L, g);
        setFinalThreshold(g);
        native_callGCTM(L);
        return;
    }

    // Log entry state for first 20 cycles
    if (stats.cycles_total < 20 and phase == .idle) {
        const tb = readU32(g + offsets.GS_totalbytes);
        const thr = readU32(g + offsets.GS_gcthreshold);
        var buf: [128]u8 = undefined;
        log.print(fmt(&buf, "  trigger: totalbytes={d} threshold={d}\n", .{ tb, thr }));
    }

    switch (phase) {
        .idle => {
            // Start a new GC cycle
            gray_count = 0;
            weak_table_count = 0;
            grayagain_count = 0;
            cur_mark_steps = 0;
            cur_sweep_steps = 0;
            cur_dead_freed = 0;
            cur_strings_freed = 0;
            dbg_table_count = 0;
            dbg_closure_count = 0;
            dbg_thread_count = 0;
            dbg_proto_count = 0;
            dbg_udata_count = 0;
            dbg_other_count = 0;

            // Push roots and start marking.
            // Birth mark stays OFF during mark and rootgc sweep. New rootgc
            // objects prepend to the head (behind our forward cursor) and are
            // safe. Birth mark is only needed during string sweep where new
            // strings can land in unswept hash buckets ahead of the cursor.
            markroot(g);
            phase = .marking;

            // Do one mark step immediately
            if (markStep()) {
                phase = .atomic;
                runAtomicAndStartSweep(L, g);
            } else {
                bumpThresholdHeadroom(g);
            }
        },

        .marking => {
            if (markStep()) {
                phase = .atomic;
                runAtomicAndStartSweep(L, g);
            } else {
                bumpThresholdHeadroom(g);
            }
        },

        .atomic => {
            // Should not be called in this phase (atomic runs to completion)
            // but handle gracefully
            runAtomicAndStartSweep(L, g);
        },

        .sweep_strings => {
            if (sweepStringsStep(L, g)) {
                sweep_prev_next = g + offsets.GS_rootgc;
                phase = .sweeping;
                if (sweepRootgcStep(L)) {
                    phase = .finalize;
                    finalizeCycle(L, g);
                }
            }
        },

        .sweeping => {
            if (sweepRootgcStep(L)) {
                phase = .finalize;
                finalizeCycle(L, g);
            }
        },

        .finalize => {
            // Should not happen (finalize runs to completion), handle gracefully
            finalizeCycle(L, g);
        },
    }
}

/// Run atomic phase then transition to incremental sweep.
/// Sweep order matches native: rootudata (atomic) -> strings -> rootgc.
///
/// Birth mark is ON only during string sweep: new strings can hash into
/// unswept buckets ahead of the cursor and would be incorrectly freed.
/// Start sweep after atomic phase.
/// Two-white eliminates birth mark: new objects born with currentwhite
/// (already flipped in atomic), which is NOT otherwhite, so they survive.
fn runAtomicAndStartSweep(L: u32, g: u32) void {
    atomicPhase(L, g);

    // Sweep rootudata atomically (small list, fast)
    sweepRootudata(L, g);

    // Start chunked string sweep
    sweep_string_bucket = 0;
    phase = .sweep_strings;

    if (sweepStringsStep(L, g)) {
        sweep_prev_next = g + offsets.GS_rootgc;
        phase = .sweeping;
        if (sweepRootgcStep(L)) {
            phase = .finalize;
            finalizeCycle(L, g);
        }
    }
}

/// Final cleanup: shrink string table, set threshold, run finalizers.
fn finalizeCycle(L: u32, g: u32) void {
    // Mainthread is not in rootgc (WoW-specific). Make it white for next cycle.
    const mt = readU32(g + offsets.GS_mainthread);
    makewhite(mt);
    if (saved_L != 0 and saved_L != mt) {
        makewhite(saved_L);
    }

    maybeShrinkStringTable(L, g);
    setFinalThreshold(g);

    // Run __gc finalizers
    native_callGCTM(L);

    // Commit stats
    stats.cycles_total += 1;
    stats.mark_steps_last = cur_mark_steps;
    stats.sweep_steps_last = cur_sweep_steps;
    stats.dead_freed_last = cur_dead_freed;
    stats.strings_freed_last = cur_strings_freed;

    if (stats.cycles_total <= 20 or stats.cycles_total % 100 == 0) {
        const tb = readU32(g + offsets.GS_totalbytes);
        const thr = readU32(g + offsets.GS_gcthreshold);
        var buf: [300]u8 = undefined;
        log.print(fmt(&buf, "cycle {d}: mark={d} sweep={d} | freed={d}+{d}str | totalbytes={d} threshold={d} | tbl={d} cl={d} th={d} proto={d} ud={d} other={d}\n", .{
            stats.cycles_total,    stats.mark_steps_last,    stats.sweep_steps_last,
            stats.dead_freed_last, stats.strings_freed_last, tb,
            thr,                   dbg_table_count,          dbg_closure_count,
            dbg_thread_count,      dbg_proto_count,          dbg_udata_count,
            dbg_other_count,
        }));
    }

    phase = .idle;
}

// =============================================================================
// Write Barriers (tri-color invariant during incremental mark)
// =============================================================================

const TableSetFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;

var table_set_hook: hook.Detour(TableSetFn) = .{};
var table_set_int_hook: hook.Detour(TableSetFn) = .{};

fn tableSetBarrier(L: u32, table: u32, key: u32) callconv(hook.cc.fastcall) u32 {
    // Barrier back (5.1 luaC_barrierback): if table is BLACK during propagate,
    // make it gray again and add to grayagain list.
    if (phase == .marking and isBlack(table)) {
        black2gray(table);
        grayagainAdd(table);
    }
    return table_set_hook.callOriginal(.{ L, table, key });
}

fn tableSetIntBarrier(L: u32, table: u32, int_key: u32) callconv(hook.cc.fastcall) u32 {
    if (phase == .marking and isBlack(table)) {
        black2gray(table);
        grayagainAdd(table);
    }
    return table_set_int_hook.callOriginal(.{ L, table, int_key });
}

// =============================================================================
// lua_setgcthreshold hook
// =============================================================================
//
// WoW (and the Lua collectgarbage() function) calls lua_setgcthreshold to
// force GC by setting a low threshold. We intercept this: if the caller wants
// to force GC (low threshold), we run our GC cycle directly. Otherwise we
// let the threshold through but cap it to at least our 2x floor.

const SetGcThresholdFn = fn (u32, u32) callconv(hook.cc.fastcall) void;
var setgcthreshold_hook: hook.Detour(SetGcThresholdFn) = .{};

fn setgcthresholdDetour(L: u32, newthreshold: u32) callconv(hook.cc.fastcall) void {
    _ = newthreshold;
    if (readU32(L + offsets.L_active_check) == 0) return;

    // 5.1 luaC_fullgc pattern: if a forced GC arrives mid-cycle,
    // abandon the current cycle and start fresh. Without this,
    // we'd continue processing stale gray stack entries from a
    // partially-traversed state after /reload swaps in new objects.
    if (phase != .idle) {
        phase = .idle;
        gray_count = 0;
        grayagain_count = 0;
        weak_table_count = 0;
    }

    const g = getGlobalState(L);
    const tb = readU32(g + offsets.GS_totalbytes);
    const thr = readU32(g + offsets.GS_gcthreshold);
    if (thr > tb) return;
    collectGarbageDetour(L);
}

// =============================================================================
// lua_close hook
// =============================================================================
//
// lua_close (0x6F6EF0) calls luaC_sweep(L,1) directly, bypassing our
// collectgarbage detour. If we're mid-cycle, our gray stack and sweep
// cursors hold pointers to objects that luaC_sweep is about to free.
// Reset our state to idle before the native close proceeds.

const LuaCloseFn = fn (u32) callconv(hook.cc.fastcall) void;
var lua_close_hook: hook.Detour(LuaCloseFn) = .{};

fn luaCloseDetour(L: u32) callconv(hook.cc.fastcall) void {
    // Abandon any in-progress cycle
    phase = .idle;
    gray_count = 0;
    grayagain_count = 0;
    weak_table_count = 0;
    in_gc = false;
    currentwhite = 0x01;
    needs_bootstrap = true;
    syncBirthMarks();

    lua_close_hook.callOriginal(.{L});
}

// =============================================================================
// luaC_link hook (two-white birth system)
// =============================================================================
//
// New objects must be born with currentwhite so they're alive in the current
// cycle. The native luaC_link sets marked=0 which in our two-white system
// means "gray" (invisible to mark). We hook it to set marked=currentwhite.

const LuaCLinkFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
var luac_link_hook: hook.Detour(LuaCLinkFn) = .{};

fn luaCLinkDetour(L: u32, obj: u32, tt: u32) callconv(hook.cc.fastcall) void {
    const g = getGlobalState(L);
    writeU32(obj + offsets.OBJ_next, readU32(g + offsets.GS_rootgc));
    writeU32(g + offsets.GS_rootgc, obj);
    writeU8(obj + offsets.OBJ_marked, currentwhite);
    writeU8(obj + offsets.OBJ_tt, @intCast(tt));
}

// =============================================================================
// Forward barriers (luaC_barrierf equivalent)
// =============================================================================
//
// Lua 5.1 has luaC_barrierf at every write site that creates a cross-object
// reference (besides table writes which use barrierback). WoW's Lua 5.0 has
// no barriers at all. We hook each function that needs one.
//
// The barrier: if we're in marking phase, and the written value is a WHITE
// collectable GC object, mark it immediately so it survives sweep.
// This prevents BLACK→WHITE edges from going unnoticed.

/// Forward barrier: if a white collectable was written somewhere during
/// marking, mark it now. Reads a TValue at the given address.
fn barrierForward(tv_addr: u32) void {
    if (phase != .marking) return;
    const tt = readU8(tv_addr + offsets.TVALUE_tt);
    if (tt < offsets.LUA_TSTRING) return; // not collectable
    const gc = readU32(tv_addr + offsets.TVALUE_gcptr);
    if (gc == 0) return;
    if (isWhite(gc)) _ = markObject(gc);
}

// --- lua_setmetatable (0x6F4020) ---
// __fastcall(ECX=L, EDX=objindex). Sets metatable on stack object.
// 5.1 barriers: luaC_objbarriert for tables, luaC_objbarrier for userdata.
const SetMetaFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var setmeta_hook: hook.Detour(SetMetaFn) = .{};
fn setmetaDetour(L: u32, objindex: u32) callconv(hook.cc.fastcall) u32 {
    const result = setmeta_hook.callOriginal(.{ L, objindex });
    // After the native sets the metatable, barrier the new metatable.
    // The metatable was just pushed on the stack (L->top - 1) before the call,
    // then popped by the native. We can't easily get the metatable pointer
    // after the call. Instead, just re-mark the object's metatable field.
    // The object is at the given stack index. Read it, get its metatable.
    if (phase == .marking) {
        // Resolve stack index to object pointer
        const obj_tv = resolveStackIndex(L, objindex);
        if (obj_tv != 0) {
            const obj_tt = readU8(obj_tv + offsets.TVALUE_tt);
            if (obj_tt == offsets.LUA_TTABLE or obj_tt == offsets.LUA_TUSERDATA) {
                const obj_gc = readU32(obj_tv + offsets.TVALUE_gcptr);
                if (obj_gc != 0) {
                    const mt = readU32(obj_gc + offsets.TABLE_metatable);
                    if (mt != 0 and isWhite(mt)) _ = markObject(mt);
                }
            }
        }
    }
    return result;
}

// --- lua_setupvalue (0x6F47B0) ---
// __fastcall(ECX=L, EDX=funcindex, stack=n). Sets upvalue by index.
const SetUpvalFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var setupval_hook: hook.Detour(SetUpvalFn) = .{};
fn setupvalDetour(L: u32, funcindex: u32, n: u32) callconv(hook.cc.fastcall) u32 {
    const result = setupval_hook.callOriginal(.{ L, funcindex, n });
    // After the native sets the upvalue, the value was popped from stack.
    // The upvalue now holds the new value. We can't easily get which upvalue
    // was written without re-deriving it. But the native already did the write.
    // For safety: if we're marking, re-traverse the closure.
    if (phase == .marking and result != 0) {
        const obj_tv = resolveStackIndex(L, funcindex);
        if (obj_tv != 0 and readU8(obj_tv + offsets.TVALUE_tt) == offsets.LUA_TFUNCTION) {
            const cl = readU32(obj_tv + offsets.TVALUE_gcptr);
            if (cl != 0 and isBlack(cl)) {
                black2gray(cl);
                grayagainAdd(cl);
            }
        }
    }
    return result;
}

// --- lua_pushcclosure (0x6F3920) ---
// __fastcall(ECX=L, EDX=fn_ptr, stack=n_upvals). Creates C closure with upvalues.
const PushCClosureFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
var pushcclosure_hook: hook.Detour(PushCClosureFn) = .{};
fn pushcclosureDetour(L: u32, fn_ptr: u32, n: u32) callconv(hook.cc.fastcall) void {
    pushcclosure_hook.callOriginal(.{ L, fn_ptr, n });
    // The new closure is at L->top - 1. It was just created (WHITE).
    // Its upvalues were set from the stack. The closure is WHITE, so
    // no BLACK→WHITE edge (barrier only matters if container is BLACK).
    // New closure is currentwhite → no barrier needed.
}

// --- lua_setfenv (0x6F40D0) ---
// __fastcall(ECX=L, EDX=idx). Sets environment table on stack object.
const SetFenvFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var setfenv_hook: hook.Detour(SetFenvFn) = .{};
fn setfenvDetour(L: u32, idx: u32) callconv(hook.cc.fastcall) u32 {
    const result = setfenv_hook.callOriginal(.{ L, idx });
    if (phase == .marking and result != 0) {
        const obj_tv = resolveStackIndex(L, idx);
        if (obj_tv != 0) {
            const obj_gc = readU32(obj_tv + offsets.TVALUE_gcptr);
            if (obj_gc != 0 and isBlack(obj_gc)) {
                black2gray(obj_gc);
                grayagainAdd(obj_gc);
            }
        }
    }
    return result;
}

/// Resolve a Lua stack index to the TValue address.
/// Positive = from base, negative = from top, pseudo-indices = special.
fn resolveStackIndex(L: u32, idx: u32) u32 {
    const idx_i: i32 = @bitCast(idx);
    if (idx_i > 0) {
        // Positive: base + (idx-1) * 16
        const base = readU32(L + 0x0C); // L->base (ci->base typically at L+0x0C)
        if (base == 0) return 0;
        return base + @as(u32, @intCast(idx_i - 1)) * offsets.TVALUE_size;
    } else if (idx_i < -10000) {
        // Pseudo-index (globals, registry, upvalues) -- skip
        return 0;
    } else {
        // Negative: top + idx * 16
        const top = readU32(L + offsets.THREAD_top);
        if (top == 0) return 0;
        return @as(u32, @intCast(@as(i32, @intCast(top)) + idx_i * @as(i32, offsets.TVALUE_size)));
    }
}

// =============================================================================
// String resurrection (5.1 lstring.c:88)
// =============================================================================
//
// During incremental sweep, the string intern table can return a dead string
// (one with otherwhite, not yet swept). Lua 5.1 handles this in luaS_newlstr:
//   if (isdead(G(L), o)) changewhite(o);  /* resurrect */
// WoW's Lua 5.0 has no such check. We hook lua_create_string_object and
// resurrect dead strings after the native returns them.

const StringCreateFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var string_create_hook: hook.Detour(StringCreateFn) = .{};

fn stringCreateDetour(L: u32, str_ptr: u32, len: u32) callconv(hook.cc.fastcall) u32 {
    const result = string_create_hook.callOriginal(.{ L, str_ptr, len });
    // If the returned string is dead (has otherwhite), resurrect it
    if (result != 0) {
        const marked = readU8(result + offsets.OBJ_marked);
        if ((marked & otherwhite() & offsets.WHITEBITS) != 0) {
            // changewhite: flip white bits (dead white → alive white)
            writeU8(result + offsets.OBJ_marked, marked ^ offsets.WHITEBITS);
        }
    }
    return result;
}

// =============================================================================
// Upvalue resurrection (5.1 lfunc.c:61-62)
// =============================================================================
//
// Same pattern as strings: luaF_findupval can return a dead open upvalue
// during incremental sweep. Resurrect it.

const UpvalCreateFn = fn (u32, u32) callconv(hook.cc.fastcall) u32;
var upval_create_hook: hook.Detour(UpvalCreateFn) = .{};

fn upvalCreateDetour(L: u32, level: u32) callconv(hook.cc.fastcall) u32 {
    const result = upval_create_hook.callOriginal(.{ L, level });
    if (result != 0) {
        const marked = readU8(result + offsets.OBJ_marked);
        if ((marked & otherwhite() & offsets.WHITEBITS) != 0) {
            writeU8(result + offsets.OBJ_marked, marked ^ offsets.WHITEBITS);
        }
    }
    return result;
}

// =============================================================================
// Compiler barriers (5.1 lcode.c:244, lparser.c:151,199,319)
// =============================================================================
//
// The Lua compiler adds constants, nested protos, locvars, and upvalue names
// to proto objects during compilation. If GC runs mid-compilation (multi-step
// mark), a proto can be BLACK when the compiler adds new WHITE children.
// 5.1 has luaC_barrier/luaC_objbarrier after each such write.
// We hook the compiler functions and apply barrier-back on the proto.

const CreateConstantFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
var create_constant_hook: hook.Detour(CreateConstantFn) = .{};

fn createConstantDetour(lexstate: u32, value: u32, typ: u32) callconv(hook.cc.fastcall) void {
    create_constant_hook.callOriginal(.{ lexstate, value, typ });
    // All callers pass LexState in ECX (verified from Ghidra: parse_string_field,
    // parseFunctionCall, parse_primary_expression all pass the same struct).
    // LexState+0x30 = FuncState, FuncState+0x00 = Proto.
    if (phase == .marking and lexstate != 0) {
        const fs = readU32(lexstate + 0x30);
        if (fs != 0) {
            const proto = readU32(fs);
            if (proto != 0 and isBlack(proto)) {
                black2gray(proto);
                grayagainAdd(proto);
            }
        }
    }
}

const FinishFunctionFn = fn (u32) callconv(hook.cc.fastcall) void;
var finish_function_hook: hook.Detour(FinishFunctionFn) = .{};

fn finishFunctionDetour(lexstate: u32) callconv(hook.cc.fastcall) void {
    // Barrier BEFORE native: proto arrays are about to be resized.
    // LexState+0x30 = FuncState, FuncState+0x00 = Proto (verified Ghidra).
    if (phase == .marking and lexstate != 0) {
        const fs = readU32(lexstate + 0x30);
        if (fs != 0) {
            const proto = readU32(fs);
            if (proto != 0 and isBlack(proto)) {
                black2gray(proto);
                grayagainAdd(proto);
            }
        }
    }
    finish_function_hook.callOriginal(.{lexstate});
}

// =============================================================================
// OP_SETUPVAL VM patch (forward barrier)
// =============================================================================
//
// At 0x6F8A97, right after the 16-byte TValue copy in OP_SETUPVAL handler,
// EDX holds uv->v (the destination pointer -- the TValue just written).
// We patch 5 bytes at 0x6F8A97 with CALL to our barrier trampoline.
// The trampoline checks if the written value is WHITE and marks it.
//
// Original bytes at 0x6F8A97: 8B 7F 04 85 FF (MOV EDI,[EDI+4]; TEST EDI,EDI)
// These are debug hook code, not critical to SETUPVAL functionality.
// We overwrite with: E8 XX XX XX XX (CALL rel32 to our function)
// Our function does the barrier check then executes the overwritten instructions.

var setupval_patch_installed: bool = false;
var setupval_original_bytes: [5]u8 = undefined;

fn installSetupvalPatch() void {
    // Read original bytes
    const src: [*]const u8 = @ptrFromInt(0x6F8A97);
    @memcpy(&setupval_original_bytes, src[0..5]);

    // Write CALL rel32 to our barrier
    const target = @intFromPtr(&setupvalBarrierTrampoline);
    const rel: i32 = @intCast(@as(i64, target) - (0x6F8A97 + 5));
    var patch: [5]u8 = undefined;
    patch[0] = 0xE8; // CALL rel32
    patch[1..5].* = @bitCast(rel);
    hook.writeProtected(0x6F8A97, &patch);
    setupval_patch_installed = true;
}

fn removeSetupvalPatch() void {
    if (setupval_patch_installed) {
        hook.writeProtected(0x6F8A97, &setupval_original_bytes);
        setupval_patch_installed = false;
    }
}

/// Called from the VM after OP_SETUPVAL's TValue copy.
/// EDX = uv->v (the TValue that was just written to).
/// Must preserve all registers and flags, execute the overwritten instructions,
/// then return.
fn setupvalBarrierTrampoline() callconv(.naked) void {
    // Called from VM after OP_SETUPVAL TValue copy. EDX = uv->v.
    // Check if written value is a white collectable during mark, mark it if so.
    // Must preserve all registers and execute overwritten instructions before ret.
    asm volatile (
        \\ pushf
        \\ push %%eax
        \\ push %%ecx
        // Check phase == .marking (1)
        \\ movl %[phase_ptr], %%eax
        \\ cmpb $1, (%%eax)
        \\ jne 1f
        // EDX = uv->v. Check tt >= LUA_TSTRING (4)
        \\ movzbl (%%edx), %%eax
        \\ cmpl $4, %%eax
        \\ jb 1f
        // Read gcptr at [EDX+8]
        \\ movl 8(%%edx), %%eax
        \\ testl %%eax, %%eax
        \\ jz 1f
        // Check if white (marked & 0x03)
        \\ testb $0x03, 5(%%eax)
        \\ jz 1f
        // White collectable during mark -> call markObject via indirect
        \\ push %%edx
        \\ push %%eax
        \\ movl %[mark_fn], %%ecx
        \\ call *%%ecx
        \\ addl $4, %%esp
        \\ pop %%edx
        \\1:
        \\ pop %%ecx
        \\ pop %%eax
        \\ popf
        // Execute overwritten: MOV EDI,[EDI+4]; TEST EDI,EDI
        \\ movl 4(%%edi), %%edi
        \\ testl %%edi, %%edi
        \\ ret
        :
        : [phase_ptr] "i" (&phase),
          [mark_fn] "i" (&markObjectCdecl),
    );
}

fn markObjectCdecl(obj: u32) callconv(.c) void {
    _ = markObject(obj);
}

// =============================================================================
// ZGCStats Lua C function
// =============================================================================

pub fn luaZGCStats(L: lua.State) callconv(hook.cc.fastcall) i32 {
    lua.pushnumber(L, @floatFromInt(stats.cycles_total));
    lua.pushnumber(L, @floatFromInt(stats.mark_steps_last));
    lua.pushnumber(L, @floatFromInt(stats.sweep_steps_last));
    lua.pushnumber(L, @floatFromInt(stats.gray_peak));
    lua.pushnumber(L, @floatFromInt(stats.dead_freed_last));
    lua.pushnumber(L, @floatFromInt(stats.strings_freed_last));
    lua.pushnumber(L, @floatFromInt(@intFromEnum(phase)));
    return 7;
}

// =============================================================================
// Installation
// =============================================================================

const CollectFn = fn (u32) callconv(hook.cc.fastcall) void;
var collect_hook: hook.Detour(CollectFn) = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    var installed: u32 = 0;

    // Install slab allocator
    installed += luaalloc.install();

    if (collect_hook.attach(offsets.luaC_collectgarbage, &collectGarbageDetour) == .ok) {
        installed += 1;
        log.print("hooked luaC_collectgarbage\n");
    }
    if (table_set_hook.attach(offsets.lua_table_set_value, &tableSetBarrier) == .ok) {
        installed += 1;
        log.print("hooked lua_table_set_value\n");
    }
    if (table_set_int_hook.attach(offsets.lua_table_set_int_key, &tableSetIntBarrier) == .ok) {
        installed += 1;
        log.print("hooked lua_table_set_int_key\n");
    }
    if (setgcthreshold_hook.attach(offsets.lua_setgcthreshold, &setgcthresholdDetour) == .ok) {
        installed += 1;
        log.print("hooked lua_setgcthreshold\n");
    }
    if (lua_close_hook.attach(offsets.lua_close, &luaCloseDetour) == .ok) {
        installed += 1;
        log.print("hooked lua_close\n");
    }
    if (luac_link_hook.attach(offsets.luaC_link, &luaCLinkDetour) == .ok) {
        installed += 1;
        log.print("hooked luaC_link\n");
    }
    // Resurrection hooks (5.1 lstring.c:88, lfunc.c:61-62)
    if (string_create_hook.attach(offsets.luaS_newlstr, &stringCreateDetour) == .ok) {
        installed += 1;
    }
    if (upval_create_hook.attach(offsets.lua_create_open_upvalue, &upvalCreateDetour) == .ok) {
        installed += 1;
    }

    // Forward barriers (5.1 luaC_barrierf equivalents)
    if (setmeta_hook.attach(offsets.lua_setmetatable, &setmetaDetour) == .ok) {
        installed += 1;
    }
    if (setupval_hook.attach(offsets.lua_setupvalue, &setupvalDetour) == .ok) {
        installed += 1;
    }
    if (setfenv_hook.attach(offsets.lua_setfenv, &setfenvDetour) == .ok) {
        installed += 1;
    }
    // Note: lua_pushcclosure doesn't need a barrier (new closures are WHITE)
    // Compiler barriers (5.1 lcode.c, lparser.c)
    if (create_constant_hook.attach(offsets.lua_parser_create_constant, &createConstantDetour) == .ok) {
        installed += 1;
    }
    if (finish_function_hook.attach(offsets.lua_parser_finish_function, &finishFunctionDetour) == .ok) {
        installed += 1;
    }
    installSetupvalPatch();
    log.print("installed forward barriers\n");

    syncBirthMarks();

    var buf: [64]u8 = undefined;
    log.print(fmt(&buf, "installed {d} hooks\n", .{installed}));
}

pub fn removeHooks() void {
    if (!g_is_hook_owner) return;

    // If mid-cycle, restore birth mark
    // Reset birth marks to native defaults
    var patch0 = [1]u8{0x00};
    hook.writeProtected(offsets.birth_mark_string, &patch0);
    var patch1 = [1]u8{0x01};
    hook.writeProtected(offsets.birth_mark_upvalue, &patch1);

    collect_hook.detach();
    table_set_hook.detach();
    table_set_int_hook.detach();
    setgcthreshold_hook.detach();
    lua_close_hook.detach();
    luac_link_hook.detach();
    string_create_hook.detach();
    upval_create_hook.detach();
    setmeta_hook.detach();
    setupval_hook.detach();
    setfenv_hook.detach();
    create_constant_hook.detach();
    finish_function_hook.detach();
    removeSetupvalPatch();
    luaalloc.remove();

    phase = .idle;
    in_gc = false;
    gray_count = 0;

    log.close();
    mod_mutex.release(&g_mutex);
}
