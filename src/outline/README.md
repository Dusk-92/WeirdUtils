# Outline Subsystem

Screen-space outline rendering for WoW 1.12.1 (build 5875), injected as a 32-bit DLL
via Wine/DXVK on Linux. Outlines are rendered using a Jump Flood Algorithm (JFA) pipeline
that runs entirely in EndScene, composited on top of the final backbuffer.

## Architecture Overview

The outline system has three main phases per frame:

1. **Object scan** (EndScene start) - identify which game objects should be outlined
2. **DIP hook** (during game rendering) - cache draw calls and write stencil marks
3. **JFA pipeline** (EndScene, after game rendering) - produce and composite outlines

## Files

| File | Purpose |
|---|---|
| `api.zig` | Public API: `init()`, `cleanup()`, `setEnabled()`, Lua command handler |
| `d3d9_hook.zig` | D3D9 vtable hooks (EndScene, DIP, Reset), JFA pipeline, all shaders |
| `model_hook.zig` | WoW model render hooks, batch reordering, `rendering_outline` flag |
| `tracker.zig` | Per-frame object/model tracking, classification, color/width queries |
| `types.zig` | D3D9 constants, vtable indices, outline colors, model categories |
| `offsets.zig` | WoW memory addresses and struct offsets (object manager, functions) |
| `wow.zig` | Game memory access wrappers (object traversal, GUID resolution, unit helpers) |

## Render Order

The game's rendering pipeline processes geometry in this order. The outline system
controls M2 batch ordering via `model_hook.zig` and uses the resulting depth/stencil
state to determine outline visibility.

```
1. World geometry + WMOs          (game engine, writes depth)
2. Game object M2s (doodads)      (batch group 1, writes depth)
3. Local player M2s               (batch group 1, writes depth)
4. Outline target M2s             (batch group 2, DIP hook writes stencil)
5. Other players + gear + NPCs    (batch group 3, renders normally)
6. EndScene                       (JFA pipeline composites outlines)
```

### Batch reordering (model_hook.zig)

`CM2SceneRenderDraw` receives a flat array of M2 batch indices. The hook partitions
them into 3 groups before calling the original function:

