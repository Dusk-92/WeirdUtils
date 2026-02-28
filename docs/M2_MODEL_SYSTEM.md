# WoW M2 Model System Analysis

This document describes the process World of Warcraft (1.12.x client) uses to load, manage, and render M2 model files. The analysis is based on reverse engineering of the game client binary.

## Overview

M2 (Model 2) files are the primary 3D model format used in WoW for characters, creatures, doodads, items, and effects. The engine uses a sophisticated multi-layered system involving:

1. **CM2Shared** - Shared model data (geometry, bones, textures) loaded once per model file
2. **CM2Model** - Per-instance model data (animation state, transforms, attachments)
3. **CM2Scene** - Scene management and batch rendering system

## Key Data Structures

### CM2Model (Instance Data)
Located at per-instance memory, key offsets:
- `+0x10`: Initialization flag (0 = not loaded, 1 = loaded)
- `+0x2c`: Parent scene/world context pointer
- `+0x30`: Pointer to CM2Shared data
- `+0x34`: Parent CM2Model (for attachments)
- `+0x44-0x48`: Render list linked list pointers (prev/next)
- `+0x64`: Color/texture lookup table
- `+0x90`: Bone animation state array
- `+0x94`: Bone matrix array (4x4 matrices, 0x40 bytes each)
- `+0xa0`: Texture animation state
- `+0xa4`: Texture reference array
- `+0x1cc`: Next sibling model (for hierarchy traversal)
- `+0x1dc`: Child model list head
- `+0x1e8`: Children initialized flag
- `+0x200`: Particle emitter instance array
- `+0x3c4`: Ribbon emitter state array
- `+0x3c8`: Particle emitter parameters
- `+0x3cc`: Particle system object pointers
- `+0x3d0`: Ribbon emitter parameters
- `+0x3d4`: Ribbon system object pointers

### CM2Shared (Shared Model Data)
Contains the actual model geometry and animation data loaded from .M2 files:
- `+0x14`: Number of global sequences
- `+0x18`: Global sequence data offset
- `+0x1c`: Number of animations
- `+0x20`: Animation data offset
- `+0x24`: Animation lookup table offset
- `+0x34`: Number of bones
- `+0x38`: Bone data offset
- `+0x48`: Vertex data (positions, normals, UVs, bone weights)
- `+0x50`: LOD skin data pointer
- `+0x54`: Number of texture animations
- `+0x5c`: Number of textures
- `+0x60`: Texture type/flags array
- `+0x64`: Number of transparency animations
- `+0x6c`: Number of UV animations
- `+0x74`: Number of bones (duplicate for validation)
- `+0x88`: Render flags array
- `+0x104`: Number of lights
- `+0x114`: Number of cameras
- `+0x11c`: Number of particle emitters
- `+0x120`: Particle emitter data offset
- `+0x124`: Number of ribbon emitters
- `+0x128`: Ribbon emitter data offset
- `+0x130`: Model header pointer
- `+0x134`: Number of particle systems
- `+0x138`: Particle system data offset
- `+0x13c`: Number of ribbon systems
- `+0x140`: Ribbon system data offset

## Loading Process

### 1. CM2Model_Initialize (0x007103d0)
Entry point for model initialization:
```
CM2Model_Initialize(this, forceReload, initializeChildren)
```
- Checks if model is already loaded (`+0x10`)
- Calls `CM2Model_LoadInstanceData` if needed
- Recursively initializes child models via linked list at `+0x1dc`

### 2. CM2Model_LoadInstanceData (0x00710xxx - renamed from LoadPlayerModelData)
Main loading function that allocates and initializes all per-instance data:

1. **Allocates bone animation state** - One entry per bone in the model
2. **Allocates texture lookup tables** - Maps texture slots to actual textures
3. **Initializes bone matrices** - 4x4 transformation matrices for each bone
4. **Loads particle emitters** - Creates particle system instances
5. **Loads ribbon emitters** - Creates ribbon trail instances
6. **Sets up animation state** - Initializes default animations
7. **Processes queued commands** - Handles deferred texture/animation changes

