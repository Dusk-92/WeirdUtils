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
  -> SetupAddonProcessing (0x0051c740)
    -> ProcessAddonDirectory (0x0051c760)
      -> EnumerateDirectoryWithCallback("Interface\\AddOns\\", ...) -- filesystem scan
        -> ProcessAddonFilePath (0x0051c910) -- per .toc file found
          -> LoadAddonTOC (0x0051c9b0) -- parses TOC, registers addon in hash table
                                        -- reads TOC via LoadFileWithTextureResourceFallback (hookable!)

InitializeGameInterface (0x0048fbf0)
  -> LoadAddonSavedVariables (0x0051ebe0) -- loads WTF/.../AddOns.txt (enabled/disabled state per addon)
  -> LoadAddonsRecursively (0x0051f600) -- iterates registered addon list
    -> LoadAddonRecursive (0x0051f242) -- per addon:
      1. loadFileListWithIncludes() -- loads TOC file list (.lua/.xml)
      2. Loads Bindings.xml if exists
      3. Loads WTF/Account/<acct>/SavedVariables/<name>.lua (account-wide)
      4. Loads WTF/Account/<acct>/<realm>/<char>/SavedVariables/<name>.lua (per-character)
      5. FireLuaEvent(0x1ad) -- ADDON_LOADED event
  -> Config_LoadSavedVariables (0x0051f650) -- called from World_HandlePlayerLogin (0x00490bd0) on logout/exit
```

### Key Functions

| Address    | Name                       | Convention | Notes |
|------------|----------------------------|------------|-------|
| 0x0051c740 | SetupAddonProcessing       | ?          | Calls ProcessAddonDirectory |
| 0x0051c760 | ProcessAddonDirectory      | cdecl/void | Scans filesystem, builds addon list |
| 0x0051c910 | ProcessAddonFilePath       | __fastcall(ECX=path) | Per-.toc callback, strips prefix, calls LoadAddonTOC |
| 0x0051c9b0 | LoadAddonTOC               | __fastcall(ECX=addonName) | Parses TOC, registers addon. RET (no stack cleanup) |
| 0x0051ebe0 | LoadAddonSavedVariables    | __fastcall(ECX=addonName or NULL for all) | Loads AddOns.txt state |
| 0x0051f242 | LoadAddonRecursive         | __fastcall(ECX=addonName, EDX=loadFlag, stack=callback) | Loads one addon + saved vars |
| 0x0051f600 | LoadAddonsRecursively      | __fastcall(ECX=callback) | Iterates all registered addons |
| 0x0051f650 | SaveAddonVariables         | cdecl/void | Writes all dirty addons' saved vars to WTF/ |
| 0x0051fa40 | ShutdownAddonSystem        | ?          | Cleanup |

### Addon Data Structure (hash table entry)

```
+0x00: u32  hash of addon name
+0x04: ...  (hash table linkage)
+0x14: *u8  addon name string (entry[5])
+0x18: u8   dirty flag (needs variable save)
+0x19: u8   loaded flag (entry[6] byte 1)
+0x1c: u32  interface version (## Interface)
+0x20: u32  revision (## Revision)
+0x26-0x2f: hash table for Title/Notes/Author/Version metadata
+0x28: u8   secure flag (## Secure)
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
```

### Key Globals

| Address    | Name | Purpose |
|------------|------|---------|
| 0x00be1b6c | PTR_00be1b6c | Addon linked list head |
| 0x00be1b64 | PTR_00be1b64 | Linked list base for traversal (node+4 offset) |
| 0x00be1b7c | PTR_00be1b7c | Hash table buckets array |
| 0x00be1b84 | PTR_00be1b84 | Hash table mask (0xffffffff = uninitialized) |
| 0x00be1bd8 | PTR_00be1bd8 | Saved variables state list head |
| 0x00be1b60 | PTR_00be1b60 | Hash table control structure |

### Fix: Hook SetupAddonProcessing

`LoadAddonTOC` reads the TOC file via `LoadFileWithTextureResourceFallback`, which our `loadFileDetour` already intercepts. So calling `LoadAddonTOC("MinimapIcons")` will:
1. Hit our file hook, serve the embedded TOC content
2. Parse `## SavedVariablesPerCharacter: WeirdUtils_MinimapIconsSettings`
3. Register the addon in the hash table with the variable name at +0x78/7c/80

Hook `SetupAddonProcessing` (0x0051c740). After calling the original (which runs `ProcessAddonDirectory` and initializes the addon system), call `LoadAddonTOC` for each DLL-embedded addon. This ensures:
- The addon memory pool is initialized
- Our addons appear in the list before `LoadAddonsRecursively` runs
- `LoadAddonRecursive` will find our addon, load its files (via our hook), load saved vars from WTF/, and fire ADDON_LOADED
- `SaveAddonVariables` will find our addon and write its variables to WTF/ on logout

This also means **Bindings.xml** will be loaded automatically if included in the TOC -- no need to handle it separately.

### Verification Plan

1. Hook `SetupAddonProcessing`, call `LoadAddonTOC("MinimapIcons")` after original
2. Check console for `[file] served embedded` messages for the .toc read during `LoadAddonTOC`
3. Toggle some NPC categories, log out
4. Check `WTF/Account/<acct>/<realm>/<char>/SavedVariables/MinimapIcons.lua` exists on disk
5. Re-login, verify toggles persisted
