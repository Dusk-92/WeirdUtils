# WoW Lua 5.0 GC System

Notes on the GC machinery of WoW 1.12.1's modified Lua 5.0, based on
disassembly (Ghidra) and cross-reference with the official Lua 5.0.3
source (`lgc.c`/`lgc.h`). Addresses are client-absolute (build 5875).

## High-Level Structure

WoW's Lua uses a **stop-the-world mark-and-sweep** collector. No tri-color
incremental marking, no generational logic, no write barriers in the
generational sense. Collection is atomic: the entire world freezes for one
full mark+sweep pass.

Key entry point: `luaC_collectgarbage` (0x6F7340).

Sequence inside `luaC_collectgarbage`:

1. `lua_gc_full_collection` (0x6F73E0) - the mark phase
2. `lua_gc_remove_objects(L, &g->rootudata, 0)` (0x6F7210) - sweep userdata
3. `lua_gc_sweep_all_lists(L, 0)` (0x6F72F0) - sweep string hash table
4. `lua_gc_remove_objects(L, &g->rootgc, 0)` - sweep rootgc list
5. `lua_gc_shrink_memory(L)` (0x6F7370) - string table shrink + threshold
6. `luaCallUserDataGC(L)` (0x6F7080) - run `__gc` finalizers

## GCObject Header

Every GC object starts with a common header:

```
offset 0x00  GCObject *next   ; linked list next
offset 0x04  lu_byte tt       ; type tag
offset 0x05  lu_byte marked   ; GC mark + flags
offset 0x06  lu_byte ...      ; type-specific (e.g. Table.flags)
```

## Type Tags

Standard Lua 5.0 values (verified via propagate dispatch at 0x6F7510):

| Value | Type           |
|-------|----------------|
| 0     | LUA_TNIL       |
| 1     | LUA_TBOOLEAN   |
| 2     | LUA_TLIGHTUSERDATA |
| 3     | LUA_TNUMBER    |
| 4     | LUA_TSTRING    |
| 5     | LUA_TTABLE     |
| 6     | LUA_TFUNCTION  |
| 7     | LUA_TUSERDATA  |
| 8     | LUA_TTHREAD    |
| 9     | LUA_TPROTO     |

`LUA_TUPVAL` exists internally (type 10?) but is NOT in the propagate
dispatch; upvalues are traversed via `mark_closure` from the containing
closure.

## `marked` Byte Layout

Bits (verified from disassembly + Lua 5.0 `lgc.h`):

```
bit 0  -- mark flag (1 = reachable/traversed)
bit 1  -- KEYWEAK   (for tables with __mode key-weak)
bit 2  -- VALUEWEAK (for tables with __mode value-weak)
bit 3  -- FINALIZED (userdata: __gc already run)
bit 4  -- propagation flag (set together with bit 0; see below)
bit 5-7 -- UNUSED (but see NOTE below)
```

**Critical**: the check used by `mark_table` / `mark_closure` / etc. when
following a child reference is:

```asm
TEST byte [child+5], 0x11    ; bits 0 and 4
JNZ skip                      ; if either is set, skip re-marking
```

This matches Lua 5.0's `ismarked` macro: `(marked & ((1<<4)|1))`.
Either bit counts as "already processed". Bit 4 is (in standard Lua 5.0)
set for tables with `WEAKKEY|WEAKVALUE` (`(1<<4)|1 == 0x11` test). In
practice our analysis of `mark_table` didn't show explicit bit 4 writes,
so this is either dead state from the original Lua behavior or used
implicitly via macro expansion.

**Additional critical**: `mark_closure` at 0x6F7828 uses a DIFFERENT check
for upvalues:

```asm
MOV AL, [upval+5]            ; whole marked byte
TEST AL, AL
JNZ skip                      ; any non-zero = already processed
```

And writes the entire marked byte to 0x01 at 0x6F7840:
```asm
MOV byte [upval+5], 0x01
```

**This means**: any non-zero bits in an upvalue's marked byte cause it to
be skipped. We CANNOT use any bit in an upvalue's marked byte for our own
flags. Age bits in bits 5-7 break upvalue traversal.

