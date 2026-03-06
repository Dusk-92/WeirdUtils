//! Minimal PNG encoder with deflate compression.
//! No large struct literals or lookup tables - entire module adds ~2KB to .rdata.
//! Supports store blocks (level 0) and fixed-Huffman encoding (levels 1-9).

const std = @import("std");

// =============================================================================
// Public interface
// =============================================================================

pub const Level = enum(u4) {
    store = 0,
    level_1 = 1,
    level_2 = 2,
    level_3 = 3,
    level_4 = 4,
    level_5 = 5,
    level_6 = 6,
    level_7 = 7,
    level_8 = 8,
    level_9 = 9,
};

pub fn mapLevel(user_level: i32) Level {
    return switch (user_level) {
        0 => .store,
        1...9 => @enumFromInt(@as(u4, @intCast(std.math.clamp(user_level, 0, 9)))),
        else => .level_6,
    };
}

/// Write an RGB24 PNG to a raw file handle (HANDLE from CreateFileA).
/// `write_fn` is called with (ctx, data) to emit bytes.
pub fn encode(
    ctx: anytype,
    write_fn: fn (@TypeOf(ctx), []const u8) void,
    pixels: [*]const u8,
    width: u16,
    height: u16,
    level: Level,
) void {
    var s = Stream(@TypeOf(ctx)){ .ctx = ctx, .write_fn = write_fn };

    const w: u32 = width;
    const h: u32 = height;

    // PNG signature
    s.writeRaw("\x89PNG\r\n\x1a\n");

    // IHDR
    {
        var ihdr: [13]u8 = undefined;
        writeU32BE(ihdr[0..4], w);
        writeU32BE(ihdr[4..8], h);
        ihdr[8] = 8; // bit depth
        ihdr[9] = 2; // color type RGB
        ihdr[10] = 0; // compression
        ihdr[11] = 0; // filter
        ihdr[12] = 0; // interlace
        s.writeChunk("IHDR", &ihdr);
    }

    // IDAT
    if (@intFromEnum(level) == 0) {
        writeIdatStore(&s, pixels, w, h);
    } else {
        writeIdatFixedHuffman(&s, pixels, w, h, @intFromEnum(level));
    }

    // IEND
    s.writeChunk("IEND", &[0]u8{});
}

// =============================================================================
// Stream wrapper - tracks CRC and Adler inline
// =============================================================================

fn Stream(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        write_fn: *const fn (Ctx, []const u8) void,
        crc: u32 = 0xFFFFFFFF,
        adler_a: u32 = 1,
        adler_b: u32 = 0,

        const Self = @This();

        fn writeRaw(self: *Self, data: []const u8) void {
            self.write_fn(self.ctx, data);
        }

        fn writeCrc(self: *Self, data: []const u8) void {
            self.writeRaw(data);
            self.crc = crc32Update(self.crc, data);
        }

        fn writeCrcAdler(self: *Self, data: []const u8) void {
            self.writeRaw(data);
            self.crc = crc32Update(self.crc, data);
            adlerUpdate(&self.adler_a, &self.adler_b, data);
        }

        fn writeChunk(self: *Self, chunk_type: *const [4]u8, data: []const u8) void {
            var buf: [4]u8 = undefined;
            writeU32BE(&buf, @intCast(data.len));
            self.writeRaw(&buf);
            self.writeRaw(chunk_type);
            self.writeRaw(data);
            var crc: u32 = 0xFFFFFFFF;
            crc = crc32Update(crc, chunk_type);
            crc = crc32Update(crc, data);
            writeU32BE(&buf, crc ^ 0xFFFFFFFF);
            self.writeRaw(&buf);
        }

        fn beginChunk(self: *Self, chunk_type: *const [4]u8, payload_len: u32) void {
            var buf: [4]u8 = undefined;
            writeU32BE(&buf, payload_len);
            self.writeRaw(&buf);
            self.writeRaw(chunk_type);
            self.crc = 0xFFFFFFFF;
            self.crc = crc32Update(self.crc, chunk_type);
        }

        fn endChunk(self: *Self) void {
            var buf: [4]u8 = undefined;
            writeU32BE(&buf, self.crc ^ 0xFFFFFFFF);
            self.writeRaw(&buf);
        }

        fn resetAdler(self: *Self) void {
            self.adler_a = 1;
            self.adler_b = 0;
        }

        fn adlerFinish(self: *Self) u32 {
            return (self.adler_b << 16) | self.adler_a;
        }
    };
}

