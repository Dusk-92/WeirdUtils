const std = @import("std");
const hook = @import("zhook");
pub const con = @import("console.zig");

// Build options for conditional module compilation
const build_opts = struct {
    const screenshot = @import("build_options").enable_screenshot;
    const interact = @import("build_options").enable_interact;
    const outline = @import("build_options").enable_outline;
    const markers = @import("build_options").enable_markers;
    const framecrash = @import("build_options").enable_framecrash;
    const combatlog = @import("build_options").enable_combatlog;
    const minimapicons = @import("build_options").enable_minimapicons;
    const transmogfix = @import("build_options").enable_transmogfix;
    const assetfix = @import("build_options").enable_assetfix;
    const healtextfix = @import("build_options").enable_healtextfix;
};

// Conditional module imports
const screenshot = if (build_opts.screenshot) @import("screenshot/screenshot.zig") else struct {};
const interact = if (build_opts.interact) @import("interact/interact.zig") else struct {};
const outline = if (build_opts.outline) @import("outline/api.zig") else struct {};
const markers = if (build_opts.markers) @import("markers/markers.zig") else struct {};
const framecrash = if (build_opts.framecrash) @import("framecrash/framecrash.zig") else struct {};
const combatlog = if (build_opts.combatlog) @import("combatlog/combatlog.zig") else struct {};
const minimapicons = if (build_opts.minimapicons) @import("minimapicons/minimapicons.zig") else struct {};
const transmogfix = if (build_opts.transmogfix) @import("transmogfix/transmogfix.zig") else struct {};
const assetfix = if (build_opts.assetfix) @import("assetfix/assetfix.zig") else struct {};
const healtextfix = if (build_opts.healtextfix) @import("healtextfix/healtextfix.zig") else struct {};

const WINAPI = std.builtin.CallingConvention.winapi;
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

// =============================================================================
// Lua Protection Bypass
// =============================================================================

var protection_hook: hook.Detour(fn () callconv(sc) void) = .{};

fn luaProtectionDetour() callconv(sc) void {}

// =============================================================================
// Lua C API wrappers (WoW 1.12.1 — all __fastcall, L in ECX)
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
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true }
    );
}

// =============================================================================
// Custom C functions (callable from Lua)
// =============================================================================

fn weirdUtilsTest(L: lua.State) callconv(.c) u32 {
    hook.fastcall(void, 0x6F3890, @intFromPtr(L), @intFromPtr(@as([*:0]const u8, "WeirdUtils is working!")));
    return 1;
}

fn weirdUtilsVersion(L: lua.State) callconv(.c) u32 {
    asm volatile (
        \\sub $8, %%esp
        \\fld1
        \\fstpl (%%esp)
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(L)),
          [func] "r" (@as(u32, 0x6F3810)),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
    return 1;
}

fn registerLuaFunctions() void {
    // Core functions (always registered)
    registerFunction("WeirdUtilsTest", @intFromPtr(&weirdUtilsTest));
    registerFunction("WeirdUtilsVersion", @intFromPtr(&weirdUtilsVersion));

    // Conditional module functions
    if (build_opts.screenshot) {
        registerFunction("WeirdUtilsScreenshot", @intFromPtr(&screenshot.screenshotCommand));
    }
    if (build_opts.interact) {
        registerFunction("InteractNearest", @intFromPtr(&interact.interactNearest));
        registerFunction("LootAllCorpses", @intFromPtr(&interact.lootAllCorpses));
    }
    if (build_opts.outline) {
        registerFunction("OutlineCommand", @intFromPtr(&outline.outlineCommand));
    }
    if (build_opts.markers and markers.isActive()) {
        registerFunction("WorldMarker", @intFromPtr(&markers.luaWorldMarker));
        registerFunction("ClearWorldMarker", @intFromPtr(&markers.luaClearWorldMarker));
        registerFunction("GetPlayerPosition", @intFromPtr(&markers.luaGetPlayerPosition));
        registerFunction("DistanceToMark", @intFromPtr(&markers.luaDistanceToMark));
        registerFunction("SetMarkerDef", @intFromPtr(&markers.luaSetMarkerDef));
        registerFunction("ClearMarkerDef", @intFromPtr(&markers.luaClearMarkerDef));
        registerFunction("GetMarkerDef", @intFromPtr(&markers.luaGetMarkerDef));
        registerFunction("GetCurrentAreaId", @intFromPtr(&markers.luaGetCurrentAreaId));
    }
}

