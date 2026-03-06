# WoW 1.12.1 Calling Conventions - Ghidra Verified

All conventions verified against WoW.exe 1.12.1 build 5875 via Ghidra decompilation and raw byte analysis.

## Model Pipeline Hooks (outline/model_hook.zig)

| # | Address | Function | Convention | Params | Prologue | RET | Status |
|---|---------|----------|------------|--------|----------|-----|--------|
| 1 | `0x0070b360` | CM2SceneRenderDraw | `__thiscall` | ECX=this, stack: viewMatrix, batchData, batchIndices, batchCount | `55 8B EC 81 EC 80 00 00 00` (9B) | - | CORRECT |
| 2 | `0x00710b90` | CM2Model_ManageRenderListNode | `__thiscall` | ECX=model, stack: addToList | `55 8B EC 8B 45 08` (6B) | - | CORRECT |
| 3 | `0x0070cb30` | CM2Scene_DrawBatchProjected | `__fastcall` | ECX=renderContext | `55 8B EC 83 EC 10` (6B) | - | CORRECT |

## Game Function Wrappers (outline/wow.zig)

| # | Address | Function | Convention | Params | Prologue | RET | Status |
|---|---------|----------|------------|--------|----------|-----|--------|
| 4 | `0x00515970` | Script_UnitGUID | `__fastcall` | ECX=unitIdStr → EAX:EDX (64-bit) | `55 8B EC 51 56 68 90 00 00 00` | - | CORRECT |
| 5 | `0x00464870` | GetObjectByGUID | **`__stdcall`** | **stack: guidLow, guidHigh → EAX** | `55 8B EC 8B 45 08 8B 4D 0C` | **RET 8** | **FIXED** - was incorrectly using `hook.fastcall` |
| 6 | `0x006061E0` | CGUnit_C::UnitReaction | `__thiscall` | ECX=localPlayer, stack: unit → EAX (reaction int) | `53 8B DC 83 EC 08 83 E4 F8` | - | CORRECT |

### GetObjectByGUID Detail

Disassembly at `0x464870`:
```
55          PUSH EBP
8B EC       MOV EBP, ESP
8B 45 08    MOV EAX, [EBP+8]     ; guidLow from STACK (not ECX!)
8B 4D 0C    MOV ECX, [EBP+C]     ; guidHigh from STACK (not EDX!)
8B D0       MOV EDX, EAX
0B D1       OR  EDX, ECX          ; test if guid == 0
74 0B       JZ  return_zero
51          PUSH ECX              ; push guidHigh for inner call
50          PUSH EAX              ; push guidLow for inner call
E8 ...      CALL FindObjectByGUID
5D          POP EBP
C2 08 00    RET 8                 ; callee cleans 8 bytes
```

The C++ reference declared this as `__fastcall(uint64_t)`. Under MSVC, `uint64_t` (8 bytes) is too large for a single 32-bit register, so `__fastcall` passes it on the stack - making it behave like `__stdcall`. The Zig code split it into two `u32` args and passed them in ECX/EDX via `hook.fastcall`, which was wrong.

The transmog addon (`transmogfix/src/main.zig:134`) and interact module (`weirdutils/src/interact.zig:50`) already had the correct push-to-stack implementation.

## Dead Overlay Functions (not yet ported - for future reference)

| # | Address | Function | Convention | Params | Status |
|---|---------|----------|------------|--------|--------|
| 7 | `0x00483EE0` | WorldProjection_WorldToScreenCoords | `__thiscall` | ECX=WorldFrame, stack: float* worldXYZ, float* screenXYZ → uint (bool) | VERIFIED |
| 8 | `0x0041ADE0` | DDCToNDC | `__fastcall` | ECX=float* outX, EDX=float* outY, stack: float inX, float inY | VERIFIED |
| 9 | `0x00609210` | CGUnit_C::GetUnitName | `__thiscall` | ECX=unit, stack: uint** param → char* | VERIFIED |
| 10 | `0x006264E0` | GetObjectName | `__fastcall` | ECX=uint64_t* guidPtr → char* | VERIFIED |

## Lua API (main.zig)

All WoW 1.12.1 Lua C API functions use `__fastcall` with L (lua_State*) in ECX.

