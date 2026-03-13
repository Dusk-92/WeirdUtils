# transformMatrix4x4 (0x714260) -- Research Notes

## Function Overview

- **Address**: 0x714260
- **Size**: 17703 bytes (0x4527)
- **Convention**: `__thiscall(ECX=SceneObject*, stack: Matrix4x4*, Matrix4x4*, Matrix4x4*, Matrix4x4*)`
- **Returns**: void
- **Epilogue**: `RET 0x10` (4 stack params, normal exit) and `RET 0x4` (early exit path)
- **Recursive**: calls itself at 0x0071875c for child scene objects

## Calling Convention Evidence

```
PROLOGUE:
  0x00714260  PUSH EBP
  0x00714261  MOV EBP,ESP
  0x00714263  SUB ESP,0x19c      ; 412 bytes of locals
  0x00714269  PUSH EBX
  0x0071426a  MOV EBX,ECX        ; this = ECX (thiscall)
```

Stack frame: 0x19c (412) bytes of locals. Massive function.

## Callers

| Address | Function | Notes |
|---------|----------|-------|
| 0x707662 | processLinkedObjectList (0x707600) | |
| 0x7077b6 | renderFrame (0x707680) | |
| 0x707824 | renderFrame (0x707680) | Second call in same function |
| 0x714069 | updateAnimationTransform (0x714000) | |
| 0x714158 | updateAnimationTransform (0x714000) | |
| 0x71417e | updateAnimationTransform (0x714000) | |
| 0x7191b2 | renderSceneNode (0x718960) | |
| 0x71875c | transformMatrix4x4 (0x714260) | Recursive self-call |

## Internal Calls

| Address | Function | Count | Purpose |
|---------|----------|-------|---------|
| 0x713d50 | findInterpolationIndices | 58 | Core animation interpolation index lookup |
| 0x713ea0 | interpolateAnimationKeyframes | 2 | Full keyframe interpolation |
| 0x71af20 | getInterpolatedFloat | 4 | Single float interpolation |
| 0x71aff0 | getIndexOffset | 12 | Animation index calculation |
| 0x71b010 | setShortValue | 12 | Write short values |
| 0x74a7c0 | initParticlePixelShaderGeneration | 3 | Particle system setup |
| 0x74b6b5 | initPixelShaderDispatcher5 | 1 | Pixel shader setup |
| 0x7b5e60 | TransformParticleVelocities | 1 | Particle velocity transforms |
| 0x7b5f60 | IsParticleBufferEmpty | 1 | Check particle buffer state |
| 0x7b7bc0 | TransformParticleVectors | 1 | Particle vector transforms |
| 0x7bd820 | calculateScaledInverseMatrix | 1 | Inverse matrix for billboarding? |
| 0x7bdca0 | scaleMatrix3x3ByVector | 2 | Scale 3x3 portion of matrix |
| 0x7bdc40 | ApplyTranslationMatrix | 5 | Apply translation to matrix |
| 0x7bddb0 | rotateMatrixByQuaternion | 1 | Quaternion rotation |
| 0x4549f0 | emptyFunction | 10 | No-op (likely stripped debug/assert) |
| 0x409aef | validateMemoryOperation | 1 | Memory validation |
| 0x40a2b0 | __ftol | 4 | Float-to-long conversion |

## High-Level Structure

### Entry Checks (lines 110-111)
```c
if (this->model_data_ptr != NULL &&
    this->transform_sync_value != *(this->animation_context_ptr + 0x10))
```
Bails immediately if no model data or transform is already up to date (sync value matches).

### Global Sequence Processing (lines 137-149)
Iterates global sequence array at `model+0x130`, computes per-sequence time offsets using
`animation_context_ptr+0xC` (current timestamp) modulo sequence duration.

### Identity Matrix Init (lines 163-194)
Sets up two identity matrices: `local_74` (4x4) and a second 3x4 matrix in `local_e8..local_ac`.

