//! Combat log session rotation with per-character directories.
//!
//! Redirects combat log, raw combat log, and chat log to per-character
//! directories: `Logs\<realm>\<character>\<Type>_<timestamp>_<PID>.txt`.
//!
//! Features:
//! - Lazy path setup: resolves character/realm on first InitializeLogBuffer call
//! - Session continuation: reuses files modified < 30 min ago
//! - Session marker: writes `COMBATLOG_SESSION: <char> <realm>` on first combat write
//!
//! All DLL-side — no Lua addon needed.

const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");
const o = @import("offsets.zig");

const sc = std.builtin.CallingConvention{ .x86_stdcall = .{} };
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

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

// =============================================================================
// Session state — reset on logout
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

/// Session marker written flag.
var g_session_marker_written: bool = false;

/// Saved original path pointers for restoration.
var g_original_combat_path_ptr: u32 = 0;
var g_original_chat_path_ptr: u32 = 0;

/// Pending init tracking — log types initialized before paths were ready.
/// When setupSessionPaths succeeds, we replay these with the correct paths
/// to re-initialize the already-created buffer contexts.
const PendingInit = struct { active: bool = false, flags: u32 = 0, handle_out: u32 = 0 };
var g_pending: [3]PendingInit = .{ .{}, .{}, .{} }; // [0]=combat, [1]=raw, [2]=chat

// =============================================================================
// Player identity (same inline asm patterns as markers module)
// =============================================================================

/// Get local player GUID via GetPlayerGUID (0x468550).
/// __fastcall(), no params, returns EAX(low):EDX(high).
fn getPlayerGUID() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("call *%[func]"
        : [_] "={eax}" (lo),
          [_] "={edx}" (hi),
        : [func] "r" (o.FN_GET_PLAYER_GUID),
        : .{ .ecx = true, .memory = true, .cc = true });
    return (@as(u64, hi) << 32) | lo;
}

/// Look up a player name from the name cache by GUID.
/// Calls RetrieveNPCDataFromCache — __thiscall(ECX=cache), 6 stack params, RET 0x18.
fn getNameFromGUID(guid_lo: u32, guid_hi: u32) ?[*:0]const u8 {
    if (guid_lo == 0 and guid_hi == 0) return null;
    var name_buf: [2]u32 = .{ 0, 0 };
    const stack_args = [6]u32{
        guid_lo,
        guid_hi,
        @intFromPtr(&name_buf),
        0, 0, 0,
    };
    const result: u32 = asm volatile (
        \\ push 20(%[a])
        \\ push 16(%[a])
        \\ push 12(%[a])
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, o.NAME_CACHE_OBJ)),
          [a] "r" (&stack_args),
          [func] "r" (@as(u32, o.FN_NAME_CACHE_LOOKUP)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
    return if (result != 0) @ptrFromInt(result) else null;
}

/// Read realm name from CVar: dereference base pointer, then read string at +0x20.
fn getRealmName() ?[*:0]const u8 {
    const base = hook.readMem(u32, o.REALM_NAME_CVAR_BASE);
    if (base == 0) return null;
    const str_addr = hook.readMem(u32, base + 0x20);
    if (str_addr == 0) return null;
    return @ptrFromInt(str_addr);
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

    con.fmt("[combatlog] dir: {s}\n", .{g_dir_path[0..g_dir_path_len]});
    return true;
}

// =============================================================================
// Session continuation — find recent file to reuse
// =============================================================================