// =============================================================================
// Embedded addon files
// =============================================================================

const AddonPrefix = struct {
    prefix: []const u8,
    files: []const FileEntry,
};

const FileEntry = struct {
    name: []const u8,
    data: []const u8,
};

// Core addon (always included)
const core_prefix = "Interface\\AddOns\\WeirdUtils\\";
const core_files = [_]FileEntry{
    .{ .name = "WeirdUtils.toc", .data = @embedFile("core/addon/WeirdUtils.toc") },
    .{ .name = "WeirdUtils.lua", .data = @embedFile("core/addon/WeirdUtils.lua") },
};

// Conditional module addons
const screenshot_files = if (build_opts.screenshot) [_]FileEntry{
    .{ .name = "Screenshot.toc", .data = @embedFile("screenshot/addon/Screenshot.toc") },
    .{ .name = "Screenshot.lua", .data = @embedFile("screenshot/addon/Screenshot.lua") },
    .{ .name = "Bindings.xml", .data = @embedFile("screenshot/addon/Bindings.xml") },
} else [_]FileEntry{};

const interact_files = if (build_opts.interact) [_]FileEntry{
    .{ .name = "Interact.toc", .data = @embedFile("interact/addon/Interact.toc") },
    .{ .name = "Interact.lua", .data = @embedFile("interact/addon/Interact.lua") },
    .{ .name = "Bindings.xml", .data = @embedFile("interact/addon/Bindings.xml") },
} else [_]FileEntry{};

const outline_files = if (build_opts.outline) [_]FileEntry{
    .{ .name = "Outline.toc", .data = @embedFile("outline/addon/Outline.toc") },
    .{ .name = "Outline.lua", .data = @embedFile("outline/addon/Outline.lua") },
    .{ .name = "Bindings.xml", .data = @embedFile("outline/addon/Bindings.xml") },
} else [_]FileEntry{};

const markers_files = if (build_opts.markers) [_]FileEntry{
    .{ .name = "Markers.toc", .data = @embedFile("markers/addon/Markers.toc") },
    .{ .name = "Markers.lua", .data = @embedFile("markers/addon/Markers.lua") },
    .{ .name = "Bindings.xml", .data = @embedFile("markers/addon/Bindings.xml") },
} else [_]FileEntry{};

// Marker model + skin + textures served under Spells\ prefix
const markers_spells_assets = if (build_opts.markers) [_]FileEntry{
    // Models (5 colors)
    .{ .name = "Raid_UI_FX_Yellow.m2", .data = @embedFile("markers/assets/Spells/Raid_UI_FX_Yellow.m2") },
    .{ .name = "Raid_UI_FX_Cyan.m2", .data = @embedFile("markers/assets/Spells/Raid_UI_FX_Cyan.m2") },
    .{ .name = "Raid_UI_FX_Green.m2", .data = @embedFile("markers/assets/Spells/Raid_UI_FX_Green.m2") },
    .{ .name = "Raid_UI_FX_Purple.m2", .data = @embedFile("markers/assets/Spells/Raid_UI_FX_Purple.m2") },
    .{ .name = "Raid_UI_FX_Red.m2", .data = @embedFile("markers/assets/Spells/Raid_UI_FX_Red.m2") },
    // Per-model raid target icon textures
    .{ .name = "RaidTarget_Star.blp", .data = @embedFile("markers/assets/Spells/RaidTarget_Star.blp") },
    .{ .name = "RaidTarget_Square.blp", .data = @embedFile("markers/assets/Spells/RaidTarget_Square.blp") },
    .{ .name = "RaidTarget_Triangle.blp", .data = @embedFile("markers/assets/Spells/RaidTarget_Triangle.blp") },
    .{ .name = "RaidTarget_Diamond.blp", .data = @embedFile("markers/assets/Spells/RaidTarget_Diamond.blp") },
    .{ .name = "RaidTarget_X.blp", .data = @embedFile("markers/assets/Spells/RaidTarget_X.blp") },
    // Shared effect textures
    .{ .name = "T_VFX_FLARE05_32ALPHA.BLP", .data = @embedFile("markers/assets/Spells/T_VFX_FLARE05_32ALPHA.BLP") },
    .{ .name = "GRAD2D.BLP", .data = @embedFile("markers/assets/Spells/GRAD2D.BLP") },
    .{ .name = "GRAD2C2.BLP", .data = @embedFile("markers/assets/Spells/GRAD2C2.BLP") },
    .{ .name = "NEXUS_FIREBEAM_FAINT_SQUARE_ORA.BLP", .data = @embedFile("markers/assets/Spells/NEXUS_FIREBEAM_FAINT_SQUARE_ORA.BLP") },
} else [_]FileEntry{};

