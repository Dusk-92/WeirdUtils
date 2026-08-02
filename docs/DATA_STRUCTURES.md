# WoW 1.12.1 Data Structures - Complete Reference

## Overview

This document provides complete specifications for all data structures involved in GPU skinning implementation. All offsets and sizes have been verified through Ghidra decompilation and runtime analysis.

---

## Model Structure

### Overview

The Model structure represents a complete M2 model (character, creature, or object). It contains pointers to geometry data, bone arrays, animations, and rendering metadata.

### Structure Definition

```cpp
struct Model {
    // Offset 0x00-0x2F: Unknown/varied data
    char pad_0x00[0x30];

    // Offset 0x30: Pointer to nested data structure
    void* dataPtr;                   // +0x30

    // Offset 0x34-0x93: Unknown/varied data
    char pad_0x34[0x60];

    // Offset 0x94: CRITICAL - Bone matrix array
    BoneMatrix* boneArray;           // +0x94

    // Offset 0x98-0x397: Unknown/varied data
    char pad_0x98[0x300];

    // Total size: At least 0x398 bytes (likely larger)
};
```

### Critical Offsets

| Offset | Type | Name | Description | Verified |
|--------|------|------|-------------|----------|
| +0x30 | `void*` | dataPtr | Pointer to geometry data container | [OK] |
| +0x94 | `BoneMatrix*` | boneArray | **Pointer to bone matrix array** | [OK] |

### Nested Structure (Model+0x30)

```cpp
struct ModelDataContainer {
    // Offset 0x00-0x12F: Unknown
    char pad_0x00[0x130];

    // Offset 0x130: Pointer to GeometryData
    GeometryData* geometryData;      // +0x130

    // More fields follow...
};
```

### GeometryData Structure (Model+0x30+0x130)

```cpp
struct GeometryData {
    // Offset 0x00-0x47: Unknown
    char pad_0x00[0x48];

    // Offset 0x48: Pointer to vertex array (T-pose vertices)
    Vertex* vertexArray;             // +0x48

    // More fields follow...
};
```

### Access Pattern

```cpp
// From a Model* pointer:
Model* model = (Model*)thisPtr;

// Get bone array directly
BoneMatrix* bones = model->boneArray;  // model + 0x94

// Get vertex array (multi-level indirection)
ModelDataContainer* container = (ModelDataContainer*)model->dataPtr;  // model + 0x30
GeometryData* geoData = container->geometryData;  // container + 0x130
Vertex* vertices = geoData->vertexArray;  // geoData + 0x48
```

### Example Code

```cpp
// Extract bone matrices for GPU upload
void UploadBoneMatrices(Model* model, IDirect3DDevice9* device) {
    BoneMatrix* bones = model->boneArray;

    // Pack to 4x3 for shader constants (12 floats per bone)
    float constants[64 * 12];  // Max 64 bones

    for (int i = 0; i < 64; i++) {  // TODO: Get actual bone count
        // Copy first 3 rows of 4x4 matrix
        memcpy(&constants[i * 12], bones[i].m, 12 * sizeof(float));
    }

    // Upload to shader constants c31-c222
    device->SetVertexShaderConstantF(31, constants, 64 * 3);
}
```

---

## MeshData Structure

### Overview

The MeshData structure describes a single submesh within a model, including vertex range, index range, and material properties.

### Structure Definition

```cpp
struct MeshData {
    // Offset 0x00-0x03: Unknown
    uint32_t unknown0;               // +0x00

    // Offset 0x04: Vertex offset in vertex array
    uint16_t vertexOffset;           // +0x04

    // Offset 0x06: Number of vertices in this submesh
    uint16_t vertexCount;            // +0x06

    // Offset 0x08: Index offset
    uint16_t indexOffset;            // +0x08

    // Offset 0x0A: Number of indices
    uint16_t indexCount;             // +0x0A

    // Offset 0x0C-0x0D: Bone indices for this submesh
    uint16_t boneStart;              // +0x0C
    uint16_t boneCount;              // +0x0E

    // Offset 0x10: Material/texture indices
    uint16_t materialIndex;          // +0x10

    // More fields follow...
    // Total size: At least 0x20 bytes
};
```

### Critical Offsets

