//! transform_capture — snapshot transformMatrix4x4 inputs + outputs for offline
//! bench/parity replay. Enabled via a feature flag in weirdperformance.zig.
//!
//! Design:
//!   - Hook transformMatrix4x4 (0x714260).
//!   - On entry: compute a path hash from SceneObject flags + model_hdr counts.
//!     Skip if already seen.
//!   - Walk reachable pointer graph; record each referenced memory page
//!     (4KB granularity, keyed by page address). Save INPUT snapshot.
//!   - Call the game original via callOriginal.
//!   - Save OUTPUT snapshot of all pages we know get written.
//!   - Write to disk: one .trxcap file per unique path hash.
//!
//! Replay (bench):
//!   - Read .trxcap file.
//!   - For each page in the input snapshot, MAP_FIXED at its VA, copy data.
//!   - Call transformImpl_SSE64 (or SSE or game's x87).
//!   - Diff memory against the saved output snapshot.
//!
//! This captures real game state and gives us true parity coverage, but has a
//! state-pollution avoidance problem in-game: we can't run *both* game x87 and
//! our SSE impls on the same live SceneObject without state bleeding between
//! calls. The solution is to replay offline with each impl starting from a
//! fresh copy of the captured input snapshot.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");

var log: logging.Logger = .{};

// Win32 file/dir APIs — we run inside a Windows DLL, no libc filesystem.
const HANDLE = *anyopaque;
const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
extern "kernel32" fn CreateFileA(
    name: [*:0]const u8,
    desiredAccess: u32,
    shareMode: u32,
    security: ?*anyopaque,
    creationDisposition: u32,
    flags: u32,
    template: ?HANDLE,
) callconv(.{ .x86_stdcall = .{} }) HANDLE;
extern "kernel32" fn WriteFile(
    h: HANDLE,
    buf: [*]const u8,
    bytes: u32,
    written: *u32,
    ov: ?*anyopaque,
) callconv(.{ .x86_stdcall = .{} }) i32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.{ .x86_stdcall = .{} }) i32;
extern "kernel32" fn CreateDirectoryA(name: [*:0]const u8, security: ?*anyopaque) callconv(.{ .x86_stdcall = .{} }) i32;
extern "kernel32" fn SetFilePointer(h: HANDLE, lo: i32, hi: ?*i32, method: u32) callconv(.{ .x86_stdcall = .{} }) u32;

const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x1;
const CREATE_ALWAYS: u32 = 2;
const OPEN_ALWAYS: u32 = 4;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_END: u32 = 2;

fn writeAll(h: HANDLE, data: []const u8) bool {
    var written: u32 = 0;
    const ok = WriteFile(h, data.ptr, @intCast(data.len), &written, null);
    return ok != 0 and written == data.len;
}

pub const module_name: [*:0]const u8 = "transform_capture";

// Hook into game transformMatrix4x4
const TransformFn = fn (u32, u32, u32, u32, u32) callconv(.{ .x86_thiscall = .{} }) void;
var transform_hook: hook.Detour(TransformFn) = .{};

// =============================================================================
// SceneObject offsets (same as bone_sse, duplicated here so we don't couple)
// =============================================================================

const SO_MODEL_DATA_PTR: u32 = 0x010;
const SO_ANIM_CTX_PTR: u32 = 0x02C;
const SO_MODEL_CTR_PTR: u32 = 0x030;
const SO_SYNC_VALUE: u32 = 0x040;
const SO_BONE_RT_BASE: u32 = 0x090;
const SO_BONE_OUT_PTR: u32 = 0x094;
const SO_TEX_ANIM_OUT: u32 = 0x0A0;
const SO_COLOR_ANIM_OUT: u32 = 0x0A8;
const SO_SCALE1: u32 = 0x0AC;
const SO_SCALE2: u32 = 0x0B0;
const SO_SCALE3: u32 = 0x0B4;
const SO_HIERARCHY_PTR: u32 = 0x1C8;
const SO_HIERARCHY_IDX: u32 = 0x1DC;
const SO_FIELD_200: u32 = 0x200;
const SO_PARTICLE1: u32 = 0x3C4;
const SO_PARTICLE2: u32 = 0x3C8;
const SO_PARTICLE3: u32 = 0x3D0;
const SO_PARTICLE4: u32 = 0x3D4;

