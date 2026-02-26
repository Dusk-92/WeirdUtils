# JFA Outline Banding Investigation

## Date: 2026-02-25

## Problem
Outlines rendered via the JFA pipeline have a "marching ants" pattern of missing outline pixels. The artifact depends on **which side of the camera** the target is on (screen-space position), not the left/right side of the model itself. Camera-angle dependent.

## What Was Ruled Out

### 1. Silhouette RT is clean (CONFIRMED)
Added `DEBUG_SHOW_SILHOUETTE` comptime flag in `d3d9_hook.zig` that skips JFA and composites the raw silhouette RT directly to the backbuffer. The silhouette was solid with no banding — the cached draw replay produces correct geometry. **Stale VB hypothesis is NOT the cause.**

### 2. JFA sentinel value (1.0, 1.0) → (-1.0, -1.0) (NO IMPROVEMENT)
Changed the JFA init shader sentinel from `(1.0, 1.0)` to `(-1.0, -1.0)` so unflooded pixels can't act as false seeds near the right screen edge. This did NOT fix the marching ants pattern. The sentinel is currently set to `(-1.0, -1.0)` in the code (uncommitted).

### 3. JFA pass count changes pattern but doesn't fix it
- `[2, 1]` → vertical bands of missing outline
- `[8, 4, 2, 1]` → marching ants alternating pattern (current uncommitted state)

### 4. Mid-DIP silhouette drawing corrupts render state (ABANDONED)
Attempted drawing silhouettes directly in DIP hook. Corrupts WoW's GxDevice state. Reverted.

### 5. Game object occlusion (FIXED, committed as 661e156)
Batch reorder puts outline targets last so depth buffer has full scene geometry when stencil marks are written.

## Current Uncommitted Changes in d3d9_hook.zig
- JFA steps changed from `[2, 1]` to `[8, 4, 2, 1]`
- JFA sentinel changed from `(1.0, 1.0)` to `(-1.0, -1.0)`
- `DEBUG_SHOW_SILHOUETTE` comptime flag added (currently `false`), with `debug_sil_ps` shader
- Debug shader had a cmp operand inversion bug that was fixed (`c0.w, c0.x` not `c0.x, c0.w`)

## Remaining Investigation — JFA Pipeline Bug

Since the silhouette is clean, the bug is in the JFA shaders (Phase 2). Possible causes:

### A. JFA propagation shader distance comparison logic
The propagation shader uses `cmp` (ps_3_0) which tests `>= 0` vs `< 0`. When `new_dist² == best_dist²` (exactly equal), `cmp` picks the OLD seed (`>= 0` branch). This tie-breaking might cause systematic bias where seeds from certain directions are always preferred, creating directional artifacts. Worth testing: swap `cmp` operands to prefer new seed on ties, or add a small epsilon.

### B. dp2add precision on DXVK
`dp2add r2.z, r2, r2, c1.x` computes `r2.x*r2.x + r2.y*r2.y + 0.0`. DXVK translates this to Vulkan — there may be precision differences vs native D3D9 that affect distance comparisons, especially for pixels equidistant from multiple seeds.

### C. Neighbor sampling at texture edges
When `mad r4.xy, offset, step_uv, v0.xy` goes outside [0,1], CLAMP addressing returns the edge texel. This could feed stale/wrong seed UVs into the comparison. Clamping the sample coordinate to valid range before comparison could help.

### D. The JFA algorithm itself may not suit this use case
Consider alternative approaches:
- **Screen-space dilation** (iterative morphological expand of silhouette) — simpler, no distance field needed
- **Gaussian blur difference** — blur silhouette, subtract original, threshold
- **Sobel/edge detection** on the silhouette RT
- Docs in `/media/storage/projects/zig/weirdutils/docs/` describe these alternatives
- Reference articles: ameye.dev "5 ways to draw an outline", Ben Golus "Quest for Very Wide Outlines"

## Key Files
- `src/outline/d3d9_hook.zig` — D3D9 hooks, JFA pipeline, all shaders
- `src/outline/model_hook.zig` — batch reordering, rendering_outline flag
- `src/outline/tracker.zig` — per-frame model tracking
- `src/outline/types.zig` — D3D9 constants
- `reference/c_overlay/d3d9_hook.cpp` — C reference (uses 3-pass shell extrusion, not JFA)

## Build / Environment
- `zig build` from `/media/storage/projects/zig/weirdutils/`
- Zig 0.15, target x86-windows-msvc (32-bit DLL injected into WoW 3.3.5)
- Linux host (Arch, kernel 6.16.1), game via Wine/DXVK
- Git last commit: `661e156` (game object occlusion fix)
