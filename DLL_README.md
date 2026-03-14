# WeirdUtils

This package provides many pre-built DLLs for enhancing the vanilla 1.12 client WoW gameplay experience, aimed in particular at ease of use and accessibility but also bug fixes.

You may get all features by installing `weirdutils.dll`, or choose any selection of features via individual DLLs.  
On Turtle WoW, place your chosen DLLs next to your `WoW.exe` and add them to your `dlls.txt`. For other versions you will need some sort of DLL loader.  

---

## Features

### World Markers

Place up to 5 animated colored markers (Cataclysm style) at any position in the world, useful for raid positioning, pull planning, or route marking. Requires party/raid leader or raid assist.

- `/worldmarker 1` through `/worldmarker 5` (or `/wm 1`) -- place a marker where your cursor is pointing
- `/worldmarker 1 target` -- place a marker on a unit (player, target, mouseover, etc.)
- `/clearworldmarker` (or `/cwm`) -- remove all markers
- `/clearworldmarker 2` -- remove a specific marker

Keybindings for placing each marker and clearing all markers are available in the Key Bindings menu.

Markers automatically sync with group members who also have WeirdUtils installed. When a leader/assist places or clears a marker, all group members see it. Markers persist across zone transitions and respawn when you return to the area.

Lua API for addon developers:

- `WorldMarker(index)` -- place marker at cursor (returns x,y,z,areaId on success, nil if no permission, -1 on failure)
- `WorldMarker(index, "unit")` -- place marker at a unit's position
- `WorldMarker(index, x, y, z)` -- place marker at world coordinates
- `ClearWorldMarker(index)` / `ClearWorldMarker()` -- remove one or all markers (returns 1 on success, nil if no permission)
- `GetWorldMarker(index)` -- returns x,y,z,areaId for an active marker, nil if empty
- `CanSetWorldMarker()` -- returns 1 if the local player is party/raid leader or raid assist, nil otherwise

**DLL:** `worldmarkers.dll`

---

### Outlines

Renders glowing colored outlines around units, improving visibility in crowded encounters.

- `/outlines` or `/ol` -- toggle outlines on or off

A keybinding is available in the Key Bindings menu.

**DLL:** `outline.dll`

---

### Interact

Smart interaction helpers for faster farming and dungeon runs:

- **Interact Nearest** -- right-clicks the closest interactable NPC or object within 5 yards
- **Loot All Corpses** -- bulk loots all nearby corpses in sequence

Best used via keybindings (available in the Key Bindings menu) or macros:
```
/run InteractNearest(1)
/run LootAllCorpses()
```

**DLL:** `interact.dll`

---

### PNG Screenshots

Saves screenshots as compressed PNG files instead of the default uncompressed TGA format. Runs on a background thread with no frame drops.

Controlled via the `screenshotQuality` CVar (saved to config.wtf):

- `/script SetCVar("screenshotQuality", "6")` -- set compression level (1 = fast, 9 = smallest, default 6)
- `/script SetCVar("screenshotQuality", "0")` -- disable PNG, use original TGA format

**DLL:** `pngscreenshots.dll`

---

### Crash Fix

Prevents a class of crashes caused by stale UI frame anchor pointers. No configuration needed, install and forget.

**DLL:** `framecrash.dll`

---

### Transmog Fix

Eliminates FPS drops caused by rapid equipment visual updates when transmogged items lose durability. No configuration needed, install and forget.

**DLL:** `transmogfix.dll`

---

### Custom Data/ Assets

Enables loading loose game asset files (models, textures, etc.) from the `Data/` directory without repacking MPQ archives. Place files in `Data/` mirroring the game's internal paths (e.g. `Data/Character/Troll/Female/TrollFemale.m2`) and they will be used instead of the MPQ version.

Also allows multi-character patch archive names (e.g. `patch-12.mpq`, `patch-jimbo.mpq`).

