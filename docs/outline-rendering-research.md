# Outline Rendering Research: Techniques for WoW 1.12.1 D3D9 Hook

## Context

DLL-injected hook into WoW 1.12.1 (D3D9, Shader Model 3.0, 32-bit). Drawing colored outlines around specific player/NPC models via IDirect3DDevice9 vtable hooks (DrawIndexedPrimitive, EndScene, Reset).

### Requirements

| Category | Walls occlude? | Other units occlude? | Notes |
|---|---|---|---|
| Alive targets | Yes | No | Outlines show over other units for combat visibility |
| Dead friendlies | No | No | Visible through everything for finding corpses |

### Current Approach

3-pass stencil with normal-extrusion vertex shader in the DIP hook:
- Pass 1: Mark body in stencil (no color write)
- Pass 2: Draw enlarged outline via VS that extrudes vertices along normals
- Pass 3: Restore state, draw normal model on top

Batch reordering (`model_hook.zig`) moves outline targets to render first in the M2 batch list so only terrain+WMO depth exists at outline time.

### Current Approach Problems
- Outline thickness varies with mesh geometry (sharp edges get thinner outlines)
- Gaps at separate body parts (WoW characters have separate meshes for armor, capes, etc.)
- Concave silhouettes produce artifacts
- Requires batch reordering to get the right depth state

---

## How Shipped Games Do It

### League of Legends (Riot Games)

Uses **depth-buffer + Sobel edge detection** tightly integrated into the rendering pipeline:

- During the skinned mesh rendering pass, shaders write **scaled depth** to a secondary buffer via **Multiple Render Targets (MRT)**.
- Outlines are produced by running a **Sobel filter** on that scaled depth buffer. The Sobel filter finds discontinuities in depth corresponding to silhouette edges.
- The detected edge is rendered back over the skinned mesh - done **per-mesh individually**, not as a single full-screen post-process.
- For GPUs that do not support MRT, there is a **fallback using stencil buffers**.
- Rendering order places outlines as a dedicated stage between skinned meshes and grass/water in a 13-stage pipeline.

This is notably clean: it piggybacks on the already-required mesh render pass (no extra geometry pass), and the Sobel filter on a per-object depth buffer gives crisp, uniform-width outlines without the variable-thickness problem of normal extrusion.

Sources:
- https://technology.riotgames.com/news/trip-down-lol-graphics-pipeline
- https://www.gamedeveloper.com/programming/a-layer-by-layer-breakdown-of-i-league-of-legends-i-rendering-process

### Valve Source Engine (Left 4 Dead / DOTA 2 / TF2)

Uses the **"L4D Glow Effect"** - a **stencil + render-to-texture + blur** approach. Used across Left 4 Dead, TF2, CS:GO, and DOTA 2 (pre-Source 2):

1. **Stencil pass**: Draw the entity onto the Stencil Buffer. Creates a "cutout" mask of the entity's silhouette.
2. **Color pass**: Draw the entity with the desired glow color (flat/constant color) onto a separate Render Target ("GlowBuff1").
3. **Blur + composite**: Blur GlowBuff1 (using a second RT "GlowBuff2" for ping-pong blur passes), then render the blurred result to the screen **while respecting the stencil buffer**. The stencil test ensures only the blurred pixels that extend beyond the entity's silhouette are visible, producing a halo/outline effect.

The stencil cutout is the key innovation - it prevents the glow color from appearing inside the character, so you only see the outline fringe.

Sources:
- https://developer.valvesoftware.com/wiki/L4D_Glow_Effect
- https://developer.valvesoftware.com/wiki/L4D_Glow_Effect.cpp
- https://developer.valvesoftware.com/wiki/L4D_Glow_Effect_(2013_SDK)

### World of Warcraft (Retail, Warlords of Draenor+)

Has an "Outline Mode" highlighting targeted/moused-over characters with color-coded outlines (green = friendly, red = hostile, yellow = neutral, blue = non-PVP):

- The **EffectGlow** system uses 4 render targets in a chain: the scene is box-blurred (FFXBox4 shader, 2x2), then Gaussian-blurred twice (FFXGauss4, 4-tap Gaussian), then composited with the original scene (FFXGlow shader).
- Intermediate blur targets are at **1/4 width x 1/4 height** of the screen.
- The Gaussian blur uses asymmetric weights: `vec2(0.125, 0.375)` for center and adjacent samples.

Sources:
- https://wowdev.wiki/Rendering/ScreenEffects
- https://wowdev.wiki/Rendering

### Unreal Engine (Fortnite etc.)

