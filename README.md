# WeirdUtils

> **This project is no longer actively developed.** The full source is published here, in the public domain (see `LICENSE`), so it can be forked, salvaged, or learned from rather than bit-rotting on a private disk. See [Source Code](#source-code) for details and caveats.

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

Adds TBC/WotLK-style minimap tracking icons for NPC types, game objects, and quest givers.  
Replaces the native tracking dropdown with a combined menu showing both spell tracking and NPC category tracking.  
Can be disabled from the normal AddOn menu. Preferences saved per-character.  

- Click the minimap tracking icon to open the dropdown
- Check/uncheck NPC categories to toggle their minimap icons
- Spell tracking (Hunter tracking, Find Herbs, etc.) remains available alongside NPC tracking
- "Hide in Cities" toggle suppresses NPC icons in capital cities

Tracks various npc types and useful objects like Oranges and Brainwasher and Mailbox.  

**DLL:** `minimapicons.dll`

---

### Clickthrough

Smart cursor targeting that prioritizes useful interactions. Instead of always selecting the nearest object under the cursor, the module finds the most useful target along the ray in priority order.

- Lootable corpses first, then interactable game objects/portals, then interactable NPCs, then normal selection
- Dead non-lootable corpses can still be selected when nothing more useful is behind them
- Disabled inside battlegrounds to prevent targeting objectives through enemy players

Can replace SuperWoW's `Clickthrough()` toggle with always-on smart targeting that doesn't require a manual toggle and preserves the ability to select dead bodies when needed. Disable corpse-clickthrough in SuperAPI if you want this.

No configuration needed, install and forget.

**DLL:** `clickthrough.dll`

---

### Log Sessions

Organizes the combat, raw combat, and chat logs into per-character, per-day files:

```
Logs\<Realm>\<Character>\WoWChatLog_YYYY_MM_DD.txt
Logs\<Realm>\<Character>\WoWCombatLog_YYYY_MM_DD.txt
Logs\<Realm>\<Character>\WoWRawCombatLog_YYYY_MM_DD.txt (superwow only)
```

Every character login begins with a marker line (`COMBATLOG_SESSION` or `CHAT_SESSION`) identifying the character and realm.
If today's log file for that character already exists, it is appended to instead of creating a new one, so a day of play stays in one file even across multiple logins or `/reload`s.

Lua API for addon developers:

- `GetCombatLogPath()` -- returns the current combat log file path
- `GetChatLogPath()` -- returns the current chat log file path

No other configuration needed, install and forget.

**DLL:** `logsessions.dll`

---

### DPSLog (Combat Log Events)

Provides WotLK 3.3.5-style `COMBAT_LOG_EVENT_UNFILTERED` for the vanilla client. Fires a single unified event with structured arguments instead of vanilla's fragmented localized text events. Enables modern DPS meter addons without expensive string parsing.

37 subevents covering all combat interactions: damage (spell, melee, periodic, environmental, damage shield, damage split), healing (direct, periodic, overheal tracking), misses (all types), auras (applied, removed, refreshed, broken, dose changes), casts (start, success, failed, interrupted), power (energize, drain, leech), dispels, extra attacks, deaths, and kills.

Each event includes source/destination GUIDs, names, unit flags, raid flags, spell info, and all WotLK-standard suffix fields. Booleans (critical, glancing, crushing) use WotLK semantics: `nil` for false, `"1"` for true. Names are `nil` when the client can't resolve the unit (despawned, out-of-range). Null GUIDs use `0x80000000` flags.

When `/combatlog` is active, also writes structured WotLK-style CSV to `Logs\WeirdCombatLog.txt` (replaces vanilla's combat log file with parseable data).

Also provides:

- `CombatLogGetCurrentEventInfo()` -- WotLK-style lazy arg retrieval (call from event handler):

```lua
local f = CreateFrame("Frame")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:SetScript("OnEvent", function()
    local sub, srcGUID, srcName, srcFlags, srcRaidFlags,
          dstGUID, dstName, dstFlags, dstRaidFlags = CombatLogGetCurrentEventInfo()
    -- suffix args follow (spellId, spellName, etc.) -- see wiki for full layout
end)
```

- `GetSpellInfo(spellId)` -- the TBC/WotLK spell lookup API:

```lua
local name, rank, icon, castTime, minRange, maxRange, spellId = GetSpellInfo(133)
```

- `UnitCastingInfo("unit")` -- TBC/WotLK cast bar query (works on any visible unit):

```lua
local name, rank, text, icon, startTime, endTime, isTradeSkill, castID, notInterruptible = UnitCastingInfo("target")
if name then
    -- startTime/endTime are in milliseconds (compare with GetTime()*1000)
end
```

- `UnitChannelInfo("unit")` -- TBC/WotLK channel bar query:

```lua
local name, rank, text, icon, startTime, endTime, isTradeSkill, notInterruptible = UnitChannelInfo("target")
```

See the [DPSLog wiki page](https://codeberg.org/gwenael/WeirdUtils/wiki/DPSLog) for full event reference and addon developer guide.

**DLL:** `dpslog.dll`

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

- `SetCursorScale(n)` -- set scale factor (1.0-4.0), takes effect on next cursor change
- `GetCursorScale()` -- returns current scale factor

**DLL:** `bigcursor.dll`

---

### Performance

Engine-level optimizations that reduce CPU time on math, rendering helpers, file lookups, and data decompression.

- **SIMD Math** -- replaces 20+ internal math functions with SSE/AVX equivalents covering skeletal animation, particle rendering, frustum culling, collision detection, text glyph caching, and float-to-integer conversion
- **Data Decompression** -- swaps the game's 2004-era zlib with a modern library (2.2x faster). Loading screen times reduced by at least 13%
- **MPQ File Cache** -- caches archive file lookups so repeat file opens skip the archive chain walk. Saving 50-160ms every 15 seconds during heavy gameplay
- **Timer Calibration** -- recalibrates the client's RDTSC against the OS high-resolution counter for accurate animation timing, and raises the OS timer resolution to 0.5ms. Ported from [VanillaFixes](https://github.com/hannesmann/vanillafixes)
- **Lua Runtime** -- custom slab allocator (O(1) free/realloc), incremental/generational GC (turns the ~1s stop-the-world freeze into ~9ms chunks), faster string interning (~40% on `luaS_newlstr`), and a literal prefilter on `string.find`/`gfind`/`gsub` that kills the O(n²) backtracking addon combat log parsers inflict on every chat message

Most noticeable in cities, raids, during zone transitions, and in addon-heavy setups.

**DLL:** `weirdperformance.dll`

---

## Source Code

This project is no longer actively developed. The full source is now published here,
in the public domain (see `LICENSE`), so it can be forked, salvaged, or learned from
rather than bit-rotting on a private disk.

Earlier releases shipped as pre-built DLLs only. That is no longer the case - the
binaries on the releases page and the source in this repo are the same project.

Fair warning to anyone building on this: these DLLs hook deeply into the client's
internals - memory layout, function addresses, rendering pipeline, input handling.
Much of it is specific to 1.12.1 build 5875 and will not survive a different client
build. Some modules (`interact`, `clickthrough`) intercept input and hit-testing;
what you do with them on someone else's server is between you and that server's admins.

### Building

Requires Zig 0.16. The only dependency is
[zhook](https://codeberg.org/marcelinevq/zhook), the x86 inline hooking library,
pinned in `build.zig.zon` and fetched automatically:

```sh
git clone https://codeberg.org/MarcelineVQ/WeirdUtils
cd WeirdUtils
zig build                                        # zig-out/bin/weirdutils.dll
zig build all-variants -Doptimize=ReleaseSmall   # + one DLL per module
```

Target is `x86-windows-msvc` (32-bit DLL); it is developed on Linux with the game
running under Wine/DXVK. Per-module build flags are listed by `zig build --help`.

### Layout

| Path | What |
|---|---|
| `src/main.zig` | DLL entry, module init, Lua API registration |
| `src/<module>/` | One directory per feature module; embedded addons live in `addon/` subdirs |
| `src/offsets.zig`, `src/wow.zig` | Client addresses and memory access wrappers |
| `build.zig` | Module list, versions, per-module build flags, variant DLL generation |
| `docs/`, `src/*/RESEARCH.md` | Reverse-engineering notes for the subsystems being hooked |

`src/dpslog/WeirdDPSMate/` is a fork of DPSMate and stays under GPL-3.0 - see its
own `LICENSE`. Everything else is unlicensed/public domain.

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

`customassets`, `framecrash`, `logsessions`, `transmogfix`, `minimapicons`, `healtextfix`, `bigcursor`, `worldmarkers`, `interact`, `outline`, `pngscreenshots`, `clickthrough`, `dpslog`, `weirdperformance`

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

### Version Query API

WeirdUtils registers a Lua global table and query function for addon developers to detect which modules are loaded and their versions. Available from the login screen onward.

#### `GetWeirdUtilsVersion()`

Returns the `WeirdUtils` table containing all enabled modules and their version strings:

```lua
local modules = GetWeirdUtilsVersion()
for name, version in pairs(modules) do
    print(name .. " v" .. version)  -- e.g. "dpslog v1.0"
end
```

#### `GetWeirdUtilsVersion("modulename")`

Returns the version string for a specific module, or `nil` if not loaded:

```lua
if GetWeirdUtilsVersion("dpslog") then
    -- DPSLog is available, register for COMBAT_LOG_EVENT_UNFILTERED
end

local ver = GetWeirdUtilsVersion("minimapicons")  -- "1.0" or nil
```

The `WeirdUtils` table is additive -- if multiple independent DLLs are loaded (e.g. `dpslog.dll` and `minimapicons.dll` separately), each adds its own modules to the shared table.

---

### Module Mutexes

Each module also holds a named mutex while active: `Local\WeirdUtils_<name>_<PID>` (e.g. `Local\WeirdUtils_framecrash_12345`). The exception is transmogfix, which uses `Local\TransmogCoalesceHook_<PID>` for legacy reasons.

If you see the mutex, the module is loaded - and can use the Runtime Module Control API to disable it. If you don't see it, the module isn't active and you're free to hook those functions yourself.