Patch archives are sorted case-insensitively by filename - last in the sort gets highest priority, and all patches override the base archives.

No configuration needed, install and forget.

**DLL:** `customassets.dll`

---

### Utility Minimap Trackings

Adds TBC-style minimap tracking icons for NPC types (vendors, trainers, innkeepers, etc.) and game objects (mailboxes).  
Replaces the native tracking dropdown with a combined menu showing both spell tracking and NPC category tracking.  
Can be disabled easily from normal AddOn menu.  

- Click the minimap tracking icon to open the dropdown
- Check/uncheck NPC categories to toggle their minimap icons
- Spell tracking (Hunter tracking, Find Herbs, etc.) remains available alongside NPC tracking

Supports many NPC types such as Auctioneer, Banker, Flightmaster, Repair, Reagents, Poisons, and more  
Supported game objects: Mailbox, Brainwasher  

**DLL:** `minimapicons.dll`

---

### Clickthrough

Makes interactable Objects and NPCs clickable through players and units.

- Players blocking interactable NPCs (vendors, trainers, flight masters, bankers, etc.) or Objects (mailboxes, summoning portals, soulwells) become transparent to clicks
- Units (pets, NPCs) blocking interactable Objects become transparent to clicks
- PvP objects and Non-interactable objects (other players' pets, random mobs) are not affected, this solely helps with player dogpiles

No configuration needed, install and forget.

**DLL:** `clickthrough.dll`

---

### Log Sessions

Organizes the combat, raw combat, and chat logs into per-character directories with timestamped filenames:

```
Logs\<Realm>\<Character>\WoWChatLog_YYYYMMDD_HHMMSS.txt
Logs\<Realm>\<Character>\WoWCombatLog_YYYYMMDD_HHMMSS.txt
Logs\<Realm>\<Character>\WoWRawCombatLog_YYYYMMDD_HHMMSS.txt (superwow only)
```

Every character login begins with a marker line (`COMBATLOG_SESSION` or `CHAT_SESSION`) identifying the character and realm.
If a log file for the same character was written to within the last 60 minutes, the same logfile will be used instead of creating a new one.

Lua API for addon developers:

- `GetCombatLogPath()` -- returns the current combat log file path
- `GetChatLogPath()` -- returns the current chat log file path

No other configuration needed, install and forget.

**DLL:** `logsessions.dll`

---

### SuperWoW Heal Text Fix

Fixes duplicate floating heal numbers caused by SuperWoW 1.5. Only relevant if you use SuperWoW. No configuration needed, install and forget.

**DLL:** `healtextfix.dll`

---

### Big Cursor

Upscales the hardware cursor for improved visibility without losing sharpness. Supports fractional scales from 1.0 (off) to 4.0.

- `/script SetCursorScale(1.2)` -- set cursor scale (default 1.2x)
- `/script SetCursorScale(1)` -- disable (use original 32x32 cursor)

This value is saved to the `cursorScale` CVar in tenths: `/script SetCVar("cursorScale", "15")` for 1.5x.

Lua API for addon developers:

- `SetCursorScale(n)` -- set scale factor (1.0–4.0), takes effect on next cursor change
- `GetCursorScale()` -- returns current scale factor

**DLL:** `bigcursor.dll`

---

### MPQ File Cache

Caches the results of MPQ archive file lookups so repeat file opens skip the expensive archive chain walk and hash table probe. The game re-opens the same model and texture files hundreds of times per second during gameplay -- each lookup normally searches through every loaded MPQ archive. The cache remembers which archive contains each file and returns the answer directly.

Cache hits cost roughly 1/30th of a full search. During heavy gameplay (cities, raids, zone transitions), this saves 50-160ms every 15 seconds. In quiet scenes with few new models loading, there is little to save because the game does fewer lookups.

The cache validates that archives are still alive before returning cached results, so if the game closes or reloads an archive, the cache falls through to the original search.

No configuration needed. Enabled by default when using `weirdutils.dll`.

**DLL:** `filecache.dll`

---

### Timer Calibration

Improves the game's internal timer precision by recalibrating the TSC (Time Stamp Counter) frequency using the OS performance counter as a reference. The vanilla client's built-in calibration is inaccurate, which can cause animation stutter and timing jitter on some systems.

Also requests higher OS timer resolution (0.5ms instead of the default 15.6ms) and disables Windows 11 power throttling for the game process.

Ported from [VanillaFixes](https://github.com/hannesmann/vanillafixes). Primarily benefits native Windows. On Wine/Linux the game typically uses GetTickCount instead of TSC, so this module enables TSC mode with a proper calibration.

No configuration needed. Included in `weirdutils.dll`.

---

## Why No Source Code?

This project is distributed as pre-built DLLs only. The source code is not and will not be made publicly available.

These DLLs work by hooking deeply into the game client's internals: memory layout, function addresses, rendering pipeline, input handling, and more.  
While every feature here is built for legitimate quality-of-life use, the underlying techniques touch on too many core mechanisms that are trivially abusable.  
Publishing the source would be handing a candy store to bad actors: the same hooks and patterns used to render a raid marker or fix a crash can be repurposed for cheats, exploits, and in particular automation with minimal effort.

---

## Developer Notes
### Runtime Module Control API

WeirdUtils exports three functions for querying and disabling modules at runtime in case other devs find their dll's in conflict.

#### Exported Functions

| Function | Signature | Description |
|---|---|---|
| `WeirdUtils_IsModuleActive` | `int __cdecl (const char *name)` | Returns 1 if the module is compiled in and currently hooked, 0 otherwise |
| `WeirdUtils_DisableModule` | `int __cdecl (const char *name)` | Unhooks the named module. Returns 1 if found, 0 otherwise |
| `WeirdUtils_DisableAll` | `int __cdecl (void)` | Unhooks all modules and core hooks. Returns count of modules disabled |

Module names are case-insensitive and match the released dll names:

`customassets`, `framecrash`, `logsessions`, `transmogfix`, `minimapicons`, `healtextfix`, `bigcursor`, `worldmarkers`, `interact`, `outline`, `pngscreenshots`, `clickthrough`

There is no re-enable API.

#### C/C++ Header

A header-only `include/weirdutils_api.h` is provided that handles DLL discovery and runtime resolution automatically. No .lib file needed:

```c
#include "weirdutils_api.h"

// Returns 0 if WeirdUtils isn't loaded - safe to call unconditionally
if (WeirdUtils_IsModuleActive("transmogfix"))
    WeirdUtils_DisableModule("transmogfix");
```

The header tries all known DLL names (`weirdutils.dll`, `worldmarkers.dll`, etc.) via `GetModuleHandleA`, so it works regardless of which DLL variant is loaded.

#### Raw GetProcAddress

If you prefer not to use the header:

```c
HMODULE hMod = GetModuleHandleA("weirdutils.dll");
if (hMod) {
    typedef int (__cdecl *IsActiveFn)(const char *);
    IsActiveFn isActive = (IsActiveFn)GetProcAddress(hMod, "WeirdUtils_IsModuleActive");
    if (isActive && isActive("transmogfix")) {
        typedef int (__cdecl *DisableFn)(const char *);
        DisableFn disable = (DisableFn)GetProcAddress(hMod, "WeirdUtils_DisableModule");
        if (disable) disable("transmogfix");
    }
}
```

### Module Mutexes

Each module also holds a named mutex while active: `Local\WeirdUtils_<name>_<PID>` (e.g. `Local\WeirdUtils_framecrash_12345`). The exception is transmogfix, which uses `Local\TransmogCoalesceHook_<PID>` for legacy reasons.

If you see the mutex, the module is loaded - and can use the Runtime Module Control API to disable it. If you don't see it, the module isn't active and you're free to hook those functions yourself.
