# SuperWoWhook vs Timber: UnitBuff/UnitDebuff Patch Conflict

## Overview

Both Timber (modified WoW.exe) and SuperWoWhook.dll extend `Lua_UnitBuff` and
`Lua_UnitDebuff` to return extra values (spell ID, dispel type). SuperWoWhook
patches vanilla return sites that Timber has already moved or replaced, causing
stack corruption and crashes.

## What Each System Does

### Vanilla WoW (unmodified)
- `UnitBuff(unit, index)` returns 2 values: texture, count
- `UnitDebuff(unit, index)` returns 3 values: texture, count, dispelType

### Timber (TW_ extensions at 0xD06xxx)
- `UnitBuff` returns 3 values: texture, count, **spellID**
- `UnitDebuff` returns 4 values: texture, count, dispelType, **spellID**
- Implemented via JMP patches into TW_ code at 0xD06xxx

### SuperWoWhook (runtime code injection)
- Extends both functions to add similar extra return values
- Built for vanilla byte layout -- patches specific return epilogues
- Uses WriteProcessMemory at runtime to overwrite code

## UnitBuff Conflict (0x519500)

### Vanilla return path (found match, has icon):
```
519703: CALL 0x6F3810          ; lua_pushnumber(count)
519708: POP EDI                ; epilogue
519709: POP ESI                ; <-- SuperWoWhook patches 4 bytes here
51970A: MOV EAX, 0x2           ;     (replaces return count + epilogue)
51970F: POP EBX
519710: MOV ESP, EBP
519712: POP EBP
519713: RET                    ; returns 2 values
```

### Timber replaces this with:
```
519703: JMP 0x00D06585         ; -> TW_UnitBuff_PushDuration
  (0x519708-0x519713 is now dead code, never reached)
519714: MOV ESI, [EBP-0x4]    ; (nil icon path continues here)
519717: MOV ECX, ESI
...
```

### What TW_UnitBuff_PushDuration does (0xD06585):
```
D06585: CALL 0x6F3810         ; lua_pushnumber(count) -- was on FPU stack
D0658A: SUB ESP, 0x8
D0658D: MOV ECX, ESI
D0658F: MOV EAX, [EBP-0x24]  ; load saved spell ID (stashed by TW_Lua_UnitBuff_Extended)
D06594: MOV dword [EBP-0x18], EAX
D06597: FILD dword [EBP-0x18] ; convert to float
D0659A: FSTP qword [ESP]
D0659D: CALL 0x6F3810         ; lua_pushnumber(spellID)
D065A2: JMP 0xD066AF          ; -> ReturnConstant3_b (return 3)
```

**Conflict**: SuperWoWhook writes 4 bytes at 0x519709 -- dead code in Timber
(JMP at 0x519703 bypasses it). This specific patch is **harmless** since it
never executes.

## UnitDebuff Conflict (0x519860) -- THE CRASH

### Vanilla return path 1 (has dispel type string):
```
519AEC: CALL 0x6F3890          ; lua_pushstring(dispelType)
519AF1: POP EDI                ; epilogue
519AF2: POP ESI                ; <-- SuperWoWhook patches 4 bytes here
519AF3: MOV EAX, 0x3           ;     (replaces return count + epilogue)
519AF8: POP EBX
519AF9: MOV ESP, EBP
519AFB: POP EBP
519AFC: RET                    ; returns 3 values
```

### Timber replaces this with:
```
519AEC: JMP 0x00D065B4         ; -> TW_UnitDebuff_PushDispelType
  (0x519AF1-0x519AFC is dead code, never reached by original path)
519AFD: MOV ESI, [EBP-0xC]    ; (nil path starts here -- DIFFERENT CODE)
519B00: MOV ECX, ESI           ; <-- This is where 0x519AF2+0x0E lands!
519B02: CALL 0x6F37F0          ; lua_pushnil
...
```

**Conflict**: SuperWoWhook writes 4 bytes at **0x519AF2**. In vanilla this was
`POP ESI; MOV EAX, 0x3` (the return-3 epilogue). In Timber this is dead code
between the JMP at 0x519AEC and the nil path at 0x519AFD. SuperWoWhook writes
a relative jump here. The bytes are technically dead on the Timber happy path,
BUT if SuperWoWhook's other patches redirect execution INTO this dead zone,
the corrupted bytes execute and crash.

