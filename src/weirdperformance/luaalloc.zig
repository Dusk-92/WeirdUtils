//! Lua allocator replacement.
//!
//! Hooks memory_pool_allocate (0x6FAE90) to replace WoW's 6-class slab
//! allocator with a faster Zig slab. Improvements over WoW's allocator:
//!
//!   - O(1) free/realloc via segment table lookup (WoW scans all pools
//!     and pages to find the owning pool -- O(classes * pages))
//!   - Zero per-allocation overhead (no header -- class stored per-page)
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


// ============================================================================
// Slab allocator -- segment-based lookup
//
// Each 64KB page is dedicated to one size class. A 64KB segment table
// maps (ptr >> 16) -> class index, giving O(1) lookup with zero
// per-allocation overhead. Free slots store a next pointer in the
// slot body (minimum slot size is 4 bytes, smallest class is 16).
//
// Pages are allocated via VirtualAlloc which guarantees 64KB alignment
// on Windows (allocation granularity). Large allocations (>4096 bytes)
// also use VirtualAlloc with a size header.
// ============================================================================

// VirtualAlloc for 64KB-aligned slab pages.
const MEM_COMMIT = 0x1000;
const MEM_RESERVE = 0x2000;
const MEM_RELEASE = 0x8000;
const PAGE_READWRITE = 0x04;
extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: u32, flAllocationType: u32, flProtect: u32) callconv(hook.cc.stdcall) ?[*]u8;
extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: u32, dwFreeType: u32) callconv(hook.cc.stdcall) i32;

const SEGMENT_SHIFT = 16; // 64KB pages
const PAGE_SIZE = 1 << SEGMENT_SHIFT; // 65536

// Class index values: 1-15 = slab classes, LARGE_CLASS = large alloc, 0 = unowned
const LARGE_CLASS = 0xFF;

// Segment table: one byte per 64KB of 32-bit address space = 64KB table.
// Stays hot in L1/L2 since every alloc/free/realloc touches it.
var segment_table: [65536]u8 = .{0} ** 65536;

// Slot sizes. Each class is roughly 1.5x the previous.
const class_sizes = [_]u32{ 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096 };
const NUM_CLASSES = class_sizes.len;

var free_lists: [NUM_CLASSES]u32 = .{0} ** NUM_CLASSES;

/// Find the smallest size class index that fits `size` bytes.
fn sizeClassIndex(size: u32) ?usize {
    inline for (class_sizes, 0..) |sz, i| {
        if (size <= sz) return i;
    }
    return null;
}

/// Look up class index from pointer via segment table.
fn classFromPtr(ptr: u32) u8 {
    return segment_table[ptr >> SEGMENT_SHIFT];
}

