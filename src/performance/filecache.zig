//! filecache -- MPQ archive pointer cache for File_FindInArchive (0x6549a0)
//!
//! 2-way set-associative cache: hash(filename) picks a set of 2 entries.
//! Filename stored and compared for collision safety. On eviction, the
//! least recently used way is replaced.
//!
//! Lifecycle managed by the performance module (no own hooks or mutex).

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");

pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

// FNV-1a 32-bit, raw bytes (no normalization). Different casings get different slots.
// Finalizer mixes high bits into low bits for better slot distribution.
pub fn hashPath(path: [*:0]const u8) u32 {
    var h: u32 = 0x811c9dc5;
    var i: usize = 0;
    while (path[i] != 0) : (i += 1) {
        h ^= path[i];
        h *%= 0x01000193;
    }
    h ^= h >> 16;
    return h;
}

// Longest filename across all MPQ archives is 122 chars. 128 covers all.
const CACHE_NAME_LEN = 128;
const NUM_SETS = 32768; // power of 2
const WAYS = 2; // 2-way set-associative

pub const ArchiveCacheEntry = struct {
    outer_archive: u32 = 0,
    inner_archive: u32 = 0,
    block_index: u32 = 0, // index into archive's block table, not raw pointer
    is_negative: bool = false,
    name: [CACHE_NAME_LEN]u8 = .{0} ** CACHE_NAME_LEN,
    name_len: u8 = 0,
};

const CacheSet = struct {
    entries: [WAYS]ArchiveCacheEntry = .{ArchiveCacheEntry{}} ** WAYS,
    lru: u8 = 0,
};

var cache: [NUM_SETS]CacheSet = @splat(CacheSet{});
var cache_entries: u32 = 0;
var cache_hits: u64 = 0;
var cache_negative_hits: u64 = 0;
var cache_misses: u64 = 0;
var cache_stale: u64 = 0;
var hit_cycles: u64 = 0;
var miss_cycles: u64 = 0;
var cache_miss_p1: u64 = 0;
var cache_miss_p2: u64 = 0;
var cache_miss_p2_archive: u64 = 0;

/// Lookup: hash picks set, check both ways for name match.
pub fn archiveCacheLookup(h: u32, path: [*:0]const u8) ?ArchiveCacheEntry {
    const set_idx = h & (NUM_SETS - 1);
    const set = &cache[set_idx];
    const span = std.mem.span(path);

    for (0..WAYS) |w| {
        const entry = &set.entries[w];
        if (entry.name_len == 0) continue;
        if (span.len != entry.name_len) continue;
        const len: usize = entry.name_len;
        if (std.mem.eql(u8, entry.name[0..len], span[0..len])) {
            set.lru = @intCast(w ^ 1);
            return entry.*;
        }
    }
    return null;
}

/// Recompute block_entry pointer from archive's current block table + cached index.
/// block_entry = archive->block_table_data + index * 0x2C
pub fn computeBlockEntry(archive: u32, index: u32) u32 {
    if (archive == 0) return 0;
    const block_table_base = hook.readMem(u32, archive + 0x290);
    if (block_table_base == 0) return 0;
    return block_table_base + index * 0x2C;
}

pub fn archiveCacheInsert(h: u32, path: [*:0]const u8, outer: u32, inner: u32, block: u32, negative: bool) void {
    const span = std.mem.span(path);
    if (span.len > CACHE_NAME_LEN) return;

    const set_idx = h & (NUM_SETS - 1);
    const set = &cache[set_idx];

    var target: u8 = set.lru;
    for (0..WAYS) |w| {
        if (set.entries[w].name_len == 0) {
            target = @intCast(w);
            cache_entries += 1;
            break;
        }
    }

    const entry = &set.entries[target];
    entry.outer_archive = outer;
    entry.inner_archive = inner;
    if (block != 0 and inner != 0) {
        const base = hook.readMem(u32, inner + 0x290);
        entry.block_index = if (base != 0) (block - base) / 0x2C else 0;
    } else {
        entry.block_index = 0;
    }
    entry.is_negative = negative;
    const len: u8 = @intCast(span.len);
    @memcpy(entry.name[0..len], span[0..len]);
    entry.name_len = len;
    set.lru = target ^ 1;
}

