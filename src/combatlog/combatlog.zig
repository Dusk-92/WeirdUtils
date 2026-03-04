//! Combat log session rotation.
//!
//! Redirects the combat log to a per-session file named with timestamp + PID
//! (e.g. `Logs\WoWCombatLog_20260303_193045_1234.txt`), and writes a
//! `COMBATLOG_SESSION,<PlayerName>` marker line when combat logging is enabled.
//!
//! All DLL-side — no Lua addon needed.

const std = @import("std");
const hook = @import("zhook");
const con = @import("../console.zig");
const o = @import("offsets.zig");

const WINAPI = std.builtin.CallingConvention.winapi;
extern "kernel32" fn CreateMutexA(lpMutexAttributes: ?*anyopaque, bInitialOwner: i32, lpName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReleaseMutex(hMutex: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
const ERROR_ALREADY_EXISTS: u32 = 183;

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
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(WINAPI) void;

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;

// =============================================================================
// Path redirect
// =============================================================================

/// Static buffer for the redirected combat log path. Must outlive the process.
var g_path_buf: [260]u8 = undefined;

/// Saved original path pointer so we can restore on unload.
var g_original_path_ptr: u32 = 0;

fn setupPathRedirect() void {
    // Save the original pointer value
    g_original_path_ptr = hook.readMem(u32, o.COMBAT_LOG_PATH_PTR);

    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);
    const pid = GetCurrentProcessId();

    const path = std.fmt.bufPrint(&g_path_buf, "Logs\\WoWCombatLog_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}_{d}.txt", .{
        st.wYear, st.wMonth,  st.wDay,
        st.wHour, st.wMinute, st.wSecond,
        pid,
    }) catch {
        con.print("[combatlog] path format error\n");
        return;
    };
    g_path_buf[path.len] = 0;

    // Overwrite the pointer at 0x00843610 to point to our buffer.
    // .data section is RW, no VirtualProtect needed.
    const ptr_bytes: [4]u8 = @bitCast(@intFromPtr(&g_path_buf));
    hook.writeMem(o.COMBAT_LOG_PATH_PTR, &ptr_bytes);

    con.fmt("[combatlog] path: {s}\n", .{path});
}

fn restorePathPointer() void {
    if (g_original_path_ptr != 0) {
        const ptr_bytes: [4]u8 = @bitCast(g_original_path_ptr);
        hook.writeMem(o.COMBAT_LOG_PATH_PTR, &ptr_bytes);
        g_original_path_ptr = 0;
    }
}

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
/// Available before the object manager is populated (unlike GetObjectPtr → GetUnitName).
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

// =============================================================================
// Session marker state
// =============================================================================

var g_session_marker_written: bool = false;

// =============================================================================
// WriteFormattedLogMessage hook — inject session marker on first combat log write
// =============================================================================

const sc = std.builtin.CallingConvention{ .x86_stdcall = .{} };

var write_log_hook: hook.Detour(fn (u32, u32, u32) callconv(sc) void) = .{};

fn writeLogDetour(handle: u32, fmt: u32, va_list: u32) callconv(sc) void {
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    // On first write to combat log, prepend our session marker
    if (!g_session_marker_written) {
        const combat_handle = hook.readMem(u32, o.COMBAT_LOG_HANDLE);
        if (handle == combat_handle and combat_handle != 0) {
            writeSessionMarkerNow(handle);
        }
    }

    write_log_hook.callOriginal(.{ handle, fmt, va_list });
}

/// Resolve player name and write COMBATLOG_SESSION via callOriginal.
fn writeSessionMarkerNow(handle: u32) void {
    const player_guid = getPlayerGUID();
    if (player_guid == 0) return;
    const guid_lo: u32 = @truncate(player_guid);
    const guid_hi: u32 = @truncate(player_guid >> 32);

    const name = getNameFromGUID(guid_lo, guid_hi) orelse {
        con.print("[combatlog] session marker: player name not in cache yet\n");
        return;
    };

    // Copy name to stack buffer — cache pointer can be invalidated by the write
    var name_local: [49]u8 = undefined;
    const name_span = std.mem.span(name);
    const len = @min(name_span.len, name_local.len - 1);
    @memcpy(name_local[0..len], name_span[0..len]);
    name_local[len] = 0;

    // va_list for %s: pointer to a char*
    const name_ptr: u32 = @intFromPtr(&name_local);
    write_log_hook.callOriginal(.{
        handle,
        @intFromPtr(@as([*:0]const u8, "COMBATLOG_SESSION: %s")),
        @intFromPtr(&name_ptr),
    });

    g_session_marker_written = true;
    con.fmt("[combatlog] session marker written: {s}\n", .{name_local[0..len]});
}

/// Resets session marker so the next login's first write gets a new marker.
/// Called from both logoutDetour (real logout) and shutdownDetour (logout/exit/reload).
pub fn onShutdown() void {
    if (g_session_marker_written) {
        g_session_marker_written = false;
        con.print("[combatlog] session marker reset\n");
    }
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

    // Redirect combat log path to timestamped+PID filename
    setupPathRedirect();

    // Hook WriteFormattedLogMessage to inject session marker before the first combat log write
    if (write_log_hook.attach(o.FN_WRITE_FMT_LOG_MSG, &writeLogDetour) != .ok) {
        con.print("[combatlog] FAILED to hook WriteFormattedLogMessage!\n");
    } else {
        con.print("[combatlog] hooked WriteFormattedLogMessage OK\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        write_log_hook.detach();
        restorePathPointer();

        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