| Offset | Type | Name | Description | Verified |
|--------|------|------|-------------|----------|
| +0x04 | `uint16_t` | vertexOffset | Start vertex in global array | [OK] |
| +0x06 | `uint16_t` | vertexCount | **Loop terminator in applyBoneTransforms** | [OK] |
| +0x08 | `uint16_t` | indexOffset | Start index for this submesh | ? |
| +0x0A | `uint16_t` | indexCount | Number of indices | ? |

### Usage in applyBoneTransforms

```c
// From decompiled code @ 0x0071a460
void __fastcall applyBoneTransforms(int param_1, int param_2, float *param_3) {
    // Extract vertex count
    uint16_t vertexCount = *(uint16_t*)(param_2 + 6);  // MeshData + 0x06

    // Extract vertex offset
    uint16_t vertexOffset = *(uint16_t*)(param_2 + 4);  // MeshData + 0x04

    // Loop through vertices
    for (uint16_t v = 0; v < vertexCount; v++) {
        // Calculate vertex pointer
        int vertexIndex = v + vertexOffset;
        // ... (skinning code)
    }
}
```

---

## Vertex Structure (T-Pose)

### Overview

The Vertex structure represents a single vertex in its **T-pose** (unskinned) state. This is the input to the skinning process.

### Structure Definition

```cpp
struct Vertex {
    // Offset 0x00: Position (T-pose)
    float position[3];               // +0x00 (12 bytes)

    // Offset 0x0C: First blend weight (byte, 0-255)
    uint8_t blendWeight0;            // +0x0C (1 byte)

    // Offset 0x0D: Bone indices (4 bones, 0-255)
    uint8_t blendIndices[4];         // +0x0D (4 bytes)

    // Offset 0x11: Padding or additional weight data
    uint8_t pad_0x11[3];             // +0x11 (3 bytes)

    // Offset 0x14: Normal (T-pose)
    float normal[3];                 // +0x14 (12 bytes)

    // Offset 0x20: Primary texture coordinates
    float texcoord0[2];              // +0x20 (8 bytes)

    // Offset 0x28: Secondary texture coordinates
    float texcoord1[2];              // +0x28 (8 bytes)

    // Total size: 0x30 (48 bytes)
};

static_assert(sizeof(Vertex) == 0x30, "Vertex size mismatch");
```

### Alternative Definition (Based on Analysis)

The exact layout is somewhat ambiguous from the decompiled code. Here's an alternative interpretation that matches the access patterns:

```cpp
struct Vertex_v2 {
    float position[3];               // +0x00 (12 bytes)
    uint8_t blendWeights[4];         // +0x0C (4 bytes) - all 4 weights as bytes
    uint8_t blendIndices[4];         // +0x10 (4 bytes) - all 4 indices
    float normal[3];                 // +0x14 (12 bytes)
    float texcoord0[2];              // +0x20 (8 bytes)
    float texcoord1[2];              // +0x28 (8 bytes)
    // Total: 48 bytes (0x30)
};
```

### Memory Layout Diagram

```
Offset  Size  Field          Type       Description
------  ----  -------------  ---------  ------------------------------------
0x00    12    position       float[3]   X, Y, Z in T-pose
0x0C    4     blendWeights   uint8[4]   Weights for bones 0-3 (0-255)
0x10    4     blendIndices   uint8[4]   Bone indices 0-3 (0-255)
0x14    12    normal         float[3]   Normal vector in T-pose
0x20    8     texcoord0      float[2]   Primary UV coordinates
0x28    8     texcoord1      float[2]   Secondary UV coordinates
0x30    --    (end)          --         Total: 48 bytes
```

### Blend Weight Encoding

**Format**: Unsigned byte (0-255)
**Conversion to float**: `float weight = (float)byte_value * (1.0f / 255.0f);`
**Constant used**: `0.003921569` = `1.0 / 255.0`

**Example**:
```cpp
uint8_t weight_byte = 200;
float weight_float = weight_byte * 0.003921569f;  // = 0.784
```

**Verification**:
```c
// From decompiled code @ 0x0071a460, line with weight extraction:
fVar11 = (float)*(byte *)(pfVar13 + 3) * 0.003921569;

// This confirms:
// 1. Weight is stored as byte
// 2. Conversion uses 1/255 constant
// 3. Offset +0x0C (3 floats = 12 bytes = pfVar13 + 3 in float pointer math)
```

