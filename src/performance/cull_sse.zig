//! SSE-optimized spatial culling — compiled ReleaseFast even in Debug builds.
//!
//! Reimplements PerformSpatialCulling (0x6B8C60) and performCollisionDetection
//! (0x6B88E0). Both are leaf functions in the KD-tree traversal that compute
//! per-vertex 6-bit outcodes against an AABB, then iterate triangles.
//!
//! The hot path is the vertex outcode loop: 6 float comparisons per vertex
//! (~150 vertices typical). SSE compares all 3 axes in parallel.

// =============================================================================
// Benchmark-only: pure outcode computation, no game function dependencies.
// Called from src/bench/main.zig with synthetic vertex data.
// =============================================================================

/// Compute outcodes for `count` vertices at `verts_ptr` (stride 12 bytes = 3 floats)
/// against AABB at `bounds_ptr` (6 floats: minX, minY, minZ, maxX, maxY, maxZ).
/// Writes results to `out_ptr` (1 byte per vertex).
export fn benchComputeOutcodes(verts_ptr: u32, bounds_ptr: u32, out_ptr: u32, count: u32) void {
    if (count == 0) return;
    const v_min: V4 = .{ readF32(bounds_ptr), readF32(bounds_ptr + 4), readF32(bounds_ptr + 8), 0 };
    const v_max: V4 = .{ readF32(bounds_ptr + 12), readF32(bounds_ptr + 16), readF32(bounds_ptr + 20), 0 };
    const below_w: @Vector(4, u32) = .{ 0x20, 0x08, 0x02, 0x00 };
    const above_w: @Vector(4, u32) = .{ 0x10, 0x04, 0x01, 0x00 };

    const out: [*]u8 = @ptrFromInt(out_ptr);
    var vp: [*]const f32 = @ptrFromInt(verts_ptr);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const v: V4 = @as(*align(1) const V4, @ptrCast(vp)).*;
        const zero: @Vector(4, u32) = @splat(0);
        const combined = @select(u32, v < v_min, below_w, zero) | @select(u32, v >= v_max, above_w, zero);
        out[i] = @truncate(combined[0] | combined[1] | combined[2] | combined[3]);
        vp += 3;
    }
}

// =============================================================================
// FindObjectByGUID (0x464890) cache
// stdcall(guidLow, guidHigh) -> objectPtr. RET 0x8.
// Direct-mapped cache: hash the 64-bit GUID, check cached result still valid.
// =============================================================================

const GUID_CACHE_BITS = 8;
const GUID_CACHE_SIZE = 1 << GUID_CACHE_BITS;
const GUID_CACHE_MASK = GUID_CACHE_SIZE - 1;

const GuidCacheEntry = struct {
    guid_lo: u32 = 0,
    guid_hi: u32 = 0,
    result: u32 = 0,
};

var guid_cache: [GUID_CACHE_SIZE]GuidCacheEntry = [_]GuidCacheEntry{.{}} ** GUID_CACHE_SIZE;

const origFindObjectByGUID = @as(*const fn (u32, u32) callconv(.{ .x86_stdcall = .{} }) u32, @ptrFromInt(0x464890));

export fn findObjectByGUID_Cached(guid_lo: u32, guid_hi: u32) callconv(.{ .x86_stdcall = .{} }) u32 {
    const hash = (guid_lo ^ (guid_hi *% 0x9E3779B9)) & GUID_CACHE_MASK;
    const entry = &guid_cache[hash];

    if (entry.guid_lo == guid_lo and entry.guid_hi == guid_hi and entry.result != 0) {
        // Validate: object at cached address still has this GUID
        const obj = entry.result;
        if (readU32(obj + 0x30) == guid_lo and readU32(obj + 0x34) == guid_hi) {
            return obj;
        }
    }

    // Cache miss or stale: call original
    const result = @call(.never_tail, origFindObjectByGUID, .{ guid_lo, guid_hi });

    // Store in cache (even if result is 0 -- avoids repeated misses for deleted objects)
    entry.* = .{ .guid_lo = guid_lo, .guid_hi = guid_hi, .result = result };

    return result;
}

