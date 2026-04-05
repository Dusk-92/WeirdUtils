//! Incremental garbage collector for Lua 5.0.
//!
//! WoW's Lua 5.0 uses stop-the-world mark-and-sweep GC. When it triggers,
//! the entire game freezes while every Lua object is visited. With 500K+
//! objects from addons, this causes visible stutters.
//!
//! This module hooks luaC_collectgarbage (0x6F7340) and replaces it with
//! an incremental state machine:
//!
//!   IDLE -> MARK -> SWEEP -> FINALIZE -> IDLE
//!
//! Mark phase runs atomically (it's fast -- only visits reachable objects).
//! Sweep phase runs incrementally -- each time allocation pressure triggers
//! the GC, we sweep a batch of objects and return. Lua's own allocation
//! pattern drives the sweep rate: heavy allocation = faster sweep.
//!
//! No write barriers needed because mark is atomic. The mutator doesn't
//! run between mark start and mark end, so no objects can be missed.

const hook = @import("zhook");

// ============================================================================
// Lua internals
//
// lua_State layout:
//   +0x10: global_State* (l_G)
//   +0x60: allowhook (checked by luaC_collectgarbage before proceeding)
//
// global_State layout (verified from disassembly):
//   +0x00: strt.hash (GCObject**)
//   +0x04: strt.nuse (int)
//   +0x08: strt.size (int)
//   +0x10: rootgc (GCObject*) -- main object list
//   +0x14: rootudata (GCObject*) -- userdata list (swept first for finalizers)
//   +0x18: tmudata (GCObject*) -- userdata pending __gc
//   +0x24: GCthreshold (lu_mem)
//   +0x28: totalbytes (lu_mem)
//
// GCObject common header:
//   +0x00: next (GCObject*) -- intrusive linked list
//   +0x04: tt (byte) -- type tag
//   +0x05: marked (byte) -- GC mark bits
// ============================================================================

const GS_ROOTGC = 0x10;
const GS_ROOTUDATA = 0x14;
const GS_GCTHRESHOLD = 0x24;
const GS_TOTALBYTES = 0x28;

const OBJ_NEXT = 0x00;
const OBJ_MARKED = 0x05;

const MARK_BIT: u8 = 0x01;

// Batch size: number of objects to sweep per GC invocation.
// Tuned for ~0.1ms per batch at typical object sizes.
const SWEEP_BATCH = 0xFFFFFFFF; // DEBUG: sweep everything in one batch

// Headroom: bytes of allocation allowed between sweep batches.
// Prevents GC from being re-triggered immediately after a batch.
const BATCH_HEADROOM = 64 * 1024; // 64KB

// ============================================================================
// Original function pointers (called directly, not hooked)
// ============================================================================

// lua_gc_full_collection (0x6F73E0): __fastcall(ECX=L) -- mark phase
const MarkFn = *const fn (u32) callconv(hook.cc.fastcall) void;
const lua_gc_full_collection: MarkFn = @ptrFromInt(0x6F73E0);

// lua_gc_free_object (0x6F7260): __fastcall(ECX=L, EDX=obj)
const FreeObjFn = *const fn (u32, u32) callconv(hook.cc.fastcall) void;
const lua_gc_free_object: FreeObjFn = @ptrFromInt(0x6F7260);

// lua_gc_sweep_all_lists (0x6F72F0): __fastcall(ECX=L, EDX=threshold)
const SweepStringsFn = *const fn (u32, u32) callconv(hook.cc.fastcall) void;
const lua_gc_sweep_all_lists: SweepStringsFn = @ptrFromInt(0x6F72F0);

// lua_gc_shrink_memory (0x6F7370): __fastcall(ECX=L)
const ShrinkFn = *const fn (u32) callconv(hook.cc.fastcall) void;
const lua_gc_shrink_memory: ShrinkFn = @ptrFromInt(0x6F7370);

// luaCallUserDataGC (0x6F7080): __fastcall(ECX=L)
const FinalizeFn = *const fn (u32) callconv(hook.cc.fastcall) void;
const luaCallUserDataGC: FinalizeFn = @ptrFromInt(0x6F7080);

