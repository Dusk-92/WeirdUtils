# MinimapIcons Research

## SavedVariables -- Addon Registration System

### Problem
DLL-embedded addons are served via `loadFileDetour` (hook on `LoadFileWithTextureResourceFallback` at 0x648620). The game reads our embedded .toc and .lua files successfully, but **SavedVariablesPerCharacter never persists to disk**. The addon's toggle state resets every session.

### Root Cause
The game discovers addons by scanning `Interface\AddOns\` on the **filesystem** via `EnumerateDirectoryWithCallback`. Since our addon has no real directory on disk, `ProcessAddonFilePath` is never called, `LoadAddonTOC` never runs, and the addon is never registered in the internal addon hash table. Without registration, the save system has no record of which variables to persist.

The addon's .lua code still runs (served via `loadFileDetour`), but it's loaded through a different path -- `loadFileListWithIncludes` reads the TOC file list and loads each .lua/.xml, all of which go through our hook. The disconnect is that `LoadAddonTOC` (which parses `## SavedVariablesPerCharacter` and registers the variable names) only runs during the directory-scan phase.

### Addon Loading Sequence

```
HandleLogin (0x0046afb0)
  -> SetupAddonProcessing (0x0051c740) -- __fastcall(ECX=mgr_ptr), RET
    -> ShutdownAddonSystem (0x0051fa40) -- clears old state
    -> ProcessAddonDirectory (0x0051c760) -- filesystem scan
      -> EnumerateDirectoryWithCallback("Interface\\AddOns\\", ...)
        -> ProcessAddonFilePath (0x0051c910) -- per .toc file found
          -> LoadAddonTOC (0x0051c9b0) -- parses TOC, registers addon in hash table
                                        -- reads TOC via LoadFileWithTextureResourceFallback (hookable!)
  -> [our hook: callLoadAddonTOC per non-hidden embedded addon]

InitializeGameInterface (0x0048fbf0)
  -> LoadAddonSavedVariables (0x0051ebe0) -- loads WTF/.../AddOns.txt (enabled/disabled state per addon)
  -> LoadAddonsRecursively (0x0051f600) -- iterates registered addon list
    -> LoadAddonRecursive (0x0051f242) -- per addon:
      1. loadFileListWithIncludes() -- loads TOC file list (.lua/.xml)
      2. Loads Bindings.xml via preloadFileWithFlags (does NOT go through our file hook)
      3. Loads WTF/Account/<acct>/SavedVariables/<name>.lua (account-wide)
      4. Loads WTF/Account/<acct>/<realm>/<char>/SavedVariables/<name>.lua (per-character)
      5. FireLuaEvent(0x1ad) -- ADDON_LOADED event
  -> [our hook: for hidden addons, callLoadFileListWithIncludes + callLoadUIBindingsFromFile]
  -> [our hook: for all addons with Bindings.xml, callLoadUIBindingsFromFile]
  -> SaveAddonVariables (0x0051f650) -- called from World_HandlePlayerLogin (0x00490bd0) on logout
```

### Key Functions

| Address    | Name                       | Convention | Notes |
|------------|----------------------------|------------|-------|
| 0x0051c740 | SetupAddonProcessing       | __fastcall(ECX=mgr_ptr), RET | Calls ShutdownAddonSystem + ProcessAddonDirectory |
| 0x0051c760 | ProcessAddonDirectory      | cdecl/void | Scans filesystem, builds addon list |
| 0x0051c910 | ProcessAddonFilePath       | __fastcall(ECX=path) | Per-.toc callback, strips prefix, calls LoadAddonTOC |
| 0x0051c9b0 | LoadAddonTOC               | __fastcall(ECX=addonName), RET | Parses TOC, registers addon in hash table |
| 0x0051d410 | ProcessAddonInterface      | __fastcall(ECX=addonData) | Reads .pub file for secure addons |
| 0x0051d4c0 | ProcessAddonURL            | __fastcall(ECX=addonData) | Reads .url file |
| 0x0051ebe0 | LoadAddonSavedVariables    | __fastcall(ECX=addonName or NULL for all) | Loads AddOns.txt state |
| 0x0051f242 | LoadAddonRecursive         | __fastcall(ECX=addonName, EDX=loadFlag, stack=callback) | Loads one addon + saved vars |
| 0x0051f600 | LoadAddonsRecursively      | __fastcall(ECX=callback) | Iterates all registered addons |
| 0x0051f650 | SaveAddonVariables         | cdecl/void | Writes all dirty addons' saved vars to WTF/ |
| 0x0051fa40 | ShutdownAddonSystem        | ? | Cleanup |
| 0x0064b3f0 | String_ComputeHash         | **__stdcall(string)**, RET 0x4 | NOT fastcall! Reads from [EBP+8]. Returns hash in EAX |
| 0x0051def0 | GetAddonCount              | cdecl | Returns PTR_00be1b90 |
| 0x0051df00 | GetAddonByIndex            | __fastcall(ECX=index) | Returns PTR_00be1b94[index] |
| 0x0051e3e0 | IsAddonSecure              | __fastcall(ECX=name) | Returns addon[0x30] byte (from .pub parsing) |
| 0x0051e470 | ValidateCommandAccess      | __fastcall(ECX=name, EDX=acctName, stack=flag) | Checks addon enabled state |
| 0x0051e780 | EnableAddonWithDependencies | __fastcall(ECX=name, ...) | Validates + enables addon |
| 0x0051e980 | GetAddonSecurityString     | __fastcall(ECX=state) | Returns PTR_s_SECURE_0085367c[state] |
| 0x0051e990 | GetAddonState              | __fastcall(ECX=name) | Returns addon[9] (+0x24) from hash table |

