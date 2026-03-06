# WeirdUtils

All-in-one WoW 1.12.1 (build 5875) utility DLL. Injected as a 32-bit DLL into the
game process via Wine/DXVK on Linux. Provides screen-space outlines, screenshots,
interaction helpers, and an embedded addon with Lua API + keybindings.

## Current Features

| Module | Description |
|---|---|
| **Outline** | JFA-based screen-space outlines for targets, raid marks, dead players. See [src/outline/README.md](src/outline/README.md). |
| **Screenshot** | Hooks CTgaFile::Write for screenshot capture. |
| **Interact** | Nearest NPC/object interaction, bulk looting with queue processing. |
| **Markers** | World-space raid markers (5 colors) using M2 model entities. Proximity respawn, group sync, animated spawn/despawn. Lua API + slash commands (`/wm`, `/cwm`). |
| **Framecrash** | Anchor vtable guards - prevents crashes from dangling relativeTo pointers and NULL frame refs. |
| **Combatlog** | Combat log fixes. |
| **Minimap Icons** | Minimap icon fixes. |
| **Transmogfix** | Coalesces transmog durability update packets to prevent death frame drops. |
| **Data Assets** | Loose file loading, permissive MPQ glob patterns, pre-indexed file hash set. |
| **Healtextfix** | Heal text display fix. |
| **Embedded Addon** | Virtual addons loaded from DLL memory - .toc, .lua, .xml, .m2, .blp served via file I/O hooks (LoadFile + Storm layer). No on-disk addon folder needed. |
| **Lua Protection Bypass** | Stubs the Lua callback address validator to allow C function registration. |

## Consolidation Plan

WeirdUtils replaces the standalone utility DLLs in the parent directory. All
development happens here - shared code, shared hooking infrastructure, one build
system. The standalone DLLs are being retired.

| Standalone DLL | Purpose | Integration Status |
|---|---|---|
| `../assetfix` | Loose file loading, permissive MPQ glob patterns, pre-indexed file hash set | Not started |
| `../transmogfix` | Death frame drop fix - coalesces transmog durability update packets | Not started |
| `../interact` | Nearest interact + bulk loot | Partially integrated |

### Compile-Time Feature Gating

Each module is gated behind a build flag. The same codebase produces both the
all-in-one DLL and individual feature DLLs - just different compile flags.
Users can pick the full package or grab only the features they want.

```zig
// build.zig options (planned)
const enable_customassets = b.option(bool, "customassets", "Enable loose file loading & permissive patch glob") orelse true;
const enable_transmogfix = b.option(bool, "transmogfix", "Enable transmog coalesce fix") orelse true;
const enable_interact = b.option(bool, "interact", "Enable interact helpers") orelse true;
const enable_outline = b.option(bool, "outline", "Enable outline rendering") orelse true;
```

```sh
# Full build - all features in one DLL
zig build

# Single-feature builds - one DLL per feature for individual distribution
zig build -Dcustomassets=true -Dtransmogfix=false -Dinteract=false -Doutline=false
zig build -Dcustomassets=false -Dtransmogfix=true -Dinteract=false -Doutline=false
# etc.
```

Release artifacts:
- `weirdutils.dll` - everything
- `customassets.dll` - just asset/MPQ fixes
- `transmogfix.dll` - just transmog coalesce
- `interact.dll` - just interact/loot helpers
- `outline.dll` - just outline rendering

All built from this repo, all sharing the same hook library and codebase.

### Per-Feature Named Mutex

A user might load the full DLL alongside one of the smaller single-feature DLLs
(e.g. they use `weirdutils.dll` for everything but also have `customassets.dll` from
before they switched). Each feature module claims a **named mutex** on load - if
it's already held, that module skips hook installation. This way any combination
of DLLs coexists safely with no duplicate hooks.

```zig
// Each module creates a process-specific named mutex on init
const mutex = CreateMutexA(null, 1, "Local\\WeirdUtils_CustomAssetsHook_{pid}");
if (GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another DLL already owns this feature's hooks - skip
    CloseHandle(mutex);
    return;
}
// First to load wins - install hooks
```

This is per-feature, not per-DLL. The full DLL claims one mutex per enabled
feature. A single-feature DLL claims one mutex. Whichever loads first owns the
hooks; the duplicate gracefully becomes a no-op.

## Planned: Ground-Projected Markers

World-space markers projected onto terrain, similar to raid markers but driven
programmatically. Use cases:

- Visual range indicators (spell range circles, aggro radius)
- Waypoint markers for navigation
- Area-of-effect visualization
- Custom raid positioning markers

Implementation will require:
- Projecting screen-space or world-space coordinates onto the terrain mesh
- Rendering textured quads or circles that conform to terrain height
- Integration with the D3D9 hook pipeline (rendered during EndScene or as
  additional geometry injected into the scene)

## Distribution

This repo is private (source not published to avoid empowering bad actors).
Distribution uses a separate **public release repo** that contains only a
user-facing README and binary releases - no source code.

- **This repo** (private): all source, development, docs
- **Public repo** (e.g. `WeirdUtils`): README with feature descriptions +
  GitHub Releases with DLL downloads

Release workflow:
```sh
# Build all variants from this repo
zig build                                              # weirdutils.dll (full)
zig build -Doutline=true -Deverything-else=false       # outline.dll
# ... etc for each single-feature build

# Publish to the public repo
gh release create v1.0 --repo YourName/WeirdUtils \
  --title "v1.0" --notes "Release notes" \
  ./zig-out/lib/weirdutils.dll \
  ./builds/outline.dll \
  ./builds/customassets.dll
```

## Project Structure

```
weirdutils/
  build.zig              Build configuration
  src/
    main.zig             DLL entry, Lua API, file I/O hook, embedded addon
    screenshot.zig       Screenshot capture hook
    interact.zig         Interact + loot helpers
    png.zig              PNG encoding for screenshots
    outline/             Outline subsystem (see src/outline/README.md)
      api.zig            Public API, Lua command handler
      d3d9_hook.zig      D3D9 vtable hooks, JFA pipeline, shaders
      model_hook.zig     M2 batch reordering, rendering_outline flag
      tracker.zig        Per-frame object/model tracking
      types.zig          D3D9 constants, outline colors, categories
      offsets.zig        WoW memory addresses and struct offsets
      wow.zig            Game memory access wrappers
    addon/               Embedded addon files (.toc, .lua, .xml)
  libs/
    hook/                Shared x86 inline hooking library (trampoline, fastcall thunks)
  docs/                  Design docs, research notes, shader analysis
  reference/             C reference implementations
```

## Build

```sh
cd /media/storage/projects/zig/weirdutils
zig build
```

Target: x86-windows-msvc (32-bit DLL), Zig 0.16 (patched: fastcall inreg fix).
Host: Linux (Arch), game runs via Wine/DXVK.

## Hook Installation Order

Hooks are installed in a specific sequence to handle dependencies:

1. **DLL_PROCESS_ATTACH** - Lua protection bypass, file I/O hook, LoadScriptFunctions,
   LoadAddonsRecursively, interact hooks, GameEngine_MainInitialize, CGGameUI_Shutdown
2. **GameEngine_MainInitialize** (one-shot) - screenshot hook, outline model hooks
3. **First model hook callback** (deferred) - D3D9 vtable hooks (EndScene, DIP, Reset)

D3D9 hooks are deferred because creating a dummy device during engine init
corrupts the d3d9 proxy's state.
