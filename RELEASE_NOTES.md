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

- **VanillaFixes Math Polyfill** - 17 UnitXP x87 FPU replacement hooks verified via
  Ghidra prologue/epilogue disassembly and benchmarked against original WoW.exe bytes.
  Hooks install in lateInit() to clobber UnitXP's hooks with correct calling conventions
  (thiscall vs fastcall verified from assembly). A/B tested via bitmask toggle.

  Micro-benchmark results (x86 Linux harness, original x87 bytes mmap'd executable):
  ```
  Winners (SSE faster):          Neutral (~1.0x):            Losers (x87 faster):
  rotMat3x3:       2.1x (158->72)   matMulVec3:  1.0x         dotProduct:       0.4x (5->11)
  rotMat4x4:       2.1x (162->76)   multiply3x3: 1.0x         evaluatePolynomial: 0.6x (11->16)
  planeNormal:     1.7x (58->33)    crossProduct: 1.0x        squaredMagnitude:  0.7x (7->9)
  transformAABox:  1.2x (89->69)    applyTranslation: 0.9x    vec3MulScalar:     0.8x
  vecMulMat4:      1.1x             scaleByVec:  0.9x         vec3MulAssign:     0.8x
  scaleByScalar:   1.1x (some runs)                            quatMulMat4:       0.8x
  ```
  Losers are at function call overhead floor (original x87 is 5-11 cycles, close to
  bare CALL/RET cost). Future direction: patch original bytes in-place at load time
  to eliminate call overhead entirely.

  Also includes CriticalSection SpinCount=4000 optimization (from UnitXP) and
  blit_hub memcpy fast paths for matching pixel formats.

- **Math SSE Benchmark Harness** (`zig build bench` / `zig build run-bench`) - standalone
  x86 Linux micro-benchmark that extracts original x87 function bytes from WoW.exe via
  Ghidra, mmaps them executable, and profiles against our SSE replacements. Fresh data
  each iteration to avoid overflow/denormal artifacts. Correctness validation included.

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

## To Explore

- **Driver env vars on load** - set environment variables like `RADV_TEX_ANISO=16` from
  the DLL at load time, allowing driver-level anisotropic filtering while setting the
  in-game option to off/low. Avoids the double-filtering performance hit of game AF
  stacked on top of driver AF. Same approach could apply to other Mesa/RADV/DXVK knobs.

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
