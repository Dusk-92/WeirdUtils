# Framecrash Research

## The Crash

```
ERROR #132 (0x85100084) Fatal Exception
Exception: 0xC0000005 (ACCESS_VIOLATION) at 0023:007A2452
The instruction at "0x007A2452" referenced memory at "0x16C0FFE8".
The memory could not be "read".
```

Crash log: `/media/bigfaststore/games/twmoa_1172/Errors/2026-02-25 19.38.01 Crash.txt`

### Registers at Crash
```
EAX=321A2188  EBX=16C0FFE4  ECX=00000000  EDX=25B94A35
ESI=03319888  EDI=303A4588  EBP=00F2FADC  ESP=00F2FACC
```

### Crash Instruction
```
0x007A2452: 8B 43 04    MOV EAX, [EBX+4]   ; EBX=0x16C0FFE4 → reads 0x16C0FFE8 (decommitted page)
```

---

## Call Chain

```
processGraphicsFrame    (0x764330)
  → renderAllFrameLayers  (0x765650)
    → processFrameUpdates
      → DispatchHeartbeatEvent (0x76b2c0)  — fires OnUpdate
        → ExecuteLuaCallback   (0x704f10)
          → luaD_pcall         (0x6f6960)
            → luaCallFunction  (0x6f6050)
              → luaGetPoint    (0x7a2340)   ← CRASH
```

An addon's **OnUpdate** handler calls `frame:GetPoint()` on a frame whose anchor
references a **destroyed frame** via a dangling pointer.

Stack string evidence: `"DBG:MinimapButtonFrame"` visible in stack dump.

---

## Function: `luaGetPoint` (0x007A2340)

This is the Lua API `frame:GetPoint(index)`. It returns anchor point info:
`point, relativeTo, relativePoint, xOfs, yOfs`.

### Relevant Disassembly

```asm
; === Anchor iteration loop ===
; Frame anchor array starts at frame+0x28, 9 slots (one per POINT enum)
0x007a23f5: LEA EAX,[EDI + 0x28]     ; anchor array start
0x007a23f8: MOV EDI,[EAX]            ; EDI = anchor_points[i]
0x007a23fa: TEST EDI,EDI             ; skip NULL slots
0x007a23fc: JZ 0x007a2404
0x007a23fe: CMP ECX,[EBP-4]          ; compare current_index with requested_index
0x007a2401: JGE 0x007a2416           ; found the requested anchor
0x007a2403: INC ECX
0x007a2404: INC EBX                  ; (EBX = enum counter here, NOT the crash EBX)
0x007a2405: ADD EAX,0x4
0x007a2408: CMP EBX,0x9              ; 9 anchor point types max
0x007a240b: JL 0x007a23f8

; === Found anchor — get relativeTo frame ===
0x007a2416: MOV EDX,[EDI]            ; anchor vtable
0x007a2418: MOV ECX,EDI              ; this = anchor
0x007a241a: CALL [EDX + 0xc]         ; vtable[3]() → GetRelativeTo → returns raw ptr
0x007a241d: TEST EAX,EAX
0x007a241f: JZ 0x007a24d7            ; NULL → safe "no relativeTo" path

; Second call to same vfunc — gets value for real this time
0x007a2425: MOV EAX,[EDI]
0x007a2429: CALL [EAX + 0xc]         ; vtable[3]() again
0x007a242c: TEST EAX,EAX
0x007a242e: JZ 0x007a2438            ; if NULL → relativeTo = NULL
0x007a2430: ADD EAX,-0x24            ; adjust from inner offset to frame base
0x007a2433: MOV [EBP-4],EAX          ; store relativeTo frame ptr

; Push anchor point name string onto Lua stack
0x007a243f: MOV ECX,EBX              ; EBX = enum value
0x007a2441: CALL PositionEnumToString ; (0x006f1890)
0x007a244a: CALL lua_pushstring       ; (0x006f3890)

; === CRASH SITE ===
0x007a244f: MOV EBX,[EBP-4]          ; EBX = relativeTo frame ptr (DANGLING!)
0x007a2452: MOV EAX,[EBX+4]          ; ← ACCESS VIOLATION: reads lua ref from freed frame
0x007a2455: TEST EAX,EAX
0x007a2457: JNZ 0x007a2462           ; if lua ref exists, skip registration
0x007a2459: PUSH 0x0
0x007a245b: MOV ECX,EBX
0x007a245d: CALL RegisterFrameScriptReference  ; (0x00701bd0)
0x007a2462: MOV ECX,[EBX+8]          ; lua reference index
...
```

