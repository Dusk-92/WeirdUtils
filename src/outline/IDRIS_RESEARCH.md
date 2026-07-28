# Idris DLL Research -- Model Ownership & Structure

Findings from `a separate Idris DLL project` relevant to outline improvements.

## Model Pointer Sources (forward mapping: object -> model)

Units/players store their CM2Model pointers directly:
- `object + 0xD8` -- primary render model
- `object + 0xDC` -- secondary model (mounted/transformed state)

The Idris DLL reads these during object iteration and stores them in a
`g_modelToOwner` map. ManageRenderListNode then does a map lookup first,
falling back to model back-pointers only if needed.

**Relevance**: solves the "shapeshift form breaks local player occlusion"
issue -- when a player shapeshifts, their model pointer at +0xD8 changes.
Reading +0xD8 each frame from the object gives the current model, while
the back-pointer approach relies on matching against a stale pointer.
Also relevant for "mount + rider" tracking.

## Model Back-Pointers (reverse mapping: model -> owner)

| Offset   | Set by                          | Stores           | Notes |
|----------|---------------------------------|-------------------|-------|
| `+0x28`  | `InitializeModelWithParameters` | Owner object ptr  | All model types (units, GOs, doodads) |
| `+0x1F8` | `SetCallbackFunctions`          | Owner object ptr  | Units only (via CreateUnitModel) |
| `+0x3C0` | `SetRenderCallbacks`            | Owner object ptr  | Units only (via CreateUnitModel) |
| `+0x3BC` | `SetRenderCallbacks`            | Render callback fn| EntityRenderCallback_ProcessLighting |

Key: `model+0x3C0` is **only set for units** (by SetRenderCallbacks called
from CreateUnitModel). Game objects do NOT go through CreateUnitModel, so
their model+0x3C0 is uninitialized. Use model+0x28 for all-type matching.

Source: Idris `RESEARCH_LOG.md` lines 432-487, verified via Ghidra decompilation
of SetRenderCallbacks and SetCallbackFunctions.

## CM2Model Instance Structure (key offsets)

From `M2_MODEL_SYSTEM.md`:
```
+0x10:  Initialization flag (0=not loaded, 1=loaded)
+0x28:  Direct owner object pointer
+0x2c:  Parent scene/world context pointer
+0x30:  Pointer to CM2Shared data
+0x34:  Parent CM2Model (for attachments)
+0x44:  Render list prev pointer
+0x48:  Render list next pointer
+0x90:  Bone animation state array
+0x94:  Bone matrix array (4x4 matrices, 0x40 bytes each)
+0xa4:  Texture reference array
+0x30:  Resource/loaded model pointer (NOT M2 data directly)
        M2 data is at *(resource + 0x130), i.e. *(*(model+0x30) + 0x130)
        Confirmed via Ghidra: raycastPickObjects (0x7089C0) line 174:
          iVar15 = *(*(node+0x30) + 0x130)
+0x130: NOT the M2 data pointer (contains float data for GO models).
        For unit models this may coincidentally look like a pointer.
        The correct path is always via +0x30 indirection (see above).
+0x1cc: Next sibling model (hierarchy traversal)
+0x1dc: Child model list head
+0x1e8: Children initialized flag
+0x1F8: Owner object ptr (via SetCallbackFunctions)
+0x3BC: Render callback function (EntityRenderCallback_ProcessLighting)
+0x3C0: Owner object ptr (via SetRenderCallbacks, units only)
```

## CM2Model Hierarchy (attachment system)

- `+0x34`: parent CM2Model (for attached equipment, riders)
- `+0x1dc`: child model list head
- `+0x1cc`: next sibling model

**Relevance**: for "mount + rider + gear" outline tracking, traverse the
attachment hierarchy: mount model has rider as child, rider has gear as
children. All child models should be included in the silhouette.

## Batch Types in CM2SceneRenderDraw

| Type | Function                        | Used for |
|------|---------------------------------|----------|
| 0    | CM2Scene_DrawModelBatchProjected | Projected/UI models, corpses |
| 1    | CM2Scene_DrawModelBatch          | Standard model batches |
| 2    | CM2Scene_DrawDoodadBatch         | Instanced world doodads |
| 3    | CM2Scene_DrawRibbonEmitter       | Ribbon trails |
| 4    | CM2Scene_DrawParticleEmitter     | Particle systems |
| 5    | DrawCallback                     | Custom render callbacks |

The outline system hooks type 0 (DrawBatchProjected) where corpses render.

## Vertex Skinning Paths

WoW 1.12 supports two vertex skinning modes:
1. **GPU path**: vertex shader (`shaders/vertex/Model2.bls`), bone matrices
   uploaded to shader constants. Enabled by `M2UseShaders` CVar.
2. **CPU path**: `CM2Model_TransformVerticesSSE` (SSE2) or
   `CM2Model_ApplySkinning` (FPU fallback). Function pointer at 0x00cf04c8.

**Relevance**: the DIP hook captures draw calls regardless of skinning path,
but understanding which path is active helps debug vertex transform issues.