// Shared effect textures served under World\Expansion01\Doodads\Zulaman\Doors\ prefix
const markers_world_assets = if (build_opts.markers) [_]FileEntry{
    .{ .name = "T_VFX_FIRE03_A.BLP", .data = @embedFile("markers/assets/World/Expansion01/Doodads/Zulaman/Doors/T_VFX_FIRE03_A.BLP") },
    .{ .name = "T_VFX_BORDER6.BLP", .data = @embedFile("markers/assets/World/Expansion01/Doodads/Zulaman/Doors/T_VFX_BORDER6.BLP") },
} else [_]FileEntry{};

// XYZ debug model (renamed to avoid collision with game's built-in xyz.m2)
const markers_xyz_model = if (build_opts.markers) [_]FileEntry{
    .{ .name = "WU_XYZ.m2", .data = @embedFile("markers/assets/Spells/WU_XYZ.m2") },
} else [_]FileEntry{};

// XYZ texture served under World\ArtTest\Boxtest\ (matches M2 internal reference)
const markers_xyz_texture = if (build_opts.markers) [_]FileEntry{
    .{ .name = "xyz.blp", .data = @embedFile("markers/assets/Spells/xyz.blp") },
} else [_]FileEntry{};

// All addon prefixes to check
const addon_prefixes = [_]AddonPrefix{
    .{ .prefix = core_prefix, .files = &core_files },
    .{ .prefix = "Interface\\AddOns\\Screenshot\\", .files = &screenshot_files },
    .{ .prefix = "Interface\\AddOns\\Interact\\", .files = &interact_files },
    .{ .prefix = "Interface\\AddOns\\Outline\\", .files = &outline_files },
    .{ .prefix = "Interface\\AddOns\\Markers\\", .files = &markers_files },
    .{ .prefix = "Spells\\", .files = &markers_spells_assets },
    .{ .prefix = "Spells\\", .files = &markers_xyz_model },
    .{ .prefix = "World\\Expansion01\\Doodads\\Zulaman\\Doors\\", .files = &markers_world_assets },
    .{ .prefix = "World\\ArtTest\\Boxtest\\", .files = &markers_xyz_texture },
};

fn findEmbeddedFile(path: [*:0]const u8) ?*const FileEntry {
    const path_span = std.mem.span(path);

    for (&addon_prefixes) |*addon| {
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

/// Call initializeFileContext (0x647290) — __thiscall(ECX=ctx, type)
fn callInitFileContext(ctx: [*]u8, file_type: u32) void {
    asm volatile (
        \\push %[ftype]
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(ctx)),
          [ftype] "r" (file_type),
          [func] "r" (@as(u32, 0x647290)),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
}

/// Call cleanupFileContext (0x6472d0) — __thiscall(ECX=ctx)
fn callCleanupFileContext(ctx: [*]u8) void {
    asm volatile (
        \\call *%[func]
        :
        : [_] "{ecx}" (@intFromPtr(ctx)),
          [func] "r" (@as(u32, 0x6472d0)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true }
    );
}

/// Free a buffer via FreeMemory/SMemFree (0x646430) — __stdcall(ptr, src, flags)
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
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true }
    );
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

    // Not our fake — call original
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

    // Always use original CleanupFileHandleResources — it handles fake contexts correctly
    // (NULL-safe checks on +0x04/+0x3C/+0x40/+0x08, then cleanupFileContext + FreeMemory).
    cleanup_file_handle_hook.callOriginal(.{file_ctx});

    if (fake) con.fmt("[file] cleanup FAKE @0x{x} done\n", .{file_ctx});
}