## Sweep Invariants

`lua_gc_remove_objects` (0x6F7210) sweeps a list. Per-object behavior:

```asm
MOV AL, [obj+5]             ; load marked
XOR ECX, ECX
MOV CL, AL                   ; ECX = marked (zero-extended)
CMP ECX, [limit]             ; threshold (typically 0)
JLE dead                     ; signed <=; alive otherwise
  AND AL, 0xFE               ; clear bit 0 on survivor
  MOV [obj+5], AL            ; preserves bits 1..7
  ...                        ; advance to next
dead:
  ; unlink and free via lua_gc_free_object (0x6F7260)
```

Properties:
- Alive if `marked > limit` (ZXed byte compared as 32-bit int)
- Alive case clears ONLY bit 0 (AND 0xFE), preserves everything else
- Dead case frees via `lua_gc_free_object` which type-dispatches to
  `luaH_free` / `luaF_freeproto` / etc., eventually back to our slab
  allocator's `slabFree`

## Mark Phase (`lua_gc_full_collection`)

Flow (from disassembly of 0x6F73E0):

```
// local GCState st on stack (20 bytes, see layout below)
st.tmark = st.wk = st.wv = st.wkv = NULL;
st.g = L->l_G;

markroot(&st, L);               ; 0x6F7AB0
propagatemarks(&st);            ; 0x6F7510

cleartablevalues(st.wkv);       ; 0x6F7A20 with st.wkv
cleartablevalues(st.wv);        ; 0x6F7A20 with st.wv
wkv_saved = st.wkv;
st.wkv = NULL;
st.wv = NULL;

luaC_separateudata(L);          ; 0x6F6FF0 -- move dead udata to tmudata
marktmu(&st);                   ; 0x6F7470 -- unmark + re-mark tmudata
propagatemarks(&st);            ; second propagation pass

cleartablekeys(wkv_saved);      ; 0x6F7970
cleartablekeys(st.wk);          ; 0x6F7970
cleartablevalues(st.wv);        ; 0x6F7A20
cleartablekeys(st.wkv);         ; 0x6F7970
cleartablevalues(st.wkv);       ; 0x6F7A20
```

Matches the Lua 5.0.3 `mark()` function in `lgc.c` exactly.

### `GCState` Layout (20 bytes)

```
offset 0x00  GCObject *tmark  ; main gray list (to-traverse)
offset 0x04  GCObject *wk     ; weak-key tables pending clear
offset 0x08  GCObject *wv     ; weak-value tables pending clear
offset 0x0C  GCObject *wkv    ; weak key+value tables
offset 0x10  global_State *g
```

Stored as a local on the caller's stack. All mark functions take
ECX = `&GCState` as their first argument (fastcall).

### `markroot` (0x6F7AB0)

Signature: `__fastcall(ECX=GCState*, EDX=lua_State*)`.

Body (from disasm):
1. If `g->defaultmeta` (at `g+0x48`) is a table (type at `g+0x40` >= 4):
   `mark_object_gray(&st, defaultmeta)`
2. If `g->registry` (at `g+0x38`) is a table (type at `g+0x30` >= 4):
   `mark_object_gray(&st, registry)`
3. `mark_thread(&st, g->mainthread)` (traversestack on main thread)
4. If `L != g->mainthread`: `mark_object_gray(&st, L)`

### `mark_object_gray` (reallymarkobject) (0x6F74A0)

```asm
OR byte [obj+5], 0x01     ; set mark bit
MOVZX EAX, [obj+4]        ; type tag
SUB EAX, 0x5              ; 0..4 for types 5..9
CMP EAX, 0x4
JA return                  ; type < 5 or > 9: just mark, don't push
JMP [dispatch + EAX*4]    ; type-specific: push to appropriate list
```

Dispatch (from jump table at 0x6F7574):

