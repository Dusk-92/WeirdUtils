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
| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| +0x10 | model_data_ptr | void* | NULL check for early bail |
| +0x2C | ptr_at_2c | void* | -> model header? |
| +0x30 | animation_context_ptr | void* | +0x0C=timestamp, +0x10=sync_value |
| +0x40 | transform_sync_value | int | Compared with anim_ctx+0x10 |
| +0x80 | unknown_0x80 | uint | Bone runtime state array base |
| +0x1CC | field_0x1cc | int* | Emitter/particle data? |

### Bone Definition (0x6c = 108 bytes per bone in model)
From `model+0x38` array. Contains:
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
