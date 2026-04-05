//! Lua allocator replacement.
//!
//! Hooks memory_pool_allocate (0x6FAE90) to replace WoW's 6-class slab
//! allocator with a faster Zig slab. Improvements over WoW's allocator:
//!
//!   - O(1) free/realloc: 4-byte header stores slot size (WoW scans all
//!     pools and pages to find the owning pool -- O(classes * pages))
//!   - 15 size classes vs 6: less internal fragmentation
//!   - @memcpy for cross-class realloc (WoW does a manual dword loop)
//!   - Slabs up to 4096 bytes (WoW falls to system heap at >256)
//!
//! LuaMemoryRealloc (the accounting wrapper at 0x6FC980) is left intact
//! so totalbytes tracking works unmodified.
//!
//! Also hooks lua_gc_step (0x6FAE00) which normally reads pool metadata to
//! calculate GC thresholds. Since pools are empty (all allocs go through us),
//! we replace it with standard Lua 5.0 threshold logic: threshold = totalbytes * 1.25.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");

pub const module_name: [*:0]const u8 = "luaalloc";

var log: logging.Logger = .{};

// ============================================================================
// Slab allocator
//
// Layout: [header: 4 bytes (u32 slot_size)][user data][padding to slot boundary]
// Free slots store a next pointer in the first 4 bytes of user area.
//
// Size classes chosen to cover Lua's common allocation sizes with <25%
// internal fragmentation at each step. Usable bytes = slot_size - HEADER.
// ============================================================================

const HEADER = 4; // bytes before user pointer, stores slot_size as u32

// Slot sizes (including header). Each class is roughly 1.5x the previous.
// Usable sizes: 12, 20, 28, 44, 60, 92, 124, 188, 252, 380, 508, 764, 1020, 2044, 4092
const class_sizes = [_]u32{ 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096 };
const NUM_CLASSES = class_sizes.len;

// Page size for backing allocations. Each page is carved into slots of one class.
const PAGE_SIZE = 65536;

var free_lists: [NUM_CLASSES]u32 = .{0} ** NUM_CLASSES; // head of free list (ptr as u32, 0 = empty)

/// Find the smallest size class that fits `total` bytes (including header).
fn sizeClassIndex(total: u32) ?usize {
    inline for (class_sizes, 0..) |sz, i| {
        if (total <= sz) return i;
    }
    return null; // too large for slab
}

/// Allocate a new page of slots for the given class, link them into the free list.
fn refillClass(class_idx: usize) bool {
    const slot_size = class_sizes[class_idx];
    const page = std.heap.page_allocator.rawAlloc(PAGE_SIZE, .@"1", @returnAddress()) orelse return false;
    const base = @intFromPtr(page);
    const slots_per_page = PAGE_SIZE / slot_size;

    // Carve page into slots and chain them via free list.
    // Build chain from last to first so the first slot is the head.
    var i: u32 = slots_per_page;
    while (i > 0) {
        i -= 1;
        const slot_addr = base + i * slot_size;
        // Write next-free pointer into user area (offset HEADER from slot start)
        const next_ptr: *u32 = @ptrFromInt(slot_addr + HEADER);
        next_ptr.* = free_lists[class_idx];
        free_lists[class_idx] = slot_addr;
    }
    return true;
}

fn slabAlloc(size: u32) ?[*]u8 {
    const total = size + HEADER;
    const class_idx = sizeClassIndex(total) orelse return largeMalloc(size);
    const slot_size = class_sizes[class_idx];

    // Pop from free list, refilling if empty
    if (free_lists[class_idx] == 0) {
        if (!refillClass(class_idx)) return null;
    }
    const slot_addr = free_lists[class_idx];
    const next_ptr: *const u32 = @ptrFromInt(slot_addr + HEADER);
    free_lists[class_idx] = next_ptr.*;

    // Write slot size into header
    const header: *u32 = @ptrFromInt(slot_addr);
    header.* = slot_size;

    // Return pointer past header
    return @ptrFromInt(slot_addr + HEADER);
}

fn slabFree(user_ptr: u32) void {
    const slot_addr = user_ptr - HEADER;
    const header: *const u32 = @ptrFromInt(slot_addr);
    const slot_size = header.*;

    // Validate it's a slab allocation (slot_size must match a known class)
    const class_idx = sizeClassIndex(slot_size) orelse {
        // Large allocation
        largeFree(user_ptr, slot_size - HEADER);
        return;
    };
    if (class_sizes[class_idx] != slot_size) {
        // Corrupted header or not our allocation -- fall through to large free
        largeFree(user_ptr, slot_size - HEADER);
        return;
    }

    // Push onto free list
    const next_ptr: *u32 = @ptrFromInt(user_ptr);
    next_ptr.* = free_lists[class_idx];
    free_lists[class_idx] = slot_addr;
}