| Type | Push Offset                    | What           |
|------|--------------------------------|----------------|
| 5    | `[obj+0x18] = st.tmark; ...`   | Table → tmark  |
| 6    | `[obj+0x08] = st.tmark; ...`   | Closure → tmark |
| 7    | (just set mark, no push)        | Userdata       |
| 8    | `[obj+0x54] = st.tmark; ...`   | Thread → tmark |
| 9    | `[obj+0x40] = st.tmark; ...`   | Proto → tmark  |

The offsets are the `gclist` field within each type's struct.

Note: `mark_object_gray` has **no skip check** at entry. It always sets
bit 0 and dispatches. The "skip if already marked" check happens at
CALLERS of `mark_object_gray` via `TEST 0x11` before the call.

### `propagatemarks` (0x6F7510)

Drains `st.tmark`:

```
while (st.tmark) {
  o = st.tmark;
  switch (o->tt) {
    case 5: st.tmark = o->gclist; mark_table(&st, o);     // 0x6F7590
    case 6: st.tmark = o->gclist; mark_closure(&st, o);   // 0x6F77B0
    case 7: st.tmark = o->gclist; /* skip */              // (just next)
    case 8: st.tmark = o->gclist; mark_thread(&st, o);    // 0x6F7860
    case 9: st.tmark = o->gclist; mark_proto(&st, o);     // 0x6F7710
  }
}
```

### `mark_table` (traversetable) (0x6F7590)

1. Mark metatable (`[table+8]`): if `TEST [mt+5], 0x11` == 0,
   `mark_object_gray(mt)`
2. Check metatable flags byte at `[mt+6]` bit 3 for weak mode
3. Resolve `__mode` metamethod via a function call to 0x6F7BA0, parse
   "k"/"v" flags
4. Update weak flags in `[table+5]` bits 1-2 (`AND 0xF9 | new_flags<<1`)
5. If weak: push onto wk/wv/wkv list instead of marking children
6. Mark hash nodes: for each `Node[i]`, check TEST 0x11 on key gc_ptr
   and value gc_ptr; call `mark_object_gray` if not set

### `mark_closure` (traverseclosure) (0x6F77B0)

Two branches based on `[closure+6]` (isC flag at offset 6):

- **C closure**: iterate `[closure+0x18 + i*0x10]` TValues (upvalue array
  is inline). For each: TEST 0x11, mark_object_gray if type >= 4.

- **Lua closure**: 
  - Mark `closure.env` at `[closure+0x18]` (TEST 0x11, mark if unset)
  - Mark `closure.p` (proto) at `[closure+0x0C]`
  - Iterate `[closure+0x20 + i*4]` which are UpVal* pointers.
    For each UpVal:
    - **`TEST AL, AL` on `[upval+5]` (whole byte)** — skip if non-zero
    - Otherwise: check the upval's value at `[upval+0x10]` (tt) and
      `[upval+0x18]` (gc_ptr) via TEST 0x11, mark if collectable
    - Unconditionally write `[upval+5] = 0x01` to mark upval as processed

The `TEST AL, AL` is the critical constraint: upvalues use the entire
marked byte as a "processed" flag. Any non-zero value (including our age
bits) causes the upval to be skipped from traversal.

### `cleartable` Functions (0x6F7A20 and 0x6F7970)

Two separate functions:

- **0x6F7A20** (`cleartablevalues`): walks a list of weak tables linked
  by `gclist`. For each table, iterates hash nodes. For each node with
  non-nil value, checks `ismarked(gcvalue(value))` — if the value is
  not marked (bit 0 clear), sets the value to nil (`removekey`).

- **0x6F7970** (`cleartablekeys`): similar but for keys. If the key
  gc_ptr is not marked, removes the entire entry (sets key type to
  LUA_TNONE, value to nil).

Both read `marked & 0x01` (or `marked & 0x11`) to determine liveness.
**Strings are auto-marked** during this check (`stringmark(s)` is called
on any collectable string, regardless of weak status, because strings
are "values" not "entries").

## Root Set

