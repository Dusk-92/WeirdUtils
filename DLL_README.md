# WeirdUtils

This package provides many pre-built DLLs for enhancing the vanilla WoW gameplay experience, aimed in particular at ease of use and accessibility but also bug fixes.

You may get all features by installing `weirdutils.dll`, or choose any selection of features via individual DLLs.

On Turtle WoW, place your chosen DLLs next to your `WoW.exe` and add them to your `dlls.txt`. For other versions you will need some sort of DLL loader.

---

## Features

### World Markers

Place up to 5 animated colored markers at any position in the world, useful for raid positioning, pull planning, or route marking. Requires party/raid leader or raid assist.

- `/worldmarker 1` through `/worldmarker 5` (or `/wm 1`) -- place a marker where your cursor is pointing
- `/worldmarker 1 target` -- place a marker on a unit (player, target, mouseover, etc.)
- `/clearworldmarker` (or `/cwm`) -- remove all markers
- `/clearworldmarker 2` -- remove a specific marker

Keybindings for placing each marker and clearing all markers are available in the Key Bindings menu.

Markers automatically sync with group members who also have WeirdUtils installed. When a leader/assist places or clears a marker, all group members see it. Markers persist across zone transitions and respawn when you return to the area.

Lua API for addon developers:

- `WorldMarker(index)` -- place marker at cursor terrain position (returns 1 on success, nil if no permission)
- `WorldMarker(index, "unit")` -- place marker at a unit's position
- `WorldMarker(index, x, y, z)` -- place marker at world coordinates
- `ClearWorldMarker(index)` / `ClearWorldMarker()` -- remove one or all markers (returns 1 on success, nil if no permission)
- `CanSetWorldMarkers()` -- returns 1 if the local player is party/raid leader or raid assist, nil otherwise

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

- `/screenshot 0` through `/screenshot 9` -- set compression level (0 = fast, 9 = smallest, default 6)

Compression level 6 provides the best balance of quality and file size. Enabled automatically on install.

**DLL:** `screenshot.dll`

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

Patch archives are sorted case-insensitively by filename — last in the sort gets highest priority, and all patches override the base archives.

No configuration needed, install and forget.

**DLL:** `customassets.dll`

---

### SuperWoW Heal Text Fix

Fixes duplicate floating heal numbers caused by SuperWoW 1.5. Only relevant if you use SuperWoW. No configuration needed, install and forget.

**DLL:** `healtextfix.dll`

---

## Why No Source Code?

This project is distributed as pre-built DLLs only. The source code is not and will not be made publicly available.

These DLLs work by hooking deeply into the game client's internals — memory layout, function addresses, rendering pipeline, input handling, and more. While every feature here is built for legitimate quality-of-life use, the underlying techniques touch on too many core mechanisms that are trivially abusable. Publishing the source would be handing a candy store to bad actors: the same hooks and patterns used to render a raid marker or fix a crash can be repurposed for cheats, exploits, and in particular automation with minimal effort.
