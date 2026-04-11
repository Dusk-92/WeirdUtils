# weirdperformance

SSE optimization subsystem for WoW 1.12.1. Bone transforms, particle systems, frustum culling, file caching, timer fixes, and fast zlib via libdeflate. Enabled by default in build.

## WHERE TO LOOK

| File | Purpose |
|------|---------|
| `weirdperformance.zig` | Module entry, build integration |
| `bone_sse.zig` | Bone transformation via SSE SIMD |
| `particle_sse.zig` | Particle system SSE optimization |
| `clip_sse.zig` | Frustum culling with SSE |
| `cull_sse.zig` | Additional culling routines |
| `silicon_sse.zig` | LibSiliconPatch port |
| `entity_sse.zig` | Entity processing acceleration |
| `filecache.zig` | In-memory file caching |
| `inflate_hook.zig` | Compression hook, deflate integration |
| `timer_fix.zig` | High-resolution timer fixes |
| `libdeflate/` | Fast zlib replacement (libdeflate) |

## CONVENTIONS

- SSE intrinsics use `std.math.losslessCast` for float/int bit conversion
- All SSE code gated behind `has_sse41` compile check
- Filecache uses named mutex for thread-safe access
- Hook installation deferred to first render, not DLL attach

## ANTI-PATTERNS

- NEVER call SSE code without checking CPU feature support at runtime
- NEVER enable libdeflate hook before game engine init completes
- NEVER use filecache mutex during WoW UI thread - causes deadlocks

## NOTES

- libdeflate provides 2-5x decompression speedup over stock zlib
- Bone SSE assumes bone matrices are 16-byte aligned
- Timer fix resolves GetTickCount rollover on long sessions
- All hooks use per-feature named mutexes to prevent duplicate installation
