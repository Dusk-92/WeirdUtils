//! Log session rotation with per-character directories.
//!
//! Redirects combat log, raw combat log, and chat log to per-character
//! directories: `Logs\<realm>\<character>\WoW<Type>Log_YYYY_MM_DD.txt`.
//!
//! Features:
//! - Early path setup: hooks HandleCharacterSelection to resolve character/realm
//!   from the select screen data before world loading begins
//! - Daily rotation: one log file per character per day, no timestamps
//! - Session continuation: appends to today's file on each login (same character)
//! - Session marker: writes `COMBATLOG_SESSION: <char> <realm>` on first combat write
//!
//! All DLL-side - no Lua addon needed.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const lua = @import("../lua.zig");
const o = @import("offsets.zig");

const WINAPI = std.builtin.CallingConvention.winapi;

// =============================================================================
// Win32 imports
// =============================================================================

extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(WINAPI) void;
extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(WINAPI) void;
extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) callconv(WINAPI) usize;
extern "kernel32" fn FindNextFileA(hFindFile: usize, lpFindFileData: *WIN32_FIND_DATAA) callconv(WINAPI) i32;
extern "kernel32" fn FindClose(hFindFile: usize) callconv(WINAPI) i32;

const ERROR_ALREADY_EXISTS: u32 = 183;
const INVALID_HANDLE_VALUE: usize = 0xFFFFFFFF;

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};

// =============================================================================
// Mutex state
// =============================================================================

const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "logsessions";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log: logging.Logger = .{};

pub fn isActive() bool {
    return g_is_hook_owner;
}

// =============================================================================
// Session state - reset on logout
// =============================================================================

/// Static buffers for redirected paths (null-terminated). Must outlive the process.
var g_combat_path: [260]u8 = undefined;
var g_raw_combat_path: [260]u8 = undefined;
var g_chat_path: [260]u8 = undefined;
var g_combat_path_len: usize = 0;
var g_raw_combat_path_len: usize = 0;
var g_chat_path_len: usize = 0;

/// Directory prefix: `Logs\<realm>\<char>\`
var g_dir_path: [280]u8 = undefined;
var g_dir_path_len: usize = 0;

/// Stored character and realm names (sanitized: spaces → underscores)
var g_session_char: [64]u8 = undefined;
var g_session_realm: [64]u8 = undefined;
var g_session_char_len: usize = 0;
var g_session_realm_len: usize = 0;

/// True once paths have been configured for this login session.
var g_paths_configured: bool = false;

/// Per-log-type session marker flags.
var g_combat_marker_written: bool = false;
var g_chat_marker_written: bool = false;
var g_raw_marker_written: bool = false;

/// Raw combat log handle address - captured from initLogDetour when SuperWoW
/// calls InitializeLogBuffer for WoWRawCombatLog. We don't know this address
/// statically; SuperWoW passes it as handle_out.
var g_raw_combat_handle_addr: u32 = 0;

// =============================================================================
// Character / realm identity
// =============================================================================

/// Read realm name from CVar: dereference base pointer, then read string at +0x20.
fn getRealmName() ?[*:0]const u8 {
    const base = hook.readMem(u32, o.REALM_NAME_CVAR_BASE);
    if (base == 0) return null;
    const str_addr = hook.readMem(u32, base + 0x20);
    if (str_addr == 0) return null;
    return @ptrFromInt(str_addr);
}

/// Read the selected character's name from the character select screen data.
/// Available when the player clicks Enter World (before world loading begins).
fn getCharSelectName() ?[*:0]const u8 {
    const index = hook.readMem(i32, o.CHAR_SELECT_INDEX);
    if (index < 0) return null;
    const count = hook.readMem(i32, o.CHAR_LIST_COUNT);
    if (index >= count) return null;
    const list_base = hook.readMem(u32, o.CHAR_LIST_BASE);
    if (list_base == 0) return null;
    const entry_addr = list_base + @as(u32, @intCast(index)) * o.CHAR_ENTRY_SIZE + o.CHAR_NAME_OFFSET;
    // Name is a C string embedded in the entry struct (not a pointer)
    return @ptrFromInt(entry_addr);
}

