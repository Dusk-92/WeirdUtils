const std = @import("std");
const hook = @import("hook");
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

const WINAPI = std.builtin.CallingConvention.winapi;
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

// =============================================================================
// Lua Protection Bypass
// =============================================================================

var protection_hook: hook.Hook = .{};

fn luaProtectionDetour() callconv(.c) void {}

// =============================================================================
// Lua C API wrappers (WoW 1.12.1 — all __fastcall, L in ECX)
// =============================================================================

pub const lua = struct {
    pub const State = *anyopaque;

    pub fn getContext() State {
        const f: *const fn () callconv(fc) State = @ptrFromInt(0x7040D0);
        return f();
    }

    pub fn gettop(L: State) i32 {
        const f: *const fn (State) callconv(fc) i32 = @ptrFromInt(0x6F3070);
        return f(L);
    }

    pub fn settop(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3080);
        f(L, index);
    }

    pub fn pop(L: State, n: i32) void {
        settop(L, -n - 1);
    }

    pub fn pushvalue(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3350);
        f(L, index);
    }

    pub fn remove(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F30D0);
        f(L, index);
    }

    pub fn insert(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F31A0);
        f(L, index);
    }

    pub fn typeOf(L: State, index: i32) i32 {
        const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F3400);
        return f(L, index);
    }

    pub fn typeName(L: State, tp: i32) [*:0]const u8 {
        const f: *const fn (State, i32) callconv(fc) [*:0]const u8 = @ptrFromInt(0x6F3480);
        return f(L, tp);
    }

    pub fn isnumber(L: State, index: i32) bool {
        const f: *const fn (State, i32) callconv(fc) u32 = @ptrFromInt(0x6F34D0);
        return f(L, index) != 0;
    }

    pub fn isstring(L: State, index: i32) bool {
        const f: *const fn (State, i32) callconv(fc) u32 = @ptrFromInt(0x6F3510);
        return f(L, index) != 0;
    }

    pub fn pushnil(L: State) void {
        const f: *const fn (State) callconv(fc) void = @ptrFromInt(0x6F37F0);
        f(L);
    }

    pub fn pushnumber(L: State, n: f64) void {
        const f: *const fn (State, f64) callconv(fc) void = @ptrFromInt(0x6F3810);
        f(L, n);
    }

    pub fn pushstring(L: State, s: [*:0]const u8) void {
        const f: *const fn (State, [*:0]const u8) callconv(fc) void = @ptrFromInt(0x6F3890);
        f(L, s);
    }

    pub fn pushboolean(L: State, b: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F39F0);
        f(L, b);
    }

    pub fn pushcclosure(L: State, func: usize, n: i32) void {
        const f: *const fn (State, usize, i32) callconv(fc) void = @ptrFromInt(0x6F3920);
        f(L, func, n);
    }

    pub fn tonumber(L: State, index: i32) f64 {
        const f: *const fn (State, i32) callconv(fc) f64 = @ptrFromInt(0x6F3620);
        return f(L, index);
    }

    pub fn tostring(L: State, index: i32) ?[*:0]const u8 {
        const f: *const fn (State, i32) callconv(fc) ?[*:0]const u8 = @ptrFromInt(0x6F3690);
        return f(L, index);
    }

    pub fn toboolean(L: State, index: i32) i32 {
        const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F3660);
        return f(L, index);
    }

    pub fn newtable(L: State) void {
        const f: *const fn (State) callconv(fc) void = @ptrFromInt(0x6F3C90);
        f(L);
    }

    pub fn settable(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3E20);
        f(L, index);
    }

    pub fn gettable(L: State, index: i32) void {
        const f: *const fn (State, i32) callconv(fc) void = @ptrFromInt(0x6F3A40);
        f(L, index);
    }

    pub fn next(L: State, index: i32) i32 {
        const f: *const fn (State, i32) callconv(fc) i32 = @ptrFromInt(0x6F4450);
        return f(L, index);
    }

    pub fn pcall(L: State, nargs: i32, nresults: i32, errfunc: i32) i32 {
        const f: *const fn (State, i32, i32, i32) callconv(fc) i32 = @ptrFromInt(0x6F41A0);
        return f(L, nargs, nresults, errfunc);
    }

    pub fn luaError(L: State, msg: [*:0]const u8) void {
        asm volatile (
            \\push %[msg]
            \\push %[L]
            \\call *%[func]
            \\add $8, %%esp
            :
            : [L] "r" (@intFromPtr(L)),
              [msg] "r" (@intFromPtr(msg)),
              [func] "r" (@as(u32, 0x6F4940)),
            : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true }
        );
    }

    pub const LuaReg = extern struct {
        name: ?[*:0]const u8,
        func: usize,
    };

    pub fn openlib(L: State, libname: ?[*:0]const u8, funcs: [*]const LuaReg, nup: i32) void {
        const f: *const fn (State, ?[*:0]const u8, [*]const LuaReg, i32) callconv(fc) void = @ptrFromInt(0x6F4DC0);
        f(L, libname, funcs, nup);
    }

    pub fn checknumber(L: State, index: i32) f64 {
        const f: *const fn (State, i32) callconv(fc) f64 = @ptrFromInt(0x6F4C80);
        return f(L, index);
    }
};

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
    if (build_opts.markers) {
        registerFunction("TestMarkerCreate", @intFromPtr(&markers.luaTestMarkerCreate));
        registerFunction("TestMarkerDestroy", @intFromPtr(&markers.luaTestMarkerDestroy));
        registerFunction("TestMarkerToggle", @intFromPtr(&markers.luaTestMarkerToggle));
        registerFunction("GetPlayerPosition", @intFromPtr(&markers.luaGetPlayerPosition));
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

var file_hook: hook.Hook = .{};

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

    const orig = file_hook.getTrampoline(
        *const fn (u32, [*:0]const u8, *?[*]u8, ?*u32, u32, u32, u32) callconv(sc) u32,
    );
    return orig(unk, path, buf_out, size_out, extra_alloc, flags, async_ptr);
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

var open_file_hook: hook.Hook = .{};
var get_file_size_hook: hook.Hook = .{};
var read_file_hook: hook.Hook = .{};
var cleanup_file_handle_hook: hook.Hook = .{};
var process_async_hook: hook.Hook = .{};
var model_load_hook: hook.Hook = .{};

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

    const orig = open_file_hook.getTrampoline(
        *const fn (u32, [*:0]const u8, u32, *u32) callconv(sc) u32,
    );
    return orig(archive_ptr, path, flags, handle_out);
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

    const orig = get_file_size_hook.getTrampoline(
        *const fn (u32, ?*u32) callconv(sc) u32,
    );
    return orig(file_ctx, high_size_out);
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

    const orig = read_file_hook.getTrampoline(
        *const fn (u32, [*]u8, u32, ?*u32, u32, u32) callconv(sc) u32,
    );
    return orig(ctx, buffer, size, bytes_read_out, async_ptr, param6);
}

