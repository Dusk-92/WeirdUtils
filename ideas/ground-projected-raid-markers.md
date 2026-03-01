# Ground-Projected Raid Markers

**Goal:** Render placeable raid markers (like Wrath+) that project onto the ground as area indicators.

**Status:** Research complete, implementation pending

---

## What We Have

### D3D9 Rendering Infrastructure
- **File:** `src/outline/d3d9_hook.zig`
- Render target management (silhouette RT, JFA ping-pong buffers)
- Shader assembly via D3DX (PS 3.0)
- Fullscreen quad rendering with `DrawPrimitiveUP`
- Complete state save/restore around custom passes
- Hooks: EndScene, DrawIndexedPrimitive, Reset

### Model Rendering Hooks
- **File:** `src/outline/model_hook.zig`
- `CM2SceneRenderDraw` hook — batch reordering for depth control
- `CM2Scene_DrawBatchProjected` hook — per-batch interception
- Access to render context and model pointers
- Batch reordering ensures outline targets render when only terrain+WMO depth exists

### Render Pipeline Documentation
- **File:** `docs/RENDER_ARCHITECTURE.md`
- Terrain renderer: `CullAndProcessWorldChunks` (0x00683040)
- WMO renderer: `ProcessStaticObjectsCulling` (0x00683bf0)
- M2 model pipeline fully mapped
- Depth buffer control via hook ordering

### Outline Rendering Research
- **File:** `docs/outline-rendering-research.md`
- JFA (Jump Flood Algorithm) for distance-field outlines
- Stencil + blur techniques (Valve L4D style)
- Screen-space dilation approaches
- All SM 3.0 compatible

### UnitXP SP3 Reference
- **Path:** `/media/storage/projects/UnitXP_SP3_Orig/UnitXP_SP3/`
- **Key file:** `Vanilla1121_functions.h`
- `vanilla1121_worldToScreen(C3Vector& world)` — world → screen projection
- `CWorld_Intersect()` — raycast through world geometry
- `vanilla1121_unitPosition()` — unit world position
- `vanilla1121_getCameraPosition()` — camera world position

### WoWee Terrain Renderer Reference
- **Path:** `/media/storage/projects/WoWee/src/rendering/terrain_renderer.cpp`
- Modern OpenGL terrain rendering with multi-layer textures
- Frustum culling, LOD, shadow mapping
- Good reference for understanding terrain data structures

---

## What's Missing

### 1. Terrain Height Query
```c
// Need: Get terrain Z at world (X, Y)
float GetTerrainHeight(float worldX, float worldY);
```

**Options:**
- Reverse engineer WoW's internal terrain height function
- Use `CWorld_Intersect()` with vertical ray: `(x, y, +1000) → (x, y, -1000)`
- ADT tile parsing (complex, requires MPQ access)

### 2. Terrain Normal Query
```c
// Need: Get terrain normal at world (X, Y) for quad orientation
C3Vector GetTerrainNormal(float worldX, float worldY);
```

**Options:**
- Sample height at 4 neighboring points, compute normal
- Reverse engineer WoW's internal function

### 3. Depth Buffer as Texture (for projected decals)
```c
// Need: Access depth buffer as readable texture
IDirect3DTexture9* GetDepthAsTexture();
```

**D3D9 approaches:**
- `INTZ` / `RAWZ` format hack (requires driver support)
- `D3DFMT_D24S8` → `D3DFMT_D24X8` with `INTZ` fourcc
- Render depth to separate RT during terrain pass
- See: https://aras-p.info/texts/D3D9GPUHacks.html

---

## Implementation Options

### Option A: Screen-Space Marker (Simplest)

**Complexity:** Low  
**Visual Quality:** Basic (icon on screen, no ground conformity)

**Implementation:**
1. Hook raid target array at `0x00B71368` (8 GUIDs)
2. Get marked unit's world position via `vanilla1121_unitPosition()`
3. Project to screen via `vanilla1121_worldToScreen()`
4. Draw icon sprite in EndScene at screen position
5. Optional: Depth test against terrain depth buffer

**Pros:**
- Minimal implementation
- Uses existing infrastructure
- No terrain queries needed

**Cons:**
- Marker doesn't conform to terrain
- Looks like a floating icon, not ground projection
- No "area on the ground" effect

---

### Option B: Projected Ground Decal (Recommended)

**Complexity:** Medium  
**Visual Quality:** Good (conforms to terrain, area indicator)