// =============================================================================
// Store blocks (level 0) - no compression, byte-aligned
// =============================================================================

fn writeIdatStore(s: anytype, pixels: [*]const u8, w: u32, h: u32) void {
    const row_bytes: u32 = 1 + w * 3;
    const raw_size: u32 = h * row_bytes;
    const max_block: u32 = 65535;
    const num_blocks: u32 = (raw_size + max_block - 1) / max_block;
    const idat_payload: u32 = 2 + num_blocks * 5 + raw_size + 4;

    s.beginChunk("IDAT", idat_payload);
    s.resetAdler();

    // Zlib header
    const zlib_hdr = [2]u8{ 0x78, 0x01 };
    s.writeCrc(&zlib_hdr);

    var raw_remaining: u32 = raw_size;
    var y: u32 = 0;
    var row_off: u32 = 0;

    while (raw_remaining > 0) {
        const block_size: u32 = @min(raw_remaining, max_block);
        const bs16: u16 = @intCast(block_size);
        var hdr: [5]u8 = undefined;
        hdr[0] = if (raw_remaining <= max_block) @as(u8, 0x01) else 0x00;
        hdr[1] = @truncate(bs16);
        hdr[2] = @truncate(bs16 >> 8);
        hdr[3] = hdr[1] ^ 0xFF;
        hdr[4] = hdr[2] ^ 0xFF;
        s.writeCrc(&hdr);

        var written: u32 = 0;
        while (written < block_size) {
            if (row_off == 0) {
                const fb = [1]u8{0x00};
                s.writeCrcAdler(&fb);
                row_off = 1;
                written += 1;
            } else {
                const pix_off = y * w * 3 + (row_off - 1);
                const left_row = w * 3 - (row_off - 1);
                const left_blk = block_size - written;
                const n = @min(left_row, left_blk);
                const data = pixels[pix_off..][0..n];
                s.writeCrcAdler(data);
                row_off += n;
                written += n;
                if (row_off > w * 3) {
                    row_off = 0;
                    y += 1;
                }
            }
        }
        raw_remaining -= block_size;
    }

    var buf: [4]u8 = undefined;
    writeU32BE(&buf, s.adlerFinish());
    s.writeCrc(&buf);
    s.endChunk();
}

// =============================================================================
// Fixed Huffman + LZ77 - RFC 1951 §3.2.6 fixed codes with back-references
//
// Sub filter makes adjacent pixel differences small (often zero in flat areas).
// LZ77 with hash-table matching finds repeated byte sequences within a 32KB
// window and encodes them as length-distance pairs.
// =============================================================================

const BitBuf = struct {
    bits: u32 = 0,
    nbits: u5 = 0,

    fn write(self: *BitBuf, s: anytype, code: u32, len: u5) void {
        self.bits |= code << self.nbits;
        self.nbits += len;
        while (self.nbits >= 8) {
            const byte = [1]u8{@truncate(self.bits)};
            s.writeCrcAdler(&byte);
            self.bits >>= 8;
            self.nbits -= 8;
        }
    }

    fn flush(self: *BitBuf, s: anytype) void {
        if (self.nbits > 0) {
            const byte = [1]u8{@truncate(self.bits)};
            s.writeCrcAdler(&byte);
            self.bits = 0;
            self.nbits = 0;
        }
    }
};

fn bitReverse(comptime T: type, val: T, n: u5) u32 {
    const full = @bitReverse(val);
    const shift: u5 = @intCast(@typeInfo(T).int.bits - @as(u8, n));
    return @as(u32, full) >> shift;
}

/// RFC 1951 fixed Huffman: encode a literal/length code (0-285).
fn fixedCode(bb: *BitBuf, s: anytype, val: u16) void {
    if (val <= 143) {
        const code: u9 = @as(u9, @intCast(val)) + 0x30;
        bb.write(s, bitReverse(u9, code, 8), 8);
    } else if (val <= 255) {
        const code: u9 = @as(u9, @intCast(val - 144)) + 0x190;
        bb.write(s, bitReverse(u9, code, 9), 9);
    } else if (val <= 279) {
        const code: u9 = @intCast(val - 256);
        bb.write(s, bitReverse(u9, code, 7), 7);
    } else {
        const code: u9 = @as(u9, @intCast(val - 280)) + 0xC0;
        bb.write(s, bitReverse(u9, code, 8), 8);
    }
}