Uses **Custom Depth + Custom Stencil** post-process approach:

- Objects that need outlines write to the **Custom Depth buffer** (optional secondary depth buffer).
- A **Custom Stencil** byte per pixel distinguishes different objects/groups for different outline colors.
- A post-process material reads Custom Depth/Stencil buffers and applies edge detection or dilation.
- UE also ships a JFA package for wide outlines.

Sources:
- https://www.michalorzelek.com/blog/tutorial-creating-outline-effect-around-objects/
- https://dev.epicgames.com/community/learning/tutorials/zj3x/unreal-engine-fortnite-overlay-materials-for-outlines-and-other-fx

---

## Candidate Techniques (All SM3.0 Compatible)

### 1. Screen-Space Dilation (Valve/L4D Style)

**How it works:**

Render each target's silhouette as flat color to an offscreen render target (depth-tested against terrain for alive, no depth for dead). Then run a pixel shader that samples an NxN neighborhood - if any sample is "on", the pixel is outline. Subtract the original mask to get just the ring. Composite over backbuffer.

```hlsl
// SM3.0 pixel shader - fixed-size box dilation
sampler2D SilhouetteTex;
float2 TexelSize; // (1.0/screenW, 1.0/screenH)

float4 DilatePS(float2 uv : TEXCOORD0) : COLOR0
{
    float hit = 0.0;
    for (int y = -3; y <= 3; y++) {
        for (int x = -3; x <= 3; x++) {
            float2 offset = float2(x, y) * TexelSize;
            hit = max(hit, tex2D(SilhouetteTex, uv + offset).r);
        }
    }
    float original = tex2D(SilhouetteTex, uv).r;
    float outline = hit - original;
    return float4(OutlineColor.rgb, outline * OutlineColor.a);
}
```

For circular (non-square) outlines, add a distance check:

```hlsl
if (length(float2(x, y)) <= OutlineRadius) {
    hit = max(hit, tex2D(SilhouetteTex, uv + offset).r);
}
```

**Pros:**
- Perfectly uniform outline width regardless of mesh geometry
- Simple shaders (a single dilation pass is ~49 tex samples for 7x7)
- Proven D3D9 technique (Valve shipped this)

**Cons:**
- Square corners at large radii (box kernel artifact)
- Cost grows as O(N^2) with outline width - impractical beyond ~8px
- Needs 2-3 render targets

**Performance:** 49 texture samples per pixel at 1024x768 = ~38M samples. On modern hardware: effectively free (<1ms). On 2004-era hardware: 2-4ms.

**Occlusion:** All 3 requirements satisfiable. The mask generation controls occlusion; the dilation is purely 2D.

### 2. Jump Flood Algorithm (JFA)

**How it works:**

The JFA (Rong & Tan, 2006) computes an approximate 2D distance transform on the GPU using O(log N) pixel shader passes. This is the foundation of high-quality screen-space outlines in modern games.

**Step 1 - Seed initialization:**
Render unit silhouettes into a binary mask. An init shader reads this mask: "on" pixels output their own UV coordinates, "off" pixels get a sentinel value (e.g., `(9999, 9999)`). Output format: RG16F (two channels for x,y coordinates).

```hlsl
// Seed init PS
float4 SeedInitPS(float2 uv : TEXCOORD0) : COLOR0
{
    float silhouette = tex2D(UnitMask, uv).r;
    if (silhouette > 0.5)
        return float4(uv.x, uv.y, 0, 1);
    else
        return float4(9999, 9999, 0, 0);
}
```

**Step 2 - JFA propagation (iterative):**
Execute `ceil(log2(maxOutlineRadius))` passes. For pass k, step size = `2^(N-k-1)` (starts large, halves each pass). Each pixel samples itself and 8 compass neighbors at the step offset (9 total samples in a 3x3 grid with large spacing). Keep the seed coordinate nearest to the current pixel. Ping-pong between two render targets.

```hlsl
// JFA propagation PS
sampler2D CurrentJFA;
float2 TexelSize;
float StepSize;

float4 JFAPassPS(float2 uv : TEXCOORD0) : COLOR0
{
    float2 bestSeed = float2(9999, 9999);
    float bestDist = 1e10;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 sampleUV = uv + float2(dx, dy) * StepSize * TexelSize;
            float2 candidate = tex2D(CurrentJFA, sampleUV).rg;
            if (candidate.x < 9000.0) {
                float d = length(candidate - uv);
                if (d < bestDist) {
                    bestDist = d;
                    bestSeed = candidate;
                }
            }
        }
    }
    return float4(bestSeed, 0, 1);
}
```