/// Scan directory for files matching `<prefix>_*.txt`, return the newest if
/// modified within 30 minutes. Writes full path into result_buf, returns length.
fn findRecentFile(prefix: []const u8, result_buf: *[260]u8) ?usize {
    if (g_dir_path_len == 0) return null;

    // Build search pattern: <dir><prefix>_*.txt
    var search_buf: [300]u8 = undefined;
    const pattern = std.fmt.bufPrint(&search_buf, "{s}{s}_*.txt", .{
        g_dir_path[0..g_dir_path_len],
        prefix,
    }) catch return null;
    search_buf[pattern.len] = 0;

    var find_data: WIN32_FIND_DATAA = undefined;
    const find_handle = FindFirstFileA(@ptrCast(search_buf[0..pattern.len :0]), &find_data);
    if (find_handle == INVALID_HANDLE_VALUE) return null;
    defer _ = FindClose(find_handle);

    var newest_time: u64 = 0;
    var newest_name: [260]u8 = undefined;
    var newest_name_len: usize = 0;

    // Iterate all matching files, track the newest by write time
    var has_result: bool = true;
    while (has_result) {
        const ft: u64 = @bitCast(find_data.ftLastWriteTime);
        if (ft > newest_time) {
            newest_time = ft;
            const name_len = std.mem.indexOfScalar(u8, &find_data.cFileName, 0) orelse 0;
            if (name_len > 0) {
                newest_name_len = name_len;
                @memcpy(newest_name[0..name_len], find_data.cFileName[0..name_len]);
            }
        }
        has_result = FindNextFileA(find_handle, &find_data) != 0;
    }

    if (newest_name_len == 0) return null;

    // Compare against current time — both UTC FILETIME (100ns units)
    var current_ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&current_ft);
    const current: u64 = @bitCast(current_ft);
    const threshold: u64 = 30 * 60 * 10_000_000; // 30 minutes

    if (current > newest_time and (current - newest_time) < threshold) {
        // Build full path: dir + filename
        const total_len = g_dir_path_len + newest_name_len;
        if (total_len >= result_buf.len) return null;
        @memcpy(result_buf[0..g_dir_path_len], g_dir_path[0..g_dir_path_len]);
        @memcpy(result_buf[g_dir_path_len..total_len], newest_name[0..newest_name_len]);
        result_buf[total_len] = 0;
        return total_len;
    }

    return null;
}

/// Resolve a log file path: reuse recent file or generate new timestamped name.
fn resolveLogPath(prefix: []const u8, result_buf: *[260]u8) usize {
    // Try to reuse a recent file (modified < 30 min ago)
    if (findRecentFile(prefix, result_buf)) |len| {
        con.fmt("[combatlog] reusing: {s}\n", .{result_buf[0..len]});
        return len;
    }

    // Generate new timestamped filename
    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);
    const pid = GetCurrentProcessId();

    const path = std.fmt.bufPrint(result_buf, "{s}{s}_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{d}.txt", .{
        g_dir_path[0..g_dir_path_len],
        prefix,
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        pid,
    }) catch return 0;
    result_buf[path.len] = 0;
    con.fmt("[combatlog] new: {s}\n", .{path});
    return path.len;
}

// =============================================================================
// Lazy session path setup
// =============================================================================

