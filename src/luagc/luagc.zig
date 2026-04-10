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
// Birth Mark
// =============================================================================

var birth_mark_active: bool = false;

fn setBirthMark(active: bool) void {
    const val: u8 = if (active) 0x01 else 0x00;
    var patch1 = [1]u8{val};
    hook.writeProtected(offsets.birth_mark_luaC_link, &patch1);
    var patch2 = [1]u8{val};
    hook.writeProtected(offsets.birth_mark_string, &patch2);
    birth_mark_active = active;
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
    return @as(*const u32, @ptrFromInt(addr)).*;
}

inline fn writeU32(addr: u32, val: u32) void {
    @as(*u32, @ptrFromInt(addr)).* = val;
}

inline fn readU8(addr: u32) u8 {
    return @as(*const u8, @ptrFromInt(addr)).*;
}

inline fn writeU8(addr: u32, val: u8) void {
    @as(*u8, @ptrFromInt(addr)).* = val;
}

fn getGlobalState(L: u32) u32 {
    return readU32(L + offsets.L_global);
}

inline fn objType(obj: u32) u8 {
    return readU8(obj + offsets.OBJ_tt);
}

/// Check if object has been marked by our traversal OR is fixed (bit 4).
/// Matches Lua 5.0's ismarked: `marked & ((1<<4)|1)`.
/// Used during mark to avoid re-pushing already-processed objects.
inline fn isMarked(obj: u32) bool {
    return (readU8(obj + offsets.OBJ_marked) & 0x11) != 0;
}

/// Check if object should survive sweep. Matches WoW binary's sweeplist at
/// 0x6F7222: `CMP marked, limit; JLE free` with limit=0.
/// The binary does NOT mask with ~(KEYWEAK|VALUEWEAK) despite the Lua 5.0
/// source saying so. ANY non-zero marked byte keeps the object alive.
inline fn isAlive(obj: u32) bool {
    return readU8(obj + offsets.OBJ_marked) != 0;
}

inline fn setMarked(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, readU8(obj + offsets.OBJ_marked) | 0x01);
}