**Step 3 - Distance readout and outline generation:**
After all passes, each texel holds the UV of the nearest seed. Convert to pixel-space distance and threshold:

```hlsl
float4 OutlinePS(float2 uv : TEXCOORD0) : COLOR0
{
    float2 nearestSeed = tex2D(JFAResult, uv).rg;
    float dist = length((nearestSeed - uv) / TexelSize);
    float inSilhouette = tex2D(SilhouetteMask, uv).r;

    // Hard outline:
    float outline = (dist < OutlineWidth && inSilhouette < 0.5) ? 1.0 : 0.0;

    // Or anti-aliased:
    // float outline = smoothstep(OutlineWidth, OutlineWidth - 1.0, dist) * (1.0 - inSilhouette);

    return float4(OutlineColor.rgb, outline * OutlineColor.a);
}
```

**D3D9/SM3.0 compatibility:** Fully compatible. Each pass is a simple pixel shader with 9 texture samples and simple arithmetic. No gather, no integer bitops, no geometry/compute shaders required. Ping-pong between two textures is standard D3D9. The only requirement is that D3D9 does not allow reading and writing the same surface - alternate between two textures each pass.

**Pros:**
- Exact circular distance field - perfectly round outlines at any width
- Anti-aliasable (smoothstep on the distance)
- Cost is O(log2(N)) passes - a 32px outline costs only 5 passes
- Enables soft glow, pulsing, gradient effects for free (just change threshold function)
- Nothing requires anything beyond SM2.0

**Cons:**
- More render target switches than dilation (5-10 passes vs 1)
- Needs two RG16F render targets (ping-pong)
- Slightly more implementation complexity
- Cannot use bilinear filtering on JFA output (it stores coordinates, not distances)

**Performance:** 10 fullscreen passes at 9 samples each = 90M samples at 1024x768. On modern hardware: sub-millisecond. Can run at half resolution (512x384) to halve cost with minimal quality loss for outlines up to 5-6px.

**Occlusion:** Same as dilation - mask generation is independent of outline generation.

**JFA quality:** Approximation error bounded at sqrt(2)/2 pixels at jump step boundaries. For outlines up to ~20px, visually imperceptible. Results are smooth, rotationally symmetric, and anti-aliasable.

Sources:
- Rong & Tan, "Jump Flooding in GPU with Applications to Voronoi Diagram and Distance Transform," ACM I3D 2006
- https://www.comp.nus.edu.sg/~tants/jfa.html
- https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9
- https://gist.github.com/bgolus/a18c1a3fc9af2d73cc19169a809eb195
- https://itscai.us/blog/post/jfa/
- https://blog.demofox.org/2016/02/29/fast-voronoi-diagrams-and-distance-dield-textures-on-the-gpu-with-the-jump-flooding-algorithm/
- https://en.wikipedia.org/wiki/Jump_flooding_algorithm
- https://www.shadertoy.com/view/4syGWK
- https://mini.gmshaders.com/p/gm-shaders-mini-jfa
- RTSDF paper (extends JFA): https://arxiv.org/abs/2210.04449

### 3. Sobel Edge Detection on ID/Depth Buffer

**How it works:**

Render each target with a unique ID value into an R8 render target (depth-tested). Run a 3x3 Sobel filter - pixels where neighboring IDs differ are edges.

```hlsl
float4 SobelEdgePS(float2 uv : TEXCOORD0) : COLOR0
{
    float tl = tex2D(IDTex, uv + float2(-1,-1) * TexelSize).r;
    float tc = tex2D(IDTex, uv + float2( 0,-1) * TexelSize).r;
    float tr = tex2D(IDTex, uv + float2( 1,-1) * TexelSize).r;
    float ml = tex2D(IDTex, uv + float2(-1, 0) * TexelSize).r;
    float mr = tex2D(IDTex, uv + float2( 1, 0) * TexelSize).r;
    float bl = tex2D(IDTex, uv + float2(-1, 1) * TexelSize).r;
    float bc = tex2D(IDTex, uv + float2( 0, 1) * TexelSize).r;
    float br = tex2D(IDTex, uv + float2( 1, 1) * TexelSize).r;

    float gx = -tl - 2*ml - bl + tr + 2*mr + br;
    float gy = -tl - 2*tc - tr + bl + 2*bc + br;
    float edge = sqrt(gx*gx + gy*gy);

    float outline = step(0.001, edge);
    return float4(OutlineColor.rgb, outline);
}
```

