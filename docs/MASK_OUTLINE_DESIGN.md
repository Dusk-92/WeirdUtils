# Outline Rendering Design — Requirements & Approach Analysis

## Date: 2026-02-24

## Requirements (Exact)

1. **Walls, terrain, game objects (doors, pillars)**: MUST occlude outlines
2. **Players and NPCs**: MUST NOT occlude outlines — outlines are specifically for making enemies easier to see in combat, so they must always show over other units
3. **Dead friendly players**: Outlines visible through EVERYTHING (including walls) — for finding corpses to resurrect

Any architectural approach is acceptable. The existing 3-pass stencil code is proof-of-concept, not a constraint. Efficiency and cleanliness matter more than preserving existing code.

## The Core Problem

The depth buffer doesn't distinguish "wall pixel" from "player pixel." After a frame is rendered, there's no way to know which depth values came from static geometry vs units. This makes pure post-process approaches (mask + edge detection in EndScene) unable to satisfy requirements 1 and 2 simultaneously:

- If you depth-test the mask render against the full depth buffer → walls occlude (✓) but players also occlude (✗)
- If you skip depth testing → players don't occlude (✓) but walls also don't occlude (✗)
- If you composite in EndScene after all rendering → outlines are on top of everything, including walls (✗)

**You need depth information from BEFORE players/NPCs have rendered, but AFTER terrain/WMOs have rendered.** This is only available at a specific point during the frame — when M2 model batches begin processing.

## Approach Analysis

### Approach A: 3-Pass Stencil with Batch Reordering (Current)

**How it satisfies the requirements:**

1. **Batch reordering** moves outline targets to render first in the M2 batch list. At that point, only terrain + WMO depth exists in the depth buffer. The outline pass (pass 2) uses `ZENABLE=TRUE` → terrain/WMOs occlude the outline. ✓
2. **Stencil bit** (`STENCIL_BIT_OUTLINE=0x02`) is written where outline pixels are drawn. Subsequent player/NPC batches test against this bit and fail where outline exists → players can't paint over outlines. ✓
3. **Dead players** use `ZENABLE=FALSE` in pass 2 → outline ignores all depth → visible through walls. ✓

**Downsides:**
- 3 DIP calls per outline target (stencil mark + outline + normal redraw)
- Heavy state save/restore (~15 render states + shader constants per outline)
- Custom bone-transform VS that duplicates the game's shader logic
- Requires D24S8 stencil buffer (force-reset if not present)
- Custom vertex declaration must match the game's exact M2 vertex format

**Key structural requirement:** Batch reordering is essential. Without it, other M2 models (including players) would have their depth in the buffer when the outline renders, causing them to occlude it. WMOs and terrain are rendered in separate systems before CM2SceneRenderDraw, so their depth is naturally present.

### Approach B: Mask + Post-Process Edge Detection

**Cannot satisfy all requirements.** The mask is rendered during DIP (with depth test), but:
- The depth buffer at DIP time contains both wall depth AND any previously-rendered player depth
- Without batch reordering, player depth may already be present → players occlude mask pixels
- With batch reordering, the mask captures the right silhouette, but compositing in EndScene draws OVER walls that rendered later

The composite happens at the wrong time — after everything has rendered, including walls that should occlude.

**Could work if combined with batch reordering** and a depth-aware composite, but this reintroduces the batch reordering requirement and adds render target + fullscreen quad overhead on top.

### Approach C: Depth Pre-Copy + Mask

Copy the depth buffer at the start of M2 rendering (after terrain/WMOs, before players), use that copy for the mask depth test, composite in EndScene.

**Problem:** D3D9 doesn't support copying depth buffers to textures natively. Would need `StretchRect` or `GetRenderTargetData` which may not work for depth surfaces, or a depth-resolve shader pass, which is complex and platform-dependent (Wine/DXVK compatibility unknown).

### Approach D: Two-Pass Stencil (Optimized Current)

Same core idea as Approach A but optimized:

1. **Pass 1 (stencil + outline):** Set stencil to mark body. Draw the expanded outline geometry with custom VS, using stencil to exclude body pixels. Write `STENCIL_BIT_OUTLINE` where outline draws.
2. **Pass 2 (normal):** Draw model normally (game's original state). This is the draw that would have happened anyway — just done after the outline.

Wait — this is still 3 DIP calls (stencil mark needs the normal geometry first). The passes can't easily be collapsed because the stencil mark (body silhouette) must exist before the outline can exclude it.

### Approach E: Inverted Hull with Game's Depth (Refined Stencil)

Same 3-pass stencil, but:
- **Use the game's own VS for pass 1 and 3** (no custom shader needed for stencil mark + normal draw)
- **Custom VS only for pass 2** (outline expansion) — this is the only pass that needs modified geometry
- **Minimize state changes** — only save/restore what we actually modify
- **Skip vertex declaration swap** if the game's declaration is compatible with our VS

This is what the current code already does, just cleaned up.

## Conclusion: Stencil + Batch Reordering is the Right Architecture

Given the requirements, the 3-pass stencil with batch reordering is the only approach that works without exotic depth buffer tricks. The key properties it provides:

1. **Outline renders when only static-world depth exists** (via batch reordering) → walls/terrain occlude ✓
2. **Stencil bit prevents later units from overwriting outline** → players don't occlude ✓
3. **Per-category depth disable** → dead player outlines through walls ✓

## Improvements to Implement

The current code is a working proof-of-concept. These improvements make it robust and correct:

### 1. Add ZWRITEENABLE=FALSE during outline pass (pass 2)

The expanded outline vertices are slightly outside the model. If they write depth, they could incorrectly occlude things behind the model. Disabling depth writes during the outline pass prevents this.

### 2. Add DEPTHBIAS save/restore

The C++ reference saves/restores `D3DRS_DEPTHBIAS`. The Zig port doesn't. If the game sets a depth bias for the current model, we need to preserve it.

### 3. Add stream source stride check

Before using the custom outline VS (which expects the GPU-skinned M2 vertex format: 48 bytes with bone weights/indices), verify the vertex stream stride matches. If the game is using CPU-skinned vertices (32 bytes, no bone data), skip the outline for that draw call to avoid reading garbage.

### 4. Verify vertex declaration compatibility

The custom VS declares: Position(FLOAT3)@0, BlendWeight(D3DCOLOR)@12, BlendIndices(D3DCOLOR)@16, Normal(FLOAT3)@20. This matches the GPU-skinned M2 format. For safety, we could check the current stream source stride in DIP before committing to the outline pass.

### 5. Handle device lost gracefully

The Reset hook releases shaders. Ensure `shaders_attempted` is reset so they're recreated on next use.

### 6. Consider vs_3_0 upgrade

The current VS uses vs_2_0. The game supports ps_3_0 (confirmed 0xFFFF0300), so vs_3_0 is available. Benefits: better precision for screen-space normal calculation, no instruction count limit. However vs_2_0 works and is simpler — this is optional.

## Implementation Order

1. Update `types.zig` — add any missing D3D9 constants
2. Update `d3d9_hook.zig` — add ZWRITEENABLE, DEPTHBIAS, stride check
3. Verify `model_hook.zig` — batch reordering and stencil flags are correct
4. Build and verify compilation
5. Test (login screen → in-game with live targets)
