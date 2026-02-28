# Outline Shading Research Log

## Goal
Implement outline shading for corpses visible through walls in the WoW 1.12.1 overlay DLL.

## Research Findings

### WoW 1.12.1 Native Highlighting System (from Ghidra)

#### Key Functions Found:
- `HandleUnitHighlight` @ 0x00492890 - Main unit highlight handler
- `SetTargetHighlight` @ 0x00614550 - Sets highlight on target, calls SetModelAmbientColor
- `EnableTargetHighlight` @ 0x004945e0 - Enables highlight, calls SetTargetHighlight
- `UnitHighlightWrapper` @ 0x00492e70 - Wrapper for HandleUnitHighlight
- `RenderUnitSelectionIndicator` @ 0x00611ff0 - Renders selection circle under units
- `SetupSelectionRenderStates` @ 0x00614e00 - Configures render states for selection

#### Selection Render States (SetupSelectionRenderStates):
```cpp
SetRenderState(7, 3);   // Blend mode
SetRenderState(0x14, 0); // D3DRS_ALPHATESTENABLE = false
SetRenderState(0x0e, 0); // D3DRS_ZWRITEENABLE = false
SetRenderState(0x12, 0); // D3DRS_ALPHAFUNC disabled
```

#### Model Rendering Pipeline:
- `CM2SceneRenderDraw` @ 0x0070b360 - Main M2 model scene rendering
- `DrawBatch` @ 0x0070cf70 - Draws model batches
- `DrawBatchDoodad` @ 0x0070d330 - Draws doodad batches
- `SetModelAlpha` @ 0x00710da0 - Sets model alpha (writes to offset 0x1c4)
- `SetModelAmbientColor` @ sets RGB at offsets 0x190, 0x194, 0x198

#### Render State Functions:
- `SetRenderState` @ wraps D3D_SetRenderState
- `D3D_SetRenderState` @ uses CGxDeviceD3d__device

#### Depth/Stencil Functions:
- `setDepthTest` @ 0x0071f9d0
- `depthFunc` @ 0x005a4af0
- `depthMask` @ 0x005a4ac0
- `CreateDepthStencilSurface` @ 0x005999c0
- `stencilFuncSeparate` @ 0x005a4810
- `stencilOpSeparate` @ 0x005a49b0

#### Nameplate Rendering (renderUnitNameplate @ 0x006c6e90):
Shows how to render world-space elements with proper transform:
1. SetTransformMatrix for identity
2. BeginRender()
3. SetRenderState calls for depth/alpha
4. CreateVertexBuffer, LockVertexBuffer
5. DrawPrimitive
6. EndRender()

### UnitXP_SP3 Source Analysis

#### Repository: https://codeberg.org/konaka/UnitXP_SP3

#### Key Files:
- `sceneBegin_sceneEnd.cpp` - Hooks WoW's scene rendering pipeline
- `Vanilla1121_functions.cpp` - Function addresses and hooks
- `worldText.cpp` - Combat text rendering

#### Scene Rendering Hook Pattern:
```cpp
void __fastcall detoured_sceneBegin(uint32_t CGxDevice, void* ignored, uint32_t unknown) {
  HRESULT test = dxDevice->TestCooperativeLevel();
  if (D3DERR_DEVICELOST == test || D3DERR_DEVICENOTRESET == test) {
    sceneEnd_fontsOnLostDevice();
  }
}
```

Scene end hook iterates text collections and calls update()/draw().

#### Key Function Addresses (from UnitXP):
- `getCamera` @ 0x4818F0
- `worldToScreen` @ 0x483ee0 (same as our WOW_FUNC_WORLD_TO_SCREEN)
- `getObject_byGUID` @ 0x464870 (same as our WOW_FUNC_GET_OBJECT_BY_GUID)
- Unit position via vftable offset 0x14 -> 0x5f1f10

### Outline Rendering Techniques

#### Option 1: Stencil Buffer Approach (Classic)
1. Render model to stencil buffer only (no color write)
2. Disable depth test
3. Render slightly scaled-up model with outline color where stencil != written
4. Re-enable depth test

#### Option 2: Two-Pass with Depth Disable
1. First pass: Render model normally
2. Second pass: Disable Z-test, render wireframe or scaled silhouette

#### Option 3: Post-Process Edge Detection
1. Hook EndScene
2. Use pixel shader to detect edges based on depth discontinuities
3. Overlay edges as outline

#### Option 4: Hook Model Rendering
1. Hook DrawBatch or CM2SceneRenderDraw
2. Identify corpse models being rendered
3. Add extra render pass with modified states

### D3D9 Render States Reference

For outline/through-wall effects:
```cpp
// Disable depth testing (see through walls)
pDevice->SetRenderState(D3DRS_ZENABLE, FALSE);
pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);

// Enable alpha blending
pDevice->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
pDevice->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
pDevice->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);

// For wireframe outline
pDevice->SetRenderState(D3DRS_FILLMODE, D3DFILL_WIREFRAME);
```

### Implementation Status [COMPLETED]

All objectives achieved - see "Working Implementation" at end of document:
- ✅ Hook DrawIndexedPrimitive to detect corpse/target/raid-marked models
- ✅ Stencil-based outline rendering in EndScene
- ✅ Custom vertex shader for bone-animated outline expansion
- ✅ Per-category visual effects (dark halo for dead, colored outline for marks/target)
- ✅ Through-wall visibility with proper body/outline layering

### D3D9 "Chams" / Wallhack Technique

The classic approach used in game mods for through-wall visibility:

#### How It Works:
1. Hook `DrawIndexedPrimitive` (D3D9 vtable index 82)
2. Identify target models by stride/vertex count/primitive count
3. Render model twice:
   - First pass: Normal render (visible when not occluded)
   - Second pass: Disable Z-buffer, render with colored material (visible through walls)

#### D3D9 VTable Indices:
- EndScene = 42 (currently hooked)
- DrawIndexedPrimitive = 82
- DrawPrimitive = 81
- SetRenderState = 57
- SetTexture = 65

#### Chams Implementation Pattern:
```cpp
HRESULT WINAPI hkDrawIndexedPrimitive(
    IDirect3DDevice9* pDevice,
    D3DPRIMITIVETYPE Type,
    INT BaseVertexIndex,
    UINT MinVertexIndex,
    UINT NumVertices,
    UINT StartIndex,
    UINT PrimitiveCount)
{
    // Check if this is our target model (by stride, vertex count, etc.)
    UINT stride;
    pDevice->GetStreamSource(0, &pVB, &offset, &stride);

    if (IsTargetModel(stride, NumVertices, PrimitiveCount)) {
        // First pass: render with Z-buffer disabled (through walls)
        pDevice->SetRenderState(D3DRS_ZENABLE, FALSE);
        pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);
        // Set color (e.g., red for behind walls)
        oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                              NumVertices, StartIndex, PrimitiveCount);

        // Second pass: normal render (visible normally)
        pDevice->SetRenderState(D3DRS_ZENABLE, TRUE);
        pDevice->SetRenderState(D3DRS_ZWRITEENABLE, TRUE);
        // Set different color (e.g., green for visible)
    }

    return oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                                  NumVertices, StartIndex, PrimitiveCount);
}
```

#### Challenge: Model Identification
The hard part is identifying which draw calls correspond to corpse models.
Options:
1. Log stride/vertex/primitive values and correlate with visual inspection
2. Hook WoW's internal functions to track which object is being rendered
3. Use world position correlation (complex)

### Current d3d9_hook.cpp Structure

Our existing hook infrastructure:
- Uses dummy device technique to get vtable
- Patches vtable entry for EndScene (index 42)
- Has PatchVTableEntry/RestoreVTableEntry helpers
- Calls RenderConsole() (which renders dead overlay) in EndScene hook

To add DrawIndexedPrimitive hook:
- Add DRAWINDEXEDPRIMITIVE_VTABLE_INDEX = 82
- Create hkDrawIndexedPrimitive function
- Patch vtable at index 82

### Practical Implementation Strategies

#### Strategy A: DrawIndexedPrimitive Hook with Model Logging
1. Hook DrawIndexedPrimitive
2. Add logging mode to record stride/vertices/primitives
3. Visually identify corpse-related values in game
4. Filter and apply chams effect to matching draw calls

**Pros**: Standard technique, well-documented
**Cons**: Requires empirical model identification, may affect many unrelated draws

#### Strategy B: Hook WoW's CM2SceneRenderDraw
1. Hook CM2SceneRenderDraw @ 0x0070b360 using MinHook/detours
2. In hook, check if rendering model belongs to dead player
3. Modify render states before calling original

**Pros**: Direct access to model context, knows what's being rendered
**Cons**: Requires understanding WoW's internal structures

#### Strategy C: Simple Circle/Glow Indicator (Current Enhancement)
1. Keep current skull/name rendering
2. Add a colored circle/glow rendered at corpse position
3. Render with Z-buffer disabled so visible through walls

**Pros**: Simple, works with current architecture
**Cons**: Not true model outline, just a marker

#### Strategy D: Hybrid - World-Space Outline Sprite
1. Create an outline/halo texture
2. Render it in world-space at corpse position (like selection circles)
3. Disable Z-buffer so it shows through walls
4. Use WoW's BeginRender/EndRender pattern

**Pros**: Looks like selection circle but visible through walls
**Cons**: Not model-conforming outline

### Recommended Approach

Start with **Strategy D** (world-space outline sprite) as it:
1. Works with our current EndScene hook
2. Doesn't require DrawIndexedPrimitive model identification
3. Can be enhanced later with model-specific rendering

Implementation steps:
1. Create a circular outline texture (or use D3DX to draw circle)
2. In RenderDeadOverlay, for each corpse:
   - Transform corpse world position to screen
   - Disable Z-buffer
   - Render circle at ground level
   - Re-enable Z-buffer
3. Render skull and name on top (already working)

## Strategy D Implementation (COMPLETED)

Added `DrawCircleAtScreen()` function in `dead_overlay.cpp`:

```cpp
static void DrawCircleAtScreen(IDirect3DDevice9* pDevice, float screenX, float screenY,
                                float radius, float thickness, D3DCOLOR color) {
    // Save render states
    // ...

    // DISABLE DEPTH TESTING - this makes it visible through walls!
    pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
    pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);

    // Enable alpha blending for semi-transparent effect
    pDevice->SetRenderState(D3DRS_ALPHABLENDENABLE, TRUE);
    pDevice->SetRenderState(D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    pDevice->SetRenderState(D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);

    // Draw thick ring using triangle strip (inner and outer circles)
    float innerRadius = radius - thickness / 2.0f;
    float outerRadius = radius + thickness / 2.0f;

    COLORED_VERTEX ring[(CIRCLE_SEGMENTS + 1) * 2];

    for (int i = 0; i <= CIRCLE_SEGMENTS; i++) {
        float angle = (float)i / (float)CIRCLE_SEGMENTS * 2.0f * PI;
        // Create inner and outer vertices for each segment
        // ...
    }

    pDevice->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, CIRCLE_SEGMENTS * 2, ring, sizeof(COLORED_VERTEX));

    // Restore states
    // ...
}
```

### Circle Parameters Used:
- Radius: 35.0f pixels
- Thickness: 6.0f pixels
- Color: `D3DCOLOR_ARGB(180, 64, 200, 255)` - semi-transparent cyan/blue

### Key Insight:
The circle is visible through walls because `D3DRS_ZENABLE` is set to `D3DZB_FALSE`, which disables depth testing. This means the circle is drawn regardless of what's in front of it in 3D space.