### 3. Memory Allocation
Uses `M2_AllocateModelBuffer` (renamed from TextureResource_Load):
```c
buffer = M2_AllocateModelBuffer(size, sourceFile, lineNumber, flags, alignment)
```
This is a general-purpose allocator that optionally zero-initializes memory.

## Rendering Pipeline

### Scene Render Entry Point
`CM2SceneRenderDraw` (0x0070b360) - Main scene rendering function:

```c
CM2SceneRenderDraw(renderContext, viewMatrix, batchData, batchIndices, batchCount)
```

1. Calls `BeginRender()` to initialize D3D state
2. Sets identity transform matrix
3. Clears all 9 texture stages
4. Sets up vertex shader
5. Iterates through batch list, dispatching to appropriate draw function:
   - **Type 0**: `CM2Scene_DrawModelBatchProjected` - Projected/UI models
   - **Type 1**: `CM2Scene_DrawModelBatch` - Standard model batches
   - **Type 2**: `CM2Scene_DrawDoodadBatch` - Instanced doodads
   - **Type 3**: `CM2Scene_DrawRibbonEmitter` - Ribbon trails
   - **Type 4**: `CM2Scene_DrawParticleEmitter` - Particle systems
   - **Type 5**: `DrawCallback` - Custom render callbacks
6. Clears texture transforms
7. Calls `EndRender()`

### Batch Rendering Context
The render context (passed as `this`) contains extensive state at offsets `+0x3240` through `+0x3358`:
- Current/previous batch pointers for state change optimization
- Bone matrix upload state
- Pixel shader constant buffers
- Material state tracking

### Vertex Skinning (CPU-side)

WoW 1.12 performs vertex skinning on the CPU, not GPU. Key functions:

#### CM2Model_TransformVerticesSSE (0x0071a9e0)
Optimized SSE path for 16-byte aligned output buffers:
- Processes vertices in a tight loop
- Reads bone weights (4 bytes: weight0, weight1, weight2, weight3)
- Reads bone indices (4 bytes following weights)
- Blends up to 4 bone matrices per vertex
- Transforms position and normal
- Outputs 32 bytes per vertex (pos, normal, UV, color)

#### CM2Model_ApplySkinning (0x0071a460)
Fallback path for unaligned buffers:
- Same algorithm as SSE version
- Uses standard floating-point operations

#### Vertex Data Layout (Input)
Each source vertex is 0x30 (48) bytes:
- `+0x00`: Position (3 floats, 12 bytes)
- `+0x0C`: Bone weights/indices (8 bytes packed)
- `+0x14`: Normal (3 floats, 12 bytes)
- `+0x20`: UV coordinates (2 floats, 8 bytes)
- `+0x28`: Secondary UV (2 floats, 8 bytes)

#### Vertex Data Layout (Output)
Each transformed vertex is 0x20 (32) bytes:
- `+0x00`: Transformed position (3 floats)
- `+0x0C`: Transformed normal (3 floats)
- `+0x18`: UV coordinates (2 floats)

### Material System

`CM2Scene_SetMaterialRenderState` (0x0070c190) manages:
- Blend modes (opaque, alpha, additive, etc.)
- Depth write/test settings
- Backface culling
- Diffuse/ambient color from animation tracks
- Emissive color for glow effects

Blend mode values:
- 0: Opaque
- 1: Alpha key (alpha test)
- 2: Alpha blend
- 3: Additive
- 4: Additive alpha
- 5: Modulate
- 6: Modulate 2x

### Texture Binding

Textures are bound using slot indices:
- Slot 0x3F (63): Environment map / reflection
- Slot 0x40 (64): Primary diffuse texture

The model stores texture references in arrays at `+0xa4` which point to loaded CGxTexture objects.

## Bone Animation System

### PlayBoneAnimation (0x007121a0)
```c
PlayBoneAnimation(model, boneIndex, animationId, sequenceIndex, animData, speed, blendMode, queue)
```