/// Called from initLogDetour on first call per session.
/// Resolves character/realm, creates directories, resolves all log file paths.
fn setupSessionPaths() void {
    // Get player GUID → name
    const player_guid = getPlayerGUID();
    if (player_guid == 0) {
        con.print("[combatlog] setup: no player GUID yet\n");
        return;
    }
    const guid_lo: u32 = @truncate(player_guid);
    const guid_hi: u32 = @truncate(player_guid >> 32);

    const char_name = getNameFromGUID(guid_lo, guid_hi) orelse {
        con.print("[combatlog] setup: player name not in cache\n");
        return;
    };
    const char_span = std.mem.span(char_name);

    // Get realm name from CVar
    const realm_name = getRealmName() orelse {
        con.print("[combatlog] setup: realm name not available\n");
        return;
    };
    const realm_span = std.mem.span(realm_name);

    // Sanitize and store names
    g_session_char_len = sanitizeName(char_span, &g_session_char);
    g_session_realm_len = sanitizeName(realm_span, &g_session_realm);

    con.fmt("[combatlog] session: {s} on {s}\n", .{
        g_session_char[0..g_session_char_len],
        g_session_realm[0..g_session_realm_len],
    });

    // Create directory tree: Logs\<realm>\<char>\
    if (!setupSessionDir(
        g_session_realm[0..g_session_realm_len],
        g_session_char[0..g_session_char_len],
    )) {
        con.print("[combatlog] setup: failed to create directories\n");
        return;
    }

    // Resolve paths for all three log types
    g_combat_path_len = resolveLogPath("WoWCombatLog", &g_combat_path);
    g_raw_combat_path_len = resolveLogPath("WoWRawCombatLog", &g_raw_combat_path);
    g_chat_path_len = resolveLogPath("WoWChatLog", &g_chat_path);

    // Belt-and-suspenders: overwrite path pointer table for game code paths
    // that read the table directly before calling InitializeLogBuffer.
    if (g_combat_path_len > 0) {
        g_original_combat_path_ptr = hook.readMem(u32, o.COMBAT_LOG_PATH_PTR);
        const ptr_bytes: [4]u8 = @bitCast(@intFromPtr(&g_combat_path));
        hook.writeMem(o.COMBAT_LOG_PATH_PTR, &ptr_bytes);
    }
    if (g_chat_path_len > 0) {
        g_original_chat_path_ptr = hook.readMem(u32, o.CHAT_LOG_PATH_PTR);
        const ptr_bytes: [4]u8 = @bitCast(@intFromPtr(&g_chat_path));
        hook.writeMem(o.CHAT_LOG_PATH_PTR, &ptr_bytes);
    }

    g_paths_configured = true;
}

fn restorePathPointers() void {
    if (g_original_combat_path_ptr != 0) {
        const ptr_bytes: [4]u8 = @bitCast(g_original_combat_path_ptr);
        hook.writeMem(o.COMBAT_LOG_PATH_PTR, &ptr_bytes);
        g_original_combat_path_ptr = 0;
    }
    if (g_original_chat_path_ptr != 0) {
        const ptr_bytes: [4]u8 = @bitCast(g_original_chat_path_ptr);
        hook.writeMem(o.CHAT_LOG_PATH_PTR, &ptr_bytes);
        g_original_chat_path_ptr = 0;
    }
}

// =============================================================================
// InitializeLogBuffer hook — lazy setup + path redirect
// =============================================================================

var init_log_hook: hook.Detour(fn (u32, u32, u32) callconv(sc) u32) = .{};

fn initLogDetour(file_path: u32, flags: u32, handle_out: u32) callconv(sc) u32 {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // Lazy setup: configure session paths on first call after login
    if (!g_paths_configured) {
        setupSessionPaths();
    }

    const path_ptr: [*:0]const u8 = @ptrFromInt(file_path);
    const path_span = std.mem.span(path_ptr);

    // Redirect based on path suffix
    if (g_combat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWCombatLog.txt")) {
        con.fmt("[combatlog] redirect: {s} -> {s}\n", .{ path_span, g_combat_path[0..g_combat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_combat_path), flags, handle_out });
    }

    if (g_raw_combat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWRawCombatLog.txt")) {
        con.fmt("[combatlog] redirect: {s} -> {s}\n", .{ path_span, g_raw_combat_path[0..g_raw_combat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_raw_combat_path), flags, handle_out });
    }

    if (g_chat_path_len > 0 and std.mem.endsWith(u8, path_span, "WoWChatLog.txt")) {
        con.fmt("[combatlog] redirect: {s} -> {s}\n", .{ path_span, g_chat_path[0..g_chat_path_len] });
        return init_log_hook.callOriginal(.{ @intFromPtr(&g_chat_path), flags, handle_out });
    }

    return init_log_hook.callOriginal(.{ file_path, flags, handle_out });
}

// =============================================================================
// WriteFormattedLogMessage hook — inject session marker on first combat write
// =============================================================================

