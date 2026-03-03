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

/// Look up a unit name by GUID — two-step approach matching perfboost:
///   1. GetObjectPtr (0x464870) — __stdcall(u64 guid) → object ptr in EAX
///   2. CGUnit_C::GetUnitName (0x609210) — __thiscall(ECX=unit, stack: 0) → char*
fn getNameFromGUID(guid: u64) ?[*:0]const u8 {
    if (guid == 0) return null;

    // Step 1: GUID → object pointer via __stdcall (GUID pushed on stack as 8 bytes)
    const guid_lo: u32 = @truncate(guid);
    const guid_hi: u32 = @truncate(guid >> 32);
    const obj: u32 = asm volatile (
        \\ push %[hi]
        \\ push %[lo]
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [lo] "r" (guid_lo),
          [hi] "r" (guid_hi),
          [func] "r" (@as(u32, o.FN_GET_OBJECT_PTR)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
    if (obj == 0) return null;

    // Step 2: object pointer → name (__thiscall: ECX=this, push flag=0)
    const result: u32 = asm volatile (
        \\ push $0
        \\ call *%[func]
        : [ret] "={eax}" (-> u32),
        : [_] "{ecx}" (obj),
          [func] "r" (@as(u32, o.FN_GET_UNIT_NAME)),
        : .{ .ecx = true, .edx = true, .memory = true, .cc = true });
    return if (result != 0 and result >= 0x10000) @ptrFromInt(result) else null;
}

// =============================================================================
// Session marker
// =============================================================================

var g_session_marker_written: bool = false;

/// Write a COMBATLOG_SESSION line with the player's name to the combat log.
/// Called once after combat logging is first enabled for this session.
fn maybeWriteSessionMarker() void {
    // Read combat log handle — 0 means log not active yet
    const combat_handle = hook.readMem(u32, o.COMBAT_LOG_HANDLE);
    if (combat_handle == 0) return;

    const player_guid = getPlayerGUID();
    if (player_guid == 0) return;

    const name = getNameFromGUID(player_guid) orelse {
        // TODO: If player name is unavailable at this point (e.g.
        // LoggingCombat enabled before login), could hook OnWorldUpdate for a
        // per-frame retry until name is available.
        con.print("[combatlog] session marker: player name not yet available\n");
        return;
    };

    // Copy name to a stack buffer — the name cache pointer can be
    // invalidated by game-side log writes.
    var name_local: [49]u8 = undefined;
    const name_span = std.mem.span(name);
    const len = @min(name_span.len, name_local.len - 1);
    @memcpy(name_local[0..len], name_span[0..len]);
    name_local[len] = 0;

    con.fmt("[combatlog] player name: '{s}' (ptr=0x{x:0>8}, len={d})\n", .{
        name_local[0..len], @intFromPtr(name), len,
    });

    // WriteFormattedLogMessage — __stdcall(handle, fmt, va_list).
    // RET 0xC: callee cleans 12 bytes (3 args), no caller cleanup needed.
    // arg3 (va_list) is a pointer to the variadic args on the stack.
    // For %s, vsprintf reads *(char**)va_list, so va_list must point to a char*.
    const name_ptr: u32 = @intFromPtr(&name_local);
    const args = [3]u32{ combat_handle, @intFromPtr(@as([*:0]const u8, "COMBATLOG_SESSION: %s")), @intFromPtr(&name_ptr) };
    asm volatile (
        \\ push 8(%[a])
        \\ push 4(%[a])
        \\ push (%[a])
        \\ call *%[func]
        :
        : [a] "r" (&args),
          [func] "r" (@as(u32, o.FN_WRITE_FMT_LOG_MSG)),
        : .{ .eax = true, .ecx = true, .edx = true, .memory = true, .cc = true });

    g_session_marker_written = true;
    con.fmt("[combatlog] session: {s}\n", .{name_local[0..len]});
}

// =============================================================================
// EnableChatLogging hook
// =============================================================================

const fc = std.builtin.CallingConvention{ .x86_fastcall = .{} };

var enable_logging_hook: hook.Detour(fn (u32, u32) callconv(fc) u32) = .{};

fn enableChatLoggingDetour(lua_state: u32, index: u32) callconv(fc) u32 {
    // The Lua VM's luaCallFunction (0x6F6050) stores luaState in ESI and the
    // C function pointer in EDI, dispatches via CALL EDI, then reads [ESI+0x8]
    // expecting callee-saved registers preserved. Zig may not push ESI/EDI/EBX
    // in this function's prologue if it doesn't allocate them itself, but subcalls
    // (callOriginal wrapper, inline asm game calls) can clobber them without the
    // compiler knowing. This barrier forces Zig to push/pop ESI/EDI/EBX in the
    // prologue/epilogue and avoid using them for intermediates — guaranteeing
    // they're correctly restored on return to the Lua VM.
    asm volatile ("" ::: .{ .esi = true, .edi = true, .ebx = true });

    const result = enable_logging_hook.callOriginal(.{ lua_state, index });
    // index 1 = combat log
    if (index == 1 and !g_session_marker_written) {
        maybeWriteSessionMarker();
    }
    return result;
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

    // Hook EnableChatLogging to inject session marker on combat log enable
    if (enable_logging_hook.attach(o.FN_ENABLE_CHAT_LOGGING, &enableChatLoggingDetour) != .ok) {
        con.print("[combatlog] FAILED to hook EnableChatLogging!\n");
    } else {
        con.print("[combatlog] hooked EnableChatLogging OK\n");
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        enable_logging_hook.detach();
        restorePathPointer();

        if (g_mutex) |m| {
            _ = ReleaseMutex(m);
            _ = CloseHandle(m);
            g_mutex = null;
        }
    }
    g_is_hook_owner = false;
}