Per `markroot` analysis, the roots are:
- `g->defaultmeta` (a metatable shared by all tables without explicit one)
- `g->registry` (the registry table, holds C API references)
- Main thread's **entire stack + CallInfo ranges** (via `mark_thread`)
- Current running `L` (if different from main thread)

**NOT traditional roots** (handled as children of other roots):
- Globals table — it's `mainthread->gt`, marked by `mark_thread`
- Open upvalues — `mainthread->openupval`, marked by `mark_thread`
  walking its `openupval` list (0x6F7860 traverses this)

## Write Barriers in the Stock GC

**There aren't any "write barriers" in the generational sense.** The
stop-the-world mark-and-sweep doesn't need them.

There IS a set of global variables that LOOK like barrier machinery:

- `0xCEEAC4` - a "barrier active" flag, non-zero during certain
  operations
- `0xCEEAC0` - a "current gc object" slot

And the pattern at table-write sites (e.g., 0x6F7FC7 in
`lua_set_table_value`, 0x6FA945 in `lua_table_new_key`):

```asm
MOV EAX, [src + 4]       ; value's gc_ptr
TEST EAX, EAX
JZ skip                   ; nil/non-collectable
CMP [0xCEEAC4], 0         ; barrier flag
JZ skip                   ; flag clear, skip
MOV [0xCEEAC0], EAX       ; record the gc_ptr
skip:
```

**This is NOT a write barrier for generational GC.** It's actually the
`fix for gcvalue` / `gcvalue save` mechanism from Lua 5.0's handling of
C API functions that might trigger GC while holding an unstable
reference. The `0xCEEAC0` slot holds a GC object that must be kept alive
across a GC step.

References to `0xCEEAC0` appear in ~100 places throughout the Lua C API,
almost all following the save/restore pattern:
```
MOV EAX, [0xCEEAC0]      ; save current
...                       ; do work that might GC
MOV [0xCEEAC0], EAX      ; restore
```

Attempting to piggyback generational write-barrier logic on these sites
is misguided: the flag `0xCEEAC4` is often zero during normal execution,
so writes don't hit these code paths, and the sites only record the
VALUE, not the destination object.

## Table Write Paths (Relevant for Real Write Barriers)

All table-value writes funnel through one of two primitives:

| Function                  | Address   | Callers                                                                                    |
|---------------------------|-----------|--------------------------------------------------------------------------------------------|
| `lua_table_set_value`     | 0x6FA840  | `lua_rawseti` (0x6F3EA0), `luaPackVarArgs` (0x6F6200), `lua_set_table_value` (0x6F7F40), `lua_table_resize` (0x6FAB90), `StoreLuaConstant` (0x700AD0) |
| `lua_table_set_int_key`   | 0x6FAD80  | `lua_rawseti` (0x6F3F60), `luaPackVarArgs` (0x6F6200), `lua_vm_execute` (0x6F8720, SETLIST opcode), `lua_table_resize` (0x6FAB90) |

Both ultimately call `lua_table_new_key` (0x6FA8A0) for new-key insertion.
`lua_table_new_key` is only called from these two primitives; barriering
both covers 100% of hash-node creation.

`lua_set_table_value` (0x6F7F40) is the high-level wrapper used by
`lua_settable`, `lua_rawset`, `lua_setfield`, `lua_setglobal`, and all
VM opcodes for table writes.

**Not covered by these primitives:**
- `lua_setmetatable` (0x6F4020) — directly writes `table->metatable`,
  bypasses `lua_table_set_value`. Callers: `luaL_create_weak_table`
  (0x6F4FC0), `RegisterFrameScriptReference` (0x701BD0). Rare, setup-time.
- Direct C writes by the game engine to internal tables — unquantified
  risk, probably limited to engine-created structures.
- Thread stack pushes (`lua_pushvalue`, etc.) — stack is always walked
  by `mark_thread` every collection, so no barrier needed as long as
  threads are always traversed.

## Freeing Objects