// =============================================================================
// Name sanitization and directory creation
// =============================================================================

/// Copy name to dst, replacing spaces with underscores. Returns length written.
fn sanitizeName(src: []const u8, dst: []u8) usize {
    const len = @min(src.len, dst.len);
    for (0..len) |i| {
        dst[i] = if (src[i] == ' ') '_' else src[i];
    }
    return len;
}

/// Create a single directory level, ignoring ERROR_ALREADY_EXISTS.
fn ensureDir(path: [*:0]const u8) bool {
    if (CreateDirectoryA(path, null) != 0) return true;
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

/// Build and create `Logs\<realm>\<char>\` directory tree.
/// Stores the full directory prefix in g_dir_path. Returns true on success.
fn setupSessionDir(realm: []const u8, char_name: []const u8) bool {
    // Logs\  (may already exist)
    if (!ensureDir("Logs")) return false;

    // Logs\<realm>
    var realm_dir: [280]u8 = undefined;
    const realm_path = std.fmt.bufPrint(&realm_dir, "Logs\\{s}", .{realm}) catch return false;
    realm_dir[realm_path.len] = 0;
    if (!ensureDir(@ptrCast(realm_dir[0..realm_path.len :0]))) return false;

    // Logs\<realm>\<char>   (CreateDirectoryA doesn't want trailing backslash)
    var char_dir: [280]u8 = undefined;
    const char_path = std.fmt.bufPrint(&char_dir, "Logs\\{s}\\{s}", .{ realm, char_name }) catch return false;
    char_dir[char_path.len] = 0;
    if (!ensureDir(@ptrCast(char_dir[0..char_path.len :0]))) return false;

    // Store with trailing backslash for path concatenation
    const dir_path = std.fmt.bufPrint(&g_dir_path, "Logs\\{s}\\{s}\\", .{ realm, char_name }) catch return false;
    g_dir_path[dir_path.len] = 0;
    g_dir_path_len = dir_path.len;

    log.fmt("dir: {s}\n", .{g_dir_path[0..g_dir_path_len]});
    return true;
}

// =============================================================================
// Daily log file lookup
// =============================================================================

/// Scan directory for today's daily log file matching `<prefix>_YYYY_MM_DD.txt`.
/// Returns full path if found, null if not.
fn findDailyFile(prefix: []const u8, result_buf: *[260]u8) ?usize {
    if (g_dir_path_len == 0) return null;

    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);

    // Build exact filename: <dir><prefix>_YYYY_MM_DD.txt
    var filename_buf: [260]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{s}_{d:0>4}_{d:0>2}_{d:0>2}.txt", .{
        prefix,
        st.wYear,
        st.wMonth,
        st.wDay,
    }) catch return null;

    // Build full path: <dir><filename>
    const total_len = g_dir_path_len + filename.len;
    if (total_len >= result_buf.len) return null;
    @memcpy(result_buf[0..g_dir_path_len], g_dir_path[0..g_dir_path_len]);
    @memcpy(result_buf[g_dir_path_len..total_len], filename);
    result_buf[total_len] = 0;

    // Check if file exists
    var find_data: WIN32_FIND_DATAA = undefined;
    const find_handle = FindFirstFileA(@ptrCast(result_buf[0..total_len :0]), &find_data);
    if (find_handle == INVALID_HANDLE_VALUE) return null;
    _ = FindClose(find_handle);

    return total_len;
}

/// Resolve a log file path: reuse today's daily file or create new one.
fn resolveDailyLogPath(prefix: []const u8, result_buf: *[260]u8) usize {
    // Try to find today's daily file
    if (findDailyFile(prefix, result_buf)) |len| {
        log.fmt("reusing: {s}\n", .{result_buf[0..len]});
        return len;
    }

    // Generate new daily filename: <dir><prefix>_YYYY_MM_DD.txt
    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);

    const path = std.fmt.bufPrint(result_buf, "{s}{s}_{d:0>4}_{d:0>2}_{d:0>2}.txt", .{
        g_dir_path[0..g_dir_path_len],
        prefix,
        st.wYear,
        st.wMonth,
        st.wDay,
    }) catch return 0;
    result_buf[path.len] = 0;
    log.fmt("new: {s}\n", .{path});
    return path.len;
}

