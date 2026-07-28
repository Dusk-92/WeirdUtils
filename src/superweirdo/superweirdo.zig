//! SuperWeirdo -- GO loot sparkle for interactable objects
//!
//! Replicates the SuperWoW loot sparkle feature via two patches and three
//! cleanup hooks:
//!
//! Patches:
//!   1. UpdateUnitStatusFlags (0x60c520) status flags initializer:
//!      0x60c560: imm32 0x00000000 -> 0x00002000
//!      Sets bit 13 in status flags, enabling sparkle visual on qualifying objects.
//!
//!   2. AttachSpellVisualToUnit (0x61fc00) object type mask:
//!      0x61fc1c: MOV ECX,0x8 -> MOV ECX,0x1
//!      Changes type filter from Unit-only (0x8) to Object base (0x1),
//!      allowing visual attachments on GOs.
//!
//!   3. Data constant at 0x838f7c: 0x14 -> 0x0D
//!      Adjusts sparkle-related rendering parameter.
//!
//! Cleanup hooks (prevent leaked render nodes on GO lifecycle changes):
//!   Vanilla GOs never had visual attachments, so their destroy/update paths
//!   don't clean them up. We hook three GO lifecycle functions and walk the
//!   render node list (obj+0xB4) to unlink+release any sparkle nodes
//!   (identified by node+0x2C & 0x8).

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "superweirdo";

// -- Sparkle cleanup logic ----------------------------------------------------

/// Walk obj+0xB4 render node linked list. Find the first node with flag 0x8
/// set at node+0x2C (visual attachment marker), unlink and release it.
fn cleanupSparkleNodes(obj: u32) void {
    var node: u32 = hook.readMem(u32, obj + 0xB4);
    while (node != 0) {
        const flags: u8 = hook.readMem(u8, node + 0x2C);
        if (flags & 0x8 != 0) {
            // UnlinkObjectFromList: __thiscall(ECX=node)
            hook.call(fn (u32) callconv(hook.cc.thiscall) void, 0x6203a0, .{node});
            // DecrementRefCountAndCleanup: __thiscall(ECX=node)
            hook.call(fn (u32) callconv(hook.cc.thiscall) void, 0x6210e0, .{node});
            return;
        }
        node = hook.readMem(u32, node + 0x8C);
    }
}

// -- Detour hooks -------------------------------------------------------------

// Hook 1: UpdateGameObjectAnimationAndDB (0x5f7c40)
// __thiscall(ECX=this), 3 stack params, RET 0xC
const GoAnimFn = fn (u32, u32, u32, u32) callconv(hook.cc.thiscall) void;
var go_anim_hook: hook.Detour(GoAnimFn) = .{};

fn goAnimDetour(this: u32, p1: u32, p2: u32, p3: u32) callconv(hook.cc.thiscall) void {
    go_anim_hook.callOriginal(.{ this, p1, p2, p3 });
    cleanupSparkleNodes(this);
}

// Hook 2: GO update function (0x5f7ed0)
// __thiscall(ECX=this), no stack params, RET
const GoThiscallFn = fn (u32) callconv(hook.cc.thiscall) void;
var go_update_hook: hook.Detour(GoThiscallFn) = .{};

fn goUpdateDetour(this: u32) callconv(hook.cc.thiscall) void {
    go_update_hook.callOriginal(.{this});
    cleanupSparkleNodes(this);
}

// Hook 3: GameObjectCacheCallback (0x5f7e40)
// __thiscall(ECX=this), no stack params, RET
var go_cache_hook: hook.Detour(GoThiscallFn) = .{};

fn goCacheDetour(this: u32) callconv(hook.cc.thiscall) void {
    cleanupSparkleNodes(this);
    go_cache_hook.callOriginal(.{this});
}

// -- Byte patches -------------------------------------------------------------

const Patch = struct {
    addr: usize,
    old: []const u8,
    new: []const u8,
    desc: []const u8,
};

const byte_patches = [_]Patch{
    // UpdateUnitStatusFlags: init flags to 0x2000 (bit 13) instead of 0
    .{
        .addr = 0x0060c560,
        .old = &.{ 0x00, 0x00, 0x00, 0x00 },
        .new = &.{ 0x00, 0x20, 0x00, 0x00 },
        .desc = "status flags init 0x2000",
    },
    // AttachSpellVisualToUnit: type mask 0x8 (Unit) -> 0x1 (Object base)
    .{
        .addr = 0x0061fc1c,
        .old = &.{ 0xB9, 0x08, 0x00, 0x00 },
        .new = &.{ 0xB9, 0x01, 0x00, 0x00 },
        .desc = "visual attach type mask",
    },
    // Data value at 0x838f7c: 0x14 -> 0x0D
    .{
        .addr = 0x00838f7c,
        .old = &.{ 0x14, 0x00, 0x00, 0x00 },
        .new = &.{ 0x0D, 0x00, 0x00, 0x00 },
        .desc = "sparkle data constant",
    },
};

// -- Module interface ---------------------------------------------------------

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var g_patches_applied: [byte_patches.len]bool = .{false} ** byte_patches.len;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .console);

    // Byte patches
    inline for (byte_patches, 0..) |p, i| {
        const current = hook.readMem([p.old.len]u8, p.addr);
        if (std.mem.eql(u8, &current, p.old)) {
            hook.writeProtected(p.addr, p.new);
            g_patches_applied[i] = true;
            log.fmt("{s}: patched\n", .{p.desc});
        } else if (std.mem.eql(u8, &current, p.new)) {
            g_patches_applied[i] = true;
            log.fmt("{s}: already active\n", .{p.desc});
        } else {
            log.fmt("{s}: unexpected bytes at 0x{x}, skipping\n", .{ p.desc, p.addr });
        }
    }

    // Detour hooks for GO sparkle cleanup
    if (go_anim_hook.attach(0x5f7c40, &goAnimDetour) != .ok) {
        log.print("WARN: failed to attach goAnimDetour\n");
    }
    if (go_update_hook.attach(0x5f7ed0, &goUpdateDetour) != .ok) {
        log.print("WARN: failed to attach goUpdateDetour\n");
    }
    if (go_cache_hook.attach(0x5f7e40, &goCacheDetour) != .ok) {
        log.print("WARN: failed to attach goCacheDetour\n");
    }
    log.print("GO cleanup hooks installed\n");
}

pub fn removeHooks() void {
    if (!g_is_hook_owner) return;

    go_cache_hook.detach();
    go_update_hook.detach();
    go_anim_hook.detach();

    inline for (byte_patches, 0..) |p, i| {
        if (g_patches_applied[i]) {
            hook.writeProtected(p.addr, p.old);
            g_patches_applied[i] = false;
            log.fmt("{s}: restored\n", .{p.desc});
        }
    }

    log.close();
    mod_mutex.release(&g_mutex);
    g_is_hook_owner = false;
}
