# WoW 1.12.1 CPU Profiling Analysis

Source: `perf.data.perfparser` (July 2025 recording via hotspot)
Exported: `cycles.out` (stack-collapsed format)

## Full CPU Time Breakdown

| % | Category | Notes |
|---|---|---|
| 33.18% | **Hooked WoW functions** | 38 hooks in transform44 module |
| 19.19% | GPU/Driver | d3d9.dll (DXVK) + amdvlk32.so -- untouchable |
| 18.74% | WoW long tail | ~2000+ functions each <0.15% -- not worth hooking |
| 13.15% | WoW mid-tier | 50 functions at 0.15-0.39% -- hookable but diminishing returns |
| 8.43% | Lua VM | lua_vm_execute, luaS_newlstr, etc. -- interpreter overhead |
| 5.38% | Unresolved | WoW.exe code not in Ghidra symbol map |
| 1.93% | Wine/System | ntdll, kernel32, wine internals |

## Hooked Functions (38 total, by self-time %)

### Already existed (6 hooks)
| % | Address | Name | Convention |
|---|---|---|---|
| 2.80% | 0x714260 | transformMatrix4x4 | thiscall RET 0x10 |
| 2.06% | 0x713d50 | findInterpolationIndices | thiscall RET 0x10 |
| 0.73% | 0x707680 | renderFrame | thiscall RET 0x4 |
| 0.44% | 0x713ea0 | interpolateAnimationKeyframes | fastcall RET 0x8 |
| - | 0x708900 | executeSceneRenderPass | thiscall RET 0x4 |
| - | 0x76FB00 | RenderTextureQuads | fastcall RET |
| - | 0x616620 | CMovement::Process | thiscall RET 0x8 |

### New perf-identified hotspots (28 hooks)
| % | Address | Name | Convention |
|---|---|---|---|
| 3.95% | 0x6318c0 | ClipPolygonToSinglePlane | stdcall RET 0x4 |
| 3.65% | 0x5ca2d0 | GetOrCreateCharacterGlyph | stdcall RET 0x8 |
| 1.73% | 0x7b2a50 | RenderParticleSprites | thiscall RET 0x8 |
| 1.57% | 0x6abc40 | processLinkedListCollision | thiscall RET 0x8 |
| 1.18% | 0x6afad0 | UpdateEntityAndChunksPositions | thiscall RET |
| 1.15% | 0x765650 | renderAllFrameLayers | thiscall RET 0x4 |
| 1.07% | 0x5ccbe0 | RenderTextToVertexBuffer | thiscall RET 0x18 |
| 1.02% | 0x58a3d0 | RenderComplexGeometry | stdcall RET 0x24 |
| 0.93% | 0x6c1f70 | updateEntitiesInBounds | thiscall RET 0x4 |
| 0.88% | 0x5cdf40 | updateTextFrameCounter | thiscall RET |
| 0.66% | 0x6816f0 | AddToSpatialGrid | thiscall RET |
| 0.65% | 0x7c29f0 | ray_tri_intersect_idx_ushort | stdcall RET 0x10 |
| 0.64% | 0x710b90 | ManageLinkedListNode | thiscall RET 0x4 |
| 0.63% | 0x7b9b10 | calculateColorValues | thiscall RET 0x18 |
| 0.61% | 0x686640 | SetVector3 | thiscall RET |
| 0.59% | 0x6b8c60 | PerformSpatialCulling | thiscall RET 0x8 |
| 0.59% | 0x6b88e0 | performCollisionDetection | thiscall RET 0x8 |
| 0.55% | 0x7b5a10 | ProcessActiveParticles | stdcall RET 0x8 |
| 0.53% | 0x404130 | CallbackIterator | stdcall RET 0x10 |
| 0.50% | 0x464890 | FindObjectByGUID | stdcall RET 0x8 |
| 0.49% | 0x632700 | RayTriangleIntersection | thiscall RET 0x20 |
| 0.48% | 0x70cb30 | DrawBatchProj | thiscall RET |
| 0.47% | 0x702000 | FindLuaFunction | stdcall RET 0x4 |
| 0.44% | 0x5a0f50 | RenderSpriteQuads | thiscall RET 0xc |
| 0.44% | 0x718960 | renderSceneNode | thiscall RET |
| 0.44% | 0x6cffc0 | generateTerrainChunk | thiscall RET |
| 0.43% | 0x593840 | D3D_SetTexture | thiscall RET 0x8 |
| 0.42% | 0x6b8b70 | checkBoundingBoxIntersection | stdcall RET 0x8 |

### Unresolved-callee hooks (4 hooks)
| % | Address | Name | Convention |
|---|---|---|---|
| ~0.5% | 0x7bdd60 | rotateMatrixByAxisAngle | thiscall RET 0xc |
| ~0.1% | 0x632460 | BuildTrianglePlanes | thiscall RET 0xc |
| ~0.2% | 0x7b3d20 | SetupParticleRendering | thiscall RET 0x4 |
| ~0.2% | 0x5ce0c0 | renderTextLine | thiscall RET 0x10 |

## Unhooked Mid-Tier (50 functions, 13.15% total)

Not worth individual hooks -- too small or too high-frequency (hook overhead would distort):

| % | Name | Why not hook |
|---|---|---|
| 0.39% | compareRenderItemsExtended | Sort comparator, millions of calls |
| 0.39% | GetCachedData | Cache accessor, extremely hot path |
| 0.39% | raycastPickObjects | Moderate frequency |
| 0.35% | inflateDecodeLiteralsAndLengths | Decompression, bursty |
| 0.34% | UpdateParticlePhysics | Per-particle, very hot |
| 0.34% | updateAnimationSystem | Could be interesting entry point |
| 0.32% | ClntObjMgrObjectPtr | Object lookup, called everywhere |
| 0.29% | multiplyMatrix4x4 | Tiny function, massive call count |
| 0.26% | quickSortArray | Sort impl, millions of comparisons |
| ... | (40 more at 0.15-0.31%) | |

## Key Insights

1. **GPU/Driver is 19%** -- nothing we can do about d3d9.dll/amdvlk overhead
2. **Lua VM is 8.4%** -- addon code execution, not optimizable from DLL side
3. **Frustum clipping (ClipPolygonToSinglePlane) is the #1 WoW hotspot at 3.95%** -- pure math, SSE candidate via binary patch (no hook overhead)
4. **Font rendering (GetOrCreateCharacterGlyph) is #2 at 3.65%** -- potential cache optimization
5. **Bone pipeline (t44 + findInterp + interpKf) totals ~5.3%** -- SSE interp hook overhead negates savings; binary patch or full t44 rewrite needed
6. **Hook overhead matters** -- for functions called >10k/frame (lerp, matrix multiply, sort comparators), detour trampoline cost (~30 cycles) exceeds any savings

## Files

- `cycles.out` -- raw stack-collapsed perf data
- `perf.data.perfparser` -- hotspot binary cache (5.3GB)
- Ghidra symbols: `/media/faststore/tmp/Dis/symbols.nm`
