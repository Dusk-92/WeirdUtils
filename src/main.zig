const std = @import("std");
const hook = @import("zhook");
const logging = @import("logging.zig");
var log: logging.Logger = .{};

// Build options for conditional module compilation
const build_opts = struct {
    const screenshot = @import("build_options").enable_pngscreenshots;
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
    const clickthrough = @import("build_options").enable_clickthrough;
    const dpslog = @import("build_options").enable_dpslog;
    const transform44 = @import("build_options").enable_transform44;
    const addonperf = @import("build_options").enable_addonperf;
    const filecache = @import("build_options").enable_filecache;
    const ssemaths = @import("build_options").enable_ssemaths;
    const silicon = @import("build_options").enable_silicon;
};

// Conditional module imports
const screenshot = if (build_opts.screenshot) @import("screenshot/screenshot.zig") else struct {};
const interact = if (build_opts.interact) @import("interact/interact.zig") else struct {};
const outline = if (build_opts.outline) @import("outline/outline.zig") else struct {};
const markers = if (build_opts.worldmarkers) @import("worldmarkers/worldmarkers.zig") else struct {};
const framecrash = if (build_opts.framecrash) @import("framecrash/framecrash.zig") else struct {};
const logsessions = if (build_opts.logsessions) @import("logsessions/logsessions.zig") else struct {};
const minimapicons = if (build_opts.minimapicons) @import("minimapicons/minimapicons.zig") else struct {};
const transmogfix = if (build_opts.transmogfix) @import("transmogfix/transmogfix.zig") else struct {};
const customassets = if (build_opts.customassets) @import("customassets/customassets.zig") else struct {};
const healtextfix = if (build_opts.healtextfix) @import("healtextfix/healtextfix.zig") else struct {};
const bigcursor = if (build_opts.bigcursor) @import("bigcursor/bigcursor.zig") else struct {};
const clickthrough = if (build_opts.clickthrough) @import("clickthrough/clickthrough.zig") else struct {};
const dpslog = if (build_opts.dpslog) @import("dpslog/dpslog.zig") else struct {};
const transform44 = if (build_opts.transform44) @import("transform44/transform44.zig") else struct {};
const addonperf = if (build_opts.addonperf) @import("addonperf/addonperf.zig") else struct {};
const ssemaths = if (build_opts.ssemaths) @import("ssemaths/ssemaths.zig") else struct {};
const file_cache = if (build_opts.filecache) @import("filecache/filecache.zig") else struct {};
const silicon = if (build_opts.silicon) @import("silicon/silicon.zig") else struct {};

const module_active = @import("module_active.zig");

const WINAPI = std.builtin.CallingConvention.winapi;

// =============================================================================
// Lua Protection Bypass
// =============================================================================

var protection_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

fn luaProtectionDetour() callconv(hook.cc.stdcall) void {}

// =============================================================================
// Lua C API wrappers (WoW 1.12.1 - all __fastcall, L in ECX)
// =============================================================================

pub const lua = @import("lua.zig");

// =============================================================================
// Game function wrappers
// =============================================================================

fn registerFunction(name: [*:0]const u8, func_addr: usize) void {
    hook.call(fn ([*:0]const u8, usize) callconv(hook.cc.fastcall) void, 0x704120, .{ name, func_addr });
}