// --- Hook 4: processAsyncFileOperation (0x647350) ---

fn processAsyncDetour(param1: u32, _edx: u32) callconv(.c) void {
    _ = _edx;
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

    // Not our fake — call original via trampoline (__fastcall ECX=param1)
    hook.fastcall(void, process_async_hook.trampoline, param1, 0);
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
    const orig = cleanup_file_handle_hook.getTrampoline(
        *const fn (u32) callconv(sc) void,
    );
    orig(file_ctx);

    if (fake) con.fmt("[file] cleanup FAKE @0x{x} done\n", .{file_ctx});
}

// --- Hook 5: loadModelFromFileAsync (0x71d4e0) ---

fn loadModelAsyncDetour(model: u32, _edx: u32, file_handle: u32, should_use_callback: u32) callconv(.c) u32 {
    _ = _edx;

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
        // detour, avoids the callconv crash from Issue 1). Original is __stdcall(1).
        con.fmt("[file]   cleanup via trampoline fh=0x{x}\n", .{file_handle});
        asm volatile (
            \\push %[fh]
            \\call *%[func]
            :
            : [fh] "r" (file_handle),
              [func] "r" (cleanup_file_handle_hook.trampoline),
            : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true }
        );
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

    // Not our fake — call original trampoline (__thiscall: ECX=model, stack: fileHandle, shouldUseCallback)
    return asm volatile (
        \\push %[cb]
        \\push %[fh]
        \\call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (model),
          [fh] "r" (file_handle),
          [cb] "r" (should_use_callback),
          [func] "r" (model_load_hook.trampoline),
        : .{ .edx = true, .memory = true, .cc = true }
    );
}

// --- Install/remove in-memory file hooks ---

fn installFileHooks() void {
    _ = open_file_hook.install(0x6477c0, 9, @intFromPtr(&openFileDetour), &.{});
    _ = get_file_size_hook.install(0x6487f0, 6, @intFromPtr(&getFileSizeDetour), &.{});
    _ = read_file_hook.install(0x648460, 6, @intFromPtr(&readFileDetour), &.{});
    _ = cleanup_file_handle_hook.install(0x648730, 7, @intFromPtr(&cleanupFileHandleDetour), &.{});

    // loadModelFromFileAsync is __thiscall(ECX=model, fileHandle, shouldUseCallback) — needs thunk bridge
    if (model_load_hook.prepare(0x71d4e0, 6, &.{})) {
        const thunk = model_load_hook.mem.? + 32;
        _ = hook.buildFastcallToCdeclThunk(thunk, @intFromPtr(&loadModelAsyncDetour), 2);
        model_load_hook.activate(@intFromPtr(thunk));
    }

    con.print("[file] in-memory file hooks installed\n");
}

