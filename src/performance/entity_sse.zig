//! SSE-optimized entity update functions -- compiled ReleaseFast.
//!
//! Reimplements UpdateEntityAndChunksPositions (0x6AFAD0) and
//! updateEntitiesInBounds (0x6C1F70).
//!
//! Main optimization: SSE dot product for view-depth computation,
//! tighter control flow, reduced function call overhead.

const V4 = @Vector(4, f32);

fn readU32(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}
fn readI32(addr: u32) i32 {
    return @as(*align(1) const i32, @ptrFromInt(addr)).*;
}
fn readF32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}
fn writeU32(addr: u32, val: u32) void {
    @as(*align(1) u32, @ptrFromInt(addr)).* = val;
}
fn writeF32(addr: u32, val: f32) void {
    @as(*align(1) f32, @ptrFromInt(addr)).* = val;
}

// =========================================================================
// Game function declarations (resolved at link time via absolute address)
// =========================================================================

// recycleVertexBuffer: fastcall(ECX=bufPtr, EDX=sizePtr), RET
const recycleVertexBuffer = @as(*const fn (u32, u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6AE9A0));
// check_instances_active: fastcall(ECX=instanceMgr) -> ptr, RET
const check_instances_active = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) u32, @ptrFromInt(0x6B2900));
// store_all_instance_buffers: fastcall(ECX=instanceMgr), RET
const store_all_instance_buffers = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6B28E0));
// return_object_to_pool: fastcall(ECX=instanceMgr), RET
const return_object_to_pool = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6B2030));
// ReturnChunkBuffers: fastcall(ECX=bufPtr, EDX=sizePtr), RET
const ReturnChunkBuffers = @as(*const fn (u32, u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x68CD50));
// IsPointInsideBounds: fastcall(ECX=point, EDX=bounds) -> u32, RET
const IsPointInsideBounds = @as(*const fn (u32, u32) callconv(.{ .x86_fastcall = .{} }) u32, @ptrFromInt(0x699330));
// AddObjectToSpatialList: fastcall(ECX=entityPtr, EDX=posPtr), RET
const AddObjectToSpatialList = @as(*const fn (u32, u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6818B0));
// AddToSpatialGrid: fastcall(ECX=objPtr), RET
const AddToSpatialGrid = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6816F0));
// CopyChunkBounds: thiscall(ECX=chunk, stack=outBounds), RET 0x4
const CopyChunkBounds = @as(*const fn (u32, u32) callconv(.{ .x86_thiscall = .{} }) void, @ptrFromInt(0x68DF40));
// AddToLayeredSpatialGrid: fastcall(ECX=chunk, EDX=idx, stack=posPtr), RET 0x4
const AddToLayeredSpatialGrid = @as(*const fn (u32, u32, u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x681970));

// ComplexMemoryCleanupAndRelease: fastcall(ECX=memObj)
const ComplexMemoryCleanupAndRelease = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6A0510));
// destroySecondaryGameObject: fastcall(ECX=entityPtr)
const destroySecondaryGameObject = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6A6A00));

// Game globals
const g_viewCoeffs: u32 = 0xC7BCB0; // 4 floats: a, b, c, d for dot product
const g_renderFlags: *const u8 = @ptrFromInt(0x867960 + 8); // actually at different offset
const g_deltaTime: *const u32 = @ptrFromInt(0xC62510); // PTR_00c62510
const g_timerThreshold: *const f32 = @ptrFromInt(0x80A1E8); // _DAT_0080a1e8