var write_log_hook: hook.Detour(fn (u32, u32, u32) callconv(sc) void) = .{};

fn writeLogDetour(handle: u32, fmt: u32, va_list: u32) callconv(sc) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    if (!g_session_marker_written) {
        const combat_handle = hook.readMem(u32, o.COMBAT_LOG_HANDLE);
        if (handle == combat_handle and combat_handle != 0) {
            writeSessionMarkerNow(handle);
        }
    }

    write_log_hook.callOriginal(.{ handle, fmt, va_list });
}

/// Write session marker using stored character + realm names (no inline asm needed).
fn writeSessionMarkerNow(handle: u32) void {
    if (g_session_char_len == 0) {
        con.print("[combatlog] session marker: names not resolved yet\n");
        return;
    }

    // Build "CharName RealmName" string on the stack
    var marker_buf: [128]u8 = undefined;
    const marker_str = std.fmt.bufPrint(&marker_buf, "{s} {s}", .{
        g_session_char[0..g_session_char_len],
        g_session_realm[0..g_session_realm_len],
    }) catch return;
    marker_buf[marker_str.len] = 0;

    // va_list for %s: pointer to a char*
    const marker_ptr: u32 = @intFromPtr(&marker_buf);
    write_log_hook.callOriginal(.{
        handle,
        @intFromPtr(@as([*:0]const u8, "COMBATLOG_SESSION: %s")),
        @intFromPtr(&marker_ptr),
    });

    g_session_marker_written = true;
    con.fmt("[combatlog] session marker: {s}\n", .{marker_str});
}

// =============================================================================
// Shutdown — reset session state for next login
// =============================================================================

/// Resets all session state so the next login gets fresh paths.
/// Called from logoutDetour/shutdownDetour in main.zig.
pub fn onShutdown() void {
    if (g_paths_configured or g_session_marker_written) {
        con.print("[combatlog] session reset\n");
    }
    g_paths_configured = false;
    g_session_marker_written = false;
    g_combat_path_len = 0;
    g_raw_combat_path_len = 0;
    g_chat_path_len = 0;
    g_dir_path_len = 0;
    g_session_char_len = 0;
    g_session_realm_len = 0;
    // Restore original path pointers so next session starts clean
    restorePathPointers();
}

// =============================================================================
// Install / remove hooks
// =============================================================================

pub fn installHooks() void {
    con.print("[combatlog] Module loaded\n");

    // Multi-DLL safety: only one instance per process should hook
    var mutex_name_buf: [64]u8 = undefined;
    const mutex_name = std.fmt.bufPrint(&mutex_name_buf, "Local\\WeirdUtils_CombatlogHook_{d}", .{GetCurrentProcessId()}) catch return;
    mutex_name_buf[mutex_name.len] = 0;

    g_mutex = CreateMutexA(null, 1, @ptrCast(mutex_name_buf[0..mutex_name.len :0]));
    if (g_mutex == null) return;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(g_mutex.?);
        g_mutex = null;
        g_is_hook_owner = false;
        con.print("[combatlog] Another DLL owns hooks (mutex taken), skipping\n");
        return;
    }
    g_is_hook_owner = true;

    // Paths are set up lazily on first InitializeLogBuffer call (after player login)

    if (init_log_hook.attach(o.FN_INIT_LOG_BUFFER, &initLogDetour) != .ok) {
        con.print("[combatlog] FAILED to hook InitializeLogBuffer!\n");
    } else {
        con.print("[combatlog] hooked InitializeLogBuffer OK\n");
    }

    if (write_log_hook.attach(o.FN_WRITE_FMT_LOG_MSG, &writeLogDetour) != .ok) {
        con.print("[combatlog] FAILED to hook WriteFormattedLogMessage!\n");
    } else {
        con.print("[combatlog] hooked WriteFormattedLogMessage OK\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        write_log_hook.detach();
        init_log_hook.detach();
        restorePathPointers();

        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
