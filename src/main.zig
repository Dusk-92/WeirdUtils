const std = @import("std");
const hook = @import("zhook");
pub const con = @import("console.zig");

// Build options for conditional module compilation
const build_opts = struct {
    const screenshot = @import("build_options").enable_screenshot;
    const interact = @import("build_options").enable_interact;
    const outline = @import("build_options").enable_outline;
    const worldmarkers = @import("build_options").enable_worldmarkers;
    const framecrash = @import("build_options").enable_framecrash;
    const logsessions = @import("build_options").enable_logsessions;
    const minimapicons = @import("build_options").enable_minimapicons;
    const transmogfix = @import("build_options").enable_transmogfix;
    const customassets = @import("build_options").enable_customassets;
    const healtextfix = @import("build_options").enable_healtextfix;
    const bigcursor = @import("build_options").enable_bigcursor;
    const dpslog = @import("build_options").enable_dpslog;
};

// Conditional module imports
const screenshot = if (build_opts.screenshot) @import("screenshot/screenshot.zig") else struct {};
const interact = if (build_opts.interact) @import("interact/interact.zig") else struct {};
const outline = if (build_opts.outline) @import("outline/api.zig") else struct {};
const markers = if (build_opts.worldmarkers) @import("markers/markers.zig") else struct {};
const framecrash = if (build_opts.framecrash) @import("framecrash/framecrash.zig") else struct {};
const logsessions = if (build_opts.logsessions) @import("logsessions/logsessions.zig") else struct {};
const minimapicons = if (build_opts.minimapicons) @import("minimapicons/minimapicons.zig") else struct {};
const transmogfix = if (build_opts.transmogfix) @import("transmogfix/transmogfix.zig") else struct {};
const customassets = if (build_opts.customassets) @import("customassets/customassets.zig") else struct {};
const healtextfix = if (build_opts.healtextfix) @import("healtextfix/healtextfix.zig") else struct {};
const bigcursor = if (build_opts.bigcursor) @import("bigcursor/bigcursor.zig") else struct {};
const dpslog = if (build_opts.dpslog) @import("dpslog/dpslog.zig") else struct {};

const WINAPI = std.builtin.CallingConvention.winapi;
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

// =============================================================================
// Lua Protection Bypass
// =============================================================================

var protection_hook: hook.Detour(fn () callconv(sc) void) = .{};

fn luaProtectionDetour() callconv(sc) void {}

// =============================================================================
// Lua C API wrappers (WoW 1.12.1 - all __fastcall, L in ECX)
// =============================================================================

pub const lua = @import("lua.zig");

// =============================================================================
// Game function wrappers
// =============================================================================

fn registerFunction(name: [*:0]const u8, func_addr: usize) void {
    hook.fastcall(void, 0x704120, @intFromPtr(name), func_addr);
}