/// Allocate a new 64KB page for the given class, register in segment table,
/// and link all slots into the free list.
fn refillClass(class_idx: usize) bool {
    const slot_size = class_sizes[class_idx];
    // VirtualAlloc with NULL base always returns 64KB-aligned addresses.
    const page = VirtualAlloc(null, PAGE_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return false;
    const base = @intFromPtr(page);

    // Register this page in the segment table (class indices are 0-based,
    // store as idx+1 so 0 remains "unowned")
    segment_table[base >> SEGMENT_SHIFT] = @intCast(class_idx + 1);

    // Carve page into slots, chain from last to first
    const slots_per_page = PAGE_SIZE / slot_size;
    var i: u32 = slots_per_page;
    while (i > 0) {
        i -= 1;
        const slot_addr = base + i * slot_size;
        const next_ptr: *u32 = @ptrFromInt(slot_addr);
        next_ptr.* = free_lists[class_idx];
        free_lists[class_idx] = slot_addr;
    }
    return true;
}

fn slabAlloc(size: u32) ?[*]u8 {
    const class_idx = sizeClassIndex(size) orelse return largeMalloc(size);

    if (free_lists[class_idx] == 0) {
        if (!refillClass(class_idx)) return null;
    }
    const slot_addr = free_lists[class_idx];
    const next_ptr: *const u32 = @ptrFromInt(slot_addr);
    free_lists[class_idx] = next_ptr.*;

    return @ptrFromInt(slot_addr);
}

fn slabFree(ptr: u32, pool_ctx: u32) void {
    const seg_val = classFromPtr(ptr);
    if (seg_val == 0) {
        // Not ours (e.g. allocated before hook install). Let original handle it.
        _ = pool_alloc_hook.callOriginal(.{ pool_ctx, ptr, @as(u32, 0) });
        return;
    }
    if (seg_val == LARGE_CLASS) {
        largeFree(ptr);
        return;
    }
    const class_idx: usize = seg_val - 1;

    const next_ptr: *u32 = @ptrFromInt(ptr);
    next_ptr.* = free_lists[class_idx];
    free_lists[class_idx] = ptr;
}

fn slabRealloc(ptr: u32, new_size: u32, pool_ctx: u32) ?[*]u8 {
    const seg_val = classFromPtr(ptr);
    if (seg_val == 0) {
        // Not ours. Allocate from our slab, copy, free old via original.
        const new_ptr = slabAlloc(new_size) orelse return null;
        const dst: [*]u8 = new_ptr;
        const src: [*]const u8 = @ptrFromInt(ptr);
        @memcpy(dst[0..new_size], src[0..new_size]);
        _ = pool_alloc_hook.callOriginal(.{ pool_ctx, ptr, @as(u32, 0) });
        return new_ptr;
    }
    if (seg_val == LARGE_CLASS) return largeRealloc(ptr, new_size);

    const class_idx: usize = seg_val - 1;
    const old_slot_size = class_sizes[class_idx];

    // If new size fits in current slot, return same pointer
    if (new_size <= old_slot_size) return @ptrFromInt(ptr);

    // Allocate new, copy, free old
    const new_ptr = slabAlloc(new_size) orelse return null;
    const copy_len = @min(old_slot_size, new_size);
    const dst: [*]u8 = new_ptr;
    const src: [*]const u8 = @ptrFromInt(ptr);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    slabFree(ptr, pool_ctx);
    return new_ptr;
}

// ============================================================================
// Large allocations (>4096 bytes): VirtualAlloc with 8-byte header.
// Header stores size (u32) + magic (u32) for identification.
// ============================================================================

const LARGE_HEADER = 8;
const LARGE_MAGIC: u32 = 0x4C554121; // "LUA!"

fn largeMalloc(size: u32) ?[*]u8 {
    const total = size + LARGE_HEADER;
    // Round up to page boundary for VirtualAlloc
    const alloc_size = (total + 0xFFF) & ~@as(u32, 0xFFF);
    const mem = VirtualAlloc(null, alloc_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return null;
    const base = @intFromPtr(mem);

    // Mark segment(s) as large
    var seg = base >> SEGMENT_SHIFT;
    const end_seg = (base + alloc_size - 1) >> SEGMENT_SHIFT;
    while (seg <= end_seg) : (seg += 1) {
        segment_table[seg] = LARGE_CLASS;
    }

    const hdr_size: *u32 = @ptrFromInt(base);
    const hdr_magic: *u32 = @ptrFromInt(base + 4);
    hdr_size.* = size;
    hdr_magic.* = LARGE_MAGIC;
    return @ptrFromInt(base + LARGE_HEADER);
}

fn largeFree(ptr: u32) void {
    const base = ptr - LARGE_HEADER;
    const hdr_magic: *const u32 = @ptrFromInt(base + 4);
    if (hdr_magic.* != LARGE_MAGIC) return;
    const hdr_size: *const u32 = @ptrFromInt(base);
    const total = hdr_size.* + LARGE_HEADER;
    const alloc_size = (total + 0xFFF) & ~@as(u32, 0xFFF);

    // Clear segment entries
    var seg = base >> SEGMENT_SHIFT;
    const end_seg = (base + alloc_size - 1) >> SEGMENT_SHIFT;
    while (seg <= end_seg) : (seg += 1) {
        segment_table[seg] = 0;
    }

    _ = VirtualFree(@ptrFromInt(base), 0, MEM_RELEASE);
}

fn largeRealloc(ptr: u32, new_size: u32) ?[*]u8 {
    const base = ptr - LARGE_HEADER;
    const hdr_magic: *const u32 = @ptrFromInt(base + 4);
    if (hdr_magic.* != LARGE_MAGIC) return null;
    const hdr_size: *const u32 = @ptrFromInt(base);
    const old_size = hdr_size.*;

    if (new_size <= old_size) return @ptrFromInt(ptr);

    const new_ptr = slabAlloc(new_size) orelse return null;
    const copy_len = @min(old_size, new_size);
    const dst: [*]u8 = new_ptr;
    const src: [*]const u8 = @ptrFromInt(ptr);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    largeFree(ptr);
    return new_ptr;
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
    // ECX=0 means non-Lua path -- pass through to original
    if (pool_ctx == 0) {
        return pool_alloc_hook.callOriginal(.{ pool_ctx, old_ptr_raw, new_size });
    }

    if (new_size == 0) {
        if (old_ptr_raw != 0) slabFree(old_ptr_raw, pool_ctx);
        return null;
    }

    if (old_ptr_raw != 0) {
        return slabRealloc(old_ptr_raw, new_size, pool_ctx);
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

pub fn install() u32 {
    var installed: u32 = 0;
    if (pool_alloc_hook.attach(0x6FAE90, &poolAllocDetour) == .ok) installed += 1;
    if (gc_step_hook.attach(0x6FAE00, &gcStepDetour) == .ok) installed += 1;
    return installed;
}

pub fn remove() void {
    gc_step_hook.detach();
    pool_alloc_hook.detach();
}