- `boneIndex = -1` affects all bones
- Supports blending between animations
- Queue mode allows chaining animations
- Speed can be negative for reverse playback

### Animation State (per bone at +0x90)
Each bone's animation state is 0x118 bytes:
- `+0x98-0xC0`: Current animation parameters
- `+0xC4-0xEC`: Previous animation (for blending)
- `+0xF8`: Queued animation ID
- `+0x100`: Blend end time
- `+0x104`: Blend rate
- `+0x108`: Blend target weight
- `+0x110-0x114`: Animation queue linked list

## Particle and Ribbon Systems

### Particle Emitters
Managed via arrays at `+0x3cc` (pointers) and `+0x3c8` (state):
- Support spherical, planar, and spline emission
- Billboard or velocity-aligned rendering
- Color/alpha gradients over lifetime
- Gravity and drag physics

### Ribbon Emitters
Trail effects stored at `+0x3d4` (pointers) and `+0x3d0` (state):
- Spawn segments along movement path
- UV scrolling along ribbon length
- Fade out over time/distance

## Doodad Batching

`CM2Scene_DrawDoodadBatch` handles instanced rendering of world objects:
- Multiple instances share the same model data
- Per-instance transforms stored in batch buffer
- Bone matrices computed per-instance
- Supports hardware instancing where available

## Key Global Variables

- `CGxDeviceD3d__device` (0x00??????): D3D device singleton
- `g_skinningFunctionPtr`: Function pointer to active skinning routine
- `PTR_00c7b298` (0x00C7B298): Global resource manager (CM2Shared cache)
- `PTR_00c7cae0` (0x00C7CAE0): Render object list head (iterated by RenderObjectList)
- `PTR_00c7cad8` (0x00C7CAD8): Render object list next pointer offset
- `0x00CA7D6C`: World object list ( AllocateAndInitializeWorldObject inserts here)
- `0x00c7cb14`: Per-render-pass list array (used by CullObjectsToRenderList)
- `0x00c7cb18`: Per-render-pass list tail array

## Critical Discovery: Dual Object Lists

**The game uses TWO separate object lists:**

### 1. World Object List (0x00CA7D6C)
- `AllocateAndInitializeWorldObject` inserts here when initFlag=1
- This is a **scene graph** list for world state
- **NOT used for rendering directly**

### 2. Render Object List (0x00C7CAE0)
- `RenderObjectList` @ 0x006813D0 iterates THIS list
- `CullObjectsToRenderList` @ 0x00683AB0 processes this list
- Objects must be HERE to be rendered

**This is why markers don't render:** Objects are added to the world object list but never registered with the render object list.

## Render List Registration

Objects get into the render list through:

1. **CullObjectsToRenderList** - Called each frame to cull and sort objects
   - Reads from game object manager (param_1 + 0x38 + renderListIndex * 0xC)
   - Performs frustum culling via `IsSphereInFrustum` and `FrustumCullBoundingBox`
   - Inserts visible objects into sorted linked list via `InsertSortedLinkedList`
   - List head stored at `0x00c7cb18 + renderListIndex * 0xC`

2. **CM2Model_ManageRenderListNode** @ 0x00710B90
   - Adds/removes model from its scene's render list
   - Uses `+0x44` (prev) and `+0x48` (next) pointers on the model
   - Scene pointer at `+0x2C` must be valid

3. **addModelToLoadQueue** @ 0x0071D5A0
   - Called by `InitializeModelAttachmentNode` at the end of setup
   - Either queues model for async load or calls `CM2Model_LoadInstanceData` directly
   - Model load queue is at scene `+0x10`

## Object Manager Integration

Units get rendered through `SetupUnitDisplayHandler`:

1. `createModelAttachment(resource_mgr, model_path, 0)` → render context
2. `CGUnit_C__SetDisplayHandler(unit, render_ctx)` → attaches to unit
3. Unit is already registered with object manager
4. `CreateGameObject_WithProperties` called with unit's model → creates game object
5. Game object automatically picked up by `CullObjectsToRenderList` via object manager