`lua_gc_free_object` (0x6F7260) dispatches by type:
- Proto → `luaF_freeproto`
- Function → `luaF_freeclosure`  
- Upval → `luaM_freelem`
- Table → `luaH_free` (frees array + node arrays + struct)
- Thread → `luaE_freethread`
- String → `luaM_free` (removes from string hash)
- Userdata → `luaM_free`

All eventually reach `luaM_realloc` (0x6FC980) which does accounting
and calls through to the allocator (our `memory_pool_allocate` hook →
slab allocator).

## Birth Mark Patches

Locations where `luaC_link` / `lua_create_string_object` write the
initial `marked` byte for new objects:

- `luaC_link` (0x6F7B20): imm8 at 0x6F7B37 (`MOV byte [EDX+5], 0x0`)
- `lua_create_string_object` (0x6F9D90): imm8 at 0x6F9DC1

The incremental GC module patches these to `0x01` during chunked sweep
so new objects are born marked-alive and survive until the next cycle.

## Generational GC Constraints (what we can and cannot do)

From all of the above, the hard constraints on any generational
retrofit:

1. **Cannot use the marked byte for age tracking.** Bits 0+4 are used
   for mark state. Bits 1+2 are used for weak flags. Upvalues use the
   entire byte as a "processed" flag (`TEST AL, AL`). Any stray bits
   cause subtle corruption.

2. **Must use external age storage.** We use per-page bitmaps in the
   slab allocator (1 bit per slot), indexed by segment + slot index.

3. **Must clear the age bitmap on free.** Freed slots return to the
   slab's free list. When reallocated, the new object inherits the
   freed object's bitmap bit. This caused a multi-hour debugging
   session — the fix is in `slabFree` to clear the bit.

4. **Write barriers must cover all table writes that could create
   old→young references.** `lua_table_set_value` and
   `lua_table_set_int_key` cover ~99% of paths. `lua_setmetatable` is
   the known gap.

5. **Skipping old objects during mark is achievable** by pre-setting
   bit 0 on old non-touched objects before calling `lua_gc_full_collection`.
   `mark_table`'s `TEST 0x11` check catches them at child references
   and skips `mark_object_gray`, which prevents them from being added
   to the gray list, which prevents their subtree from being traversed.

6. **Pre-marking must NOT touch non-table objects.** Closures need full
   traversal because upvalue values can change via `setupvalue` which
   isn't barriered. Threads need full traversal because stack contents
   change without barriers. Pre-marking upvalues directly would break
   the `TEST AL, AL` check in `mark_closure`.

## Heap Size and Object Count

Observed characteristics from profiling + existing luagc module:

- **Steady-state rootgc size**: on the order of **100k-300k objects** in
  a typical addon-heavy gameplay session. Not precisely measured, but
  the incremental sweep module uses `CHUNK_SIZE = 50000` and takes
  multiple chunks on a full sweep (observed "chunk0"/"chunkN"/"final"
  log lines during gameplay).
- **Pre-generational stop-the-world sweep**: up to **5 seconds** worst
  case during addon loading bursts. Main cost is rootgc sweep; mark
  phase alone is ~80ms.
- **String count**: not instrumented separately but visible via the
  string hash sweep (`lua_gc_sweep_all_lists`) which costs ~44-92ms per
  full cycle. String hash table has `g->strt.size` buckets (power of 2,
  grows with `strt.nuse`).
- **Userdata count**: small (hundreds at most). Sweep is atomic and
  fast; not a contributor to GC stutter.
- **Total memory footprint**: accounted via `g->totalbytes`
  (`global_State + 0x28`). Typical session: tens of MB to >100 MB.
- **Allocator size classes** (from slab profiling via `luaalloc`):
  dominant sizes are **40 bytes** (Lua Table nodes), **80/160/320/640**
  (power-of-2 hash arrays of nodes), and **~24-48 bytes** (small
  objects like TString headers, closures). Large allocations (>4KB) are
  rare.

Implication: full mark of ~200k objects in ~80ms = ~400ns per object.
Full sweep at similar rates. Any generational scheme that lets us skip
90% of the heap gives ~8ms mark + sweep on the common minor path, well
under one-frame budget.

## Threading Model

