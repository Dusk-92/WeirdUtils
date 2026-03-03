//! Address constants for combat log session rotation.

// =============================================================================
// Combat log path and state
// =============================================================================

/// Path table pointer — .data section (RW), points to "Logs\WoWCombatLog.txt" string.
/// Index 0 (0x0084360c) = chat log, index 1 (0x00843610) = combat log.
/// Overwriting the u32 at this address redirects where the combat log file is created.
pub const COMBAT_LOG_PATH_PTR: usize = 0x00843610;

/// Runtime combat log buffer handle (log_handles[1], BSS).
/// Non-zero when combat logging is active. Read to check if we can write log lines.
pub const COMBAT_LOG_HANDLE: usize = 0x00b50544;

// =============================================================================
// Log writing
// =============================================================================

/// WriteFormattedLogMessage — __stdcall(handle: u32, fmt: [*:0]const u8, va_list: *anyopaque).
/// Three fixed params, callee cleans stack (RET 0xC). Third arg is va_list pointer.
/// Writes a timestamped, formatted line to the log buffer. Auto-flushes at 48KB.
pub const FN_WRITE_FMT_LOG_MSG: usize = 0x0065ac20;

// =============================================================================
// Combat log enable
// =============================================================================

/// EnableChatLogging — __fastcall(ECX=lua_State, EDX=index).
/// index 0=chat, 1=combat. Called by LoggingCombat()/LoggingChat() Lua functions.
/// Reads path from path_table[index] and opens log file on first enable.
pub const FN_ENABLE_CHAT_LOGGING: usize = 0x0049fe50;

// =============================================================================
// Player identity (shared with markers module)
// =============================================================================

/// GetPlayerGUID — __fastcall(), no params, returns EAX(low):EDX(high).
pub const FN_GET_PLAYER_GUID: usize = 0x00468550;

/// GetObjectPtr — __stdcall(u64 guid) → object ptr in EAX.
/// GUID is pushed on the stack as 8 bytes. (perfboost: 0x464870)
pub const FN_GET_OBJECT_PTR: usize = 0x00464870;

/// CGUnit_C::GetUnitName — __thiscall(ECX=unit_ptr, stack: flag=0) → char* in EAX.
/// (perfboost: 0x609210)
pub const FN_GET_UNIT_NAME: usize = 0x00609210;
