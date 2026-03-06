# Combat Log Research

## Goal
Session-unique combat log files with player login markers, robust against rapid
client open/close and multiple simultaneous clients.

## Approach
- Overwrite string pointer at `0x00843610` to redirect combat log to timestamped+PID filename
- Hook `EnableChatLogging` (0x0049fe50) to inject session marker line on combat log enable
- Use Lua `PLAYER_ENTERING_WORLD` event hook to inject player login lines
- Optional: cleanup pass on startup for tiny/stale files

---

## String Table Layout

The combat log path is stored in a static pointer table in `.data` (WRITABLE):

```
0x0084360c -> 0x008441ec = "Logs\WoWChatLog.txt"     (index 0)
0x00843610 -> 0x008441d4 = "Logs\WoWCombatLog.txt"   (index 1)
```

Both the pointer table AND the string data are in `.data` section
(0x00827000-0x00882fff), which is R/W. No VirtualProtect needed.

## Section Map

```
.text   0x00401000-0x007fefff  R-X
.rdata  0x007ff000-0x00826fff  R--
.data   0x00827000-0x00882fff  RW-  <-- pointer table + strings are HERE
.data   0x00883000-0x00cfa153  RW-  <-- BSS (runtime globals)
```

## Global Arrays (BSS, runtime)

- `PTR_00b4fdb4[index]` -- enable flags (0=disabled, nonzero=enabled)
  - `[0]` = chat log enabled (0x00b4fdb4)
  - `[1]` = combat log enabled (0x00b4fdb8)
- `PTR_00b50540[index]` -- log buffer handles (returned by InitializeLogBuffer)
  - `[0]` = chat log handle (0x00b50540)
  - `[1]` = combat log handle (0x00b50544)

## Key Functions

### EnableChatLogging (0x0049fe50) -- __fastcall(ECX=lua_State, EDX=index)

Lua C function called as `LoggingCombat(bool)` / `LoggingChat(bool)`.
`param_2` (EDX) selects which log: 0=chat, 1=combat.

```
EnableChatLogging(lua_State *L, int index):
  if lua_gettop(L) > 0:
    enabled = LuaValueToBool(L, 1, true)
    enable_flags[index] = enabled
    if enabled and log_handles[index] == NULL:
      CreateDirectoryRecursive("Logs")
      log_handles[index] = InitializeLogBuffer(
          path_table[index],   // "Logs\WoWCombatLog.txt" for index=1
          4,                   // flags: append mode (bit 2 set)
          &log_handles[index])
      if failed: enable_flags[index] = 0
  return enabled ? 1.0 : nil
```

Disasm confirms __fastcall:
```
0x0049fe50: PUSH EBX
0x0049fe51: PUSH ESI
0x0049fe52: PUSH EDI
0x0049fe53: MOV ESI,EDX      ; index
0x0049fe55: MOV EDI,ECX      ; lua_State
```

Access pattern: `[ESI*4 + 0xb4fdb4]` (enable flags), `[ESI*4 + 0xb50540]` (handles).
Path loaded from: `[ESI*4 + 0x0084360c]` (path_table).

**HOOK TARGET**: This is where the path is read and passed to InitializeLogBuffer.
We can either:
1. Overwrite the pointer at `0x00843610` before this runs (simplest)
2. Or overwrite the string itself at `0x008441d4` (also simple, 21 chars available
   but we need more -- "Logs\WoWCombatLog_YYYYMMDD_HHMMSS_PPPPP.txt" = ~48 chars)

Since the original string buffer is only 22 bytes ("Logs\WoWCombatLog.txt\0"), we
MUST use the pointer redirect approach -- point `0x00843610` to our own static
buffer that has enough room for the longer name.

### InitializeLogBuffer (0x0065a0c0) -- __cdecl(filePath, flags, *handle)

