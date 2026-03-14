//! filecache -- MPQ archive pointer cache for File_FindInArchive (0x6549a0)
//!
//! 2-way set-associative cache: hash(filename) picks a set of 2 entries.
//! Filename stored and compared for collision safety. On eviction, the
//! least recently used way is replaced.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "filecache";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log_state: logging.Logger = .{};

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

/// Insert: hash picks set, store in empty way or evict LRU.
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
    // Convert block_entry pointer to index: (ptr - base) / 0x2C
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

pub const CacheStats = struct {
    hits: u64, neg_hits: u64, misses: u64, stale: u64,
    miss_p1: u64, miss_p2: u64, miss_p2_archive: u64,
    entries: u32, total: u64,
};

pub fn getCacheStats() CacheStats {
    return .{
        .hits = cache_hits,
        .neg_hits = cache_negative_hits,
        .misses = cache_misses,
        .stale = cache_stale,
        .miss_p1 = cache_miss_p1,
        .miss_p2 = cache_miss_p2,
        .miss_p2_archive = cache_miss_p2_archive,
        .entries = cache_entries,
        .total = cache_hits + cache_negative_hits + cache_misses + cache_stale,
    };
}

pub fn resetStats() void {
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

fn pct(part: u64, total: u64) u64 {
    if (total == 0) return 0;
    return part *| 1000 / total;
}

pub fn dumpStats() void {
    const fc = getCacheStats();
    if (fc.total == 0) return;
    const hit_pct = pct(fc.hits + fc.neg_hits, fc.total);
    // @3GHz: cycles/3000 = us, cycles/3000000 = ms
    const total_hit_calls = fc.hits + fc.neg_hits;
    const avg_hit = if (total_hit_calls > 0) hit_cycles / total_hit_calls else 0;
    const avg_miss = if (fc.misses > 0) miss_cycles / fc.misses else 0;
    // Without cache, hits would have cost avg_miss each
    const saved_us = if (avg_miss > avg_hit) total_hit_calls * (avg_miss - avg_hit) / 3000 else 0;
    if (saved_us >= 2000) {
        log_state.fmt("  file_cache: {d}.{d}% hit ({d}hit/{d}neg/{d}miss) {d} entries | saved {d}ms (avg hit={d}cy miss={d}cy)\n", .{
            hit_pct / 10, hit_pct % 10,
            fc.hits, fc.neg_hits, fc.misses, fc.entries,
            saved_us / 1000, avg_hit, avg_miss,
        });
    } else {
        log_state.fmt("  file_cache: {d}.{d}% hit ({d}hit/{d}neg/{d}miss) {d} entries | saved {d}us (avg hit={d}cy miss={d}cy)\n", .{
            hit_pct / 10, hit_pct % 10,
            fc.hits, fc.neg_hits, fc.misses, fc.entries,
            saved_us, avg_hit, avg_miss,
        });
    }
    resetStats();
}

// Frame counting for periodic stats dump
const DUMP_FRAMES: u64 = 900; // ~15s at 60fps
var frame_count: u64 = 0;

const WorldUpdateFn = fn (u32) callconv(hook.cc.fastcall) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

fn worldUpdateDetour(fc: u32) callconv(hook.cc.fastcall) void {
    world_update_hook.callOriginal(.{fc});
    frame_count +|= 1;
    if (frame_count >= DUMP_FRAMES) {
        dumpStats();
        frame_count = 0;
    }
}

// Module lifecycle
pub fn isActive() bool { return g_is_hook_owner; }

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
    log_state = logging.Logger.open(module_name, .console);
    _ = world_update_hook.attach(0x482EA0, &worldUpdateDetour);
    log_state.print("filecache: active\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        world_update_hook.detach();
        dumpStats();
        log_state.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