### Safe "no relativeTo" path (0x007a24d7)
When `GetRelativeTo()` returns NULL, execution jumps here and pushes just
the point name + x/y offsets, skipping the relativeTo frame entirely.

---

## Anchor Object Structure (0x14 = 20 bytes)

Discovered from `SetAnimationOrder` (0x00767c70) — the internal C++ `SetPoint`:

```
Offset  Size  Field
+0x00   4     vtable pointer = PTR_GetAnimationOrder_0081c44c
+0x04   4     x offset (float)
+0x08   4     y offset (float)
+0x0C   4     relativeTo frame pointer (RAW — no refcount, no validation!)
+0x10   4     relative point enum (uint)
```

**Vtable address**: `0x0081c44c` (in .rdata)
**vtable[3]** (at vtable+0xC = `0x0081c458`): GetRelativeTo — simply returns `this+0x0C`

### Anchor Creation (in SetAnimationOrder)
```c
// Allocate 0x14 bytes
anchor = M2_AllocateModelBuffer(0x14, ...);
anchor->xOfs = param_4;            // +0x04
anchor->yOfs = param_5;            // +0x08
anchor->relativeTo = param_2;      // +0x0C  ← RAW POINTER, no ref held
anchor->relativePoint = param_3;   // +0x10
anchor->vtable = &PTR_0081c44c;    // +0x00

// Store in frame's anchor array
frame_anchors[pointEnum] = anchor;  // frame + enum*4 + 0x28
```

### Anchor Destruction
When a frame is destroyed (`DestroyFrame` 0x773240 / `DestroyFrameScriptObject` 0x4c34a0):
- The frame's own anchors are cleaned up
- But **no notification is sent to OTHER frames whose anchors reference this frame**
- Result: dangling pointer at `anchor+0x0C`

---

## Root Cause

**The anchor stores a raw pointer to the relativeTo frame with no weak reference or
invalidation mechanism.** When the relativeTo frame is destroyed:

1. Frame memory is freed (and potentially decommitted by the OS)
2. The anchor's `relativeTo` pointer at +0x0C is NOT cleared
3. Next time `GetPoint()` is called, `GetRelativeTo()` returns the stale pointer
4. The code dereferences it → ACCESS_VIOLATION

---

## Relevant WoW Functions & Globals

### Frame Validation
| Address | Name | Purpose |
|---------|------|---------|
| 0x787910 | `ValidateFrameTypePointer` | Compares value against `g_ParentFrameTypeID`, `g_FrameTypeID` |
| 0x789480 | `ValidatePointerType` | Same pattern, different type set |
| 0x403f50 | `ValidateObjectPointer` | Calls `IsBadReadPtr` via `[0x007ff2b8]` |
| 0x4c38a0 | `FrameScript_ValidateMemory` | Global memory validation |

### Type ID Globals (runtime values, .bss — not readable from Ghidra)
| Address | Name |
|---------|------|
| 0x00cf0c10 | `g_ParentFrameTypeID` |
| 0x00cf0c3c | `g_FrameTypeID` |
| 0x00cf4f2c | Frame type ID (specific subclass) |
| 0x00cf4f48 | Frame type ID (specific subclass) |

### Frame Lifecycle
| Address | Name |
|---------|------|
| 0x773240 | `DestroyFrame` — clears fields +0/+4, unlinks |
| 0x4c34a0 | `DestroyFrameScriptObject` — clears lua ref, unlinks from list, frees |
| 0x4c3510 | `FrameScript_InsertIntoList` |
| 0x4c3c10 | `FrameScript_UnlinkFromList` |
| 0x701bd0 | `RegisterFrameScriptReference` — creates Lua table + metatable for frame |

### Anchor Functions
| Address | Name |
|---------|------|
| 0x767c70 | `SetAnimationOrder` — internal SetPoint (creates anchor object) |
| 0x768010 | `IsAnimationPlaying` — recursive anchor dependency check |
| 0x7a2340 | `luaGetPoint` — Lua API, CRASH SITE |
| 0x7a2540 | `luaSetPoint` — Lua API |
| 0x7a2940 | `luaClearAllPoints` — Lua API |

### Windows API
| IAT Address | API |
|-------------|-----|
| 0x007ff2b8 | `IsBadReadPtr` (used by `ValidateObjectPointer`) |