- **Group 1 - depth-priority models**: game object M2s and the local player's M2s.
  These render first so their depth is in the buffer when stencil marks are written.
  The local player occludes outlines (they're the camera reference point).
  If the local player IS an outline target, their models go in group 2 instead
  (the outline check takes priority in the partition logic).

- **Group 2 - outline targets**: models belonging to tracked entities (current target,
  raid-marked units, dead friendly players). The DIP hook intercepts these draws to
  cache parameters and write stencil=1 where they pass the depth test.

- **Group 3 - everything else**: other players, their gear, NPCs, creatures.
  These render last. Their depth is NOT in the buffer when stencil marks are written,
  so outlines show through them. The outline composites on top in EndScene regardless.

### What occludes outlines

| Geometry | Occludes outlines? | Why |
|---|---|---|
| World terrain, WMOs | Yes | Rendered before any M2s, depth already in buffer |
| Game objects (M2 doodads) | Yes | Batch group 1, depth written before stencil |
| Local player | Yes | Batch group 1, unless self-outlined |
| Other players + gear | No | Batch group 3, render after stencil is written |
| NPCs / creatures | No | Batch group 3 |

## Stencil System

The DIP hook writes stencil marks during outline target rendering (group 2):

- `STENCILFUNC = ALWAYS`, `STENCILPASS = REPLACE`, `STENCILREF = 1`
- `STENCILZFAIL = KEEP` - pixels behind depth-tested geometry keep stencil=0
- After each outline DIP, `STENCILWRITEMASK` is set to 0 to protect marks from
  subsequent draws (group 3 models could otherwise overwrite them)
- Exception: dead players skip stencil entirely (`STENCILENABLE = 0`) so their
  outlines are visible through walls for corpse finding

EndScene Phase 1 uses `STENCILFUNC = EQUAL`, `STENCILREF = 1` to gate the
silhouette replay - only pixels marked as visible get silhouette color.

Stencil is cleared to 0 after Phase 1 to avoid affecting the next frame.

## JFA Pipeline (EndScene Phase 2)

After Phase 1 produces the silhouette RT (A8R8G8B8), the JFA pipeline generates
outlines via distance field:

1. **JFA Init** - seed the distance field from the silhouette. Pixels with
   silhouette content (alpha >= 0.002) output their own UV as a seed.
   Empty pixels output sentinel (-1, -1) which is outside UV space [0,1]
   so it never wins distance comparisons.

2. **JFA Propagation** - 4 passes at step sizes [8, 4, 2, 1], ping-ponging
   between two G16R16F render targets. Each pass does a 9-tap sample
   (self + 8 neighbors at step distance) and keeps the nearest seed UV.

3. **JFA Decode + Composite** - compute pixel-space distance from each pixel
   to its nearest seed. If distance < outline width AND the pixel is outside
   the silhouette interior, output the outline color with alpha blending.

### Outline widths

| Category | Pixels | Encoded alpha |
|---|---|---|
| Target | 2.25 | 0.5625 |
| Raid mark | 1.5 | 0.375 |
| Dead player | 2.5 | 0.625 |

Width is encoded as `alpha = pixels / 4.0` in the silhouette, decoded as
`width = alpha * 4.0` in the decode shader.

### Render targets

| RT | Format | Purpose |
|---|---|---|
| `rt_silhouette_tex` | A8R8G8B8 | Flat-color silhouettes with width-encoded alpha |
| `rt_jfa_a_tex` | G16R16F | JFA ping buffer (seed UV coordinates) |
| `rt_jfa_b_tex` | G16R16F | JFA pong buffer |

## DIP Hook - Draw Caching

The DIP hook does NOT draw silhouettes inline (that corrupts WoW's GxDevice
internal render state). Instead it:

1. Caches draw parameters (VB, IB, vertex decl, VS, VS constants, prim params)
2. AddRef's COM objects to keep them alive until EndScene
3. Writes stencil marks using the game's own depth buffer
4. Calls the original DIP exactly once (normal game rendering)

EndScene Phase 1 replays cached draws to the silhouette RT with:
- The flat-color pixel shader (outputs PS constant c0)
- The game's original vertex shader + VS constants (bone matrices, transforms)
- Stencil gating (stencil=1 required, except dead players)
- Depth testing disabled, depth writes disabled

## Object Tracking (tracker.zig)

Each frame, `scanObjects()` iterates the WoW object manager and collects:

- **Outline targets**: current target, raid-marked units/players, dead friendly players
- **Depth-priority objects**: game objects (type 5) and the local player

When `CM2Model_ManageRenderListNode` fires for each model being added to the
render list, `classifyModel()` reads the model's owner back-pointers
(`model+0x28` direct, `model+0x3C0` callback) and matches them against the
collected object pointers. No pointer dereferencing of unknown memory - just
value comparison against the validated set from the object manager.

## Outline Categories

| Category | Color | Trigger |
|---|---|---|
| `target` | Golden amber (#FFC800) | Current target |
| `raid_marked` | Per-mark color (8 colors) | Unit has raid mark 1-8 |
| `dead_player` | Cyan (#00FFFF) | Dead friendly player or non-skeleton corpse |

## Hook Installation

1. `api.init()` installs model hooks immediately (ManageRenderListNode,
   DrawBatchProjected, CM2SceneRenderDraw)
2. D3D9 hooks are **deferred** until the first model hook fires - creating a
   dummy D3D9 device during engine init corrupts the proxy's state
3. `api.initD3D9Deferred()` patches the D3D9 vtable (EndScene, DIP, Reset)
4. Reset hook forces D24S8 depth/stencil format (8 stencil bits required)

## Lua API

```lua
OutlineCommand()          -- returns current enabled state (bool)
OutlineCommand("on")      -- enable outlines
OutlineCommand("off")     -- disable outlines
```

## Known Issues

- **JFA banding artifacts**: "marching ants" pattern in the JFA output, dependent
  on screen-space position of the target. Confirmed the silhouette RT is clean
  (no stale VB issue). Root cause is in the JFA propagation/decode shaders.
  See `docs/jfa-banding-investigation.md` for full analysis.

- **Outline target gear not included**: equipment M2s (shoulders, weapons, helms)
  belonging to the outline target are not currently part of the silhouette.
  The outline follows the body mesh contour only. Tracking equipment models
  requires identifying them via owner back-pointers (planned).

- **Local player outline (planned)**: a Gaussian blur outline mode for the local
  player to improve visibility in combat when surrounded by mobs. Separate from
  the JFA pipeline - will use blur difference (blur silhouette, subtract original,
  threshold) for a softer glow effect and only apply to other players.

- **Death tracking needs improvement**: currently uses `UNIT_FLAG_DEAD` which is
  too simple. Needed changes:
  - Dead players should be outlined (works now)
  - Released bodies (corpse objects) should also be outlined (partially works via `.corpse`
    type, but needs verification that released-but-not-skeleton corpses are caught)
  - Feign Death must NOT trigger the dead outline - feign death sets the dead flag
    but the player is alive. Need to check for the feign death aura/buff or use a
    more specific death condition
  - The local player should never get a death outline on themselves - the purpose
    of the death outline is to help the player find and resurrect others, not to
    highlight their own corpse
  - Marker outlines should not persist on units after they die
  - Targeting a dead body should use a distinct outline color/style from the normal
    target outline, a player body should have the corpse outline. Only group/raid member
    bodies/corpses should outline!
  - Skeleton corpses should not outline.

- **Shapeshift form breaks local player occlusion**: changing form (e.g. ghost wolf,
  druid forms) causes the local player's model pointer to change. The new model
  isn't matched against the local player's object pointer, so it falls into batch
  group 3 instead of group 1 and no longer occludes outlines.

- **Mount + rider outline (planned)**: mounted players should outline the full
  mount+rider+gear as one unit. Requires understanding the M2 attachment hierarchy
  (mount is parent, rider is attached, gear is attached to rider?). All child models
  (rider body, gear) should be included in the silhouette.

- ** MISC **: target outlines on players should be diff color than on mobs. Also when a mob and you are in melee range your outline should merge with his probably, so show you who you'te attacking.
  Also we should shade targeted units not just outline them. And each outline and shade be a setting toggle

- **debug**: we should add to our debug mode coloring that colors each object type a different solid color, so that they issues arise it's easy to determine what object type is causing issues

## Future Architecture Notes

- **Hook "should render" function for model tracking**: the perfboost system uses a
  "should render" callback that receives a direct live object reference for every
  model considered for rendering each frame. Hooking this instead of (or alongside)
  `ManageRenderListNode` would give us a more reliable way to stay current on what
  objects and models are in the scene, with a direct object reference we can inspect
  for owner, form, mount status, etc. This could solve the shapeshift/mount model
  tracking issues since we'd always have the live object to check against.

## Build

```sh
cd /media/storage/projects/zig/weirdutils
zig build
```

Target: x86-windows-msvc (32-bit DLL), Zig 0.15.