## Next Step: Strategy B (Model Outline)

To implement true model outlines, we need to hook WoW's internal `CM2SceneRenderDraw` function at `0x0070b360`.

### Model-to-GUID Mapping Discovery

From `CGUnit_LoadModelWithEquipment`:
```cpp
SetCallbackFunctions(this, DrawObjectModel,
                    (undefined *)**(undefined4 **)((int)param_1 + 8),  // GUID low
                    (undefined *)(*(undefined4 **)((int)param_1 + 8))[1]);  // GUID high
```

Model structure stores owner GUID:
- `model + 0x1f8` = GUID low (32-bit)
- `model + 0x1fc` = GUID high (32-bit)

During `CM2SceneRenderDraw`:
- `renderContext + 0x3310` = model data pointer
- From model data: `*(uint32_t*)(modelData + 0x1f8)` = GUID low
- From model data: `*(uint32_t*)(modelData + 0x1fc)` = GUID high

### Hook Implementation Plan

1. Create trampoline for `CM2SceneRenderDraw` at `0x0070b360`
2. In detour function:
   - Call original to render normally
   - For each batch, extract model GUID from `renderContext + 0x3310 -> +0x1f8/0x1fc`
   - Check if GUID belongs to dead friendly player (using our existing tracking)
   - If dead player: render again with Z-buffer disabled and colored shader

### Function Signature
```cpp
// __thiscall means 'this' is in ECX register
typedef void (__thiscall *CM2SceneRenderDraw_t)(
    void* thisPtr,           // ECX
    void* viewMatrix,        // arg1
    int batchData,           // arg2
    int batchIndices,        // arg3
    uint32_t batchCount      // arg4
);
```