### Vanilla return path 2 (nil dispel, fallback):
```
519B14: CALL 0x6F37F0          ; lua_pushnil
519B19: POP EDI                ; epilogue
519B1A: POP ESI                ; <-- SuperWoWhook patches 4 bytes here
519B1B: MOV EAX, 0x3
519B20: POP EBX
519B21: MOV ESP, EBP
519B23: POP EBP
519B24: RET                    ; returns 3 values
```

### Timber replaces this with:
```
519B14: JMP 0x00D065D4         ; -> TW_UnitDebuff_PushNilFallback
  (0x519B19-0x519B24 is dead code)
519B25: LEA ECX, [EBP-0x20]   ; (next function or unrelated code)
519B28: CALL 0x496400
...
```

**Conflict**: SuperWoWhook writes 4 bytes at **0x519B1A**. In Timber this is
dead code after the JMP at 0x519B14. Timber's disassembler doesn't even show
instructions at 0x519B1A. SuperWoWhook writes corrupted jump bytes into this
dead zone. Same risk as above.

### UnitDebuff return paths that are IDENTICAL (safe):
```
519C49: POP ESI                ; <-- SuperWoWhook patches (SAME in both)
519C4A: MOV EAX, 0x3

519C6E: POP ESI                ; <-- SuperWoWhook patches (SAME in both)
519C6F: MOV EAX, 0x3
```
These paths were NOT modified by Timber. SuperWoWhook's patches here are safe.

## Crash Mechanism

### Execution trace

The crash stack has return address `0x51983B` (UnitBuff epilogue: POP EDI, POP ESI,
MOV EAX 2, ... RET). This is a UnitBuff return path that Timber did NOT modify --
the "no match" or error path returning 2 values. From this path, execution entered
SuperWoWhook's return-value formatter (offset 0x1688) via one of the 27 rel32 JMP
patches.

The crash block at 0x10001688 reads `[EBP-0x10]` (aura data ptr) and `[EBP-0x8]`
(aura index) from UnitBuff's stack frame. These are locals set up by UnitBuff's
prologue. If EBP is valid, this works.

### The corruption

EBP = `0x616C7441` = ASCII "AltA". This is string data, not a stack address. The
saved EBP was overwritten BEFORE SuperWoWhook's code runs -- SuperWoWhook's code
is the victim, not the cause of the corruption.

The string "AltA" likely comes from `ChatFrameEditBox:SetAltArrowKeyMode(false)` --
called by pfUI or shaguTweaks during an AceEvent OnUpdate handler. The stack also
contains "DBG:AceEvent20Frame".

### Possible causes

1. **Lua addon buffer overflow**: a Lua addon (pfUI, shaguTweaks) called from an
   AceEvent OnUpdate handler overflows a fixed-size buffer in the C call chain,
   writing "AltArrowKeyMode" string data over the saved EBP on the stack. This
   happens on a re-entrant Lua call from within UnitBuff processing.

2. **SuperWoWhook code cave stack collision**: SuperWoWhook's code cave may use
   stack space that overlaps with Timber's larger UnitBuff frame (Timber adds
   `[EBP-0x24]` for spell ID). If SuperWoWhook's code cave uses the same stack
   offsets for different purposes, the frames collide.

3. **Re-entrant UnitBuff call**: UnitBuff -> SuperWoWhook -> fires Lua event
   (UNIT_CASTEVENT) -> addon handler calls UnitBuff again -> second invocation
   corrupts the first's stack frame.

### What SuperWoWhook patches are harmless on Timber

All 5 UnitBuff/UnitDebuff return-epilogue patches (0x519709, 0x519AF2, 0x519B1A,
0x519C49, 0x519C6E) land on dead code or unmodified code. These patches alone
don't cause the crash -- they redirect to SuperWoWhook's formatters which work
fine IF EBP is valid.

### Confirmed: Stack Frame Size Differs

**Vanilla UnitBuff prologue:**
```
519503: SUB ESP, 0x20          ; 32 bytes of locals
```

**Timber UnitBuff prologue:**
```
519503: SUB ESP, 0x24          ; 36 bytes of locals (+4 for [EBP-0x24] spell ID)
```

Timber enlarged the stack frame by 4 bytes to store the spell ID at `[EBP-0x24]`.
However, this alone does NOT explain the crash:

- The formatter blocks use EBP-relative addressing (`[EBP-0x10]`, `[EBP-0x8]`)
  which is unaffected by the frame size change
- The formatters end with `RET`, bypassing the original epilogue entirely --
  they never do `POP EBP` so the shifted saved-register positions don't matter
- If this were the sole cause, UnitBuff would crash on EVERY call, not intermittently

### Root Cause: Formatter Uses Wrong Locals on Other-Player Path

**Confirmed via Unicorn x86 emulation.**

SuperWoWhook's formatter at offset 0x1680 does:
```
MOV ESI, [EBP-0x10]           ; assumes: unit data pointer
MOV EAX, [EBP-0x8]            ; assumes: aura slot index
MOVZX ESI, word [ESI+EAX*2]   ; reads u16 from aura array
```

This is correct for the **local player** aura iteration path (0x51960F+),
where `[EBP-0x10]` = unit object and `[EBP-0x8]` = aura iteration index.

But SuperWoWhook patches the **other player** return sites at 0x51981D and
0x51983B with E9 JMPs to this same formatter. On the other-player path:

- `[EBP-0x10]` = unit object pointer (from ClntObjMgrObjectPtr)
- `[EBP-0x8]` = NOT an aura index -- it's the Lua buff index from lua_tonumber

The formatter computes `unit_obj + lua_buff_index * 2` and reads a u16.
This is NOT a valid aura array access. Depending on the unit pointer and
buff index values:

- Usually: reads from valid heap -> returns garbage data (wrong but no crash)
- Sometimes: reads from unmapped memory or guard page -> ACCESS_VIOLATION

The EBP="AltA" corruption in the crash reports is a RED HERRING. The real
crash is the formatter reading `[ESI+EAX*2]` with ESI=unit_ptr and EAX=buff_index
on a code path where those locals hold different data than expected. When
the computed address (unit_ptr + buff_index*2) happens to land on unmapped
memory, it crashes. When it lands on mapped memory, it silently returns
wrong data.

### Emulation Evidence

Unicorn x86 emulation of Timber+SuperWoWhook patched UnitBuff:

**Test 1** (no-icon other-player path -> 0x51983B -> formatter):
```
STEP  11: SW PATCH (nil-icon other)      EBP=0x0010effc
STEP  12: *** SW FORMATTER ***           EBP=0x0010effc ESI=0x00000000
MEM ERR: [0x01000000] at EIP=0x10001688  (MOVZX ESI, [ESI+EAX*2])
```

**Test 2** (has-icon other-player path -> 0x51981D -> formatter):
```
STEP  13: *** SW FORMATTER ***           EBP=0x0010effc ESI=0x02000000
MEM ERR: [0x01000000] at EIP=0x10001688  (MOVZX ESI, [ESI+EAX*2])
```

Both crash at the same instruction. The formatter works on the local-player
path (tested separately, returns correctly), but crashes on the other-player
path because the locals at [EBP-0x10] and [EBP-0x8] mean different things.

### Why It's Intermittent

The crash only occurs when `unit_ptr + buff_index*2` points to unmapped
memory. Most unit object pointers are in the heap (0x1xxxxxxx-0x3xxxxxxx
range) and buff indices are small (0-31), so `unit_ptr + 0..62` usually
lands in mapped heap. The crash happens when:
- The unit was recently freed (dangling pointer)
- The unit is at a high heap address where +index*2 crosses a page boundary
- Memory pressure causes the page to be unmapped

### Fix

SuperWoWhook should use **different formatters** for the local-player and
other-player return paths, since the stack frame locals differ between them.
Or it should not patch the other-player return sites (0x51981D, 0x51983B)
at all, since Timber doesn't extend those paths with spell ID anyway.

## Fix Options

1. **SuperWoWhook detects Timber**: check if 0x519703 is a JMP (byte 0xE9)
   before patching. If so, skip UnitBuff/UnitDebuff patches since Timber
   already provides spell ID.

2. **Timber provides a flag**: export a marker (global variable or named
   mutex) that SuperWoWhook checks before patching.

3. **Users disable SuperWoWhook**: since Timber already provides the extra
   return values, SuperWoWhook's UnitBuff extension is redundant on Timber.

Not a WeirdUtils issue. WeirdUtils is not loaded in either crash.