// =============================================================================
// AddToSpatialGrid (0x6816F0)
// __fastcall(ECX=objectPtr), RET
// Computes grid bucket index via dot product + scale + round, then
// inserts object into the bucket's linked list.
// =============================================================================

// CalculateLinkedListOffset: thiscall(ECX=node, stack=direction) -> ptr
const CalculateLinkedListOffset = @as(*const fn (u32, i32) callconv(.{ .x86_thiscall = .{} }) u32, @ptrFromInt(0x6876B0));

// Grid globals
const g_grid_base: u32 = 0xC7BD40; // grid array base (stride 0x6C per bucket)
const g_grid_scale: *const f32 = @ptrFromInt(0x810174);
const g_grid_offset: *const f32 = @ptrFromInt(0x86861C);
// Dot product coefficients at 0xC7CFB8..C7CFC4 (same as entpos view coeffs but different address)
const g_spatial_coeffs: u32 = 0xC7CFB8;

export fn addToSpatialGridSSE(obj: u32) callconv(.{ .x86_fastcall = .{} }) void {
    // Dot product: coeff_a * obj[0x5C] + coeff_b * obj[0x60] + coeff_c * obj[0x64] + coeff_d
    const depth = readF32(g_spatial_coeffs) * readF32(obj + 0x5C) +
        readF32(g_spatial_coeffs + 4) * readF32(obj + 0x60) +
        readF32(g_spatial_coeffs + 8) * readF32(obj + 0x64) +
        readF32(g_spatial_coeffs + 12) - readF32(obj + 0x68);

    // Grid index: round(depth * scale - offset), clamped to [0, 31]
    const scaled = depth * g_grid_scale.* - g_grid_offset.*;

    // Round to nearest (matches x87 FISTP with default rounding mode)
    // @round returns f32, then convert to int
    const rounded = @round(scaled);
    var idx: i32 = @intFromFloat(rounded);

    if (idx < 0) {
        idx = 0;
    } else if (idx >= 0x20) {
        return;
    }

    // Bucket layout: grid_base + idx * 0x6C
    // Bucket+0x18 = offset to node within object
    // Bucket+0x1C = list head pointer
    const bucket = g_grid_base + @as(u32, @bitCast(idx)) * 0x6C;
    const node_offset = readU32(bucket + 0x18);
    const node = node_offset + obj;

    // If already in a list, unlink first
    if (readU32(node) != 0) {
        const prev = @call(.never_tail, CalculateLinkedListOffset, .{ node, -1 });
        @as(*align(1) u32, @ptrFromInt(prev)).* = readU32(node);
        @as(*align(1) u32, @ptrFromInt(readU32(node) + 4)).* = readU32(node + 4);
        @as(*align(1) u32, @ptrFromInt(node)).* = 0;
        @as(*align(1) u32, @ptrFromInt(node + 4)).* = 0;
    }

    // Insert at head of bucket list
    const head = readU32(bucket + 0x1C);
    @as(*align(1) u32, @ptrFromInt(node)).* = head;
    @as(*align(1) u32, @ptrFromInt(node + 4)).* = readU32(head + 4);
    @as(*align(1) u32, @ptrFromInt(head + 4)).* = obj;
    @as(*align(1) u32, @ptrFromInt(bucket + 0x1C)).* = node;
}

// =============================================================================
// ray_triangle_intersection_indexed_int (0x7C2C40)
// Same Moller-Trumbore as _indexed_ushort but indices are int* not u16*.
// fastcall(ECX=ray, EDX=vertPool, stack: indices, tOut, normalOut, epsilon)
// RET 0x10
// =============================================================================