### Sources
- [UnitXP_SP3 Codeberg](https://codeberg.org/konaka/UnitXP_SP3)
- [UnitXP_SP3 GitHub Fork](https://github.com/jrc13245/UnitXP_SP3)
- [wowdev.wiki Rendering](https://wowdev.wiki/Rendering)
- [wowdev.wiki M2](https://wowdev.wiki/M2)
- [wowdev.wiki M2/Rendering](https://wowdev.wiki/M2/Rendering)
- [D3D9 Chams Tutorial](https://niemand.com.ar/2019/01/13/creating-your-own-wallhack/)
- [Stack Overflow D3D9 Hooking](https://stackoverflow.com/questions/47652902/d3d9-hooking-endscene-drawindexedprimitive)

---

## Detailed Structure Analysis (Ghidra Decompilation)

### CM2SceneRenderDraw @ 0x0070b360 (FULL ANALYSIS)

```cpp
void __thiscall CM2SceneRenderDraw(void* this, undefined* viewMatrix,
                                    int batchData, int batchIndices, uint batchCount)
```

**Prologue** (9 bytes total - MUST copy all for inline hook):
```
0x0070b360: PUSH EBP           ; 1 byte  (55)
0x0070b361: MOV EBP, ESP       ; 2 bytes (8B EC)
0x0070b363: SUB ESP, 0x80      ; 6 bytes (81 EC 80 00 00 00)
```

**Batch Processing Loop:**
```cpp
for (uVar4 = 0; uVar4 < batchCount; uVar4++) {
    // Get batch pointer: batchData + (batchIndices[i] * 0x40)
    puVar2 = (uint32_t*)(*(int*)(batchIndices + uVar4 * 4) * 0x40 + batchData);

    // Store batch ptr at renderContext+0x3300
    *(uint32_t**)(this + 0x3300) = puVar2;

    // batch[0] = batch type, stored at renderContext+0x3308
    *(uint32_t*)(this + 0x3308) = puVar2[0];

    // batch[1] = CM2Model pointer
    iVar1 = puVar2[1];
    *(int*)(this + 0x3310) = iVar1;

    // Read CM2Model+0x30 -> stored at renderContext+0x3318
    *(uint32_t*)(this + 0x3318) = *(uint32_t*)(iVar1 + 0x30);

    // Read CM2Model+0x3b8 -> stored at renderContext+0x3320
    *(uint32_t*)(this + 0x3320) = *(uint32_t*)(iVar1 + 0x3b8);

    // Read (CM2Model+0x30)->0x130 -> stored at renderContext+0x48
    *(uint32_t*)(this + 0x48) = *(uint32_t*)(*(int*)(this + 0x3318) + 0x130);

    switch(batch[0]) {
        case 0: DrawBatchProj(this); break;      // Projected/2D
        case 1: DrawBatch(this); break;          // Standard 3D
        case 2: DrawBatchDoodad(...); break;     // Doodads
        case 3: DrawRibbon(this); break;         // Ribbons
        case 4: DrawParticle(this); break;       // Particles
        case 5: DrawCallback(this); break;       // Callbacks
    }
}
```

### Batch Structure (0x40 bytes per batch)

| Offset | Size | Description |
|--------|------|-------------|
| 0x00   | 4    | Batch type (0-5) |
| 0x04   | 4    | CM2Model pointer |
| 0x20   | 4    | Count (used in doodad batching) |
| 0x2c   | 4    | Some index |
| 0x30   | 4    | Another index |

### CreateUnitModel @ 0x00695100

```cpp
undefined* __fastcall CreateUnitModel(undefined** modelData, int unitObject, int forceInitialize)
{
    // Create model attachment
    this = createModelAttachment(PTR_00c7b298, modelData, 0);

    // IMPORTANT: Store model pointer at unit+0x88
    *(undefined***)(unitObject + 0x88) = this;

    if (this == NULL) return NULL;

    CopyArrayToObject(this, (undefined**)(unitObject + 0xcc));
    SetModelScale(*(void**)(unitObject + 0x88), ...);

    // Store unit pointer in model at multiple offsets
    SetCallbackFunctions(*(void**)(unitObject + 0x88), HandleSoundEvents,
                         (undefined*)unitObject, (undefined*)0x0);

    SetRenderCallbacks(*(void**)(unitObject + 0x88), EntityRenderCallback_ProcessLighting,
                       (undefined*)unitObject);

    PlayBoneAnimation(...);
    if (forceInitialize) InitializePlayerModel(...);

    return (undefined*)0x1;
}
```

### SetCallbackFunctions

```cpp
void __thiscall SetCallbackFunctions(void* this, undefined* callback1,
                                      undefined* callback2, undefined* callback3)
{
    *(undefined**)(this + 0x1F4) = callback1;  // HandleSoundEvents
    *(undefined**)(this + 0x1F8) = callback2;  // unitObject pointer!
    *(undefined**)(this + 0x1FC) = callback3;  // NULL
}
```

### SetRenderCallbacks

```cpp
void __thiscall SetRenderCallbacks(void* this, undefined* renderCallback1,
                                    undefined* renderCallback2)
{
    *(undefined**)(this + 0x3BC) = renderCallback1;  // EntityRenderCallback_ProcessLighting
    *(undefined**)(this + 0x3C0) = renderCallback2;  // unitObject pointer!
}
```

### Key Offset Summary

**Unit/Corpse Object:**
| Offset | Description |
|--------|-------------|
| 0x30   | GUID low 32 bits |
| 0x34   | GUID high 32 bits |
| 0x88   | Model pointer (CM2Model instance) |

**CM2Model Instance (from unit+0x88):**
| Offset | Description |
|--------|-------------|
| 0x1F4  | Sound callback function |
| 0x1F8  | Owner unit pointer (via SetCallbackFunctions) |
| 0x1FC  | NULL |
| 0x3BC  | Render callback function |
| 0x3C0  | Owner unit pointer (via SetRenderCallbacks) |

**IMPORTANT DISCOVERY:**
The model pointer stored at unit+0x88 has back-pointers to the unit at model+0x1F8 AND model+0x3C0.

---

## The Batch-to-Unit Mismatch Problem

### Debug Log Evidence

```
[DeadOverlay] Corpse obj=0x3AE98008, +0x88=0x3AE98090, +0x120=0x3AE98125
[ModelOutline] Added dead player model: 0x3AE98090 (count=1)
[ModelOutline] batch modelData=0x33C4A008, tracking model=0x3AE98090
```

**The Problem:**
- Corpse object: `0x3AE98008`
- Corpse's model (unit+0x88): `0x3AE98090`
- Batch's modelData (batch[1]): `0x33C4A008`

**batch[1] (0x33C4A008) ≠ corpse model (0x3AE98090)**

### Hypothesis

The batch[1] pointer is NOT the same structure as unit+0x88. They're different objects:

1. **unit+0x88** = CM2Model instance (created by createModelAttachment, ~0x428 bytes)
2. **batch[1]** = Something else, possibly:
   - M2 file data pointer
   - Render element wrapper
   - Intermediate structure that CONTAINS a reference to the CM2Model

### Chain to Explore

From CM2SceneRenderDraw:
```
batch[1] -> +0x30 -> stored at renderContext+0x3318
renderContext+0x3318 -> +0x130 -> stored at renderContext+0x48
```

Maybe: `batch[1]+0x30` points to the CM2Model instance (0x3AE98090)?

Or: Need to find where in batch[1] structure the link to unit+0x88 model exists.

### Next Investigation Steps

1. **Log batch[1] structure contents** - read batch[1]+0x00 through +0x40 to find 0x3AE98090
2. **Follow the chain** - check if batch[1]+0x30 -> ... -> leads to unit's model
3. **Alternative approach** - if batch[1] is the "real" M2 model, then batch[1]+0x3C0 might directly give us the unit pointer

### Alternative Matching Strategy

Instead of matching model pointers, try:
1. From batch[1], read batch[1]+0x3C0 (owner unit pointer, if it exists)
2. If valid, read (batch[1]+0x3C0)+0x30 to get GUID
3. Compare GUID with tracked dead player GUIDs

---

## New Research: CGUnit_ShouldRender Hook Strategy (from perf_boost)

### Source: https://gitea.com/avitasia/perf_boost

The perf_boost addon hooks `CGUnit_ShouldRender` to intercept unit rendering decisions.

### Key Offsets from perf_boost

```cpp
CGUnitShouldRender = 0x00607da0
CGUnitPreAnimate   = 0x00607ed0
CGUnitAnimate      = 0x00608560
OnWorldRender      = 0x00483460
```

### CGUnit_ShouldRender Analysis (0x00607da0)

**Function Signature:**
```cpp
// __thiscall: ECX = unit pointer
// Stack: stateFlags (uint32_t)
// Returns: non-zero if should render, 0 otherwise
// Callee cleans stack (RET 0x4)
undefined* __thiscall CGUnit_ShouldRender(void* this, uint stateFlags)
```

**Prologue (6 bytes):**
```asm
00607da0: PUSH EBX           ; 1 byte
00607da1: MOV EBX,ESP        ; 2 bytes
00607da3: SUB ESP,0x8        ; 3 bytes
```

**Key Logic:**
```cpp
// Check if model needs initialization
if (*(int*)(unit + 0xCCC) != 0) {
    // Initialize model at unit+0xD8
    if (CM2Model_Initialize(*(void**)(unit + 0xD8), 0, 0) == NULL) {
        return NULL;  // Don't render
    }
    *(uint*)(unit + 0xCCC) = 0;
}

// Add model to render list
void* model = *(void**)(unit + 0xDC);  // Try alternate model first
if (model == NULL) {
    model = *(void**)(unit + 0xD8);    // Fallback to primary model
}
CM2Model_ManageRenderListNode(model, 1);  // 1 = add to list
```

### Unit Model Pointer Relationships

**CRITICAL FINDING:** There are MULTIPLE model-related offsets on units:

| Offset | Description | Set By |
|--------|-------------|--------|
| 0x88   | Model pointer from CreateUnitModel | CreateUnitModel() |
| 0xD8   | Primary render model pointer | CGUnit_ShouldRender uses this |
| 0xDC   | Alternate model (mounted/transformed?) | Unknown |

**Model+0x3C0 stores owner unit pointer** (set by SetRenderCallbacks in CreateUnitModel)

### Corpses vs Dead Units - IMPORTANT DISTINCTION

**Player Death Behavior in WoW 1.12.1:**

1. **Dead Players** = CGUnit objects with health ≤ 0
   - Still rendered via CGUnit_ShouldRender
   - Model at unit+0xD8 is the corpse model (lying down)
   - GUID at unit+0x30/0x34 unchanged

2. **Corpse Objects** (type 0x40 or 0x80) = Different object type
   - Used for YOUR OWN corpse marker (for resurrection)
   - NOT enemy player corpses
   - Created at death location, separate from player unit

**For enemy player corpses:** We need to track CGUnit objects where:
- Health ≤ 0: `*(int*)(*(int*)(unit + 0x110) + 0x40) < 1`
- Or dead flag: `(*(uint*)(*(int*)(unit + 0x110) + 0x224) >> 5 & 1) != 0`

### Health/Death Check (from Lua_UnitIsDead @ 0x00517ac0)

```cpp
// Get unit descriptors
int* descriptors = *(int**)(unit + 0x110);

// Health at descriptors+0x40
int health = *(int*)(descriptors + 0x40);

// Dead flag at descriptors+0x224 bit 5
uint deadFlag = (*(uint*)(descriptors + 0x224) >> 5) & 1;

bool isDead = (health < 1) || (deadFlag != 0);
```

### CM2Model_ManageRenderListNode @ 0x00710b90

This function adds/removes models from the render list. **ALL renderable models pass through here.**

**Signature:**
```cpp
void __thiscall CM2Model_ManageRenderListNode(void* model, int addToList)
// addToList = 1: add to render list
// addToList = 0: remove from render list
```

**Called From:**
- CGUnit_ShouldRender (units)
- ProcessActiveGameObjects (game objects)
- ProcessInactiveGameObjects
- RenderModelsWithAnimation
- And many more...

### Proposed New Hook Strategy

**Option 1: Hook CGUnit_ShouldRender**
```cpp
// In hook:
// 1. ECX = unit pointer
// 2. Check if unit's GUID matches tracked dead player
// 3. If match, store unit+0xD8 (model) in tracking set
// 4. Call original
// 5. In CM2SceneRenderDraw, match batch[1] to stored models
```

**Option 2: Hook CM2Model_ManageRenderListNode**
```cpp
// In hook:
// 1. ECX = model pointer being added to render list
// 2. Check model+0x3C0 for owner object pointer
// 3. If owner is tracked dead player, store model pointer
// 4. Call original
// 5. In CM2SceneRenderDraw, match batch[1] to stored models
```

**Option 2 is more comprehensive** as it catches ALL models, including:
- Units (players, NPCs)
- Game objects
- Corpse objects (if they exist)
- Effects, particles, etc.

### GUID Location on Objects

From FindObjectByGUID @ 0x00464530:
- `object + 0x30` = GUID low (32-bit)
- `object + 0x34` = GUID high (32-bit)

### Object Type Identification

Object types are identified by:
1. GUID high bits contain type info
2. Or object structure differences

For our purposes, we track dead players by GUID from Lua, so type identification happens at the Lua level.

### Resolution

Model detection was solved by hooking `DrawBatchProj` (called before each model's draw batches) which provides the model pointer directly. Model-to-unit mapping is done by iterating game objects each frame and reading their model pointers at offset 0xD8.

---

## Current Investigation: Finding Abuzee's Corpse Model (2024-12)

### Test Subject
- **Player Name:** Abuzee
- **GUID:** `0x00000000003DAEE9` (consistent across attempts)
- **Goal:** Find where this GUID appears in model ownership so we can render an outline

### Key Discovery: CGCorpse Objects Are Minimal

From `GetObjectTypeSize @ 0x00465690`:
```cpp
switch(objectType) {
  case 1: case 3: case 5: case 6: case 7:  // Item, Unit(?), GO, DynObj, Corpse
    return 0x18;  // Only 24 bytes!
  case 2:  // Container
    return 0xC0;
  case 4:  // Player
    return 0x2F0;
}
```

**Corpse objects (type 7) are only 0x18 bytes** - just GUID and a few fields. They don't have model pointers at 0x88, 0xD8, etc.

### Debug Log Analysis

```
=== Debug Log Initialized ===
[DeadOverlay] Player obj=0x32DD0008, isDead=0
[DeadOverlay] Corpse obj=0x3B060008 (no model - corpses are 0x18 bytes)
[DeadOverlay] Corpse obj=0x3B060370 (no model - corpses are 0x18 bytes)
[Track] Added GUID 0x00000000003DAEE9 name='Abuzee' (count=1)
[DeadOverlay] Player obj=0x3D0E0008, isDead=0
... (more players, all isDead=0)
[Hook] model=0x20A5B808 +0x3C0->0x3A090848('Unknown') +0x28->0x32DD0008('0x0000000000186B75') found='0x0000000000186B75' tracking=1
```

### Analysis

1. **Abuzee's GUID** (`0x003DAEE9`) comes from corpse owner field (CORPSE_FIELD_OWNER at object+0x118)
2. **Two corpse objects** exist: `0x3B060008` and `0x3B060370` - both are minimal 0x18-byte objects
3. **All visible players** have `isDead=0` - none are dead CGUnit objects
4. **The hook** finds one model with owner GUID `0x00186B75` (different player)
5. **Abuzee's GUID never appears** in the hook output

### The Problem

When a player dies and **releases spirit**:
1. Their CGUnit is **despawned** (removed from object list)
2. A minimal CGCorpse object remains (just a marker for resurrection)
3. The corpse **visual** (dead body lying on ground) must come from somewhere else

**Abuzee has released spirit**, so:
- No CGUnit exists with GUID `0x003DAEE9`
- Only the minimal corpse marker exists
- But we can still see Abuzee's dead body in the game world

### Hypotheses for Corpse Visual Rendering

**Hypothesis A: Server-side model rendering**
The dead body might be rendered purely based on server data (model ID in corpse fields) without needing a client-side CGUnit.

**Hypothesis B: Corpse has hidden model data**
The corpse object might store model info at different offsets than we're checking (not 0x88/0xD8).

**Hypothesis C: Shared model system**
Dead body visuals might use a different rendering path that doesn't go through CM2Model_ManageRenderListNode.

**Hypothesis D: Object data fields**
CORPSE_FIELD_DISPLAY_ID or similar might directly specify what to render.

### UpdateFields for Corpses (from UpdateFields.h)

```cpp
CORPSE_FIELD_OWNER     = OBJECT_END + 0x00  // GUID of owner
CORPSE_FIELD_FACING    = OBJECT_END + 0x02  // float
CORPSE_FIELD_POS_X     = OBJECT_END + 0x03
CORPSE_FIELD_POS_Y     = OBJECT_END + 0x04
CORPSE_FIELD_POS_Z     = OBJECT_END + 0x05
CORPSE_FIELD_DISPLAY_ID= OBJECT_END + 0x06  // Model to display?
CORPSE_FIELD_ITEM      = OBJECT_END + 0x07  // 19 slots
CORPSE_FIELD_BYTES_1   = OBJECT_END + 0x1A
CORPSE_FIELD_BYTES_2   = OBJECT_END + 0x1B
CORPSE_FIELD_GUILD     = OBJECT_END + 0x1C
CORPSE_FIELD_FLAGS     = OBJECT_END + 0x1D
CORPSE_FIELD_DYNAMIC_FLAGS = OBJECT_END + 0x1E
```

### Key Ghidra Discovery: Corpses DO Have Models!

From `InitializeObjectByType @ 0x00466010`:
```cpp
case 7:  // Corpse type
    ComplexObjectConstructor(param_2, ...);
    SetupUnitDisplayHandler(param_2);  // <-- Creates model at +0xD8!
```

**Corpse objects call `SetupUnitDisplayHandler`** which:
1. Creates a model via `createModelAttachment()`
2. Stores it at `corpse+0xD8` via `SetDisplayHandler()`
3. Calls `InitializeModelWithParameters(model, callback, corpse)` which sets `model+0x28 = corpse`

**This means corpses SHOULD have models at +0xD8 just like units!**

### Updated Code (dead_overlay.cpp)

Changed corpse handling to:
```cpp
// Get model pointer from corpse+0xD8 (same as units)
void* corpseModelD8 = *(void**)((uint8_t*)obj + 0xD8);
void* corpseModelDC = *(void**)((uint8_t*)obj + 0xDC);

DebugLogF("[DeadOverlay] Corpse obj=0x%08X +0xD8=0x%08X +0xDC=0x%08X\n", ...);

// Track corpse model directly if available
if (corpseModelD8 != nullptr) {
    ModelOutline_AddDeadPlayerModel(corpseModelD8);
}
```

### Next Test

If corpse+0xD8 shows a valid model pointer:
- The model should appear in the CM2Model_ManageRenderListNode hook
- We can match by model pointer directly
- `model+0x28` should point back to the corpse object

If corpse+0xD8 is NULL:
- Corpse visual might be rendered differently (e.g., server-side model ID in UpdateFields)
- Need to investigate CORPSE_FIELD_DISPLAY_ID usage

### SUCCESS! Model Detection Working (2024-12)

**Test Results:**
```
[DeadOverlay] Corpse obj=0x3AFA8370 +0xD8=0x3AFBF008 +0xDC=0x00000000
[DeadOverlay] Adding corpse model 0x3AFBF008 for owner Abuzee (GUID=0x00000000003DAEE9)
[Hook] DIRECT MODEL MATCH! model=0x3AFBF008
```

**What's Working:**
1. Corpse objects DO have model pointers at `+0xD8` (not NULL)
2. Direct model pointer tracking works - we store `corpse+0xD8` and match in hook
3. CM2Model_ManageRenderListNode hook detects when Abuzee's corpse model is being rendered

**Next Step: Implement Outline Rendering**
Now that we can identify the corpse model during rendering, we need to:
1. Modify render states when matched model is detected
2. Re-render with depth test disabled and colored shader
3. Create the visible-through-walls outline effect

---

## Batch Type Discovery (RenderBatches @ 0x0070b630)

### Critical Finding: Different Draw Functions per Batch Type

`RenderBatches` uses a switch statement to call different rendering functions based on batch type:

```cpp
switch(*(uint32_t*)batch) {  // batch[0] = type
    case 0: DrawBatchProj(renderContext);     // Projected/2D elements
    case 1: DrawBatch(renderContext);          // Standard 3D models
    case 2: DrawBatchDoodad(...);              // Doodads/world objects
    case 3: DrawRibbon(renderContext);         // Ribbon effects (trails)
    case 4: DrawParticle(renderContext);       // Particle systems
    case 5: DrawCallback(renderContext);       // Custom callback rendering
}
```

**We only hooked `DrawBatch` (case 1) - corpse models might use a different batch type!**

### Draw Function Addresses

| Function | Address | Batch Type |
|----------|---------|------------|
| DrawBatchProj | 0x0070cb30 | 0 |
| DrawBatch | 0x0070cf70 | 1 |
| DrawBatchDoodad | 0x0070d330 | 2 |
| DrawRibbon | 0x0070d820 | 3 |
| DrawParticle | 0x0070d8b0 | 4 |
| DrawCallback | 0x0070d960 | 5 |

### Investigation Needed

1. **Determine corpse batch type** - Add logging to RenderBatches to see what batch type corpse models use
2. **Hook the correct function** - May need to hook a different draw function
3. **Consider hooking RenderBatches** - Hook at a higher level to intercept all batch types

### DXVK Considerations

Using DXVK (D3D9→Vulkan translation layer):
- DXVK intercepts at the **D3D9 API level** (IDirect3DDevice9 calls)
- WoW's internal functions (DrawBatch, RenderBatches) execute **before** D3D9 calls
- Internal function hooks should work normally - they're within WoW.exe address space
- DXVK only sees the D3D9 calls that result from these functions

**Conclusion:** DXVK shouldn't affect our internal WoW hooks. The issue is likely that corpse models use a batch type other than 1, so they go through a different draw function.

---

## Render State Effects Discovered (2024-12)

### See-Through-Models Effect (NOT through walls)

The following render states make a model visible through **other models** (players, NPCs, objects) but NOT through world geometry (walls, terrain):

```cpp
// In DrawIndexedPrimitive hook, when rendering target model:
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);      // Disable Z-test
pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);       // Don't write to Z-buffer
pDevice->SetRenderState(D3DRS_TEXTUREFACTOR, D3DCOLOR_ARGB(255, 0, 255, 255));  // Cyan
pDevice->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
pDevice->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TFACTOR);

// IMPORTANT: Must save/restore states to avoid affecting other models
```

**Key Insight:** Disabling Z-test at DrawIndexedPrimitive level makes the model render on top of other models rendered in the same pass, but world geometry (walls/terrain) renders in a **different pass** with its own depth buffer management, so models behind walls are still occluded.

**Use Case:** This is useful for making specific models visible through crowds of NPCs/players without showing them through walls. Could be used for:
- Target highlighting in crowds
- Party member visibility
- Pet/companion tracking

### True Through-Wall Visibility [SOLVED]

Solution: Render in EndScene with `D3DRS_ZENABLE = FALSE`. At EndScene, depth buffer is cleared, so disabling depth test allows through-wall visibility. Stencil buffer (on our custom D24S8 surface) handles body/outline separation.

---

## Outline Rendering Approaches [SOLVED]

### Goal
Add a colored outline around corpse models that is visible through walls.

> **Solution implemented:** Custom vertex shader expands along normals after bone transform.
> Stencil buffer marks body, outline renders where stencil ≠ body.

### Approach 1: Scaled Model Silhouette

Classic outline technique:
1. **Pass 1**: Render model normally
2. **Pass 2**: Scale model slightly larger (1.05x), cull front faces, render solid color
3. The scaled back-faces create an outline effect around the normal model

```cpp
// Pass 2: Outline
pDevice->SetRenderState(D3DRS_CULLMODE, D3DCULL_CW);     // Cull front faces (show back)
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);     // Through walls
// Scale transform... (complex - need access to world matrix)
```

**Problem:** Need access to the world/transform matrix to scale the model.

### Approach 2: Wireframe Overlay

```cpp
// Pass 2: Wireframe outline
pDevice->SetRenderState(D3DRS_FILLMODE, D3DFILL_WIREFRAME);
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
pDevice->SetRenderState(D3DRS_TEXTUREFACTOR, g_outlineColor);
pDevice->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
pDevice->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TFACTOR);
```

**Pros:** Simple, no matrix manipulation needed
**Cons:** Shows internal wireframe, not just outline edge

### Approach 3: Edge Detection Post-Process

1. Hook EndScene
2. Read depth buffer and detect edges where depth changes sharply
3. Draw outline at detected edges

**Pros:** True edge outline
**Cons:** Complex, requires shaders, may have performance impact

### Approach 4: Stencil Buffer Outline

1. Render model to stencil buffer (increment)
2. Render slightly enlarged model where stencil == 0 (edges only)

```cpp
// Step 1: Write to stencil
pDevice->SetRenderState(D3DRS_STENCILENABLE, TRUE);
pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
pDevice->SetRenderState(D3DRS_STENCILREF, 1);
pDevice->SetRenderState(D3DRS_STENCILPASS, D3DSTENCILOP_REPLACE);
// Render model normally...

// Step 2: Draw outline where stencil != 1
pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_NOTEQUAL);
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
// Render enlarged model with outline color...
```

**Problem:** Still need transform matrix to enlarge model.

### Current Recommendation

Start with **Approach 2 (Wireframe)** as it's simplest to implement:
- No transform matrix manipulation needed
- Already have the hook infrastructure
- Can be enhanced later with better techniques

---

## Through-Wall Rendering Experiments (2024-12)

### Findings

**What Works:**
- Disabling texture + setting emissive material → Model renders flat black (color control works)
- Face culling changes → Visible effect (can see body parts through other parts)
- Clearing depth buffer → Affects ground rendering (depth buffer IS accessible)

**What Doesn't Work:**
- `D3DRS_ZENABLE = FALSE` → Model still hidden by walls
- `D3DRS_ZFUNC = D3DCMP_ALWAYS` → Model still hidden by walls
- `D3DRS_ZWRITEENABLE = FALSE` → Model still hidden by walls
- Clearing depth buffer before draw → Ground affected, but model unchanged
- World matrix scaling → No effect (WoW uses bone matrices, ignores D3DTS_WORLD)
- TEXTUREFACTOR color → No effect (WoW uses shaders, ignores fixed-function pipeline)

### Key Insight: Render Order

WoW's rendering order appears to be:
1. **Models** (characters, corpses, objects) - rendered first
2. **World geometry** (terrain, walls) - rendered AFTER models

This means walls render on top of models regardless of our depth settings. Our depth modifications only affect how this model interacts with things rendered BEFORE it.

### Why M2 Model Depth Settings Don't Work

WoW's M2 model rendering appears to:
1. Use its own bone/transform matrices (ignoring D3DTS_WORLD)
2. Use pixel shaders (ignoring fixed-function TEXTUREFACTOR)
3. Have its depth handling managed at a higher level than individual DIP calls

The depth buffer clear test proved this: clearing the Z-buffer affected the ground (which uses standard depth) but NOT the M2 model (which has its own depth handling).

### Solutions for True Through-Wall Visibility

**Option A: EndScene Redraw (Complex)**
1. In DIP hook: Cache vertex buffer, index buffer, transforms when corpse is detected
2. In EndScene: After all world rendering is complete, replay the cached draw calls with Z-disabled
3. Challenge: Need to capture and replay all necessary state

**Option B: Hook World Geometry Rendering**
1. Find where WoW renders walls/terrain
2. Insert our corpse redraw AFTER wall rendering
3. Challenge: Need to identify the right hook point

**Option C: Enhanced 2D Overlay (Simple, Working)**
1. Keep current skull/name markers in EndScene
2. Add screen-space indicators (arrows, distance, direction)
3. Works reliably since 2D overlay renders after everything

**Option D: Hybrid - World-Space Outline Sprite**
1. Create an outline/halo texture
2. Render it in world-space at corpse position (like selection circles)
3. Disable Z-buffer so it shows through walls
4. Use WoW's BeginRender/EndRender pattern

### Current Recommendation

For reliable through-wall corpse indication, use **Option C (2D Overlay)** as it:
- Already works (skull markers render on top of everything)
- Can be enhanced with arrows, distance text, directional indicators
- Doesn't require complex model caching/replay

For true 3D model silhouette through walls, **Option A (EndScene Redraw)** would be needed but is significantly more complex.

---

## EndScene Replay Experiments (2024-12)

### Attempt 1: Cache renderContext pointers

**Approach:**
- In DrawBatchProj hook, cache `renderContext` pointers when corpse detected
- In EndScene, call `DrawBatchProj` again with cached pointers

**Result:** Model pointers were NULL/invalid by EndScene time

**Problem:** `renderContext` is stack memory (always same address `0x00E2C7E0`), gets reused between DrawBatchProj calls and is invalid by EndScene.

### Attempt 2: Copy entire renderContext structure

**Approach:**
- Copy 0x3320 bytes of renderContext to static buffers
- In EndScene, pass copied buffer to DrawBatchProj

**Result:** CRASH at instruction `0x0070BB2F` - memory reference to `0x3F72E8DF`

**Problem:** The renderContext contains **internal pointers** to other stack-local structures (matrices, buffers, etc.). Copying the raw bytes preserves the pointers but they now point to invalid/reused stack memory. When DrawBatchProj dereferences them → crash.

The address `0x3F72E8DF` looks like a float value (≈0.949) being interpreted as a pointer, confirming the copied structure has garbage where pointers should be.

### Conclusion on EndScene Replay

**EndScene replay of WoW's render functions is NOT viable because:**
1. Render contexts contain nested pointers to stack-local data
2. Those structures are not relocatable via simple memory copy
3. By EndScene time, original stack memory is reused

**Alternative approaches needed:**
1. Find a simpler render function that takes just model pointer + transforms
2. Use stencil buffer marking during normal render, draw overlay in EndScene
3. Hook at a different point in the render pipeline (after walls but before present)
4. Implement true outline shader technique at the D3D level

---

## WoW 1.12.1 Rendering Pipeline Understanding

### Render Order (from CGWorldFrame_OnWorldRender)

```
1. BeginRender()
2. RenderWorldMainLoop()        - Main world terrain/geometry
3. RenderParticleSystemBatched()
4. executeSceneRenderPass(0)    - Scene pass 0
5. RenderTargetingReticle()
6. RenderObjectList()           - Objects (units, corpses, etc.)
7. executeSceneRenderPass(1/2)  - More scene passes
8. CallWorldFunction_Wrapper()
9. renderBlizzard()             - Blizzard logo?
10. EndRender()
```

### Key Functions for M2 Model Rendering

| Function | Address | Purpose |
|----------|---------|---------|
| CM2SceneRenderDraw | 0x0070b360 | Main M2 scene render, iterates batches |
| DrawBatchProj | 0x0070cb30 | Batch type 0 (projected/2D) - **CORPSES USE THIS** |
| DrawBatch | 0x0070cf70 | Batch type 1 (standard 3D) |
| DrawBatchDoodad | 0x0070d330 | Batch type 2 (doodads) |
| FinishRendering | 0x0070cb10 | Cleanup after rendering |
| CM2Model_ManageRenderListNode | 0x00710b90 | Add/remove models from render list |

### M2 Model Internal Structures

WoW's M2 models use:
- **Bone matrices** for skeletal animation (not D3DTS_WORLD)
- **Pixel shaders** for rendering (not fixed-function TEXTUREFACTOR)
- **Custom depth handling** managed above DIP level

This is why D3D9 state changes at DrawIndexedPrimitive level don't affect M2 model depth:
- The D3D9 vtable hook works (we can see terrain effects)
- But M2 models use a different code path with their own state management

---

## M2 Outline Research Findings (Agent)

### 1. Repository Analysis

#### UnitXP_SP3 (https://codeberg.org/konaka/UnitXP_SP3)
**Purpose:** World of Warcraft Vanilla 1.12 client modification toolkit focused on UI enhancements and rendering optimization.

**Key Technical Components:**
- **Scene Rendering Hooks:** `sceneBegin_sceneEnd.cpp/h` implements scene lifecycle hooks for device lost logic and FPS management
- **Visual Effects:** `worldText.cpp/h` handles floating combat text rendering with custom serif fonts
- **Distance Calculations:** `distanceBetween.cpp` and `modernNameplateDistance.cpp/h` for unit/nameplate distance-based rendering
- **No Direct Outline Implementation:** This repository focuses on UI overlays and text rendering, not 3D model outlining or silhouetting

**Language Composition:** C++ (78.5%), C (21.5%)

**Relevance:** Useful for understanding WoW 1.12.1 scene hook patterns but does not implement model outline techniques.

#### perf_boost (https://gitea.com/avitasia/perf_boost)
**Purpose:** Performance DLL using selective unit rendering with distance controls.

**Key Features:**
- **Selective Unit Rendering:** Distance-based culling for different unit types
- **Fast distance approximation** with frame-based caching
- **Context-aware settings** (combat vs non-combat, city vs outdoor)
- **Smart exceptions** for raid-marked units

**Language Composition:** C++ (96.4%), CMake (3.6%)

**Architecture Notes:**
- Uses boost and hadesmem libraries
- Implements render hooks but source code details not accessible via web fetch

**Relevance:** Repository README confirms it hooks rendering but implementation details require direct source inspection. Likely uses model culling rather than outline/silhouette techniques.

#### VanillaHelpers (https://github.com/isfir/VanillaHelpers)
**Purpose:** Helper library for Vanilla WoW 1.12 with display manipulation features.

**Key Features:**
- **Minimap Blips:** Customize unit markers on the minimap
- **High-Resolution Textures:** Support for 1024x1024 textures (vs standard 512x512)
- **Character Morph:** Change character appearances, mounts, and visible items via Lua API
- **Display ID Manipulation:** `SetUnitDisplayID()`, `RemapDisplayID()`, etc.

**Lua API Functions:**
- `SetUnitMountDisplayID()` / `RemapMountDisplayID()`
- `SetUnitVisibleItemID()` / `RemapVisibleItemID()`
- `UnitDisplayInfo()`
- `GetItemDisplayID()`

**Relevance:** This library manipulates what models are displayed but does not implement outline/glow effects. Focused on model swapping rather than rendering effects.

### 2. Technique Summary: D3D9 Model Outline Methods

Based on comprehensive web research, here are the viable techniques for rendering model outlines in DirectX 9:

#### **Technique A: Stencil Buffer Two-Pass Outline**

**How It Works:**
1. **First Pass:** Render the model normally while writing a value (e.g., 1) to the stencil buffer
2. **Second Pass:** Render the model slightly scaled up with stencil test set to only draw where stencil ≠ 1 (the edges)

**D3D9 Implementation:**
```cpp
// Pass 1: Write to stencil
pDevice->SetRenderState(D3DRS_STENCILENABLE, TRUE);
pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
pDevice->SetRenderState(D3DRS_STENCILREF, 1);
pDevice->SetRenderState(D3DRS_STENCILPASS, D3DSTENCILOP_REPLACE);
// Render model normally...

// Pass 2: Draw outline where stencil != 1
pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_NOTEQUAL);
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);  // For through-walls visibility
// Render enlarged/scaled model with solid outline color...
```

**Depth Buffer Format:** Must use D3DFMT_D24S8 (24-bit depth + 8-bit stencil) to support stencil operations.

**Pros:**
- Clean outline edge detection
- Relatively efficient (two render passes)
- Standard technique used in many games

**Cons:**
- Requires model scaling/dilation (need transform matrix access)
- Simple uniform scaling doesn't work well for all mesh geometries
- For generic solution, mesh must be dilated (extruded along vertex normals), not just scaled

**Sources:**
- [Microsoft Learn: Stencil Buffer Techniques](https://learn.microsoft.com/en-us/windows/win32/direct3d9/stencil-buffer-techniques)
- [Stack Overflow: Using stencil buffer in Direct3D](https://stackoverflow.com/questions/6183791/using-stencil-buffer-in-direct3d)
- [Game Developer: Inside Direct3D Stencil Buffers](https://www.gamedeveloper.com/programming/inside-direct3d----stencil-buffers)

#### **Technique B: Scaled Backface Silhouette (Inverted Hull)**

**How It Works:**
1. **First Pass:** Render model normally with standard culling
2. **Second Pass:**
   - Scale model slightly larger (e.g., 1.02-1.05x)
   - Flip culling mode (cull front faces instead of back faces)
   - Render with solid outline color
   - The scaled back-faces create an outline around the normal model

**D3D9 Implementation:**
```cpp
// Pass 1: Normal render
pDevice->SetRenderState(D3DRS_CULLMODE, D3DCULL_CCW);
// Render model normally...

// Pass 2: Outline via scaled backfaces
pDevice->SetRenderState(D3DRS_CULLMODE, D3DCULL_CW);  // Cull front faces
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);   // Through walls
// Scale transform by 1.02-1.05x
// Render model with solid color shader
```

**Vertex Shader Approach:**
Scale each vertex along its normal direction:
```hlsl
// In vertex shader
float outlineWidth = 0.02; // 2% larger
output.position = input.position + (input.normal * outlineWidth);
```

**Pros:**
- Very efficient (used in Guilty Gear Xrd for performance)
- Easy to control outline thickness via vertex color
- Both external AND internal outlines (around lips, eyes, etc.)
- Generally cheaper than post-processing

**Cons:**
- Requires vertex shader for proper normal extrusion
- WoW 1.12.1 M2 models use their own vertex shaders (bone animation)
- May need to inject/replace vertex shader

**Sources:**
- [Game Dev Stack Exchange: How can I draw outlines around 3D models?](https://gamedev.stackexchange.com/questions/68401/how-can-i-draw-outlines-around-3d-models)
- [RoveCoder: DirectX 11 Stencil Outline](https://rovecoder.net/article/directx-11/stencil-outline)
- [Imaginary Blend: Backface culling based outlines](https://imaginaryblend.com/2018/07/15/533/)

#### **Technique C: Edge Detection Post-Process**

**How It Works:**
1. **First Pass:** Render scene with normals/depth to separate render target
2. **Second Pass:** Full-screen post-process applies edge detection filter (Sobel, etc.) to detect discontinuities
3. Draw detected edges as outlines

**Edge Detection Methods:**
- **Depth-based:** Detect sharp changes in depth buffer
- **Normal-based:** Detect changes in surface normal direction
- **Sobel filtering:** Classic image processing edge detection

**D3D9 Considerations:**
- Requires Multiple Render Targets (MRT) or multiple passes
- D3D9 has limited MRT support (max 4 targets)
- Depth/stencil cannot be directly bound as texture in D3D9 (use separate R32F render target)

**Pros:**
- True edge-only outline (no wireframe artifacts)
- Can detect both external silhouette and internal feature lines
- No model manipulation needed

**Cons:**
- More complex implementation (requires shaders, render targets)
- Higher performance cost than two-pass methods
- D3D9 limitations make it more difficult than modern APIs

**Sources:**
- [Medium: Three.js Post-processing outline Effect](https://medium.com/@coderfromnineteen/three-js-post-processing-outline-effect-6dff6a2fe3c0)
- [Ameye.dev: Edge Detection Outlines](https://ameye.dev/notes/edge-detection-outlines/)
- [Stack Overflow: Multiple Render Targets in DirectX9](https://stackoverflow.com/questions/10157734/multiple-render-targets-in-directx9)

#### **Technique D: Wireframe Overlay (Simple)**

**How It Works:**
Render the model twice:
1. **First Pass:** Normal textured render
2. **Second Pass:** Wireframe mode with thick lines in outline color

**D3D9 Implementation:**
```cpp
// Pass 1: Normal render
// ... render model ...

// Pass 2: Wireframe outline
pDevice->SetRenderState(D3DRS_FILLMODE, D3DFILL_WIREFRAME);
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);  // Through walls
pDevice->SetRenderState(D3DRS_TEXTUREFACTOR, outlineColor);
pDevice->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
pDevice->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TFACTOR);
// Render model again in wireframe...
```

**Pros:**
- Extremely simple to implement
- No matrix manipulation or shaders needed
- Works immediately with existing hooks

**Cons:**
- Shows internal wireframe triangles, not just outer silhouette
- Visual quality inferior to proper outline techniques
- May appear cluttered on high-poly models

**Relevance:** Good for quick prototyping but not production-quality.

#### **Technique E: Shader Injection/Replacement**

**How It Works:**
Hook D3D9 `SetVertexShader` and `SetPixelShader` calls to inject custom shaders that:
- Extrude vertices along normals for outline pass
- Apply solid colors or special effects
- Bypass depth testing for through-wall visibility

**D3D9 Hook Points:**
- `IDirect3DDevice9::CreateVertexShader` (vtable index varies)
- `IDirect3DDevice9::SetVertexShader` (vtable index varies)
- `IDirect3DDevice9::SetPixelShader` (vtable index varies)
- `IDirect3DDevice9::SetVertexShaderConstantF` - modify shader parameters

**Custom Shader Workflow:**
1. Hook `SetVertexShader` or `SetPixelShader`
2. Detect when WoW's M2 model shaders are being set
3. Replace with custom compiled shader that adds outline effect
4. Use `D3DXCompileShader()` to compile HLSL at runtime

**Pros:**
- Full control over rendering behavior
- Can implement sophisticated effects (rim lighting, Fresnel, etc.)
- Works within existing render pipeline

**Cons:**
- Complex - requires understanding WoW's shader system
- Must maintain compatibility with bone animation system
- May break with DXVK or other translation layers
- Requires reverse-engineering WoW's shader constants/inputs

**Sources:**
- [Microsoft Learn: Using Shaders in Direct3D 9](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-using-shaders-9)
- [Microsoft Learn: IDirect3DDevice9::SetVertexShaderConstantF](https://learn.microsoft.com/en-us/windows/win32/api/d3d9/nf-d3d9-idirect3ddevice9-setvertexshaderconstantf)
- [CodePal: Direct3D Hooks in C++](https://codepal.ai/code-generator/query/ubPbNvDO/implementing-direct3d-hooks-cpp)

### 3. Recommended Approach for WoW 1.12.1 M2 Models

Given the specific constraints of your project:
- WoW 1.12.1 M2 models use custom vertex shaders for bone animation
- M2 models ignore standard D3D9 render states (D3DRS_ZENABLE, D3DRS_TEXTUREFACTOR, etc.)
- Models render BEFORE world geometry (walls occlude even with Z-disabled)
- You already have DrawIndexedPrimitive hook infrastructure

**Primary Recommendation: Stencil Buffer + DrawIndexedPrimitive Hook**

**Implementation Strategy:**

1. **Hook DrawIndexedPrimitive (D3D9 vtable index 82)**
   - Already have vtable patching infrastructure from EndScene hook
   - Can identify corpse models by comparing against tracked model pointers

2. **Two-Pass Rendering with Stencil:**

```cpp
HRESULT WINAPI hkDrawIndexedPrimitive(
    IDirect3DDevice9* pDevice,
    D3DPRIMITIVETYPE Type,
    INT BaseVertexIndex,
    UINT MinVertexIndex,
    UINT NumVertices,
    UINT StartIndex,
    UINT PrimitiveCount)
{
    // Check if this model belongs to tracked corpse
    bool isCorpseModel = IsTrackedCorpseModel();

    if (isCorpseModel) {
        // PASS 1: Render to stencil buffer
        DWORD oldStencilEnable, oldStencilFunc, oldStencilRef, oldStencilPass;
        pDevice->GetRenderState(D3DRS_STENCILENABLE, &oldStencilEnable);
        pDevice->GetRenderState(D3DRS_STENCILFUNC, &oldStencilFunc);
        pDevice->GetRenderState(D3DRS_STENCILREF, &oldStencilRef);
        pDevice->GetRenderState(D3DRS_STENCILPASS, &oldStencilPass);

        pDevice->SetRenderState(D3DRS_STENCILENABLE, TRUE);
        pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
        pDevice->SetRenderState(D3DRS_STENCILREF, 1);
        pDevice->SetRenderState(D3DRS_STENCILPASS, D3DSTENCILOP_REPLACE);

        // Render model normally (writes to stencil)
        oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                              NumVertices, StartIndex, PrimitiveCount);

        // PASS 2: Render outline where stencil == 0 (edges only)
        // Problem: Need to render scaled/enlarged model here
        // WoW's transform matrices are managed internally
        // May need to use wireframe as simpler alternative

        // Restore stencil states
        pDevice->SetRenderState(D3DRS_STENCILENABLE, oldStencilEnable);
        pDevice->SetRenderState(D3DRS_STENCILFUNC, oldStencilFunc);
        pDevice->SetRenderState(D3DRS_STENCILREF, oldStencilRef);
        pDevice->SetRenderState(D3DRS_STENCILPASS, oldStencilPass);

        return D3D_OK;
    }

    return oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                                  NumVertices, StartIndex, PrimitiveCount);
}
```

**Why This Approach:**
- Works at D3D9 API level (after WoW's internal rendering)
- Can identify corpse models via your existing model tracking
- Stencil buffer approach proven to work in D3D9
- Doesn't require understanding WoW's internal transform matrices

**Remaining Challenge: Model Scaling for Outline Pass**

The stencil approach requires rendering a slightly enlarged version of the model in pass 2. Options:

**Option 1: Wireframe Instead of Scaled Model**
- Use `D3DRS_FILLMODE = D3DFILL_WIREFRAME` for pass 2
- Simpler, no scaling needed
- Quality is lower but functional

**Option 2: Capture and Modify Vertex Buffer**
- In pass 1, capture vertex buffer pointer via `GetStreamSource`
- Lock vertex buffer, scale vertices along calculated normals
- Render modified vertices in pass 2
- Restore original vertex buffer
- Complex but provides true outline

**Option 3: Vertex Shader Injection**
- Create custom vertex shader that extrudes vertices along normals
- Inject via `SetVertexShader` hook when rendering corpse
- Must preserve WoW's bone animation inputs
- Most technically sophisticated

### 4. Implementation Notes

#### A. Setting Up Stencil Buffer

**Ensure Depth/Stencil Surface Format:**
```cpp
// During device initialization or reset
D3DPRESENT_PARAMETERS d3dpp;
d3dpp.AutoDepthStencilFormat = D3DFMT_D24S8; // 24-bit depth, 8-bit stencil
d3dpp.EnableAutoDepthStencil = TRUE;
```

**Clearing Stencil at Frame Start:**
```cpp
// In BeginScene or frame start
pDevice->Clear(0, NULL, D3DCLEAR_TARGET | D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL,
               0, 1.0f, 0);
```

#### B. Handling Through-Wall Visibility

The key issue discovered: M2 models render BEFORE world geometry, so disabling depth test at DIP level doesn't help.

**Solution: Post-Render Pass in EndScene**

```cpp
// In EndScene hook (after all rendering complete)
void hkEndScene(IDirect3DDevice9* pDevice) {
    // World geometry has been rendered
    // Now re-render corpse models with Z-disabled

    for (auto& corpseModel : g_trackedCorpseModels) {
        // Set states for through-wall rendering
        pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
        pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);

        // Render cached corpse geometry here
        // Challenge: Need to cache vertex/index buffers during normal render
    }

    // Call original EndScene
    oEndScene(pDevice);
}
```

**Caching Geometry During Normal Render:**
```cpp
// In DrawIndexedPrimitive hook
if (isCorpseModel) {
    // Cache rendering parameters
    IDirect3DVertexBuffer9* pVB;
    UINT offset, stride;
    pDevice->GetStreamSource(0, &pVB, &offset, &stride);

    IDirect3DIndexBuffer9* pIB;
    pDevice->GetIndices(&pIB);

    // Store for later replay in EndScene
    CacheCorpseGeometry(pVB, pIB, BaseVertexIndex, MinVertexIndex,
                        NumVertices, StartIndex, PrimitiveCount, Type);
}
```

#### C. Identifying Corpse Models in DrawIndexedPrimitive

You have model tracking via `ModelOutline_AddDeadPlayerModel()`. Need to correlate DIP calls:

**Method 1: Model Pointer Correlation**
- In WoW's internal hooks, store model memory address
- In DIP, check if current vertex buffer belongs to that model
- Difficult: No direct mapping from VB to model

**Method 2: Stride/Count Fingerprinting**
- Log stride, vertex count, primitive count for known corpse models
- Use these signatures to identify corpse draws
- Empirical but effective

**Method 3: Render State Markers**
- In WoW internal hook, set a unique render state when corpse model starts rendering
- In DIP, check for that marker state
- Example: `SetRenderState(D3DRS_TEXTUREFACTOR, CORPSE_MARKER_VALUE)`

#### D. Code Pattern: Complete DIP Hook with Stencil Outline

```cpp
HRESULT WINAPI hkDrawIndexedPrimitive(
    IDirect3DDevice9* pDevice,
    D3DPRIMITIVETYPE Type,
    INT BaseVertexIndex,
    UINT MinVertexIndex,
    UINT NumVertices,
    UINT StartIndex,
    UINT PrimitiveCount)
{
    // Save all states we'll modify
    DWORD oldStencilEnable, oldStencilFunc, oldStencilRef;
    DWORD oldStencilPass, oldFillMode, oldZEnable;

    pDevice->GetRenderState(D3DRS_STENCILENABLE, &oldStencilEnable);
    pDevice->GetRenderState(D3DRS_STENCILFUNC, &oldStencilFunc);
    pDevice->GetRenderState(D3DRS_STENCILREF, &oldStencilRef);
    pDevice->GetRenderState(D3DRS_STENCILPASS, &oldStencilPass);
    pDevice->GetRenderState(D3DRS_FILLMODE, &oldFillMode);
    pDevice->GetRenderState(D3DRS_ZENABLE, &oldZEnable);

    // Check if this is a corpse model
    bool isCorpse = IsTrackedCorpseModel(pDevice);

    if (isCorpse) {
        // PASS 1: Normal render + stencil write
        pDevice->SetRenderState(D3DRS_STENCILENABLE, TRUE);
        pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
        pDevice->SetRenderState(D3DRS_STENCILREF, 1);
        pDevice->SetRenderState(D3DRS_STENCILPASS, D3DSTENCILOP_REPLACE);

        oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                              NumVertices, StartIndex, PrimitiveCount);

        // PASS 2: Wireframe outline where stencil != 1
        pDevice->SetRenderState(D3DRS_STENCILFUNC, D3DCMP_NOTEQUAL);
        pDevice->SetRenderState(D3DRS_FILLMODE, D3DFILL_WIREFRAME);
        pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE); // Try for through-walls

        // Set outline color
        pDevice->SetRenderState(D3DRS_TEXTUREFACTOR, D3DCOLOR_ARGB(255, 255, 0, 255));
        pDevice->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
        pDevice->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TFACTOR);

        oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                              NumVertices, StartIndex, PrimitiveCount);

        // Restore states
        pDevice->SetRenderState(D3DRS_STENCILENABLE, oldStencilEnable);
        pDevice->SetRenderState(D3DRS_STENCILFUNC, oldStencilFunc);
        pDevice->SetRenderState(D3DRS_STENCILREF, oldStencilRef);
        pDevice->SetRenderState(D3DRS_STENCILPASS, oldStencilPass);
        pDevice->SetRenderState(D3DRS_FILLMODE, oldFillMode);
        pDevice->SetRenderState(D3DRS_ZENABLE, oldZEnable);

        return D3D_OK;
    }

    // Normal rendering for non-corpse models
    return oDrawIndexedPrimitive(pDevice, Type, BaseVertexIndex, MinVertexIndex,
                                  NumVertices, StartIndex, PrimitiveCount);
}
```

### 5. Reference Links

**Repository Analysis:**
- [UnitXP_SP3 on Codeberg](https://codeberg.org/konaka/UnitXP_SP3)
- [perf_boost on Gitea](https://gitea.com/avitasia/perf_boost)
- [VanillaHelpers on GitHub](https://github.com/isfir/VanillaHelpers)

**Stencil Buffer Techniques:**
- [Microsoft Learn: Stencil Buffer Techniques (Direct3D 9)](https://learn.microsoft.com/en-us/windows/win32/direct3d9/stencil-buffer-techniques)
- [Stack Overflow: Using stencil buffer in Direct3D](https://stackoverflow.com/questions/6183791/using-stencil-buffer-in-direct3d)
- [Game Developer: Inside Direct3D Stencil Buffers](https://www.gamedeveloper.com/programming/inside-direct3d----stencil-buffers)
- [LearnOpenGL: Stencil testing](https://learnopengl.com/Advanced-OpenGL/Stencil-testing) (OpenGL but concepts translate)

**Outline Rendering Techniques:**
- [Game Dev Stack Exchange: How can I draw outlines around 3D models?](https://gamedev.stackexchange.com/questions/68401/how-can-i-draw-outlines-around-3d-models)
- [RoveCoder: DirectX 11 Stencil Outline](https://rovecoder.net/article/directx-11/stencil-outline) (DX11 but technique applies)
- [Imaginary Blend: Backface culling based outlines](https://imaginaryblend.com/2018/07/15/533/)
- [Ameye.dev: Edge Detection Outlines](https://ameye.dev/notes/edge-detection-outlines/)

**D3D9 Shader and Hooking:**
- [Microsoft Learn: Using Shaders in Direct3D 9](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-using-shaders-9)
- [Microsoft Learn: IDirect3DDevice9::SetPixelShader](https://learn.microsoft.com/en-us/windows/win32/api/d3d9/nf-d3d9-idirect3ddevice9-setpixelshader)
- [Microsoft Learn: IDirect3DDevice9::SetVertexShaderConstantF](https://learn.microsoft.com/en-us/windows/win32/api/d3d9/nf-d3d9-idirect3ddevice9-setvertexshaderconstantf)
- [CodePal: Direct3D Hooks in C++](https://codepal.ai/code-generator/query/ubPbNvDO/implementing-direct3d-hooks-cpp)
- [Stack Overflow: D3D9 Hooking (EndScene + DrawIndexedPrimitive)](https://stackoverflow.com/questions/47652902/d3d9-hooking-endscene-drawindexedprimitive)

**Depth and Render States:**
- [Microsoft Learn: D3DRENDERSTATETYPE enumeration](https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3drenderstatetype)
- [Microsoft Learn: Depth Buffering State (Direct3D 9)](https://learn.microsoft.com/en-us/windows/win32/direct3d9/depth-buffering-state)
- [Microsoft Learn: Changing Depth Buffer Comparison Functions](https://learn.microsoft.com/en-us/windows/win32/direct3d9/changing-depth-buffer-comparison-functions)

**WoW-Specific:**
- [wowdev.wiki: Rendering](https://wowdev.wiki/Rendering)
- [wowdev.wiki: M2](https://wowdev.wiki/M2)
- [wowdev.wiki: M2/Rendering](https://wowdev.wiki/M2/Rendering)
- [wowdev.wiki: M2/.skin](https://wowdev.wiki/M2/.skin)

---

## Summary [OUTDATED - See "Working Implementation" at end]

> This section documented early research plans. The final implementation is different.
> See "Working Implementation: Shader-Based Outline System" for the actual solution.

**What was actually implemented:**
- Custom vertex shader with full bone transforms + normal expansion
- Stencil-based rendering in EndScene (not wireframe)
- Create our own D24S8 depth/stencil surface (WoW's is D24X8)
- Per-category effects: dark halo for dead players, colored outlines for raid marks/targets

---

## Solid Color Rendering Technique (WORKING - 2024-12)

### Discovery: Back-Face Culling with Z-Disabled

Successfully implemented solid color rendering of corpse models visible through walls using:

1. **Geometry caching at DIP level** - Store vertex/index buffers and shader constants
2. **EndScene replay** - Re-render cached geometry after all world geometry
3. **Back-face culling** - Cull front faces (D3DCULL_CW), render only back faces
4. **Z-disabled** - Model visible through walls

**Key Code Pattern:**
```cpp
// In ReplayCorpseOutlines (EndScene):
// Disable depth test - visible through walls
pDevice->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
pDevice->SetRenderState(D3DRS_ZWRITEENABLE, FALSE);

// Cull FRONT faces - only render back faces
pDevice->SetRenderState(D3DRS_CULLMODE, D3DCULL_CW);

// Solid color via texture factor (requires disabling pixel shader)
pDevice->SetPixelShader(NULL);  // CRITICAL: Must disable WoW's pixel shader
pDevice->SetRenderState(D3DRS_TEXTUREFACTOR, solidColor);
pDevice->SetTextureStageState(0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
pDevice->SetTextureStageState(0, D3DTSS_COLORARG1, D3DTA_TFACTOR);

// Re-render with cached vertex shader and bone matrices
pDevice->SetVertexShader(draw.pVertexShader);
pDevice->SetVertexShaderConstantF(0, draw.VSConstants, draw.VSConstantCount);
g_oDrawIndexedPrimitive(pDevice, ...);
```

**Why This Works:**
- M2 models use VERTEX shaders for bone animation (must keep these)
- M2 models use PIXEL shaders for texturing (must DISABLE these for solid color)
- Disabling pixel shader allows TEXTUREFACTOR to work
- Back-face culling shows back surfaces which are visible at silhouette edges
- EndScene replay happens AFTER walls render, so Z-disable works for through-wall

**Result:** Corpse renders as solid cyan color visible through walls.

**Limitation:** Without scaling, back faces cover the entire model instead of just the edges. Need to scale the model slightly larger so back faces only show around the silhouette.

### Resolution: Custom Vertex Shader

Matrix scaling approaches didn't work well. Final solution uses a custom vertex shader that:
1. Performs full bone transforms (same as WoW's shader)
2. Expands vertices along their normals by a configurable thickness
3. Uses stencil buffer to prevent outline from covering body

See "Working Implementation: Shader-Based Outline System" for shader code.

---

## Shader Constant Analysis (2024-12)

### Logged Vertex Shader Constants (c0-c7)

From corpse model rendering at DrawBatchProj:

```
c0: 0.000 0.000 0.000 0.000  <- Unused/zero
c1: 0.000 0.000 0.000 0.000  <- Unused/zero
c2: 1.054 0.000 0.000 0.000  <- X scale (aspect/FOV related)
c3: 0.000 1.874 0.000 0.000  <- Y scale (aspect/FOV related)
c4: 0.000 0.000 1.000 -0.080 <- Z with small offset (-0.08)
c5: 0.000 0.000 1.000 0.000  <- Z identity
c6: 1.000 0.000 0.000 0.000  <- X identity
c7: 0.000 1.000 0.000 0.000  <- Y identity
```

### Key Observations

1. **NOT a standard view-projection matrix** - Values are sparse scale/offset factors
2. **c2/c3 are aspect ratio scales** - 1.054 and 1.874 relate to screen aspect ratio and FOV
3. **c4 has Z offset** - The -0.080 suggests depth bias or near plane offset
4. **c6/c7 are identity-like** - Possibly additional coordinate transforms

### Scaling Experiment Results

**Attempted:** Scale c0.x, c1.y, c2.x, c3.y by `g_outlineThickness` (1.2x)

**Result:**
- Model silhouette appears larger ✓
- But silhouette MOVES when view angle changes ✗
- Silhouette covers corpse instead of outlining it ✗

**Root Cause:** Scaling these projection-space constants distorts the view transformation, not the model. The model center isn't at origin in view space, so scaling pushes it in different directions based on camera angle.

### Why Back-Face Culling Alone Doesn't Create Outlines

The back-face culling technique requires:
1. Model A rendered at normal scale (front faces visible)
2. Model B rendered **SCALED LARGER** (back faces only)
3. The back faces of B extend beyond A's silhouette = visible outline

**Current problem:** We're not scaling the model in world space. We're distorting the view-projection, which:
- Shifts model position (not centered at origin)
- Doesn't uniformly enlarge in screen space
- Creates a moving silhouette, not an outline

### Correct Scaling Requirements

For proper outline, need to scale vertices **from the model's center point** in world space:

```
scaled_vertex = model_center + (vertex - model_center) * scale_factor
```

This requires knowing `model_center` - the centroid of the model in world space.

---

## Outline Approach Options Analysis

### Option 1: Find Model Center from WoW Memory

**Concept:** Read the model's world-space position from WoW's object memory, use it as scale center.

**Implementation:**
1. From corpse object, get position at `corpse + 0x9E8` or via `GetUnitPosition` (0x00606F50)
2. Pass model center to custom vertex shader via constants (c8+)
3. In shader: `scaled = center + (vertex - center) * scale`
4. Transform scaled vertex with original view-projection

**Shader Code (vs_1_1):**
```hlsl
vs_1_1
dcl_position v0
; c0-c7 = original WoW constants
; c8.xyz = model center (world space)
; c9.x = scale factor

; Offset vertex from center
sub r0.xyz, v0.xyz, c8.xyz   ; r0 = vertex - center
mul r0.xyz, r0.xyz, c9.x     ; r0 = (vertex - center) * scale
add r0.xyz, r0.xyz, c8.xyz   ; r0 = center + scaled_offset
mov r0.w, v0.w               ; preserve W

; Apply original transform
dp4 oPos.x, r0, c0
dp4 oPos.y, r0, c1
dp4 oPos.z, r0, c2
dp4 oPos.w, r0, c3
```

**Pros:**
- Correct mathematical approach
- Controllable thickness via scale factor
- Works with existing bone animation (vertices already skinned)

**Cons:**
- Requires reading model position from WoW memory
- Need to understand WoW's coordinate system
- Shader must match WoW's expected inputs

**Thickness Control:** Direct - scale factor of 1.02 = 2% larger = thin outline, 1.10 = thick outline

### Option 3: Post-Process Edge Detection

**Concept:** Instead of scaling geometry, detect edges in the rendered image using depth/normal discontinuities.

**Implementation:**
1. During corpse rendering, write depth to a separate render target
2. In EndScene, run edge detection shader on depth buffer
3. Draw detected edges as colored outline

**Edge Detection Methods:**

**A. Sobel Filter on Depth:**
```hlsl
// Sample depth buffer at 8 neighbors
float depthL = tex2D(depthSampler, uv + float2(-1, 0) * texelSize).r;
float depthR = tex2D(depthSampler, uv + float2(+1, 0) * texelSize).r;
// ... etc
// Compute Sobel gradient magnitude
float edge = length(sobelX) + length(sobelY);
```

**B. Roberts Cross on Depth:**
Simpler 2x2 kernel, faster but less accurate.

**C. Normal-based Edge Detection:**
Requires rendering normals to a texture - more complex setup.

**D3D9 Implementation Challenges:**
- Cannot directly read depth buffer as texture in D3D9
- Need to render depth to a R32F render target in first pass
- Requires pixel shader 2.0+ for edge detection
- May need Multiple Render Targets (MRT) or extra passes

**Pros:**
- True edge-only outline (no filled silhouette)
- Detects internal feature lines (eyes, armor details)
- No geometry manipulation needed

**Cons:**
- More complex (requires render targets, shaders)
- Higher performance cost
- D3D9 limitations (can't sample depth buffer directly)
- Outline is screen-space pixels, not world-space thickness

**Thickness Control:** Indirect - controlled by texel sampling distance. Harder to make consistent across distances.

### Recommendation

**Option 1 (Model Center Scaling) is more suitable because:**
1. Controllable world-space thickness
2. Works with existing EndScene replay infrastructure
3. Simpler implementation (single shader modification)
4. Consistent outline regardless of distance

**Option 3 (Post-Process) would require:**
1. Additional render target creation
2. Multiple rendering passes
3. New shader infrastructure
4. Solving D3D9 depth buffer limitations

---

## Coordinate Space Discovery (2024-12)

### Key Finding: Vertices are in MODEL SPACE, not World Space

From vertex buffer analysis during draw call caching:

```
Model center (from vertex centroid): 0.03, -0.00, 2.00
```

This is **model-local coordinates** - the 2.0 Z value is approximately chest height on a humanoid character. The vertices are NOT pre-transformed to world space.

### Shader Constants Contain World Transform Data

```
c9: -0.000, -1000.000, 500.000, -0.000  <- WORLD POSITION!
c10-c15: varying values per frame       <- Bone matrices / animation
```

The c9 values (-1000, 500) are typical WoW world coordinates. This confirms:
- **c2-c7**: View-projection transform (aspect ratio, FOV, depth)
- **c8-c9**: World position / transform data
- **c10-c15**: Bone matrices (change with animation)

### Transform Chain

WoW's vertex shader performs:
```
Model Space → (bone transforms c10-c15) → (world offset c8-c9) → (view-proj c2-c7) → Clip Space
```

### Why Custom Shader Failed

The custom shader only implemented the last stage:
```hlsl
mul oPos.x, r0.x, c2.x    // View-proj X
mul oPos.y, r0.y, c3.y    // View-proj Y
```

This skipped the world positioning, causing the model to render at screen origin (top-down view on monitor).

### Current Status

Using WoW's original shader with all cached constants renders the silhouette correctly positioned over the corpse, but **without scaling** (no outline effect yet).

### Scaling Options Going Forward

**Option A: Scaled Vertex Buffer Copy**
1. Create a dynamic vertex buffer during caching
2. Copy vertices with positions scaled from model-space center
3. Use scaled VB for outline pass, original VB for normal render
4. Pro: Works with WoW's full transform chain
5. Con: Memory overhead, VB creation per frame

**Option B: Modify Cached Vertex Data In-Place**
1. Lock original VB and scale positions temporarily
2. Render outline pass
3. Restore original positions
4. Pro: No extra memory
5. Con: May cause visual glitches if timing is wrong

**Option C: Inject Scale into Bone Matrices**
1. Identify which constants are bone matrices (c10-c15?)
2. Multiply bone matrices by scale factor
3. Pro: Cleaner than VB modification
4. Con: Requires understanding bone matrix layout

**Option D: Post-Process Edge Detection**
1. Render corpse to stencil/depth buffer
2. Detect edges via pixel shader
3. Pro: True edge-only outline
4. Con: Complex, D3D9 limitations

---

## Implementation Progress: Scaled Vertex Buffer Approach (2024-12) [SUPERSEDED]

> **Note:** This approach was superseded by the shader-based stencil system.
> Key issues: Scaled VB didn't handle bone animations, created artifacts.
> See "Working Implementation: Shader-Based Outline System" for the final solution.

### Lessons Learned

1. **Stencil IS available**: WoW uses D3DFMT_D24X8 (no stencil), but we can create our own D3DFMT_D24S8 surface and swap it in during EndScene.

2. **Shader-based expansion is superior**: Instead of pre-scaling vertex buffers:
   - Custom vertex shader expands along normals in world space
   - Properly handles bone animations via same bone transform as WoW
   - No need to cache/create scaled VBs

3. **Full bone transform required**: WoW's M2 models use skeletal animation. Any outline expansion must happen AFTER bone transforms, not in model space.

---

## Critical Discovery: Depth Buffer Cleared at EndScene (2024-12)

### Problem

When rendering corpse body in EndScene with depth testing enabled:
- `D3DCMP_LESSEQUAL`: Body **never** renders (fails everywhere)
- `D3DCMP_GREATEREQUAL`: Body **always** renders (passes everywhere)
- `D3DCMP_ALWAYS`: Body renders (as expected)

### Analysis

This behavior indicates the depth buffer is cleared to **0 (near plane)** before EndScene:
- If depth buffer = 0 everywhere:
  - Body depth > 0, so LESSEQUAL (body ≤ 0) fails
  - Body depth > 0, so GREATEREQUAL (body ≥ 0) passes
  - GREATER (body > 0) also passes

### Implications

1. **Cannot use depth buffer at EndScene** for wall occlusion testing
2. **Scene depth information is lost** by the time EndScene is called
3. **Depth bias has no effect** - buffer is all zeros regardless of bias value

### The Fundamental Conflict

Requirements:
1. Silhouette visible through walls → must render AFTER walls (EndScene)
2. Body covers silhouette → body must render AFTER silhouette
3. Walls occlude body → body must use depth test against walls

But at EndScene, wall depth info is gone. We cannot satisfy all three requirements.

### Attempted Solutions

| Approach | Result |
|----------|--------|
| EndScene: silhouette (depth off) + body (depth on) | Body fails depth test everywhere |
| EndScene: silhouette (GREATER) | Shows everywhere (buffer is 0) |
| Depth bias to push silhouette forward | No effect (buffer is 0) |
| Let body render in main pass, silhouette in EndScene | Silhouette covers body |

### Potential Solutions

1. **Find hook point after walls but before depth clear** - Need to identify where WoW clears depth
2. **Render silhouette in DIP hook** - But then walls cover silhouette (no through-wall)
3. **Accept visual compromise** - Semi-transparent outline that shows over body slightly

### Resolution

The stencil buffer solved this problem:
1. Mark body pixels in stencil (pass 1) - no color write
2. Render dark halo/outline where stencil ≠ body (pass 2) - creates outline effect
3. Depth buffer not needed - stencil provides the "body vs outline" distinction

See "Working Implementation: Shader-Based Outline System" below for details.

---

## Working Implementation: Shader-Based Outline System (2024-12)

### Overview

The final working system uses a custom vertex shader that performs full bone transforms, combined with stencil-based rendering in EndScene for proper layering and through-wall visibility.

### Architecture

```
Frame Render Order:
1. WoW renders world geometry (terrain, walls, objects)
2. DrawIndexedPrimitive hook detects corpse/target/raid-marked models
3. Draw calls are cached with full D3D state
4. EndScene hook replays cached draws with stencil-based outline rendering
```

### Key Components

#### 1. Draw Call Caching (CacheCorpseDrawCall)

When a tracked model is detected during rendering, we cache:
- Primitive parameters (type, indices, vertex count)
- Vertex buffer, index buffer, vertex declaration
- Vertex shader and all 256 VS constants (bone matrices!)
- Pixel shader and PS constants
- Transforms (world, view, projection)
- Texture state
- Model category (TARGET, RAID_MARKED, DEAD_PLAYER)
- Calculated outline thickness based on distance

#### 2. WoW M2 Vertex Format

WoW's character models use this vertex layout:
```
Offset 0x00:  POSITION     (float3)     - Local vertex position
Offset 0x0C:  BLENDWEIGHT  (D3DCOLOR)   - 4 bone weights (normalized 0-255)
Offset 0x10:  BLENDINDICES (D3DCOLOR)   - 4 bone indices (0-255)
Offset 0x14:  NORMAL       (float3)     - Vertex normal
```

D3DCOLOR stores 4 bytes as ARGB (0xAARRGGBB), but when read as blend weights/indices:
- Component order in shader is .zyxw (BGRA swizzle)
- Bone weights are normalized (0-255 → 0.0-1.0)
- Bone indices are raw byte values

#### 3. Bone Matrix Storage

WoW stores bone matrices in vertex shader constants starting at c31:
- Each bone uses 3 consecutive float4 constants (4x3 matrix rows)
- Bone N is at: c[N*3 + 31], c[N*3 + 32], c[N*3 + 33]
- To convert bone index to constant offset: index * 765 (when indices are 0-1 normalized)

Example: Bone index 0 → constants c31, c32, c33
         Bone index 1 → constants c34, c35, c36

#### 4. Custom Outline Vertex Shader

The shader performs full skeletal animation then expands along normals:

```asm
vs_2_0
dcl_position v0         ; position (float3)
dcl_blendweight v2      ; blend weights (D3DCOLOR normalized)
dcl_blendindices v3     ; blend indices (D3DCOLOR)
dcl_normal v1           ; normal (float3)

; Convert blend indices to bone constant offsets
; v3 components are 0-1 (D3DCOLOR normalized), multiply by 765 to get bone index * 3
; WoW uses zyxw swizzle order (BGRA)
mul r0.xyz, v3.zyxw, c251.x    ; indices * 765
mova a0.xyz, r0                 ; move to address register for indexed access

; First bone row (transforms to get world X)
mul r0, v2.y, c[a0.y + 31]
mad r0, c[a0.x + 31], v2.z, r0
mad r0, c[a0.z + 31], v2.x, r0
dp3 r3.x, r0, v1               ; normal.x after bone transform
dp4 r4.x, r0, v0               ; position.x after bone transform

; Second bone row (world Y)
mul r1, v2.y, c[a0.y + 32]
mad r1, c[a0.x + 32], v2.z, r1
mad r1, c[a0.z + 32], v2.x, r1
dp3 r3.y, r1, v1               ; normal.y
dp4 r4.y, r1, v0               ; position.y

; Third bone row (world Z)
mul r2, v2.y, c[a0.y + 33]
mad r2, c[a0.x + 33], v2.z, r2
mad r2, c[a0.z + 33], v2.x, r2
dp3 r3.z, r2, v1               ; normal.z
dp4 r4.z, r2, v0               ; position.z

; Now r4.xyz = world-space position, r3.xyz = world-space normal (unnormalized)
nrm r5.xyz, r3                  ; normalize the normal

; Expand position along normal for outline effect
mul r6.xyz, r5.xyz, c250.x      ; normal * thickness (c250.x)
add r4.xyz, r4.xyz, r6.xyz      ; position += normal_offset
mov r4.w, c251.y                ; w = 1.0

; Apply view-projection matrix (c2-c5 in WoW's constants)
dp4 oPos.x, c2, r4
dp4 oPos.y, c3, r4
dp4 oPos.z, c4, r4
dp4 oPos.w, c5, r4
```

Shader constants:
- c0-c249: WoW's original constants (bone matrices, transforms, lighting)
- c250.x: Outline thickness (world units)
- c251: Helper constants (765.0, 1.0, 0.0, 0.0)

The `mova` instruction is critical - it allows indexed access to bone matrix constants based on per-vertex bone indices.

#### 5. Stencil-Based Rendering (EndScene)

Three-pass rendering for proper outline effect:

**Pass 1: Mark body in stencil buffer**
```cpp
SetRenderState(D3DRS_STENCILENABLE, TRUE);
SetRenderState(D3DRS_STENCILFUNC, D3DCMP_ALWAYS);
SetRenderState(D3DRS_STENCILPASS, D3DSTENCILOP_REPLACE);
SetRenderState(D3DRS_STENCILREF, 1);
SetRenderState(D3DRS_COLORWRITEENABLE, 0);  // No color, stencil only
// Render body at original size → marks stencil = 1 where body is
```

**Pass 2: Dark halo (dead players only)**
```cpp
SetRenderState(D3DRS_STENCILFUNC, D3DCMP_NOTEQUAL);  // Not where body is
SetRenderState(D3DRS_STENCILREF, 1);
SetRenderState(D3DRS_TEXTUREFACTOR, 0x80000000);     // 50% alpha black
// Render with shader at 4x thickness → dark halo around body
```

**Pass 3: Bright outline (raid marks, targets)**
```cpp
SetRenderState(D3DRS_STENCILFUNC, D3DCMP_NOTEQUAL);
SetRenderState(D3DRS_STENCILREF, 1);
SetRenderState(D3DRS_TEXTUREFACTOR, outlineColor);   // Per-model color
// Render with shader at normal thickness → colored outline
```

All passes use `D3DRS_ZENABLE = FALSE` for through-wall visibility.

#### 6. Per-Category Outline Handling

Three model categories with different visual treatment:

| Category | Base Thickness | Min | Max | Effect |
|----------|---------------|-----|-----|--------|
| TARGET | 0.08 | 0.06 | 0.375 | White outline |
| RAID_MARKED | 0.05 | 0.04 | 0.375 | Colored outline (matches marker) |
| DEAD_PLAYER | 0.02 | 0.02 | 0.15 | Dark halo (4x thickness, 50% black) |

Thickness scales with distance to maintain consistent screen-space size:
```cpp
float scale = distance / OUTLINE_REFERENCE_DISTANCE;  // 20 yards reference
float thickness = baseThickness * scale;
// Then clamp to per-category min/max
```

Target has larger minimum than raid marks so it's more prominent at close range, but converges to same maximum at long range.

#### 7. Custom Depth/Stencil Surface

WoW uses D3DFMT_D24X8 (no stencil). We create our own D3DFMT_D24S8 surface:
```cpp
pDevice->CreateDepthStencilSurface(width, height, D3DFMT_D24S8, ...);
// Swap in our surface for stencil passes, restore original after
```

### Model Detection

Models are tracked via:
1. **Dead players**: GUIDs added when unit has dead flag, removed when alive
2. **Raid marks**: Model pointers added each frame for units with raid target icons
3. **Current target**: Model pointer updated each frame from wow_get_target()

Self-outline prevention: Local player is excluded from target and raid mark outlines.

### Files

- `d3d9_hook.cpp`: EndScene/DIP hooks, stencil rendering, shader creation
- `model_outline_hook.cpp`: Model tracking, color/category lookups, thickness values
- `dead_overlay.cpp`: Frame update logic, populates model tracking from game state

### Status

- ✅ Full bone transform shader working
- ✅ Stencil-based outline rendering
- ✅ Per-category visual effects (outline vs dark halo)
- ✅ Distance-based thickness scaling with min/max clamping
- ✅ Through-wall visibility
- ✅ Self-outline prevention