pub fn recordCacheHit() void { cache_hits +|= 1; }
pub fn addHitCycles(c: u64) void { hit_cycles +|= c; }
pub fn addMissCycles(c: u64) void { miss_cycles +|= c; }
pub fn recordNegativeHit() void { cache_negative_hits +|= 1; }
pub fn recordCacheMiss() void { cache_misses +|= 1; }
pub fn recordCacheStale() void { cache_stale +|= 1; }
pub fn recordMissP1() void { cache_miss_p1 +|= 1; }
pub fn recordMissP2() void { cache_miss_p2 +|= 1; }
pub fn recordMissP2Archive() void { cache_miss_p2_archive +|= 1; }

pub fn getSlotOccupant(h: u32) ?[]const u8 {
    const set_idx = h & (NUM_SETS - 1);
    const set = &cache[set_idx];
    for (0..WAYS) |w| {
        if (set.entries[w].name_len != 0)
            return set.entries[w].name[0..set.entries[w].name_len];
    }
    return null;
}

// =============================================================================
// File_FindInArchive hook (0x6549a0)
// =============================================================================

const FileFindFn = fn (u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;
var file_find_hook: hook.Detour(FileFindFn) = .{};

fn fileFindDetour(
    archive_or_group: u32,
    filename_ptr: u32,
    flags: u32,
    out_inner_archive: u32,
    out_outer_archive: u32,
    out_block_entry: u32,
    out_disk_path: u32,
) callconv(hook.cc.fastcall) u32 {
    if (filename_ptr == 0)
        return file_find_hook.callOriginal(.{ archive_or_group, filename_ptr, flags, out_inner_archive, out_outer_archive, out_block_entry, out_disk_path });

    const tsc_start = rdtsc();
    const path: [*:0]const u8 = @ptrFromInt(filename_ptr);
    const h = hashPath(path);

    cache_check: {
        const cached = archiveCacheLookup(h, path) orelse break :cache_check;

        if (cached.is_negative and archive_or_group == 0) {
            recordNegativeHit();
            if (out_outer_archive != 0) @as(*align(1) u32, @ptrFromInt(out_outer_archive)).* = 0;
            if (out_inner_archive != 0) @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = 0;
            if (out_block_entry != 0) @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = 0;
            hook.call(fn (u32) callconv(hook.cc.stdcall) void, 0x64e850, .{2});
            addHitCycles(rdtsc() - tsc_start);
            return 0;
        }

        if (!cached.is_negative) {
            if (archive_or_group == 0 and out_outer_archive != 0) {
                const valid_outer = if (cached.outer_archive != 0)
                    hook.call(fn (u32, u32) callconv(hook.cc.fastcall) u32, 0x650780, .{ cached.outer_archive, 0 })
                else
                    0;
                if (valid_outer == 0 and cached.outer_archive != 0) break :cache_check;
                @as(*align(1) u32, @ptrFromInt(out_outer_archive)).* = valid_outer;
                if (out_inner_archive != 0 and cached.inner_archive != 0) {
                    const valid_inner = hook.call(fn (u32, u32) callconv(hook.cc.fastcall) u32, 0x650780, .{ cached.inner_archive, 0 });
                    @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = valid_inner;
                } else if (out_inner_archive != 0) {
                    @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = 0;
                }
                if (out_block_entry != 0) {
                    @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = computeBlockEntry(cached.inner_archive, cached.block_index);
                }
                recordCacheHit();
                addHitCycles(rdtsc() - tsc_start);
                return 1;
            }

            if (archive_or_group != 0 and (archive_or_group == cached.outer_archive or archive_or_group == cached.inner_archive)) {
                if (out_outer_archive != 0 and cached.outer_archive != 0) {
                    const valid = hook.call(fn (u32, u32) callconv(hook.cc.fastcall) u32, 0x650780, .{ cached.outer_archive, 0 });
                    if (valid == 0) break :cache_check;
                    @as(*align(1) u32, @ptrFromInt(out_outer_archive)).* = valid;
                } else if (out_outer_archive != 0) {
                    @as(*align(1) u32, @ptrFromInt(out_outer_archive)).* = 0;
                }
                if (out_inner_archive != 0 and cached.inner_archive != 0) {
                    const valid = hook.call(fn (u32, u32) callconv(hook.cc.fastcall) u32, 0x650780, .{ cached.inner_archive, 0 });
                    if (valid == 0) break :cache_check;
                    @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = valid;
                } else if (out_inner_archive != 0) {
                    @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = 0;
                }
                if (out_block_entry != 0) {
                    @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = computeBlockEntry(cached.inner_archive, cached.block_index);
                }
                recordCacheHit();
                addHitCycles(rdtsc() - tsc_start);
                return 1;
            }
        }
    }

    recordCacheMiss();
    const ret = file_find_hook.callOriginal(.{ archive_or_group, filename_ptr, flags, out_inner_archive, out_outer_archive, out_block_entry, out_disk_path });
    addMissCycles(rdtsc() - tsc_start);

    if (archive_or_group != 0 and out_inner_archive != 0 and out_block_entry != 0) {
        if (ret == 1) {
            const inner = hook.readMem(u32, out_inner_archive);
            const block = hook.readMem(u32, out_block_entry);
            archiveCacheInsert(h, path, archive_or_group, inner, block, false);
        }
    }
    if (archive_or_group == 0 and ret == 0) {
        archiveCacheInsert(h, path, 0, 0, 0, true);
    }

    return ret;
}

pub fn install() bool {
    return file_find_hook.attach(0x6549a0, &fileFindDetour) == .ok;
}

pub fn remove() void {
    file_find_hook.detach();
}

// =============================================================================
// Stats
// =============================================================================

fn pct(part: u64, total: u64) u64 {
    if (total == 0) return 0;
    return part *| 1000 / total;
}

fn resetStats() void {
    cache_hits = 0;
    cache_negative_hits = 0;
    cache_misses = 0;
    cache_stale = 0;
    cache_miss_p1 = 0;
    cache_miss_p2 = 0;
    cache_miss_p2_archive = 0;
    hit_cycles = 0;
    miss_cycles = 0;
}

pub fn dumpStats(lg: *logging.Logger) void {
    const total = cache_hits + cache_negative_hits + cache_misses + cache_stale;
    if (total == 0) return;
    const hit_pct = pct(cache_hits + cache_negative_hits, total);
    const total_hit_calls = cache_hits + cache_negative_hits;
    const avg_hit = if (total_hit_calls > 0) hit_cycles / total_hit_calls else 0;
    const avg_miss = if (cache_misses > 0) miss_cycles / cache_misses else 0;
    const saved_us = if (avg_miss > avg_hit) total_hit_calls * (avg_miss - avg_hit) / 3000 else 0;
    if (saved_us >= 2000) {
        lg.fmt("file_cache: {d}.{d}% hit ({d}hit/{d}neg/{d}miss) {d} entries | saved {d}ms\n", .{
            hit_pct / 10, hit_pct % 10,
            cache_hits, cache_negative_hits, cache_misses, cache_entries,
            saved_us / 1000,
        });
    } else {
        lg.fmt("file_cache: {d}.{d}% hit ({d}hit/{d}neg/{d}miss) {d} entries | saved {d}us\n", .{
            hit_pct / 10, hit_pct % 10,
            cache_hits, cache_negative_hits, cache_misses, cache_entries,
            saved_us,
        });
    }
    resetStats();
}