fn allocateGameBuffer(size: u32) ?[*]u8 {
    return asm volatile (
        \\push $0
        \\push $0
        \\push %[src]
        \\push %[size]
        \\call *%[func]
        : [ret] "={eax}" (-> ?[*]u8),
        : [size] "r" (size),
          [src] "r" (@intFromPtr(@as([*:0]const u8, "weirdutils"))),
          [func] "r" (@as(u32, 0x6462E0)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Custom C functions (callable from Lua)
// =============================================================================

fn registerLuaFunctions() void {
    // Conditional module functions
    if (build_opts.interact) {
        registerFunction("InteractNearest", @intFromPtr(&interact.interactNearest));
        registerFunction("LootAllCorpses", @intFromPtr(&interact.lootAllCorpses));
    }
    if (build_opts.outline) {
        registerFunction("OutlineCommand", @intFromPtr(&outline.outlineCommand));
    }
    if (build_opts.logsessions) {
        registerFunction("GetCombatLogPath", @intFromPtr(&logsessions.luaGetCombatLogPath));
        registerFunction("GetChatLogPath", @intFromPtr(&logsessions.luaGetChatLogPath));
    }
    if (build_opts.bigcursor) {
        registerFunction("SetCursorScale", @intFromPtr(&bigcursor.luaSetCursorScale));
        registerFunction("GetCursorScale", @intFromPtr(&bigcursor.luaGetCursorScale));
    }
    if (build_opts.minimapicons and minimapicons.isActive()) {
        registerFunction("SetObjectTypeBlip", @intFromPtr(&minimapicons.luaSetObjectTypeBlip));
    }
    if (build_opts.worldmarkers and markers.isActive()) {
        // User-facing functions stay global
        registerFunction("WorldMarker", @intFromPtr(&markers.luaWorldMarker));
        registerFunction("ClearWorldMarker", @intFromPtr(&markers.luaClearWorldMarker));
        registerFunction("GetWorldMarker", @intFromPtr(&markers.luaGetWorldMarker));
        registerFunction("CanSetWorldMarker", @intFromPtr(&markers.luaCanSetMarkers));

        // Sync functions in WorldMarkers table (used by addon message handler)
        const lib = [_]lua.LuaReg{
            .{ .name = "SetMarkerSync", .func = @intFromPtr(&markers.luaSetMarkerDef) },
            .{ .name = "ClearMarkerSync", .func = @intFromPtr(&markers.luaClearMarkerDef) },
            .{ .name = null, .func = 0 }, // sentinel
        };
        lua.openlib(lua.getContext(), "WorldMarkers", &lib, 0);
    }
}

// =============================================================================
// Embedded addon files — auto-generated from addon/ and assets/ directories
// =============================================================================

const build_options = @import("build_options");

const AddonPrefix = struct {
    prefix: []const u8,
    files: []const FileEntry,
};

const FileEntry = struct {
    name: []const u8,
    data: []const u8,
};

/// Module descriptor for compile-time embed generation.
/// addon_name: WoW AddOns folder name (determines prefix + TOC/Bindings paths).
/// option: build_options field name for enable flag.
/// addon_files_opt / asset_files_opt: build_options field names for file lists.
const EmbedModule = struct {
    option: []const u8,
    addon_name: ?[]const u8 = null,
    addon_files_opt: ?[]const u8 = null,
    asset_files_opt: ?[]const u8 = null,
    /// If true, addon is marked as SECURE (hidden from addon list, always loaded).
    hidden: bool = false,
};

const embed_modules = [_]EmbedModule{
    .{ .option = "screenshot" },
    .{ .option = "interact", .addon_name = "WeirdUtils_Interact", .addon_files_opt = "interact_addon_files" },
    .{ .option = "outline", .addon_name = "WeirdUtils_Outline", .addon_files_opt = "outline_addon_files" },
    .{ .option = "worldmarkers", .addon_name = "WeirdUtils_WorldMarkers", .addon_files_opt = "worldmarkers_addon_files", .asset_files_opt = "worldmarkers_asset_files", .hidden = true },
    .{ .option = "logsessions", .addon_name = "WeirdUtils_LogSessions", .addon_files_opt = "logsessions_addon_files" },
    .{ .option = "minimapicons", .addon_name = "WeirdUtils_MinimapIcons", .addon_files_opt = "minimapicons_addon_files", .asset_files_opt = "minimapicons_asset_files" },
};

/// Extract filename from a path like "markers/addon/Foo.lua" → "Foo.lua"
fn comptimeBasename(comptime path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') return path[i + 1 ..];
    }
    return path;
}

/// Extract WoW-style parent directory: "markers/assets/Spells/foo.m2" with
/// assets_prefix="markers/assets/" → "Spells\\"
fn comptimeWowDir(comptime path: []const u8, comptime assets_prefix: []const u8) []const u8 {
    const rel = path[assets_prefix.len..]; // e.g. "Spells/foo.m2"
    // Find last '/' to separate dir from filename
    var last_slash: usize = 0;
    var found = false;
    for (rel, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
            found = true;
        }
    }
    if (!found) return "";
    const dir = rel[0..last_slash]; // e.g. "Spells"
    // Convert '/' to '\' and add trailing '\'
    return comptime blk: {
        var buf: [dir.len + 1]u8 = undefined;
        for (dir, 0..) |c, i| {
            buf[i] = if (c == '/') '\\' else c;
        }
        buf[dir.len] = '\\';
        const final = buf;
        break :blk &final;
    };
}

/// Embed a list of files, returning an array of FileEntry.
fn embedFiles(comptime paths: []const []const u8) [paths.len]FileEntry {
    comptime {
        var entries: [paths.len]FileEntry = undefined;
        for (paths, 0..) |path, i| {
            entries[i] = .{
                .name = comptimeBasename(path),
                .data = @embedFile(path),
            };
        }
        const final = entries;
        return final;
    }
}

/// Build all AddonPrefix entries from embed_modules at comptime.
fn buildAllPrefixes() []const AddonPrefix {
    @setEvalBranchQuota(50000);
    comptime {
        // First pass: count total prefix entries
        var count: usize = 0;
        for (embed_modules) |mod| {
            if (!@field(build_options, "enable_" ++ mod.option)) continue;

            if (mod.addon_files_opt) |opt| {
                if (@field(build_options, opt).len > 0) count += 1;
            }
            if (mod.asset_files_opt) |opt| {
                const asset_paths = @field(build_options, opt);
                // Determine assets_prefix from first path (e.g. "markers/assets/")
                if (asset_paths.len > 0) {
                    const pfx = assetsPrefixFromOpt(opt);
                    count += countUniqueAssetDirs(asset_paths, pfx);
                }
            }
        }

        // Second pass: build array
        var result: [count]AddonPrefix = undefined;
        var idx: usize = 0;
        for (embed_modules) |mod| {
            if (!@field(build_options, "enable_" ++ mod.option)) continue;

            if (mod.addon_files_opt) |opt| {
                const paths = @field(build_options, opt);
                if (paths.len > 0) {
                    const files = embedFiles(paths);
                    result[idx] = .{
                        .prefix = "Interface\\AddOns\\" ++ mod.addon_name.? ++ "\\",
                        .files = &files,
                    };
                    idx += 1;
                }
            }
            if (mod.asset_files_opt) |opt| {
                const asset_paths = @field(build_options, opt);
                if (asset_paths.len > 0) {
                    const pfx = assetsPrefixFromOpt(opt);
                    idx = appendAssetPrefixes(&result, idx, asset_paths, pfx);
                }
            }
        }
        const final = result;
        return &final;
    }
}

/// Derive the assets/ path prefix from the option name pattern.
/// "worldmarkers_asset_files" → look at first path to get "markers/assets/"
fn assetsPrefixFromOpt(comptime opt: []const u8) []const u8 {
    const paths = @field(build_options, opt);
    // First path is like "markers/assets/Spells/foo.m2" — find "/assets/" to get prefix
    const first = paths[0];
    for (first, 0..) |_, i| {
        if (i + 8 <= first.len and eqlSlice(first[i .. i + 8], "/assets/")) {
            return first[0 .. i + 8]; // e.g. "markers/assets/"
        }
    }
    return first; // fallback
}

fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Count unique parent directories in asset paths.
fn countUniqueAssetDirs(comptime paths: []const []const u8, comptime assets_prefix: []const u8) usize {
    var dirs: [paths.len][]const u8 = undefined;
    var n: usize = 0;
    for (paths) |path| {
        const dir = comptimeWowDir(path, assets_prefix);
        if (dir.len == 0) continue;
        var found = false;
        for (dirs[0..n]) |d| {
            if (eqlSlice(d, dir)) {
                found = true;
                break;
            }
        }
        if (!found) {
            dirs[n] = dir;
            n += 1;
        }
    }
    return n;
}

/// Append asset prefix entries grouped by WoW directory.
fn appendAssetPrefixes(result: anytype, start_idx: usize, comptime paths: []const []const u8, comptime assets_prefix: []const u8) usize {
    comptime {
        // Collect unique directories
        var dirs: [paths.len][]const u8 = undefined;
        var n_dirs: usize = 0;
        for (paths) |path| {
            const dir = comptimeWowDir(path, assets_prefix);
            if (dir.len == 0) continue;
            var found = false;
            for (dirs[0..n_dirs]) |d| {
                if (eqlSlice(d, dir)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                dirs[n_dirs] = dir;
                n_dirs += 1;
            }
        }

        var idx = start_idx;
        for (dirs[0..n_dirs]) |dir| {
            // Count files in this directory
            var file_count: usize = 0;
            for (paths) |path| {
                if (eqlSlice(comptimeWowDir(path, assets_prefix), dir)) file_count += 1;
            }
            // Build file entries for this group
            var files: [file_count]FileEntry = undefined;
            var fi: usize = 0;
            for (paths) |path| {
                if (eqlSlice(comptimeWowDir(path, assets_prefix), dir)) {
                    files[fi] = .{ .name = comptimeBasename(path), .data = @embedFile(path) };
                    fi += 1;
                }
            }
            const final_files = files;
            result[idx] = .{ .prefix = dir, .files = &final_files };
            idx += 1;
        }
        return idx;
    }
}

const addon_prefixes = buildAllPrefixes();

fn findEmbeddedFile(path: [*:0]const u8) ?*const FileEntry {
    const path_span = std.mem.span(path);

    for (addon_prefixes) |*addon| {
        if (path_span.len <= addon.prefix.len) continue;

        // Case-insensitive prefix check
        var prefix_match = true;
        for (path_span[0..addon.prefix.len], addon.prefix) |a, b| {
            const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (la != lb) {
                prefix_match = false;
                break;
            }
        }
        if (!prefix_match) continue;

        const relative = path_span[addon.prefix.len..];
        for (addon.files) |*entry| {
            if (relative.len != entry.name.len) continue;
            var match = true;
            for (relative, entry.name) |a, b| {
                const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (la != lb) {
                    match = false;
                    break;
                }
            }
            if (match) return entry;
        }
    }
    return null;
}

// =============================================================================
// Hook: LoadFileWithTextureResourceFallback (0x648620)
// =============================================================================

const LoadFileFn = fn (u32, [*:0]const u8, *?[*]u8, ?*u32, u32, u32, u32) callconv(sc) u32;
var file_hook: hook.Detour(LoadFileFn) = .{};

fn loadFileDetour(
    unk: u32,
    path: [*:0]const u8,
    buf_out: *?[*]u8,
    size_out: ?*u32,
    extra_alloc: u32,
    flags: u32,
    async_ptr: u32,
) callconv(sc) u32 {
    if (findEmbeddedFile(path)) |entry| {
        const data_len: u32 = @intCast(entry.data.len);
        const total = data_len + extra_alloc;
        const buf = allocateGameBuffer(total) orelse return 0;

        @memcpy(buf[0..entry.data.len], entry.data);

        if (extra_alloc > 0) {
            @memset(buf[entry.data.len..][0..extra_alloc], 0);
        }

        buf_out.* = buf;
        if (size_out) |s| s.* = data_len;
        con.fmt("[file] served embedded: {s} ({d} bytes)\n", .{ std.mem.span(path), data_len });
        return 1;
    }

    return file_hook.callOriginal(.{ unk, path, buf_out, size_out, extra_alloc, flags, async_ptr });
}

// =============================================================================
// In-memory file serving hooks (Storm file I/O layer)
// =============================================================================
//
// M2 model loading bypasses our LoadFileWithTextureResourceFallback hook.
// These hooks intercept at the lower Storm file I/O level (openFileWithOptions
// and friends) to create fake file contexts for embedded files and serve data
// from memory.
//
// Fake context detection: type==0, handle(+0x04)==NULL, embedded_ptr(+0x30)!=0

const OpenFileFn = fn (u32, [*:0]const u8, u32, *u32) callconv(sc) u32;
var open_file_hook: hook.Detour(OpenFileFn) = .{};

const GetFileSizeFn = fn (u32, ?*u32) callconv(sc) u32;
var get_file_size_hook: hook.Detour(GetFileSizeFn) = .{};

const ReadFileFn = fn (u32, [*]u8, u32, ?*u32, u32, u32) callconv(sc) u32;
var read_file_hook: hook.Detour(ReadFileFn) = .{};

const CleanupFileFn = fn (u32) callconv(sc) void;
var cleanup_file_handle_hook: hook.Detour(CleanupFileFn) = .{};

const ProcessAsyncFn = fn (u32) callconv(fc) void;
var process_async_hook: hook.Detour(ProcessAsyncFn) = .{};

const tc: std.builtin.CallingConvention = .{ .x86_thiscall = .{} };
const LoadModelFn = fn (u32, u32, u32) callconv(tc) u32;
var model_load_hook: hook.Detour(LoadModelFn) = .{};

// Windows API imports for async handling
extern "kernel32" fn EnterCriticalSection(lpCriticalSection: *anyopaque) callconv(WINAPI) void;
extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: *anyopaque) callconv(WINAPI) void;
extern "kernel32" fn SetEvent(hEvent: *anyopaque) callconv(WINAPI) i32;

/// Check if a file context is one of our fakes
fn isFakeFileContext(ctx_addr: u32) bool {
    if (ctx_addr < 0x10000) return false;
    return hook.readMem(u32, ctx_addr) == 0 and // type == 0 (disk)
        hook.readMem(u32, ctx_addr + 0x04) == 0 and // handle == NULL
        hook.readMem(u32, ctx_addr + 0x30) != 0; // embedded ptr set
}

/// Call initializeFileContext (0x647290) - __thiscall(ECX=ctx, type)
fn callInitFileContext(ctx: [*]u8, file_type: u32) void {
    asm volatile (
        \\push %[ftype]
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(ctx)),
          [ftype] "r" (file_type),
          [func] "r" (@as(u32, 0x647290)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

/// Call cleanupFileContext (0x6472d0) - __thiscall(ECX=ctx)
fn callCleanupFileContext(ctx: [*]u8) void {
    asm volatile (
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(ctx)),
          [func] "r" (@as(u32, 0x6472d0)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

/// Free a buffer via FreeMemory/SMemFree (0x646430) - __stdcall(ptr, src, flags)
fn freeGameBuffer(ptr: [*]u8) void {
    asm volatile (
        \\push $0xffffffff
        \\push %[src]
        \\push %[ptr]
        \\call *%[func]
        :
        : [ptr] "r" (@intFromPtr(ptr)),
          [src] "r" (@intFromPtr(@as([*:0]const u8, "weirdutils"))),
          [func] "r" (@as(u32, 0x646430)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

// --- Hook 1: openFileWithOptions (0x6477c0) ---

fn openFileDetour(
    archive_ptr: u32,
    path: [*:0]const u8,
    flags: u32,
    handle_out: *u32,
) callconv(sc) u32 {
    if (findEmbeddedFile(path)) |entry| {
        // Allocate and zero-fill 0x60-byte file context
        const ctx = allocateGameBuffer(0x60) orelse {
            handle_out.* = 0;
            return 0;
        };
        @memset(ctx[0..0x60], 0);

        // Initialize critical section and set type=0
        callInitFileContext(ctx, 0);

        // Store embedded data pointer and size in unused fields
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(ctx) + 0x30)).* = @intCast(@intFromPtr(entry.data.ptr));
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(ctx) + 0x34)).* = @intCast(entry.data.len);

        // Duplicate path string at +0x0C for game's use
        const path_span = std.mem.span(path);
        const path_len: u32 = @intCast(path_span.len + 1);
        if (allocateGameBuffer(path_len)) |path_buf| {
            @memcpy(path_buf[0..path_span.len], path_span);
            path_buf[path_span.len] = 0;
            @as(*align(1) u32, @ptrFromInt(@intFromPtr(ctx) + 0x0C)).* = @intFromPtr(path_buf);
        }

        handle_out.* = @intFromPtr(ctx);
        con.fmt("[file] fake ctx @0x{x}: {s} ({d} bytes)\n", .{ @intFromPtr(ctx), path_span, entry.data.len });
        return 2; // success (non-zero type code)
    }

    return open_file_hook.callOriginal(.{ archive_ptr, path, flags, handle_out });
}

// --- Hook 2: GetFileSizeFromHandle (0x6487f0) ---

fn getFileSizeDetour(
    file_ctx: u32,
    high_size_out: ?*u32,
) callconv(sc) u32 {
    if (isFakeFileContext(file_ctx)) {
        if (high_size_out) |h| h.* = 0;
        const size = hook.readMem(u32, file_ctx + 0x34);
        con.fmt("[file] getFileSize fake @0x{x} = {d}\n", .{ file_ctx, size });
        return size;
    }

    return get_file_size_hook.callOriginal(.{ file_ctx, high_size_out });
}

// --- Hook 3: ReadFileFromMultipleSources (0x648460) ---

fn readFileDetour(
    ctx: u32,
    buffer: [*]u8,
    size: u32,
    bytes_read_out: ?*u32,
    async_ptr: u32,
    param6: u32,
) callconv(sc) u32 {
    if (isFakeFileContext(ctx)) {
        const data_ptr = hook.readMem(u32, ctx + 0x30);
        const data_size = hook.readMem(u32, ctx + 0x34);
        const read_size = @min(size, data_size);

        con.fmt("[file] readFile fake @0x{x} size={d}/{d} async=0x{x}\n", .{ ctx, read_size, data_size, async_ptr });

        const src: [*]const u8 = @ptrFromInt(data_ptr);
        @memcpy(buffer[0..read_size], src[0..read_size]);

        if (bytes_read_out) |out| out.* = read_size;

        // If async, signal the completion event immediately
        if (async_ptr != 0) {
            const event_handle = hook.readMem(u32, async_ptr + 4);
            if (event_handle != 0) {
                _ = SetEvent(@ptrFromInt(event_handle));
            }
        }

        return 1; // success
    }

    return read_file_hook.callOriginal(.{ ctx, buffer, size, bytes_read_out, async_ptr, param6 });
}

// --- Hook 4: processAsyncFileOperation (0x647350) ---

fn processAsyncDetour(param1: u32) callconv(fc) void {
    const ctx_addr = hook.readMem(u32, param1 + 0x08);

    if (isFakeFileContext(ctx_addr)) {
        // Enter critical section (same as original prologue)
        EnterCriticalSection(@ptrFromInt(ctx_addr + 0x24));

        // Read request fields
        const dest = hook.readMem(u32, param1 + 0x0C);
        const req_size = hook.readMem(u32, param1 + 0x10);
        const data_ptr = hook.readMem(u32, ctx_addr + 0x30);
        const data_size = hook.readMem(u32, ctx_addr + 0x34);
        const read_size = @min(req_size, data_size);

        // Copy embedded data to destination buffer
        const src: [*]const u8 = @ptrFromInt(data_ptr);
        const dst: [*]u8 = @ptrFromInt(dest);
        @memcpy(dst[0..read_size], src[0..read_size]);

        // Replicate cleanup epilogue from original function:
        // 1. Decrement refcount at *(ctx + 0x5c)
        const rc_addr = ctx_addr + 0x5c;
        const cur_rc = hook.readMem(i32, rc_addr);
        @as(*align(1) i32, @ptrFromInt(rc_addr)).* = cur_rc - 1;

        // 2. Leave critical section
        LeaveCriticalSection(@ptrFromInt(ctx_addr + 0x24));

        // 3. Signal completion event: *(*(param1 + 0x14) + 4)
        const seek_struct = hook.readMem(u32, param1 + 0x14);
        if (seek_struct != 0) {
            const event_handle = hook.readMem(u32, seek_struct + 4);
            if (event_handle != 0) {
                _ = SetEvent(@ptrFromInt(event_handle));
            }
        }

        // 4. If close-after-read flag at *(ctx + 0x58) is set, clean up
        const close_flag = hook.readMem(u32, ctx_addr + 0x58);
        if (close_flag != 0) {
            cleanupFileHandleDetour(ctx_addr);
        }

        return;
    }

    // Not our fake - call original
    process_async_hook.callOriginal(.{param1});
}

// --- Hook 6: CleanupFileHandleResources (0x648730) ---

fn cleanupFileHandleDetour(file_ctx: u32) callconv(sc) void {
    const fake = isFakeFileContext(file_ctx);
    if (fake) {
        const path_ptr = hook.readMem(u32, file_ctx + 0x0C);
        if (path_ptr != 0) {
            const path: [*:0]const u8 = @ptrFromInt(path_ptr);
            con.fmt("[file] cleanup FAKE @0x{x}: {s}\n", .{ file_ctx, std.mem.span(path) });
        } else {
            con.fmt("[file] cleanup FAKE @0x{x}: (no path)\n", .{file_ctx});
        }
    }

    // Always use original CleanupFileHandleResources - it handles fake contexts correctly
    // (NULL-safe checks on +0x04/+0x3C/+0x40/+0x08, then cleanupFileContext + FreeMemory).
    cleanup_file_handle_hook.callOriginal(.{file_ctx});

    if (fake) con.fmt("[file] cleanup FAKE @0x{x} done\n", .{file_ctx});
}

// --- Hook 5: loadModelFromFileAsync (0x71d4e0) ---

fn loadModelAsyncDetour(model: u32, file_handle: u32, should_use_callback: u32) callconv(tc) u32 {

    // file_handle IS the file context address directly (Ghidra shows pointer* but
    // the assembly pushes it directly to GetFileSizeFromHandle - no dereference)
    if (isFakeFileContext(file_handle)) {
        con.fmt("[file] loadModelAsync: model=0x{x} fh=0x{x} cb={d}\n", .{ model, file_handle, should_use_callback });
        const data_ptr = hook.readMem(u32, file_handle + 0x30);
        const data_size = hook.readMem(u32, file_handle + 0x34);
        con.fmt("[file]   embed_ptr=0x{x} embed_size={d}\n", .{ data_ptr, data_size });

        // Toggle callback flag (bit 1 of model+8) based on shouldUseCallback
        const flags = hook.readMem(u32, model + 0x08);
        if (should_use_callback != 0) {
            @as(*align(1) u32, @ptrFromInt(model + 0x08)).* = flags | 2;
        } else {
            @as(*align(1) u32, @ptrFromInt(model + 0x08)).* = flags & ~@as(u32, 2);
        }

        // Store size in model first (original does this before allocation)
        @as(*align(1) u32, @ptrFromInt(model + 0x134)).* = data_size;

        // Allocate buffer via setCullMode (0x71f9a0) - same as original path
        // setCullMode is __fastcall(ECX=size), returns buffer pointer
        const buffer_addr = hook.fastcall(u32, 0x71f9a0, data_size, 0);
        if (buffer_addr == 0) {
            con.print("[file]   setCullMode alloc failed\n");
            return 0;
        }
        con.fmt("[file]   buffer=0x{x}\n", .{buffer_addr});

        // Store buffer in model object
        @as(*align(1) u32, @ptrFromInt(model + 0x130)).* = buffer_addr;

        // Copy embedded data into the allocated buffer
        const buffer: [*]u8 = @ptrFromInt(buffer_addr);
        const src: [*]const u8 = @ptrFromInt(data_ptr);
        @memcpy(buffer[0..data_size], src[0..data_size]);
        con.print("[file]   memcpy done\n");

        // No async task - set task pointer to NULL
        @as(*align(1) u32, @ptrFromInt(model + 0x0c)).* = 0;
        con.print("[file]   task=0 set\n");

        // Match onModelLoadComplete ordering: clean up file handle BEFORE processing.
        // The original async flow does: CleanupFileHandleResources → ReturnAsyncTaskToPool
        // → model+0x0c=0 → processLoadedModelData. We must close the file context before
        // processLoadedModelData runs, because initializeModelResources creates texture
        // async tasks that interact with the file I/O system.
        // Call original CleanupFileHandleResources through the trampoline (bypasses our
        // detour). Must clean up file context before processLoadedModelData runs.
        con.fmt("[file]   cleanup via trampoline fh=0x{x}\n", .{file_handle});
        cleanup_file_handle_hook.callOriginal(.{file_handle});
        con.print("[file]   cleanup done\n");

        // Dump model fields before processLoadedModelData
        con.fmt("[file]   PRE  model+0x0c=0x{x} +0x130=0x{x} +0x134=0x{x} +0x138=0x{x}\n", .{
            hook.readMem(u32, model + 0x0c),
            hook.readMem(u32, model + 0x130),
            hook.readMem(u32, model + 0x134),
            hook.readMem(u32, model + 0x138),
        });

        // Call processLoadedModelData directly - __fastcall(ECX=model)
        con.fmt("[file]   calling processLoadedModelData(0x{x})...\n", .{model});
        const result = hook.fastcall(u32, 0x71d640, model, 0);
        con.print("[file]   processLoadedModelData returned\n");
        con.fmt("[file]   result=0x{x}\n", .{result});

        // Dump model fields after processLoadedModelData - check if texture async task was created
        con.print("[file]   POST dump:\n");
        con.fmt("[file]   POST model+0x0c=0x{x} +0x130=0x{x} +0x134=0x{x} +0x138=0x{x}\n", .{
            hook.readMem(u32, model + 0x0c),
            hook.readMem(u32, model + 0x130),
            hook.readMem(u32, model + 0x134),
            hook.readMem(u32, model + 0x138),
        });

        con.fmt("[file]   sync loaded {d} bytes, returning 1\n", .{data_size});
        con.print("[file]   === loadModelAsyncDetour EXIT ===\n");
        return 1;
    }

    // Not our fake - call original
    return model_load_hook.callOriginal(.{ model, file_handle, should_use_callback });
}

// --- Hook 6: CheckFileExistence (0x654DD0) ---
// __fastcall(ECX=filename, EDX=flags, stack=outputBuffer) → EAX (bool)
// Tells the game whether a file exists in the VFS. Without this, embedded
// files are invisible to preloadFileWithFlags, so LoadAddonRecursive skips
// Bindings.xml (and SavedVariables) for our addons.

const CheckFileExistenceFn = fn (u32, u32, u32) callconv(fc) u32;
var cfe_hook: hook.Detour(CheckFileExistenceFn) = .{};

fn checkFileExistenceDetour(filename_ptr: u32, flags: u32, output_buffer_ptr: u32) callconv(fc) u32 {
    if (filename_ptr != 0) {
        // Embedded DLL files
        const path: [*:0]const u8 = @ptrFromInt(filename_ptr);
        if (findEmbeddedFile(path) != null) return 1;

        // Loose disk files (customassets module)
        if (build_opts.customassets and customassets.isActive()) {
            if (customassets.looseFilesLookup(filename_ptr, output_buffer_ptr)) return 1;
        }
    }
    return cfe_hook.callOriginal(.{ filename_ptr, flags, output_buffer_ptr });
}

// --- Install/remove in-memory file hooks ---

fn installFileHooks() void {
    _ = open_file_hook.attach(0x6477c0, &openFileDetour);
    _ = get_file_size_hook.attach(0x6487f0, &getFileSizeDetour);
    _ = read_file_hook.attach(0x648460, &readFileDetour);
    _ = cleanup_file_handle_hook.attach(0x648730, &cleanupFileHandleDetour);
    _ = model_load_hook.attach(0x71d4e0, &loadModelAsyncDetour);
    _ = cfe_hook.attach(0x654DD0, &checkFileExistenceDetour);
    con.print("[file] in-memory file hooks installed\n");
}

fn removeFileHooks() void {
    cfe_hook.detach();
    model_load_hook.detach();
    process_async_hook.detach();
    cleanup_file_handle_hook.detach();
    read_file_hook.detach();
    get_file_size_hook.detach();
    open_file_hook.detach();
}

// =============================================================================
// Hook: LoadScriptFunctions (0x490250)
// =============================================================================

var lsf_hook: hook.Detour(fn () callconv(sc) void) = .{};

fn loadScriptFunctionsDetour() callconv(sc) void {
    lsf_hook.callOriginal(.{});
    registerLuaFunctions();
}

// =============================================================================
// Hook: SetupAddonProcessing (0x51C740)
// Called during HandleLogin. After the original runs (which scans Interface\AddOns\
// on the filesystem), we call LoadAddonTOC for each DLL-embedded addon to register
// them in the game's internal addon hash table. This makes the game aware of our
// addons for SavedVariables, Bindings.xml, and proper load ordering.
// =============================================================================

var setup_addons_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

fn setupAddonsDetour(mgr_ptr: u32) callconv(fc) void {
    setup_addons_hook.callOriginal(.{mgr_ptr});

    // Register each embedded addon via LoadAddonTOC. The game reads the .toc
    // file through LoadFileWithTextureResourceFallback, which our loadFileDetour
    // intercepts to serve the embedded content. This populates the addon's
    // SavedVariablesPerCharacter list so the game saves/loads them from WTF/.
    inline for (embed_modules) |mod| {
        if (comptime mod.addon_name == null) continue;
        if (!@field(build_options, "enable_" ++ mod.option)) continue;

        const load = if (comptime std.mem.eql(u8, mod.option, "worldmarkers"))
            markers.isActive()
        else
            true;

        if (load and !mod.hidden) {
            const name: [*:0]const u8 = comptime (mod.addon_name.? ++ "\x00").ptr;
            con.fmt("[addons] registering embedded addon: {s}\n", .{name});
            callLoadAddonTOC(name);
        }
    }
}

/// Call LoadAddonTOC (0x0051c9b0) -- __fastcall(ECX=addonName), RET
fn callLoadAddonTOC(addon_name: [*:0]const u8) void {
    asm volatile (
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(addon_name)),
          [func] "{eax}" (@as(u32, 0x0051c9b0)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Hook: LoadAddonsRecursively (0x51F600)
// Non-hidden addons are fully handled by the game's LoadAddonRecursive (which
// respects enabled/disabled state) — our CheckFileExistence hook makes their
// embedded files visible to preloadFileWithFlags. Hidden addons bypass
// LoadAddonRecursive, so we load their TOC and bindings explicitly here.
// =============================================================================

var load_addons_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

fn loadAddonsDetour(error_handler: u32) callconv(fc) void {
    load_addons_hook.callOriginal(.{error_handler});

    var md5ctx = std.mem.zeroes([88]u8);

    inline for (embed_modules) |mod| {
        if (comptime mod.addon_name == null) continue;
        if (!@field(build_options, "enable_" ++ mod.option)) continue;

        const load = if (comptime std.mem.eql(u8, mod.option, "worldmarkers"))
            markers.isActive()
        else
            true;

        if (load) {
            const addon_name = comptime mod.addon_name.?;
            const paths = comptime @field(build_options, mod.addon_files_opt.?);

            if (mod.hidden) {
                // Hidden addons are not registered via LoadAddonTOC, so the game
                // doesn't know about them. Load their files directly to keep them
                // invisible in the addon list.
                const toc_name = comptime findTocName(paths);
                if (toc_name) |tn| {
                    callLoadFileListWithIncludes(
                        "Interface\\AddOns\\" ++ addon_name ++ "\\" ++ tn,
                        &md5ctx,
                        error_handler,
                    );
                }

                // Hidden addons bypass LoadAddonRecursive, so load bindings
                // explicitly. Non-hidden addons get theirs loaded by the game
                // (which respects addon enabled/disabled state).
                if (comptime hasFile(paths, "Bindings.xml")) {
                    callLoadUIBindingsFromFile(
                        "Interface\\AddOns\\" ++ addon_name ++ "\\Bindings.xml",
                        &md5ctx,
                        error_handler,
                    );
                }
            }
        }
    }
}

/// Find the .toc filename from an addon file path list.
fn findTocName(comptime paths: []const []const u8) ?[]const u8 {
    for (paths) |path| {
        const name = comptimeBasename(path);
        if (name.len >= 4 and eqlSlice(name[name.len - 4 ..], ".toc")) return name;
    }
    return null;
}

/// Check if a filename exists in the path list.
fn hasFile(comptime paths: []const []const u8, comptime target: []const u8) bool {
    for (paths) |path| {
        if (eqlSlice(comptimeBasename(path), target)) return true;
    }
    return false;
}

fn callLoadFileListWithIncludes(toc_path: [*:0]const u8, md5ctx: *[88]u8, error_handler: u32) void {
    asm volatile (
        \\push %[eh]
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(toc_path)),
          [_] "{edx}" (@intFromPtr(md5ctx)),
          [eh] "r" (error_handler),
          [func] "r" (@as(u32, 0x6EDB90)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

fn callLoadUIBindingsFromFile(path: [*:0]const u8, md5ctx: *[88]u8, callback: u32) void {
    const binding_mgr = hook.readMem(u32, 0xB71290);
    asm volatile (
        \\push %[cb]
        \\push %[md5]
        \\push %[path]
        \\call *%[func]
        :
        : [_] "{ecx}" (binding_mgr),
          [func] "{edx}" (@as(u32, 0x4B6F70)),
          [path] "r" (@intFromPtr(path)),
          [md5] "r" (@intFromPtr(md5ctx)),
          [cb] "r" (callback),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });
}

// =============================================================================
// Hook: GameEngine_MainInitialize (0x46a400)
// =============================================================================

var engine_init_hook: hook.Detour(fn () callconv(sc) void) = .{};

fn engineInitDetour() callconv(sc) void {
    engine_init_hook.callOriginal(.{});

    if (build_opts.screenshot) {
        screenshot.installHook();
    }
    if (build_opts.outline) {
        _ = outline.init();
    }
    if (build_opts.healtextfix) {
        healtextfix.lateInit();
    }
    if (build_opts.bigcursor) {
        bigcursor.lateInit();
    }
}

// =============================================================================
// Hook: World_HandleLogoutCleanup (0x491180)
// Fires on real character logout/disconnect only - NOT on /reload or map change.
// =============================================================================

var logout_hook: hook.Detour(fn () callconv(sc) void) = .{};

fn logoutDetour() callconv(sc) void {
    con.print("[weirdutils] World_HandleLogoutCleanup -- player logout\n");

    // Reset per-session state - only on real logout/disconnect, not /reload.
    if (build_opts.worldmarkers) markers.onShutdown();
    if (build_opts.minimapicons) minimapicons.onShutdown();
    if (build_opts.logsessions) logsessions.onShutdown();

    // Clean up world objects BEFORE game teardown - modules with
    // remove_on_shutdown must destroy while game systems are alive.
    comptime var i = modules.len;
    inline while (i > 0) {
        i -= 1;
        const m = modules[i];
        if (m.remove_on_shutdown) {
            if (m.remove) |rm| rm();
        }
    }

    logout_hook.callOriginal(.{});
}

// =============================================================================
// Hook: CGGameUI_Shutdown (0x490BD0)
// =============================================================================

var shutdown_hook: hook.Detour(fn () callconv(sc) void) = .{};

// =============================================================================
// Module lifecycle - single table drives install, shutdown, and uninstall.
// Adding a module here guarantees all three phases are handled.
// =============================================================================

const ModuleHooks = struct {
    name: ?[*:0]const u8 = null,
    install: ?*const fn () void = null,
    remove: ?*const fn () void = null,
    is_active: ?*const fn () bool = null,
    /// If true, remove is also called during CGGameUI_Shutdown (before game
    /// teardown), not just during DLL unload. Use for modules that create
    /// world objects which must be destroyed while game systems are alive.
    remove_on_shutdown: bool = false,
};

/// Order matters: modules are installed top-to-bottom, removed bottom-to-top.
/// Modules with remove_on_shutdown run their remove during shutdownDetour too.
const modules = [_]ModuleHooks{
    if (build_opts.customassets) .{ .name = customassets.module_name, .install = customassets.installHooks, .remove = customassets.removeHooks, .is_active = customassets.isActive } else .{},
    if (build_opts.framecrash) .{ .name = framecrash.module_name, .install = framecrash.installHooks, .remove = framecrash.removeHooks, .is_active = framecrash.isActive } else .{},
    if (build_opts.logsessions) .{ .name = logsessions.module_name, .install = logsessions.installHooks, .remove = logsessions.removeHooks, .is_active = logsessions.isActive } else .{},
    if (build_opts.transmogfix) .{ .name = transmogfix.module_name, .install = transmogfix.installHooks, .remove = transmogfix.removeHooks, .is_active = transmogfix.isActive } else .{},
    if (build_opts.minimapicons) .{ .name = minimapicons.module_name, .install = minimapicons.installHooks, .remove = minimapicons.removeHooks, .is_active = minimapicons.isActive } else .{},
    if (build_opts.healtextfix) .{ .name = healtextfix.module_name, .install = healtextfix.installHooks, .remove = healtextfix.removeHooks, .is_active = healtextfix.isActive } else .{},
    if (build_opts.bigcursor) .{ .name = bigcursor.module_name, .install = bigcursor.installHooks, .remove = bigcursor.removeHooks, .is_active = bigcursor.isActive } else .{},
    if (build_opts.dpslog) .{ .name = dpslog.module_name, .install = dpslog.installHooks, .remove = dpslog.removeHooks, .is_active = dpslog.isActive } else .{},
    if (build_opts.worldmarkers) .{ .name = markers.module_name, .install = markers.installHooks, .remove = markers.removeHooks, .is_active = markers.isActive } else .{},
    if (build_opts.interact) .{ .name = interact.module_name, .install = interact.installHooks, .remove = interact.removeHooks, .is_active = interact.isActive } else .{},
    if (build_opts.outline) .{ .name = outline.module_name, .remove = outline.cleanup, .is_active = outline.isActive } else .{},
    if (build_opts.screenshot) .{ .name = screenshot.module_name, .remove = screenshot.removeHook, .is_active = screenshot.isActive } else .{},
};

fn shutdownDetour() callconv(sc) void {
    con.print("[weirdutils] CGGameUI_Shutdown\n");
    // Per-session resets and remove_on_shutdown cleanup live in logoutDetour
    // (World_HandleLogoutCleanup) - fires on real logout/disconnect only, not /reload.
    shutdown_hook.callOriginal(.{});
}

// =============================================================================
// Init / Cleanup
// =============================================================================

fn install() void {
    con.init();
    con.print("[weirdutils] Installing hooks\n");
    _ = protection_hook.attach(0x42a320, &luaProtectionDetour);
    installFileHooks();
    _ = file_hook.attach(0x648620, &loadFileDetour);
    _ = lsf_hook.attach(0x490250, &loadScriptFunctionsDetour);

    inline for (modules) |m| {
        if (m.install) |inst| inst();
    }

    _ = setup_addons_hook.attach(0x51C740, &setupAddonsDetour);
    _ = load_addons_hook.attach(0x51F600, &loadAddonsDetour);
    _ = engine_init_hook.attach(0x46a400, &engineInitDetour);
    _ = logout_hook.attach(0x491180, &logoutDetour);
    _ = shutdown_hook.attach(0x490BD0, &shutdownDetour);
}

fn uninstall() void {
    shutdown_hook.detach();
    logout_hook.detach();
    engine_init_hook.detach();

    // Remove in reverse order
    comptime var i = modules.len;
    inline while (i > 0) {
        i -= 1;
        if (modules[i].remove) |rm| rm();
    }

    load_addons_hook.detach();
    setup_addons_hook.detach();
    lsf_hook.detach();
    file_hook.detach();
    removeFileHooks();
    protection_hook.detach();
    con.deinit();
}

// =============================================================================
// Runtime Module Control API - exported for other DLLs
// =============================================================================

fn asciiEqlIgnoreCase(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = a[i];
        const cb = b[i];
        if (ca == 0 and cb == 0) return true;
        if (ca == 0 or cb == 0) return false;
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
}

/// Returns 1 if the named module is compiled in AND currently active, 0 otherwise.
fn isModuleActive(name: [*:0]const u8) callconv(.c) i32 {
    inline for (modules) |m| {
        if (m.name) |mod_name| {
            if (asciiEqlIgnoreCase(name, mod_name)) {
                if (m.is_active) |active_fn| {
                    return if (active_fn()) 1 else 0;
                }
                return 0;
            }
        }
    }
    return 0;
}

/// Disables the named module by calling its remove function.
/// Returns 1 if found and removed, 0 if not found or not compiled in.
fn disableModule(name: [*:0]const u8) callconv(.c) i32 {
    inline for (modules) |m| {
        if (m.name) |mod_name| {
            if (asciiEqlIgnoreCase(name, mod_name)) {
                if (m.remove) |rm| {
                    rm();
                    return 1;
                }
                return 0;
            }
        }
    }
    return 0;
}

/// Disables all modules in reverse order, then detaches core hooks.
/// Returns the number of modules that were disabled.
fn disableAll() callconv(.c) i32 {
    var count: i32 = 0;

    // Remove modules in reverse order
    comptime var i = modules.len;
    inline while (i > 0) {
        i -= 1;
        if (modules[i].remove) |rm| {
            rm();
            count += 1;
        }
    }

    // Detach core hooks
    shutdown_hook.detach();
    logout_hook.detach();
    engine_init_hook.detach();
    load_addons_hook.detach();
    setup_addons_hook.detach();
    lsf_hook.detach();
    file_hook.detach();
    removeFileHooks();
    protection_hook.detach();

    return count;
}

comptime {
    @export(&isModuleActive, .{ .name = "WeirdUtils_IsModuleActive" });
    @export(&disableModule, .{ .name = "WeirdUtils_DisableModule" });
    @export(&disableAll, .{ .name = "WeirdUtils_DisableAll" });
}

// =============================================================================
// DLL entry point
// =============================================================================

pub export fn DllMain(
    _: ?*anyopaque,
    reason: u32,
    _: ?*anyopaque,
) callconv(WINAPI) i32 {
    switch (reason) {
        1 => install(),
        0 => uninstall(),
        else => {},
    }
    return 1;
}