// RFC 1951 length/distance encoding tables (from stb_image_write.h)
const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

inline fn zhashFn(d: *const [3]u8) u32 {
    var h: u32 = @as(u32, d[0]) +% (@as(u32, d[1]) << 8) +% (@as(u32, d[2]) << 16);
    h ^= h *% 8;
    h +%= h >> 5;
    h ^= h *% 16;
    h +%= h >> 17;
    h ^= h *% (1 << 25);
    h +%= h >> 6;
    return h;
}

fn countMatch(data: []const u8, a: u32, b: u32) u32 {
    const max_len: u32 = @min(@as(u32, @intCast(data.len)) - b, 258);
    var i: u32 = 0;
    while (i < max_len) : (i += 1) {
        if (data[a + i] != data[b + i]) break;
    }
    return i;
}

/// Emit a deflate length-distance pair using fixed Huffman codes.
fn emitMatch(bb: *BitBuf, s: anytype, length: u32, distance: u32) void {
    // Length code
    var li: usize = 0;
    while (li + 1 < length_base.len and length >= length_base[li + 1]) : (li += 1) {}
    fixedCode(bb, s, @intCast(li + 257));
    if (length_extra[li] > 0) bb.write(s, length - length_base[li], length_extra[li]);
    // Distance code: 5-bit reversed + extra bits
    var di: usize = 0;
    while (di + 1 < dist_base.len and distance >= dist_base[di + 1]) : (di += 1) {}
    bb.write(s, bitReverse(u5, @as(u5, @intCast(di)), 5), 5);
    if (dist_extra[di] > 0) bb.write(s, distance - dist_base[di], dist_extra[di]);
}

