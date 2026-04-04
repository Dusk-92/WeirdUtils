//! Click-through module.
//!
//! Priority raycast cascade: instead of one raycast that picks the nearest
//! object, we run up to 3 filtered raycasts in priority order. Each pass
//! uses custom flag bits in CanTargetEntity to exclude unwanted objects at
//! the raycast level (terrain/WMO occlusion applies per pass).
//!
//!   Pass 1 (loot):  only lootable corpses
//!   Pass 2 (GO):    only interactable game objects
//!   Pass 3 (NPC):   only units with NPC interaction flags
//!   Fallthrough:     normal unfiltered behavior
//!
//! Hooks:
//!   CanTargetEntity (0x480610) - per-object filter, reads custom flag bits
//!   WorldIntersectionTest (0x480DF0) - runs the cascade

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");
const offsets = @import("../offsets.zig");
const wow = @import("../wow.zig");
const portal_filter = @import("portal_filter.zig");
// const portal_visual = @import("portal_visual.zig");

pub const module_name: [*:0]const u8 = "clickthrough";

// =============================================================================
// Addresses
// =============================================================================

const ADDR_WorldIntersectionTest: usize = 0x480DF0;
const ADDR_CanTargetEntity: usize = 0x480610;
const ADDR_CheckObjectTypePermissions: usize = 0x480780;

// =============================================================================
// HitTestResult layout
// =============================================================================

const HIT_GUID_LO: usize = 0x00;
const HIT_GUID_HI: usize = 0x04;
const HIT_RESULT_SIZE: usize = 0x34;

// =============================================================================
// Custom raycast flag bits (upper bits unused by game)
// =============================================================================

// Standard vanilla NPC interaction flags (gossip through repair)
const NPC_INTERACT_MASK: u32 = 0x00007FFF;

// PLAYER_FLAGS descriptor offset (UpdateField index 190, byte offset 190*4=0x2F8)
const DESC_PLAYER_FLAGS: usize = 0x2F8;
const PLAYER_FLAG_GM: u32 = 0x08;

const FLAG_LOOT_ONLY: u32 = 0x01000000; // pass 1: only lootable corpses
const FLAG_GO_ONLY: u32 = 0x02000000; // pass 2: only interactable GOs
const FLAG_NPC_ONLY: u32 = 0x04000000; // pass 3: only interactable NPCs
const FLAG_CUSTOM_MASK: u32 = FLAG_LOOT_ONLY | FLAG_GO_ONLY | FLAG_NPC_ONLY;

// =============================================================================
// Hook state
// =============================================================================

fn isGM() bool {
    const player = wow.getLocalPlayer();
    if (player == 0) return false;
    const desc = wow.getDescriptor(player);
    if (!wow.isValidPtr(desc)) return false;
    return (hook.readMem(u32, desc + DESC_PLAYER_FLAGS) & PLAYER_FLAG_GM) != 0;
}

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};
var go_log_count: u32 = 0;

// CheckObjectTypePermissions (0x480780) -- verified from assembly:
// __thiscall: ECX=context (saved to EDI, passed to CanTargetEntity)
// Stack: objectData [EBP+8], permFlags [EBP+C]. RET 0x8.
const CheckObjTypeFn = fn (u32, u32, u32) callconv(hook.cc.thiscall) u32;
var cotp_hook: hook.Detour(CheckObjTypeFn) = .{};

const WorldIntersectFn = fn (u32, u32, u32, u32, u32) callconv(hook.cc.thiscall) u32;
var wit_hook: hook.Detour(WorldIntersectFn) = .{};

// =============================================================================
// Hook: CanTargetEntity (0x480610)
// Per-object filter called during raycast enumeration.
// When custom flag bits are set, exclude objects that don't match the pass.
// =============================================================================