fn allocateGameBuffer(size: u32) ?[*]u8 {
    return hook.call(fn (u32, u32, u32, u32) callconv(hook.cc.stdcall) ?[*]u8, 0x6462E0, .{
        size, @intFromPtr(@as([*:0]const u8, "weirdutils")), 0, 0,
    });
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
        const lib = [_]lua.LuaReg{
            .{ .name = "SetObjectTypeBlip", .func = @intFromPtr(&minimapicons.luaSetObjectTypeBlip) },
            .{ .name = "SetMinimapCityToggle", .func = @intFromPtr(&minimapicons.luaSetCityToggle) },
            .{ .name = null, .func = 0 },
        };
        lua.openlib(lua.getContext(), "WeirdUtils", &lib, 0);
    }
    if (build_opts.transform44) {
        registerFunction("SetWeatherOverride", @intFromPtr(&transform44.luaSetWeatherOverride));
    }
    if (build_opts.dpslog) {
        registerFunction("GetSpellInfo", @intFromPtr(&dpslog.luaGetSpellInfo));
    }
    if (build_opts.addonperf) {
        registerFunction("GetAddOnMemoryUsage", @intFromPtr(&addonperf.luaGetAddOnMemoryUsage));
        registerFunction("UpdateAddOnMemoryUsage", @intFromPtr(&addonperf.luaUpdateAddOnMemoryUsage));
        registerFunction("GetAddOnCPUUsage", @intFromPtr(&addonperf.luaGetAddOnCPUUsage));
        registerFunction("UpdateAddOnCPUUsage", @intFromPtr(&addonperf.luaUpdateAddOnCPUUsage));
        registerFunction("ResetAddOnCPUUsage", @intFromPtr(&addonperf.luaResetAddOnCPUUsage));
        registerFunction("GetScriptCPUUsage", @intFromPtr(&addonperf.luaGetScriptCPUUsage));
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
// Module version registry — GetWeirdUtilsVersion(name?) from Lua
// =============================================================================
//
// Populates a global "WeirdUtils" table with { module_name = "version", ... }
// for each enabled module. If the table already exists (from another DLL),
// new entries are merged in additively.
//
// GetWeirdUtilsVersion()        → returns the full WeirdUtils table
// GetWeirdUtilsVersion("name")  → returns version string for that module, or nil

const all_module_names = @import("build_options").all_module_names;
const all_module_versions = @import("build_options").all_module_versions;

fn registerModuleVersions() void {
    const L = lua.getContext();

    // Get or create the WeirdUtils global table
    lua.getglobal(L, "WeirdUtils");
    if (lua.typeOf(L, -1) != 5) { // 5 = LUA_TTABLE
        lua.pop(L, 1);
        lua.newtable(L);
    }

    // For each enabled module, set WeirdUtils[name] = version
    inline for (all_module_names, 0..) |name, i| {
        const enabled = @field(@import("build_options"), "enable_" ++ name);
        if (enabled) {
            lua.pushstring(L, @ptrCast(name.ptr));
            lua.pushstring(L, @ptrCast(all_module_versions[i].ptr));
            lua.settable(L, -3);
        }
    }

    // Set as global
    lua.setglobal(L, "WeirdUtils");

    // Register query function
    registerFunction("GetWeirdUtilsVersion", @intFromPtr(&luaGetWeirdUtilsVersion));
}

fn luaGetWeirdUtilsVersion(L_ecx: usize) callconv(hook.cc.fastcall) u32 {
    const L: lua.State = @ptrFromInt(L_ecx);
    const nargs = lua.gettop(L);

    if (nargs >= 1 and lua.isstring(L, 1)) {
        // GetWeirdUtilsVersion("name") → return version or nil
        const name = lua.tostring(L, 1) orelse {
            lua.pushnil(L);
            return 1;
        };
        lua.getglobal(L, "WeirdUtils");
        if (lua.typeOf(L, -1) != 5) {
            lua.pop(L, 1);
            lua.pushnil(L);
            return 1;
        }
        lua.pushstring(L, name);
        lua.gettable(L, -2);
        lua.remove(L, -2); // remove WeirdUtils table, leave value
        return 1;
    }

    // GetWeirdUtilsVersion() → return the whole table
    lua.getglobal(L, "WeirdUtils");
    return 1;
}

// =============================================================================
// Embedded addon files
// =============================================================================

const build_options = @import("build_options");
const addons = @import("addons.zig");
const findEmbeddedFile = addons.findEmbeddedFile;

// =============================================================================
// Hook: LoadFileWithTextureResourceFallback (0x648620)
// =============================================================================

const LoadFileFn = fn (u32, [*:0]const u8, *?[*]u8, ?*u32, u32, u32, u32) callconv(hook.cc.stdcall) u32;
var file_hook: hook.Detour(LoadFileFn) = .{};

fn loadFileDetour(
    unk: u32,
    path: [*:0]const u8,
    buf_out: *?[*]u8,
    size_out: ?*u32,
    extra_alloc: u32,
    flags: u32,
    async_ptr: u32,
) callconv(hook.cc.stdcall) u32 {
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
        log.fmt("served embedded: {s} ({d} bytes)\n", .{ std.mem.span(path), data_len });
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

const OpenFileFn = fn (u32, [*:0]const u8, u32, *u32) callconv(hook.cc.stdcall) u32;
var open_file_hook: hook.Detour(OpenFileFn) = .{};

const GetFileSizeFn = fn (u32, ?*u32) callconv(hook.cc.stdcall) u32;
var get_file_size_hook: hook.Detour(GetFileSizeFn) = .{};

const ReadFileFn = fn (u32, [*]u8, u32, ?*u32, u32, u32) callconv(hook.cc.stdcall) u32;
var read_file_hook: hook.Detour(ReadFileFn) = .{};

const CleanupFileFn = fn (u32) callconv(hook.cc.stdcall) void;
var cleanup_file_handle_hook: hook.Detour(CleanupFileFn) = .{};

const ProcessAsyncFn = fn (u32) callconv(hook.cc.fastcall) void;
var process_async_hook: hook.Detour(ProcessAsyncFn) = .{};

const LoadModelFn = fn (u32, u32, u32) callconv(hook.cc.thiscall) u32;
var model_load_hook: hook.Detour(LoadModelFn) = .{};

// File_FindInArchive (0x6549a0) — Storm internal MPQ file lookup
// __fastcall(ECX=archive_or_group, EDX=filename, stack: flags, out_inner_archive,
//            out_outer_archive, out_block_entry, out_disk_path) → int
// Returns: 0=not found, 1=found in MPQ, 2=found on disk, 3=deleted
const FileFindFn = fn (u32, u32, u32, u32, u32, u32, u32) callconv(hook.cc.fastcall) u32;
var file_find_hook: hook.Detour(FileFindFn) = .{};

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
    hook.call(fn (u32, u32) callconv(hook.cc.thiscall) void, 0x647290, .{ @intFromPtr(ctx), file_type });
}

/// Call cleanupFileContext (0x6472d0) - __thiscall(ECX=ctx)
fn callCleanupFileContext(ctx: [*]u8) void {
    hook.call(fn (u32) callconv(hook.cc.thiscall) void, 0x6472d0, .{@intFromPtr(ctx)});
}

/// Free a buffer via FreeMemory/SMemFree (0x646430) - __stdcall(ptr, src, flags)
fn freeGameBuffer(ptr: [*]u8) void {
    hook.call(fn (u32, u32, u32) callconv(hook.cc.stdcall) void, 0x646430, .{
        @intFromPtr(ptr), @intFromPtr(@as([*:0]const u8, "weirdutils")), 0xffffffff,
    });
}

// --- Hook 1: openFileWithOptions (0x6477c0) ---

fn openFileDetour(
    archive_ptr: u32,
    path: [*:0]const u8,
    flags: u32,
    handle_out: *u32,
) callconv(hook.cc.stdcall) u32 {
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
        log.fmt("fake ctx @0x{x}: {s} ({d} bytes)\n", .{ @intFromPtr(ctx), path_span, entry.data.len });
        return 2; // success (non-zero type code)
    }

    return open_file_hook.callOriginal(.{ archive_ptr, path, flags, handle_out });
}