**WoW 1.12 is effectively single-threaded from Lua's perspective.**

- The main game thread runs the Lua VM, executes scripts, handles
  events, does rendering setup. All Lua stack manipulation, all GC
  runs, all addon code executes here.
- Other OS threads exist (sound, network, worker pool, D3D device
  thread) but **none of them touch the Lua state**. They communicate
  via OS-level synchronization (events, queues) and never access
  `global_State` or any `lua_State`.
- Our hooks run on whichever thread calls the hooked function. For
  `memory_pool_allocate`, `luaC_collectgarbage`, `lua_table_set_value`,
  `lua_gc_free_object`, this is always the main thread.

**Consequences for write barriers:**
- No synchronization needed on `touched_set` or the age bitmap.
- No race between a write barrier fire and a concurrent GC step.
- `in_gc` flag is sufficient to detect GC re-entrance (finalizers
  allocating, etc.); no need for atomics.
- The pre-mark / post-mark phase transitions don't need memory barriers.

This is a significant simplification compared to generational GCs in
multithreaded runtimes (HotSpot, V8, etc.) where every barrier fire
needs at least a relaxed atomic.

## Using Ghidra for Discovery

The workflow we've used for every GC investigation in this project.
Ghidra is run **headless** from CLI (no GUI); see the `ghidra-cli-wow-re`
skill for setup.

### Tool Chain

- **Ghidra 11.4.2** at `<ghidra-install>/`
- **Project** `Dis` at `/media/faststore/tmp/Dis`
- **Target binary**: `WoW.exe.multi.latest` (labeled vanilla 1.12.1)
  or `WoW.exe.timber` (Turtle WoW with extra labels)
- **Wrapper script**:
  `<ghidra-scripts>/run-analysis.sh`
  takes a Python/Jython script path and runs it headless against the
  default binary, dumping stdout.

### Standard Steps

**Step 1: Write a Python analysis script to `/tmp`.**

Jython 2.7 with Ghidra's scripting API (`currentProgram`, `getReferencesTo`,
`getFunctionContaining`, etc.). Example patterns we use constantly:

```python
# Disassemble a range
listing = currentProgram.getListing()
def disasm(start, length, label):
    print("\n=== %s (0x%08x) ===" % (label, start))
    addr = toAddr(start)
    end = start + length
    count = 0
    while count < 200:
        insn = listing.getInstructionContaining(addr)
        if insn is None:
            b = getByte(addr)
            print("  0x%08x  %02x  <data>" % (addr.getOffset(), b & 0xff))
            addr = addr.add(1)
        else:
            raw = ""
            for i in range(insn.getLength()):
                b = getByte(insn.getAddress().add(i))
                raw += "%02x " % (b & 0xff)
            print("  0x%08x  %-28s %s" % (
                insn.getAddress().getOffset(), raw.strip(), insn.toString()))
            addr = insn.getAddress().add(insn.getLength())
        count += 1
        if addr.getOffset() >= end:
            break

# Find callers of a function
def get_callers(addr_int, label):
    refs = getReferencesTo(toAddr(addr_int))
    seen = set()
    for ref in refs:
        if ref.getReferenceType().isCall():
            fn = getFunctionContaining(ref.getFromAddress())
            if fn and fn.getEntryPoint().getOffset() not in seen:
                seen.add(fn.getEntryPoint().getOffset())
                print("  0x%08x  %s" % (fn.getEntryPoint().getOffset(), fn.getName()))
```

**Step 2: Run the script.**

```bash
<ghidra-scripts>/run-analysis.sh /tmp/my_script.py 2>/dev/null | grep "0x006f"
```

The `2>/dev/null` suppresses Ghidra's startup noise; `grep "0x006f"`
filters to output lines referencing the Lua code region (0x6F0000+).

**Step 3: Verify from raw bytes.**

The Ghidra decompiler is a best-guess engine, especially for calling
conventions. Before hooking any function:
1. Read the **prologue** (first 10-20 insns) — confirms register
   conventions (`MOV ESI, EDX` ⇒ EDX is the `table` arg, etc.)
