# Task: Pure Zig Unit Outline Reimplementation for weirdutils

## Mission
Reimplement the WoW unit outlining system in **pure Zig** inside `zig/weirdutils`, with cleanly separated source files and no runtime dependency on the Idris C/C++ outline implementation.

## Explicit Tooling Permission
You are explicitly authorized to use **Code Executor MCP freely**, including controlling **Ghidra** for reverse engineering support (function signatures, prologues, calling conventions, offsets, call sites).

Use this freedom proactively to verify:
- Function prologues and patch-safe lengths
- rel32 fixup needs for call/jmp in overwritten prologues
- Calling convention correctness (__thiscall/__fastcall/__stdcall)
- Data structure offsets relevant to model tracking/render hooks

## Repos / Paths
- Target implementation: `/media/storage/projects/zig/weirdutils`
- Reference implementation: `/media/storage/projects/idris/dlls`
- Existing Zig hook library reference: `/media/storage/projects/zig/hook`

## Hard Constraints
1. **Pure Zig runtime path for outlines** (C/C++ outline files from Idris are reference-only).
2. Keep existing weirdutils features working (screenshot/interact/addon load).
3. Split code into focused modules; avoid giant monolith file growth.
4. Maintain x86 WoW 1.12.1 calling-convention correctness.
5. Preserve hook-chain safety (do not break existing detours).

## Desired Source Layout (implement this or a clearly better equivalent)
Create these Zig modules under `src/outline/`:
- `offsets.zig` – constants for addresses/offsets
- `types.zig` – enums/structs (object types, vectors, draw categories)
- `wow.zig` – game memory access wrappers
- `tracker.zig` – per-frame model/category tracking state
- `model_hook.zig` – WoW render pipeline hooks for model classification
- `d3d9_hook.zig` – D3D9 DIP/EndScene hook logic for outline rendering
- `shader.zig` – optional shader helpers/constants (if used)
- `api.zig` – public init/reset/config functions exposed to main

Also update:
- `src/main.zig` (initialize/cleanup outline subsystem)
- `build.zig` (if needed for new modules)
- `src/addon/WeirdUtils.lua` (outline command UX/status)

## Behavior Requirements
Implement category-based outlines:
- Dead friendly players/corpses: through-wall style visibility
- Raid-marked units: clear colored outlines
- Current target (enemy NPC): emphasized outline

Implement robust per-frame reset + repopulation logic to avoid stale tracking.

## Implementation Phases
### Phase 1 – Mapping + verification
- Use Ghidra + references to verify prologues and hook patch sizes.
- Produce a concise mapping note in `docs/outline-port-notes.md`.

### Phase 2 – Core Zig architecture
- Create modular outline subsystem under `src/outline/`.
- Port tracking/state logic and category assignment.

### Phase 3 – Hook integration
- Implement render hooks with safe trampoline usage using existing Zig hook patterns.
- Integrate into weirdutils startup/shutdown flow.

### Phase 4 – User controls + defaults
- Add `/wu outline` command family:
  - `/wu outline on`
  - `/wu outline off`
  - `/wu outline status`

### Phase 5 – Validation
- Ensure weirdutils still builds for x86 windows msvc.
- Smoke-check no regressions in interact/screenshot command registration paths.
- Add a brief test checklist in `docs/outline-validation.md`.

## Deliverables
1. Pure Zig outline subsystem in separated files.
2. Updated integration in main/addon.
3. `docs/outline-port-notes.md` with verified hook/prologue decisions.
4. `docs/outline-validation.md` with run/test checklist.
5. Final summary with changed files and known limitations.

## Guardrails
- Do not run destructive git operations.
- Do not remove existing features.
- If a prologue/callconv is uncertain, verify in Ghidra before patching.

## Completion Signal
When fully done, run:
`openclaw system event --text "Done: pure Zig outline port implemented in weirdutils" --mode now`

Then print a short completion summary.