// =============================================================================
// Memory helpers
// =============================================================================

inline fn ru32(addr: u32) u32 {
    return @as(*const u32, @ptrFromInt(addr)).*;
}
inline fn ru16(addr: u32) u16 {
    return @as(*align(1) const u16, @ptrFromInt(addr)).*;
}

// =============================================================================
// Page capture infrastructure
// =============================================================================

const PAGE_SIZE: u32 = 0x1000;
const PAGE_MASK: u32 = 0xFFFFF000;
const MAX_CAPTURES: usize = 64; // cap on unique-hash scenarios we record
const MAX_PAGES_PER_CAPTURE: usize = 512; // each capture can touch up to 2MB

/// One captured page's raw bytes plus its VA.
const PageBlock = extern struct {
    va: u32,
    data: [PAGE_SIZE]u8,
};

/// One captured scenario: input pages + output pages + entry args.
const Capture = struct {
    path_hash: u32 = 0,
    this: u32 = 0,
    mat1: u32 = 0,
    mat2: u32 = 0,
    mat3: u32 = 0,
    mat4: u32 = 0,

    input_page_count: u32 = 0,
    output_page_count: u32 = 0,
    input_pages: [*]PageBlock = undefined,
    output_pages: [*]PageBlock = undefined,
};

// One scratch slot — we write captures to disk immediately, so only one in-
// flight capture needs memory at a time.
var scratch: Capture = .{};
var scratch_input_pages: [MAX_PAGES_PER_CAPTURE]PageBlock align(16) = undefined;
var scratch_output_pages: [MAX_PAGES_PER_CAPTURE]PageBlock align(16) = undefined;

// Deduplication: array of hashes we've already dumped.
var seen_hashes: [MAX_CAPTURES]u32 = [_]u32{0} ** MAX_CAPTURES;
var seen_hash_count: usize = 0;

// Re-entry guard (transformMatrix4x4 recurses into itself for attachments).
var in_capture: bool = false;

// Total captures written (== seen_hash_count, kept separate for clarity)
var capture_count: usize = 0;

// Total hook calls seen (for coverage statistics)
var total_calls: u64 = 0;

// Captures-written-per-log-slot so we can track distribution of hash values
var call_counts_per_hash: [MAX_CAPTURES]u32 = [_]u32{0} ** MAX_CAPTURES;

// How many consecutive calls have yielded no new hash (for "coverage saturated" heuristic).
var calls_since_new_hash: u64 = 0;

// Output directory — set at install time. Default = current working dir.
var capture_dir: []const u8 = ".";

// Per-capture scratch: pages we've already saved this iteration.
var seen_pages: [MAX_PAGES_PER_CAPTURE]u32 = [_]u32{0} ** MAX_PAGES_PER_CAPTURE;
var seen_count: usize = 0;

fn seenAdd(page_va: u32) bool {
    // Linear scan; MAX_PAGES_PER_CAPTURE is small enough that this is cheap.
    for (seen_pages[0..seen_count]) |p| if (p == page_va) return false;
    if (seen_count >= MAX_PAGES_PER_CAPTURE) return false;
    seen_pages[seen_count] = page_va;
    seen_count += 1;
    return true;
}

fn seenReset() void {
    seen_count = 0;
}