/// Clear mark bit 0 only. Preserves fixed (bit 4) and all other flags.
inline fn clearMarked(obj: u32) void {
    writeU8(obj + offsets.OBJ_marked, readU8(obj + offsets.OBJ_marked) & offsets.CLEAR_MARK);
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

fn traverseAndPushChildren(obj: u32) void {
    const tt = objType(obj);
    switch (tt) {
        offsets.LUA_TTABLE => {
            dbg_table_count += 1;
            traverseTable(obj);
        },
        offsets.LUA_TFUNCTION => {
            dbg_closure_count += 1;
            traverseClosure(obj);
        },
        offsets.LUA_TTHREAD => {
            dbg_thread_count += 1;
            traverseThread(obj);
        },
        offsets.LUA_TPROTO => {
            dbg_proto_count += 1;
            traverseProto(obj);
        },
        offsets.LUA_TUSERDATA => {
            // Userdata: mark metatable (at udata+0x08).
            // Lua 5.0 reallymarkobject does: markvalue(st, gcotou(o)->uv.metatable)
            dbg_udata_count += 1;
            const mt = readU32(obj + offsets.UDATA_metatable);
            if (mt != 0 and !isMarked(mt)) {
                setMarked(mt);
                grayStackPush(mt);
            }
        },
        else => {
            // Strings: no children. Just count.
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
    marked &= ~@as(u8, 0x06); // clear KEYWEAK|VALUEWEAK

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
        if (weakkey) marked |= 0x02; // KEYWEAK
        if (weakvalue) marked |= 0x04; // VALUEWEAK
    }

    writeU8(table + offsets.OBJ_marked, marked);
}

/// Traverse a table's children (metatable, array slots, hash nodes).
/// Weak tables are deferred to atomicClearWeakTables.
fn traverseTable(table: u32) void {
    const mt = readU32(table + offsets.TABLE_metatable);
    if (mt != 0 and !isMarked(mt)) {
        setMarked(mt);
        grayStackPush(mt);
    }

    // Detect weak mode from metatable, matching native traversetable behavior.
    // The native GC checks gfasttm(g, metatable, TM_MODE) and sets weak bits
    // in marked. We replicate this so new tables get weak flags set.
    if (mt != 0) {
        detectAndSetWeakFlags(table, mt);
    }

    const marked = readU8(table + offsets.OBJ_marked);
    const weakkey = (marked & 0x02) != 0;   // KEYWEAK
    const weakvalue = (marked & 0x04) != 0; // VALUEWEAK
    const is_weak = weakkey or weakvalue;

    // Array section: skip only if value-weak (matches native: `if (!weakvalue)`)
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
                    if (gc != 0 and !isMarked(gc)) {
                        setMarked(gc);
                        grayStackPush(gc);
                    }
                }
            }
        }
    }

    // Hash section: mark the STRONG dimension, skip the weak dimension.
    // Native: condmarkobject(key, !weakkey); condmarkobject(value, !weakvalue)
    const node_ptr = readU32(table + offsets.TABLE_node);
    if (node_ptr == 0) {
        if (is_weak) weakTableListAdd(table);
        return;
    }
    const lsizenode = readU8(table + offsets.TABLE_lsizenode);
    const sizenode: u32 = @as(u32, 1) << @as(u5, @intCast(lsizenode));

    var ni: u32 = 0;
    while (ni < sizenode) : (ni += 1) {
        const node = node_ptr + ni * offsets.NODE_size;
        const val_tt = readU8(node + offsets.NODE_value_tt);
        if (val_tt == 0) continue; // dead node (nil value)

        // Mark key if collectable AND not key-weak
        if (!weakkey) {
            const key_tt = readU8(node + offsets.NODE_key_tt);
            if (key_tt >= offsets.LUA_TSTRING) {
                const key_gc = readU32(node + offsets.NODE_key_gcptr);
                if (key_gc != 0 and !isMarked(key_gc)) {
                    setMarked(key_gc);
                    grayStackPush(key_gc);
                }
            }
        }

        // Mark value if collectable AND not value-weak
        if (!weakvalue) {
            if (val_tt >= offsets.LUA_TSTRING) {
                const val_gc = readU32(node + offsets.NODE_value_gcptr);
                if (val_gc != 0 and !isMarked(val_gc)) {
                    setMarked(val_gc);
                    grayStackPush(val_gc);
                }
            }
        }
    }

    if (is_weak) weakTableListAdd(table);
}

/// Traverse closure children (C upvalues or Lua env+proto+upvals).
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
                if (gc != 0 and !isMarked(gc)) {
                    setMarked(gc);
                    grayStackPush(gc);
                }
            }
        }
    } else {
        // Lua closure: mark two header pointers (env table + proto)
        const m1 = readU32(cl + offsets.CLOSURE_lua_mark1);
        if (m1 != 0 and !isMarked(m1)) {
            setMarked(m1);
            grayStackPush(m1);
        }
        const m2 = readU32(cl + offsets.CLOSURE_lua_mark2);
        if (m2 != 0 and !isMarked(m2)) {
            setMarked(m2);
            grayStackPush(m2);
        }

        // UpVal pointer array at cl+0x20, stride 4.
        // Always process every upvalue -- do NOT skip based on marked byte.
        // Open upvalues (pointing into the stack) are not in rootgc, so our
        // sweep never clears their marked byte. Skipping "already processed"
        // upvalues would cause their values to go unmarked in cycle 2+.
        // The isMarked check on the held value prevents redundant gray pushes
        // when multiple closures share the same upvalue.
        var i: u32 = 0;
        while (i < nups) : (i += 1) {
            const upv = readU32(cl + offsets.CLOSURE_lua_upval_ptrs + i * 4);
            if (upv == 0) continue;

            const val_tt = readU8(upv + offsets.UPVAL_value_tt);
            if (val_tt >= offsets.LUA_TSTRING) {
                const val_gc = readU32(upv + offsets.UPVAL_value_gcptr);
                if (val_gc != 0 and !isMarked(val_gc)) {
                    setMarked(val_gc);
                    grayStackPush(val_gc);
                }
            }

            writeU8(upv + offsets.UPVAL_marked, 0x01);
        }
    }
}

