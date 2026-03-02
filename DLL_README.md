# WeirdUtils

This package provides many pre-built DLLs for enhancing the vanilla WoW gameplay experience, aimed in particular at ease of use and accessibility but also bug fixes.

You may get all features by installing `weirdutils.dll`, or choose any selection of features via individual DLLs.

On Turtle WoW, place your chosen DLLs next to your `WoW.exe` and add them to your `dlls.txt`. For other versions you will need some sort of DLL loader.

---

## Features

### World Markers

Place up to 5 animated colored markers at any position in the world, useful for raid positioning, pull planning, or route marking.

- `/worldmarker 1` through `/worldmarker 5` (or `/wm 1`) -- place a marker where your cursor is pointing
- `/worldmarker 1 target` -- place a marker on a unit (player, target, mouseover, etc.)
- `/clearworldmarker` (or `/cwm`) -- remove all markers
- `/clearworldmarker 2` -- remove a specific marker

Keybindings for placing each marker and clearing all markers are available in the Key Bindings menu.

Lua API for addon developers:

- `WorldMarker(index)` -- place marker at cursor terrain position
- `WorldMarker(index, "unit")` -- place marker at a unit's position
- `WorldMarker(index, x, y, z)` -- place marker at world coordinates
- `ClearWorldMarker(index)` / `ClearWorldMarker()` -- remove one or all markers

**DLL:** `markers.dll`

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

Eliminates FPS lag spikes caused by rapid equipment visual updates during transmog changes. No configuration needed, install and forget.

**DLL:** `transmogfix.dll`

---

### Custom Assets

Enables loading loose asset files (textures, models) from disk without repacking MPQ archives. Also supports multi-character patch archive names. No configuration needed, install and forget.

**DLL:** `assetfix.dll`

---

### SuperWoW Heal Text Fix

Fixes duplicate floating heal numbers caused by SuperWoW 1.5. Only relevant if you use SuperWoW. No configuration needed, install and forget.

**DLL:** `healtextfix.dll`