/// Copy one 4KB page from game memory into the destination array.
/// Returns true if the page was new (added to seen list).
fn captureOnePage(addr: u32, dst: [*]PageBlock, idx: *u32) bool {
    const page_va = addr & PAGE_MASK;
    if (!seenAdd(page_va)) return false;
    if (idx.* >= MAX_PAGES_PER_CAPTURE) return false;
    dst[idx.*].va = page_va;
    @memcpy(&dst[idx.*].data, @as([*]const u8, @ptrFromInt(page_va))[0..PAGE_SIZE]);
    idx.* += 1;
    return true;
}

/// Capture a memory range (rounded to pages).
fn capturePagesCovering(addr: u32, size: u32, dst: [*]PageBlock, idx: *u32) void {
    if (addr == 0 or size == 0) return;
    const start_page = addr & PAGE_MASK;
    const end_addr = addr +% size;
    var cur = start_page;
    while (cur < end_addr) : (cur +%= PAGE_SIZE) {
        _ = captureOnePage(cur, dst, idx);
    }
}

// =============================================================================
// Graph walk — identify all pages reachable from the SceneObject that
// transformMatrix4x4 might read.
// =============================================================================

fn walkAndCapture(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32, dst: [*]PageBlock, idx: *u32) void {
    _ = mat4;

    // Direct pages
    capturePagesCovering(this, 0x400, dst, idx);
    capturePagesCovering(mat1, 0x40, dst, idx);
    capturePagesCovering(mat2, 0x0C, dst, idx);
    capturePagesCovering(mat3, 0x0C, dst, idx);

    // Following pointers
    const anim_ctx = ru32(this + SO_ANIM_CTX_PTR);
    capturePagesCovering(anim_ctx, 0x20, dst, idx);

    const model_ctr = ru32(this + SO_MODEL_CTR_PTR);
    capturePagesCovering(model_ctr, 0x140, dst, idx);
    if (model_ctr == 0) return;

    const model_hdr = ru32(model_ctr + 0x130);
    capturePagesCovering(model_hdr, 0x200, dst, idx);
    if (model_hdr == 0) return;

    // model_hdr reference arrays
    const gs_durations = ru32(model_hdr + 0x18);
    const gs_count = ru32(model_hdr + 0x14);
    capturePagesCovering(gs_durations, gs_count * 4, dst, idx);

    const anim_lookup = ru32(model_hdr + 0x20);
    capturePagesCovering(anim_lookup, 0x1000, dst, idx); // conservative; actual size unknown

    const bone_count = ru32(model_hdr + 0x34);
    const bone_defs = ru32(model_hdr + 0x38);
    capturePagesCovering(bone_defs, bone_count * 0x6C, dst, idx);

    // bone_rt / bone_out
    const bone_rt = ru32(this + SO_BONE_RT_BASE);
    capturePagesCovering(bone_rt, bone_count * 0x118, dst, idx);
    const bone_out = ru32(this + SO_BONE_OUT_PTR);
    capturePagesCovering(bone_out, bone_count * 0x40, dst, idx);

    // AnimData inside bone_defs references keyframe arrays
    var bi: u32 = 0;
    var bd = bone_defs;
    while (bi < bone_count) : ({
        bi += 1;
        bd += 0x6C;
    }) {
        // Three animation tracks per bone (trans/rot/scale)
        inline for ([_]u32{ 0x0C, 0x28, 0x44 }) |track_off| {
            const ad = bd + track_off;
            const ranges = ru32(ad + 0x08);
            const ranges_count = ru32(ad + 0x04); // nRanges
            capturePagesCovering(ranges, ranges_count * 8, dst, idx);
            const ts = ru32(ad + 0x10);
            const kf_count = ru32(ad + 0x0C);
            capturePagesCovering(ts, kf_count * 4, dst, idx);
            const kf_base = ru32(ad + 0x18);
            // Stride varies by track — trans/scale=12, rot=16, but spline modes
            // use 36. Conservative: use 36 × kf_count per track.
            capturePagesCovering(kf_base, kf_count * 36, dst, idx);
        }
    }

    // Output-buffer pages (will be WRITTEN but we need to capture input state
    // too in case the game reads before writing)
    capturePagesCovering(ru32(this + SO_TEX_ANIM_OUT), 0x200, dst, idx);
    capturePagesCovering(ru32(this + SO_COLOR_ANIM_OUT), 0x200, dst, idx);
    capturePagesCovering(ru32(this + SO_SCALE1), 0x200, dst, idx);
    capturePagesCovering(ru32(this + SO_SCALE2), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_SCALE3), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_HIERARCHY_PTR), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_FIELD_200), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_PARTICLE1), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_PARTICLE2), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_PARTICLE3), 0x800, dst, idx);
    capturePagesCovering(ru32(this + SO_PARTICLE4), 0x400, dst, idx);

    // Attachment data
    const attach_count = ru32(model_hdr + 0x104);
    const attach_data = ru32(model_hdr + 0x108);
    capturePagesCovering(attach_data, attach_count * 0x30, dst, idx);

    // Texture/color/word anim data
    inline for ([_]struct { cnt: u32, dat: u32, stride: u32 }{
        .{ .cnt = 0x54, .dat = 0x58, .stride = 0x34 }, // tex anim
        .{ .cnt = 0x64, .dat = 0x68, .stride = 0x28 }, // color anim
        .{ .cnt = 0x74, .dat = 0x78, .stride = 0x1C }, // word anim
        .{ .cnt = 0xAC, .dat = 0xB0, .stride = 0x54 }, // bone keyframe
        .{ .cnt = 0x11C, .dat = 0x120, .stride = 0xD4 }, // ribbon emitter
        .{ .cnt = 0x124, .dat = 0x128, .stride = 0x7C }, // particle emitter
        .{ .cnt = 0x134, .dat = 0x138, .stride = 0xDC }, // partsec
        .{ .cnt = 0x13C, .dat = 0x140, .stride = 0x1F8 }, // partlarge
    }) |sec| {
        const c = ru32(model_hdr + sec.cnt);
        const d = ru32(model_hdr + sec.dat);
        capturePagesCovering(d, c * sec.stride, dst, idx);
    }
}

