# Unreleased Changes

Track notable changes here between releases. Clear this file when cutting a new release
(move contents into the release notes on Codeberg).

## What's New

- **World Markers** - place up to 5 animated Cataclysm-style markers at any position in
  the world. Slash commands (`/wm 1`, `/cwm`), keybindings, full Lua API, and automatic
  group sync between WeirdUtils users. Requires party/raid leader or raid assist.

- **DPSLog (COMBAT_LOG_EVENT)** - unified TBC/WotLK-style COMBAT_LOG_EVENT system with
  30 subevents across 23 hooks. Provides a single event (slot 549) with subevent strings
  (SWING_DAMAGE, SPELL_HEAL, SPELL_AURA_APPLIED, etc.) instead of vanilla's fragmented
  per-type events. Includes embedded addon for parsing. Not yet in DLL_README.

- **Interact** - smart interaction helpers: "Interact Nearest" right-clicks the closest
  interactable NPC or object within 5 yards, "Loot All Corpses" bulk loots nearby corpses.
  Keybindings and Lua API. Already documented in DLL_README but not yet released.

- **Crash Fix (framecrash)** - prevents crashes from stale UI frame anchor pointers.
  Already documented in DLL_README but not yet released.

- **Outlines** - renders glowing colored outlines around units. Already documented in
  DLL_README but not yet released.

- **Addon Profiling Stub (addonperf)** - TBC+ addon CPU profiling API stub
  (GetScriptCPUUsage). Internal/experimental, not in DLL_README.

## Enhancements

- **Clickthrough**: Lootable corpses now click-through over players. Previously only
  interactable NPCs (vendors, quest givers) and game objects would win over a blocking
  player. Now dead units with the lootable flag are also prioritized, so you can loot
  corpses through the player crowd without having to reposition.

- **World Markers**: Disabled in battlegrounds via Map.dbc mapType check. Markers cannot
  be placed while in a battleground instance.

- **Clickthrough**: Reduced log noise -- logging changed from file to console-only.
  Also ignores assets_backup directories in custom asset scanning.

## Bug Fixes

- **World Markers**: Fixed marker placement over game objects -- re-raycast now uses
  terrain-only flags to find the ground position beneath a GO, instead of placing the
  marker at the GO's collision point.

- **DPSLog**: Fixed dynamic event slot search and environmental damage parameter ordering.

- **Addon System**: Fixed addon files not loading -- switched from @hasField to @hasDecl
  for compile-time module introspection.

## Internal / Performance

- **Transform44 Profiling** - render pipeline profiling module with 39 hotspot hooks,
  A/B testing framework for comparing baseline vs optimized code paths, SSE replacements
  for ClipPolygonToSinglePlane (4x), BuildTrianglePlanes (10x), rotateMatrixByAxisAngle
  (4.3x), RayTriangleIntersection (1.3x), multiplyMatrix4x4 (4.3x).

- **VanillaFixes Math Polyfill** (WIP) - incorporating x87 FPU replacements from UnitXP
  and libSiliconPatch into our SSE pipeline. Replaces ~20 game math functions (matrix
  multiply, vector ops, collision geometry, animation interpolation) with SSE or modern
  scalar equivalents. Compiled ReleaseFast as a separate compilation unit (math_sse.zig).
  Not yet wired into hooks -- will be its own module with independent mutex.

- **Glyph Shadow Cache** - direct-mapped O(1) bypass for the game's 4-bucket hash table
  in GetOrCreateCharacterGlyph. Reduces glyph lookup from ~3.65% frame time.

- **MPQ File Cache (filecache)** - 2-way set-associative cache for File_FindInArchive
  (0x6549a0). Skips the MPQ chain walk and per-archive hash table probe on repeat file
  opens. Cache hits cost ~1000 cycles vs ~30000 cycles for full search. 60-90% hit rate
  during gameplay, saving 6-160ms per 15s reporting period depending on scene load.
  Validated via game's own FindAndIncrementResourceReference to handle archive lifecycle.

- **Timer Fix (VanillaFixes port)** - TSC calibration, OS timer resolution (0.5ms via
  NtSetTimerResolution), and Windows 11 power throttling disable. Ported from
  hannesmann/vanillafixes. Primarily benefits native Windows; no measurable impact on
  Wine/Linux but applied unconditionally.

- **MPQ File Cache** - hooks File_FindInArchive (0x6549a0) to cache archive lookup
  results. First open does full MPQ chain walk (~60K cycles), subsequent opens hit
  direct-mapped cache with filename verification (~300 cycles). 80% hit rate in testing.
  Moved from standalone file_perf module to transform44 sub-module (file_cache.zig).

- **Logging Module** - centralized logging with auto-prefix, file and/or console routing.
  All modules now route output through the shared Logger.

- **Addon System Refactor** - module list now derived from build.zig, inactive addon
  prefixes pruned at runtime. Fully data-driven.

- **Shared Offsets** - consolidated shared game offsets and accessor functions into
  offsets.zig and wow.zig, eliminating per-module duplication.

- **Build System** - default optimize changed from Debug to ReleaseFast (works around
  Zig fastcall inreg LLVM bug). Logging available in all modes except ReleaseSmall.

## DLL_README Gaps

Features documented in DLL_README but never included in a release:
- World Markers
- Outlines
- Interact
- Crash Fix (framecrash)

Features implemented but not yet documented in DLL_README:
- DPSLog (COMBAT_LOG_EVENT)
- Clickthrough lootable corpse priority
- World Markers battleground restriction