fn checkObjTypeDetour(ctx: u32, obj_data: u32, perm_flags: u32) callconv(hook.cc.thiscall) u32 {
    // Strip custom bits before passing to original
    const clean_flags = perm_flags & ~FLAG_CUSTOM_MASK;
    const original = cotp_hook.callOriginal(.{ ctx, obj_data, clean_flags });

    // If original says exclude, respect that
    if (original == 0) return 0;

    // Resolve the object pointer from obj_data via ClntObjMgrObjectPtr.
    // __fastcall(ECX=typeMask, EDX=debugStr, stack: guid_lo, guid_hi, debugCode)
    // RET 0xC. See nampower ClntObjMgrObjectPtrT typedef.
    const obj = hook.call(
        fn (u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) u32,
        0x468460, // ClntObjMgrObjectPtr
        .{ 1, 0, hook.readMem(u32, obj_data + 0x18), hook.readMem(u32, obj_data + 0x1C), 0 },
    );
    if (obj == 0) return original;

    const desc = wow.getDescriptor(obj);
    if (!wow.isValidPtr(desc)) return original;
    const type_mask = hook.readMem(u32, desc + 0x08);

    // Always block unusable player-summoned portals/rituals (all passes)
    if (type_mask == 0x21) {
        const go_type = hook.readMem(u32, desc + offsets.DESC_GO_TYPE);
        if ((go_type == 18 or go_type == 22) and portal_filter.shouldFilter(desc))
            return 0;
    }

    // No custom filtering active - pass through
    if ((perm_flags & FLAG_CUSTOM_MASK) == 0) return original;

    if ((perm_flags & FLAG_LOOT_ONLY) != 0) {
        if (type_mask != 0x09) return 0; // units only
        if (!wow.isLootable(obj)) return 0;
        return original;
    }

    if ((perm_flags & FLAG_GO_ONLY) != 0) {
        if (type_mask != 0x21) return 0; // GOs only
        const go_type = hook.readMem(u32, desc + offsets.DESC_GO_TYPE);
        if (go_type == 9 or go_type == 7) return 0; // TEXT, CHAIR
        if (hook.call(fn (u32) callconv(hook.cc.fastcall) u8, offsets.FN_CALL_SPELL_CAST_HANDLER, .{obj}) == 0)
            return 0;
        return original;
    }

    if ((perm_flags & FLAG_NPC_ONLY) != 0) {
        if (type_mask != 0x09 and type_mask != 0x19) return 0; // units/players only
        if ((wow.getNpcFlags(obj) & NPC_INTERACT_MASK) == 0) return 0;
        return original;
    }

    return original;
}

// =============================================================================
// Hook: WorldIntersectionTest (0x480DF0)
// Priority raycast cascade: loot > GO > NPC > normal
// =============================================================================

fn worldIntersectDetour(world_frame: u32, ray_start: u32, ray_end: u32, flags: u32, hit_result: u32) callconv(hook.cc.thiscall) u32 {
    // Don't cascade if we're already in a custom pass (prevent recursion),
    // in a battleground, or in GM mode (GMs need unfiltered targeting)
    if (!g_is_hook_owner or (flags & FLAG_CUSTOM_MASK) != 0 or wow.isInBattleground() or isGM()) {
        return wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, flags, hit_result });
    }

    // Pass 1: lootable corpses (units + dead + our custom filter)
    {
        const loot_flags = (flags | FLAG_LOOT_ONLY) & ~@as(u32, 0x10); // include units, exclude players
        const hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, loot_flags, hit_result });
        if (hit_type == 2) return hit_type;
    }

    // Pass 2: interactable game objects
    {
        const go_flags = (flags | FLAG_GO_ONLY);
        const hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, go_flags, hit_result });
        if (hit_type == 2) return hit_type;
    }

    // Pass 3: interactable NPCs
    {
        const npc_flags = (flags | FLAG_NPC_ONLY) & ~@as(u32, 0x10); // include units, exclude players
        const hit_type = wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, npc_flags, hit_result });
        if (hit_type == 2) return hit_type;
    }

    // Fallthrough: normal unfiltered raycast
    return wit_hook.callOriginal(.{ world_frame, ray_start, ray_end, flags, hit_result });
}

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .both);
    _ = cotp_hook.attach(ADDR_CheckObjectTypePermissions, &checkObjTypeDetour);
    _ = wit_hook.attach(ADDR_WorldIntersectionTest, &worldIntersectDetour);
    // _ = portal_visual.install();
    log.print("clickthrough: cascade raycast active\n");
}

pub fn lateInit() void {
    if (!g_is_hook_owner) return;
    // portal_visual.lateInit();
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        // portal_visual.remove();
        wit_hook.detach();
        cotp_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}

pub fn onShutdown() void {}
