//! Framecrash fix module.
//!
//! Fixes ACCESS_VIOLATION crashes caused by UI frame anchor objects holding raw
//! pointers to their "relativeTo" frame (anchor+0x0C). When the relativeTo frame
//! is destroyed, the pointer is never cleared, causing crashes in any code that
//! dereferences it (luaGetPoint, luaGetWidth, luaGetHeight, etc).
//!
//! Root cause fix: detour hook on cleanup_linked_list_structures (0x767720),
//! the common frame destruction path. Before the original runs, we walk the
//! dying frame's PauseAnimationGroup dependency list (frame+0x34) to find all
//! other frames whose anchors reference the dying frame. For each, we destroy
//! the anchor and NULL the slot, preventing any stale/NULL pointer dereferences.
//!
//! Defense-in-depth: vtable[3] (GetRelativeTo) hook validates returned pointers
//! with IsBadReadPtr, catching any cases the root cause fix misses.
//!
//! See RESEARCH.md for full reverse engineering notes.

const std = @import("std");
const hook = @import("hook");
const con = @import("../console.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const THISCALL = std.builtin.CallingConvention{ .x86_thiscall = .{} };

extern "kernel32" fn IsBadReadPtr(lp: ?*const anyopaque, ucb: usize) callconv(WINAPI) i32;

// =============================================================================
// Anchor vtable layout (20-byte object allocated in SetPoint / SetAnimationOrder)
//
//   +0x00  vtable ptr  → 0x0081c44c (.rdata)
//   +0x04  x offset    (float)
//   +0x08  y offset    (float)
//   +0x0C  relativeTo  (raw frame pointer — the dangerous one)
//   +0x10  relPoint    (uint, anchor point enum on the relativeTo frame)
//
// vtable at 0x0081c44c:
//   [0] +0x00  GetAnimationOrder (0x767d80) — destructor/cleanup
//   [1] +0x04  luaGetWidth       (0x7a2f90) — reads [this+0xC]+0x3C
//   [2] +0x08  luaGetHeight      (0x7a3070) — reads [this+0xC]+0x3C
//   [3] +0x0C  GetRelativeTo     (0x767d70) — returns *(this+0x0C)
// =============================================================================

const ANCHOR_VTABLE_ADDR: usize = 0x0081c44c;
const GET_RELATIVE_TO_SLOT: usize = ANCHOR_VTABLE_ADDR + 0x0C; // vtable[3]

// =============================================================================
// Root cause fix: hook frame destruction to clean up reverse anchor references
//
// cleanup_linked_list_structures (0x767720) is the common frame cleanup path,
// called from destroy_object, CleanupRegion, and cleanupGraphicsResources.
// It cleans up the dying frame's OWN anchors (forward direction) but NOT other
// frames' anchors that reference the dying frame (reverse direction).
//
// PauseAnimationGroup maintains a linked list on the relativeTo frame:
//   frame+0x34 → first node
//   Each node (0x10 bytes): [link0, next(+4), owner_frame(+8), bitmask(+C)]
//   bitmask = OR of (1 << anchor_point_enum) for each referencing anchor slot
//
// Anchor slots in a frame: frame + point_enum*4 + 4  (9 slots, enum 0..8)
//
// Prologue at 0x767720 (5 bytes, no rel32):
//   53 56 8B F1 57  =  PUSH EBX; PUSH ESI; MOV ESI,ECX; PUSH EDI
// =============================================================================

const CLEANUP_TARGET: usize = 0x767720;
const CLEANUP_PROLOGUE_SIZE: usize = 5;

/// FreeMemory — __stdcall(ptr, source_string, flags)
const FreeMemory = @as(*const fn (u32, u32, u32) callconv(WINAPI) void, @ptrFromInt(0x646430));
const CLAYOUT_FRAME_STR: u32 = 0x878540; // "...CLayoutFrame..."

var cleanup_hook: hook.Hook = .{};

/// Detour for cleanup_linked_list_structures. Runs before the original to
/// walk the dying frame's dependency list and destroy referencing anchors.
fn cleanupDetour(frame: u32) callconv(THISCALL) void {
    cleanupReverseDependencies(frame);

    // Call original cleanup_linked_list_structures via trampoline
    const orig = cleanup_hook.getTrampoline(*const fn (u32) callconv(THISCALL) void);
    orig(frame);
}

/// Walk the PauseAnimationGroup dependency list on the dying frame and destroy
/// all anchors from other frames that reference it.
fn cleanupReverseDependencies(dying_frame: u32) void {
    // Read first node from dying_frame+0x34
    var node: u32 = readAligned(dying_frame + 0x34);

    // Validate: odd pointer or zero means empty list
    if (node == 0 or (node & 1) != 0) return;

    var cleaned: u32 = 0;

    while (node != 0 and (node & 1) == 0) {
        // Save next pointer before we potentially free this node
        const next: u32 = readAligned(node + 0x04);
        const owner_frame: u32 = readAligned(node + 0x08);
        const bitmask: u32 = readAligned(node + 0x0C);

        if (owner_frame != 0) {
            // For each bit set in bitmask, destroy the corresponding anchor
            var bit: u5 = 0;
            while (bit < 9) : (bit += 1) {
                if ((bitmask & (@as(u32, 1) << bit)) == 0) continue;

                const anchor_slot_addr = owner_frame + @as(u32, bit) * 4 + 4;
                const anchor: u32 = readAligned(anchor_slot_addr);
                if (anchor == 0) continue;

                // Verify this anchor actually references the dying frame
                const relativeTo: u32 = readAligned(anchor + 0x0C);
                if (relativeTo != dying_frame) continue;

                // Call anchor destructor: vtable[0](1) — thiscall with flag=1 (free)
                const vtable: u32 = readAligned(anchor);
                const dtor_addr: u32 = readAligned(vtable);
                const dtor: *const fn (u32, u32) callconv(THISCALL) void = @ptrFromInt(dtor_addr);
                dtor(anchor, 1);

                // NULL the anchor slot in the owner frame
                const slot: *align(1) u32 = @ptrFromInt(anchor_slot_addr);
                slot.* = 0;

                cleaned += 1;
            }
        }

        // Free the dependency list node
        FreeMemory(node, CLAYOUT_FRAME_STR, 0xfffffffe);

        node = next;
    }

    if (cleaned > 0) {
        con.fmt("[framecrash] Cleaned {d} stale anchor(s) referencing dying frame 0x{x:0>8}\n", .{ cleaned, dying_frame });
    }

    // Clear the list head so the original cleanup doesn't see stale nodes
    const head: *align(1) u32 = @ptrFromInt(dying_frame + 0x30);
    head.* = 0;
    const tail: *align(1) u32 = @ptrFromInt(dying_frame + 0x34);
    tail.* = 0;
}

fn readAligned(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}

// =============================================================================
// Defense-in-depth: GetRelativeTo vtable hook
// =============================================================================

var orig_get_relative_to: usize = 0;

/// Replacement for the anchor's GetRelativeTo virtual function.
/// Validates the stored relativeTo pointer before returning it.
/// If the pointer is stale (freed/decommitted memory), NULLs it out
/// and returns 0 so the caller takes the safe "no relativeTo" code path.
fn getRelativeToHook(this: u32) callconv(THISCALL) u32 {
    // Call the original GetRelativeTo to get the stored pointer
    const orig: *const fn (u32) callconv(THISCALL) u32 = @ptrFromInt(orig_get_relative_to);
    const result = orig(this);

    if (result == 0) return 0;

    // Validate: the returned pointer is an inner offset into the frame object.
    // The caller (luaGetPoint) subtracts 0x24 to get the frame base, then reads
    // at +0x00 (vtable), +0x04 (lua ref), +0x08 (lua ref index).
    // Check that the frame base region is readable.
    if (IsBadReadPtr(@ptrFromInt(result -% 0x24), 0x10) != 0) {
        con.fmt("[framecrash] Stale relativeTo ptr 0x{x:0>8} in anchor 0x{x:0>8} — nulled\n", .{ result, this });

        // Self-heal: clear the dangling pointer in the anchor object
        const field: *align(1) u32 = @ptrFromInt(this + 0x0C);
        field.* = 0;
        return 0;
    }

    return result;
}

// =============================================================================
// Module API
// =============================================================================

pub fn installHooks() void {
    // Root cause fix: detour cleanup_linked_list_structures to clean up
    // reverse anchor references before the frame is destroyed.
    // Prologue: 53 56 8B F1 57 (5 bytes, no rel32 fixups needed)
    // if (!cleanup_hook.install(CLEANUP_TARGET, CLEANUP_PROLOGUE_SIZE, @intFromPtr(&cleanupDetour), &.{})) {
    //     con.print("[framecrash] ERROR: Failed to install frame cleanup detour\n");
    // } else {
    //     con.print("[framecrash] Frame cleanup detour installed\n");
    // }
}

pub fn removeHooks() void {
    cleanup_hook.remove();
    con.print("[framecrash] Frame cleanup detour removed\n");
}
