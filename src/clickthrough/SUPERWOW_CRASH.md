# SuperWoWhook + Timber UnitBuff Crash

## Bug

SuperWoWhook.dll crashes at DLL offset 0x1688 (`MOVZX ESI, word [ESI+EAX*2]`)
when UnitBuff is called for another player who has no buff in the queried slot.
Not a WeirdUtils or Timber bug -- root cause is a data error in SuperWoWhook's
inline patching template.

## Root Cause

SuperWoWhook's `SuperWoW_BuildUnitBuffHook` (0x10002460) patches UnitBuff's
return epilogues with CALL instructions that redirect to DLL formatter blocks.
Each CALL site has a paired return-landing patch that rewrites the bytes after
the CALL with proper register-restore code (POP EDI; POP ESI; POP EBX; ...).

Template entries 88-103 contain 8 CALL+landing pairs. All 7 first pairs follow
the pattern `landing = CALL_addr + 5`:

| Pair | CALL addr  | Landing    | OK?            |
|------|------------|------------|----------------|
| 0    | 0x519AF1   | 0x519AF6   | +5, correct    |
| 1    | 0x519B19   | 0x519B1E   | +5, correct    |
| 2    | 0x519C48   | 0x519C4D   | +5, correct    |
| 3    | 0x519C6D   | 0x519C72   | +5, correct    |
| 4    | 0x519708   | 0x51970D   | +5, correct    |
| 5    | 0x519729   | 0x51972E   | +5, correct    |
| 6    | 0x51981D   | 0x519822   | +5, correct    |
| **7**| **0x51983B** | **0x519830** | **-16, WRONG** |

Pair 7's landing is at 0x519830 (should be 0x519840). The template dword at
`0x1001B240 + 103*4 = 0x1001B3DC` contains `0x00519830` instead of `0x00519840`.

### What happens

The "other player no buff" path (JE at 0x519803 taken -> 0x519829):

1. `lua_pushnil` called at 0x51982B, returns to 0x519830
2. Code at 0x519830 was patched with `5F 5E 5B 8B` (meant for 0x519840)
3. This creates: `POP EDI; POP ESI; POP EBX; MOV EBP,[EDX+0]` -- the `8B` from
   the patch combines with `6A 00` from the original code to form `MOV EBP,[EDX]`
4. EBP is overwritten with whatever EDX points to (addon string data: "AltA")
5. `lua_pushnumber` called at 0x519836 with shifted stack
6. CALL at 0x51983B jumps to formatter `UnitBuff_ReturnFieldU16_3vals` (0x10001680)
7. Formatter reads `[EBP-0x10]` with EBP = 0x616C7441 -> ACCESS_VIOLATION

Meanwhile, 0x519840 (the actual CALL return address) is never patched and has
`00 00 5B 8B E5 5D C3` -- `ADD [EAX],AL` would crash even if the formatter survived.

### Why intermittent

The crash only triggers when:
- Querying buffs on another player (not self) -- self uses Timber's TW path
- That player has no buff in the queried slot -- triggers the "no buff" JE path
- EDX happens to point to readable memory -- if [EDX] faults, different crash site

### Why Timber-specific reports

- On vanilla, the same bug exists but is less visible: the "other player" path is
  rarely exercised by addons compared to the "self" path
- On Timber, the "self" path is redirected through TW code (bypassing SuperWoWhook),
  so addons calling UnitBuff("player", N) never hit SuperWoWhook's patches -- only
  UnitBuff("target", N) etc. can trigger it

## Fix

Single byte fix in SuperWoWhook.dll: change the dword at file offset corresponding
to VA `0x1001B3DC` from `0x00519830` to `0x00519840`.

## Crash Signature

- ACCESS_VIOLATION at SuperWoWhook offset 0x1688
- `MOVZX ESI, word [ESI + EAX*2]` with invalid address
- EBP = ASCII text (e.g. 0x616C7441 = "AltA") -- corrupted by MOV EBP,[EDX]
- Stack contains 0x00519840 and addon strings ("DBG:AceEvent20Frame")

## Ghidra Labels

SuperWoWhook.dll:
- `SuperWoW_BuildUnitBuffHook` (0x10002460)
- `UnitBuff_ReturnFieldU16_3vals` (0x10001680) -- crash site
- Template at 0x1001B240 (197 dwords), replacement data at local_328

WoW.exe (Timber):
- UnitBuff other-player path: 0x519780-0x519846
- JE at 0x519803: "no buff found" branch to 0x519829
- Two epilogues: 0x51981D (buff found, pair 6 OK), 0x51983B (no buff, pair 7 BROKEN)