fn slabRealloc(user_ptr: u32, new_size: u32) ?[*]u8 {
    const slot_addr = user_ptr - HEADER;
    const header: *const u32 = @ptrFromInt(slot_addr);
    const old_slot_size = header.*;
    const old_usable = old_slot_size - HEADER;

    // If new size fits in current slot, return same pointer
    if (new_size <= old_usable) return @ptrFromInt(user_ptr);

    // Allocate new, copy, free old
    const new_ptr = slabAlloc(new_size) orelse return null;
    const copy_len = @min(old_usable, new_size);
    const dst: [*]u8 = new_ptr;
    const src: [*]const u8 = @ptrFromInt(user_ptr);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    slabFree(user_ptr);
    return new_ptr;
}

// Large allocations (>4092 usable bytes): fall through to WoW's system heap.
// We still prepend our 4-byte header so free/realloc can identify them.

// M2_AllocateModelBuffer (0x6462E0): __stdcall(size, src, line, flags) -> ptr. RET 0x10.
const AllocMemory: *const fn (u32, [*:0]const u8, u32, u32) callconv(hook.cc.stdcall) ?[*]u8 =
    @ptrFromInt(0x6462E0);
// FreeMemory (0x646430): __stdcall(ptr, src, line, flags). RET 0x10.
const FreeMemory: *const fn (?*anyopaque, [*:0]const u8, u32, u32) callconv(hook.cc.stdcall) void =
    @ptrFromInt(0x646430);

const large_src: [*:0]const u8 = "luaalloc";

fn largeMalloc(size: u32) ?[*]u8 {
    const total = size + HEADER;
    const mem = AllocMemory(total, large_src, 0, 0) orelse return null;
    const base = @intFromPtr(mem);
    const header: *u32 = @ptrFromInt(base);
    header.* = total; // store total as "slot size" so realloc/free works
    return @ptrFromInt(base + HEADER);
}

fn largeFree(user_ptr: u32, _: u32) void {
    FreeMemory(@ptrFromInt(user_ptr - HEADER), large_src, 0, 0);
}

// ============================================================================
// memory_pool_allocate hook
//
// Original at 0x6FAE90:
//   __fastcall(ECX=pool_context, EDX=old_ptr, stack: new_size)
//   RET 0x4 (cleans 1 stack param)
//   Verified from prologue: ECX saved to [EBP-0xC], EDX->ESI, [EBP+8]=new_size.
//   All 11 RET instructions are RET 0x4.
//
// Called from LuaMemoryRealloc (0x6FC980) which handles totalbytes accounting.
// Also called from non-Lua paths (ECX=NULL) for general pool allocation.
// ============================================================================

const PoolAllocFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) ?[*]u8;

var pool_alloc_hook: hook.Detour(PoolAllocFn) = .{};

fn poolAllocDetour(pool_ctx: u32, old_ptr_raw: u32, new_size: u32) callconv(hook.cc.fastcall) ?[*]u8 {
    _ = pool_ctx;

    if (new_size == 0) {
        if (old_ptr_raw != 0) slabFree(old_ptr_raw);
        return null;
    }

    if (old_ptr_raw != 0) {
        return slabRealloc(old_ptr_raw, new_size);
    }

    return slabAlloc(new_size);
}

// ============================================================================
// lua_gc_step hook
//
// Original at 0x6FAE00:
//   __fastcall(ECX=lua_State*), plain RET (no stack cleanup).
//   Called from lua_gc_shrink_memory (0x6F73D6) only.
//   Iterates 6 pool size classes to calculate GC threshold from pool usage.
//   Crashes when pool descriptor array (global_State[0]) is NULL.
//
// Replacement: set threshold = totalbytes + totalbytes/4 (standard Lua 1.25x).
//   global_State layout: [0]=pool_ptrs, ..., [9]=GCthreshold, [10]=totalbytes
//   L->l_G at L+0x10.
// ============================================================================

const GcStepFn = fn (u32) callconv(hook.cc.fastcall) void;

var gc_step_hook: hook.Detour(GcStepFn) = .{};

fn gcStepDetour(lua_state: u32) callconv(hook.cc.fastcall) void {
    if (lua_state == 0) return;
    const global_state: [*]u32 = @ptrFromInt(@as(*const u32, @ptrFromInt(lua_state + 0x10)).*);
    const totalbytes = global_state[10]; // offset 0x28
    global_state[9] = totalbytes + (totalbytes >> 2); // offset 0x24 = GCthreshold
}

// ============================================================================
// Module interface
// ============================================================================

var g_is_hook_owner: bool = false;

pub fn installHooks() void {
    log = logging.Logger.open(module_name, .console);
    _ = pool_alloc_hook.attach(0x6FAE90, &poolAllocDetour);
    _ = gc_step_hook.attach(0x6FAE00, &gcStepDetour);
    g_is_hook_owner = true;
    log.print("hooked memory_pool_allocate + lua_gc_step\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        gc_step_hook.detach();
        pool_alloc_hook.detach();
        log.close();
    }
    g_is_hook_owner = false;
}

pub fn isActive() bool {
    return g_is_hook_owner;
}