**Key insight:** Units work because they're already in the object manager. Standalone world objects need separate registration.

## Critical Function: CM2Model_ManageRenderListNode

**Address:** 0x00710B90
**Convention:** `__thiscall` (ECX = render context, stack: enable)

This function adds/removes a model from its scene's render list:

```c
void CM2Model_ManageRenderListNode(void *renderContext, int enable) {
    if (enable == 0) {
        // Remove from list: unlink +0x44 and +0x48
    } else {
        // Add to list: insert at scene+0x20
        // Scene pointer read from renderContext+0x2C
    }
}
```

**CRITICAL:** After `CM2Model_CreateForModelObject`, must call:
```zig
CM2Model_ManageRenderListNode(render_ctx, 1)
```

Without this call, the model exists in the world object list but is never rendered because it's not in the scene's render list.

## Game Object List (PTR_00C7CAEC)

**The primary render path for dynamic objects:**

- **List head:** `0x00C7CAEC`
- **Linked list offsets:** `+0x16C` (prev), `+0x170` (next)
- **Iterator:** `AllocateGameObject` @ 0x00683F80 (called each frame)

**How it works:**
1. `AllocateGameObject` iterates the list
2. For each object with model at `+0x88`:
   - Calculates distance from camera
   - Calls `CM2Model_ManageRenderListNode(obj+0x88, visible)`
   - Calls `SetRenderCallbacks` for lighting
   - Sets fade/transparency based on distance

**To add an object:**
```zig
// Insert at head (sentinel pattern)
obj[0x16C] = 0x00C7CAEC;  // prev = list head address
obj[0x170] = old_head;     // next = old list head
[0x00C7CAEC] = obj;        // new head = this object
```

**Object requirements:**
- `+0x88`: Model/render context pointer
- `+0x5C-0x68`: Position (XYZ) for distance calculation
- `+0x8`: Visibility flags (0x8000 = visible)
- `+0x174/+0x178`: Optional manager callback slots used by `AllocateGameObject`

### Critical safety note (2026-02-27)

`AllocateGameObject` (`0x00683F80`) contains an indirect callback call:

- if `obj+0x174 != 0`, engine executes `call [obj+0x174]` with context from `+0x178`.

If custom-inserted objects (manual list insertion path) carry garbage at `+0x174`, this causes immediate crash (jump to invalid address).

**Mitigation for manual insertion path:**
- Set `obj+0x174 = 0`
- Set `obj+0x178 = 0`
before linking object into `PTR_00C7CAEC`.

### List pointer tagging note

Manager list pointers may be low-bit tagged (`ptr | 1`, e.g. `...E9`).
Always clear tag bits before dereferencing list links during unlink or traversal (`ptr & ~1`).

## Function Renames Applied

| Old Name | New Name | Address |
|----------|----------|---------|
| TextureResource_Load | M2_AllocateModelBuffer | - |
| LoadPlayerModelData | CM2Model_LoadInstanceData | - |
| optimizedBoneTransform | CM2Model_TransformVerticesSSE | 0x0071a9e0 |
| applyBoneTransforms | CM2Model_ApplySkinning | 0x0071a460 |
| calculateBoneMatrices | CM2Model_ApplySkinningUnaligned | 0x0071a720 |
| DrawBatch | CM2Scene_DrawModelBatch | 0x0070cf70 |
| DrawBatchProj | CM2Scene_DrawModelBatchProjected | 0x0070cb30 |
| DrawBatchDoodad | CM2Scene_DrawDoodadBatch | 0x0070d330 |
| DrawParticle | CM2Scene_DrawParticleEmitter | - |
| DrawRibbon | CM2Scene_DrawRibbonEmitter | - |
| SetupRendering | CM2Scene_SetupRenderState | - |
| RenderMesh | CM2Model_RenderSkinnedMesh | 0x00719ac0 |
| BuildVertexBuffer | CM2Shared_BuildSkinnedVertexBuffer | 0x0071dc80 |
| executeSceneRenderPass | CM2Scene_ExecuteRenderPass | 0x00708900 |
| InitializeModelHierarchy | CM2Model_InitializeHierarchy | 0x00710560 |
| validateAndFixupBoneArray | CM2Model_ValidateBoneArray | 0x0071e9d0 |
| SetMaterialRenderState | CM2Scene_SetMaterialRenderState | 0x0070c190 |