Creates a log buffer context. The file path string is stored inside the context
object at offset +8 (via SafeStringCopy, max 0x104 = 260 bytes). The file handle
is at context+0x10c. File opening is lazy (bit 0 not set in flags=4, so
EnsureLogFileOpen opens on first write).

### CreateLogFile (0x0065a1c0) -- __fastcall(ECX=filePath, stack: *handle, flags)

Opens the actual file via `CreateFileA`. Uses `FILE_SHARE_READ | FILE_SHARE_WRITE`
(share mode 3). Append mode (flag bit 2) uses `OPEN_ALWAYS` + `SetFilePointer(END)`.

### EnsureLogFileOpen (0x0065a930) -- __fastcall(ECX=context)

Called before each write. If handle is -1, calls `CreateLogFile` with the stored
path from context+0x08. This is the lazy-open path.

### WriteFormattedLogMessage (0x0065ac20) -- __stdcall(handle, fmt, va_list)

**NOT cdecl variadic.** Three fixed params, callee cleans stack (`RET 0xC`).
The third argument is a `va_list` (pointer to variadic args), not the args
themselves. For `%s`, vsprintf reads `*(char**)va_list` to get the string pointer.

Disasm evidence:
```
0x0065ac20: PUSH EBP
0x0065ac21: MOV EBP,ESP
0x0065ac23: MOV ECX,[EBP+0x8]    ; handle
...
0x0065ac5d: MOV EAX,[EBP+0x10]   ; va_list
0x0065ac60: MOV ECX,[EBP+0xC]    ; fmt string
...
0x0065ac69: PUSH EAX              ; va_list -> vsprintf arg3
0x0065ac6a: PUSH ECX              ; fmt -> vsprintf arg2
0x0065ac6b: LEA EAX,[EDX+ESI+0x124]
0x0065ac72: PUSH EAX              ; dest buffer -> vsprintf arg1
0x0065ac73: CALL vsprintf         ; (0x7412c1) -- cdecl internally
0x0065ac78: ADD ESP,0xC           ; vsprintf cleanup (cdecl)
...
0x0065acdc: RET 0xC               ; stdcall -- callee cleans 3 args
```

Correct calling pattern from DLL:
```
// va_list must point to where the char* lives in memory
name_ptr = &name_buf;
push &name_ptr    // arg3: va_list (pointer TO the char*)
push fmt_str      // arg2: "COMBATLOG_SESSION,%s"
push handle       // arg1: combat log handle
call WriteFormattedLogMessage
// NO add esp -- callee cleans via RET 0xC
```

Previous crash: passing `&name_buf` directly as va_list caused vsprintf to
interpret the first 4 bytes of the name ("Munj" = 0x6A6E754D) as a char*,
crashing at strlen (0x0074300E: `CMP BYTE [EAX], 0`).

The main write path:
```
WriteFormattedLogMessage(handle, formatStr, va_list):
  context = GetLogBufferContext(handle)
  EnsureLogFileOpen(context)
  WriteTimestampToLogLine(context, 1)
  WriteIndentationSpaces(context)
  vsprintf(context_buffer + offset, formatStr, va_list)
  offset += strlen(...)
  WriteLogLineTerminator(context)
  if offset > 0xBFFF: WriteLogBufferToFile(context)  // auto-flush at 48KB
```

### WriteLogEntry (0x0063cb50) -- __fastcall(ECX=text, EDX=param2)

Higher-level: adds text to the in-memory chat log ring buffer AND dispatches
to file log buffers.

### LogCombatMessage (0x006268f0) -- uses ECX as message type index

Formats combat message strings. Accesses `[ESI*4 + 0x862920]` for format strings.

## Log Buffer Context Structure

```
+0x000: linked list prev?
+0x004: linked list next?
+0x008: char filePath[260]  (0x104 bytes) -- copied from InitializeLogBuffer arg
+0x10c: HANDLE fileHandle   (context[0x43]) -- INVALID_HANDLE_VALUE until open
+0x110: uint flags           (context[0x44])
+0x114: uint writeOffset     (context[0x45]) -- current position in buffer
+0x118: uint debugOffset     (context[0x46])
+0x11c: uint unknown         (context[0x47])
+0x120: uint active          (context[0x48])
+0x124: char buffer[]        (write buffer, flushed at 48KB)
```