// =========================================================================
// UpdateEntityAndChunksPositions (0x6AFAD0)
// __fastcall(ECX=entityPtr), RET
// =========================================================================
export fn updateEntityAndChunksPositions(ent: u32) callconv(.{ .x86_fastcall = .{} }) void {
    // Dot product: depth = a*x + b*y + c*z + d - offset
    const depth = readF32(g_viewCoeffs) * readF32(ent + 0x5C) +
        readF32(g_viewCoeffs + 4) * readF32(ent + 0x60) +
        readF32(g_viewCoeffs + 8) * readF32(ent + 0x64) +
        readF32(g_viewCoeffs + 12) - readF32(ent + 0x68);
    writeF32(ent + 0x78, depth);

    // Render distance flag
    writeU32(ent + 0xB8, readU32(0x867964));
    if ((@as(*const u8, @ptrFromInt(0xC7B2A4)).* & 4) != 0 and readF32(0x867960) < depth) {
        writeU32(ent + 0xB8, readU32(0x867968));
    }

    // Timer accumulation
    const dt_bits = g_deltaTime.*;
    const dt: f32 = @bitCast(dt_bits);
    const timer = readF32(ent + 0xAC) + dt;
    writeF32(ent + 0xAC, timer);
    const threshold = g_timerThreshold.*;

    // Vertex buffer recycling
    if (threshold < timer and readU32(ent + 0x14C) != 0) {
        @call(.never_tail, recycleVertexBuffer, .{ ent + 0x14C, ent + 0x150 });
    }

    // Instance buffer management
    const inst_mgr = readU32(ent + 0xC0);
    if (inst_mgr != 0) {
        if (1.0 < readF32(ent + 0xAC)) {
            const active = @call(.never_tail, check_instances_active, .{inst_mgr});
            if (active != 0) {
                @call(.never_tail, store_all_instance_buffers, .{inst_mgr});
            }
        }
        if (threshold < readF32(ent + 0xAC)) {
            @call(.never_tail, return_object_to_pool, .{inst_mgr});
            writeU32(ent + 0xC0, 0);
        }
    }

    // Chunk timer loop (4 chunks at ent+0x118, stride 4)
    inline for (0..4) |ci| {
        const chunk = readU32(ent + 0x118 + ci * 4);
        if (chunk != 0) {
            const chunk_timer = readF32(chunk + 0x30) + dt;
            writeF32(chunk + 0x30, chunk_timer);
            if (readU32(chunk + 0x400) != 0 and threshold < chunk_timer) {
                @call(.never_tail, ReturnChunkBuffers, .{ chunk + 0x400, chunk + 0x404 });
            }
        }
    }

    // Bounds check and spatial grid registration
    const bx = readF32(ent + 0x44);
    const by = readF32(ent + 0x48);
    const bz = readF32(ent + 0x4C);
    if (bx <= readF32(0xC7CB68) and by <= readF32(0xC7CB6C) and bz <= readF32(0xC7CB70)) {
        const inside = @call(.never_tail, IsPointInsideBounds, .{ ent + 0x50, 0xC7CB5C });
        if (inside != 0) {
            // Compute position from animation data
            const anim_idx = readU32(0x86B580 + readU32(0xC7F294) * 4);
            const anim_base = ent + 0x83C + @as(u32, @bitCast(anim_idx)) * 0xC;
            var pos: [3]f32 = undefined;
            pos[0] = readF32(anim_base) + readF32(ent + 0x6C);
            pos[1] = readF32(anim_base + 4) + readF32(ent + 0x70);
            pos[2] = readF32(anim_base + 8) + readF32(ent + 0x74);

            @call(.never_tail, AddObjectToSpatialList, .{ ent, @intFromPtr(&pos) });

            // Walk sub-object linked list
            var node = readU32(ent + 0xE4);
            if ((node & 1) != 0 or node == 0) node = 0;
            while ((node & 1) == 0 and node != 0) {
                const obj = readU32(node + 4);
                if ((@as(*const u8, @ptrFromInt(obj + 0xC)).* & 0x80) != 0 and (readU32(obj + 0x88) != 0 or readU32(obj + 0x174) != 0)) {
                    @call(.never_tail, AddToSpatialGrid, .{obj});
                }
                node = readU32(readU32(ent + 0xDC) + node + 4);
            }
        }
    }

    // Chunk bounds + spatial grid loop (4 chunks)
    inline for (0..4) |ci| {
        const chunk = readU32(ent + 0x118 + ci * 4);
        if (chunk != 0) {
            var bounds: [6]f32 = undefined;
            @call(.never_tail, CopyChunkBounds, .{ chunk, @intFromPtr(&bounds) });

            // Check if chunk bounds intersect the world region
            if (bounds[0] <= readF32(0xC7CB68) and bounds[1] <= readF32(0xC7CB6C) and
                bounds[2] <= readF32(0xC7CB70) and readF32(0xC7CB5C) <= bounds[3] and
                readF32(0xC7CB60) <= bounds[4] and readF32(0xC7CB64) <= bounds[5])
            {
                var center: [3]f32 = undefined;
                center[0] = (bounds[3] + bounds[0]) * 0.5;
                center[1] = (bounds[4] + bounds[1]) * 0.5;
                center[2] = (bounds[5] + bounds[2]) * 0.5;
                @call(.never_tail, AddToLayeredSpatialGrid, .{ chunk, @as(u32, ci), @intFromPtr(&center) });
            }
        }
    }
}

// =========================================================================
// updateEntitiesInBounds (0x6C1F70)
// __thiscall(ECX=this, stack=param_1), RET 0x4
// =========================================================================
export fn updateEntitiesInBoundsSSE(this: u32, param_1: u32) callconv(.{ .x86_thiscall = .{} }) void {
    var node = readU32(this + 0x274);
    if ((node & 1) != 0 or node == 0) node = 0;

    while ((node & 1) == 0 and node != 0) {
        const entity = readU32(node + 4);
        const next = readU32(readU32(this + 0x26C) + 4 + node);

        // Prefetch next node's entity data while we process this one
        if ((next & 1) == 0 and next != 0) {
            const next_entity = readU32(next + 4);
            @prefetch(@as([*]const u8, @ptrFromInt(next_entity + 0x44)), .{ .locality = 1 });
            @prefetch(@as([*]const u8, @ptrFromInt(next_entity + 0x8C)), .{ .locality = 1 });
        }

        // Bounds check: entity chunk coords vs global region
        const cx = readI32(entity + 0x8C);
        const cy = readI32(entity + 0x90);

        if (cx < readI32(0xC63278) or readI32(0xC63280) < cx or
            cy < readI32(0xC63274) or readI32(0xC6327C) < cy)
        {
            // Out of bounds: destroy
            const slot_idx = readU32(entity + 0xB4); // entityPtr[0x2d] = +0xB4
            writeU32(this + slot_idx * 4 + 0x278, 0);
            @call(.never_tail, ComplexMemoryCleanupAndRelease, .{node});
            @call(.never_tail, destroySecondaryGameObject, .{entity});
        } else {
            if (param_1 != 0) {
                // Call through game address so the Detour hook fires (enables A/B timing)
                const entPosHooked = @as(*const fn (u32) callconv(.{ .x86_fastcall = .{} }) void, @ptrFromInt(0x6AFAD0));
                @call(.never_tail, entPosHooked, .{entity});
            }
        }
        node = next;
    }
}