## Rendering Flow Summary

```
Game Loop
    |
    v
CM2Scene_ExecuteRenderPass
    |
    v
CM2SceneRenderDraw
    |
    +---> Check hardware shader support (flag bit 8)
    |         |
    |         +---> If supported: initPixelShaderDispatcher4/2()
    |                             Load Model2.bls vertex shader
    |
    +---> For each batch:
    |         |
    |         +---> Type 0/1: CM2Scene_DrawModelBatch[Projected]
    |         |         |
    |         |         +---> CM2Scene_SetupRenderState
    |         |         +---> CM2Scene_SetMaterialRenderState
    |         |         +---> [GPU Path] Upload bone matrices to shader constants
    |         |         |               RenderVertexBuffer with shader
    |         |         +---> [CPU Path] CM2Model_TransformVerticesSSE
    |         |                          DrawPrimitive (pre-transformed)
    |         |
    |         +---> Type 2: CM2Scene_DrawDoodadBatch
    |         |         |
    |         |         +---> [GPU Path] Upload bone matrices per instance
    |         |         |               CM2Shared_BuildSkinnedVertexBuffer
    |         |         +---> [CPU Path] g_skinningFunctionPtr per instance
    |         |                          DrawPrimitive (pre-transformed)
    |         |
    |         +---> Type 3: CM2Scene_DrawRibbonEmitter
    |         +---> Type 4: CM2Scene_DrawParticleEmitter
    |
    v
EndRender
```

## Vertex Skinning Paths

The WoW 1.12 client supports **TWO vertex skinning paths**:

### 1. GPU Vertex Shader Skinning (Hardware Path)
Enabled when:
- Hardware supports vertex shaders (checked via `UpdateLightingOffset() + 0x94`)
- The `M2UseShaders` console variable is enabled
- Flag bit 8 is set in the renderer context at `*(renderer + 0x44) + 4`

When enabled:
- Loads vertex shader from `"shaders\vertex\Model2.bls"`
- Bone matrices are uploaded to shader constants (offsets +0x70 through +0xac in render context)
- `initPixelShaderDispatcher4()` and `initPixelShaderDispatcher2()` configure the shader pipeline
- Vertex transformation happens on the GPU

Evidence: String `"skin models using vertex shaders"` at 0x0082e68c describes this feature.

### 2. CPU Vertex Skinning (Software Fallback)
Used when hardware shaders are unavailable or disabled:

**Function pointer**: `g_skinningFunctionPtr` (0x00cf04c8) is set during initialization:
- Default: `CM2Model_ApplySkinningUnaligned` (basic FPU path)
- SSE2 capable: `CM2Model_TransformVerticesSSE` (SIMD optimized)

The CPU path:
- Reads bone weights (4 bytes) and indices (4 bytes) per vertex
- Blends up to 4 bone matrices per vertex
- Outputs transformed position, normal, and UVs
- 32 bytes output per vertex

### Path Selection in Drawing Functions

**CM2Scene_DrawDoodadBatch**:
```
if (renderContext[0x32f0] == 0) {
    // CPU path: call g_skinningFunctionPtr for each instance
} else {
    // GPU path: upload bone matrices to shader constants
}
```

**CM2Scene_DrawModelBatchProjected**:
```
if (renderContext[0xcbc] != 0) {  // flag bit 8
    // GPU path: bone matrices to constants, use vertex shader
} else {
    // CPU path: software transform
}
```

### Console Variables
- `M2UseShaders` - Enable/disable GPU vertex shader skinning
- `M2UsePixelShaders` - Related pixel shader features
- `M2UseThreads` - Multi-threaded model processing