### Main Bone Loop (lines 203-2204)
```c
do {
    pMVar23 = param_3 * 0x6c + *(local_18 + 0x38);  // bone def from model
    puVar20 = param_3 * 0x118 + this->unknown_0x80;  // bone runtime state
    ...
    param_3++;
} while (param_3 < *(local_18 + 0x34));  // bone count
```

Each bone is 0x6c (108) bytes in the model definition and 0x118 (280) bytes in runtime state.

Per-bone processing:
1. **Parent bone inheritance** (lines 210-268): Copy transform from parent bone if parent index != -1
2. **Animation time computation** (lines 230-267): Handle looping vs clamped animations, compute current keyframe position
3. **Blend weight (crossfade)** (lines 334-367): Hermite interpolation for animation blending
4. **Bone flags processing** (lines 368-478): Billboard types (flags & 7):
   - 0x2: Cylindrical billboard (normalize rotation columns)
   - 0x4: Spherical billboard (inherit parent rotation)
   - 0x6: Full billboard (copy parent rotation directly)
   - Flag 0x1: Fixed translation vs pivot-relative
5. **Scale interpolation** (lines 522-572): `scaleMatrix3x3ByVector` with interpolated scale
6. **Translation interpolation** (lines 583-628): Add interpolated translation to pivot
7. **Rotation interpolation** (quaternion, lines 630+): `rotateMatrixByQuaternion`
8. **Matrix composition** (lines 1050+): `ApplyTranslationMatrix` to build final bone matrix
9. **Write to output** (lines 480-492): Copy final matrix to bone transform array at `this->transform_vec2_x`

### Attachment Processing (lines 2206-2257)
After all bones, iterates attached child objects:
- Extracts parent bone matrix
- Applies attachment offset translation
- **Recursive call** to transformMatrix4x4 for each child SceneObject

### Sync Value Update (line 2259)
```c
this->transform_sync_value = *(this->animation_context_ptr + 0x10);
```
Marks transform as up to date.

## Key Data Structures

### SceneObject (this pointer)

**WARNING**: Ghidra decompiler swaps +0x2C and +0x30 labels. Assembly is authoritative.

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| +0x10 | model_data_ptr | void* | NULL check for early bail |
| +0x2C | animation_context_ptr | void* | +0x0C=timestamp, +0x10=sync_value |
| +0x30 | model_container_ptr | void* | +0x130 = M2 model header |
| +0x40 | transform_sync_value | int | Compared with *(anim_ctx+0x10) |
| +0x80 | unknown_0x80 | uint | Bone runtime state array base |
| +0x1CC | field_0x1cc | int* | Emitter/particle context |

Assembly proof (0x714277-0x714293):
```asm
MOV EAX, [EBX + 0x2c]     ; EAX = animation_context_ptr
MOV ECX, [EBX + 0x40]     ; ECX = sync_value
CMP ECX, [EAX + 0x10]     ; sync check: this+0x40 vs *(this+0x2C)+0x10
...
MOV EDX, [EBX + 0x30]     ; EDX = model_container_ptr
MOV EDI, [EDX + 0x130]    ; EDI = M2 model header
```

### Model Container (at *(this+0x30))
| Offset | Field | Notes |
|--------|-------|-------|
| +0x14 | global sequence count | Loop bound for GS processing |
| +0x18 | global sequence durations array | |
| +0x130 | M2 model header pointer | **This is the actual model** |

**Pointer chain to bone count**: `*(*(*(this+0x30) + 0x130) + 0x34)`

### Bone Definition (0x6c = 108 bytes per bone in model)
From `model+0x38` array (where model = `*(*(this+0x2C) + 0x130)`). Contains:
- Flags, parent bone index, billboard type
- Keyframe data pointers for translation, rotation, scale
- Pivot point (Vec3)

### Bone Runtime State (0x118 = 280 bytes per bone)
From `this->unknown_0x80` array. Contains:
- Current interpolation indices and weights
- Interpolated translation, rotation, scale values
- Blend state for animation crossfading
- Final composed 4x4 transform matrix

## Key Observations