### Addon Data Structure (hash table entry)

```
+0x00: u32  hash of addon name
+0x04: ...  (hash table linkage)
+0x14: *u8  addon name string (entry[5])
+0x18: u8   dirty flag (needs variable save)
+0x19: u8   loaded flag (entry[6] byte 1)
+0x1c: u32  interface version (## Interface)
+0x20: u32  revision (## Revision)
+0x24: u32  security state (0=SECURE, 1=INSECURE, 2=BANNED)
+0x26-0x2f: hash table for Title/Notes/Author/Version metadata
+0x28: u8   secure TOC flag (## Secure) -- triggers .pub validation
+0x2b: u8   default state enabled/disabled (## DefaultState)
+0x2c: u8   load on demand flag (## LoadOnDemand)
+0x34: u32  line count in TOC

Dynamic arrays (each: capacity/count/data_ptr/growth at 3 dword intervals):
+0x38/3c/40/44: OptionalDeps (## OptionalDep)
+0x48/4c/50/54: RequiredDeps (## RequiredDep / ## Dep)
+0x58/5c/60/64: LoadWith/Dependencies (## LoadWith)
+0x68/6c/70/74: SavedVariables (## SavedVariables) -- account-wide
+0x78/7c/80/84: SavedVariablesPerCharacter (## SavedVariablesPerCharacter)
+0x8c-0x98:     dependents array

+0xC1: u8   .pub type byte (from ParseAddonInterfaceData)
+0xC2: [256]u8  .pub key data (256 bytes)
+0x1C2: [16]u8  MD5 hash for signature validation
```

### Key Globals

| Address    | Name | Purpose |
|------------|------|---------|
| 0x00be1b60 | PTR_00be1b60 | Hash table control structure |
| 0x00be1b64 | PTR_00be1b64 | Linked list base for traversal (node+4 offset) |
| 0x00be1b6c | PTR_00be1b6c | Addon linked list head |
| 0x00be1b7c | PTR_00be1b7c | Hash table buckets array |
| 0x00be1b84 | PTR_00be1b84 | Hash table mask (0xffffffff = uninitialized) |
| 0x00be1b90 | PTR_00be1b90 | Flat addon count (for GetAddonCount) |
| 0x00be1b94 | PTR_00be1b94 | Flat addon array (for GetAddonByIndex) |
| 0x00be1bd8 | PTR_00be1bd8 | Saved variables state list head |

### Hash Table Structure
- Buckets at PTR_00be1b7c, mask at PTR_00be1b84
- Each bucket is 12 bytes: `[+0] next_offset, [+4] ?, [+8] list_head_ptr`
- Node traversal: `next = *(node + bucket.next_offset + 4)`
- Lookup: compute hash via `String_ComputeHash`, bucket = `mask & hash`, walk chain comparing hash then name

## Addon Security System

### Security States (+0x24)
- **0 = SECURE** -- Blizzard addon, hidden from addon list, always loaded
- **1 = INSECURE** -- Normal third-party addon, shown in list
- **2 = BANNED** -- Failed signature validation, shown as "Banned"

String table at `PTR_s_SECURE_0085367c` indexed by state value.

### Signature Validation Flow
When `## Secure: 1` is in the TOC:
1. `LoadAddonTOC` sets `+0x28` secure flag, then calls `ProcessAddonInterface` + `ProcessAddonURL`
2. `ProcessAddonInterface` (0x0051d410) reads `Interface\AddOns\<name>\<name>.pub` via `LoadFileWithTextureResourceFallback`
3. `.pub` file must be exactly **257 bytes**: 1 byte type + 256 bytes public key
4. Stored at addon struct `+0xC1` (type) and `+0xC2` (key data)
5. Later in `LoadAddonRecursive`, MD5 hash of addon files is compared against signature
6. If no valid `.pub` or signature mismatch: security state set to **2 (BANNED)**

