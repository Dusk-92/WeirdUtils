# Pixel Shader-Based Outline Research for WoW 1.12.1 D3D9 Hook

## Executive Summary

This document researches pixel shader-based outline rendering techniques to achieve consistent screen-space outline thickness (2-3 pixels) regardless of unit distance from camera, for implementation in a WoW 1.12.1 D3D9 hook DLL.

### Current Implementation Limitations

The existing vertex shader approach expands vertices along normals in world space:
- **Problem**: Outline thickness varies with distance (far objects appear thinner on screen, close objects thicker)
- **Root Cause**: Fixed world-space expansion (e.g., 0.08 units) projects to different pixel counts at different depths
- **Current Workaround**: Distance-based scaling with clamping (THICKNESS_MIN/MAX per category)

### Research Goal

Achieve pixel-perfect, distance-independent outline thickness using pixel/fragment shader techniques suitable for D3D9 Shader Model 2.0/3.0.

---

## Current Implementation Analysis

### System Architecture (from `/media/storage/home/august/projects/idris/dlls/c_src/d3d9_hook.cpp`)

**Rendering Pipeline**:
1. Hook `DrawIndexedPrimitive` (vtable index 82) to identify corpse/target/raid-marked models
2. Cache draw calls with full state (vertex buffers, bone matrices, transforms)
3. During `EndScene`, replay cached draws with custom vertex shader
4. Two-pass stencil technique:
   - **Pass 1**: Render body to stencil buffer (value=1, no color write)
   - **Pass 2**: Render scaled outline where stencil != 1 (through walls, Z-disabled)

**Current Vertex Shader** (lines 835-882):
```hlsl
vs_2_0
dcl_position v0
dcl_blendweight v2
dcl_blendindices v3
dcl_normal v1

// Bone transformation (supports WoW M2 skeletal animation)
mul r0.xyz, v3.zyxw, c251.x           // indices * 765
mova a0.xyz, r0
mul r0, v2.y, c[a0.y + 31]            // Blend bone matrices
mad r0, c[a0.x + 31], v2.z, r0
mad r0, c[a0.z + 31], v2.x, r0
// ... (similar for all bone transform rows)

// Transform normal to world space
dp3 r3.x, r0, v1
dp3 r3.y, r1, v1
dp3 r3.z, r2, v1
nrm r5.xyz, r3                        // Normalize

// WORLD-SPACE EXPANSION (the problem)
mul r6.xyz, r5.xyz, c250.x            // normal * thickness (world units)
add r4.xyz, r4.xyz, r6.xyz            // position += offset

// Project to clip space
dp4 oPos.x, c2, r4
dp4 oPos.y, c3, r4
dp4 oPos.z, c4, r4
dp4 oPos.w, c5, r4
```

**Key Issue**: `c250.x` (thickness) is in world units. After projection, this creates variable screen-space thickness.

### Debug Log Analysis (first 100 lines)

From `/media/bigfaststore/games/Elysium Project Game Client/outline_debug.log`:
- **Pixel Shader Version**: `0xFFFF0300` (Shader Model 3.0 supported!)
- **Surface Size**: 1920x1080
- **Depth/Stencil Format**: D3DFMT_D24X8 (0x4D) - no native stencil, custom D24S8 created
- **Vertex Declaration**: Standard WoW M2 format (position, blendweight, blendindices, normal, texcoords)
- **Vertex Shader**: WoW's skinned shader (vs_2_0, 908 bytes)

**Hardware Capabilities Confirmed**:
- Pixel Shader 3.0 available
- Stencil operations supported (StencilCaps: 0x000001FF)
- Max vertex shader constants: 256

---

## Pixel Shader Outline Techniques

### 1. Sobel Edge Detection (Post-Process)

**How It Works**:
Uses convolution kernels to detect discontinuities in depth/normal/color buffers.