| # | Address | Function | Convention | Params | RET | Status |
|---|---------|----------|------------|--------|-----|--------|
| 11 | `0x00704120` | FrameScript::Register | `__fastcall` | ECX=name, EDX=funcAddr | - | CORRECT |
| 12 | `0x006F3070` | lua_gettop | `__fastcall` | ECX=L → int | RET | CORRECT |
| 13 | `0x006F3080` | lua_settop | `__fastcall` | ECX=L, EDX=index | - | CORRECT |
| 14 | `0x006F3350` | lua_pushvalue | `__fastcall` | ECX=L, EDX=index | - | CORRECT |
| 15 | `0x006F3400` | lua_type | `__fastcall` | ECX=L, EDX=index → int | RET | CORRECT |
| 16 | `0x006F3510` | lua_isstring | `__fastcall` | ECX=L, EDX=index → int | RET | CORRECT |
| 17 | `0x006F3690` | lua_tostring | `__fastcall` | ECX=L, EDX=index → char* | - | CORRECT |
| 18 | `0x006F39F0` | lua_pushboolean | `__fastcall` | ECX=L, EDX=bool | - | CORRECT |
| 19 | `0x006F3890` | lua_pushstring | `__fastcall` | ECX=L, EDX=string | - | CORRECT |
| 20 | `0x006F3810` | lua_pushnumber | `__fastcall` | ECX=L, stack: f64 (8 bytes) | RET 8 | CORRECT |
| 21 | `0x006F3920` | lua_pushcclosure | `__fastcall` | ECX=L, EDX=func, stack: nupvalues | - | **FIXED** - was 0x6F3B80 (wrong addr) |
| 22 | `0x006F4940` | luaL_error | `__cdecl` | stack: L, fmt, ... | - | CORRECT |
| 23 | `0x006F4DC0` | luaL_openlib | `__fastcall` | ECX=L, EDX=libname, stack: funcs, nup | - | CORRECT |

### lua_pushcclosure Detail

Ghidra search found `lua_pushcclosure @ 006f3920`. No function exists at the old address `0x6F3B80` - it falls mid-body of another function. The wrapper was unused (never called from current code) so no crash occurred.

### lua_pushnumber Detail

Takes a `double` (8 bytes) which is too large for EDX, so it goes on the stack per `__fastcall` rules. Callee cleans with `RET 8`. The inline asm workaround in `weirdUtilsVersion` correctly does `SUB ESP,8; FSTPL (ESP); CALL` and relies on `RET 8` to rebalance.

## File/Addon Hooks (main.zig)

| # | Address | Function | Convention | Params | Prologue | RET | Status |
|---|---------|----------|------------|--------|----------|-----|--------|
| 24 | `0x0042a320` | ValidateFunctionPointer | `__fastcall` | ECX=addr | `55 8B EC 83 EC 40` (6B) | - | CORRECT (empty detour) |
| 25 | `0x00648620` | LoadFileWithTextureResourceFallback | `__stdcall` | 7 stack params | `55 8B EC 8B 4D 1C` (6B) | RET 0x1C | CORRECT |
| 26 | `0x00490250` | FrameScript_RegisterAllSystemCommands | `void(void)` | none | `56 E8 ...` (6B) | - | CORRECT (fixup at offset 1) |
| 27 | `0x0051F600` | LoadAddonsRecursively | `__fastcall` | ECX=error_handler | `53 8B 1D ...` (7B) | - | CORRECT |
| 28 | `0x006EDB90` | loadFileListWithIncludes | `__fastcall` | ECX=path, EDX=md5ctx, stack: error_handler | `55 8B EC 6A FF ...` | RET 4 | CORRECT |
| 29 | `0x004B6F70` | LoadUIBindingsFromFile | `__thiscall` | ECX=binding_mgr, stack: path, md5ctx, callback | `55 8B EC 81 EC 1C 04 00 00` | RET 0x0C | CORRECT |
| 30 | `0x0046a400` | GameEngine_MainInitialize | `void(void)` | none | `55 8B EC 83 EC 28` (6B) | - | CORRECT |
| 31 | `0x00490BD0` | World_HandlePlayerLogin | `void(void)` | none | `56 E8 ...` (6B) | - | CORRECT (fixup at offset 1) |

### Note on #31

Ghidra names this `World_HandlePlayerLogin`, not `CGGameUI_Shutdown`. The Zig hook's detour just calls the original with no extra logic, so the naming discrepancy has no functional impact.

## Utility Functions

| # | Address | Function | Convention | Params | RET | Status |
|---|---------|----------|------------|--------|-----|--------|
| 32 | `0x006462E0` | M2_AllocateModelBuffer | `__stdcall` | stack: size, source_file, line, flags | RET 0x10 | CORRECT |
| 33 | `0x007040D0` | FrameScript::GetContext | `void(void)` | none → lua_State* in EAX | RET | CORRECT (trivial: `MOV EAX,[global]; RET`) |

## Bugs Fixed (2026-02-24)

1. **GetObjectByGUID** (`outline/wow.zig`): Changed from `hook.fastcall(u32, 0x464870, lo, hi)` to inline asm `push hi; push lo; call`. The function reads params from stack `[EBP+8]`/`[EBP+C]` and does `RET 8`.

2. **lua_pushcclosure** (`main.zig`): Changed address from `0x6F3B80` to `0x6F3920`. The old address pointed into the middle of another function's body.