---

## Fix Strategies

### Option A: Inline Hook at Crash Site (minimal, symptom fix)
Patch 6 bytes at `0x007a244f` (MOV EBX,[EBP-4] + MOV EAX,[EBX+4]):
```
Original: 8B 5D FC 8B 43 04   → JMP trampoline + NOP
```
Trampoline:
1. `MOV EBX,[EBP-4]` (original)
2. `TEST EBX,EBX` / `JZ no_relative` (→ 0x007a24d7)
3. Validate EBX via `IsBadReadPtr([0x007ff2b8])` or VirtualQuery
4. If invalid → JMP 0x007a24d7 (safe path)
5. If valid → `MOV EAX,[EBX+4]` + JMP 0x007a2455

**Pro**: Minimal patch, only affects GetPoint
**Con**: Only fixes this one crash site; other code using GetRelativeTo is still vulnerable

### Option B: Hook Anchor vtable[3] (GetRelativeTo)
Replace function pointer at `0x0081c458` with our own GetRelativeTo:
1. Read `this+0x0C` (relativeTo pointer)
2. If NULL → return NULL
3. Call `IsBadReadPtr(ptr, 0x10)` via `[0x007ff2b8]`
4. If bad → clear `this+0x0C` to NULL, return NULL
5. If good → return original value

**Pro**: Protects ALL callers of GetRelativeTo, self-healing (clears stale ptr)
**Con**: Modifies vtable in .rdata (need VirtualProtect), slight overhead on every anchor access

### Option C: Hook Frame Destruction (root cause fix)
Hook `DestroyFrameScriptObject` (0x4c34a0) to scan all frames' anchors and
clear any that reference the frame being destroyed.

**Pro**: Fixes the root cause, no runtime overhead on GetPoint
**Con**: Complex, needs to iterate all frames, frame list structure must be understood

### Recommended: Option B ← IMPLEMENTED
The vtable hook is the best balance of robustness and simplicity. It:
- Uses WoW's own `IsBadReadPtr` import (no new API dependencies)
- Self-heals by NULLing the stale pointer on first detection
- Protects all code paths, not just GetPoint
- The vtable is a single pointer write (after VirtualProtect)

Implementation: `src/framecrash/framecrash.zig`

---

## Second Crash: `luaGetWidth` NULL Layout Pointer (0x007A2FB8)

**NOT related to the anchor/GetRelativeTo fix above.** This is a separate bug.

Crash log: `/media/bigfaststore/games/twmoa_1172/Errors/2026-02-27 12.37.03 Crash.txt`

### Crash Details
```
Exception: 0xC0000005 (ACCESS_VIOLATION) at 0023:007A2FB8
The instruction at "0x007A2FB8" referenced memory at "0x0000003C".
The memory could not be "read".
```

### Registers
```
EAX=3F4F5C29  EBX=0081C3D0  ECX=00000000  EDX=0081C44C
ESI=16D046A8  EDI=17077C2C  EBP=00F2F7EC  ESP=00F2F7D8
```

### Crash Instruction
```
0x007A2FB8: F6 41 3C 02    TEST byte ptr [ECX+0x3C], 0x02   ; ECX=0 → reads 0x0000003C
```

ECX is NULL — the frame/layout object pointer is missing.

**Note**: EDX=0x0081C44C (the anchor vtable) is just a leftover register value,
NOT caused by our vtable hook. EDX is not used at the crash site.

### Call Chain
```
GetAnimationSmoothing       (0x768d20)
  → calculate_negative...   (0x7673d0)  — pushes 0x0081C3D0, calls SetFrameHitTestMode
    → SetFrameHitTestMode   (0x7671a0)  — iterates anchors, calls vtable[1] (+0x04)
      → luaGetWidth          (0x7a2f90)  ← CRASH: ECX=NULL
```

This crashes during **frame layout calculation at startup** — the frame layout
system is computing dimensions, and a frame's layout dependency (parent or
anchor target) is NULL.

### Key Disassembly (crash site in luaGetWidth)
```asm
; luaGetWidth prologue — sets up local vars
0x007a2faa: MOV [EBP-8], 0x0
0x007a2fb1: MOV [EBP-4], 0x0
0x007a2fb8: TEST byte ptr [ECX+0x3C], 0x02    ← CRASH (ECX=NULL)
0x007a2fbc: JZ 0x007a2fc5                      ; skip if flag not set
0x007a2fbe: PUSH 0x0
0x007a2fc0: CALL 0x00768060
```

