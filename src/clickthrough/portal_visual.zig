//! portal_visual -- grey out unusable player-summoned portals/rituals.
//!
//! Hooks the M2 render pipeline to desaturate GO types 18 (ritual) and 22
//! (portal) whose creator is a player not in the local player's group.
//!
//! Three hooks:
//!   ManageRenderListNode (0x710B90) -- tags portal models when added to render list
//!   DrawBatchProjected (0x70CB30) -- sets rendering_portal flag around batch draw
//!   DrawIndexedPrimitive (D3D9 vtable[82]) -- swaps pixel shader to desaturate

const hook = @import("zhook");
const wow = @import("../wow.zig");
const offsets = @import("../offsets.zig");
const portal_filter = @import("portal_filter.zig");
const logging = @import("../logging.zig");

var log: logging.Logger = .{};

const WINAPI = @import("std").builtin.CallingConvention.winapi;
extern "kernel32" fn IsBadReadPtr(lp: u32, ucb: u32) callconv(WINAPI) i32;
extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new: u32, old: *u32) callconv(WINAPI) i32;

const MODEL_OWNER: usize = 0x28;
const RENDER_CTX_MODEL: usize = 0x3310;

// Tagged portal model set -- direct-mapped cache
const TAG_SIZE: u32 = 256;
const TAG_MASK: u32 = TAG_SIZE - 1;
var tagged_models: [TAG_SIZE]u32 = .{0} ** TAG_SIZE;

// Stores the GO object pointer alongside the model tag so we can access entity
const TagEntry = struct { model: u32 = 0, owner: u32 = 0 };
var tagged_entries: [TAG_SIZE]TagEntry = .{TagEntry{}} ** TAG_SIZE;

// Track entities we've already triggered fade on (one-shot test)
var fade_triggered: [TAG_SIZE]u32 = .{0} ** TAG_SIZE;

// CreateFadeEffect: __thiscall(entity_ECX, fadeTime_f32_stack)
const ENTITY_OFFSET: usize = 0x88;
const CreateFadeEffectFn = fn (u32, f32) callconv(hook.cc.thiscall) void;
const createFadeEffect: *const CreateFadeEffectFn = @ptrFromInt(0x672DF0);

// Deferred fade queue -- CreateFadeEffect is NOT safe to call during render list
// traversal (ManageRenderListNode). Queue owner ptrs and process next frame.
const FADE_QUEUE_SIZE: u32 = 16;
var fade_queue: [FADE_QUEUE_SIZE]u32 = .{0} ** FADE_QUEUE_SIZE;
var fade_queue_count: u32 = 0;

fn queueFade(owner: u32) void {
    if (fade_queue_count < FADE_QUEUE_SIZE) {
        fade_queue[fade_queue_count] = owner;
        fade_queue_count += 1;
    }
}

fn processFadeQueue() void {
    var i: u32 = 0;
    while (i < fade_queue_count) : (i += 1) {
        triggerFade(fade_queue[i]);
        fade_queue[i] = 0;
    }
    fade_queue_count = 0;
}

fn triggerFade(owner: u32) void {
    if (IsBadReadPtr(owner, 0x90) != 0) return;
    const entity = hook.readMem(u32, owner + ENTITY_OFFSET);
    if (entity == 0) return;
    if (IsBadReadPtr(entity, 0xC0) != 0) return;
    const scene_obj = hook.readMem(u32, entity + 0x88);
    if (scene_obj == 0) return;
    log.fmt("triggerFade: owner=0x{x} entity=0x{x} scene=0x{x}\n", .{ owner, entity, scene_obj });
    createFadeEffect(entity, 1.0);
}

fn classifyModel(model: u32) void {
    const owner = hook.readMem(u32, model + MODEL_OWNER);
    if (owner == 0) return;
    if (IsBadReadPtr(owner, 0x20) != 0) return;
    const obj_type = hook.readMem(u32, owner + 0x14);
    if (obj_type != 5) {
        if (tagged_models[model & TAG_MASK] == model) {
            tagged_models[model & TAG_MASK] = 0;
            tagged_entries[model & TAG_MASK] = .{};
        }
        return;
    }
    const desc = wow.getDescriptor(owner);
    if (!wow.isValidPtr(desc)) return;
    const go_type = hook.readMem(u32, desc + offsets.DESC_GO_TYPE);
    if ((go_type == 18 or go_type == 22) and portal_filter.shouldFilter(desc)) {
        tagged_models[model & TAG_MASK] = model;
        tagged_entries[model & TAG_MASK] = .{ .model = model, .owner = owner };
    } else {
        if (tagged_models[model & TAG_MASK] == model) {
            tagged_models[model & TAG_MASK] = 0;
            tagged_entries[model & TAG_MASK] = .{};
        }
    }
}