## World Enter Events

- `PLAYER_LOGIN` at 0x00852d50 -- event table slot at 0x00be15d0
- `PLAYER_ENTERING_WORLD` at 0x00852d28 -- event table slot at 0x00be15d8

These are Lua event name strings in the game's event table. The event IDs are
the table indices (PLAYER_LOGIN = slot[0], PLAYER_ENTERING_WORLD = slot[2]).

## Player Name Resolution

The markers module already has the pattern:
- `GetPlayerGUID` (0x00468550) -- `__fastcall()`, returns EAX(lo):EDX(hi)
  - Actually `ClntObjMgrGetActivePlayer` -- returns player object pointer
  - Player object: +0x8 = GUID (8 bytes)
- `RetrieveNPCDataFromCache` (0x0055f080) -- `__thiscall(ECX=cache_obj)`, 6 stack params
  - Cache object at 0x00c0e228
  - (guid_lo, guid_hi, name_buf_ptr, 0, 0, 0) -> char* name or NULL
- `getRealmNameConfigValue` (0x005ab7d0) -- returns CVar value ptr
  - CVar "realmName" stored at PTR_00c28130+0x20

## CVar: combatLogOn

- String: `s_combatLogOn_008430d4`
- Registered in `InitializeGameInterface` (0x0048fbf0)
- Stored at global `DAT_00b4da38`

---

## Implementation Plan

### 1. Redirect Combat Log Path (session-unique files)

**At DLL init time** (before any Lua runs):
1. Format a timestamped path: `"Logs\WoWCombatLog_YYYYMMDD_HHMMSS_PID.txt"`
   into a static buffer in our DLL
2. Overwrite the pointer at `0x00843610` with the address of our buffer

This is race-free because:
- Each process has its own address space, so each gets its own pointer value
- The timestamp+PID combo is unique even for rapid client open/close
- The path is read lazily when `LoggingCombat(1)` is called from Lua,
  which happens after UI init -- well after our DLL loads

### 2. Player Login Line Injection

Two approaches, both viable:

**A. Hook EnableChatLogging** -- intercept the `LoggingCombat(1)` call. When
index=1 (combat log) and the call succeeds, immediately write a session marker.
This requires hooking a __fastcall function (5 bytes at prologue).

**B. Lua-side approach** -- register for `PLAYER_ENTERING_WORLD` in Lua and
have the handler call `WriteFormattedLogMessage` via our DLL's exported function.
Simpler but requires the combat log to already be enabled.

**Recommended**: Approach A for the session start marker (guarantees it's the
first line), plus Approach B for subsequent world-enter markers (zone changes,
logout/login). Use `WriteFormattedLogMessage(combat_handle, "COMBATLOG_SESSION,%s,%s")`
where combat_handle = `*(u32*)0x00b50544`.

### 3. Cleanup (phase 2)