2. Check **every RET** for stack cleanup (`RET 4` ⇒ stdcall/fastcall
   with 1 stack arg; plain `RET` ⇒ all regs)
3. Cross-reference struct field accesses (`[EDX+0x08]`) against
   assumed struct layouts from Lua 5.0 source

### Specific Techniques Used in This Module

**Discovering the marked byte check patterns:**

```python
# Find every instruction of the form `TEST byte [reg+5], imm`
# Pattern: F6 4x 05 imm  (where 4x is 40|reg)
import jarray
mem = currentProgram.getMemory()
for reg_byte in [0x40, 0x41, 0x42, 0x43, 0x45, 0x46, 0x47]:
    pat = jarray.array([0xF6, reg_byte, 0x05], 'b')
    cur = toAddr(0x6F0000)
    while True:
        found = mem.findBytes(cur, pat, None, True, monitor)
        if found is None or found.getOffset() > 0x6FF000:
            break
        imm = getByte(found.add(3)) & 0xff
        fn = getFunctionContaining(found)
        print("  0x%08x  TEST [reg+5], 0x%02x in %s" % (
            found.getOffset(), imm,
            fn.getName() if fn else "?"))
        cur = found.add(1)
```

We used this to discover that `TEST 0x11` is the dominant mark check
(bits 0+4) and that `TEST 0xFF` in closure traversal is a different
whole-byte check.

**Finding global_State offsets:**

Start from a known offset (e.g., `rootgc` at `g+0x10`, discovered from
the handoff) and trace code that accesses `[g+X]` in GC-related
functions. Compare with Lua 5.0's `global_State` struct in `lstate.h`
to map offsets to fields. Key offsets we've confirmed:

| Offset | Field                    | How verified                     |
|--------|--------------------------|----------------------------------|
| 0x0C   | stringtable.hash         | Sweep function walks it           |
| 0x10   | rootgc                   | `lua_gc_remove_objects` arg       |
| 0x14   | rootudata                | Sweep loop iterates this          |
| 0x18   | tmudata                  | `marktmu` walks this              |
| 0x24   | GCthreshold              | Threshold updates in gc_step      |
| 0x28   | totalbytes               | Memory accounting                 |
| 0x30   | registry type tag        | `markroot` `[g+0x30]` check       |
| 0x38   | registry ptr             | `markroot` `[g+0x38]` load        |
| 0x40   | defaultmeta type         | `markroot` `[g+0x40]` check       |
| 0x48   | defaultmeta ptr          | `markroot` `[g+0x48]` load        |
| 0x50   | mainthread               | `markroot` `[g+0x50]` → traversestack |

**Cross-referencing with Lua 5.0 source:**

Download Lua 5.0.3 source once (`/tmp/lua5/lua-5.0.3/`) and grep for
function names and struct fields when Ghidra's decompilation is
ambiguous. The WoW build is a lightly modified Lua 5.0 — most functions
map 1:1 to their `lgc.c` / `ltable.c` / `lobject.h` counterparts.

**Verifying calling conventions:**

Zig's `fastcall` with `@callconv(.fastcall)` puts args in ECX, EDX,
then stack. We verified this matches WoW's by looking at the prologue
of every hookable function. The pattern `MOV ESI, EDX; MOV EBX, ECX`
indicates the 1st and 2nd fastcall args are being saved; stack args
are accessed via `[EBP+8]`, `[EBP+0xC]`, etc.

`RET 4` means one 4-byte stack arg is cleaned by the callee — this
must match the Zig function signature's parameter count.

## Known Unknowns

- `0xCEEAC4` flag: when exactly is it set/cleared? Understanding this
  could unlock the existing Lua C API barrier mechanism as an
  alternative write barrier path.
- Exact function at 0x6F6FF0 (called between the two propagate passes
  in `lua_gc_full_collection`) — likely `luaC_separateudata` but not
  verified.
- Whether `lua_table_resize` can move hash nodes in a way that bypasses
  our barriers transiently during a write.