/// Traverse a thread: globals table + stack slots up to max(top, all ci->top).
fn traverseThread(th: u32) void {
    // Globals table TValue at thread+0x40..+0x48
    const gt_tt = readU8(th + offsets.THREAD_gt_tt);
    if (gt_tt >= offsets.LUA_TSTRING) {
        const gt_gc = readU32(th + offsets.THREAD_gt_gcptr);
        if (gt_gc != 0 and !isMarked(gt_gc)) {
            setMarked(gt_gc);
            grayStackPush(gt_gc);
        }
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
    // Matches native: `for (o = L1->stack; o < L1->top; o++) markobject(st, o);`
    var sp: u32 = stack_base;
    while (sp < top) : (sp += offsets.TVALUE_size) {
        const tt = readU8(sp + offsets.TVALUE_tt);
        if (tt >= offsets.LUA_TSTRING) {
            const gc = readU32(sp + offsets.TVALUE_gcptr);
            if (gc != 0 and !isMarked(gc)) {
                setMarked(gc);
                grayStackPush(gc);
            }
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
    // source (TString*) -- stringmark
    const source = readU32(proto + offsets.PROTO_source);
    if (source != 0) {
        writeU8(source + offsets.OBJ_marked, readU8(source + offsets.OBJ_marked) | 0x01);
    }

    // Constants: only string constants
    const k_ptr = readU32(proto + offsets.PROTO_k);
    const sizek = readU32(proto + offsets.PROTO_sizek);
    if (k_ptr != 0) {
        var i: u32 = 0;
        while (i < sizek) : (i += 1) {
            const tv = k_ptr + i * offsets.TVALUE_size;
            if (readU8(tv + offsets.TVALUE_tt) == offsets.LUA_TSTRING) {
                const s = readU32(tv + offsets.TVALUE_gcptr);
                if (s != 0) {
                    writeU8(s + offsets.OBJ_marked, readU8(s + offsets.OBJ_marked) | 0x01);
                }
            }
        }
    }

    // Upvalue names (TString**)
    const upv_ptr = readU32(proto + offsets.PROTO_upvalues);
    const sizeup = readU32(proto + offsets.PROTO_sizeupvalues);
    if (upv_ptr != 0) {
        var i: u32 = 0;
        while (i < sizeup) : (i += 1) {
            const s = readU32(upv_ptr + i * 4);
            if (s != 0) {
                writeU8(s + offsets.OBJ_marked, readU8(s + offsets.OBJ_marked) | 0x01);
            }
        }
    }

    // Nested protos
    const p_ptr = readU32(proto + offsets.PROTO_p);
    const sizep = readU32(proto + offsets.PROTO_sizep);
    if (p_ptr != 0) {
        var i: u32 = 0;
        while (i < sizep) : (i += 1) {
            const sub = readU32(p_ptr + i * 4);
            if (sub != 0 and !isMarked(sub)) {
                setMarked(sub);
                grayStackPush(sub);
            }
        }
    }

    // LocVar names (12 bytes each, TString* at first field)
    const lv_ptr = readU32(proto + offsets.PROTO_locvars);
    const sizelv = readU32(proto + offsets.PROTO_sizelocvars);
    if (lv_ptr != 0) {
        var i: u32 = 0;
        while (i < sizelv) : (i += 1) {
            const s = readU32(lv_ptr + i * offsets.LOCVAR_size);
            if (s != 0) {
                writeU8(s + offsets.OBJ_marked, readU8(s + offsets.OBJ_marked) | 0x01);
            }
        }
    }
}

// =============================================================================
// Root Mark
// =============================================================================

fn pushAllRoots(g: u32) void {
    const before = gray_count;

    // defaultmeta (TValue at g+0x40/+0x48)
    if (readU8(g + 0x40) >= offsets.LUA_TTABLE) {
        const dm = readU32(g + offsets.GS_defaultmeta);
        if (dm != 0 and !isMarked(dm)) {
            setMarked(dm);
            grayStackPush(dm);
        }
    }

    // registry (TValue at g+0x30/+0x38)
    if (readU8(g + 0x30) >= offsets.LUA_TTABLE) {
        const reg = readU32(g + offsets.GS_registry);
        if (reg != 0 and !isMarked(reg)) {
            setMarked(reg);
            grayStackPush(reg);
        }
    }

    // mainthread
    const mt = readU32(g + offsets.GS_mainthread);
    const mt_marked_before = readU8(mt + offsets.OBJ_marked);
    const mt_tt = readU8(mt + offsets.OBJ_tt);
    if (!isMarked(mt)) {
        setMarked(mt);
        grayStackPush(mt);
    }

    // current L if different
    if (saved_L != 0 and saved_L != mt) {
        if (!isMarked(saved_L)) {
            setMarked(saved_L);
            grayStackPush(saved_L);
        }
    }

    // Diagnostic: log root push details for first 15 cycles
    if (stats.cycles_total < 15) {
        var buf: [200]u8 = undefined;
        log.print(fmt(&buf, "  pushRoots cycle {d}: mt=0x{x} tt={d} marked=0x{x} pushed={d} gray={d}\n", .{
            stats.cycles_total + 1, mt,         mt_tt, mt_marked_before,
            gray_count - before,    gray_count,
        }));
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
        traverseAndPushChildren(obj);
        processed += 1;
    }

    return gray_count == 0;
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

fn atomicPhase(L: u32, g: u32) void {
    // (0) Re-traverse threads and grayagain tables.
    // Lua 5.1 atomic: re-mark running thread, re-traverse grayagain.
    // This catches new stack values and table mutations from between mark steps.
    const mt = readU32(g + offsets.GS_mainthread);
    if (isMarked(mt)) {
        grayStackPush(mt);
    }
    if (saved_L != 0 and saved_L != mt) {
        if (isMarked(saved_L)) {
            grayStackPush(saved_L);
        }
    }

    var gi: u32 = 0;
    while (gi < grayagain_count) : (gi += 1) {
        const tbl = grayagain_list[gi];
        if (isMarked(tbl)) {
            // Re-traverse: clear mark, re-mark, push to gray
            clearMarked(tbl);
            setMarked(tbl);
            grayStackPush(tbl);
        }
    }
    grayagain_count = 0;

    // Drain gray stack fully (all grayagain + thread re-traversals)
    while (gray_count > 0) {
        const obj = grayStackPop();
        if (obj == 0) break;
        traverseAndPushChildren(obj);
    }

    // (1) Clear weak table VALUES
    atomicClearWeakTables();

    // (2) Separate dead userdata with __gc into tmudata
    native_separateudata(L);

    // (3) Re-mark tmudata so their refs survive sweep
    marktmuImpl(g);

    // (4) Drain gray stack (bounded by tmudata size, typically small)
    while (gray_count > 0) {
        const obj = grayStackPop();
        if (obj == 0) break;
        traverseAndPushChildren(obj);
    }

    weak_table_count = 0;
    // Clear any grayagain entries added during atomic traversals (threads
    // re-add themselves). These don't need processing -- atomic caught everything.
    grayagain_count = 0;
}

/// Walk tmudata and re-mark each entry so references survive sweep.
fn marktmuImpl(g: u32) void {
    var obj = readU32(g + offsets.GS_tmudata);
    while (obj != 0) {
        clearMarked(obj);
        setMarked(obj);
        grayStackPush(obj);
        obj = readU32(obj + offsets.OBJ_next);
    }
}

/// Clear dead entries from weak tables collected during mark.
fn atomicClearWeakTables() void {
    var i: u32 = 0;
    while (i < weak_table_count) : (i += 1) {
        const table = weak_table_list[i];
        const marked = readU8(table + offsets.OBJ_marked);
        if ((marked & 0x04) != 0) clearWeakValues(table); // VALUEWEAK
        if ((marked & 0x02) != 0) clearWeakKeys(table); // KEYWEAK
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
                if (gc != 0 and !isMarked(gc)) {
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
        if (!isMarked(val_gc)) {
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
        if (!isMarked(key_gc)) {
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

        if (isAlive(obj)) {
            // Alive: clear mark bit for next cycle, advance.
            // Preserves fixed (bit 4) and other flags.
            clearMarked(obj);
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
        if (isAlive(obj)) {
            clearMarked(obj);
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
            if (isAlive(obj)) {
                clearMarked(obj);
                prev_next = obj + offsets.OBJ_next;
            } else {
                const next = readU32(obj + offsets.OBJ_next);
                writeU32(prev_next, next);
                // Decrement strt.nuse
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
        setBirthMark(false);
        const mt = readU32(g + offsets.GS_mainthread);
        clearMarked(mt);
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
        pushAllRoots(g);
        while (gray_count > 0) {
            const obj = grayStackPop();
            if (obj == 0) break;
            traverseAndPushChildren(obj);
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
        clearMarked(mt);
        native_shrink_memory(L);
        native_callGCTM(L);
        return;
    }

    // Mode 4: our mark + our atomic + our sweep, but all-at-once (no state machine)
    // Tests whether the state machine itself is the bug.
    if (DIAG_MODE == 4) {
        gray_count = 0;
        weak_table_count = 0;
        pushAllRoots(g);
        while (gray_count > 0) {
            const obj = grayStackPop();
            if (obj == 0) break;
            traverseAndPushChildren(obj);
        }
        atomicPhase(L, g);
        sweep_prev_next = g + offsets.GS_rootgc;
        var done = false;
        while (!done) done = sweepRootgcStep(L);
        sweepRootudata(L, g);
        sweep_string_bucket = 0;
        done = false;
        while (!done) done = sweepStringsStep(L, g);
        setBirthMark(false);
        const mt = readU32(g + offsets.GS_mainthread);
        clearMarked(mt);
        if (saved_L != 0 and saved_L != mt) clearMarked(saved_L);
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
            pushAllRoots(g);
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
                // Strings done, turn off birth mark before rootgc sweep
                setBirthMark(false);
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
/// For rootgc, new objects prepend to the head (behind the forward cursor)
/// so birth mark is unnecessary and harmful (causes next cycle to skip
/// traversal of born-marked objects).
fn runAtomicAndStartSweep(L: u32, g: u32) void {
    atomicPhase(L, g);

    // Sweep rootudata atomically (small list, fast)
    sweepRootudata(L, g);

    // String sweep needs birth mark: new strings can land in unswept buckets
    setBirthMark(true);
    sweep_string_bucket = 0;
    phase = .sweep_strings;

    // Do one string step immediately
    if (sweepStringsStep(L, g)) {
        // Strings done, birth mark no longer needed
        setBirthMark(false);
        // Start rootgc sweep (no birth mark needed)
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
    setBirthMark(false);

    // The mainthread is always a root but may not be in rootgc (WoW manages
    // it separately). Clear its mark so pushAllRoots can push it next cycle.
    // Also clear the current L if different.
    const mt = readU32(g + offsets.GS_mainthread);
    clearMarked(mt);
    if (saved_L != 0 and saved_L != mt) {
        clearMarked(saved_L);
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
    // Barrier back: BLACK table got a write during incremental mark.
    // Add to grayagain for re-traversal in the atomic phase.
    if (phase == .marking and isMarked(table)) {
        grayagainAdd(table);
    }
    return table_set_hook.callOriginal(.{ L, table, key });
}

fn tableSetIntBarrier(L: u32, table: u32, int_key: u32) callconv(hook.cc.fastcall) u32 {
    if (phase == .marking and isMarked(table)) {
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
    // The caller wants to set gcthreshold = newthreshold << 10.
    // If it's a low value (forcing GC), just run our GC cycle.
    // The original also calls luaC_checkGC after setting, which would
    // trigger our collectGarbageDetour anyway. Skip the threshold write
    // entirely -- our GC owns the threshold.
    _ = newthreshold;
    if (readU32(L + offsets.L_active_check) == 0) return;
    const g = getGlobalState(L);
    const tb = readU32(g + offsets.GS_totalbytes);
    const thr = readU32(g + offsets.GS_gcthreshold);
    // If threshold is already above totalbytes, no need to force GC
    if (thr > tb) return;
    // Otherwise trigger a GC by calling our detour path
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
    setBirthMark(false);
    in_gc = false;

    // Let the native lua_close proceed
    lua_close_hook.callOriginal(.{L});
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

    var buf: [64]u8 = undefined;
    log.print(fmt(&buf, "installed {d} hooks\n", .{installed}));
}

pub fn removeHooks() void {
    if (!g_is_hook_owner) return;

    // If mid-cycle, restore birth mark
    if (birth_mark_active) {
        setBirthMark(false);
    }

    collect_hook.detach();
    table_set_hook.detach();
    table_set_int_hook.detach();
    setgcthreshold_hook.detach();
    lua_close_hook.detach();
    luaalloc.remove();

    phase = .idle;
    in_gc = false;
    gray_count = 0;

    log.close();
    mod_mutex.release(&g_mutex);
}