// =============================================================================
// Session path configuration
// =============================================================================

/// Core path setup: sanitize names, create directories, resolve all log paths.
/// Called from enterWorldDetour when the player clicks Enter World.
fn configureSession(char_span: []const u8, realm_span: []const u8) void {
    // Sanitize and store names
    g_session_char_len = sanitizeName(char_span, &g_session_char);
    g_session_realm_len = sanitizeName(realm_span, &g_session_realm);

    log.fmt("session: {s} on {s}\n", .{
        g_session_char[0..g_session_char_len],
        g_session_realm[0..g_session_realm_len],
    });

    // Create directory tree: Logs\<realm>\<char>\
    if (!setupSessionDir(
        g_session_realm[0..g_session_realm_len],
        g_session_char[0..g_session_char_len],
    )) {
        log.print("setup: failed to create directories\n");
        return;
    }

    // Resolve paths for all three log types
    g_combat_path_len = resolveDailyLogPath("WoWCombatLog", &g_combat_path);
    g_raw_combat_path_len = resolveDailyLogPath("WoWRawCombatLog", &g_raw_combat_path);
    g_chat_path_len = resolveDailyLogPath("WoWChatLog", &g_chat_path);

    g_paths_configured = true;
}

// =============================================================================
// HandleCharacterSelection hook - set up paths before world loading
// =============================================================================

var enter_world_hook: hook.Detour(fn () callconv(hook.cc.stdcall) void) = .{};

/// Fires when the player clicks Enter World on the character select screen.
/// Character name and realm are available from the select screen data.
/// Sets up paths BEFORE the world loading sequence calls InitializeLogBuffer.
fn enterWorldDetour() callconv(hook.cc.stdcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (!g_paths_configured) {
        const char_name = getCharSelectName();
        const realm_name = getRealmName();

        if (char_name != null and realm_name != null) {
            configureSession(std.mem.span(char_name.?), std.mem.span(realm_name.?));
        } else {
            log.print("enter world: char/realm not available\n");
        }
    }

    enter_world_hook.callOriginal(.{});
}

// =============================================================================
// InitializeLogBuffer hook - lazy setup + path redirect
// =============================================================================

var init_log_hook: hook.Detour(fn (u32, u32, u32) callconv(hook.cc.stdcall) u32) = .{};

fn initLogDetour(file_path: u32, flags: u32, handle_out: u32) callconv(hook.cc.stdcall) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const path_ptr: [*:0]const u8 = @ptrFromInt(file_path);
    const path_span = std.mem.span(path_ptr);

    // Redirect based on path suffix
    if (g_combat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWCombatLog.txt")) {
        log.fmt("redirect: {s} -> {s}\n", .{ path_span, g_combat_path[0..g_combat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_combat_path), flags, handle_out });
    }

    if (g_raw_combat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWRawCombatLog.txt")) {
        g_raw_combat_handle_addr = handle_out; // capture SuperWoW's handle address
        log.fmt("redirect: {s} -> {s}\n", .{ path_span, g_raw_combat_path[0..g_raw_combat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_raw_combat_path), flags, handle_out });
    }

    if (g_chat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWChatLog.txt")) {
        log.fmt("redirect: {s} -> {s}\n", .{ path_span, g_chat_path[0..g_chat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_chat_path), flags, handle_out });
    }

    return init_log_hook.callOriginal(.{ file_path, flags, handle_out });
}

// =============================================================================
// WriteFormattedLogMessage hook - inject session markers on first write per log
// =============================================================================

var write_log_hook: hook.Detour(fn (u32, u32, u32) callconv(hook.cc.stdcall) void) = .{};