On DLL init, scan `Logs\` directory for `WoWCombatLog_*.txt` files:
- Delete files < 1KB (empty sessions, client crashes before any combat)
- Optionally compress files older than N days

---

## Resolved Questions

- [x] Section at 0x00843610: `.data` (RW) -- no VirtualProtect needed
- [x] Player name: use `GetObjectName` (0x6264E0) - __fastcall(ECX=guid_ptr) → char*.
      RetrieveNPCDataFromCache (0x55f080) does NOT return char* in EAX - it returns
      name bytes. The actual pointer is written to the output buffer param.
      GetObjectName is simpler and verified by c_overlay reference.
- [x] Original string too short for timestamped name -- must use pointer redirect
- [x] **ESI clobber crash (ACCESS_VIOLATION at 0x6F61AF)**: luaCallFunction stores
      luaState in ESI and the C function pointer in EDI, dispatches via `CALL EDI`,
      then reads `[ESI+0x8]`. Our detour's compiled code (Debug build) did NOT push
      ESI/EDI/EBX in its prologue - Zig only saves callee-saved registers it
      allocates directly, but subcalls (callOriginal wrapper, inline asm game calls)
      can clobber them without the compiler knowing. **All game functions verified
      to preserve ESI/EDI/EBX**: GetPlayerGUID (0x468550, doesn't touch them),
      GetObjectName (0x6264E0, PUSH/POP ESI), WriteFormattedLogMessage (0x65AC20,
      PUSH/POP ESI). The clobber originates from Zig's generated code paths, not
      game functions. **Fix**: `asm volatile ("" ::: .{ .esi=true, .edi=true,
      .ebx=true })` barrier at top of detour forces Zig to push/pop in
      prologue/epilogue regardless of internal register allocation.

## Logout Detection

`CGGameUI_Shutdown` (0x490BD0) fires on `/reload` AND logout -- unsuitable for
per-session reset. The correct logout-only function is:

### World_HandleLogoutCleanup (0x491180) -- __stdcall(), no params

Only called from `ShutdownClientSystems` (0x401ee0), which is called from:
- `NetworkDisconnectHandler` (0x46c540)
- `handleDisconnectWithReason` (0x5aad70)
- `cleanupAfterDisconnect` (0x5aaeb0)

These are all real disconnect/logout paths. NOT called on `/reload` or map change.

`World_HandleLogoutCleanup` calls `World_HandlePlayerLogin` (0x490BD0) as its
first action, which fires `SignalEvent(271)` (PLAYER_LOGOUT).

Full cleanup sequence: World_HandlePlayerLogin (fires PLAYER_LOGOUT event),
UI_ProcessDirtyFaces, release_minimap_textures, ShutdownChatSubsystem,
SpellBookManager_Cleanup, CleanupUnitSystem, UnregisterPlayerStateHandlers, etc.

Hooked in `main.zig` as `logout_hook` -- available to all modules via `onLogout()`.

### Event IDs (verified via event table at 0xbe1198)

- PLAYER_LOGIN = 270 (table slot 0xbe15d0, string at 0x852d50)
- PLAYER_LOGOUT = 271 (table slot 0xbe15d4, string at 0x852d40)
- PLAYER_ENTERING_WORLD = 272 (table slot 0xbe15d8, string at 0x852d28)
- LOGOUT_CANCEL = event at table slot 0xbe15f0, string at 0x852cc4

### SignalEvent callers for login/logout events

- `SignalEvent(270)` PLAYER_LOGIN: from `CGGameUI::EnterWorld` (0x4908c0)
- `SignalEvent(271)` PLAYER_LOGOUT: from `World_HandlePlayerLogin` (0x490bd0)
- `SignalEvent(272)` PLAYER_ENTERING_WORLD: from `CGGameUI::EnterWorld` (0x4908c0)
- `SignalEvent(273)`: from `World_HandleEnterWorldCleanup` (0x490a80)

### Player Name Resolution

`GetObjectPtr` (0x464870) -> `GetUnitName` (0x609210) does NOT work during early
login -- player object not in object manager yet. Use name cache instead:
`RetrieveNPCDataFromCache` (0x55f080, cache at 0xc0e228) is populated before the
object manager and works for the local player GUID.

## SuperWoW Combat Log Interference

SuperWoWhook.dll has its own Lua C function `CombatLogAdd` (at 0x10001f50 in
the current build) that calls `InitializeLogBuffer` (0x0065a0c0) directly with
**hardcoded path strings**, bypassing the path pointer table at 0x0084360c entirely.

### SuperWoW CombatLogAdd (0x10001f50) logic

```
CombatLogAdd(lua_State *L):
  raw = LuaValueToBool(L, 2, false)    // arg2: is this a raw log event?
  if raw:
    handle_ptr = 0x1001e4c8            // SuperWoW's own handle (in DLL .bss)
    path = "Logs\WoWRawCombatLog.txt"  // hardcoded at 0x1001af00
  else:
    handle_ptr = 0x00b50544            // WoW's combat log handle
    path = "Logs\WoWCombatLog.txt"     // hardcoded at 0x1001aee8
  if *handle_ptr == 0:
    CreateDirectoryRecursive("Logs")
    InitializeLogBuffer(path, 4, handle_ptr)
  WriteTimestampToLogBuffer(*handle_ptr, fmt, value)
  return 1.0