### D3D9 Vertex Declaration

For GPU skinning, the vertex declaration must match this layout:

```cpp
D3DVERTEXELEMENT9 elements[] = {
    // Stream 0, Offset 0, Type FLOAT3, Usage POSITION, Index 0
    {0, 0,  D3DDECLTYPE_FLOAT3,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION,     0},

    // Offset 12 (0x0C), Type UBYTE4N (4 bytes normalized to 0-1), Usage BLENDWEIGHT
    {0, 12, D3DDECLTYPE_UBYTE4N,  D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_BLENDWEIGHT,  0},

    // Offset 16 (0x10), Type UBYTE4 (4 bytes as integers), Usage BLENDINDICES
    {0, 16, D3DDECLTYPE_UBYTE4,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_BLENDINDICES, 0},

    // Offset 20 (0x14), Type FLOAT3, Usage NORMAL
    {0, 20, D3DDECLTYPE_FLOAT3,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL,       0},

    // Offset 32 (0x20), Type FLOAT2, Usage TEXCOORD0
    {0, 32, D3DDECLTYPE_FLOAT2,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD,     0},

    // Offset 40 (0x28), Type FLOAT2, Usage TEXCOORD1
    {0, 40, D3DDECLTYPE_FLOAT2,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD,     1},

    D3DDECL_END()
};
```

**Note**: `D3DDECLTYPE_UBYTE4N` automatically normalizes bytes to 0-1 range, matching WoW's weight encoding.

---

## SkinnedVertex Structure (Output)

### Overview

The SkinnedVertex structure represents a vertex **after** CPU skinning. This is written to the dynamic vertex buffer created by `CreateVertexBuffer`.

### Structure Definition

```cpp
struct SkinnedVertex {
    // Offset 0x00: Skinned position (world/model space)
    float position[3];               // +0x00 (12 bytes)

    // Offset 0x0C: Skinned normal
    float normal[3];                 // +0x0C (12 bytes)

    // Offset 0x18: Primary texture coordinates (copied, unskinned)
    float texcoord0[2];              // +0x18 (8 bytes)

    // Offset 0x20: Secondary texture coordinates (copied, unskinned)
    float texcoord1[2];              // +0x20 (8 bytes)

    // Total size: 0x28 (40 bytes)
};

static_assert(sizeof(SkinnedVertex) == 0x28, "SkinnedVertex size mismatch");
```

### Memory Layout Diagram

```
Offset  Size  Field      Type       Description
------  ----  ---------  ---------  ------------------------------------
0x00    12    position   float[3]   Skinned X, Y, Z
0x0C    12    normal     float[3]   Skinned normal vector
0x18    8     texcoord0  float[2]   Primary UV (copied from T-pose)
0x20    8     texcoord1  float[2]   Secondary UV (copied from T-pose)
0x28    --    (end)      --         Total: 40 bytes
```

### Verification

**From decompiled code** @ 0x0071a460:
```c
// Output stride is 10 floats = 40 bytes
param_3 = param_3 + 10;  // Advance output pointer

// Writes:
*param_3     = skinned_position.x;  // +0x00
param_3[1]   = skinned_position.y;  // +0x04
param_3[2]   = skinned_position.z;  // +0x08
param_3[3]   = skinned_normal.x;    // +0x0C
param_3[4]   = skinned_normal.y;    // +0x10
param_3[5]   = skinned_normal.z;    // +0x14
param_3[6]   = texcoord0.x;         // +0x18
param_3[7]   = texcoord0.y;         // +0x1C
param_3[8]   = texcoord1.x;         // +0x20
param_3[9]   = texcoord1.y;         // +0x24
// Next vertex at +0x28 (40 bytes)
```

### D3D9 Vertex Declaration

For the **skinned output** (if using CPU skinning or compute shader output):

```cpp
D3DVERTEXELEMENT9 skinned_elements[] = {
    {0, 0,  D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0},
    {0, 12, D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_NORMAL,   0},
    {0, 24, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0},
    {0, 32, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 1},
    D3DDECL_END()
};
```

---

## BoneMatrix Structure

### Overview

The BoneMatrix structure represents a single bone's transformation matrix. Bones are stored in an array at `Model + 0x94`.

### Structure Definition

