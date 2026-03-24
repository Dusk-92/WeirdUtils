# Particle System SSE Optimization Research

## Overview

Three related functions form the particle rendering pipeline, totaling ~3% CPU:

| Function | Address | CPU% | Size | FPU ops | CALLs | Convention |
|----------|---------|------|------|---------|-------|------------|
| RenderParticleSprites | 0x7B2A50 | 1.73% | ~1700 bytes | 182 | 6 | __thiscall RET 0x8 |
| calculateColorValues | 0x7B9B10 | 0.63% | ~350 bytes | 39 | 1 | __thiscall RET 0x18 |
| SetupParticleRendering | 0x7B3D20 | ~0.2% | ~720 bytes | 6 | 7 | __thiscall RET 0x4 |
| ProcessActiveParticles | 0x7B5A10 | 0.55% | ~1376 bytes | 49 | 14 | __stdcall RET 0x8 |

## Call Graph

```
RenderParticleSprites (0x7B2A50) — per-emitter, called from render pass
  ├─ calculateColorValues (0x7B9B10) — particle color interpolation
  ├─ 0x58A230 — rendering state setup
  ├─ 0x7BCA80 — mat*vec3 transform (already SSE'd in frustumCull pattern)
  ├─ 0x7BE490 — rotation/sin-cos setup
  └─ 0x7BCB40 — matrix function

SetupParticleRendering (0x7B3D20) — builds transform matrices
  ├─ 0x58B0B0 — rendering setup
  ├─ 0x58B050 — rendering setup
  └─ 0x7BC6A0 — multiplyMatrix4x4 (×5, already SSE'd in clip_sse.zig)

ProcessActiveParticles (0x7B5A10) — per-emitter particle simulation
  ├─ 0x7B5550 — particle helper (×2)
  ├─ 0x7B2680 — particle helper
  ├─ 0x7B28E0 — particle helper
  ├─ 0x7B5880 — particle helper
  └─ ... (14 total calls, complex simulation logic)
```

## RenderParticleSprites (0x7B2A50) — Detailed Analysis

### Assembly reference: `decompiled/asm_RenderParticleSprites.txt`

**Calling convention**: `__thiscall(ECX=emitter, stack=param1, param2)`, RET 0x8

### Structure

1. **Early-out checks** (0x7B2A5E-0x7B2B0B):
   - Check `emitter+0x1B4` vs `0x7FF9D8` (visibility threshold)
   - Check `emitter+0x1C0` vs `0x7FFD74` (alpha threshold)
   - Compute `emitter+0x1B0 * param1[0x1C]`, clamp to [0x7FFD74, 0x7FFE58]
   - Compute particle count from float → integer bits

2. **Color computation** (0x7B2B41):
   - CALL `calculateColorValues` (0x7B9B10) — 39 FPU ops, pure math

3. **Rendering setup** (0x7B2B46):
   - CALL `0x58A230` — sets render state

4. **Transform** (0x7B2BBE):
   - CALL `0x7BCA80` (mat*vec3) — transforms particle position

5. **Billboard vertex computation** (0x7B2BF3-0x7B2DEB or 0x7B2D10-0x7B2F0E):
   - Two code paths based on particle type (flags at emitter)
   - Path A (0x7B2BF3): axis-aligned billboards — scale + offset computation
   - Path B (0x7B2D10): world-oriented particles — full rotation via lookup table at 0x87D710
   - Both paths: ~50 FPU ops each (multiply, add, subtract for 4 corner vertices)

6. **Optional rotation** (0x7B2E25):
   - CALL `0x7BE490` — builds rotation matrix from angle
   - Followed by 8×8 FPU multiply block for rotating corner offsets

7. **Vertex output** (0x7B2F30-0x7B3041):
   - CALL `0x7BCB40` — final vertex transform/output
   - Writes to vertex buffer

### SSE Opportunities

**calculateColorValues** (biggest single-function win):
- 39 FPU ops in 350 bytes. Pure scalar math: interpolation, multiply, add, clamp.
- Color = base + (delta * time * scale). 4-component (RGBA) computation.
- Perfect for V4: process all 4 color channels simultaneously.
- Single CALL at end (0x73F90A) — likely a clamp/validation helper.
- Convention: __thiscall(ECX=colorCtx), 6 stack params (RET 0x18).

**Billboard vertex math** (per-particle, hot inner loop):
- 4 corner vertices, each = center ± halfWidth * right ± halfHeight * up
- Currently scalar x87: 4 × (3 multiplies + 3 adds) = 24 FPU ops per particle
- SSE: broadcast halfWidth/halfHeight, V4 multiply-add for xyz+w simultaneously
- The two code paths (axis-aligned vs world-oriented) need separate SSE versions

**Rotation block** (when particles rotate):
- 8 multiplies + 8 adds for 2D rotation of corner offsets
- SSE: 2 operations (broadcast sin/cos, V4 multiply-add)

## calculateColorValues (0x7B9B10) — Detailed Analysis

### Assembly reference: `decompiled/asm_calculateColorValues.txt`

**Calling convention**: `__thiscall(ECX=colorCtx, stack: time, scale, outAlpha, outR, outG, outB)`, RET 0x18

**Algorithm** (from assembly):
1. Compute `t = (time - ctx+0x2C) * ctx+0x30 * 0x808AAC + 0x807A3C`
2. Interpolate: `value = (float)ctx[+4] * t + (float)ctx[+3]`
3. Scale by param: `value *= scale`
4. Add 0.5 (rounding): `value += 0x8029CC`
5. Store to output as integer (FISTP)
6. Repeat for RGB channels (offsets +0x04/+0x08/+0x0C in ctx)
7. Alpha: separate path with different scaling
8. CALL 0x73F90A — clamp/validate
9. Return via 6 output pointers

**SSE approach**: Load all 4 channel bases as V4, load deltas as V4, single V4 multiply-add chain, then scatter to output pointers.

## SetupParticleRendering (0x7B3D20) — Detailed Analysis

### Assembly reference: `decompiled/asm_SetupParticleRendering.txt`

Already benefits from our SSE multiplyMatrix4x4. Remaining cost is matrix setup (writing identity matrices to stack) and 5 function calls. Not a high-value target — only ~0.2% after matmul optimization.

## Priority Order

1. **calculateColorValues** — pure math, 0.63% CPU, cleanest SSE candidate
2. **Billboard vertex math** (inside RenderParticleSprites) — per-particle, 4 vertices × 3 components
3. **Rotation block** — only when particles rotate, but cheap SSE win
4. **SetupParticleRendering** — low priority, already mostly SSE'd via matmul

## Implementation Plan

Create `src/transform44/particle_sse.zig` as a separate ReleaseFast compilation unit (same pattern as bone_sse.zig / clip_sse.zig). Export functions callable from transform44.zig detour hooks.

Phase 1: `calculateColorValues` SSE replacement
Phase 2: Billboard vertex computation (inline in RenderParticleSprites replacement)
Phase 3: Full RenderParticleSprites replacement (if phases 1-2 show good results)
