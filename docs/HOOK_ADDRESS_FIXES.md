# Hook Address Analysis and Fixes

**Date:** 2025-12-10
**Tool:** Ghidra MCP + Code Executor

## Critical Address Fixes

### [X] ProcessWorldWithFrustum
- **Old Address:** `0x00683000` (WRONG - no function at this address)
- **Correct Address:** `0x00682fa0`
- **Ghidra Signature:** `undefined __fastcall ProcessWorldWithFrustum(float * frustumBounds)`
- **First Byte:** `0x57` (PUSH EDI)
- **Stolen Bytes:** 9 bytes
- **Status:** [OK] FIXED in discovery_hooks.cpp

### [X] RenderObjectsWithLOD
- **Old Address:** `0x00684600` (WRONG - no function at this address)
- **Correct Address:** `0x00684510`
- **Ghidra Signature:** `undefined __stdcall RenderObjectsWithLOD(void)`
- **First Byte:** `0x55` (PUSH EBP)
- **Stolen Bytes:** 8 bytes
- **Status:** [OK] FIXED in discovery_hooks.cpp

## Verified Correct Addresses

### [OK] ScenePresent
- **Address:** `0x0059a870`
- **Ghidra Signature:** `void __fastcall CGxDeviceD3d::ScenePresent(CGxDeviceD3d * device)`
- **First Byte:** `0x55` (PUSH EBP)
- **Stolen Bytes:** 6 bytes
- **Calling Convention:** __fastcall (saves ECX+EDX) [OK] Correct in code

### [OK] CullAndProcessWorldChunks
- **Address:** `0x00683040`
- **Ghidra Signature:** `undefined __stdcall CullAndProcessWorldChunks(void)`
- **First Byte:** `0x55` (PUSH EBP)
- **Stolen Bytes:** 8 bytes
- **Calling Convention:** __stdcall (no register saves) [OK] Correct in code

### [OK] ProcessStaticObjectsCulling
- **Address:** `0x00683bf0`
- **Ghidra Signature:** `undefined __fastcall ProcessStaticObjectsCulling(int staticObjectManager)`
- **First Byte:** `0x55` (PUSH EBP)
- **Stolen Bytes:** 9 bytes
- **Calling Convention:** __fastcall (saves ECX+EDX) [OK] Correct in code

### [OK] CM2Scene_DrawModelBatch
- **Address:** `0x0070cf70`
- **Ghidra Signature:** `undefined __fastcall CM2Scene_DrawModelBatch(void * renderContext)`
- **First Byte:** `0x55` (PUSH EBP)
- **Stolen Bytes:** 8 bytes
- **Calling Convention:** __fastcall (saves ECX+EDX) [OK] Correct in code

## Calling Convention Summary

| Function | Ghidra Convention | Code Implementation | Status |
|----------|------------------|---------------------|--------|
| ScenePresent | __fastcall | __fastcall (ECX+EDX) | [OK] Correct |
| ProcessWorldWithFrustum | __fastcall | __fastcall (ECX+EDX) | [OK] Correct |
| CullAndProcessWorldChunks | __stdcall | __cdecl (no saves) | OK (both no reg saves) |
| ProcessStaticObjectsCulling | __fastcall | __fastcall (ECX+EDX) | [OK] Correct |
| RenderObjectsWithLOD | __stdcall | __cdecl (no saves) | OK (both no reg saves) |
| CM2Scene_DrawModelBatch | __fastcall | __fastcall (ECX+EDX) | [OK] Correct |

## Prologue Byte Analysis

All functions follow standard x86 calling conventions:

**Common patterns:**
- `0x55` = PUSH EBP (saves base pointer)
- `0x57` = PUSH EDI (saves EDI register)
- Followed by MOV EBP, ESP and SUB ESP, n

**Stolen byte counts:**
- 6 bytes: Minimal prologue (PUSH EBP + MOV EBP,ESP + SUB ESP,small)
- 8 bytes: Standard prologue with one register save
- 9 bytes: Extended prologue with multiple saves or larger stack allocation

## Limitations Encountered

The Ghidra MCP `get_bytes` tool only returns 1 byte regardless of the length parameter. This prevented detailed byte-by-byte prologue verification. However:

1. Function signatures were verified via `get_function_by_address`
2. Decompiled code confirmed function structure
3. First byte at each address was confirmed
4. Calling conventions were verified

## Recommendations

1. [OK] **Address fixes have been applied** to discovery_hooks.cpp
2. [!] **Test the DLL** after recompilation to verify hooks work correctly
3. [!] **Monitor for crashes** that could indicate incorrect stolen byte counts
4. If crashes occur after address fix, use Ghidra GUI to manually count instruction bytes in prologues

## Next Steps

1. Rebuild discovery DLL with corrected addresses
2. Test in WoW to verify hooks execute without crashes
3. If issues persist, manually verify stolen byte counts in Ghidra GUI using:
   - Right-click function → "Listing: Function"
   - Count bytes of first N instructions until reaching or exceeding stolen byte count
   - Ensure no instruction is partially stolen (causes invalid opcode crashes)