**Pros:**
- Cheapest option (single pass, 9 samples)
- Crisp, accurate silhouette detection
- No variable-thickness artifacts

**Cons:**
- Produces only 1-2px outlines - can't thicken without adding dilation anyway
- Detects unit-to-unit boundaries too (unwanted internal edges between overlapping characters)
- Alone, not sufficient for controllable-width outlines

**Performance:** 8 texture samples per pixel. Roughly 0.1-0.2ms at 1024x768. Fastest of all approaches.

**Occlusion:** Req 1 yes, Req 3 yes, Req 2 partially (spurious edges at unit overlaps).

### 4. Gaussian Blur Difference (WoW Retail Style)

**How it works:**

Render silhouette to RT. Separable Gaussian blur (H pass + V pass). Subtract original from blurred → outline. Can downsample to 1/4 res for performance (like retail WoW does for bloom).

```hlsl
// Gaussian blur 5-tap (separable - run horizontal then vertical)
float weights[5] = {0.0625, 0.25, 0.375, 0.25, 0.0625};

float4 GaussianBlurPS(float2 uv : TEXCOORD0) : COLOR0
{
    float result = 0;
    for (int i = -2; i <= 2; i++) {
        float2 offset = float2(i, 0) * TexelSize; // horizontal pass
        result += tex2D(SilhouetteTex, uv + offset).r * weights[i+2];
    }
    return float4(result, result, result, 1);
}

// Outline extraction
float4 OutlineExtractPS(float2 uv : TEXCOORD0) : COLOR0
{
    float blurred = tex2D(BlurredTex, uv).r;
    float original = tex2D(OriginalTex, uv).r;
    float outline = saturate(blurred - original);
    return float4(OutlineColor.rgb, outline * OutlineColor.a);
}
```

**Pros:**
- Very cheap with separable blur: O(2N) samples total
- Soft, aesthetically pleasing glow
- Downsampling to 1/4 res makes a 4px kernel act like a 16px outline

**Cons:**
- Soft/gradient edges, not crisp - looks like a glow, not a hard outline
- Width control is imprecise (tied to blur sigma)
- Can't produce a hard-edged outline without thresholding (which re-introduces aliasing)

**Performance:** 2 fullscreen passes with 5 samples each = 10 samples total. Very cheap.

**Occlusion:** Same as dilation - mask generation is independent.

### 5. Normal Extrusion (Current Approach, Refined)

**How it works (fix for variable thickness):**

Extrude in clip space instead of object space. Multiply extrusion by `pos.w` to compensate for perspective division:

```hlsl
float4 pos = mul(WorldViewProj, float4(Position, 1.0));
float2 screenNormal = normalize(mul((float2x2)WorldViewProj, Normal.xy));
pos.xy += screenNormal * OutlineWidth * pos.w;
output.Position = pos;
```

This makes outline thickness uniform in screen pixels at any depth.

**Pros:**
- Minimal change to existing code
- No render targets needed
- Works entirely in the DIP hook

**Cons:**
- Still geometry-dependent at concave silhouettes and mesh part boundaries
- Gaps at separate body parts (WoW characters have separate meshes for armor, capes, etc.)
- Still requires batch reordering for occlusion

---

## Comparison Matrix

| | Width uniformity | Max width | Quality | Passes | Render targets | Complexity |
|---|---|---|---|---|---|---|
| **Dilation** | Uniform | ~8px | Good (square corners) | 1 fullscreen + 1/unit | 2-3 RGBA8 | Medium |
| **JFA** | Uniform, circular | Unlimited | Excellent, AA | log2(R) + 2 | 2 RG16F + 1 mask | Medium-High |
| **Sobel** | 1px only | 1-2px | Crisp but thin | 1 fullscreen + 1/unit | 1 R8 | Low |
| **Gaussian blur** | Soft gradient | ~16px (at 1/4 res) | Soft glow | 3 fullscreen + 1/unit | 3 RGBA8 | Medium |
| **Normal extrusion** | Non-uniform | ~4px | Variable | 3/unit in DIP | 0 | Low |

---

## Architectural Insight: Two-Phase Separation

All screen-space techniques (1-4) share a two-phase architecture that differs fundamentally from the current normal-extrusion approach:

**Phase A - Silhouette mask generation (in DIP hook, per-unit)**
- For alive targets: render unit geometry with depth test ON against scene depth → writes to RT_Silhouette
- For dead targets: render with depth test OFF → writes to RT_Dead
- This is where the 3 occlusion requirements are enforced

