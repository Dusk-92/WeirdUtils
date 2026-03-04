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
// Player identity
// =============================================================================

/// GetPlayerGUID — __fastcall(), no params, returns EAX(low):EDX(high).
pub const FN_GET_PLAYER_GUID: usize = 0x00468550;

/// RetrieveNPCDataFromCache — __thiscall(ECX=cache_obj), 6 stack params, RET 0x18.
/// (guid_low, guid_high, name_buf_ptr, 0, 0, 0) → char* name or NULL in EAX.
/// Resolves player/NPC names from the name cache — available before the object manager.
pub const FN_NAME_CACHE_LOOKUP: usize = 0x0055f080;

/// Name cache object — static instance passed as ECX (this) to RetrieveNPCDataFromCache.
pub const NAME_CACHE_OBJ: usize = 0x00c0e228;