1. **Performance critical**: Called per-frame for every visible M2 model with animated bones
2. **58 calls to findInterpolationIndices**: This is the hot inner function
3. **Recursive for attachments**: Child objects (weapons, shoulders, etc.) recurse through this same function
4. **Two animation blend sources**: Primary animation + blend target with crossfade weight at puVar20[0x43]
5. **Billboard support**: Flags-based billboard types for UI/particle-facing bones

## Inner Function Analysis (decompiled 2026-03-12)

### findInterpolationIndices (0x713d50) — 334 bytes, 58 calls
**Signature**: `__thiscall(ECX=SceneObject*, stack: searchValue, trackIndex, AnimationData*, outputIndices*)`
**RET 0x10**

Three-tier search strategy with temporal coherence:
1. **Forward linear scan** (hot path): If `searchValue - lastTimestamp < 500`, scan forward from cached position. This is the common case during sequential animation playback — typically 0-4 iterations.
2. **Backward linear scan**: If delta is negative (unsigned wrap > 0xFFFFFF0C), scan backward.
3. **Binary search** (fallback): Standard bisection on timestamp array.

Output: `outputIndices[0]` = lower keyframe index, `[1]` = upper keyframe index, `[2]` = interpolation factor (float stored as uint bits).

The cached index at `outputIndices[0]` is reused across calls — exploits the fact that animation time advances monotonically between frames.

**Optimization potential**: Limited — the linear scan hot path is already tight (1-4 iterations for most bones). SSE4-wide timestamp comparison might help for binary search fallback, but that path is rarely hit during normal playback.

### interpolateAnimationKeyframes (0x713ea0) — 337 bytes, 2 calls
**Signature**: `__fastcall(ECX=animObj, EDX=animState, stack: keyframeData*, outputBuffer*)`
**RET 0x8**

Calls findInterpolationIndices, then does 4-component lerp (vec4/quaternion). If crossfade is active (blend weight != 0 and timeIndex == -1), does a secondary findInterpolationIndices + lerp + blend.

Keyframes are 16 bytes (4 floats). Interpolation: `result[i] = a[i] + (b[i] - a[i]) * t`.

**Optimization**: The 4-component lerp is a textbook SSE target — one load, one sub, one mul, one add replaces 4 scalar x87 operations.

### getInterpolatedFloat (0x71af20) — 199 bytes, 4 calls
**Signature**: `__fastcall(ECX=animObj, EDX=animState, stack: keyframeData*, outputBuffer*)`
**RET 0x8**

Same pattern as interpolateAnimationKeyframes but for scalar (single float) tracks. Also supports crossfade blending.

### getIndexOffset (0x71aff0) — 16 bytes, 12 calls
Trivial: `return *(this+4) + param_1 * 2`. Returns pointer to short value in timestamp index array.

### setShortValue (0x71b010) — 18 bytes, 12 calls
Trivial: `*(short*)this = *(short*)param_1`. Copies a 16-bit value.

### scaleMatrix3x3ByVector (0x7bdca0) — 82 bytes, 2 calls
**Signature**: `__thiscall(ECX=matrix, stack: scaleVec3*)`
Scales each row of the 3x3 rotation portion of a 4x4 matrix by the corresponding scale component:
```
row0 *= scale.x  (3 muls)
row1 *= scale.y  (3 muls)
row2 *= scale.z  (3 muls)
```
Uses x87 FPU. **SSE candidate**: 3 shuffled multiplies instead of 9 scalar.

### ApplyTranslationMatrix (0x7bdc40) — 90 bytes, 5 calls
**Signature**: `__thiscall(ECX=matrix, stack: translationVec3*)`
Applies translation through the rotation matrix:
```
mat[3][0] += dot(mat[0], translation)
mat[3][1] += dot(mat[1], translation)
mat[3][2] += dot(mat[2], translation)
```
Uses x87 FPU. **SSE candidate**: 3 dot products → SSE dp_ps or manual mul+hadd.

### rotateMatrixByQuaternion (0x7bddb0) — 333 bytes, 1 call
**Signature**: `__thiscall(ECX=matrix, stack: quaternion*)`
Converts quaternion to 3x3 rotation matrix, then calls `multiplyMatrix4x4_SSE_Optimized` (game already has SSE matrix multiply!). The quaternion→matrix conversion uses x87 but the final multiply is SSE.