fn removeFileHooks() void {
    model_load_hook.remove();
    process_async_hook.remove();
    cleanup_file_handle_hook.remove();
    read_file_hook.remove();
    get_file_size_hook.remove();
    open_file_hook.remove();
}

// =============================================================================
// Hook: LoadScriptFunctions (0x490250)
// =============================================================================

var lsf_hook: hook.Hook = .{};

fn loadScriptFunctionsDetour() callconv(sc) void {
    const orig = lsf_hook.getTrampoline(*const fn () callconv(sc) void);
    orig();
    registerLuaFunctions();
}

// =============================================================================
// Hook: LoadAddonsRecursively (0x51F600)
// =============================================================================

var load_addons_hook: hook.Hook = .{};

fn loadAddonsDetour(error_handler: u32, _edx: u32) callconv(.c) void {
    _ = _edx;

    callOrigLoadAddons(error_handler);

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
    if (build_opts.markers) {
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

fn callOrigLoadAddons(error_handler: u32) void {
    asm volatile (
        \\call *%[func]
        :
        : [_] "{ecx}" (error_handler),
          [func] "r" (load_addons_hook.trampoline),
        : .{ .eax = true, .edx = true, .memory = true, .cc = true }
    );
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

var engine_init_hook: hook.Hook = .{};

fn engineInitDetour() callconv(sc) void {
    const orig = engine_init_hook.getTrampoline(*const fn () callconv(sc) void);
    orig();

    if (build_opts.screenshot) {
        screenshot.installHook();
    }
    if (build_opts.outline) {
        _ = outline.init();
    }
}

// =============================================================================
// Hook: CGGameUI_Shutdown (0x490BD0)
// =============================================================================

var shutdown_hook: hook.Hook = .{};

fn shutdownDetour() callconv(sc) void {
    // Clean up world objects BEFORE game shutdown — atexit handlers run before DllMain
    // so we must destroy markers here, not in uninstall().
    if (build_opts.markers) {
        markers.removeHooks();
    }

    const orig = shutdown_hook.getTrampoline(*const fn () callconv(sc) void);
    orig();
}

// =============================================================================
// Init / Cleanup
// =============================================================================

fn install() void {
    con.init();
    con.print("[weirdutils] Installing hooks\n");
    _ = protection_hook.install(0x42a320, 6, @intFromPtr(&luaProtectionDetour), &.{});
    installFileHooks();
    _ = file_hook.install(0x648620, 6, @intFromPtr(&loadFileDetour), &.{});
    _ = lsf_hook.install(0x490250, 6, @intFromPtr(&loadScriptFunctionsDetour), &.{1});

    if (build_opts.assetfix) {
        _ = assetfix.installHooks();
    }
    if (build_opts.framecrash) {
        framecrash.installHooks();
    }
    if (build_opts.combatlog) {
        combatlog.installHooks();
    }
    if (build_opts.transmogfix) {
        _ = transmogfix.installHooks();
    }
    if (build_opts.minimapicons) {
        minimapicons.installHooks();
    }

    if (load_addons_hook.prepare(0x51F600, 7, &.{})) {
        const thunk = load_addons_hook.mem.? + 32;
        _ = hook.buildFastcallToCdeclThunk(thunk, @intFromPtr(&loadAddonsDetour), 0);
        load_addons_hook.activate(@intFromPtr(thunk));
    }

    if (build_opts.interact) {
        interact.installHooks();
    }

    _ = engine_init_hook.install(0x46a400, 6, @intFromPtr(&engineInitDetour), &.{});
    _ = shutdown_hook.install(0x490BD0, 6, @intFromPtr(&shutdownDetour), &.{1});
}

fn uninstall() void {
    shutdown_hook.remove();
    engine_init_hook.remove();

    // Markers must be cleaned up first — destroys world objects while game systems are still alive
    if (build_opts.markers) {
        markers.removeHooks();
    }
    if (build_opts.outline) {
        outline.cleanup();
    }
    if (build_opts.screenshot) {
        screenshot.removeHook();
    }
    if (build_opts.interact) {
        interact.removeHooks();
    }
    if (build_opts.framecrash) {
        framecrash.removeHooks();
    }
    if (build_opts.combatlog) {
        combatlog.removeHooks();
    }
    if (build_opts.minimapicons) {
        minimapicons.removeHooks();
    }
    if (build_opts.transmogfix) {
        transmogfix.removeHooks();
    }
    if (build_opts.assetfix) {
        assetfix.removeHooks();
    }

    load_addons_hook.remove();
    lsf_hook.remove();
    file_hook.remove();
    removeFileHooks();
    protection_hook.remove();
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