```

### Why pointer redirect sometimes fails

When SuperWoW's `CombatLogAdd` fires before the game's `LoggingCombat(1)`:
1. SuperWoW calls `InitializeLogBuffer("Logs\WoWCombatLog.txt", 4, 0x00b50544)`
   using its own hardcoded string -- our pointer at 0x00843610 is never read
2. Handle at 0x00b50544 becomes non-zero
3. When `EnableChatLogging` runs later, it sees handle != 0 and skips init
4. Result: log file created with default name despite our pointer redirect

The "sometimes works" depends on whether the addon's `LoggingCombat(1)` or
SuperWoW's first `CombatLogAdd` call fires first.

### Fix: Hook InitializeLogBuffer

Instead of overwriting the path pointer, hook `InitializeLogBuffer` (0x0065a0c0)
itself. Intercept the `filePath` argument and replace:
- `"Logs\WoWCombatLog.txt"` -> our timestamped combat log path
- `"Logs\WoWRawCombatLog.txt"` -> our timestamped raw combat log path

This works regardless of who calls InitializeLogBuffer (game or SuperWoW).

`InitializeLogBuffer` is __stdcall with RET 0xC: (filePath, flags, *handleOut).
The path is copied into the context struct via SafeStringCopy (max 260 bytes),
so substituting a different pointer is safe.

### SuperWoW raw log handle

SuperWoW stores its raw combat log handle at `0x1001e4c8` (in SuperWoWhook.dll's
.bss section). This is NOT in WoW.exe's handle array -- it's SuperWoW-private.
The raw log path `"Logs\WoWRawCombatLog.txt"` is at `0x1001af00` in the DLL.

### ShutdownMessageSystem (0x00659ec0) -- __stdcall(handle), RET 0x4

Proper cleanup for a log buffer handle:
1. Gets log buffer context from handle
2. If file handle != -1: flushes (WriteLogBufferToFile), closes (CloseHandle)
3. Frees context memory (FreeMemoryFromPool)

Called from ShutdownChatSubsystem (0x00498700) which loops both handle slots.

## Open Questions

- [x] Exact prologue size of `EnableChatLogging` for hooking (need 5+ bytes).
      First 3 instructions = PUSH EBX; PUSH ESI; PUSH EDI = 3 bytes. Then
      MOV ESI,EDX = 2 bytes. Total = 5 bytes -- just enough for a jmp hook.
- [x] **Markers permission check**: markers' `getNameFromGUID` uses
      `RetrieveNPCDataFromCache` (0x55f080) and works correctly for roster GUIDs.
      The combatlog crash (EAX=name bytes instead of char*) is specific to the
      context -- either the player's own GUID is handled differently, or the cache
      state during `EnableChatLogging` is incomplete. Combatlog now uses
      RetrieveNPCDataFromCache directly (same pattern as markers) and it works.
- [x] **Player name at EnableChatLogging time**: name cache IS populated when
      LoggingCombat(1) fires. The GetObjectPtr path failed because the object
      manager isn't ready, not because the name isn't known.
- [x] **Session marker ordering**: Hooking WriteFormattedLogMessage (0x65ac20)
      directly guarantees our marker is the first line -- intercepts the first
      write to the combat log handle and prepends the session marker.