fn isTagged(model: u32) bool {
    return tagged_models[model & TAG_MASK] == model;
}

var rendering_portal: bool = false;
var log_count: u32 = 0;

// =============================================================================
// Hook: ManageRenderListNode (0x710B90)
// =============================================================================

const ManageRenderFn = fn (u32, u32) callconv(hook.cc.thiscall) void;
var manage_hook: hook.Detour(ManageRenderFn) = .{};

fn manageRenderDetour(model: u32, add_to_list: u32) callconv(hook.cc.thiscall) void {
    if (model != 0 and add_to_list == 1) {
        classifyModel(model);
        if (isTagged(model)) {
            const entry = tagged_entries[model & TAG_MASK];
            // One-shot: trigger fade test on first detection
            if (entry.owner != 0 and fade_triggered[model & TAG_MASK] != model) {
                fade_triggered[model & TAG_MASK] = model;
                triggerFadeTest(entry.owner);
            }
        }
    } else if (model != 0) {
        if (tagged_models[model & TAG_MASK] == model) {
            tagged_models[model & TAG_MASK] = 0;
            tagged_entries[model & TAG_MASK] = .{};
        }
    }
    manage_hook.callOriginal(.{ model, add_to_list });
}

// =============================================================================
// Hook: DrawBatchProjected (0x70CB30)
// =============================================================================

const DrawBatchFn = fn (u32) callconv(hook.cc.thiscall) void;
var draw_batch_hook: hook.Detour(DrawBatchFn) = .{};

const MODEL_ALPHA: usize = 0x180; // written by fade system via SetMemoryPointer
const DIM_ALPHA: u32 = @bitCast(@as(f32, 0.35));
const FULL_ALPHA: u32 = @bitCast(@as(f32, 1.0));

fn drawBatchDetour(ctx: u32) callconv(hook.cc.thiscall) void {
    const model_ptr = if (wow.isValidPtr(ctx +% @as(u32, @intCast(RENDER_CTX_MODEL))))
        hook.readMem(u32, ctx + RENDER_CTX_MODEL)
    else
        0;

    if (model_ptr != 0 and isTagged(model_ptr)) {
        // Write dim alpha to the model's opacity field before batch draws
        const saved = hook.readMem(u32, model_ptr + MODEL_ALPHA);
        const dest: *u32 = @ptrFromInt(model_ptr + MODEL_ALPHA);
        dest.* = DIM_ALPHA;

        rendering_portal = true;
        draw_batch_hook.callOriginal(.{ctx});
        rendering_portal = false;

        dest.* = saved;
    } else {
        draw_batch_hook.callOriginal(.{ctx});
    }
}

// =============================================================================
// D3D9 DIP hook + desaturation pixel shader
// =============================================================================

inline fn vt(obj: *anyopaque) [*]usize {
    return @ptrFromInt(hook.readMem(u32, @intFromPtr(obj)));
}

const VT_DIP: usize = 82;
const VT_CreatePixelShader: usize = 106;
const VT_SetPixelShader: usize = 107;
const VT_GetPixelShader: usize = 108;
const VT_SetPSConstantF: usize = 109;

var orig_dip: usize = 0;
var d3d9_vtable: ?[*]usize = null;
var desat_shader: ?*anyopaque = null;

// ps_2_0 desaturation shader: samples texture, converts to greyscale via luminance.
// c0 = luminance weights (0.299, 0.587, 0.114, 0.0)
//
//   ps_2_0
//   dcl t0.xy
//   dcl_2d s0
//   texld r0, t0, s0        ; sample texture
//   dp3 r1.x, r0, c0        ; grey = dot(rgb, luma)
//   mov r1.y, r1.x           ; replicate
//   mov r1.z, r1.x
//   mov r1.w, r0.w           ; preserve alpha
//   mov oC0, r1
//
// Assembled from the D3D shader token spec (ps_2_0 format):
const desat_shader_bytecode = [_]u32{
    0xFFFF0200, // ps_2_0
    // dcl t0.xy
    0x0200001F, 0x80000000, 0xB0030000,
    // dcl_2d s0
    0x0200001F, 0x90000000, 0xA00F0800,
    // texld r0, t0, s0
    0x03000042, 0x800F0000, 0xB0E40000, 0xA0E40800,
    // dp3 r1.x, r0, c0
    0x03000008, 0x80010001, 0x80E40000, 0xA0E40000,
    // mov r1.y, r1.x
    0x02000001, 0x80020001, 0x80000001,
    // mov r1.z, r1.x
    0x02000001, 0x80040001, 0x80000001,
    // mov r1.w, r0.w
    0x02000001, 0x80080001, 0x80FF0000,
    // mov oC0, r1
    0x02000001, 0x800F0800, 0x80E40001,
    // end
    0x0000FFFF,
};

