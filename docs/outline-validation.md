# Outline Validation Checklist

## Build

- [ ] `zig build` succeeds with no errors (x86 windows-msvc target)
- [ ] Output DLL present at `zig-out/lib/weirdutils.dll`

## Existing Feature Regression

- [ ] DLL loads without crash (inject into WoW 1.12.1)
- [ ] `/wu version` responds correctly
- [ ] `/wu test` calls C function and returns string
- [ ] Screenshot hook works (`/wu ss`, PNG output)
- [ ] Interact/loot bindings work (InteractNearest, LootAllCorpses)
- [ ] Addon loads on login (green "WeirdUtils loaded" message)

## Outline Subsystem

### Commands
- [ ] `/wu outline` shows ON/OFF status
- [ ] `/wu outline on` enables outlines
- [ ] `/wu outline off` disables outlines
- [ ] `/wu` help text includes outline commands

### Dead Player Outlines
- [ ] Dead friendly players in party/raid show cyan outline
- [ ] Outline is visible through walls (no depth test)
- [ ] Outline disappears when player is resurrected
- [ ] Skeleton corpses are NOT outlined

### Raid Mark Outlines
- [ ] Units with raid icons (Star through Skull) show coloured outlines
- [ ] Each icon has a distinct colour
- [ ] Outlines update when raid marks change
- [ ] Outlines respect terrain occlusion (depth test enabled)

### Target Outline
- [ ] Current target shows golden amber outline
- [ ] Outline changes when target changes
- [ ] Outline clears when target is deselected
- [ ] Outline respects terrain occlusion

### Rendering Quality
- [ ] Outlines are clean (no jagged edges or flicker)
- [ ] Outline thickness is consistent across distances
- [ ] Normal model renders correctly on top of outline
- [ ] No visible render state leakage to other models
- [ ] Non-outlined units don't cover outline pixels (stencil test)

### Performance
- [ ] No noticeable FPS drop in normal gameplay
- [ ] No FPS drop in 40-player raid with multiple outlines
- [ ] Frame rate stable when toggling outlines on/off

### Edge Cases
- [ ] D3DX DLL not present → outlines gracefully disabled (no crash)
- [ ] No targets tracked → zero overhead (fast path)
- [ ] `/wu outline off` → DIP hook passes through immediately
- [ ] Device Reset (resolution change) → shaders recreated properly

## Hook Prologue Verification (Ghidra)

Verified 2026-02-23 using Ghidra MCP against WoW.exe 1.12.1 (build 5875, 4,907,008 bytes).

### Method

Raw bytes read from each hook target address via `get_bytes`. Instruction boundaries decoded to confirm the `prologue_size` parameter passed to `hook.prepare()` lands on a clean instruction boundary. A mid-instruction cut would corrupt the trampoline — the copied bytes would decode as a different instruction when followed by the trampoline's JMP.

### Results

| Address | Function | Prologue bytes | Decoded | Boundary | Safe | Fixups |
|---------|----------|---------------|---------|----------|------|--------|
| `0x0070b360` | `CM2SceneRenderDraw` | `55 8B EC 81 EC 80 00 00 00` | `PUSH EBP; MOV EBP,ESP; SUB ESP,0x80` | +1,+3,**+9** | 9B | none |
| `0x00710b90` | `CM2Model_ManageRenderListNode` | `55 8B EC 8B 45 08` | `PUSH EBP; MOV EBP,ESP; MOV EAX,[EBP+8]` | +1,+3,**+6** | 6B | none |
| `0x0070cb30` | `CM2Scene_DrawBatchProjected` | `55 8B EC 83 EC 10` | `PUSH EBP; MOV EBP,ESP; SUB ESP,0x10` | +1,+3,**+6** | 6B | none |

### Fix applied

`CM2SceneRenderDraw` prologue changed from 6 to **9** bytes in `src/outline/model_hook.zig`. The original 6-byte value would have split the `SUB ESP, 0x80` instruction (opcode `81 EC` + 4-byte immediate, spanning offset +3 to +9). The trampoline would have executed `81 EC 80 E9 xx xx` as `SUB ESP, <corrupted>`, leading to stack corruption and a crash.

### No other changes needed

- All three prologues contain only register/memory instructions (no `E8 CALL` or `E9 JMP`), so `rel32_fixups` remains `&.{}`.
- The 4-byte NOP padding (bytes 5-8) at `0x0070b360` after the 5-byte `E9 JMP` is harmless — it is never executed (execution jumps to the detour thunk).