// =============================================================================
// Path hash — distinguishes different code paths through transformMatrix4x4.
// Cheap to compute; aim to hit every major branch.
// =============================================================================

fn pathHash(this: u32) u32 {
    var h: u32 = 0x811C9DC5;

    const model_ctr = ru32(this + SO_MODEL_CTR_PTR);
    if (model_ctr == 0) return h;
    const model_hdr = ru32(model_ctr + 0x130);
    if (model_hdr == 0) return h;

    const bone_count = ru32(model_hdr + 0x34);
    h = (h ^ bone_count) *% 0x01000193;

    const bone_defs = ru32(model_hdr + 0x38);
    if (bone_count > 0 and bone_defs != 0) {
        // Flags of first few bones (encodes billboard types, etc.)
        const max_bones = @min(bone_count, 6);
        var bi: u32 = 0;
        while (bi < max_bones) : (bi += 1) {
            const flags = ru32(bone_defs + bi * 0x6C + 0x04);
            h = (h ^ flags) *% 0x01000193;
        }
    }

    // Which post-bone-loop sections are populated?
    inline for ([_]u32{ 0x14, 0x54, 0x64, 0x74, 0xAC, 0x104, 0x11C, 0x124, 0x134, 0x13C }) |off| {
        const v = ru32(model_hdr + off);
        h = (h ^ (if (v == 0) @as(u32, 0) else 1)) *% 0x01000193;
    }

    // emitter_ctx presence
    const emitter_ctx = ru32(this + 0x1CC);
    h = (h ^ (if (emitter_ctx == 0) @as(u32, 0) else 1)) *% 0x01000193;

    return h;
}

// =============================================================================
// Detour
// =============================================================================

