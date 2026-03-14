//! file_cache — MPQ archive pointer cache for File_FindInArchive (0x6549a0)
//!
//! Direct-mapped cache: hash(filename) → {outer_archive, inner_archive, block_entry}.
//! Populated on successful File_FindInStorage calls (where all three values are
//! available). Used to skip both the archive chain walk and per-archive hash lookup.
//!
//! MPQ archives are loaded at startup and never modified, so cached pointers
//! (archive structs, block table entries) remain valid for the entire session.
//!
//! Cache verification uses stored filename comparison (not hash alone) to
//! guarantee no wrong data is ever returned on hash collisions.

const std = @import("std");

// FNV-1a 32-bit, case-insensitive, backslash-normalized (for cache slot indexing).
pub fn hashPath(path: [*:0]const u8) u32 {
    var h: u32 = 0x811c9dc5;
    var i: usize = 0;
    while (path[i] != 0) : (i += 1) {
        var c = path[i];
        if (c >= 'A' and c <= 'Z') c += 32;
        if (c == '\\') c = '/';
        h ^= c;
        h *%= 0x01000193;
    }
    return h;
}

// Longest filename across all MPQ archives is 122 chars (macOS .nib path in base.MPQ).
// Longest game-relevant path is 114 chars (WMO models). 128 covers all with margin.
// Paths exceeding this are not cached (safe fallback to original function).
const CACHE_NAME_LEN = 128;
const CACHE_SIZE = 16384; // power of 2, direct-mapped

pub const ArchiveCacheEntry = struct {
    outer_archive: u32 = 0,
    inner_archive: u32 = 0,
    block_entry: u32 = 0,
    is_negative: bool = false,
    name: [CACHE_NAME_LEN]u8 = .{0} ** CACHE_NAME_LEN,
    name_len: u8 = 0,
};

var archive_cache: [CACHE_SIZE]ArchiveCacheEntry = @splat(ArchiveCacheEntry{});
var cache_entries: u32 = 0;
var cache_hits: u64 = 0;
var cache_negative_hits: u64 = 0;
var cache_misses: u64 = 0;

/// Lookup by hash (slot index) + filename verification. Returns null on miss or name mismatch.
pub fn archiveCacheLookup(h: u32, path: [*:0]const u8) ?ArchiveCacheEntry {
    const idx = h & (CACHE_SIZE - 1);
    const entry = &archive_cache[idx];
    if (entry.name_len == 0) return null;
    const span = std.mem.span(path);
    if (span.len != entry.name_len) return null;
    const len: usize = entry.name_len;
    if (!std.mem.eql(u8, entry.name[0..len], span[0..len])) return null;
    return entry.*;
}

/// Insert: hash picks slot, filename stored for verification on future lookups.
pub fn archiveCacheInsert(h: u32, path: [*:0]const u8, outer: u32, inner: u32, block: u32, negative: bool) void {
    const span = std.mem.span(path);
    if (span.len > CACHE_NAME_LEN) return; // too long to cache, skip
    const idx = h & (CACHE_SIZE - 1);
    if (archive_cache[idx].name_len == 0) cache_entries += 1;
    const entry = &archive_cache[idx];
    entry.outer_archive = outer;
    entry.inner_archive = inner;
    entry.block_entry = block;
    entry.is_negative = negative;
    const len: u8 = @intCast(span.len);
    @memcpy(entry.name[0..len], span[0..len]);
    entry.name_len = len;
}

pub fn recordCacheHit() void {
    cache_hits +|= 1;
}

pub fn recordNegativeHit() void {
    cache_negative_hits +|= 1;
}

pub fn recordCacheMiss() void {
    cache_misses +|= 1;
}

pub const CacheStats = struct { hits: u64, neg_hits: u64, misses: u64, entries: u32, total: u64 };

pub fn getCacheStats() CacheStats {
    return .{
        .hits = cache_hits,
        .neg_hits = cache_negative_hits,
        .misses = cache_misses,
        .entries = cache_entries,
        .total = cache_hits + cache_negative_hits + cache_misses,
    };
}

/// Reset cache stats but preserve cached data (archive pointers remain valid).
pub fn resetStats() void {
    cache_hits = 0;
    cache_negative_hits = 0;
    cache_misses = 0;
}