**Implementation:**
1. Store marker world positions (from raid target array or click events)
2. In EndScene, after terrain+WMO depth written:
3. For each active marker:
   - Bind depth buffer as texture (INTZ hack or separate RT)
   - Render fullscreen quad with decal shader
   - Shader reconstructs world position from depth
   - If within marker radius, output marker color/texture
   - Distance fade at edges for soft boundary

**Decal Shader (HLSL SM 3.0):**
```hlsl
// Uniforms set by CPU
float3 MarkerCenter;    // World position
float  MarkerRadius;    // In world units
float4 MarkerColor;     // RGBA
float2 ScreenSize;      // For UV calculation

// Depth buffer bound to s0
sampler2D DepthSampler : register(s0);

float4 DecalPS(float2 uv : TEXCOORD0) : COLOR
{
    // Read depth, reconstruct world position
    float depth = tex2D(DepthSampler, uv).r;
    float3 worldPos = ReconstructWorldPosition(uv, depth);
    
    // Distance from marker center (XZ plane)
    float2 offset = worldPos.xz - MarkerCenter.xz;
    float dist = length(offset);
    
    // Soft falloff
    float alpha = saturate(1.0 - (dist / MarkerRadius));
    alpha = smoothstep(0.0, 0.3, alpha); // Soft edge
    
    // Output
    return float4(MarkerColor.rgb, MarkerColor.a * alpha);
}
```

**Pros:**
- Conforms to terrain contours
- Looks like ground projection
- Can support multiple markers
- Soft edges for aesthetic

**Cons:**
- Requires depth buffer access (driver-dependent)
- More complex shader setup
- Per-marker render pass overhead

---

### Option C: World-Space Quad (Best Conformity)

**Complexity:** High  
**Visual Quality:** Best (actual geometry on terrain)

**Implementation:**
1. Create marker quad mesh (4 vertices, 2 triangles)
2. Hook `CM2SceneRenderDraw` to inject custom geometry
3. For each marker:
   - Query terrain height at marker position
   - Query terrain normal for orientation
   - Position quad at terrain height, orient to normal
   - Add to render batch with marker texture
4. Render as part of M2 batch with depth testing

**Pros:**
- Perfect terrain conformity
- Actual geometry, not shader trick
- Proper depth testing with other objects

**Cons:**
- Requires terrain height/normal queries
- More complex geometry management
- Hook injection into render pipeline

---

## Recommended Path

### Phase 1: Proof of Concept (Screen-Space)
1. Implement basic screen-space marker rendering
2. Hook raid target array, project positions
3. Draw simple circle/icon at screen position
4. Verify hook integration works

**Estimated effort:** 1-2 hours

### Phase 2: Ground Decal (Primary Target)
1. Implement INTZ depth texture hack
2. Write decal projection shader
3. Add marker position storage
4. Render projected circles on terrain

**Estimated effort:** 4-6 hours

### Phase 3: Polish
1. Add marker textures (skull, cross, square, etc.)
2. Soft edge falloff
3. Multiple marker colors
4. Optional: Click-to-place interface

**Estimated effort:** 2-3 hours

---

## Key Files to Create/Modify

### New Files
```
src/marker/
├── marker_tracker.zig    # Track active markers, positions
├── marker_decal.zig      # Decal rendering shader + pipeline
├── marker_hooks.zig      # Raid target array hooks
└── marker_types.zig      # Data structures
```

### Modified Files
```
src/outline/d3d9_hook.zig  # Add depth texture creation
src/outline/types.zig      # Add depth texture format constants
src/main.zig               # Initialize marker system
```

---

## External References

### D3D9 Depth Buffer Hacks
- https://aras-p.info/texts/D3D9GPUHacks.html
- INTZ / RAWZ format for reading depth as texture

### Decal Rendering Techniques
- Valve L4D Glow Effect (stencil + blur): https://developer.valvesoftware.com/wiki/L4D_Glow_Effect
- Unreal Engine deferred decals: https://docs.unrealengine.com/4.27/en-US/RenderingAndGraphics/DeferredRendering/

### WoW 1.12.1 Internals
- wowdev.wiki for ADT terrain format
- UnitXP_SP3 for function signatures and calling conventions

---

## Notes

- Raid markers in Wrath+ use ground-projected circles with icon in center
- Our outline system already has the render target / shader infrastructure
- Depth buffer access is the main technical challenge for Option B
- Option A is good for quick testing, Option B is the production target