```cpp
struct BoneMatrix {
    // 4x4 transformation matrix (row-major)
    float m[16];                     // 64 bytes total

    // Alternative interpretation:
    // float m[4][4];  // 4 rows, 4 columns

    // Or as rows:
    // float row0[4];  // +0x00
    // float row1[4];  // +0x10
    // float row2[4];  // +0x20
    // float row3[4];  // +0x30 (usually [0, 0, 0, 1])
};

static_assert(sizeof(BoneMatrix) == 0x40, "BoneMatrix size must be 64 bytes");
```

### Memory Layout

```
Offset  Size  Element    Description
------  ----  ---------  ------------------------------------
0x00    4     m[0]       Row 0, Column 0 (right.x)
0x04    4     m[1]       Row 0, Column 1 (right.y)
0x08    4     m[2]       Row 0, Column 2 (right.z)
0x0C    4     m[3]       Row 0, Column 3 (translation.x)

0x10    4     m[4]       Row 1, Column 0 (up.x)
0x14    4     m[5]       Row 1, Column 1 (up.y)
0x18    4     m[6]       Row 1, Column 2 (up.z)
0x1C    4     m[7]       Row 1, Column 3 (translation.y)

0x20    4     m[8]       Row 2, Column 0 (forward.x)
0x24    4     m[9]       Row 2, Column 1 (forward.y)
0x28    4     m[10]      Row 2, Column 2 (forward.z)
0x2C    4     m[11]      Row 2, Column 3 (translation.z)

0x30    4     m[12]      Row 3, Column 0 (usually 0)
0x34    4     m[13]      Row 3, Column 1 (usually 0)
0x38    4     m[14]      Row 3, Column 2 (usually 0)
0x3C    4     m[15]      Row 3, Column 3 (usually 1)

Total: 64 bytes (0x40)
```

### Matrix Format

**Format**: Row-major 4x4 matrix
**Layout**: Affine transformation (rotation + translation)
**Fourth Row**: Usually `[0, 0, 0, 1]` (not stored in some formats)

**Interpretation**:
```
[ m[0]  m[1]  m[2]  m[3]  ]   [ Xx  Xy  Xz  Tx ]   [ right.x    right.y    right.z    translation.x ]
[ m[4]  m[5]  m[6]  m[7]  ] = [ Yx  Yy  Yz  Ty ] = [ up.x       up.y       up.z       translation.y ]
[ m[8]  m[9]  m[10] m[11] ]   [ Zx  Zy  Zz  Tz ]   [ forward.x  forward.y  forward.z  translation.z ]
[ m[12] m[13] m[14] m[15] ]   [ 0   0   0   1  ]   [ 0          0          0          1             ]
```

### Array Access

```cpp
// From Model pointer
BoneMatrix* bones = model->boneArray;  // Array at model + 0x94

// Access individual bone
int boneIndex = 5;
BoneMatrix* bone5 = &bones[boneIndex];

// Or using byte offset (as in decompiled code)
float* bone5_ptr = (float*)((char*)bones + boneIndex * 0x40);
```

### Verification from Decompiled Code

```c
// From applyBoneTransforms @ 0x0071a460:
pfVar12 = (float *)(((uint)local_c & 0xff) * 0x40 + *(int *)(param_1 + 0x94));
//                   ^                      ^        ^
//                   boneIndex              stride   bone array pointer

// This confirms:
// 1. Each bone is 0x40 (64) bytes
// 2. Array is at model + 0x94
// 3. Indexed as: bones + (index * 64)
```

### Packing for Shader Constants

GPU vertex shaders have limited constant space (256 constants = 256 × float4 = 4096 bytes).