**Phase B - Outline generation + composite (in EndScene, once per frame)**
- Dilate/JFA/blur the mask → extract outline ring → alpha-blend over backbuffer
- This is purely 2D, knows nothing about depth

This separation means you can **swap the outline renderer** (dilation vs JFA vs blur) without touching occlusion logic at all.

### The Remaining Hard Problem: Requirement 2

Requirement 2 (other units don't occlude outlines) is the hardest to satisfy. It requires that when generating the silhouette mask for alive targets, the depth test uses a **terrain-only depth buffer** that excludes other characters. Two approaches:

**A. Terrain-only depth buffer (cleanest):** Create a secondary D24S8 surface. During DIP, when WoW draws terrain/WMO/game objects, also render a depth-only pass into this secondary buffer. When rendering outline silhouettes, bind this buffer instead of the scene depth.

**B. Keep batch reordering (current approach):** `model_hook.zig` already moves outline targets to render first in the M2 batch list. At that point, only terrain depth exists. Simpler but couples outline rendering to draw order.

---

## Recommendation

**JFA with batch reordering for Req 2.**

Rationale:
- Batch reordering already solves Req 2 without needing a secondary depth buffer - outline targets render when only terrain depth exists
- JFA gives the best outline quality (uniform, circular, anti-aliased, any width) at O(log2(N)) cost
- The outline width of 2-3px only needs ~2 JFA passes - nearly free
- Glow/pulse effects come for free if desired
- Everything is SM2.0 compatible, let alone SM3.0
- The silhouette mask pass replaces the current pass 1+2 (stencil body + normal extrusion) with a simpler "render flat color to RT"
- The stencil bit for preventing later units from painting over outlines still works alongside this

### Concrete Implementation Plan

**Resources to create at device creation/reset:**
```
RT_Silhouette:  RGBA8, screen size - mask for all outline targets
RT_JFA_A:       RG16F, screen size - JFA ping-pong buffer A
RT_JFA_B:       RG16F, screen size - JFA ping-pong buffer B
```

**Hook intercept points:**
```
EndScene (start of hook):
  - Clear RT_Silhouette

DrawIndexedPrimitive (when rendering_outline):
  - Save current RT and DS
  - Bind RT_Silhouette as render target (keep scene depth for alive, unbind for dead)
  - Render unit as flat color (category-colored)
  - Restore original RT and DS
  - Write stencil bits as before (for unit-over-outline prevention)
  - Render normal model (pass 3 equivalent)

EndScene (end of hook, before calling original):
  - Run JFA: init pass → flood passes → decode+composite as fullscreen quad
  - Alpha-blend outline over backbuffer
```

**Critical D3D9 state management for outline passes:**
```
Save before outline pass:
  GetRenderTarget(0, &savedRT0)
  GetDepthStencilSurface(&savedDS)
  GetVertexShader(&savedVS)
  GetPixelShader(&savedPS)
  GetRenderState(D3DRS_ZENABLE, ...)
  GetRenderState(D3DRS_ALPHABLENDENABLE, ...)
  GetRenderState(D3DRS_STENCILENABLE, ...)
  GetRenderState(D3DRS_COLORWRITEENABLE, ...)
  GetRenderState(D3DRS_ZWRITEENABLE, ...)
  GetRenderState(D3DRS_DEPTHBIAS, ...)
  Viewport, stream sources, vertex declaration, index buffer

Restore all after outline composite.
```

---

## Additional References

- "Inking the Cube" (GPU Gems 1, Chapter 11, Everitt) - screen-space dilation
- "Advanced Techniques in Real-Time Rendering" (GDC 2011, de Carpentier) - screen-space outlines
- "Post-Processing Effects in Games" (GDC 2013, Wihlidal) - Sobel ID-buffer approach
- Unreal Engine 4 custom depth/stencil outline documentation
- https://ameye.dev/notes/rendering-outlines/ - "5 Ways to Draw an Outline"
- https://linework.ameye.dev/soft-outline/ - soft outline documentation
- https://www.codeproject.com/Articles/128527/Stencil-Buffer-Glows-Part-1
- https://www.codeproject.com/Articles/156323/Stencil-Buffer-Glows-Part-2
- https://www.tomlooman.com/unreal-engine-soft-outline/
- https://aras-p.info/texts/D3D9GPUHacks.html - D3D9 GPU hacks reference
- https://ameye.dev/notes/edge-detection-outlines/ - edge detection outlines
- https://www.videopoetics.com/tutorials/pixel-perfect-outline-shaders-unity/ - pixel-perfect outlines