// ============================================================================
// GC state machine
// ============================================================================

const GcPhase = enum { idle, sweeping_udata, sweeping_strings, sweeping_rootgc, finalizing };

var phase: GcPhase = .idle;
var sweep_ptr: u32 = 0; // pointer TO current position in linked list (so we can unlink)
var sweep_threshold: u32 = 0; // mark threshold for current cycle
var saved_L: u32 = 0; // lua_State* for calling back into Lua

fn getGlobalState(L: u32) u32 {
    return @as(*const u32, @ptrFromInt(L + 0x10)).*;
}

fn readU32(addr: u32) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}

fn writeU32(addr: u32, val: u32) void {
    @as(*u32, @ptrFromInt(addr)).* = val;
}

fn readU8(addr: u32) u8 {
    return @as(*const u8, @ptrFromInt(addr)).*;
}

fn writeU8(addr: u32, val: u8) void {
    @as(*u8, @ptrFromInt(addr)).* = val;
}

/// Sweep a batch of objects from the linked list at *sweep_ptr.
/// Returns number of objects freed.
fn sweepBatch(L: u32, count: u32) u32 {
    var freed: u32 = 0;
    var remaining = count;

    while (remaining > 0) {
        const obj = readU32(sweep_ptr);
        if (obj == 0) break; // end of list

        const marked = readU8(obj + OBJ_MARKED);
        if (marked > sweep_threshold) {
            // Object is marked (alive) -- clear mark bit, advance
            writeU8(obj + OBJ_MARKED, marked & ~MARK_BIT);
            sweep_ptr = obj + OBJ_NEXT;
        } else {
            // Object is unmarked (dead) -- unlink and free
            writeU32(sweep_ptr, readU32(obj + OBJ_NEXT));
            lua_gc_free_object(L, obj);
            freed += 1;
        }
        remaining -= 1;
    }

    return freed;
}

/// Main hook replacing luaC_collectgarbage (0x6F7340).
/// __fastcall(ECX=lua_State*), plain RET.
var in_gc: bool = false;

fn collectGarbageDetour(L: u32) callconv(hook.cc.fastcall) void {
    if (in_gc) return; // re-entrancy guard
    // Original checks L->allowhook (offset 0x60) before proceeding
    if (@as(*const u32, @ptrFromInt(L + 0x60)).* == 0) return;
    in_gc = true;
    defer in_gc = false;

    const g = getGlobalState(L);
    saved_L = L;

    switch (phase) {
        .idle => {
            // Start new GC cycle: run full mark phase atomically
            // lua_gc_full_collection expects state set up via prior calls.
            // The original luaC_collectgarbage calls it after checking allowhook
            // with ECX = L still in register. We replicate this.
            lua_gc_full_collection(L);

            // Mark phase done. Start sweeping userdata first (same order as original).
            phase = .sweeping_udata;
            sweep_ptr = g + GS_ROOTUDATA;
            sweep_threshold = 0; // first sweep pass uses threshold 0x100
            // Actually the original passes param_2=0x100 for userdata sweep.
            // The threshold comparison is: if marked > threshold, keep alive.
            // With threshold 0x100, only objects with marked > 256 survive,
            // which means nothing survives (marked is a byte, max 255).
            // Wait -- that means the first udata sweep frees EVERYTHING?
            // No: the original passes EDI=0 (from XOR EDX,EDX -> param_2=0),
            // then luaGarbageCollect sets EDI=0x100 if param_2!=0.
            // luaC_collectgarbage calls luaGarbageCollect(L, 0), so EDI=0.
            // threshold=0 means: if marked > 0, keep (marked objects survive).
            sweep_threshold = 0;

            // Raise GCthreshold to prevent immediate re-trigger
            const totalbytes = readU32(g + GS_TOTALBYTES);
            writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);

            // Do first batch of udata sweep
            _ = sweepBatch(L, SWEEP_BATCH);

            // Check if udata sweep is done
            if (readU32(sweep_ptr) == 0) {
                phase = .sweeping_strings;
            }
        },

        .sweeping_udata => {
            _ = sweepBatch(L, SWEEP_BATCH);

            if (readU32(sweep_ptr) == 0) {
                phase = .sweeping_strings;
            }

            // Keep threshold ahead of allocations
            const totalbytes = readU32(g + GS_TOTALBYTES);
            writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
        },

        .sweeping_strings => {
            // String table sweep is not a linked list walk -- it's a hash
            // table scan. Run it atomically (it's bounded by string count,
            // typically fast).
            lua_gc_sweep_all_lists(L, 0);

            // Now start main rootgc sweep
            phase = .sweeping_rootgc;
            sweep_ptr = g + GS_ROOTGC;

            _ = sweepBatch(L, SWEEP_BATCH);

            if (readU32(sweep_ptr) == 0) {
                phase = .finalizing;
            }

            const totalbytes = readU32(g + GS_TOTALBYTES);
            writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
        },

        .sweeping_rootgc => {
            _ = sweepBatch(L, SWEEP_BATCH);

            if (readU32(sweep_ptr) == 0) {
                phase = .finalizing;
            }

            const totalbytes = readU32(g + GS_TOTALBYTES);
            writeU32(g + GS_GCTHRESHOLD, totalbytes + BATCH_HEADROOM);
        },

        .finalizing => {
            // Shrink string table + buffers, set final threshold
            lua_gc_shrink_memory(L);
            // Run __gc finalizers
            luaCallUserDataGC(L);
            phase = .idle;
        },
    }
}