### calculateScaledInverseMatrix (0x7bd820) — 347 bytes, 1 call
Used for billboarding. Transposes the 3x3 rotation, scales by 1/scale², applies inverse translation.

## Optimization Strategy

### What we know
- The game already uses SSE for matrix multiplication (multiplyMatrix4x4_SSE_Optimized)
- All other math (scale, translate, interpolate) uses x87 FPU
- findInterpolationIndices has good temporal coherence — hot path is already fast
- The 58 findInterpolationIndices calls are spread across translation, rotation, scale tracks for each bone

### Priority targets (by impact)
1. **Profile first** — need real data on call frequency, early-exit ratio, cycles per call, bone counts
2. **LOD-based culling** — skip entire transformMatrix4x4 for distant/tiny models (biggest potential win)
3. **SSE interpolateAnimationKeyframes** — replace 4-component lerp with SSE (called per bone for rotation)
4. **SSE scaleMatrix3x3ByVector / ApplyTranslationMatrix** — replace x87 with SSE
5. **Batch findInterpolationIndices** — process multiple tracks per bone in one call to amortize function overhead

### Implementation plan
- Phase 1: Profiling hook on transformMatrix4x4 (DONE — in transform44.zig)
- Phase 2: Analyze profiling data, identify hottest path
- Phase 3: Implement targeted SSE replacements or LOD culling

---

## SetWeatherType (0x67baf0) — Weather Control

- **Convention**: `__thiscall(ECX=weatherObj, stack: type(int), intensity(float), smoothFade(bool))`
- **RET 0x0C** (3 stack params) — assembly-verified
- **Global weather object**: `*(u32*)0x00C6326C` — all 5 callers load ECX from this address
- **Valid types**: 0=clear, 1=rain, 2=snow, 3=sandstorm (clamped: rejects <0 or >=4)
- **Intensity**: float 0.0-1.0, stored at weatherObj+0x?? (controls particle density)
- **smoothFade**: bool at stack+0x10, stored at weatherObj+0x25
  - `1` = gradual fade transition (slow)
  - `0` = abrupt/immediate change
  - Packet handler uses `SETZ AL` — sends 1 when a condition is zero (smooth by default from server)
  - Debug commands (SetModeA/B/C/D) all pass `1` (smooth)
  - Our Lua func uses `0` (abrupt) for instant testing
- **Lua API**: `SetWeatherOverride(type, intensity)` — registered when transform44 is enabled
- **blit_hub (0x5a4f60)**: also profiled in this module — 83-byte pixel transfer dispatcher, `__fastcall`, RET 0x18

---

## GxDevice Wrapper Functions — Calling Conventions (assembly-verified)

All route through the GxDevice global at `0xC0ED38`. Used for RTQ batching optimization.

### BeginRender (0x589f40, 11 bytes)
```asm
MOV ECX, [0xC0ED38]    ; load GxDevice
JMP 0x593950            ; tail-call to vtable method
```
Thiscall thunk, no caller params. Call as `fn() callconv(.c) void`.

### EndRender (0x589f50, 11 bytes)
```asm
MOV ECX, [0xC0ED38]
JMP 0x593a50
```
Same pattern as BeginRender.

### SetRenderState (0x589e60, 27 bytes)
```asm
CMP ECX, 0x46          ; bounds check: stateId < 0x46
JL valid
PUSH 0x57              ; error code
CALL 0x64e850          ; error handler
RET
valid:
PUSH EDX               ; value
PUSH ECX               ; stateId
MOV ECX, [0xC0ED38]    ; GxDevice
CALL 0x593710
RET
```
**Convention**: `__fastcall(ECX=stateId, EDX=value)`, plain `RET`.

### SetTexture (0x589e80, 14 bytes)
```asm
PUSH EDX               ; texturePtr
PUSH ECX               ; stage
MOV ECX, [0xC0ED38]
CALL 0x593840
RET
```
**Convention**: `__fastcall(ECX=stage, EDX=texturePtr)`, plain `RET`.