### Caller (0x007673E7)
```asm
0x007673e7: PUSH 0x81c3d0                      ; NOT the anchor vtable (0x81c44c)
0x007673ec: MOV ECX, ESI                        ; frame object
0x007673ee: MOV [ESI+0x28], EAX                 ; store layout result
0x007673f1: CALL SetFrameHitTestMode (0x7671a0)
```

### Full Disassembly (luaGetWidth entry → crash)
```asm
0x007a2f90: PUSH EBP
0x007a2f91: MOV EBP, ESP
0x007a2f93: SUB ESP, 0x10
0x007a2f96: PUSH ESI
0x007a2f97: MOV ESI, ECX              ; save original this (anchor) to ESI
0x007a2f99: MOV ECX, [ESI+0xC]        ; ECX = anchor->relativeTo (NULL!)
0x007a2f9c: MOV [EBP-0x10], 0x0
0x007a2fa3: MOV [EBP-0xC], 0x0
0x007a2faa: MOV [EBP-0x8], 0x0
0x007a2fb1: MOV [EBP-0x4], 0x0
0x007a2fb8: TEST byte ptr [ECX+0x3C], 0x02    ← CRASH (ECX=NULL from ESI+0xC)
```

### SetFrameHitTestMode Call Site
```asm
0x007671b4: MOV EAX, [EBX+ESI*4]       ; load index from array at 0x81c3d0
0x007671b7: MOV ECX, [EDI+EAX*4+0x4]   ; load anchor from frame[index]
0x007671bb: TEST ECX, ECX               ; NULL check on ANCHOR (not relativeTo)
0x007671bd: JZ skip
0x007671bf: MOV EAX, [EDI+0x58]        ; load frame->field_0x58
0x007671c2: MOV EDX, [ECX]             ; EDX = anchor vtable (0x81c44c)
0x007671c4: PUSH EAX                    ; push param
0x007671c5: CALL [EDX+0x4]             ; call vtable[1] = luaGetWidth
0x007671c8: FLD ST0                     ; duplicate float return
0x007671ca: FCOMP [0x00cf550c]          ; compare with sentinel
```

### Root Cause (CONFIRMED)

`SetFrameHitTestMode` checks that the anchor object is non-NULL, but
`luaGetWidth` / `luaGetHeight` read `anchor+0x0C` (the relativeTo pointer)
and dereference it at `+0x3C` **without** a NULL check. The anchor exists,
but its `relativeTo` field is NULL (no target frame set).

**`0x0081C3D0` is NOT a vtable** — it's a static array of 3 anchor-point indices:
`[0, 3, 6]`, used by the width layout pass. `SetFrameHitTestMode` iterates these
indices to look up anchors from the frame's anchor array.

### Anchor Vtable (0x0081C44C) — Full Layout
```
[0] +0x00 = 0x00767d80 → GetAnimationOrder (destructor)
[1] +0x04 = 0x007a2f90 → luaGetWidth       ← CRASH FUNCTION
[2] +0x08 = 0x007a3070 → luaGetHeight      ← SAME VULNERABILITY
[3] +0x0C = 0x00767d70 → GetRelativeTo     (already hooked)
```

### Fix Attempt: vtable[1]/[2] hook returning 0.0 — REVERTED

Hooked vtable[1] (GetWidth) and vtable[2] (GetHeight) with wrappers that
returned 0.0 when relativeTo was NULL/dangling. **This broke UI layout** because:
1. 0.0 is not the sentinel value that `SetFrameHitTestMode` expects
   (it compares via `FCOMP [0x00cf550c]` — a runtime .bss value)
2. The functions have side effects (IsAnimationDone, GetAnimationTarget calls)
   that update layout state — skipping them entirely is wrong

### Relationship Between Crash 1 and Crash 2

The GetRelativeTo hook (crash 1 fix) self-heals by NULLing anchor+0x0C when
it detects a dangling pointer. But GetWidth/GetHeight read anchor+0x0C
**directly** (not through vtable[3]), so they see the now-NULL value and crash.
The two crashes are likely the same underlying issue — the GetRelativeTo hook
is masking the dangling pointer but exposing it as a NULL pointer to other code.

---

## Root Cause Analysis: Frame Destruction Missing Anchor Cleanup