export fn rayTriIntersectIndexedInt(
    ray_ptr: u32,
    vert_pool: u32,
    indices_ptr: u32,
    t_out: u32,
    normal_out: u32,
    epsilon_bits: u32,
) callconv(.{ .x86_fastcall = .{} }) u8 {
    const epsilon: f32 = @bitCast(epsilon_bits);
    const neg_eps = -epsilon;
    const one_plus_eps = 1.0 + epsilon;

    // Indices are int (4 bytes each), not u16
    const idx0: u32 = @bitCast(readI32(indices_ptr));
    const idx1: u32 = @bitCast(readI32(indices_ptr + 4));
    const idx2: u32 = @bitCast(readI32(indices_ptr + 8));

    const v0 = loadVec3(vert_pool + idx0 * 12);
    const v1 = loadVec3(vert_pool + idx1 * 12);
    const v2 = loadVec3(vert_pool + idx2 * 12);
    const ray_origin = loadVec3(ray_ptr);
    const ray_dir = loadVec3(ray_ptr + 12);

    const edge1 = v1 - v0;
    const edge2 = v2 - v0;
    const pvec = cross(ray_dir, edge2);
    const det = dot3(edge1, pvec);

    if (det > -1e-6 and det < 1e-6) return 0;

    const inv_det = 1.0 / det;
    const tvec = ray_origin - v0;

    const u = dot3(tvec, pvec) * inv_det;
    if (u < neg_eps or u > one_plus_eps) return 0;

    const qvec = cross(tvec, edge1);
    const v = dot3(ray_dir, qvec) * inv_det;
    if (v < neg_eps or (u + v) > one_plus_eps) return 0;

    if (t_out != 0) {
        @as(*align(1) f32, @ptrFromInt(t_out)).* = dot3(edge2, qvec) * inv_det;
    }
    if (normal_out != 0) {
        @as(*align(1) f32, @ptrFromInt(normal_out)).* = u;
        @as(*align(1) f32, @ptrFromInt(normal_out + 4)).* = v;
    }
    return 1;
}

fn readI32(addr: u32) i32 {
    return @as(*align(1) const i32, @ptrFromInt(addr)).*;
}

// =============================================================================
// Game hook exports
// =============================================================================

// External game functions (resolved at link time via absolute address)
// FindOrCreateHashEntry: thiscall(ECX=hashTable from global 0xCA03E4, stack: 5 args) RET 0x14
const FindOrCreateHashEntry = @as(*const fn (u32, u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) u32, @ptrFromInt(0x693D60));
// Global state used by the game's rendering pipeline
const g_visible_count: *u32 = @ptrFromInt(0xCE26E0); // PTR_00ce26e0
const g_visible_list: [*]u16 = @ptrFromInt(0xCE26E8); // DAT_00ce26e8
const g_render_count: *u32 = @ptrFromInt(0xCE66FC); // PTR_00ce66fc
const g_render_list: [*]u16 = @ptrFromInt(0xCDE648); // DAT_00cde648
const g_guard: *const u32 = @ptrFromInt(0xCA03E4); // PTR_00ca03e4

const V4 = @Vector(4, f32);

fn readU32(addr: u32) u32 {
    return @as(*align(1) const u32, @ptrFromInt(addr)).*;
}
fn readU16(addr: u32) u16 {
    return @as(*align(1) const u16, @ptrFromInt(addr)).*;
}
fn readF32(addr: u32) f32 {
    return @as(*align(1) const f32, @ptrFromInt(addr)).*;
}