### Hiding Addons -- Approaches Tried

**Approach 1: `## Secure: 1` in TOC** -- FAILED
Sets secure flag but without a valid `.pub` file, `ProcessAddonInterface` runs and the addon
ends up as BANNED (state 2). Cannot forge a valid `.pub` without Blizzard's private key.

**Approach 2: Patch +0x24 after LoadAddonTOC** -- NOT VERIFIED
After calling `LoadAddonTOC`, look up addon in hash table and write 0 to `+0x24`.
Issue: `String_ComputeHash` is `__stdcall` NOT `__fastcall` -- initial crash was caused
by calling it via `hook.fastcall` which passed the string pointer in ECX instead of on
the stack. Fixed to use direct function pointer cast with `callconv(sc)`.
The write logic itself was not verified to work at runtime before being removed.

**Approach 3: Skip LoadAddonTOC for hidden addons** -- CURRENT
Hidden addons (`hidden = true` in EmbedModule) are NOT registered via `LoadAddonTOC` at all.
They don't appear in the addon hash table, so the game doesn't know about them.
Their files are loaded directly via `callLoadFileListWithIncludes` in `loadAddonsDetour`,
same as the original pre-SavedVariables approach. This means they are invisible in the
addon list but also cannot have SavedVariables.

### Current Implementation

Two-tier addon loading controlled by `EmbedModule.hidden`:

**Visible addons** (`hidden = false`):
- Registered via `LoadAddonTOC` in `setupAddonsDetour` (hook on SetupAddonProcessing)
- Appear in charselect addon list as INSECURE (normal)
- Game handles file loading, SavedVariables, ADDON_LOADED events
- Bindings.xml loaded explicitly (preloadFileWithFlags bypass)

**Hidden addons** (`hidden = true`):
- NOT registered via `LoadAddonTOC` -- invisible in addon list
- Files loaded directly via `callLoadFileListWithIncludes` in `loadAddonsDetour`
- Bindings.xml loaded explicitly
- No SavedVariables support (no addon hash table entry)

| Addon | Hidden |
|-------|--------|
| WeirdUtils_Screenshot | yes |
| WeirdUtils_Interact | no |
| WeirdUtils_Outline | no |
| WeirdUtils_WorldMarkers | yes |
| WeirdUtils_LogSessions | no |
| WeirdUtils_MinimapIcons | no |

### Future: Proper Addon Hiding
To revisit Approach 2 (patching +0x24 to SECURE after registration), need to:
1. Verify `markAddonSecure` hash table traversal with debug logging
2. Confirm `hook.writeMem` actually writes to the addon struct
3. Check if `GetAddonState` is the only thing the UI reads, or if there are other
   security-related fields that also need patching
4. Investigate whether generating a valid `.pub` + MD5 signature is feasible
   (likely needs Blizzard's private key, but the validation algorithm is in-binary)

## Login Screen Addon List

### Architecture

Two separate Lua C function tables exist for addon management:
- **Glue (login/charselect) table** at 0x008374a0 -- functions in 0x0046dxxx range
- **In-game table** at 0x0083e488 -- functions in 0x0048exxx range

Both read from the **same** underlying addon data.

#### Glue Lua Functions (charselect screen)

| Address    | Function |
|------------|----------|
| 0x0046d420 | GetNumAddOns |
| 0x0046d460 | GetAddOnInfo -- returns: name, title, notes, url, loadable, reason, security, isNew |
| 0x0046d5e0 | LaunchAddOnURL |
| 0x0046d650 | GetAddOnDependencies |
| 0x0046d6f0 | GetAddOnEnableState |
| 0x0046d7b0 | EnableAddOn |
| 0x0046d850 | EnableAllAddOns |
| 0x0046d8a0 | DisableAddOn |
| 0x0046d940 | DisableAllAddOns |
| 0x0046d990 | SaveAddOns |
| 0x0046d9a0 | ResetAddOns |

### Data Path
- `GetAddonCount` (0x0051def0): returns `PTR_00be1b90` (simple count)
- `GetAddonByIndex` (0x0051df00): returns `PTR_00be1b94[index]` (flat array of addon ptrs)

These are a flat indexed view, separate from the hash table (PTR_00be1b7c) and
linked list (PTR_00be1b6c). Registered addons appear in the list after `SetupAddonProcessing`.

### Open Questions

1. **When is PTR_00be1b90/PTR_00be1b94 populated?** Need to find xrefs to determine
   who writes to it and when relative to our hook.

2. **Enable/Disable persistence**: `EnableAddOn`/`DisableAddOn` write to `AddOns.txt`
   via `SaveAddOns`. The DLL could check this file or the addon struct's enabled field
   at startup to decide whether to install hooks for a given module.