// ============================================================================
// luaC_link hook (0x6F7B20) -- birth-mark barrier
//
// luaC_link adds every new GC object to rootgc and sets marked=0 (white).
// During incremental sweep, white objects get freed. New objects born during
// sweep must be born BLACK (marked=1) so the sweep skips them.
//
// Original: __fastcall(ECX=L, EDX=obj, stack: type_tag), RET 0x4
//   MOV EAX, [ECX+0x10]       ; global_State
//   MOV EAX, [EAX+0x10]       ; old rootgc head
//   MOV [EDX], EAX             ; obj->next = old head
//   MOV ECX, [ECX+0x10]        ; global_State
//   MOV [ECX+0x10], EDX        ; rootgc = obj
//   MOV byte [EDX+0x5], 0x0    ; obj->marked = 0 (WHITE)
//   MOV byte [EDX+0x4], AL     ; obj->tt = type_tag
// ============================================================================

const LinkFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) void;
var link_hook: hook.Detour(LinkFn) = .{};

fn linkDetour(L: u32, obj: u32, type_tag: u32) callconv(hook.cc.fastcall) void {
    // Replicate original luaC_link logic
    const g = getGlobalState(L);
    const old_head = readU32(g + GS_ROOTGC);
    writeU32(obj + OBJ_NEXT, old_head); // obj->next = old head
    writeU32(g + GS_ROOTGC, obj); // rootgc = obj
    writeU8(obj + 0x04, @truncate(type_tag)); // obj->tt = type_tag

    // Birth-mark: during sweep, born BLACK so sweep skips this object
    if (phase != .idle) {
        writeU8(obj + OBJ_MARKED, MARK_BIT); // born marked
    } else {
        writeU8(obj + OBJ_MARKED, 0); // born white (normal)
    }
}

// ============================================================================
// Hook management
// ============================================================================

const CollectFn = fn (u32) callconv(hook.cc.fastcall) void;
var collect_hook: hook.Detour(CollectFn) = .{};

pub fn install() u32 {
    var installed: u32 = 0;
    if (collect_hook.attach(0x6F7340, &collectGarbageDetour) == .ok) installed += 1;
    // if (link_hook.attach(0x6F7B20, &linkDetour) == .ok) installed += 1; // DEBUG: disabled to isolate crash
    return installed;
}

pub fn remove() void {
    collect_hook.detach();
    link_hook.detach();
    phase = .idle;
}
