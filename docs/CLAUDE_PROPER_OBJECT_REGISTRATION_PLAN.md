# Proper Object Registration Plan (for Claude)

## Goal
Stop ad-hoc list insertion and implement a **correct, engine-native object creation/registration path** for client-side markers in WoW 1.12.1.

Success = marker is visible in-world, no crash on create/destroy/toggle, and lifecycle uses native manager functions (not manual pointer surgery as primary path).

---

## Current Status Summary (Read First)

1. **Crash fixed, visibility not fixed**
   - We eliminated crash caused by callback slot garbage (`obj+0x174`) in manager iteration path.
   - Markers still invisible in both current test paths.

2. **What was tried**
   - Path A: Allocate world object + attach model + manual insert into manager list (`0x00C7CAEC`).
   - Path B: `CreateGameObject_WithProperties` + fallback manual insertion if unlinked.
   - Both now create/destroy cleanly, still not rendering.

3. **Known engine behaviors**
   - Manager iterator (`AllocateGameObject` region around `0x00683F80`) uses positions at `+0x5C/+0x60/+0x68` and calls render-management functions.
   - It may call callback pointer at `+0x174` if non-zero.
   - List pointers can be low-bit tagged.

4. **Conclusion so far**
   - List manipulation and crash stability are mostly solved.
   - Remaining blocker is likely **incorrect native registration/state initialization**, i.e. object not entering correct draw/classification path.

---

## Mandatory Context Files

Read these before coding:

1. `research/marker-visibility-debug-log.md`
2. `docs/M2_MODEL_SYSTEM.md`
3. `research/dynamic-object-research.md`
4. `src/markers/markers.zig`
5. Crash reference: `/media/bigfaststore/games/twmoa_1172/Errors/2026-02-27 07.11.41 Crash.txt`

Also review the CLI Ghidra skill:
- `~/.claude/skills/ghidra-cli-wow-re/SKILL.md`

---

## Rules of Engagement

1. **Do not treat manual list insertion as final architecture.**
2. **Do not trust decompiler signatures alone.** Verify calling conventions from bytes/prologue/RET cleanup.
3. **Prefer discovering native add/remove APIs** used by real visible objects.
4. **Every hypothesis must have an observable test log.**
5. **No broad refactors until registration path is proven.**

---

## Execution Plan

## Phase 1 - Identify canonical native registration path

### Task 1.1: Recover true iterator and linkage semantics
- Disassemble around `0x00683F80` (and nearby helpers) in detail.
- Map exactly how nodes are traversed and linked (including pointer tagging and indirection via globals like `0x00C7CAE4/0x00C7CAEC`).
- Produce pseudocode with verified offsets and conditions.

**Deliverable:** short technical note: "Manager traversal/link semantics".

### Task 1.2: Find native insertion/removal helpers
- Find xrefs to `0x00C7CAEC` and offsets `+0x16C/+0x170`.
- Identify functions that insert/remove objects in production code.
- Verify one candidate by callsite context (who calls it and when).

**Deliverable:** candidate helper function list with addresses + confidence.

### Task 1.3: Find real creator path for visible world objects
- Trace from known visible object creators (game objects/doodads/spell visuals) to registration.
- Determine **minimal required function chain** from creation to render visibility.

**Deliverable:** canonical call chain diagram with function addresses.

---

## Phase 2 - Build proper registration wrapper in markers module

### Task 2.1: Implement native-path wrapper
- Add a wrapper that uses discovered native creator/registration APIs.
- Manual list insertion may remain only as fallback/diagnostic mode, not default.

### Task 2.2: Lifecycle correctness
- Ensure destroy path uses matching native teardown/unlink APIs.
- Prevent double-unlink and callback garbage.

### Task 2.3: Instrumentation
- Keep concise debug logs for:
  - object pointer
  - model pointer
  - registration result path
  - destroy path confirmation

**Deliverable:** code in `src/markers/markers.zig` with clear mode labels.

---

## Phase 3 - Validation protocol (must pass)

Run and capture logs for:

1. `/mark on`
2. visually confirm marker appears
3. `/mark off`
4. repeat 5+ times
5. mode switching stress (`testa/testb` if retained)

Must pass:
- no crash
- no panic
- marker visible at player position
- clean destroy every cycle

If failed:
- report exact failing step, log lines, and next smallest probe

---

## Expected Outputs from Claude

1. Updated code implementing native registration path.
2. Updated `research/marker-visibility-debug-log.md` with:
   - what changed
   - what was validated
   - remaining unknowns (if any)
3. Optional update to `docs/M2_MODEL_SYSTEM.md` for newly confirmed function semantics.
4. Final summary:
   - root cause
   - final fix
   - evidence (logs + addresses)

---

## Suggested Command Workflow (CLI Ghidra)

Use headless scripts via:

```bash
<ghidra-scripts>/run-analysis.sh /tmp/analysis.py
```

Focus scripts on:
- xrefs to manager globals and list offsets
- disassembly around candidate insertion helpers
- call graph from visible object creation paths

---

## Non-Goals (for this pass)

- New marker visuals
- Effects polish
- Optimizations unrelated to visibility/registration correctness
- Expanding to many marker types before first visible stable marker

---

## Acceptance Criteria

- Marker visibility achieved using engine-native registration path (or proven minimal wrapper around it)
- No crash across repeated create/destroy
- Documentation updated with verified semantics
- Ad-hoc list surgery no longer required as primary behavior