const luma_weights = [4]f32{ 0.299, 0.587, 0.114, 0.0 };

fn createShader(device: *anyopaque) bool {
    const createFn: *const fn (*anyopaque, [*]const u32, **anyopaque) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(vt(device)[VT_CreatePixelShader]);
    var shader: ?*anyopaque = null;
    const hr = createFn(device, &desat_shader_bytecode, @ptrCast(&shader));
    if (hr >= 0 and shader != null) {
        desat_shader = shader;
        return true;
    }
    log.fmt("CreatePixelShader failed: hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
    return false;
}

fn hkDIP(
    device: *anyopaque,
    prim_type: u32,
    base_vtx: i32,
    min_vtx: u32,
    num_verts: u32,
    start_idx: u32,
    prim_count: u32,
) callconv(hook.cc.stdcall) i32 {
    const origFn: *const fn (*anyopaque, u32, i32, u32, u32, u32, u32) callconv(hook.cc.stdcall) i32 =
        @ptrFromInt(orig_dip);

    if (rendering_portal and desat_shader != null) {
        // Save current pixel shader
        var saved_ps: ?*anyopaque = null;
        const getFn: *const fn (*anyopaque, *?*anyopaque) callconv(hook.cc.stdcall) i32 =
            @ptrFromInt(vt(device)[VT_GetPixelShader]);
        _ = getFn(device, &saved_ps);

        // Set desaturation shader + luminance weights
        const setFn: *const fn (*anyopaque, ?*anyopaque) callconv(hook.cc.stdcall) i32 =
            @ptrFromInt(vt(device)[VT_SetPixelShader]);
        _ = setFn(device, desat_shader);

        const setConstFn: *const fn (*anyopaque, u32, [*]const f32, u32) callconv(hook.cc.stdcall) i32 =
            @ptrFromInt(vt(device)[VT_SetPSConstantF]);
        _ = setConstFn(device, 0, &luma_weights, 1);

        const result = origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);

        // Restore pixel shader
        _ = setFn(device, saved_ps);
        if (saved_ps) |ps| {
            const relFn: *const fn (*anyopaque) callconv(hook.cc.stdcall) u32 = @ptrFromInt(vt(ps)[2]);
            _ = relFn(ps);
        }

        return result;
    }

    return origFn(device, prim_type, base_vtx, min_vtx, num_verts, start_idx, prim_count);
}

fn patchVtableEntry(vtable_ptr: [*]usize, idx: usize, new_fn: usize, old_fn: *usize) bool {
    old_fn.* = vtable_ptr[idx];
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0) return false;
    vtable_ptr[idx] = new_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
    return true;
}

fn restoreVtableEntry(vtable_ptr: [*]usize, idx: usize, old_fn: usize) void {
    var old_prot: u32 = 0;
    const addr: *anyopaque = @ptrFromInt(@intFromPtr(&vtable_ptr[idx]));
    if (VirtualProtect(addr, @sizeOf(usize), 0x40, &old_prot) == 0) return;
    vtable_ptr[idx] = old_fn;
    _ = VirtualProtect(addr, @sizeOf(usize), old_prot, &old_prot);
}

fn getD3D9VTable() ?[*]usize {
    const gx = hook.readMem(u32, offsets.GX_DEVICE_PTR);
    if (gx == 0) return null;
    const dev = hook.readMem(u32, gx + offsets.GX_DEVICE_D3D_OFFSET);
    if (dev == 0) return null;
    const vtable_addr = hook.readMem(u32, dev);
    if (vtable_addr == 0) return null;
    return @ptrFromInt(vtable_addr);
}

var d3d9_initialized: bool = false;

fn initD3D9() void {
    // DIP shader hook disabled -- testing model+0x180 alpha approach
}

// =============================================================================
// Install / Remove
// =============================================================================

pub fn install() bool {
    log = logging.Logger.open("portal_visual", .both);
    if (manage_hook.attach(0x710B90, &manageRenderDetour) != .ok) return false;
    if (draw_batch_hook.attach(0x70CB30, &drawBatchDetour) != .ok) {
        manage_hook.detach();
        return false;
    }
    return true;
}

/// Deferred D3D9 init -- call from lateInit when device exists.
pub fn lateInit() void {
    initD3D9();
}

pub fn remove() void {
    if (d3d9_vtable) |vtbl| {
        if (orig_dip != 0) restoreVtableEntry(vtbl, VT_DIP, orig_dip);
    }
    draw_batch_hook.detach();
    manage_hook.detach();
}