// --- Hook 5: loadModelFromFileAsync (0x71d4e0) ---

fn loadModelAsyncDetour(model: u32, file_handle: u32, should_use_callback: u32) callconv(tc) u32 {

    // file_handle IS the file context address directly (Ghidra shows pointer* but
    // the assembly pushes it directly to GetFileSizeFromHandle — no dereference)
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

        // Allocate buffer via setCullMode (0x71f9a0) — same as original path
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

        // No async task — set task pointer to NULL
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
        cleanup_file_handle_hook.original()(file_handle);
        con.print("[file]   cleanup done\n");

        // Dump model fields before processLoadedModelData
        con.fmt("[file]   PRE  model+0x0c=0x{x} +0x130=0x{x} +0x134=0x{x} +0x138=0x{x}\n", .{
            hook.readMem(u32, model + 0x0c),
            hook.readMem(u32, model + 0x130),
            hook.readMem(u32, model + 0x134),
            hook.readMem(u32, model + 0x138),
        });

        // Call processLoadedModelData directly — __fastcall(ECX=model)
        con.fmt("[file]   calling processLoadedModelData(0x{x})...\n", .{model});
        const result = hook.fastcall(u32, 0x71d640, model, 0);
        con.print("[file]   processLoadedModelData returned\n");
        con.fmt("[file]   result=0x{x}\n", .{result});

        // Dump model fields after processLoadedModelData — check if texture async task was created
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

    // Not our fake — call original
    return model_load_hook.callOriginal(.{ model, file_handle, should_use_callback });
}

// --- Install/remove in-memory file hooks ---

fn installFileHooks() void {
    _ = open_file_hook.attach(0x6477c0, &openFileDetour);
    _ = get_file_size_hook.attach(0x6487f0, &getFileSizeDetour);
    _ = read_file_hook.attach(0x648460, &readFileDetour);
    _ = cleanup_file_handle_hook.attach(0x648730, &cleanupFileHandleDetour);
    _ = model_load_hook.attach(0x71d4e0, &loadModelAsyncDetour);
    con.print("[file] in-memory file hooks installed\n");
}

fn removeFileHooks() void {
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
// Hook: LoadAddonsRecursively (0x51F600)
// =============================================================================

var load_addons_hook: hook.Detour(fn (u32) callconv(fc) void) = .{};

fn loadAddonsDetour(error_handler: u32) callconv(fc) void {
    load_addons_hook.callOriginal(.{error_handler});

    var md5ctx = std.mem.zeroes([88]u8);

    // Always load core addon
    callLoadFileListWithIncludes(
        "Interface\\AddOns\\WeirdUtils\\WeirdUtils.toc",
        &md5ctx,
        error_handler,
    );

    // Conditionally load module addons
    if (build_opts.screenshot) {
        callLoadFileListWithIncludes(
            "Interface\\AddOns\\Screenshot\\Screenshot.toc",
            &md5ctx,
            error_handler,
        );
        callLoadUIBindingsFromFile(
            "Interface\\AddOns\\Screenshot\\Bindings.xml",
            &md5ctx,
            error_handler,
        );
    }
    if (build_opts.interact) {
        callLoadFileListWithIncludes(
            "Interface\\AddOns\\Interact\\Interact.toc",
            &md5ctx,
            error_handler,
        );
        callLoadUIBindingsFromFile(
            "Interface\\AddOns\\Interact\\Bindings.xml",
            &md5ctx,
            error_handler,
        );
    }
    if (build_opts.outline) {
        callLoadFileListWithIncludes(
            "Interface\\AddOns\\Outline\\Outline.toc",
            &md5ctx,
            error_handler,
        );
        callLoadUIBindingsFromFile(
            "Interface\\AddOns\\Outline\\Bindings.xml",
            &md5ctx,
            error_handler,
        );
    }
    if (build_opts.markers and markers.isActive()) {
        callLoadFileListWithIncludes(
            "Interface\\AddOns\\Markers\\Markers.toc",
            &md5ctx,
            error_handler,
        );
        callLoadUIBindingsFromFile(
            "Interface\\AddOns\\Markers\\Bindings.xml",
            &md5ctx,
            error_handler,
        );
    }
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
        : .{ .eax = true, .memory = true, .cc = true }
    );
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
        : .{ .eax = true, .memory = true, .cc = true }
    );
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
}