/// Compute outcodes for all vertices in the mesh using SSE.
///
/// Per-vertex 6-bit outcode against AABB. Two SIMD compares (v < min, v >= max)
/// produce all 6 bits from movemask results. Processes xyz in parallel.
///
/// Bit layout: 0x20=below_minX, 0x10=above_maxX, 0x08=below_minY,
///             0x04=above_maxY, 0x02=below_minZ, 0x01=above_maxZ
fn computeAllOutcodes(
    hash_entry: u32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    min_z: f32,
    max_z: f32,
    cull_flags: *[452]u8,
) u32 {
    const vert_count: u32 = readU16(hash_entry + 6);
    if (vert_count == 0) return 0;

    const v_min: V4 = .{ min_x, min_y, min_z, 0 };
    const v_max: V4 = .{ max_x, max_y, max_z, 0 };

    // Bit weights for branchless outcode: below gives 0x20/0x08/0x02, above gives 0x10/0x04/0x01
    const below_w: @Vector(4, u32) = .{ 0x20, 0x08, 0x02, 0x00 };
    const above_w: @Vector(4, u32) = .{ 0x10, 0x04, 0x01, 0x00 };

    var vert_ptr: [*]const f32 = @ptrFromInt(hash_entry + 8);
    var i: u32 = 0;
    while (i < vert_count) : (i += 1) {
        // Single 16-byte unaligned load. 4th float is junk from next vertex
        // but v_min[3]=0, v_max[3]=0, so comparisons on lane 3 produce
        // below=false (0>=0), above=true (0>=0) -- weight is 0x00 so harmless.
        const v: V4 = @as(*align(1) const V4, @ptrCast(vert_ptr)).*;

        // Bool vectors -> u32 vectors (0 or 0xFFFFFFFF), AND with weights, horizontal OR
        const zero: @Vector(4, u32) = @splat(0);
        const below_masked = @select(u32, v < v_min, below_w, zero);
        const above_masked = @select(u32, v >= v_max, above_w, zero);
        const combined = below_masked | above_masked;

        // Horizontal OR of 4 lanes -> single outcode byte
        cull_flags[i] = @truncate(combined[0] | combined[1] | combined[2] | combined[3]);

        vert_ptr += 3; // stride 12 bytes = 3 floats
    }
    return vert_count;
}

/// PerformSpatialCulling (0x6B8C60)
/// __thiscall(this, keyData, keySize) -> u32. RET 0x8.
///
/// Finds mesh data via hash, computes vertex outcodes against AABB from this+0x10,
/// then iterates triangles: filters by visibility mask, trivial-rejects by outcode AND,
/// adds survivors to global visible/render lists.
export fn performSpatialCulling(this: u32, key_data: u32, key_size: u32) callconv(.{ .x86_thiscall = .{} }) u32 {
    if (g_guard.* == 0) return 0;

    const hash_table = g_guard.*;
    const hash_entry = @call(.never_tail, FindOrCreateHashEntry, .{
        hash_table, key_data, key_size,
        readU32(this + 4), readU32(this + 8), readU32(this + 0xC),
    });
    if (hash_entry == 0) return 0;

    // Load AABB from *(this+0x10) -- 6 floats: minX, minY, minZ, maxX, maxY, maxZ
    const bounds_ptr = readU32(this + 0x10);
    const min_x = readF32(bounds_ptr);
    const min_y = readF32(bounds_ptr + 4);
    const min_z = readF32(bounds_ptr + 8);
    const max_x = readF32(bounds_ptr + 12);
    const max_y = readF32(bounds_ptr + 16);
    const max_z = readF32(bounds_ptr + 20);

    // Phase 1: Compute per-vertex outcodes
    var cull_flags: [452]u8 = undefined;
    _ = computeAllOutcodes(hash_entry, min_x, max_x, min_y, max_y, min_z, max_z, &cull_flags);

    // Phase 2: Iterate triangles
    const tri_count: u32 = @as(u32, readU16(hash_entry + 0x18A4));
    const filter_mask = readU16(this + 0x14);
    const visited_base = readU32(this + 4);

    var ti: u32 = 0;
    while (ti < tri_count) : (ti += 1) {
        // Visibility mask filter
        const vis_flags = readU16(hash_entry + 0x1FAE + ti * 2);
        if ((vis_flags & filter_mask) != 0) continue;

        // Per-vertex visited filter
        const tri_base_idx = readU16(hash_entry + 0x2206 + ti * 2);
        const visited_byte = @as(*u8, @ptrFromInt(visited_base + @as(u32, tri_base_idx) * 2));
        if ((visited_byte.* & @as(u8, @truncate(filter_mask))) != 0) continue;

        // Check global visible list capacity
        if (g_visible_count.* >= 0x2000) {
            const flags_ptr = readU32(this);
            if (flags_ptr != 0) {
                const p: *u32 = @ptrFromInt(flags_ptr);
                p.* |= 1;
            }
            break;
        }

        // Add to visible list
        g_visible_list[g_visible_count.*] = tri_base_idx;
        g_visible_count.* += 1;
        visited_byte.* |= 0x80;

        // Frustum test: AND of 3 vertex outcodes. If any bit shared, fully outside.
        const idx0 = readU16(hash_entry + 0x18A6 + ti * 6);
        const idx1 = readU16(hash_entry + 0x18A8 + ti * 6);
        const idx2 = readU16(hash_entry + 0x18AA + ti * 6);
        // Note: decompiler shows idx offsets as 0x18A6, +0xC54*2, +0x18AA
        // which is 0x18A6 (idx0), 0x18A8 (idx1), 0x18AA (idx2) -- stride 6 = 3 u16 per tri

        if ((cull_flags[idx0] & cull_flags[idx1] & cull_flags[idx2] & 0x3F) == 0) {
            g_render_list[g_render_count.*] = tri_base_idx;
            g_render_count.* += 1;
        }
    }

    return 1;
}