fn writeIdatFixedHuffman(s: anytype, pixels: [*]const u8, w: u32, h: u32, level: u4) void {
    const row_bytes: u32 = 1 + w * 3;
    const raw_size: u32 = h * row_bytes;

    // Pre-filter all pixel data (Sub filter) into contiguous buffer
    const filtered = std.heap.page_allocator.alloc(u8, raw_size) catch {
        writeIdatStore(s, pixels, w, h);
        return;
    };
    defer std.heap.page_allocator.free(filtered);
    {
        var pos: u32 = 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            filtered[pos] = 1; // Sub filter type byte
            pos += 1;
            const row = y * w * 3;
            var x: u32 = 0;
            while (x < w * 3) : (x += 1) {
                const raw = pixels[row + x];
                filtered[pos] = if (x >= 3) raw -% pixels[row + x - 3] else raw;
                pos += 1;
            }
        }
    }

    // Adler-32 over entire filtered buffer
    var adler_a: u32 = 1;
    var adler_b: u32 = 0;
    adlerUpdate(&adler_a, &adler_b, filtered[0..raw_size]);
    const adler: u32 = (adler_b << 16) | adler_a;

    // Output buffer (worst case: ~9 bits per byte for fixed Huffman literals)
    const max_out: u32 = raw_size + raw_size / 4 + 1024;
    const out_buf = std.heap.page_allocator.alloc(u8, max_out) catch {
        writeIdatStore(s, pixels, w, h);
        return;
    };
    defer std.heap.page_allocator.free(out_buf);

    // Hash chains for LZ77 matching - chain depth = 2 * level (stb approach)
    const ZHASH: u32 = 16384;
    const chain_depth: u32 = @as(u32, level) * 2;
    const chain_mem = std.heap.page_allocator.alloc(u32, ZHASH * chain_depth) catch {
        writeIdatStore(s, pixels, w, h);
        return;
    };
    defer std.heap.page_allocator.free(chain_mem);
    const chain_count = std.heap.page_allocator.alloc(u8, ZHASH) catch {
        writeIdatStore(s, pixels, w, h);
        return;
    };
    defer std.heap.page_allocator.free(chain_count);
    @memset(chain_count, 0);

    var out_pos: u32 = 0;
    const OutStream = struct {
        buf: []u8,
        pos: *u32,
        fn writeCrcAdler(self: *@This(), data: []const u8) void {
            for (data) |byte| {
                if (self.pos.* < self.buf.len) {
                    self.buf[self.pos.*] = byte;
                    self.pos.* += 1;
                }
            }
        }
    };
    var out_stream = OutStream{ .buf = out_buf, .pos = &out_pos };

    // Zlib header
    out_buf[0] = 0x78;
    out_buf[1] = 0x9C;
    out_pos = 2;

    var bb: BitBuf = .{};
    // BFINAL=1, BTYPE=01 (fixed Huffman)
    bb.write(&out_stream, 0b011, 3);

    // LZ77 + fixed Huffman encoding
    const WINDOW: u32 = 32768;
    var i: u32 = 0;
    while (i + 2 < raw_size) {
        const bucket = zhashFn(filtered[i..][0..3]) & (ZHASH - 1);
        const base = bucket * chain_depth;

        // Search chain for best match (prefer closest of equal length via >=)
        var best_len: u32 = 3;
        var best_dist: u32 = 0;
        {
            var j: u32 = 0;
            while (j < chain_count[bucket]) : (j += 1) {
                const prev = chain_mem[base + j];
                if (i -% prev <= WINDOW) {
                    const ml = countMatch(filtered[0..raw_size], prev, i);
                    if (ml >= best_len) {
                        best_len = ml;
                        best_dist = i - prev;
                    }
                }
            }
        }

        // Add current position to chain; prune oldest half when full
        {
            var cnt = @as(u32, chain_count[bucket]);
            if (cnt >= chain_depth) {
                const keep = chain_depth / 2;
                const src = base + chain_depth - keep;
                @memcpy(chain_mem[base..][0..keep], chain_mem[src..][0..keep]);
                cnt = keep;
            }
            chain_mem[base + cnt] = i;
            chain_count[bucket] = @intCast(cnt + 1);
        }

        if (best_dist > 0) {
            // Lazy matching: check if next position beats current match
            if (i + 3 < raw_size) {
                const bucket2 = zhashFn(filtered[i + 1 ..][0..3]) & (ZHASH - 1);
                const base2 = bucket2 * chain_depth;
                var j: u32 = 0;
                while (j < chain_count[bucket2]) : (j += 1) {
                    const prev2 = chain_mem[base2 + j];
                    if ((i + 1) -% prev2 <= WINDOW) {
                        if (countMatch(filtered[0..raw_size], prev2, i + 1) > best_len) {
                            best_dist = 0; // cancel - next position is better
                            break;
                        }
                    }
                }
            }
            if (best_dist > 0) {
                emitMatch(&bb, &out_stream, best_len, best_dist);
                i += best_len;
                continue;
            }
        }

        fixedCode(&bb, &out_stream, filtered[i]);
        i += 1;
    }
    // Remaining <3 bytes as literals
    while (i < raw_size) : (i += 1) {
        fixedCode(&bb, &out_stream, filtered[i]);
    }

    fixedCode(&bb, &out_stream, 256); // End of block
    bb.flush(&out_stream);

    // Append Adler-32 (big-endian)
    if (out_pos + 4 <= out_buf.len) {
        out_buf[out_pos] = @truncate(adler >> 24);
        out_buf[out_pos + 1] = @truncate(adler >> 16);
        out_buf[out_pos + 2] = @truncate(adler >> 8);
        out_buf[out_pos + 3] = @truncate(adler);
        out_pos += 4;
    }

    // Fallback to store if compressed is larger
    if (out_pos >= raw_size) {
        writeIdatStore(s, pixels, w, h);
        return;
    }

    s.writeChunk("IDAT", out_buf[0..out_pos]);
}

// =============================================================================
// CRC-32 (1KB comptime table) and Adler-32
// =============================================================================

const crc32_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        table[n] = c;
    }
    break :blk table;
};

fn crc32Update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| {
        c = crc32_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c;
}

fn adlerUpdate(a: *u32, b: *u32, data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = @min(remaining.len, 5552);
        for (remaining[0..n]) |byte| {
            a.* += byte;
            b.* += a.*;
        }
        a.* %= 65521;
        b.* %= 65521;
        remaining = remaining[n..];
    }
}

fn writeU32BE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}