// =============================================================================
// Hook: CGGameUI_Shutdown (0x490BD0)
// =============================================================================

var shutdown_hook: hook.Detour(fn () callconv(sc) void) = .{};

// =============================================================================
// Module lifecycle — single table drives install, shutdown, and uninstall.
// Adding a module here guarantees all three phases are handled.
// =============================================================================

const ModuleHooks = struct {
    install: ?*const fn () void = null,
    remove: ?*const fn () void = null,
    /// If true, remove is also called during CGGameUI_Shutdown (before game
    /// teardown), not just during DLL unload. Use for modules that create
    /// world objects which must be destroyed while game systems are alive.
    remove_on_shutdown: bool = false,
};

/// Order matters: modules are installed top-to-bottom, removed bottom-to-top.
/// Modules with remove_on_shutdown run their remove during shutdownDetour too.
const modules = [_]ModuleHooks{
    if (build_opts.assetfix) .{ .install = assetfix.installHooks, .remove = assetfix.removeHooks } else .{},
    if (build_opts.framecrash) .{ .install = framecrash.installHooks, .remove = framecrash.removeHooks } else .{},
    if (build_opts.combatlog) .{ .install = combatlog.installHooks, .remove = combatlog.removeHooks } else .{},
    if (build_opts.transmogfix) .{ .install = transmogfix.installHooks, .remove = transmogfix.removeHooks } else .{},
    if (build_opts.minimapicons) .{ .install = minimapicons.installHooks, .remove = minimapicons.removeHooks } else .{},
    if (build_opts.healtextfix) .{ .install = healtextfix.installHooks, .remove = healtextfix.removeHooks } else .{},
    if (build_opts.markers) .{ .install = markers.installHooks, .remove = markers.removeHooks } else .{},
    if (build_opts.interact) .{ .install = interact.installHooks, .remove = interact.removeHooks } else .{},
    if (build_opts.outline) .{ .remove = outline.cleanup } else .{},
    if (build_opts.screenshot) .{ .remove = screenshot.removeHook } else .{},
};

fn shutdownDetour() callconv(sc) void {
    // Clear marker definitions on logout/exit (not on map change).
    if (build_opts.markers) markers.onShutdown();

    // Clean up world objects BEFORE game shutdown — atexit handlers run before
    // DllMain so modules with remove_on_shutdown must destroy here.
    comptime var i = modules.len;
    inline while (i > 0) {
        i -= 1;
        const m = modules[i];
        if (m.remove_on_shutdown) {
            if (m.remove) |rm| rm();
        }
    }

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

    _ = load_addons_hook.attach(0x51F600, &loadAddonsDetour);
    _ = engine_init_hook.attach(0x46a400, &engineInitDetour);
    _ = shutdown_hook.attach(0x490BD0, &shutdownDetour);
}

fn uninstall() void {
    shutdown_hook.detach();
    engine_init_hook.detach();

    // Remove in reverse order
    comptime var i = modules.len;
    inline while (i > 0) {
        i -= 1;
        if (modules[i].remove) |rm| rm();
    }

    load_addons_hook.detach();
    lsf_hook.detach();
    file_hook.detach();
    removeFileHooks();
    protection_hook.detach();
    con.deinit();
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