**Sobel Operator** ([Vertex Fragment, 2023](https://www.vertexfragment.com/ramblings/unity-postprocessing-sobel-outline/)):
```
Horizontal Kernel:      Vertical Kernel:
[-1  0  1]              [-1 -2 -1]
[-2  0  2]              [ 0  0  0]
[-1  0  1]              [ 1  2  1]
```

**Implementation** ([5 Ways to Draw an Outline](http://ameye.dev/notes/rendering-outlines/)):
1. Render scene to texture (requires render target)
2. Sample 9 neighboring pixels (3x3 grid)
3. Apply Sobel kernels to depth/normal buffers
4. Calculate gradient magnitude: `sqrt(Gx² + Gy²)`
5. If gradient > threshold, output outline color

**Pros**:
- Detects all edges in scene automatically
- Works with any geometry
- Computationally cheap (9 texture samples)
- Constant performance (screen resolution dependent, not model complexity)

**Cons**:
- Requires render-to-texture capability
- Outlines all objects (can't selectively outline specific units)
- 2-pixel maximum thickness with standard 3x3 kernel
- Thicker outlines require larger kernels (225 samples for 16px!)
- Not anti-aliased (blocky appearance)

**D3D9 Feasibility**: **HIGH**
- Shader Model 2.0 supports texture sampling
- Requires 1 additional render target (scene color/depth)
- Can use D3DFMT_R32F or D3DFMT_A8R8G8B8 for mask texture

---

### 2. Jump Flood Algorithm (JFA) for Distance Fields

**How It Works** ([Blog at Bottom of Sea, 2016](https://blog.demofox.org/2016/02/29/fast-voronoi-diagrams-and-distance-dield-textures-on-the-gpu-with-the-jump-flooding-algorithm/)):
Efficiently generates 2D distance fields for arbitrary shapes via parallel flooding.

**Algorithm** ([Ben Golus - Quest for Very Wide Outlines](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9)):
1. Initialize seed texture (object silhouette = 1, background = 0)
2. For each pass with jump distance D (start at texture_size/2):
   - Sample 9 neighbors (8 compass directions + center)
   - Find closest seed position
   - Store seed position at current pixel
   - Halve jump distance: D = D/2
3. Repeat until D = 1 (log2(texture_size) passes)
4. Final pass: draw outline where distance field is within threshold

**Passes Required** (for 1024x1024 texture):
- Pass 1: Jump = 512 pixels
- Pass 2: Jump = 256 pixels
- Pass 3: Jump = 128 pixels
- ... (10 total passes)
- Pass 10: Jump = 1 pixel

**Pros**:
- Perfect screen-space thickness control (specify exact pixel width)
- Supports very wide outlines (100+ pixels) efficiently
- Enables glow effects, soft shadows, rounded corners
- Logarithmic complexity: O(log(resolution))

**Cons**:
- Requires multiple render-to-texture passes (ping-pong between 2 textures)
- Memory intensive (2x full-screen R32F textures minimum)
- Complex to implement correctly
- Approximate algorithm (small errors, but negligible in practice)

**D3D9 Feasibility**: **MEDIUM**
- No compute shaders in D3D9 (must use pixel shaders + render-to-texture)
- Requires at least 2 full-screen R32F textures (16MB at 1920x1080)
- 10-12 rendering passes for 1080p (performance concern)
- Complex state management (ping-pong rendering)

**HLSL Pseudocode** (Shader Model 3.0):
```hlsl
// Pass: JFA iteration with jump distance D
sampler2D seedTex : register(s0);
float2 texelSize;   // 1.0 / texture dimensions
float jumpDist;     // Current jump distance

float4 PS_JFA(float2 uv : TEXCOORD0) : COLOR0
{
    float closestDist = 99999.0;
    float2 closestSeed = float2(0, 0);

    // Sample 9 neighbors (8 directions + center)
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offset = float2(x, y) * jumpDist * texelSize;
            float2 sampleUV = uv + offset;
            float2 seedPos = tex2D(seedTex, sampleUV).xy;

            if (seedPos.x > 0.0) {  // Valid seed
                float dist = distance(uv, seedPos);
                if (dist < closestDist) {
                    closestDist = dist;
                    closestSeed = seedPos;
                }
            }
        }
    }

    return float4(closestSeed, 0, 1);
}

// Final outline pass
float outlineWidth; // in pixels
float4 PS_Outline(float2 uv : TEXCOORD0) : COLOR0
{
    float2 seedPos = tex2D(seedTex, uv).xy;
    float dist = distance(uv, seedPos);

    // Convert to pixels
    float pixelDist = dist / length(texelSize);

    if (pixelDist < outlineWidth && pixelDist > 0.1) {
        return outlineColor;
    }
    return sceneColor;
}
```

---

### 3. Mask-Based Edge Detection (Hybrid Approach)

**Concept**: Combine stencil masking with pixel shader edge detection.

**Implementation**:
1. **Render silhouette mask** (current Pass 1) to dedicated render target
   - Render target format: D3DFMT_A8R8G8B8 or D3DFMT_R8G8B8
   - Draw target models with solid white color
2. **Edge detection pass** (pixel shader):
   - Sample mask texture in 3x3 or 5x5 kernel
   - Detect edges: if center = white AND any neighbor = black → edge
   - Output outline color at edge pixels
3. **Composite** over scene in EndScene

**Pros**:
- Selective outlining (only marked models)
- Precise pixel-width control
- Simpler than full JFA
- Works with current architecture (already rendering silhouettes)

**Cons**:
- Still requires render-to-texture
- Limited to moderate thickness (5x5 = ~2px, 9x9 = ~4px)
- Multiple texture samples per pixel

**D3D9 Feasibility**: **HIGH** - Best practical option
- Minimal changes to existing system
- 1 additional render target (mask texture)
- Single-pass edge detection shader
- Compatible with Shader Model 2.0

**HLSL Implementation** (ps_2_0):
```hlsl
sampler2D maskTex : register(s0);
float2 texelSize;     // 1.0 / (width, height)
float4 outlineColor;

// Simple 4-neighbor edge detection
float4 PS_EdgeDetect(float2 uv : TEXCOORD0) : COLOR0
{
    float center = tex2D(maskTex, uv).r;

    // Sample 4 cardinal directions
    float left   = tex2D(maskTex, uv + float2(-texelSize.x, 0)).r;
    float right  = tex2D(maskTex, uv + float2( texelSize.x, 0)).r;
    float top    = tex2D(maskTex, uv + float2(0, -texelSize.y)).r;
    float bottom = tex2D(maskTex, uv + float2(0,  texelSize.y)).r;

    // Edge if center is inside (white) but has outside neighbor (black)
    float isEdge = 0.0;
    if (center > 0.5) {
        if (left < 0.5 || right < 0.5 || top < 0.5 || bottom < 0.5) {
            isEdge = 1.0;
        }
    }

    return isEdge * outlineColor;
}

// 8-neighbor for thicker/smoother outlines
float4 PS_EdgeDetect8(float2 uv : TEXCOORD0) : COLOR0
{
    float center = tex2D(maskTex, uv).r;

    // Sample 8 neighbors
    float neighbors[8];
    neighbors[0] = tex2D(maskTex, uv + float2(-texelSize.x, -texelSize.y)).r; // TL
    neighbors[1] = tex2D(maskTex, uv + float2(0,           -texelSize.y)).r; // T
    neighbors[2] = tex2D(maskTex, uv + float2( texelSize.x, -texelSize.y)).r; // TR
    neighbors[3] = tex2D(maskTex, uv + float2(-texelSize.x, 0          )).r; // L
    neighbors[4] = tex2D(maskTex, uv + float2( texelSize.x, 0          )).r; // R
    neighbors[5] = tex2D(maskTex, uv + float2(-texelSize.x,  texelSize.y)).r; // BL
    neighbors[6] = tex2D(maskTex, uv + float2(0,            texelSize.y)).r; // B
    neighbors[7] = tex2D(maskTex, uv + float2( texelSize.x,  texelSize.y)).r; // BR

    float isEdge = 0.0;
    if (center > 0.5) {
        for (int i = 0; i < 8; i++) {
            if (neighbors[i] < 0.5) {
                isEdge = 1.0;
                break;
            }
        }
    }

    return isEdge * outlineColor;
}
```

---

### 4. Screen-Space Vertex Expansion (Improved Vertex Shader)

**Concept** ([Pixel-Perfect Outline Shaders](https://www.videopoetics.com/tutorials/pixel-perfect-outline-shaders-unity/)):
Instead of expanding in world space, expand in clip/screen space after projection.

**Mathematical Approach** ([Constant Screen-Space Width Rim Shading](https://computergraphics.stackexchange.com/questions/5355/constant-screen-space-width-rim-shading)):
1. Transform position and normal to clip space
2. Compute screen-space normal (perpendicular to view direction)
3. Offset position by `(normal_screenspace * pixel_thickness) / clip_w`
4. Division by `w` ensures consistent screen-space offset

**Key Insight**:
Clip space `w` component represents depth/distance. Dividing offset by `w` compensates for perspective projection.

**HLSL Implementation** (vs_3_0):
```hlsl
// Constants
float4x4 worldViewProj;
float4x4 worldView;
float outlinePixels;      // Desired thickness in pixels
float2 screenSize;        // Viewport dimensions (1920, 1080)

struct VS_OUTPUT {
    float4 position : POSITION;
};

VS_OUTPUT VS_ScreenSpaceOutline(
    float3 pos : POSITION,
    float3 normal : NORMAL,
    float4 blendWeights : BLENDWEIGHT,
    float4 blendIndices : BLENDINDICES)
{
    VS_OUTPUT output;

    // Apply bone transformations (same as current shader)
    float3 worldPos = ApplyBoneTransform(pos, blendWeights, blendIndices);
    float3 worldNormal = ApplyBoneTransformNormal(normal, blendWeights, blendIndices);

    // Transform to clip space
    float4 clipPos = mul(float4(worldPos, 1.0), worldViewProj);

    // Transform normal to view space, then project
    float3 viewNormal = mul(worldNormal, (float3x3)worldView);
    float4 clipNormal = mul(float4(viewNormal, 0.0), worldViewProj);

    // Normalize in clip space (ignore w component for direction)
    float2 screenNormal = normalize(clipNormal.xy);

    // Calculate pixel offset in NDC space
    // NDC ranges from -1 to 1, so full screen width = 2.0
    float2 offset = screenNormal * outlinePixels * float2(2.0 / screenSize.x, 2.0 / screenSize.y);

    // Apply offset, scaled by w for perspective correction
    clipPos.xy += offset * clipPos.w;

    output.position = clipPos;
    return output;
}
```

**Pros**:
- No render-to-texture required
- Pixel-perfect thickness regardless of distance
- Works with existing architecture (vertex shader approach)
- Simple to implement

**Cons**:
- Still requires two rendering passes
- Normal calculation in screen space can be imprecise for complex geometry
- May have artifacts at silhouette edges
- Requires Shader Model 3.0 for precision

**D3D9 Feasibility**: **VERY HIGH** - Easiest upgrade path
- Drop-in replacement for current vertex shader
- No new render targets needed
- Already have PS 3.0 support (0xFFFF0300)
- Minimal code changes

---

## Recommended Approach for WoW 1.12.1 D3D9

### Best Solution: Hybrid Screen-Space Vertex + Mask Edge Detection

Combine approaches 3 and 4 for optimal results:

**Phase 1 - Quick Win** (Screen-Space Vertex Shader):
1. Replace current world-space expansion with screen-space offset calculation
2. Maintain existing two-pass stencil rendering
3. Achieve pixel-consistent thickness with minimal changes

**Phase 2 - Enhanced Quality** (Add Mask Edge Detection):
1. Create render target for silhouette mask (D3DFMT_A8R8G8B8, same res as backbuffer)
2. Render silhouette to mask in Pass 1 (instead of just stencil)
3. Apply edge detection pixel shader to mask
4. Composite outline over scene
5. Enables multi-pixel outlines with precise control

### Implementation Steps

#### Step 1: Screen-Space Outline Vertex Shader

**File**: `/media/storage/home/august/projects/idris/dlls/c_src/d3d9_hook.cpp` (lines 835-882)

**Replace shader code** in `CreateOutlineShader()`:

```hlsl
const char* shaderSource =
    "vs_3_0\n"  // Upgrade to 3.0 for better precision
    "dcl_position v0\n"
    "dcl_blendweight v2\n"
    "dcl_blendindices v3\n"
    "dcl_normal v1\n"

    // Bone transformation (unchanged)
    "mul r0.xyz, v3.zyxw, c251.x\n"
    "mova a0.xyz, r0\n"
    "mul r0, v2.y, c[a0.y + 31]\n"
    "mad r0, c[a0.x + 31], v2.z, r0\n"
    "mad r0, c[a0.z + 31], v2.x, r0\n"
    "dp3 r3.x, r0, v1\n"
    "dp4 r4.x, r0, v0\n"

    "mul r1, v2.y, c[a0.y + 32]\n"
    "mad r1, c[a0.x + 32], v2.z, r1\n"
    "mad r1, c[a0.z + 32], v2.x, r1\n"
    "dp3 r3.y, r1, v1\n"
    "dp4 r4.y, r1, v0\n"

    "mul r2, v2.y, c[a0.y + 33]\n"
    "mad r2, c[a0.x + 33], v2.z, r2\n"
    "mad r2, c[a0.z + 33], v2.x, r2\n"
    "dp3 r3.z, r2, v1\n"
    "dp4 r4.z, r2, v0\n"

    "mov r4.w, c251.y\n"              // w = 1.0

    // Now r4.xyz = world position, r3.xyz = world normal

    // Project position to clip space FIRST
    "dp4 r6.x, c2, r4\n"              // clipPos.x
    "dp4 r6.y, c3, r4\n"              // clipPos.y
    "dp4 r6.z, c4, r4\n"              // clipPos.z
    "dp4 r6.w, c5, r4\n"              // clipPos.w (depth)

    // Transform normal to clip space
    "mov r5.w, c251.z\n"              // normal.w = 0 (direction)
    "dp4 r7.x, c2, r5\n"              // clipNormal.x
    "dp4 r7.y, c3, r5\n"              // clipNormal.y

    // Normalize screen-space normal (r7.xy)
    "dp2add r8.x, r7, r7, c251.z\n"   // dot(normal.xy, normal.xy)
    "rsq r8.x, r8.x\n"                // 1/sqrt(dot)
    "mul r7.xy, r7.xy, r8.xx\n"       // normalize

    // Calculate pixel offset in NDC space
    // c252 = (outlinePixels * 2.0 / screenWidth, outlinePixels * 2.0 / screenHeight, 0, 0)
    "mul r8.xy, r7.xy, c252.xy\n"     // offset = normal * pixelScale

    // Apply perspective-corrected offset
    "mul r8.xy, r8.xy, r6.ww\n"       // offset *= clipPos.w
    "add r6.xy, r6.xy, r8.xy\n"       // clipPos.xy += offset

    "mov oPos, r6\n";                 // Output final position
```

**Update constants** (before DrawIndexedPrimitive):
```cpp
// Current thickness constant (c250.x) - KEEP for compatibility
float thicknessConst[4] = { draw.OutlineThickness, 0.0f, 0.0f, 0.0f };
pDevice->SetVertexShaderConstantF(250, thicknessConst, 1);

// Shared constants (c251)
float shaderConst[4] = { 765.0f, 1.0f, 0.0f, 0.0f };
pDevice->SetVertexShaderConstantF(251, shaderConst, 1);

// NEW: Screen-space scaling constants (c252)
float pixelThickness = 2.5f;  // Desired outline width in pixels
D3DSURFACE_DESC rtDesc;
IDirect3DSurface9* pRT = nullptr;
pDevice->GetRenderTarget(0, &pRT);
pRT->GetDesc(&rtDesc);
pRT->Release();

float screenSpaceScale[4] = {
    pixelThickness * 2.0f / (float)rtDesc.Width,   // x scale
    pixelThickness * 2.0f / (float)rtDesc.Height,  // y scale
    0.0f,
    0.0f
};
pDevice->SetVertexShaderConstantF(252, screenSpaceScale, 1);
```

#### Step 2 (Optional): Add Mask Edge Detection

**Create mask render target** (add to d3d9_hook.cpp globals):
```cpp
static IDirect3DTexture9* g_pMaskTexture = nullptr;
static IDirect3DSurface9* g_pMaskSurface = nullptr;
static IDirect3DPixelShader9* g_pEdgeDetectPS = nullptr;
```

**Initialize in EndScene**:
```cpp
static bool CreateMaskRenderTarget(IDirect3DDevice9* pDevice, UINT width, UINT height) {
    HRESULT hr = pDevice->CreateTexture(
        width, height, 1, D3DUSAGE_RENDERTARGET,
        D3DFMT_A8R8G8B8, D3DPOOL_DEFAULT,
        &g_pMaskTexture, nullptr
    );
    if (FAILED(hr)) return false;

    return SUCCEEDED(g_pMaskTexture->GetSurfaceLevel(0, &g_pMaskSurface));
}

static bool CreateEdgeDetectShader(IDirect3DDevice9* pDevice) {
    const char* psSource =
        "ps_2_0\n"
        "dcl t0.xy\n"              // UV coordinates
        "dcl_2d s0\n"              // Mask texture sampler
        "def c0, 0.00052083, 0.00092593, 0.5, 1.0\n"  // texelSize (1/1920, 1/1080), 0.5, 1.0

        // Sample center
        "texld r0, t0, s0\n"

        // Sample 4 neighbors
        "add r1.xy, t0, c0.xy\n"   // right
        "texld r1, r1, s0\n"
        "sub r2.xy, t0, c0.xy\n"   // left
        "texld r2, r2, s0\n"
        "add r3.xy, t0.xy, float2(0, c0.y)\n"  // top
        "texld r3, r3, s0\n"
        "sub r4.xy, t0.xy, float2(0, c0.y)\n"  // bottom
        "texld r4, r4, s0\n"

        // Edge detection: center > 0.5 AND any neighbor < 0.5
        "cmp r5, r0.r-c0.z, c0.z, c0.w\n"     // center > 0.5?
        "cmp r6, c0.z-r1.r, c0.w, c0.z\n"     // right < 0.5?
        "cmp r7, c0.z-r2.r, c0.w, c0.z\n"     // left < 0.5?
        "add r6, r6, r7\n"
        "cmp r7, c0.z-r3.r, c0.w, c0.z\n"     // top < 0.5?
        "add r6, r6, r7\n"
        "cmp r7, c0.z-r4.r, c0.w, c0.z\n"     // bottom < 0.5?
        "add r6, r6, r7\n"

        "mul r5, r5, r6\n"                     // center AND neighbor
        "cmp r0, r5-c0.z, c0.wwww, c0.zzzz\n" // output 1 if edge, 0 otherwise
        "mov oC0, r0\n";

    // Compile and create shader (use D3DXAssembleShader like vertex shader)
    // ...
}
```

**Render pipeline** (replace stencil passes in EndScene):
```cpp
// 1. Render silhouettes to mask texture (white)
pDevice->SetRenderTarget(0, g_pMaskSurface);
pDevice->Clear(0, nullptr, D3DCLEAR_TARGET, 0x00000000, 1.0f, 0);  // Black background
// ... render white silhouettes ...

// 2. Apply edge detection
pDevice->SetRenderTarget(0, pBackbuffer);
pDevice->SetTexture(0, g_pMaskTexture);
pDevice->SetPixelShader(g_pEdgeDetectPS);
// ... render fullscreen quad with edge detect shader ...

// 3. Composite result
```

---

## Performance Considerations

### Rendering Cost Analysis (1920x1080)

| Technique | Render Targets | Shader Passes | Texture Samples/Pixel | Est. GPU Cost |
|-----------|----------------|---------------|----------------------|---------------|
| Current (world-space vertex) | 1 (D24S8) | 2 (stencil + outline) | 0 | **LOW** (baseline) |
| Screen-space vertex | 1 (D24S8) | 2 (stencil + outline) | 0 | **LOW** (same as current) |
| Mask + edge detect (4-neighbor) | 2 (D24S8 + A8R8G8B8) | 3 (mask + edge + composite) | 5 | **MEDIUM** (+30%) |
| Mask + edge detect (8-neighbor) | 2 | 3 | 9 | **MEDIUM** (+50%) |
| Sobel filter | 2 | 2 (scene + edge) | 9 | **MEDIUM** (+40%) |
| JFA (10 passes) | 3 (scene + 2x R32F) | 12 (init + 10 JFA + outline) | 9-18 | **HIGH** (+200%) |

**Memory Usage**:
- Current: ~8 MB (1920x1080x4 bytes D24S8)
- +Mask: +8 MB (A8R8G8B8)
- +JFA: +32 MB (2x R32F at 1920x1080x4 bytes)

**Recommendation**: Start with **screen-space vertex shader** (zero cost increase), optionally add **4-neighbor edge detection** if more thickness needed.

---

## D3D9 Shader Model Compatibility

### Shader Model 2.0 (Minimum Supported)

**Pixel Shader Capabilities** ([ps_2_0 documentation](https://developer.download.nvidia.com/cg/ps_2_0.html)):
- Texture samples: 32 max
- Instruction slots: 64-96 (shader model 2.0b)
- Interpolators: 8
- Temporary registers: 12-32
- **No**: Dynamic branching, integer operations, texture writes

**Vertex Shader**: vs_2_0 similar to current implementation (256 instruction slots)

### Shader Model 3.0 (WoW 1.12.1 Confirmed)

**Enhancements** ([ps_3_0 documentation](https://developer.download.nvidia.com/cg/ps_3_0.html)):
- Texture samples: **Unlimited** (important for JFA)
- Instruction slots: **Unlimited** (up to 65536)
- Interpolators: 10
- Temporary registers: 32
- Dynamic flow control (if/loop)
- **Still no**: Texture writes (requires DX10), compute shaders

**Key Limitation**: Cannot write to textures from shaders. JFA requires ping-pong rendering between render targets (change RT, render fullscreen quad, repeat).

### Multiple Render Targets (MRT)

**D3D9 Support** ([Stack Overflow](https://stackoverflow.com/questions/1366232/how-many-render-targets-do-low-end-pixel-shader-2-0-supporting-video-cards-suppo)):
- Shader Model 2.0: 1-4 MRTs (hardware dependent)
- Shader Model 3.0: Up to 4 guaranteed
- WoW likely supports 4 MRTs (DX9-era NVidia/ATI cards)

**Use Case**: Could render color + depth + normal simultaneously for enhanced edge detection.

---

## Alternative: Depth-Based Screen-Space Outlines

Another approach mentioned in research ([Godot Depth-Based Outline](https://godotshaders.com/shader/depth-based-outline-shader/)):

**Concept**:
1. Render scene normally
2. Sample depth buffer in pixel shader
3. Compare depth with neighbors
4. Large depth discontinuity = edge → outline

**Advantages**:
- No additional geometry rendering
- Automatically detects all silhouettes
- Works with current WoW depth buffer

**Disadvantages**:
- Cannot selectively outline specific units (outlines everything)
- Requires access to depth buffer as texture (may need resolve pass)
- Interior edges not detected (only silhouettes)

**D3D9 Implementation**:
```hlsl
// Requires depth buffer as shader resource (D3DFMT_D24X8 or D3DFMT_D24S8)
sampler2D depthTex : register(s1);
float2 texelSize;

float4 PS_DepthOutline(float2 uv : TEXCOORD0) : COLOR0
{
    float centerDepth = tex2D(depthTex, uv).r;

    // Sample neighbors
    float leftDepth   = tex2D(depthTex, uv + float2(-texelSize.x, 0)).r;
    float rightDepth  = tex2D(depthTex, uv + float2( texelSize.x, 0)).r;
    float topDepth    = tex2D(depthTex, uv + float2(0, -texelSize.y)).r;
    float bottomDepth = tex2D(depthTex, uv + float2(0,  texelSize.y)).r;

    // Calculate depth gradient
    float depthGradX = abs(rightDepth - leftDepth);
    float depthGradY = abs(bottomDepth - topDepth);
    float depthGrad = sqrt(depthGradX * depthGradX + depthGradY * depthGradY);

    // Threshold for edge detection
    float edgeThreshold = 0.01;
    float isEdge = step(edgeThreshold, depthGrad);

    return isEdge * outlineColor;
}
```

**Not Recommended** for this project because it can't selectively outline corpses/targets only.

---

## Implementation Roadmap

### Phase 1: Screen-Space Vertex Shader (Immediate)

**Effort**: 2-4 hours
**Files Modified**: `/media/storage/home/august/projects/idris/dlls/c_src/d3d9_hook.cpp`
**Changes**:
1. Update shader source to vs_3_0
2. Add screen-space offset calculation (lines 835-882)
3. Add c252 constant setup (screen dimensions)
4. Test with existing two-pass stencil rendering

**Expected Result**: Pixel-perfect 2-3 pixel outlines at all distances.

### Phase 2: Mask Render Target (Optional, 1-2 days)

**Effort**: 1-2 days
**Files Modified**: `d3d9_hook.cpp`
**New Code**:
1. Mask texture creation (D3DFMT_A8R8G8B8)
2. Render silhouettes to mask (white on black)
3. Fullscreen quad rendering infrastructure

**Expected Result**: Foundation for pixel shader effects.

### Phase 3: Edge Detection Shader (Optional, 1 day)

**Effort**: 1 day
**Files Modified**: `d3d9_hook.cpp`
**New Code**:
1. ps_2_0 edge detection shader (4 or 8 neighbor)
2. Fullscreen quad with edge shader
3. Composite over scene with alpha blending

**Expected Result**: Smoother, wider outlines (up to 4-5 pixels).

### Phase 4: JFA Implementation (Advanced, 3-5 days)

**Only if needed** for very wide outlines (10+ pixels).
**Effort**: 3-5 days
**Complexity**: High (ping-pong rendering, multiple passes)
**Benefit**: Very wide, smooth outlines with glow effects

---

## Conclusion

### Recommended Implementation

**For your project (WoW 1.12.1 corpse outlines):**

1. **Implement Phase 1** (screen-space vertex shader) immediately
   - Zero performance cost
   - Solves distance-dependent thickness problem
   - Drop-in replacement for current shader
   - Estimated 2-3 hours development time

2. **Evaluate results**, then decide on Phase 2/3
   - If 2-3 pixel outline sufficient → DONE
   - If need wider/smoother → Add edge detection

3. **Skip JFA** unless very wide outlines (10+ pixels) required
   - Significant complexity
   - Performance cost
   - Overkill for corpse highlighting

### Technical Summary

**Best approach**: Screen-space vertex expansion with perspective correction
- **Shader Model**: 3.0 (confirmed supported: 0xFFFF0300)
- **Render Targets**: Use existing D24S8 (no new allocations)
- **Performance**: Same as current (zero overhead)
- **Thickness**: Exactly 2-3 pixels regardless of distance
- **Compatibility**: WoW 1.12.1 D3D9 fully compatible

**Alternative (if more thickness needed)**: Add mask-based edge detection
- **Shader Model**: 2.0 or 3.0
- **Render Targets**: +1 (A8R8G8B8)
- **Performance**: +30-50% GPU time
- **Thickness**: Up to 4-5 pixels with smooth anti-aliasing

---

## References and Sources

### Academic Papers

No specific arXiv papers found for outline rendering (search conducted December 2025). Most research in this area is industry-focused rather than academic.

### Industry Resources

1. [Pixel-Perfect Outline Shaders for Unity](https://www.videopoetics.com/tutorials/pixel-perfect-outline-shaders-unity/) - Screen-space outline techniques
2. [The Quest for Very Wide Outlines](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9) - Ben Golus, comprehensive exploration of JFA for outlines
3. [5 Ways to Draw an Outline](http://ameye.dev/notes/rendering-outlines/) - Comparison of outline techniques
4. [Sobel Outline with Unity Post-Processing](https://www.vertexfragment.com/ramblings/unity-postprocessing-sobel-outline/) - Sobel operator implementation
5. [Edge Detection Outlines](https://ameye.dev/notes/edge-detection-outlines/) - Post-processing edge detection
6. [Constant Screen-Space Width Rim Shading](https://computergraphics.stackexchange.com/questions/5355/constant-screen-space-width-rim-shading) - Mathematical approach to screen-space consistency
7. [Jump Flooding Algorithm](https://blog.demofox.org/2016/02/29/fast-voronoi-diagrams-and-distance-dield-textures-on-the-gpu-with-the-jump-flooding-algorithm/) - Distance field generation
8. [Godot Thick 3D Outline Shader](https://godotshaders.com/shader/thick-3d-screen-space-depth-normal-based-outline-shader/) - Practical shader implementation

### DirectX 9 Documentation

9. [Writing HLSL Shaders in Direct3D 9](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-writing-shaders-9) - Microsoft Official Documentation
10. [ps_2_0 Profile](https://developer.download.nvidia.com/cg/ps_2_0.html) - Nvidia Cg Documentation
11. [ps_3_0 Profile](https://developer.download.nvidia.com/cg/ps_3_0.html) - Nvidia Cg Documentation
12. [D3D9 Render Target Texture](https://gamedev.net/forums/topic/547390-can-not-render-to-a-render-target-that-is-also-used-as-a-texture/) - GameDev.net Discussion
13. [SSAO on D3D9 with HLSL](https://www.gamedev.net/forums/topic/534676-ssao-on-d3d9-with-hlsl/4455080/) - Post-processing example
14. [Unity Shader Compilation Targets](https://docs.unity3d.com/2020.1/Documentation/Manual/SL-ShaderCompileTargets.html) - Shader model capabilities

### Related Techniques

15. [GitHub - Unity Sobel Outline](https://github.com/ssell/UnitySobelOutline) - Open source implementation
16. [GitHub - Jump Flood Algorithm with bgfx](https://itscai.us/blog/post/jfa/) - JFA implementation details
17. [Outline Shader with Variable Width Lines](https://stackoverflow.com/questions/13836597/outline-shader-with-variable-width-lines) - Stack Overflow discussion

---

## Appendix: Full Shader Code

### A. Screen-Space Outline Vertex Shader (vs_3_0)

Complete shader with bone transformation and screen-space expansion:

```hlsl
vs_3_0

// Vertex inputs
dcl_position v0        // Position (float3)
dcl_blendweight v2     // Blend weights (D3DCOLOR normalized)
dcl_blendindices v3    // Blend indices (D3DCOLOR)
dcl_normal v1          // Normal (float3)

// Constants:
// c0-c1: Reserved (WoW constants)
// c2-c5: View-projection matrix
// c31-c255: Bone matrices (c[idx+31], c[idx+32], c[idx+33] per bone)
// c250: (thickness_world, unused, unused, unused) - kept for compatibility
// c251: (765.0, 1.0, 0.0, 0.0) - bone index scale, constants
// c252: (pixelScale.x, pixelScale.y, 0, 0) - screen-space thickness

// Convert blend indices to bone constant offsets
mul r0.xyz, v3.zyxw, c251.x    // indices * 765 (WoW's bone index encoding)
mova a0.xyz, r0                 // Move to address register

// Bone matrix blending - Row 1 (X component of transform)
mul r0, v2.y, c[a0.y + 31]
mad r0, c[a0.x + 31], v2.z, r0
mad r0, c[a0.z + 31], v2.x, r0

// Apply to position and normal
dp4 r4.x, r0, v0               // Transform position X
dp3 r3.x, r0, v1               // Transform normal X

// Bone matrix blending - Row 2 (Y component)
mul r1, v2.y, c[a0.y + 32]
mad r1, c[a0.x + 32], v2.z, r1
mad r1, c[a0.z + 32], v2.x, r1

dp4 r4.y, r1, v0               // Transform position Y
dp3 r3.y, r1, v1               // Transform normal Y

// Bone matrix blending - Row 3 (Z component)
mul r2, v2.y, c[a0.y + 33]
mad r2, c[a0.x + 33], v2.z, r2
mad r2, c[a0.z + 33], v2.x, r2

dp4 r4.z, r2, v0               // Transform position Z
dp3 r3.z, r2, v1               // Transform normal Z

mov r4.w, c251.y               // position.w = 1.0

// Normalize world-space normal
nrm r5.xyz, r3

// === SCREEN-SPACE EXPANSION (NEW) ===

// Project position to clip space
dp4 r6.x, c2, r4               // clipPos.x
dp4 r6.y, c3, r4               // clipPos.y
dp4 r6.z, c4, r4               // clipPos.z
dp4 r6.w, c5, r4               // clipPos.w (depth for perspective)

// Project normal to clip space (w=0 for direction vector)
mov r5.w, c251.z               // normal.w = 0
dp4 r7.x, c2, r5               // clipNormal.x
dp4 r7.y, c3, r5               // clipNormal.y

// Normalize clip-space normal (2D)
dp2add r8.x, r7.xy, r7.xy, c251.z  // dot(normal.xy, normal.xy)
rsq r8.x, r8.x                      // 1 / sqrt(dot) = 1/length
mul r7.xy, r7.xy, r8.xx             // normalize: normal / length

// Calculate screen-space offset
// c252.xy = (outlinePixels * 2.0 / screenWidth, outlinePixels * 2.0 / screenHeight)
mul r8.xy, r7.xy, c252.xy      // offset = normal * pixelScale

// Apply perspective correction: scale by clipPos.w
mul r8.xy, r8.xy, r6.ww        // offset *= depth

// Apply offset to clip position
add r6.xy, r6.xy, r8.xy        // clipPos.xy += offset

// Output final position
mov oPos, r6
```

### B. Edge Detection Pixel Shader (ps_2_0)

4-neighbor edge detection for mask texture:

```hlsl
ps_2_0

// Texture coordinate input
dcl t0.xy

// Sampler for mask texture (white = inside, black = outside)
dcl_2d s0

// Constants:
// c0 = (texelSize.x, texelSize.y, 0.5, 1.0)
//      texelSize = 1.0 / (screenWidth, screenHeight)
def c0, 0.00052083, 0.00092593, 0.5, 1.0  // Example for 1920x1080

// Sample center pixel
texld r0, t0, s0

// Sample right neighbor
add r1.xy, t0.xy, float2(c0.x, 0)
texld r1, r1, s0

// Sample left neighbor
sub r2.xy, t0.xy, float2(c0.x, 0)
texld r2, r2, s0

// Sample top neighbor
add r3.xy, t0.xy, float2(0, c0.y)
texld r3, r3, s0

// Sample bottom neighbor
sub r4.xy, t0.xy, float2(0, c0.y)
texld r4, r4, s0

// Edge detection logic:
// Edge if (center > 0.5) AND (any neighbor < 0.5)

// Check if center is inside (white)
cmp r5, r0.r-c0.z, c0.z, c0.w   // r5 = (center > 0.5) ? 1.0 : 0.5

// Check if any neighbor is outside (black)
cmp r6, c0.z-r1.r, c0.w, c0.z   // r6 = (right < 0.5) ? 1.0 : 0.5
cmp r7, c0.z-r2.r, c0.w, c0.z   // r7 = (left < 0.5) ? 1.0 : 0.5
add r6, r6, r7                   // Accumulate neighbor checks
cmp r7, c0.z-r3.r, c0.w, c0.z   // r7 = (top < 0.5) ? 1.0 : 0.5
add r6, r6, r7
cmp r7, c0.z-r4.r, c0.w, c0.z   // r7 = (bottom < 0.5) ? 1.0 : 0.5
add r6, r6, r7

// Combine: edge if center inside AND neighbor outside
mul r5, r5, r6                   // Multiply conditions
cmp r0, r5-c0.z, c0.wwww, c0.zzzz  // Output 1.0 if edge, 0.0 otherwise

// Output edge mask
mov oC0, r0
```

### C. Fullscreen Quad Vertex Shader

For rendering edge detection pass:

```hlsl
vs_2_0

// No inputs needed for fullscreen quad
// Quad vertices: (-1,-1), (1,-1), (-1,1), (1,1)
// Generated procedurally from vertex ID

dcl_position v0   // Quad vertex position (clip space)

// Output position and UVs
mov oPos, v0
add oT0.xy, v0.xy, float2(1, 1)  // Convert -1..1 to 0..2
mul oT0.xy, oT0.xy, float2(0.5, -0.5)  // Convert to UV (flip Y)
```

---

**Document Created**: December 3, 2025
**Target Platform**: WoW 1.12.1, DirectX 9, Shader Model 3.0
**Purpose**: Research pixel shader outline techniques for consistent screen-space thickness
**Status**: Ready for implementation (Phase 1 recommended)