### InitializeRenderingPipeline (0x58a2a0, 54 bytes)
```asm
PUSH EBP
MOV EBP, ESP
; Re-pushes 9 of 11 stack params (skips EBP+0x1C and EBP+0x20)
MOV EAX, [EBP+0x30]   ; push params in reverse
PUSH EAX               ; ... (9 pushes total)
...
MOV EAX, [EBP+0x08]
PUSH EAX
MOV [0xC0ED2C], ECX    ; store vertexCount to global
CALL 0x58a3d0          ; inner function (9 stack params)
POP EBP
RET 0x2c               ; clean 44 bytes = 11 stack params
```
**Convention**: `__fastcall(ECX=vertexCount, EDX=verticesPtr, 11 stack params)`, `RET 0x2c`.

**Critical**: Stores ECX (vertexCount) to global `[0xC0ED2C]` — RenderVertexBuffer reads this and bails if zero.

**Full param mapping** (from decompiled RTQ call site):
| # | Location | Original value | Meaning |
|---|----------|----------------|---------|
| 1 | ECX | 4 | vertex count |
| 2 | EDX | vertices | xyz data ptr (stride 0x0C) |
| 3 | [EBP+08] | 0x0C | vertex stride |
| 4 | [EBP+0C] | &g_defaultTexCoord | constant at 0xCF4CF4 |
| 5 | [EBP+10] | 0 | |
| 6 | [EBP+14] | additionalData | secondary vertex data |
| 7 | [EBP+18] | dataStride | secondary stride |
| 8 | [EBP+1C] | 0 | (skipped in forwarding) |
| 9 | [EBP+20] | 0 | (skipped in forwarding) |
| 10 | [EBP+24] | textureCoords | UV data ptr |
| 11 | [EBP+28] | 8 | UV stride |
| 12 | [EBP+2C] | 0 | |
| 13 | [EBP+30] | 0 | |

### RenderVertexBuffer (0x58a2e0, 82 bytes)
```asm
PUSH EBP
MOV EBP, ESP
SUB ESP, 0x10
MOV EAX, [0xC0ED2C]   ; read vertex count global (from InitRenderPipeline)
TEST EAX, EAX
PUSH ESI
PUSH EDI
MOV ESI, EDX           ; save vertCount
MOV EDI, ECX           ; save primType
JZ skip                ; bail if global == 0
MOV EDX, [EBP+0x08]   ; indicesPtr from stack
MOV ECX, ESI           ; ECX = vertCount
CALL 0x58a750          ; submit geometry
; ... builds local struct, calls 0x58a830 ...
skip:
POP EDI
POP ESI
MOV ESP, EBP
POP EBP
RET 0x4                ; clean 4 bytes = 1 stack param
```
**Convention**: `__fastcall(ECX=primType, EDX=vertCount, stack: indicesPtr)`, `RET 0x4`.

**Note**: vertCount stored as `u16` internally (MOV WORD PTR), so max 65535 vertices per call. For 256 batched quads = 1024 verts, well within limit.

### EmptyRenderFunction (0x58a340, 1 byte)
Literal `RET`. No-op.

### Key Globals
| Address | Name | Notes |
|---------|------|-------|
| 0xC0ED38 | GxDevice ptr | All wrappers load ECX from here |
| 0xC0ED2C | Vertex count | Set by InitRenderPipeline, read by RenderVertexBuffer |
| 0xCF4CF4 | g_defaultTexCoord | Constant UV default |
| 0x878CDC | g_quadVertexIndices | {0,1,2,0,2,3} for single quad |

### RTQ Batching Strategy
- Sort items by (texture, renderState, secondaryTexture)
- Groups with no additionalData: concatenate xyz/uv into contiguous buffers, single InitRenderPipeline + RenderVertexBuffer call
- Groups with additionalData: per-item draw calls through wrappers
- Reduces draw calls from N to num_texture_groups (typically 5-20x reduction)
- Sort-only (Approach A) provided 0% improvement — confirms bottleneck is draw call count, not texture switching
