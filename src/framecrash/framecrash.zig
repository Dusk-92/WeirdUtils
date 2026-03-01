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
//! other frames whose anchors reference the dying frame. For each, we NULL the
//! relativeTo field, preventing any stale pointer dereferences.
//!
//! Defense-in-depth: anchor vtable hooks on [1] GetWidth, [2] GetHeight, and
//! [3] GetRelativeTo. Each independently validates anchor+0x0C (relativeTo)
//! with IsBadReadPtr before use. GetWidth/GetHeight return the layout sentinel
//! from [0x00cf550c] when relativeTo is invalid. Catches cases the root cause
//! fix misses (frames destroyed through paths other than cleanup_linked_list).
//!
//! See RESEARCH.md for full reverse engineering notes.

const std = @import("std");
const hook = @import("hook");
const con = @import("../console.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const THISCALL = std.builtin.CallingConvention{ .x86_thiscall = .{} };

extern "kernel32" fn IsBadReadPtr(lp: ?*const anyopaque, ucb: usize) callconv(WINAPI) i32;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

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

var cleanup_hook: hook.Hook = .{};

// =============================================================================
// Second destruction path: destroyUIElement (0x7645a0)
//
// Called from cleanupGraphicsResources (UI teardown/reload) via the strata loop.
// Frees frames WITHOUT calling cleanup_linked_list_structures — just unlinks from
// lists, cleans up sub-regions, and calls FreeMemory. The dependency list at
// frame+0x34 is never walked, so other frames' anchors are left dangling.
//
// Signature: void* __thiscall destroyUIElement(void* this, byte free_flag)
// Prologue: 55 8B EC 56 8B F1 (6 bytes, no rel32)
// =============================================================================

const DESTROY_UI_TARGET: usize = 0x7645a0;
const DESTROY_UI_PROLOGUE_SIZE: usize = 6;

var destroy_ui_hook: hook.Hook = .{};

// =============================================================================
// Third destruction path: ProcessUIUpdateEvent (0x772ec0)
//
// Virtual function (vtable entry at 0x81c7ac), called via vtable dispatch.
// Calls CleanupUIElement + FreeMemory without cleanup_linked_list_structures.
// Signature: void* __thiscall ProcessUIUpdateEvent(void* this, byte free_flag)
// Prologue: 55 8B EC 56 8B F1 (6 bytes, no rel32)
// =============================================================================

const PROCESS_UI_TARGET: usize = 0x772ec0;
const PROCESS_UI_PROLOGUE_SIZE: usize = 6;

var process_ui_hook: hook.Hook = .{};

// =============================================================================
// Priority 1: Hook PauseAnimationGroup (0x767ee0) — dependency registration
//
// Records every dependency registration so we can later determine whether a
// stale relativeTo pointer was ever registered through PauseAnimationGroup.
// If PauseAnimationGroup was never called for an address, the dependency was
// never created — pointing to a race condition or unknown creation path.
//
// Signature: void __thiscall PauseAnimationGroup(ECX=relativeTo_frame, owner_frame, bitmask)
// Prologue: 55 8B EC 53 8B D9 (6 bytes, no rel32)
// RET 0x8 (callee cleans 2 stack args)
// =============================================================================

const PAUSE_ANIM_TARGET: usize = 0x767ee0;
const PAUSE_ANIM_PROLOGUE_SIZE: usize = 6;

var pause_anim_hook: hook.Hook = .{};

// =============================================================================
// Priority 2: Hook SetAnimationOrder (0x767c70) — anchor creation validation
//
// Validates the relativeTo param with IsBadReadPtr BEFORE the original runs.
// If relativeTo is already freed when the anchor is created, the dependency
// list node goes on dead frame memory (which may be reused). Detects race
// conditions at anchor creation time.
//
// Signature: void __thiscall SetAnimationOrder(ECX=frame, point_enum, relativeTo,
//            relPoint, xOfs, yOfs, param_6)
// Prologue: 55 8B EC 8B 45 0C (6 bytes, no rel32)
// RET 0x18 (callee cleans 6 stack args)
// =============================================================================

const SET_ANIM_TARGET: usize = 0x767c70;
const SET_ANIM_PROLOGUE_SIZE: usize = 6;

var set_anim_hook: hook.Hook = .{};

// =============================================================================
// Dependency registration ring buffer — track PauseAnimationGroup calls
//
// When vtable hooks detect a stale pointer, we look up this buffer to answer:
// "was PauseAnimationGroup ever called for this address?"
// =============================================================================

const REG_HISTORY_SIZE = 2048;

const DepRegistration = struct {
    relativeTo: u32 = 0, // the frame being depended upon (ECX of PauseAnimationGroup)
    owner: u32 = 0, // the frame that owns the anchor
    bitmask: u32 = 0, // which anchor slots (OR of 1<<point_enum)
    seq: u32 = 0, // monotonic sequence number for ordering
};

var reg_history: [REG_HISTORY_SIZE]DepRegistration = @splat(.{});
var reg_idx: u32 = 0;

fn recordRegistration(relativeTo: u32, owner: u32, bitmask: u32) void {
    const seq = reg_idx;
    reg_history[reg_idx % REG_HISTORY_SIZE] = .{
        .relativeTo = relativeTo,
        .owner = owner,
        .bitmask = bitmask,
        .seq = seq,
    };
    reg_idx +%= 1;
}

/// Look up whether PauseAnimationGroup was ever called for a given relativeTo address.
/// Returns the most recent registration entry if found, null otherwise.
fn lookupRegistration(relativeTo: u32) ?DepRegistration {
    // Search backwards from most recent for best chance of finding it
    var best: ?DepRegistration = null;
    for (&reg_history) |*entry| {
        if (entry.relativeTo == relativeTo) {
            if (best == null or entry.seq > best.?.seq) {
                best = entry.*;
            }
        }
    }
    return best;
}

/// Count all registrations for a given relativeTo address.
fn countRegistrations(relativeTo: u32) u32 {
    var count: u32 = 0;
    for (&reg_history) |*entry| {
        if (entry.relativeTo == relativeTo) count += 1;
    }
    return count;
}

// =============================================================================
// Destruction history ring buffer — correlate stale pointers with frame names
// =============================================================================

const HISTORY_SIZE = 1024;

const DestroyedFrame = struct {
    addr: u32 = 0,
    name: [63:0]u8 = @splat(0),
};

var destroy_history: [HISTORY_SIZE]DestroyedFrame = @splat(.{});
var history_idx: u32 = 0;

fn recordDestruction(layout_frame: u32) void {
    var entry = DestroyedFrame{};
    entry.addr = layout_frame;

    if (getFrameName(layout_frame)) |name| {
        const span = std.mem.span(name);
        const len = @min(span.len, 63);
        @memcpy(entry.name[0..len], span[0..len]);
    }

    destroy_history[history_idx % HISTORY_SIZE] = entry;
    history_idx +%= 1;
}

fn lookupDestroyed(layout_frame: u32) ?[]const u8 {
    for (&destroy_history) |*entry| {
        if (entry.addr == layout_frame) {
            const span = std.mem.sliceTo(&entry.name, 0);
            return if (span.len > 0) span else null;
        }
    }
    return null;
}

/// Format info about a stale relativeTo for vtable hook logging.
/// Checks the ring buffer first; falls back to reading (possibly garbage) memory.
fn fmtStaleInfo(relativeTo: u32) struct { name: []const u8, saw_destroy: bool } {
    if (lookupDestroyed(relativeTo)) |name| {
        return .{ .name = name, .saw_destroy = true };
    }
    return .{ .name = fmtFrameName(relativeTo), .saw_destroy = false };
}

/// Log registration status for a stale relativeTo address.
fn logRegistrationStatus(relativeTo: u32) void {
    const reg_count = countRegistrations(relativeTo);
    if (lookupRegistration(relativeTo)) |reg| {
        con.fmt("[framecrash]   DEP REGISTERED: PauseAnimGroup was called {d}x for 0x{x:0>8}, last owner=0x{x:0>8} mask=0x{x}\n", .{
            reg_count, relativeTo, reg.owner, reg.bitmask,
        });
    } else {
        con.fmt("[framecrash]   DEP NEVER REGISTERED: PauseAnimGroup was NEVER called for 0x{x:0>8} (in {d}-entry buffer)\n", .{
            relativeTo, REG_HISTORY_SIZE,
        });
    }
}

/// Dump diagnostic info for a stale relativeTo pointer not seen in our detour.
fn dumpStaleContext(relativeTo: u32, anchor: u32) void {
    // Anchor relPoint enum at +0x10
    if (IsBadReadPtr(@ptrFromInt(anchor + 0x10), 4) != 0) return;
    const rel_point = readAligned(anchor + 0x10);

    // Derive owner frame: anchor lives at owner_frame + relPoint*4 + 4
    const owner_layout = anchor -% (rel_point * 4 + 4);
    const owner_name = fmtFrameName(owner_layout);
    con.fmt("[framecrash]   owner=\"{s}\" (0x{x:0>8}), relPoint={d}, stale=0x{x:0>8}\n", .{
        owner_name, owner_layout, rel_point, relativeTo,
    });
}

/// Detour for cleanup_linked_list_structures. Runs before the original to
/// walk the dying frame's dependency list and destroy referencing anchors.
fn cleanupDetour(frame: u32) callconv(THISCALL) void {
    // Record this frame in the destruction history before anything changes
    recordDestruction(frame);

    // Count reverse dependencies for logging
    const dep_count = countReverseDependencies(frame);
    if (dep_count > 0) {
        con.fmt("[framecrash] Destroying frame \"{s}\" (0x{x:0>8}), {d} reverse dependencies\n", .{
            fmtFrameName(frame),
            frame,
            dep_count,
        });
    }

    cleanupReverseDependencies(frame);

    // Call original cleanup_linked_list_structures via trampoline
    const orig = cleanup_hook.getTrampoline(*const fn (u32) callconv(THISCALL) void);
    orig(frame);
}

/// Detour for destroyUIElement. This is the second frame destruction path,
/// called from cleanupGraphicsResources during UI teardown/reload. The original
/// frees frames without walking the dependency list, leaving stale anchors.
/// Signature: void* __thiscall destroyUIElement(void* this, byte free_flag)
fn destroyUIDetour(frame: u32, free_flag: u32) callconv(THISCALL) u32 {
    // Record both possible interpretations: frame as CLayoutFrame inner,
    // and frame+0x24 in case frame is actually a CFrame base.
    // Anchors store CLayoutFrame inner ptrs as relativeTo.
    recordDestruction(frame);
    if (IsBadReadPtr(@ptrFromInt(frame + 0x24), 4) == 0) {
        recordDestruction(frame + 0x24);
    }

    // Try cleaning deps at both offsets. cleanupReverseDependencies is
    // guarded by IsBadReadPtr so the wrong offset safely no-ops.
    const dep_count_a = countReverseDependencies(frame);
    const dep_count_b = countReverseDependencies(frame + 0x24);

    if (dep_count_a > 0) {
        con.fmt("[framecrash] destroyUIElement frame \"{s}\" (0x{x:0>8}), {d} reverse deps (layout)\n", .{
            fmtFrameName(frame), frame, dep_count_a,
        });
        cleanupReverseDependencies(frame);
    }
    if (dep_count_b > 0) {
        con.fmt("[framecrash] destroyUIElement frame \"{s}\" (0x{x:0>8}), {d} reverse deps (inner+0x24)\n", .{
            fmtFrameName(frame + 0x24), frame + 0x24, dep_count_b,
        });
        cleanupReverseDependencies(frame + 0x24);
    }

    // Call original destroyUIElement via trampoline
    const orig: *const fn (u32, u32) callconv(THISCALL) u32 = @ptrFromInt(destroy_ui_hook.trampoline);
    return orig(frame, free_flag);
}

/// Detour for ProcessUIUpdateEvent — third destruction path, called via vtable.
fn processUIDetour(frame: u32, free_flag: u32) callconv(THISCALL) u32 {
    recordDestruction(frame);
    if (IsBadReadPtr(@ptrFromInt(frame + 0x24), 4) == 0) {
        recordDestruction(frame + 0x24);
    }

    const dep_count_a = countReverseDependencies(frame);
    const dep_count_b = countReverseDependencies(frame + 0x24);

    if (dep_count_a > 0) {
        con.fmt("[framecrash] processUI frame \"{s}\" (0x{x:0>8}), {d} reverse deps (layout)\n", .{
            fmtFrameName(frame), frame, dep_count_a,
        });
        cleanupReverseDependencies(frame);
    }
    if (dep_count_b > 0) {
        con.fmt("[framecrash] processUI frame \"{s}\" (0x{x:0>8}), {d} reverse deps (inner+0x24)\n", .{
            fmtFrameName(frame + 0x24), frame + 0x24, dep_count_b,
        });
        cleanupReverseDependencies(frame + 0x24);
    }

    const orig: *const fn (u32, u32) callconv(THISCALL) u32 = @ptrFromInt(process_ui_hook.trampoline);
    return orig(frame, free_flag);
}

/// Detour for PauseAnimationGroup — records every dependency registration.
/// This tells us whether a stale relativeTo was ever registered through the
/// normal dependency tracking system.
/// Signature: void __thiscall PauseAnimationGroup(ECX=relativeTo_frame, owner_frame, bitmask)
fn pauseAnimDetour(relativeTo_frame: u32, owner_frame: u32, bitmask: u32) callconv(THISCALL) void {
    // Record this registration
    recordRegistration(relativeTo_frame, owner_frame, bitmask);

    con.fmt("[framecrash] PauseAnimGroup: relativeTo=0x{x:0>8} \"{s}\", owner=0x{x:0>8} \"{s}\", mask=0x{x}\n", .{
        relativeTo_frame,
        fmtFrameName(relativeTo_frame),
        owner_frame,
        fmtFrameName(owner_frame),
        bitmask,
    });

    // Call original
    const orig = pause_anim_hook.getTrampoline(*const fn (u32, u32, u32) callconv(THISCALL) void);
    orig(relativeTo_frame, owner_frame, bitmask);
}

/// Detour for SetAnimationOrder — validates relativeTo param before anchor creation.
/// Uses cdecl thunk bridge because the function has float params.
/// cdecl args: (ecx=frame, edx=unused, point_enum, relativeTo, relPoint, xOfs_bits, yOfs_bits, param_6)
fn setAnimOrderDetour(frame: u32, _edx: u32, point_enum: u32, relativeTo: u32, rel_point: u32, x_ofs: u32, y_ofs: u32, param_6: u32) callconv(.c) void {
    _ = _edx;

    // Validate relativeTo BEFORE the original creates the anchor
    if (relativeTo != 0) {
        if (IsBadReadPtr(@ptrFromInt(relativeTo), 0x10) != 0) {
            con.fmt("[framecrash] RACE: SetAnimOrder creating anchor with INVALID relativeTo=0x{x:0>8}! frame=0x{x:0>8} \"{s}\", point={d}\n", .{
                relativeTo,
                frame,
                fmtFrameName(frame),
                point_enum,
            });
        } else if (relativeTo == frame) {
            // Self-reference — the original function rejects this, but log it
            con.fmt("[framecrash] SetAnimOrder: self-reference rejected, frame=0x{x:0>8}\n", .{frame});
        }
    }

    // Call original trampoline as __thiscall(ECX=frame, 6 stack args).
    // All args are u32 — float params (xOfs, yOfs) are passed as raw bit patterns
    // which the original function reads from the stack as floats. The bit layout
    // is identical because __thiscall pushes all non-this args onto the stack.
    const orig: *const fn (u32, u32, u32, u32, u32, u32, u32) callconv(THISCALL) void =
        @ptrFromInt(set_anim_hook.trampoline);
    orig(frame, point_enum, relativeTo, rel_point, x_ofs, y_ofs, param_6);
}

/// Count how many nodes are in the PauseAnimationGroup dependency list.
fn countReverseDependencies(dying_frame: u32) u32 {
    if (IsBadReadPtr(@ptrFromInt(dying_frame + 0x34), 4) != 0) return 0;

    var node: u32 = readAligned(dying_frame + 0x34);
    if (node == 0 or (node & 1) != 0) return 0;

    var count: u32 = 0;
    while (node != 0 and (node & 1) == 0) {
        if (IsBadReadPtr(@ptrFromInt(node), 0x10) != 0) break;
        count += 1;
        node = readAligned(node + 0x04);
    }
    return count;
}

/// Walk the PauseAnimationGroup dependency list on the dying frame and NULL out
/// the relativeTo field in any anchors from other frames that reference it.
///
/// Safety: purely defensive — does NOT call destructors, free nodes, or modify
/// the dying frame's list pointers. The original cleanup_linked_list_structures
/// handles its own data structures.
fn cleanupReverseDependencies(dying_frame: u32) void {
    // Validate dying_frame+0x34 is readable before dereferencing
    if (IsBadReadPtr(@ptrFromInt(dying_frame + 0x34), 4) != 0) return;

    var node: u32 = readAligned(dying_frame + 0x34);

    // Validate: odd pointer or zero means empty list
    if (node == 0 or (node & 1) != 0) return;

    var cleaned: u32 = 0;

    while (node != 0 and (node & 1) == 0) {
        // Validate node is readable (need 0x10 bytes: link0, next, owner_frame, bitmask)
        if (IsBadReadPtr(@ptrFromInt(node), 0x10) != 0) break;

        const next: u32 = readAligned(node + 0x04);
        const owner_frame: u32 = readAligned(node + 0x08);
        const bitmask: u32 = readAligned(node + 0x0C);

        if (owner_frame != 0 and IsBadReadPtr(@ptrFromInt(owner_frame), 0x28) == 0) {
            var bit: u5 = 0;
            while (bit < 9) : (bit += 1) {
                if ((bitmask & (@as(u32, 1) << bit)) == 0) continue;

                const anchor_slot_addr = owner_frame + @as(u32, bit) * 4 + 4;
                const anchor: u32 = readAligned(anchor_slot_addr);
                if (anchor == 0) continue;

                // Validate anchor is readable (need vtable + xOfs + yOfs + relativeTo = 0x10)
                if (IsBadReadPtr(@ptrFromInt(anchor), 0x10) != 0) continue;

                // Verify this anchor actually references the dying frame
                const relativeTo: u32 = readAligned(anchor + 0x0C);
                if (relativeTo != dying_frame) continue;

                // Verify vtable matches the known anchor vtable — reject garbage objects
                const vtable: u32 = readAligned(anchor);
                if (vtable != ANCHOR_VTABLE_ADDR) continue;

                // NULL the relativeTo pointer so it can't dangle.
                // Don't call destructors or free the anchor — that risks cascading
                // side effects and is unnecessary. A NULL relativeTo is handled
                // gracefully by all code paths (luaGetPoint, GetWidth, GetHeight).
                const field: *align(1) u32 = @ptrFromInt(anchor + 0x0C);
                field.* = 0;

                cleaned += 1;
            }
        }

        node = next;
    }

    if (cleaned > 0) {
        con.fmt("[framecrash] Nulled {d} stale relativeTo ptr(s) referencing dying frame 0x{x:0>8}\n", .{ cleaned, dying_frame });
    }
}

fn readAligned(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}

/// Given a CLayoutFrame inner pointer, derive the CFrame base (subtract 0x24)
/// and read the name string at CFrame+0x98. Returns null if any pointer is
/// invalid or the name field is NULL.
fn getFrameName(layout_frame: u32) ?[*:0]const u8 {
    if (layout_frame < 0x24) return null;
    const frame_base = layout_frame -% 0x24;

    // Validate that frame_base+0x98 (name pointer field) is readable
    if (IsBadReadPtr(@ptrFromInt(frame_base + 0x98), 4) != 0) return null;

    const name_ptr = readAligned(frame_base + 0x98);
    if (name_ptr == 0) return null;

    // Validate the name string itself is readable (at least 1 byte)
    if (IsBadReadPtr(@ptrFromInt(name_ptr), 1) != 0) return null;

    return @ptrFromInt(name_ptr);
}

/// Format a frame name for logging — returns "FrameName" or "(unnamed)".
fn fmtFrameName(layout_frame: u32) []const u8 {
    if (getFrameName(layout_frame)) |name| {
        return std.mem.span(name);
    }
    return "(unnamed)";
}

// =============================================================================
// Defense-in-depth: anchor vtable hooks
//
// Three vtable slots must be hooked because they independently read anchor+0x0C
// (relativeTo) without going through each other:
//   [1] GetWidth  — reads [this+0xC]+0x3C, crashes if relativeTo is NULL/dangling
//   [2] GetHeight — same pattern as GetWidth
//   [3] GetRelativeTo — returns *(this+0x0C), caller dereferences it
//
// GetRelativeTo NULLs the pointer on detection (self-heal). GetWidth/GetHeight
// must independently handle both NULL and dangling relativeTo by returning the
// sentinel value from [0x00cf550c] — the value SetFrameHitTestMode compares
// against to detect "no dimension available".
// =============================================================================

const GET_WIDTH_SLOT: usize = ANCHOR_VTABLE_ADDR + 0x04; // vtable[1]
const GET_HEIGHT_SLOT: usize = ANCHOR_VTABLE_ADDR + 0x08; // vtable[2]

/// Sentinel float that SetFrameHitTestMode compares GetWidth/GetHeight results
/// against. Stored at runtime in .bss at 0x00cf550c.
const SENTINEL_ADDR: usize = 0x00cf550c;

var orig_get_width: usize = 0;
var orig_get_height: usize = 0;
var orig_get_relative_to: usize = 0;

/// Check if a relativeTo pointer (CLayoutFrame inner ptr) is valid.
/// Returns true if the pointer is non-NULL and the frame base region is readable.
fn isRelativeToValid(relativeTo: u32) bool {
    if (relativeTo == 0) return false;
    // relativeTo is an inner offset; callers subtract 0x24 for the frame base.
    // Validate that the frame base region (vtable + lua ref + index) is readable.
    return IsBadReadPtr(@ptrFromInt(relativeTo -% 0x24), 0x10) == 0;
}

/// Hook for vtable[3] GetRelativeTo. Validates the stored pointer.
/// If stale, NULLs anchor+0x0C and returns 0 (safe "no relativeTo" path).
fn getRelativeToHook(this: u32) callconv(THISCALL) u32 {
    const orig: *const fn (u32) callconv(THISCALL) u32 = @ptrFromInt(orig_get_relative_to);
    const result = orig(this);

    if (result == 0) return 0;

    if (!isRelativeToValid(result)) {
        const info = fmtStaleInfo(result);
        if (info.saw_destroy) {
            con.fmt("[framecrash] STALE: frame \"{s}\" (0x{x:0>8}) went through detour but dep list missed anchor 0x{x:0>8}, detected in GetRelativeTo\n", .{
                info.name, result, this,
            });
        } else {
            con.fmt("[framecrash] STALE: frame 0x{x:0>8} NOT seen in detour, anchor 0x{x:0>8}, detected in GetRelativeTo\n", .{
                result, this,
            });
            dumpStaleContext(result, this);
        }
        logRegistrationStatus(result);
        const field: *align(1) u32 = @ptrFromInt(this + 0x0C);
        field.* = 0;
        return 0;
    }

    return result;
}

/// Hook for vtable[1] GetWidth. Checks anchor+0x0C before calling original.
/// Returns sentinel if relativeTo is NULL or dangling.
/// Signature: f32 __thiscall GetWidth(this, u32 param) — callee cleans 1 stack arg.
fn getWidthHook(this: u32, param: u32) callconv(THISCALL) f32 {
    const relativeTo: u32 = readAligned(this + 0x0C);
    if (!isRelativeToValid(relativeTo)) {
        // Self-heal if dangling (not just NULL)
        if (relativeTo != 0) {
            const info = fmtStaleInfo(relativeTo);
            if (info.saw_destroy) {
                con.fmt("[framecrash] STALE: frame \"{s}\" (0x{x:0>8}) went through detour but dep list missed anchor 0x{x:0>8}, detected in GetWidth\n", .{
                    info.name, relativeTo, this,
                });
            } else {
                con.fmt("[framecrash] STALE: frame 0x{x:0>8} NOT seen in detour, anchor 0x{x:0>8}, detected in GetWidth\n", .{
                    relativeTo, this,
                });
                dumpStaleContext(relativeTo, this);
            }
            logRegistrationStatus(relativeTo);
            const field: *align(1) u32 = @ptrFromInt(this + 0x0C);
            field.* = 0;
        }
        return @as(*align(1) const f32, @ptrFromInt(SENTINEL_ADDR)).*;
    }

    const orig: *const fn (u32, u32) callconv(THISCALL) f32 = @ptrFromInt(orig_get_width);
    return orig(this, param);
}

/// Hook for vtable[2] GetHeight. Same pattern as GetWidth.
/// Signature: f32 __thiscall GetHeight(this, u32 param) — callee cleans 1 stack arg.
fn getHeightHook(this: u32, param: u32) callconv(THISCALL) f32 {
    const relativeTo: u32 = readAligned(this + 0x0C);
    if (!isRelativeToValid(relativeTo)) {
        if (relativeTo != 0) {
            const info = fmtStaleInfo(relativeTo);
            if (info.saw_destroy) {
                con.fmt("[framecrash] STALE: frame \"{s}\" (0x{x:0>8}) went through detour but dep list missed anchor 0x{x:0>8}, detected in GetHeight\n", .{
                    info.name, relativeTo, this,
                });
            } else {
                con.fmt("[framecrash] STALE: frame 0x{x:0>8} NOT seen in detour, anchor 0x{x:0>8}, detected in GetHeight\n", .{
                    relativeTo, this,
                });
                dumpStaleContext(relativeTo, this);
            }
            logRegistrationStatus(relativeTo);
            const field: *align(1) u32 = @ptrFromInt(this + 0x0C);
            field.* = 0;
        }
        return @as(*align(1) const f32, @ptrFromInt(SENTINEL_ADDR)).*;
    }

    const orig: *const fn (u32, u32) callconv(THISCALL) f32 = @ptrFromInt(orig_get_height);
    return orig(this, param);
}

// =============================================================================
// Module API
// =============================================================================

fn patchVtableSlot(slot_addr: usize, new_fn: usize, save_to: *usize) void {
    save_to.* = hook.readMem(u32, slot_addr);
    const new_val: u32 = @intCast(new_fn);
    hook.writeProtected(slot_addr, std.mem.asBytes(&new_val));
}

fn restoreVtableSlot(slot_addr: usize, saved: *usize) void {
    if (saved.* != 0) {
        const orig: u32 = @intCast(saved.*);
        hook.writeProtected(slot_addr, std.mem.asBytes(&orig));
        saved.* = 0;
    }
}

pub fn installHooks() void {
    // Multi-DLL safety: only one instance per process should hook
    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\FramecrashHook_{d}", .{GetCurrentProcessId()}) catch return;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[framecrash] Another DLL owns hooks (mutex taken), skipping\n");
        return;
    }
    g_is_hook_owner = true;

    // Root cause fix #1: detour cleanup_linked_list_structures to clean up
    // reverse anchor references before the frame is destroyed.
    // Prologue: 53 56 8B F1 57 (5 bytes, no rel32 fixups needed)
    if (!cleanup_hook.install(CLEANUP_TARGET, CLEANUP_PROLOGUE_SIZE, @intFromPtr(&cleanupDetour), &.{})) {
        con.print("[framecrash] ERROR: Failed to install frame cleanup detour\n");
    } else {
        con.print("[framecrash] Frame cleanup detour installed\n");
    }

    // Root cause fix #2: detour destroyUIElement — the second destruction path
    // used by cleanupGraphicsResources during UI teardown/reload. This path
    // frees frames without walking the dependency list.
    // Prologue: 55 8B EC 56 8B F1 (6 bytes, no rel32 fixups needed)
    if (!destroy_ui_hook.install(DESTROY_UI_TARGET, DESTROY_UI_PROLOGUE_SIZE, @intFromPtr(&destroyUIDetour), &.{})) {
        con.print("[framecrash] ERROR: Failed to install destroyUIElement detour\n");
    } else {
        con.print("[framecrash] destroyUIElement detour installed\n");
    }

    // Root cause fix #3: detour ProcessUIUpdateEvent — virtual function that
    // calls CleanupUIElement + FreeMemory without layout cleanup.
    // Prologue: 55 8B EC 56 8B F1 (6 bytes, no rel32 fixups needed)
    if (!process_ui_hook.install(PROCESS_UI_TARGET, PROCESS_UI_PROLOGUE_SIZE, @intFromPtr(&processUIDetour), &.{})) {
        con.print("[framecrash] ERROR: Failed to install ProcessUIUpdateEvent detour\n");
    } else {
        con.print("[framecrash] ProcessUIUpdateEvent detour installed\n");
    }

    // Defense-in-depth: patch anchor vtable[1]/[2]/[3] to validate relativeTo
    // before use. Catches dangling pointers from any destruction path.
    patchVtableSlot(GET_WIDTH_SLOT, @intFromPtr(&getWidthHook), &orig_get_width);
    patchVtableSlot(GET_HEIGHT_SLOT, @intFromPtr(&getHeightHook), &orig_get_height);
    patchVtableSlot(GET_RELATIVE_TO_SLOT, @intFromPtr(&getRelativeToHook), &orig_get_relative_to);
    con.print("[framecrash] Anchor vtable hooks installed (GetWidth/GetHeight/GetRelativeTo)\n");

    // Diagnostic: hook PauseAnimationGroup to track dependency registrations.
    // Answers: "was a dependency ever registered for this stale address?"
    // Prologue: 55 8B EC 53 8B D9 (6 bytes, no rel32)
    if (!pause_anim_hook.install(PAUSE_ANIM_TARGET, PAUSE_ANIM_PROLOGUE_SIZE, @intFromPtr(&pauseAnimDetour), &.{})) {
        con.print("[framecrash] ERROR: Failed to install PauseAnimationGroup detour\n");
    } else {
        con.print("[framecrash] PauseAnimationGroup detour installed\n");
    }

    // Diagnostic: hook SetAnimationOrder to detect race conditions.
    // Validates relativeTo param BEFORE anchor creation.
    // Prologue: 55 8B EC 8B 45 0C (6 bytes, no rel32)
    // Uses fastcall-to-cdecl thunk because of float stack params.
    if (set_anim_hook.prepare(SET_ANIM_TARGET, SET_ANIM_PROLOGUE_SIZE, &.{})) {
        const thunk = set_anim_hook.mem.? + 32;
        _ = hook.buildFastcallToCdeclThunk(thunk, @intFromPtr(&setAnimOrderDetour), 6);
        set_anim_hook.activate(@intFromPtr(thunk));
        con.print("[framecrash] SetAnimationOrder detour installed\n");
    } else {
        con.print("[framecrash] ERROR: Failed to install SetAnimationOrder detour\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // Remove diagnostic hooks first (reverse install order)
        set_anim_hook.remove();
        con.print("[framecrash] SetAnimationOrder detour removed\n");

        pause_anim_hook.remove();
        con.print("[framecrash] PauseAnimationGroup detour removed\n");

        // Restore original vtable pointers (reverse order)
        restoreVtableSlot(GET_RELATIVE_TO_SLOT, &orig_get_relative_to);
        restoreVtableSlot(GET_HEIGHT_SLOT, &orig_get_height);
        restoreVtableSlot(GET_WIDTH_SLOT, &orig_get_width);
        con.print("[framecrash] Anchor vtable hooks removed\n");

        process_ui_hook.remove();
        con.print("[framecrash] ProcessUIUpdateEvent detour removed\n");

        destroy_ui_hook.remove();
        con.print("[framecrash] destroyUIElement detour removed\n");

        cleanup_hook.remove();
        con.print("[framecrash] Frame cleanup detour removed\n");
    }

    if (g_is_hook_owner) {
        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