fn transformDetour(this: u32, mat1: u32, mat2: u32, mat3: u32, mat4: u32) callconv(.{ .x86_thiscall = .{} }) void {
    // Re-entry guard: transformMatrix4x4 recurses for attachment children.
    if (in_capture) {
        transform_hook.callOriginal(.{ this, mat1, mat2, mat3, mat4 });
        return;
    }

    total_calls +%= 1;

    if (capture_count < MAX_CAPTURES) {
        const h = pathHash(this);
        var known_idx: ?usize = null;
        for (seen_hashes[0..seen_hash_count], 0..) |sh, i| if (sh == h) {
            known_idx = i;
            break;
        };
        if (known_idx) |idx| {
            call_counts_per_hash[idx] +%= 1;
            calls_since_new_hash +%= 1;
        } else {
            in_capture = true;
            defer in_capture = false;

            scratch.path_hash = h;
            scratch.this = this;
            scratch.mat1 = mat1;
            scratch.mat2 = mat2;
            scratch.mat3 = mat3;
            scratch.mat4 = mat4;
            scratch.input_page_count = 0;
            scratch.output_page_count = 0;

            seenReset();
            walkAndCapture(this, mat1, mat2, mat3, mat4, &scratch_input_pages, &scratch.input_page_count);

            transform_hook.callOriginal(.{ this, mat1, mat2, mat3, mat4 });

            var oi: u32 = 0;
            var pi: usize = 0;
            while (pi < scratch.input_page_count) : (pi += 1) {
                if (oi >= MAX_PAGES_PER_CAPTURE) break;
                scratch_output_pages[oi].va = scratch_input_pages[pi].va;
                @memcpy(&scratch_output_pages[oi].data, @as([*]const u8, @ptrFromInt(scratch_input_pages[pi].va))[0..PAGE_SIZE]);
                oi += 1;
            }
            scratch.output_page_count = oi;
            scratch.input_pages = &scratch_input_pages;
            scratch.output_pages = &scratch_output_pages;

            const dump_err = dumpOneToDir(capture_dir, scratch);
            const cov_err = appendCoverageLog(h, scratch.input_page_count);
            log.fmt("capture: hash=0x{x:08} pages={d} dump={any} cov={any}\n", .{
                h, scratch.input_page_count, dump_err, cov_err,
            });

            if (seen_hash_count < MAX_CAPTURES) {
                seen_hashes[seen_hash_count] = h;
                call_counts_per_hash[seen_hash_count] = 1;
                seen_hash_count += 1;
            }
            capture_count += 1;
            calls_since_new_hash = 0;
            return;
        }
    } else {
        calls_since_new_hash +%= 1;
    }

    transform_hook.callOriginal(.{ this, mat1, mat2, mat3, mat4 });
}

// =============================================================================
// File format
// =============================================================================

const MAGIC: [4]u8 = .{ 'T', 'R', 'X', 'C' };
const VERSION: u32 = 1;

const FileHeader = extern struct {
    magic: [4]u8 = MAGIC,
    version: u32 = VERSION,
    path_hash: u32,
    this: u32,
    mat1: u32,
    mat2: u32,
    mat3: u32,
    mat4: u32,
    input_page_count: u32,
    output_page_count: u32,
};

/// Build a null-terminated path: "<dir>/<filename>".
fn buildPath(buf: []u8, dir: []const u8, filename: []const u8) ![:0]const u8 {
    const total = dir.len + 1 + filename.len + 1;
    if (total > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 ..][0..filename.len], filename);
    buf[dir.len + 1 + filename.len] = 0;
    return buf[0 .. dir.len + 1 + filename.len :0];
}

