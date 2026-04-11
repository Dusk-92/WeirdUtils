# Lua 5.0 GC Write Barrier in lua_vm_execute

## Location

`lua_vm_execute` (0x6F8720), the main VM interpreter loop.
The barrier appears after every TValue copy (~20 sites in the function).

## Globals

- `0xCEEAC0` -- GC barrier value (current white marker / gc object pointer)
- `0xCEEAC4` -- GC barrier flag (non-zero = barrier is active)

## Pattern (from disassembly)

After copying a 16-byte TValue (type_tag, gc_ptr, value_lo, value_hi):

```asm
mov  eax, [dst + 4]       ; eax = copied gc_ptr field
test eax, eax
jz   skip                 ; NULL gc_ptr -> no barrier needed
cmp  dword ptr [0xCEEAC4], 0
jz   skip                 ; barrier disabled -> skip
mov  [0xCEEAC0], eax      ; mark: write gc_ptr into barrier global
skip:
```

## What it does

The gc_ptr field at TValue+0x04 holds a pointer to a GC-managed object
(string, table, closure, userdata) or NULL for non-collectable types
(number, boolean, nil, lightuserdata).

When a TValue is copied (MOVE, GETGLOBAL, GETTABLE, LOADK, etc.), the
barrier checks:
1. Is the copied value a GC object? (gc_ptr != NULL)
2. Is the write barrier active? (flag at 0xCEEAC4 != 0)
3. If both true, write the gc_ptr to the barrier global at 0xCEEAC0

This is Lua 5.0's incremental GC write barrier. It tracks which GC objects
have been moved/copied so the collector knows which objects are reachable
from newly-written locations. The barrier global accumulates the "last written"
gc object -- the actual GC uses this to avoid rescanning the full root set.

## Opcodes that trigger the barrier

Every opcode that writes a TValue to a register or table slot:
- MOVE (op 0)
- LOADK (op 1) -- loads constant, has gc_ptr for string constants
- GETUPVAL (op 4)
- GETGLOBAL (op 5)
- GETTABLE (op 6)
- SETGLOBAL (op 7) -- barrier on the table side
- SETTABLE (op 9)
- NEWTABLE (op 10)
- SELF (op 11)
- CONCAT (op 21)
- CLOSURE (op 30)
- FORLOOP (op 23) -- number only, but barrier still present

## Relevance to luagc module

Our luagc module (in weirdperformance) hooks `lua_gc_step` (0x6FAE00).
Understanding the barrier globals is useful for:
- Knowing when/how often the barrier fires during heavy addon activity
- Potentially batching barrier writes if we ever replace the GC step
- The flag at 0xCEEAC4 could be used to temporarily disable the barrier
  during bulk operations (dangerous -- must re-enable before GC runs)