### Dependency Tracking System

WoW's frame system tracks anchor dependencies via `PauseAnimationGroup` /
`ResumeAnimationGroup`:

**PauseAnimationGroup(relativeTo_frame, owner_frame, bitmask)** — 0x767ee0
- Called by `SetAnimationOrder` (SetPoint) when creating an anchor
- Maintains a linked list on `relativeTo_frame+0x30/0x34`
- Each node is 0x10 bytes: `[link0, next_ptr(+4), owner_frame(+8), bitmask(+C)]`
- Bitmask = `1 << anchor_point_enum` — tracks which anchor slots reference this frame
- If owner already in list, ORs in the new bitmask bits

**ResumeAnimationGroup(relativeTo_frame, owner_frame, bitmask)** — 0x767fa0
- Called when replacing/removing an anchor
- Walks list at `relativeTo_frame+0x34`, finds matching owner
- Clears bitmask bits: `node+0xC &= ~bitmask`
- If bitmask reaches 0, unlinks and frees the node

### Proper Anchor Cleanup (exists but not called on destruction)

**cleanup_array_of_objects** (0x767620) — cleans up a frame's OWN anchors:
```c
for i in 0..9:
    anchor = *(frame + i*4 + 4)     // anchor slot
    if anchor != NULL:
        relativeTo = anchor->vtable[3]()  // GetRelativeTo
        if relativeTo != NULL:
            ResumeAnimationGroup(relativeTo, frame, 1 << i)  // unregister dependency
        anchor->vtable[0](1)  // destructor
        *(frame + i*4 + 4) = 0
```

Called from: `SetAnimationOrigin` (0x768e20), `StartAnimationGroup` (0x767db0),
`GetAnimationEndDelay` (0x768430) — **never during frame destruction**.

### Frame Destruction Chain

```
destroy_object (0x7676f0) — thiscall(frame, free_flag)
  -> cleanup_linked_list_structures (0x767720) — thiscall(frame)
       -> sets vtable to CLayoutFrame base (0x81c400)
       -> SetAnimationOrigin(frame) -> cleanup_array_of_objects(frame)
            ^ cleans up THIS frame's own anchors (forward direction)
            ^ MISSING: cleanup of OTHER frames' anchors pointing to this frame
       -> unlinks from various lists
  -> if (free_flag & 1): FreeMemory(frame)
```

Also called from: `CleanupRegion` (0x76c560), `cleanupGraphicsResources` (0x764390)

### The Bug

When frame B is destroyed:
1. `cleanup_array_of_objects(B)` cleans up B's own anchors (calls
   ResumeAnimationGroup on each of B's relativeTo frames) ✓
2. **MISSING**: Nobody walks B's dependency list at B+0x30/0x34 to clean up
   other frames' anchors that reference B ✗
3. Frame A's anchor still has `anchor+0xC = B` (now freed/stale)
4. Any code that reads the anchor's relativeTo → crash

### Proposed Root Cause Fix

Hook `cleanup_linked_list_structures` (0x767720). Before calling the original:
1. Walk the dependency list at `dying_frame+0x34`
2. For each entry `(owner_frame, bitmask)`:
   - For each bit `i` in bitmask:
     - `anchor = *(owner_frame + i*4 + 4)`
     - If anchor != NULL and `*(anchor+0xC) == dying_frame`:
       - Call `anchor->vtable[0](1)` to destroy the anchor
       - `*(owner_frame + i*4 + 4) = 0` to clear the slot
   - Free the dependency list node
3. Clear `dying_frame+0x30/0x34`
4. Call original `cleanup_linked_list_structures`

This uses the game's own anchor destructor and cleans up the dependency list.
The existing GetRelativeTo vtable hook can be kept as defense-in-depth.

### cleanup_linked_list_structures Prologue (for detour)
```asm
0x767720: 53                   PUSH EBX          ; 1 byte
0x767721: 56                   PUSH ESI          ; 1 byte
0x767722: 8B F1                MOV ESI, ECX      ; 2 bytes
0x767724: 57                   PUSH EDI          ; 1 byte
0x767725: C7 06 00 C4 81 00    MOV [ESI], 0x81c400  ; 6 bytes (vtable set)
0x76772b: E8 F0 16 00 00       CALL SetAnimationOrigin ; 5 bytes
```
First 5 bytes (53 56 8B F1 57) can be replaced with JMP rel32 for a detour.