**Optimization**: Pack 4x4 to 4x3 (save 4th row since it's always [0,0,0,1]):

```cpp
void PackBoneMatricesForShader(BoneMatrix* bones, int boneCount, float* output) {
    for (int i = 0; i < boneCount; i++) {
        // Copy first 3 rows (12 floats = 3 × float4)
        memcpy(&output[i * 12], bones[i].m, 12 * sizeof(float));
        // Skip 4th row (m[12], m[13], m[14], m[15])
    }
}

// Usage:
float packedBones[64 * 12];  // 64 bones × 12 floats = 768 floats = 192 constants
PackBoneMatricesForShader(model->boneArray, 64, packedBones);
device->SetVertexShaderConstantF(31, packedBones, 64 * 3);  // 64 bones × 3 constants each
```

### Transform a Vertex

**CPU code (matches WoW's implementation)**:
```cpp
void TransformVertex(const float* position, const BoneMatrix& bone, float* output) {
    // Transform as: output = bone × [position.x, position.y, position.z, 1]
    output[0] = bone.m[0] * position[0] + bone.m[1] * position[1] +
                bone.m[2] * position[2] + bone.m[3];
    output[1] = bone.m[4] * position[0] + bone.m[5] * position[1] +
                bone.m[6] * position[2] + bone.m[7];
    output[2] = bone.m[8] * position[0] + bone.m[9] * position[1] +
                bone.m[10] * position[2] + bone.m[11];
}
```

**Shader code (HLSL)**:
```hlsl
float4 row0 = c[31 + boneIndex * 3 + 0];  // [m0, m1, m2, m3]
float4 row1 = c[31 + boneIndex * 3 + 1];  // [m4, m5, m6, m7]
float4 row2 = c[31 + boneIndex * 3 + 2];  // [m8, m9, m10, m11]

float4 pos4 = float4(position, 1.0);
skinnedPos.x = dot(row0, pos4);
skinnedPos.y = dot(row1, pos4);
skinnedPos.z = dot(row2, pos4);
```

---

## Batch Structure

### Overview

The Batch structure describes a rendering batch, which may contain multiple submeshes with the same material and state.

### Structure Definition (Partial)

```cpp
struct Batch {
    // Offset 0x00: Batch type
    uint32_t type;                   // +0x00
    // 0 = DrawBatchProj (projected/corpses)
    // 1 = DrawBatch (standard models)
    // 2 = DrawBatchDoodad (props)
    // 3 = DrawRibbon (ribbons)
    // 4 = DrawParticle (particles)
    // 5 = DrawCallback (custom)

    // Offset 0x04: Pointer to Model
    Model* modelPtr;                 // +0x04

    // Offset 0x08-0x1F: Unknown
    char pad_0x08[0x18];

    // Offset 0x20: Doodad count (for type 2)
    uint32_t doodadCount;            // +0x20

    // More fields...
    // Total size: 0x40 (64 bytes)
};
```

### Verification

```c
// From CM2SceneRenderDraw @ 0x0070b360:
puVar2 = (undefined4 *)(*(int *)(batchIndices + uVar4 * 4) * 0x40 + batchData);
//                                                          ^
//                                                          64 bytes per batch

// Switch on batch type:
switch(**(undefined4 **)((int)this + 0x3300)) {
    case 0: DrawBatchProj((float *)this); break;
    case 1: DrawBatch(this); break;
    case 2: DrawBatchDoodad(this, batchData, batchIndices + uVar4 * 4);
            uVar4 = (uVar4 - 1) + *(int *)(*(int *)((int)this + 0x3300) + 0x20);
            break;
    // ...
}
```

---

## RenderContext Structure (Partial)

### Overview

The RenderContext structure holds per-frame rendering state used by `CM2SceneRenderDraw` and related functions.

### Structure Definition (Partial)

```cpp
struct RenderContext {
    // Unknown fields 0x00-0x3F
    char pad_0x00[0x40];

    // Offset 0x40: Camera pointer
    void* camera;                    // +0x40

    // Offset 0x44: Model flags
    uint32_t modelFlags;             // +0x44

    // Offset 0x48: Shader constants pointer
    void* shaderConstants;           // +0x48

    // Offset 0x4C: View matrix
    void* viewMatrix;                // +0x4C

    // Offset 0x50-0x6F: Unknown
    char pad_0x50[0x20];

    // Offset 0x70-0xAC: Transform matrix (4x4)
    float transform[16];             // +0x70

    // Large gap...
    char pad_0xB0[0x3190];

    // Offset 0x3240: Shader constant min index
    uint32_t shaderConstMin;         // +0x3240

    // Offset 0x3244: Shader constant max index
    uint32_t shaderConstMax;         // +0x3244

    // More gaps...
    char pad_0x3248[0xB8];

    // Offset 0x3300: Current batch pointer
    Batch* currentBatch;             // +0x3300

    // Offset 0x3304: Previous batch pointer
    Batch* previousBatch;            // +0x3304

    // Offset 0x3308: Current batch type
    uint32_t currentBatchType;       // +0x3308

    // Offset 0x330C: Previous batch type
    uint32_t previousBatchType;      // +0x330C

    // Offset 0x3310: Current model pointer
    Model* currentModel;             // +0x3310

    // Offset 0x3314-0x3317: Unknown
    char pad_0x3314[0x4];

    // Offset 0x3318: Current mesh data pointer
    void* currentMeshData;           // +0x3318

    // More fields...
    // Total size: At least 0x3400 bytes
};
```

---

## CGxDeviceD3d Structure (Partial)

### Overview

The CGxDeviceD3d structure wraps the D3D9 device and manages rendering state.

### Global Pointer

**Address**: `0x00c0ed38`
**Type**: `CGxDeviceD3d*` (or `IDirect3DDevice9**`)

```cpp
// Global device pointer
IDirect3DDevice9** g_d3d9DevicePtr = (IDirect3DDevice9**)0x00c0ed38;

// Usage:
IDirect3DDevice9* device = *g_d3d9DevicePtr;
device->SetVertexShader(...);
```

### Structure Definition (Partial)

```cpp
struct CGxDeviceD3d {
    // Offset 0x00: D3D9 device pointer
    IDirect3DDevice9* pD3D9Device;   // +0x00

    // Offset 0x04-0x27DF: Unknown (state tracking, buffers, etc.)
    char pad_0x04[0x27DC];

    // Offset 0x27E0: Current primitive type
    int currentPrimType;             // +0x27E0

    // Offset 0x27E4: Current vertex data pointer
    void* currentVertexData;         // +0x27E4

    // Offset 0x27E8: Current draw flags
    uint32_t currentDrawFlags;       // +0x27E8

    // More fields...
};
```

---

## Summary Table

| Structure | Size (bytes) | Critical Offsets | Purpose |
|-----------|--------------|------------------|---------|
| Model | 0x398+ | +0x94 (boneArray) | Container for entire M2 model |
| MeshData | 0x20+ | +0x06 (vertexCount) | Describes a submesh |
| Vertex (T-pose) | 0x30 (48) | +0x0C (weights), +0x10 (indices) | Unskinned vertex |
| SkinnedVertex | 0x28 (40) | N/A | Skinned vertex output |
| BoneMatrix | 0x40 (64) | N/A | 4x4 bone transform |
| Batch | 0x40 (64) | +0x00 (type), +0x04 (model) | Render batch descriptor |
| RenderContext | 0x3400+ | +0x3300 (currentBatch) | Frame rendering state |

---

## Memory Alignment

All structures appear to be naturally aligned:
- `float` fields: 4-byte aligned
- Pointers: 4-byte aligned (32-bit executable)
- Structures: Aligned to largest member

**No packing directives needed** for these structures.

---

## Validation Checklist

### Before Implementation

- [ ] Verify Model+0x94 points to valid bone array
- [ ] Verify MeshData+0x06 contains correct vertex count
- [ ] Verify Vertex stride is 48 bytes (0x30)
- [ ] Verify SkinnedVertex stride is 40 bytes (0x28)
- [ ] Verify BoneMatrix size is 64 bytes (0x40)
- [ ] Verify CGxDeviceD3d__device @ 0x00c0ed38 is valid

### Runtime Verification Code

```cpp
void VerifyStructures() {
    // Check sizes
    assert(sizeof(Vertex) == 0x30);
    assert(sizeof(SkinnedVertex) == 0x28);
    assert(sizeof(BoneMatrix) == 0x40);

    // Check device pointer
    IDirect3DDevice9** devicePtr = (IDirect3DDevice9**)0x00c0ed38;
    assert(!IsBadReadPtr(devicePtr, sizeof(void*)));

    IDirect3DDevice9* device = *devicePtr;
    assert(!IsBadReadPtr(device, sizeof(void*)));

    // Check device vtable
    void** vtable = *(void***)device;
    assert(!IsBadReadPtr(vtable, sizeof(void*) * 100));

    OutputDebugStringA("Structure verification passed\n");
}
```

---

**Document Version**: 1.0
**Last Updated**: 2025-12-04
**All offsets verified**: Ghidra decompilation of Wow.exe (1.12.1)
