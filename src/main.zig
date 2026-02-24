const std = @import("std");
const hook = @import("hook");
const screenshot = @import("screenshot.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
const fc: std.builtin.CallingConvention = .{ .x86_fastcall = .{} };
const sc: std.builtin.CallingConvention = .{ .x86_stdcall = .{} };

// =============================================================================
// Lua Protection Bypass
// =============================================================================

var protection_hook: hook.Hook = .{};

/// Empty detour — replaces the Lua callback address validator at 0x42a320.
/// Prologue: 55 8B EC 83 EC 40 = 6 bytes, no fixups
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
        const f: *const fn (State, usize, i32) callconv(fc) void = @ptrFromInt(0x6F3B80);
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
        // lua_error is __cdecl(L, msg) at 0x6F4940
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

/// FrameScript::Register(name_ECX, func_EDX) at 0x704120
fn registerFunction(name: [*:0]const u8, func_addr: usize) void {
    hook.fastcall(void, 0x704120, @intFromPtr(name), func_addr);
}

/// M2_AllocateModelBuffer(size, source_file, line, flags) at 0x6462E0
/// __stdcall, 4 params, ret 0x10 — allocates from WoW's internal memory pool.
/// Returned buffer can be freed by game code via FreeFileResourceMemory.
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
//
// FIX: Cannot use the lua.* wrappers (e.g. lua.pushstring) from inside Lua
// C callbacks. The wrappers call through typed callconv(fc) function pointers,
// but Zig 0.15's x86 codegen is broken for callconv(fc) — it generates
// `ret 0x4` instead of plain `ret` for fastcall calls with ≤2 register params,
// corrupting the stack. Work around by using hook.fastcall / raw inline asm
// which bypasses Zig's calling-convention codegen entirely.

fn weirdUtilsTest(L: lua.State) callconv(.c) u32 {
    hook.fastcall(void, 0x6F3890, @intFromPtr(L), @intFromPtr(@as([*:0]const u8, "WeirdUtils is working!")));
    return 1;
}

fn weirdUtilsVersion(L: lua.State) callconv(.c) u32 {
    // lua_pushnumber is __fastcall(L_ECX, f64_stack) — f64 skips EDX and goes
    // on the stack. Callee cleans with ret 8.
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
    registerFunction("WeirdUtilsTest", @intFromPtr(&weirdUtilsTest));
    registerFunction("WeirdUtilsVersion", @intFromPtr(&weirdUtilsVersion));
    registerFunction("WeirdUtilsScreenshot", @intFromPtr(&screenshot.screenshotCommand));
}

// =============================================================================
// Embedded addon files
// =============================================================================

const addon_prefix = "Interface\\AddOns\\WeirdUtils\\";

const FileEntry = struct {
    name: []const u8,
    data: []const u8,
};

const embedded_files = [_]FileEntry{
    .{ .name = "WeirdUtils.toc", .data = @embedFile("addon/WeirdUtils.toc") },
    .{ .name = "WeirdUtils.lua", .data = @embedFile("addon/WeirdUtils.lua") },
};

fn findEmbeddedFile(path: [*:0]const u8) ?*const FileEntry {
    const path_span = std.mem.span(path);
    if (path_span.len <= addon_prefix.len) return null;
    // Case-insensitive prefix check — WoW paths use mixed case
    for (path_span[0..addon_prefix.len], addon_prefix) |a, b| {
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (la != lb) return null;
    }
    const relative = path_span[addon_prefix.len..];
    for (&embedded_files) |*entry| {
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
    return null;
}

// =============================================================================
// Hook: LoadFileWithTextureResourceFallback (0x648620)
// __stdcall(unk, path, buf_out, size_out, extra_alloc, flags, async) → ret 0x1C
// Prologue: 55 8B EC 8B 4D 1C = 6 bytes, no fixups
//
// The central file I/O function — all .toc, .lua, .xml, and texture file reads
// go through here. We intercept reads for our addon prefix and serve from
// DLL-embedded memory, allocated with the game's own allocator so the game
// can free the buffer normally.
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

        // Zero extra bytes (null terminator for text files when extra_alloc=1)
        if (extra_alloc > 0) {
            @memset(buf[entry.data.len..][0..extra_alloc], 0);
        }

        buf_out.* = buf;
        if (size_out) |s| s.* = data_len;
        return 1;
    }

    // Not our file — forward to original
    const orig = file_hook.getTrampoline(
        *const fn (u32, [*:0]const u8, *?[*]u8, ?*u32, u32, u32, u32) callconv(sc) u32,
    );
    return orig(unk, path, buf_out, size_out, extra_alloc, flags, async_ptr);
}