fn buildDirZ(buf: []u8, dir: []const u8) ![:0]const u8 {
    if (dir.len + 1 > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    return buf[0..dir.len :0];
}

fn dumpOneToDir(dir_path: []const u8, c: Capture) !void {
    var dir_buf: [256]u8 = undefined;
    const dir_z = try buildDirZ(&dir_buf, dir_path);
    _ = CreateDirectoryA(dir_z.ptr, null); // ignore result: already-exists is fine

    var name_buf: [64]u8 = undefined;
    const fname = try std.fmt.bufPrint(&name_buf, "{x:08}.trxcap", .{c.path_hash});

    var path_buf: [512]u8 = undefined;
    const path = try buildPath(&path_buf, dir_path, fname);

    const h = CreateFileA(path.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return error.CreateFailed;
    defer _ = CloseHandle(h);

    const hdr = FileHeader{
        .path_hash = c.path_hash,
        .this = c.this,
        .mat1 = c.mat1,
        .mat2 = c.mat2,
        .mat3 = c.mat3,
        .mat4 = c.mat4,
        .input_page_count = c.input_page_count,
        .output_page_count = c.output_page_count,
    };
    if (!writeAll(h, std.mem.asBytes(&hdr))) return error.WriteFailed;
    if (!writeAll(h, @as([*]const u8, @ptrCast(c.input_pages))[0 .. c.input_page_count * @sizeOf(PageBlock)])) return error.WriteFailed;
    if (!writeAll(h, @as([*]const u8, @ptrCast(c.output_pages))[0 .. c.output_page_count * @sizeOf(PageBlock)])) return error.WriteFailed;
}

/// Append a line to coverage.log whenever we see a new path hash.
fn appendCoverageLog(new_hash: u32, page_count: u32) !void {
    var dir_buf: [256]u8 = undefined;
    const dir_z = try buildDirZ(&dir_buf, capture_dir);
    _ = CreateDirectoryA(dir_z.ptr, null);

    var path_buf: [512]u8 = undefined;
    const path = try buildPath(&path_buf, capture_dir, "coverage.log");

    const h = CreateFileA(path.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return error.CreateFailed;
    defer _ = CloseHandle(h);
    _ = SetFilePointer(h, 0, null, FILE_END);

    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "[#{d}] new hash 0x{x:08} (total_calls={d}, pages={d})\n", .{
        seen_hash_count + 1, new_hash, total_calls, page_count,
    });
    if (!writeAll(h, line)) return error.WriteFailed;
}

// =============================================================================
// Install / Remove
// =============================================================================

/// Install with the given output directory (relative to WoW's current working
/// directory, usually the game install folder). Captures + coverage.log will
/// land there. Pass "." to write them next to WoW.exe.
pub fn install() bool {
    return installTo("transform_captures");
}

pub fn installTo(dir: []const u8) bool {
    log = logging.Logger.open("transform_capture", .both);
    capture_dir = dir;
    const ok = transform_hook.attach(0x714260, &transformDetour) == .ok;
    log.fmt("install: hook_attach={any} dir={s}\n", .{ ok, dir });

    // Smoke-test the write path so we know if file I/O is broken before any
    // transform calls arrive.
    var dir_buf: [256]u8 = undefined;
    const dir_z = buildDirZ(&dir_buf, capture_dir) catch return ok;
    const mkdir_ok = CreateDirectoryA(dir_z.ptr, null);
    log.fmt("install: mkdir returned {d}\n", .{mkdir_ok});

    var path_buf: [512]u8 = undefined;
    const path = buildPath(&path_buf, capture_dir, "install_test.txt") catch return ok;
    const h = CreateFileA(path.ptr, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) {
        log.fmt("install: CreateFileA FAILED for {s}\n", .{path});
    } else {
        _ = writeAll(h, "transform_capture install test\n");
        _ = CloseHandle(h);
        log.fmt("install: wrote install_test.txt ok\n", .{});
    }
    return ok;
}

pub fn remove() void {
    transform_hook.detach();
}

pub fn getCaptureCount() usize {
    return capture_count;
}

pub fn getTotalCalls() u64 {
    return total_calls;
}

pub fn getCallsSinceNewHash() u64 {
    return calls_since_new_hash;
}
