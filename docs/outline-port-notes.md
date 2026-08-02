# Outline Port Notes

Pure Zig reimplementation of the WoW 1.12.1 unit outline system, ported from the earlier Idris C/C++ reference implementation (`reference/c_overlay/`, not included in this repo).

## Hooked Functions

### Model pipeline (inline hooks via `libs/hook`)

| Address      | Function                          | Convention   | Prologue | Fixups | Notes |
|-------------|-----------------------------------|-------------|----------|--------|-------|
| `0x0070b360` | `CM2SceneRenderDraw`              | `__thiscall` | 9 bytes  | none   | Batch reordering for outline priority |
| `0x00710b90` | `CM2Model_ManageRenderListNode`   | `__thiscall` | 6 bytes  | none   | Classifies models on render-list add |
| `0x0070cb30` | `CM2Scene_DrawBatchProjected`     | `__fastcall` | 6 bytes  | none   | Flags DIP hook for outline rendering |

**Prologue verification** (Ghidra, WoW.exe 1.12.1 build 5875):

- `0x0070b360`: `55 8B EC 81 EC 80 00 00 00` - `PUSH EBP; MOV EBP,ESP; SUB ESP,0x80`. Boundaries at +1, +3, +9. The `SUB ESP,0x80` is a 6-byte instruction (81 EC + imm32) spanning offset +3..+9, so 6-byte overwrite is **unsafe** - changed to 9.
- `0x00710b90`: `55 8B EC 8B 45 08` - `PUSH EBP; MOV EBP,ESP; MOV EAX,[EBP+8]`. Boundaries at +1, +3, +6. Clean 6-byte boundary.
- `0x0070cb30`: `55 8B EC 83 EC 10` - `PUSH EBP; MOV EBP,ESP; SUB ESP,0x10`. Boundaries at +1, +3, +6. Clean 6-byte boundary.

All three use `buildFastcallToCdeclThunk` to bridge to `callconv(.c)` detour functions (since `__thiscall` is `__fastcall` with unused EDX).

### D3D9 (vtable patching via dummy device)

| VTable Index | Method                    | Purpose |
|-------------|---------------------------|---------|
| 42           | `EndScene`                | Per-frame object scan, stencil clear |
| 82           | `DrawIndexedPrimitive`    | Three-pass stencil outline rendering |
| 16           | `Reset`                   | Force D24S8 depth/stencil format |

Vtable obtained by creating a temporary `IDirect3DDevice9` via `Direct3DCreate9` → `CreateDevice` with a hidden window.  All D3D9 devices share the same vtable, so patching affects the game's device.

## Outline Rendering (DIP hook)

Three-pass stencil approach per outline model:

1. **Pass 1 - Mark body**: Draw original geometry to stencil buffer (bit 0), no colour write.
2. **Pass 2 - Draw outline**: Screen-space vertex shader expands vertices along normals. Stencil test rejects body pixels. Write outline bit 1. Dead players disable depth test (through-wall); targets/raid marks respect depth.
3. **Pass 3 - Normal draw**: Restore all state, draw model normally on top.

## Vertex Shader

Compiled at runtime via `D3DXAssembleShader` from `d3dx9_43.dll` (loaded dynamically).  Falls back to no outlines if the DLL isn't present.

Format: `vs_2_0`, uses WoW's bone matrix constants (`c[idx+31..33]`), view-projection at `c2-c5`, custom constants at `c251` (bone scale) and `c252` (pixel thickness).

Pixel shader: `ps_3_0`, outputs solid colour from `c0`.

## Key Offsets

| Address/Offset | Purpose |
|---------------|---------|
| `0x00B41414`  | Object Manager pointer |
| `+0xAC`       | First object in linked list |
| `+0xA4`       | Base for next-object traversal |
| `+0xC0`       | Local player GUID (from ObjMgr) |
| `0x00B71368`  | Raid target GUID array (8 × 8 bytes) |
| `0x515970`    | `UnitGUID(__fastcall, string_ECX→EAX:EDX)` |
| `0x464870`    | `GetObjectByGUID(__stdcall, lo_stack, hi_stack→EAX)` - NOT fastcall! |
| `0x6061E0`    | `UnitReaction(__thiscall, player_ECX, unit_stack→int)` |
| model+`0x28`  | Direct owner object pointer |
| model+`0x3C0` | Callback owner object pointer |
| ctx+`0x3310`  | Model pointer in render context |

## Category Priority

1. **Target** (golden amber `#FFC800`) - current target, 2.25px outline
2. **Raid-marked** (per-icon colour) - units with raid icons 1-8, 1.5px
3. **Dead player** (cyan `#00FFFF`) - deceased friendly players, 2.5px, through walls

## Per-frame Flow

1. `EndScene` fires → `tracker.scanObjects()` rebuilds GUID tracking → stencil cleared
2. Next frame: `ManageRenderListNode` classifies models → `DrawBatchProj` sets flags → `DIP` does three-pass rendering
3. One-frame latency for tracking updates (imperceptible)

## Differences from Reference

- No `std::unordered_set`/`std::unordered_map` - fixed arrays with linear search (max 64 dead GUIDs, 8 raid marks, 256 outline models).
- No `CriticalSection` - all hooks run on the main WoW thread; no synchronisation needed.
- No MinHook - uses the project's existing `libs/hook` inline hook library.
- Object scanning is frame-based (EndScene), not event-driven (no separate Idris runtime thread).
- Shader loading uses dynamic `d3dx9_43.dll` lookup; gracefully disabled if absent.