fn writeLogDetour(handle: u32, fmt: u32, va_list: u32) callconv(hook.cc.stdcall) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (g_session_char_len > 0) {
        if (!g_combat_marker_written) {
            const combat_handle = hook.readMem(u32, o.COMBAT_LOG_HANDLE);
            if (handle == combat_handle and combat_handle != 0) {
                writeSessionMarker(handle, "COMBATLOG_SESSION: %s");
                g_combat_marker_written = true;
            }
        }

        if (!g_chat_marker_written) {
            const chat_handle = hook.readMem(u32, o.CHAT_LOG_HANDLE);
            if (handle == chat_handle and chat_handle != 0) {
                writeSessionMarker(handle, "CHAT_SESSION: %s");
                g_chat_marker_written = true;
            }
        }

        if (!g_raw_marker_written and g_raw_combat_handle_addr != 0) {
            const raw_handle = hook.readMem(u32, g_raw_combat_handle_addr);
            if (handle == raw_handle and raw_handle != 0) {
                writeSessionMarker(handle, "COMBATLOG_SESSION: %s");
                g_raw_marker_written = true;
            }
        }
    }

    write_log_hook.callOriginal(.{ handle, fmt, va_list });
}

/// Write a session marker line using stored character + realm names.
fn writeSessionMarker(handle: u32, fmt_str: [*:0]const u8) void {
    var marker_buf: [128]u8 = undefined;
    const marker_str = std.fmt.bufPrint(&marker_buf, "{s} {s}", .{
        g_session_char[0..g_session_char_len],
        g_session_realm[0..g_session_realm_len],
    }) catch return;
    marker_buf[marker_str.len] = 0;

    const marker_ptr: u32 = @intFromPtr(&marker_buf);
    write_log_hook.callOriginal(.{
        handle,
        @intFromPtr(fmt_str),
        @intFromPtr(&marker_ptr),
    });

    log.fmt("marker: {s}\n", .{marker_str});
}

// =============================================================================
// Shutdown - reset session state for next login
// =============================================================================

/// Resets all session state so the next login gets fresh paths.
/// Called from logoutDetour/shutdownDetour in main.zig.
pub fn onShutdown() void {
    if (g_paths_configured) {
        log.print("session reset\n");
    }
    g_paths_configured = false;
    g_combat_marker_written = false;
    g_chat_marker_written = false;
    g_raw_marker_written = false;
    g_raw_combat_handle_addr = 0;
    // Keep paths set so initLogDetour keeps redirecting on next login
    g_session_char_len = 0;
    g_session_realm_len = 0;
}

// =============================================================================
// Lua API - log path accessors
// =============================================================================

/// GetCombatLogPath() → string or nil
pub fn luaGetCombatLogPath(L: lua.State) callconv(.c) u32 {
    if (g_combat_path_len > 0) {
        lua.pushstring(L, @ptrCast(g_combat_path[0..g_combat_path_len :0]));
    } else {
        lua.pushnil(L);
    }
    return 1;
}

/// GetChatLogPath() → string or nil
pub fn luaGetChatLogPath(L: lua.State) callconv(.c) u32 {
    if (g_chat_path_len > 0) {
        lua.pushstring(L, @ptrCast(g_chat_path[0..g_chat_path_len :0]));
    } else {
        lua.pushnil(L);
    }
    return 1;
}

// =============================================================================
// Install / remove hooks
// =============================================================================

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;

    log = logging.Logger.open(module_name, .console);

    // Hook HandleCharacterSelection - sets up paths when player clicks Enter World,
    // before the world loading sequence calls InitializeLogBuffer.
    if (enter_world_hook.attach(o.FN_HANDLE_CHAR_SELECT, &enterWorldDetour) != .ok) {
        log.print("FAILED to hook HandleCharacterSelection!\n");
    } else {
        log.print("hooked HandleCharacterSelection OK\n");
    }

    if (init_log_hook.attach(o.FN_INIT_LOG_BUFFER, &initLogDetour) != .ok) {
        log.print("FAILED to hook InitializeLogBuffer!\n");
    } else {
        log.print("hooked InitializeLogBuffer OK\n");
    }

    if (write_log_hook.attach(o.FN_WRITE_FMT_LOG_MSG, &writeLogDetour) != .ok) {
        log.print("FAILED to hook WriteFormattedLogMessage!\n");
    } else {
        log.print("hooked WriteFormattedLogMessage OK\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        write_log_hook.detach();
        init_log_hook.detach();
        enter_world_hook.detach();
        log.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
