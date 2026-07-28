# MPQ Load Order — WoW 1.12.1

`MPQ_InitializeArchives` (0x403740) loads in two phases.

## Phase 1 — Base archives (loaded by index)

Filename table at `0x82e12c`:

| Index | Archive |
|-------|---------|
| 0 | model.MPQ |
| 1 | texture.MPQ |
| 2 | terrain.MPQ |
| 3 | wmo.MPQ |
| 4 | sound.MPQ |
| 5 | misc.MPQ |
| 6 | interface.MPQ |
| 7 | fonts.MPQ |
| 8 | speech.MPQ |
| 9 | dbc.MPQ |
| 10 | speech2.MPQ |

Each opened via `OpenMPQArchiveWithPaths` (0x403b00) which tries `Data\name` then `..\Data\name`.

## Phase 2 — Patch archives

- `MPQArchiveEnumerator` (0x4039b0) discovers `patch-?.MPQ` files via glob
- Then opens `patch.MPQ` and any discovered `patch-X.MPQ` archives

## Search order at file lookup time

`File_FindInArchive` (0x6549a0) searches the global archive array at `0x8826b4` recursively — later-registered archives (patches) are checked first. The array is searched from `count-1` down to `0`, so patches override base content.

## Global archive array

```
Struct at 0x8826b4:
  +0x00 [0x8826b4]: capacity
  +0x04 [0x8826b8]: count
  +0x08 [0x8826bc]: array_ptr (SArchive**)
  +0x0C [0x8826c0]: growth_incr
```