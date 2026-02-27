const std = @import("std");
const hook = @import("hook");
pub const con = @import("console.zig");

// Build options for conditional module compilation
const build_opts = struct {
    const screenshot = @import("build_options").enable_screenshot;
    const interact = @import("build_options").enable_interact;
    const outline = @import("build_options").enable_outline;
    const markers = @import("build_options").enable_markers;
};

// Conditional module imports
const screenshot = if (build_opts.screenshot) @import("screenshot/screenshot.zig") else struct {};
const interact = if (build_opts.interact) @import("interact/interact.zig") else struct {};
const outline = if (build_opts.outline) @import("outline/api.zig") else struct {};
const markers = if (build_opts.markers) @import("markers/markers.zig") else struct {};

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

const markers_assets = if (build_opts.markers) [_]FileEntry{
    .{ .name = "xyz.m2", .data = @embedFile("markers/assets/World/ArtTest/Boxtest/xyz.m2") },
    .{ .name = "xyz.blp", .data = @embedFile("markers/assets/World/ArtTest/Boxtest/xyz.blp") },
} else [_]FileEntry{};

// All addon prefixes to check
const addon_prefixes = [_]AddonPrefix{
    .{ .prefix = core_prefix, .files = &core_files },
    .{ .prefix = "Interface\\AddOns\\Screenshot\\", .files = &screenshot_files },
    .{ .prefix = "Interface\\AddOns\\Interact\\", .files = &interact_files },
    .{ .prefix = "Interface\\AddOns\\Outline\\", .files = &outline_files },
    .{ .prefix = "Interface\\AddOns\\Markers\\", .files = &markers_files },
    .{ .prefix = "World\\ArtTest\\Boxtest\\", .files = &markers_assets },
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
    _ = file_hook.install(0x648620, 6, @intFromPtr(&loadFileDetour), &.{});
    _ = lsf_hook.install(0x490250, 6, @intFromPtr(&loadScriptFunctionsDetour), &.{1});

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

    load_addons_hook.remove();
    lsf_hook.remove();
    file_hook.remove();
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