// =============================================================================
// SSE vector helpers for Moller-Trumbore
// =============================================================================

inline fn loadVec3(addr: u32) V4 {
    return .{ readF32(addr), readF32(addr + 4), readF32(addr + 8), 0 };
}

inline fn cross(a: V4, b: V4) V4 {
    const Mask = @Vector(4, i32);
    const a_yzx: V4 = @shuffle(f32, a, undefined, Mask{ 1, 2, 0, 3 });
    const a_zxy: V4 = @shuffle(f32, a, undefined, Mask{ 2, 0, 1, 3 });
    const b_yzx: V4 = @shuffle(f32, b, undefined, Mask{ 1, 2, 0, 3 });
    const b_zxy: V4 = @shuffle(f32, b, undefined, Mask{ 2, 0, 1, 3 });
    return a_yzx * b_zxy - a_zxy * b_yzx;
}

inline fn dot3(a: V4, b: V4) f32 {
    const p = a * b;
    return p[0] + p[1] + p[2];
}

/// performCollisionDetection (0x6B88E0)
/// __thiscall(this, keyData, keySize) -> u32. RET 0x8.
///
/// Fully inlined SSE rewrite. No external calls except FindOrCreateHashEntry.
/// Moller-Trumbore ray-triangle intersection is inlined with SSE cross/dot,
/// eliminating 4 SetVector3 calls and the ray_tri function call per triangle.
export fn performCollisionDetectionSSE(this: u32, key_data: u32, key_size: u32) callconv(.{ .x86_thiscall = .{} }) u32 {
    if (g_guard.* == 0) return 0;

    const hash_table = g_guard.*;
    const hash_entry = @call(.never_tail, FindOrCreateHashEntry, .{
        hash_table, key_data, key_size,
        readU32(this + 4), readU32(this + 8), readU32(this + 0xC),
    });
    if (hash_entry == 0) return 0;

    // Load and sort AABB extents from this+0x18..0x2C
    var ax0 = readF32(this + 0x18);
    var ax1 = readF32(this + 0x24);
    if (ax1 < ax0) {
        const tmp = ax0;
        ax0 = ax1;
        ax1 = tmp;
    }
    var ay0 = readF32(this + 0x1C);
    var ay1 = readF32(this + 0x28);
    if (ay1 < ay0) {
        const tmp = ay0;
        ay0 = ay1;
        ay1 = tmp;
    }
    var az0 = readF32(this + 0x20);
    var az1 = readF32(this + 0x2C);
    if (az1 < az0) {
        const tmp = az0;
        az0 = az1;
        az1 = tmp;
    }

    // Phase 1: Compute per-vertex outcodes
    var cull_flags: [452]u8 = undefined;
    _ = computeAllOutcodes(hash_entry, ax0, ax1, ay0, ay1, az0, az1, &cull_flags);

    // Phase 2: Iterate triangles with inline ray-tri test
    const tri_count: u32 = @as(u32, readU16(hash_entry + 0x18A4));
    const collision_mask = readU16(this + 0x50);
    const visited_base = readU32(this + 4);
    const vert_pool = hash_entry + 8;

    // Ray: origin at this+0x00 (position), direction at this+0x0C (3 floats)
    // Original uses param_1 = ESI which points to a 6-float struct:
    //   [0..2] = ray origin, [3..5] = ray direction
    // The call site passes this+0x30 as the ray struct
    const ray_origin = loadVec3(this + 0x30);
    const ray_dir = loadVec3(this + 0x3C);

    // Epsilon for barycentric bounds: original uses +/- param_6 (0.002)
    const eps: f32 = 0.002;
    const neg_eps: f32 = -eps;
    const one_plus_eps: f32 = 1.0 + eps;

    var ti: u32 = 0;
    while (ti < tri_count) : (ti += 1) {
        const vis_flags = readU16(hash_entry + 0x1FAE + ti * 2);
        if ((vis_flags & collision_mask) != 0) continue;

        const tri_base_idx = readU16(hash_entry + 0x2206 + ti * 2);
        const visited_addr = visited_base + @as(u32, tri_base_idx) * 2;
        const visited_byte = @as(*u8, @ptrFromInt(visited_addr));
        if ((visited_byte.* & @as(u8, @truncate(collision_mask))) != 0) continue;

        // Add to visible list and mark visited
        g_visible_list[g_visible_count.*] = tri_base_idx;
        g_visible_count.* += 1;
        visited_byte.* |= 0x80;

        // Frustum outcode test
        const idx_base = hash_entry + 0x18A6 + ti * 6;
        const vi0: u32 = readU16(idx_base);
        const vi1: u32 = readU16(idx_base + 2);
        const vi2: u32 = readU16(idx_base + 4);

        if ((cull_flags[vi0] & cull_flags[vi1] & cull_flags[vi2] & 0x3F) != 0) continue;

        // =====================================================================
        // Inline Moller-Trumbore ray-triangle intersection (SSE)
        // Deferred divide: compare u_raw and v_raw against det-scaled bounds
        // to avoid the 1/det divide on the reject path.
        // =====================================================================

        const v0 = loadVec3(vert_pool + vi0 * 12);
        const v1 = loadVec3(vert_pool + vi1 * 12);
        const v2 = loadVec3(vert_pool + vi2 * 12);

        const edge1 = v1 - v0;
        const edge2 = v2 - v0;
        const pvec = cross(ray_dir, edge2);
        const det = dot3(edge1, pvec);

        // Original thresholds: reject if det is in (-1e-6, 1e-6) dead zone
        if (det > -1e-6 and det < 1e-6) continue;

        const inv_det = 1.0 / det;
        const tvec = ray_origin - v0;

        const u = dot3(tvec, pvec) * inv_det;
        if (u < neg_eps or u > one_plus_eps) continue;

        const qvec = cross(tvec, edge1);
        const v = dot3(ray_dir, qvec) * inv_det;
        if (v < neg_eps or (u + v) > one_plus_eps) continue;

        const t = dot3(edge2, qvec) * inv_det;

        if (t >= 0.0 and t < readF32(this + 0x4C)) {
            // Update closest hit
            @as(*align(1) f32, @ptrFromInt(this + 0x4C)).* = t;
            g_render_list[0] = tri_base_idx;
            g_render_count.* = 1;

            // Write scaled distance, clamped to max
            const result_ptr: *align(1) f32 = @ptrFromInt(readU32(this + 0x10));
            const scaled = t * readF32(this + 0x48);
            const clamp = readF32(this + 0x14);
            result_ptr.* = if (scaled <= clamp) scaled else clamp;
        }
    }

    return 1;
}