// --- Hook 2: GetFileSizeFromHandle (0x6487f0) ---

fn getFileSizeDetour(
    file_ctx: u32,
    high_size_out: ?*u32,
) callconv(hook.cc.stdcall) u32 {
    if (isFakeFileContext(file_ctx)) {
        if (high_size_out) |h| h.* = 0;
        const size = hook.readMem(u32, file_ctx + 0x34);
        log.fmt("getFileSize fake @0x{x} = {d}\n", .{ file_ctx, size });
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
) callconv(hook.cc.stdcall) u32 {
    if (isFakeFileContext(ctx)) {
        const data_ptr = hook.readMem(u32, ctx + 0x30);
        const data_size = hook.readMem(u32, ctx + 0x34);
        const read_size = @min(size, data_size);

        log.fmt("readFile fake @0x{x} size={d}/{d} async=0x{x}\n", .{ ctx, read_size, data_size, async_ptr });

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

fn processAsyncDetour(param1: u32) callconv(hook.cc.fastcall) void {
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

fn cleanupFileHandleDetour(file_ctx: u32) callconv(hook.cc.stdcall) void {
    const fake = isFakeFileContext(file_ctx);
    if (fake) {
        const path_ptr = hook.readMem(u32, file_ctx + 0x0C);
        if (path_ptr != 0) {
            const path: [*:0]const u8 = @ptrFromInt(path_ptr);
            log.fmt("cleanup FAKE @0x{x}: {s}\n", .{ file_ctx, std.mem.span(path) });
        } else {
            log.fmt("cleanup FAKE @0x{x}: (no path)\n", .{file_ctx});
        }
    }

    // Always use original CleanupFileHandleResources - it handles fake contexts correctly
    // (NULL-safe checks on +0x04/+0x3C/+0x40/+0x08, then cleanupFileContext + FreeMemory).
    cleanup_file_handle_hook.callOriginal(.{file_ctx});

    if (fake) log.fmt("cleanup FAKE @0x{x} done\n", .{file_ctx});
}

// --- Hook 5: loadModelFromFileAsync (0x71d4e0) ---

fn loadModelAsyncDetour(model: u32, file_handle: u32, should_use_callback: u32) callconv(hook.cc.thiscall) u32 {

    // file_handle IS the file context address directly (Ghidra shows pointer* but
    // the assembly pushes it directly to GetFileSizeFromHandle - no dereference)
    if (isFakeFileContext(file_handle)) {
        log.fmt("loadModelAsync: model=0x{x} fh=0x{x} cb={d}\n", .{ model, file_handle, should_use_callback });
        const data_ptr = hook.readMem(u32, file_handle + 0x30);
        const data_size = hook.readMem(u32, file_handle + 0x34);
        log.fmt("  embed_ptr=0x{x} embed_size={d}\n", .{ data_ptr, data_size });

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
        const buffer_addr = hook.call(fn (u32) callconv(hook.cc.fastcall) u32, 0x71f9a0, .{data_size});
        if (buffer_addr == 0) {
            log.print("  setCullMode alloc failed\n");
            return 0;
        }
        log.fmt("  buffer=0x{x}\n", .{buffer_addr});

        // Store buffer in model object
        @as(*align(1) u32, @ptrFromInt(model + 0x130)).* = buffer_addr;

        // Copy embedded data into the allocated buffer
        const buffer: [*]u8 = @ptrFromInt(buffer_addr);
        const src: [*]const u8 = @ptrFromInt(data_ptr);
        @memcpy(buffer[0..data_size], src[0..data_size]);
        log.print("  memcpy done\n");

        // No async task - set task pointer to NULL
        @as(*align(1) u32, @ptrFromInt(model + 0x0c)).* = 0;
        log.print("  task=0 set\n");

        // Match onModelLoadComplete ordering: clean up file handle BEFORE processing.
        // The original async flow does: CleanupFileHandleResources → ReturnAsyncTaskToPool
        // → model+0x0c=0 → processLoadedModelData. We must close the file context before
        // processLoadedModelData runs, because initializeModelResources creates texture
        // async tasks that interact with the file I/O system.
        // Call original CleanupFileHandleResources through the trampoline (bypasses our
        // detour). Must clean up file context before processLoadedModelData runs.
        log.fmt("  cleanup via trampoline fh=0x{x}\n", .{file_handle});
        cleanup_file_handle_hook.callOriginal(.{file_handle});
        log.print("  cleanup done\n");

        // Dump model fields before processLoadedModelData
        log.fmt("  PRE  model+0x0c=0x{x} +0x130=0x{x} +0x134=0x{x} +0x138=0x{x}\n", .{
            hook.readMem(u32, model + 0x0c),
            hook.readMem(u32, model + 0x130),
            hook.readMem(u32, model + 0x134),
            hook.readMem(u32, model + 0x138),
        });

        // Call processLoadedModelData directly - __fastcall(ECX=model)
        log.fmt("  calling processLoadedModelData(0x{x})...\n", .{model});
        const result = hook.call(fn (u32) callconv(hook.cc.fastcall) u32, 0x71d640, .{model});
        log.print("  processLoadedModelData returned\n");
        log.fmt("  result=0x{x}\n", .{result});

        // Dump model fields after processLoadedModelData - check if texture async task was created
        log.print("  POST dump:\n");
        log.fmt("  POST model+0x0c=0x{x} +0x130=0x{x} +0x134=0x{x} +0x138=0x{x}\n", .{
            hook.readMem(u32, model + 0x0c),
            hook.readMem(u32, model + 0x130),
            hook.readMem(u32, model + 0x134),
            hook.readMem(u32, model + 0x138),
        });

        log.fmt("  sync loaded {d} bytes, returning 1\n", .{data_size});
        log.print("  === loadModelAsyncDetour EXIT ===\n");
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

const CheckFileExistenceFn = fn (u32, u32, u32) callconv(hook.cc.fastcall) u32;
var cfe_hook: hook.Detour(CheckFileExistenceFn) = .{};

fn checkFileExistenceDetour(filename_ptr: u32, flags: u32, output_buffer_ptr: u32) callconv(hook.cc.fastcall) u32 {
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

// --- Hook 7: File_FindInArchive (0x6549a0) — archive cache short-circuit ---
// Intercepts the core MPQ file lookup to skip both chain walk and hash lookup
// on repeat opens. Caches {outer_archive, inner_archive, block_entry} per file.
//
// Called from two paths during each open:
// 1. FindFileInArchive wrapper (param_1=0): walks all archives, uses param_5 for output
// 2. File_FindInStorage (param_1=specific): single archive, uses param_4 + param_6
//
// We cache on path 2 (has all data), serve both paths from cache on subsequent opens.

fn fileFindDetour(
    archive_or_group: u32, // ECX: 0 = search all, else specific archive/group
    filename_ptr: u32, // EDX: filename string
    flags: u32,
    out_inner_archive: u32, // ptr to ptr: inner archive (File_FindInStorage uses this)
    out_outer_archive: u32, // ptr to ptr: outer archive (FindFileInArchive wrapper uses this)
    out_block_entry: u32, // ptr to ptr: block table entry data
    out_disk_path: u32, // ptr to buf: disk path output
) callconv(hook.cc.fastcall) u32 {
    if (!build_opts.filecache or filename_ptr == 0)
        return file_find_hook.callOriginal(.{ archive_or_group, filename_ptr, flags, out_inner_archive, out_outer_archive, out_block_entry, out_disk_path });

    const tsc_start = file_cache.rdtsc();
    const path: [*:0]const u8 = @ptrFromInt(filename_ptr);
    const h = file_cache.hashPath(path);

    cache_check: {
        const cached = file_cache.archiveCacheLookup(h, path) orelse break :cache_check;

        if (cached.is_negative and archive_or_group == 0) {
            file_cache.recordNegativeHit();
            if (out_outer_archive != 0) @as(*align(1) u32, @ptrFromInt(out_outer_archive)).* = 0;
            if (out_inner_archive != 0) @as(*align(1) u32, @ptrFromInt(out_inner_archive)).* = 0;
            if (out_block_entry != 0) @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = 0;
            hook.call(fn (u32) callconv(hook.cc.stdcall) void, 0x64e850, .{2});
            file_cache.addHitCycles(file_cache.rdtsc() - tsc_start);
            return 0;
        }

        if (!cached.is_negative) {
            // Path 1: search-all
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
                    @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = file_cache.computeBlockEntry(cached.inner_archive, cached.block_index);
                }
                file_cache.recordCacheHit();
                file_cache.addHitCycles(file_cache.rdtsc() - tsc_start);
                return 1;
            }

            // Path 2: specific archive
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
                    @as(*align(1) u32, @ptrFromInt(out_block_entry)).* = file_cache.computeBlockEntry(cached.inner_archive, cached.block_index);
                }
                file_cache.recordCacheHit();
                file_cache.addHitCycles(file_cache.rdtsc() - tsc_start);
                return 1;
            }
        }
    }

    // Cache miss — call original and populate cache
    file_cache.recordCacheMiss();
    const ret = file_find_hook.callOriginal(.{ archive_or_group, filename_ptr, flags, out_inner_archive, out_outer_archive, out_block_entry, out_disk_path });
    file_cache.addMissCycles(file_cache.rdtsc() - tsc_start);

    if (archive_or_group != 0 and out_inner_archive != 0 and out_block_entry != 0) {
        if (ret == 1) {
            const inner = hook.readMem(u32, out_inner_archive);
            const block = hook.readMem(u32, out_block_entry);
            file_cache.archiveCacheInsert(h, path, archive_or_group, inner, block, false);
        }
    }
    if (archive_or_group == 0 and ret == 0) {
        file_cache.archiveCacheInsert(h, path, 0, 0, 0, true);
    }

    return ret;
}

// --- Install/remove in-memory file hooks ---

fn installFileHooks() void {
    _ = open_file_hook.attach(0x6477c0, &openFileDetour);
    _ = get_file_size_hook.attach(0x6487f0, &getFileSizeDetour);
    _ = read_file_hook.attach(0x648460, &readFileDetour);
    _ = cleanup_file_handle_hook.attach(0x648730, &cleanupFileHandleDetour);
    _ = model_load_hook.attach(0x71d4e0, &loadModelAsyncDetour);
    _ = cfe_hook.attach(0x654DD0, &checkFileExistenceDetour);
    if (build_opts.filecache) {
        _ = file_find_hook.attach(0x6549a0, &fileFindDetour);
        log.print("archive cache hook installed\n");
    }
    log.print("in-memory file hooks installed\n");
}

fn removeFileHooks() void {
    file_find_hook.detach();
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

var register_commands_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};
var glue_commands_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

/// Hook for Player_LoadScriptFunctions (0x490250).
/// Fires after login/reload — registers gameplay Lua functions + version table.
fn registerAllSystemCommandsDetour() callconv(hook.cc.stdcall) void {
    register_commands_hook.callOriginal(.{});
    registerLuaFunctions();
    registerModuleVersions();
}

/// Hook for Glue_LoadScriptFunctions (0x46ABB0).
/// Fires at the login/glue screen — registers version table so addons can query early.
fn glueLoadScriptFunctionsDetour() callconv(hook.cc.stdcall) void {
    glue_commands_hook.callOriginal(.{});
    registerModuleVersions();
}

// =============================================================================
// Hook: GameEngine_MainInitialize (0x46a400)
// =============================================================================

var engine_init_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

fn engineInitDetour() callconv(hook.cc.stdcall) void {
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
    if (build_opts.transform44) {
        transform44.lateInit();
    }
    if (build_opts.ssemaths) {
        ssemaths.lateInit();
    }
    if (build_opts.silicon) {
        silicon.lateInit();
    }
}

// =============================================================================
// Hook: World_HandleLogoutCleanup (0x491180)
// Fires on real character logout/disconnect only - NOT on /reload or map change.
// =============================================================================

var logout_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

fn logoutDetour() callconv(hook.cc.stdcall) void {
    log.print("World_HandleLogoutCleanup -- player logout\n");

    // Reset per-session state - only on real logout/disconnect, not /reload.
    if (build_opts.worldmarkers) markers.onShutdown();
    if (build_opts.minimapicons) minimapicons.onShutdown();
    if (build_opts.clickthrough) clickthrough.onShutdown();
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

var shutdown_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

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
    if (build_opts.clickthrough) .{ .name = clickthrough.module_name, .install = clickthrough.installHooks, .remove = clickthrough.removeHooks, .is_active = clickthrough.isActive } else .{},
    if (build_opts.dpslog) .{ .name = dpslog.module_name, .install = dpslog.installHooks, .remove = dpslog.removeHooks, .is_active = dpslog.isActive } else .{},
    if (build_opts.transform44) .{ .name = transform44.module_name, .install = transform44.installHooks, .remove = transform44.removeHooks, .is_active = transform44.isActive } else .{},
    if (build_opts.addonperf) .{ .name = addonperf.module_name, .install = addonperf.installHooks, .remove = addonperf.removeHooks, .is_active = addonperf.isActive } else .{},
    if (build_opts.ssemaths) .{ .name = ssemaths.module_name, .install = ssemaths.installHooks, .remove = ssemaths.removeHooks, .is_active = ssemaths.isActive } else .{},
    if (build_opts.filecache) .{ .name = file_cache.module_name, .install = file_cache.installHooks, .remove = file_cache.removeHooks, .is_active = file_cache.isActive } else .{},
    if (build_opts.worldmarkers) .{ .name = markers.module_name, .install = markers.installHooks, .remove = markers.removeHooks, .is_active = markers.isActive } else .{},
    if (build_opts.interact) .{ .name = interact.module_name, .install = interact.installHooks, .remove = interact.removeHooks, .is_active = interact.isActive } else .{},
    if (build_opts.outline) .{ .name = outline.module_name, .remove = outline.cleanup, .is_active = outline.isActive } else .{},
    if (build_opts.screenshot) .{ .name = screenshot.module_name, .remove = screenshot.removeHook, .is_active = screenshot.isActive } else .{},
    if (build_opts.silicon) .{ .name = silicon.module_name, .install = silicon.installHooks, .remove = silicon.removeHooks, .is_active = silicon.isActive } else .{},
};

fn shutdownDetour() callconv(hook.cc.stdcall) void {
    log.print("CGGameUI_Shutdown\n");
    // Per-session resets and remove_on_shutdown cleanup live in logoutDetour
    // (World_HandleLogoutCleanup) - fires on real logout/disconnect only, not /reload.
    shutdown_hook.callOriginal(.{});
}

// =============================================================================
// Init / Cleanup
// =============================================================================

fn install() void {
    logging.init();
    log = logging.Logger.open("weirdutils", .console);
    log.print("Installing hooks\n");
    _ = protection_hook.attach(0x42a320, &luaProtectionDetour);
    installFileHooks();
    _ = file_hook.attach(0x648620, &loadFileDetour);
    _ = register_commands_hook.attach(0x490250, &registerAllSystemCommandsDetour);
    _ = glue_commands_hook.attach(0x46ABB0, &glueLoadScriptFunctionsDetour);

    inline for (modules) |m| {
        if (m.install) |inst| inst();
        // Register isActive for addons.zig runtime lookup
        if (m.name) |name| {
            if (m.is_active) |f| module_active.register(name, f);
        }
    }

    addons.install();
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

    addons.uninstall();
    register_commands_hook.detach();
    glue_commands_hook.detach();
    file_hook.detach();
    removeFileHooks();
    protection_hook.detach();
    logging.deinit();
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
                    addons.pruneInactivePrefixes();
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
    addons.pruneInactivePrefixes();

    // Detach core hooks
    shutdown_hook.detach();
    logout_hook.detach();
    engine_init_hook.detach();
    addons.uninstall();
    register_commands_hook.detach();
    glue_commands_hook.detach();
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