// =============================================================================
// Hook: LoadScriptFunctions (0x490250)
// Prologue: 56 E8 FA 60 27 00 = 6 bytes, fixup at offset 1
// =============================================================================

var lsf_hook: hook.Hook = .{};

fn loadScriptFunctionsDetour() callconv(sc) void {
    const orig = lsf_hook.getTrampoline(*const fn () callconv(sc) void);
    orig();
    registerLuaFunctions();
}

// =============================================================================
// Hook: LoadAddonsRecursively (0x51F600)
// __fastcall(error_handler_ECX) — prologue: 53 8B 1D ... = 7 bytes, no fixups
// After all real addons load, we call loadFileListWithIncludes with our .toc
// path, triggering the full addon loading pipeline (toc parse → lua exec →
// xml parse) with file reads served from embedded memory via the file hook.
// =============================================================================

var load_addons_hook: hook.Hook = .{};

fn loadAddonsDetour(error_handler: u32, _edx: u32) callconv(.c) void {
    _ = _edx;

    // Call original — loads all player addons
    callOrigLoadAddons(error_handler);

    // Trigger our addon through the real loading pipeline.
    // loadFileListWithIncludes will read our .toc via LoadFileWithTextureResourceFallback
    // (intercepted by file_hook), parse it, and call processIncludeFile for each entry,
    // which loads .lua files through the same hooked path.
    //
    // FIX: loadFileListWithIncludes unconditionally calls MD5_Update on the md5ctx
    // param (EDX). Passing NULL here caused the original crash-on-load — an access
    // violation inside MD5_Update. Allocate a zeroed 88-byte context on the stack.
    var md5ctx = std.mem.zeroes([88]u8);
    callLoadFileListWithIncludes(
        "Interface\\AddOns\\WeirdUtils\\WeirdUtils.toc",
        &md5ctx,
        error_handler,
    );
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

/// loadFileListWithIncludes(path_ECX, md5ctx_EDX, error_handler_stack)
/// __fastcall at 0x6EDB90, ret 4 (1 stack param)
fn callLoadFileListWithIncludes(toc_path: [*:0]const u8, md5ctx: *[88]u8, error_handler: u32) void {
    // __fastcall: ECX=path, EDX=md5ctx, stack: error_handler
    // Callee cleans the 1 stack arg (ret 4)
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

// =============================================================================
// Hook: CGGameUI_Shutdown (0x490BD0)
// Prologue: 56 E8 7A 83 FC FF = 6 bytes, fixup at offset 1
// =============================================================================

var shutdown_hook: hook.Hook = .{};

fn shutdownDetour() callconv(sc) void {
    const orig = shutdown_hook.getTrampoline(*const fn () callconv(sc) void);
    orig();
}

// =============================================================================
// Init / Cleanup
// =============================================================================

fn install() void {
    // 1. Lua protection bypass — empty stub replaces address validator
    _ = protection_hook.install(0x42a320, 6, @intFromPtr(&luaProtectionDetour), &.{});

    // 2. File I/O hook — serve embedded addon files from memory
    //    Must be installed before LoadAddonsRecursively hook fires
    _ = file_hook.install(0x648620, 6, @intFromPtr(&loadFileDetour), &.{});

    // 3. LoadScriptFunctions — register C functions after built-in commands
    _ = lsf_hook.install(0x490250, 6, @intFromPtr(&loadScriptFunctionsDetour), &.{1});

    // 4. LoadAddonsRecursively — trigger our addon load after real addons
    //    Uses thunk: __fastcall(ECX) → cdecl(ecx_val, edx_val)
    if (load_addons_hook.prepare(0x51F600, 7, &.{})) {
        const thunk = load_addons_hook.mem.? + 32;
        _ = hook.buildFastcallToCdeclThunk(thunk, @intFromPtr(&loadAddonsDetour), 0);
        load_addons_hook.activate(@intFromPtr(thunk));
    }

    // 5. Screenshot hook — async PNG capture replacing TGA write
    screenshot.installHook();

    // 6. CGGameUI_Shutdown — cleanup
    _ = shutdown_hook.install(0x490BD0, 6, @intFromPtr(&shutdownDetour), &.{1});
}

fn uninstall() void {
    shutdown_hook.remove();
    screenshot.removeHook();
    load_addons_hook.remove();
    lsf_hook.remove();
    file_hook.remove();
    protection_hook.remove();
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
        1 => install(), // DLL_PROCESS_ATTACH
        0 => uninstall(), // DLL_PROCESS_DETACH
        else => {},
    }
    return 1;
}
