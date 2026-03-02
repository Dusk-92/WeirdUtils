# M2 Model Loading Research

## Root Cause (Confirmed)
M2 model loading uses `openFileWithOptions` (0x6477c0) directly — it **never** goes through our hooked `LoadFileWithTextureResourceFallback` (0x648620). That's why embedded M2 files aren't served.

## M2 Loading Call Chain
```
createModelAttachment (0x707350)
  → loadResourceByPath (0x706a50)
    → openFileWithOptions (0x6477c0)     ← file not found, returns NULL
    → loadModelFromFileAsync (0x71d4e0)  ← never reached
  → falls back to ErrorCube.mdx
```

## File Context Structure (0x60 bytes, allocated by openFileWithOptions)
- **+0x00**: type (0=disk, 1=validated disk, 2/3=storage, 4=archive)
- **+0x04**: file handle pointer (disk types)
- **+0x0C**: path string
- **+0x14**: pre-read size (type 1)
- **+0x24**: critical section
- **+0x3C**: stream handle (types 2/3)
- **+0x40**: archive handle (type 4)

## Calling Conventions (verified from disasm)
| Function | Convention | Params | RET |
|---|---|---|---|
| `openFileWithOptions` (0x6477c0) | `__stdcall` | 4 | `RET 0x10` |
| `GetFileSizeFromHandle` (0x6487f0) | `__stdcall` | 2 | `RET 0x08` |
| `ReadFileFromMultipleSources` (0x648460) | `__stdcall` | 5 | `RET 0x14` |
| `CleanupFileHandleResources` (0x648730) | `__stdcall` | 1 | `RET 0x04` |
| `loadModelFromFileAsync` (0x71d4e0) | `__thiscall` | ECX=this, 2 stack | `RET 0x08` |

## GetFileSizeFromHandle (0x6487f0) — dispatches on context type
- Type 0: `fstatFileHandle(ctx[1]+0x10)` — needs real file handle
- Type 1: returns `ctx[5]` (value at +0x14) — **simplest, just returns a stored value**
- Types 2/3: `GetAudioStreamPosition(ctx[0xf])`
- Type 4: `getFileSize(ctx[0x10])`

## ReadFileFromMultipleSources (0x648460) — dispatches on context type
- Type 0: `fileReadWithLock(buffer, 1, size, ctx[1])` — needs real file handle
- Other types: use respective handle fields

## initializeFileContext (0x647290) — __thiscall, ECX=ctx, 1 stack param (type)
```c
TraverseListNodes((LPCRITICAL_SECTION)(this + 0x24));  // init critical section
*(uint *)this = param_1;        // +0x00: type
*(uint *)(this + 0x04) = 0;     // file handle
*(uint *)(this + 0x08) = 0;
*(uint *)(this + 0x0C) = 0;     // path
*(uint *)(this + 0x18) = 0;
*(uint *)(this + 0x3C) = 0;
*(uint *)(this + 0x40) = 0;
*(uint *)(this + 0x54) = 0;
*(uint *)(this + 0x58) = 0;
*(uint *)(this + 0x10) = 0;
*(uint *)(this + 0x5C) = 0;
*(uint *)(this + 0x1C) = 0;
```

## CleanupFileHandleResources (0x648730) — __stdcall, 1 param, RET 0x04
```c
if (ctx + 0x04 != NULL) closeFileStreamSafely(ctx + 0x04);   // disk file handle
if (ctx + 0x3C != 0)    Stream_CompareBuffers(ctx + 0x3C);   // stream
if (ctx + 0x40 != NULL) closeArchiveFile(ctx + 0x40);         // archive
// then frees path at +0x0C, buffer at +0x18, context at +0x1C
// calls cleanupFileContext (0x6472d0) on the 0x60-byte struct
// frees the struct itself
```

## Async Task Structure (from loadModelFromFileAsync)
```
+0x00: file handle context
+0x04: destination buffer ptr
+0x08: data size
+0x0C: model object (callback context)
+0x10: onModelLoadComplete callback
+0x14: error callback (0x71d610)
+0x18: 0
+0x1C: byte 0
+0x1D: byte 1
+0x28: byte 0
```
Queued via `AsyncTask_QueueForExecution` (0x443ae0). Executor reads from file handle into buffer, then calls completion callback.

## loadResourceByPath (0x706a50) — __thiscall, ECX=resourceMgr
After `openFileWithOptions` succeeds:
1. Allocates 0x164-byte model object via `M2_AllocateModelBuffer`
2. `initializeModelObject(modelObj, resourceMgr)`
3. `loadModelFromFileAsync(modelObj, fileHandle, loadFlags)`
4. On success: copies normalized path into modelObj+0x20, sets up hash links
5. On failure: `CleanupFileHandleResources`, free model object, return NULL

## LoadFileWithTextureResourceFallback (0x648620) — our hooked function
Calls `openFileWithOptions(param_1, path, async_flag, &handle_out)`, then:
1. `GetFileSizeFromHandle(handle, NULL)` → size
2. `M2_AllocateModelBuffer(size + extra_alloc)` → buffer
3. `ReadFileFromMultipleSources(handle, buffer, size, &bytesRead, asyncFlag)` → data
4. Returns buffer + size to caller
**Only called by UI/config/addon loaders**, never by M2 model loading.

## The Core Problem
Every file context type needs a **real file handle or archive handle** for the read path. There's no "memory buffer" type. A fake context that works through the normal read pipeline requires either:
- A real handle pointing to our data, or
- Hooking the read functions to detect our fakes and return embedded data

## Hook Options

### Option 1: Triple hook (openFileWithOptions + GetFileSizeFromHandle + ReadFileFromMultipleSources)
- Create fake type-0 context with NULL handle, store data ptr/size in unused fields (+0x30/+0x34)
- GetFileSizeFromHandle hook: detect fake (type 0, +0x04==NULL, +0x30!=0), return +0x34
- ReadFileFromMultipleSources hook: detect fake, memcpy from +0x30
- **Risk**: async executor might call fileReadWithLock directly, bypassing ReadFileFromMultipleSources

### Option 2: Hook loadModelFromFileAsync
- After openFileWithOptions succeeds with fake context, fill buffer synchronously
- Call onModelLoadComplete directly, skip async task
- **Need**: onModelLoadComplete address, setCullMode (allocator) address
- **Risk**: completion callback may expect async-specific state

### Option 3: Hook openFileWithOptions only
- Make it produce a context that works through existing read pipeline
- **Hardest** — requires understanding all read paths for the chosen type

## Implementation: In-Memory File Serving (chosen: Option 1 extended)

### Implemented Hooks
5 hooks at the Storm file I/O layer, plus the existing `loadFileDetour` at 0x648620:

| Hook | Target | Convention | Prologue | Purpose |
|---|---|---|---|---|
| `openFileDetour` | 0x6477c0 | `__stdcall(4)` | 9 bytes | Create fake file context for embedded files |
| `getFileSizeDetour` | 0x6487f0 | `__stdcall(2)` | 6 bytes | Return embedded data size |
| `readFileDetour` | 0x648460 | `__stdcall(5)` | 6 bytes | memcpy embedded data (sync+async) |
| `processAsyncDetour` | 0x647350 | `__fastcall(ECX)` | 7 bytes | Serve data in async executor path |
| `cleanupFileHandleDetour` | 0x648730 | `__stdcall(1)` | 7 bytes | Free fake context + path |

### Fake File Context Layout
Allocated via `allocateGameBuffer(0x60)`, zero-filled, then:
- `initializeFileContext(ctx, 0)` — sets type=0, inits critsec at +0x24
- `+0x0C`: duplicated path string (game-allocated)
- `+0x30`: embedded data pointer (custom field, points into DLL .rdata)
- `+0x34`: embedded data size (custom field)
- **Detection**: `type==0 && handle(+0x04)==NULL && *(ctx+0x30)!=0`
- Return value from openFileWithOptions: 2 (non-zero = success)

### processAsyncFileOperation (0x647350) — verified via Ghidra
- `__fastcall(ECX=request)`, plain `RET` (c3)
- Request: `+0x08`=file_ctx, `+0x0C`=dest_buf, `+0x10`=read_size, `+0x14`=seek/event struct
- Event handle at `*(*(request+0x14)+4)` — signaled via `SetEvent`
- Cleanup epilogue: decrement `*(ctx+0x5c)`, `LeaveCriticalSection(ctx+0x24)`, signal event, conditional `CleanupFileHandleResources`
- Close-after-read flag at `*(ctx+0x58)`

### CleanupFileHandleResources (0x648730) — verified decompile
```c
void CleanupFileHandleResources(int ctx) {
    if (ctx == 0) return;
    if (*(ctx+0x04)) closeFileStreamSafely(*(ctx+0x04));
    if (*(ctx+0x3C)) Stream_CompareBuffers(*(ctx+0x3C));
    if (*(ctx+0x40)) closeArchiveFile(*(ctx+0x40));
    if (*(ctx+0x08)) { /* check+free sub-buffer */ FreeMemory(*(ctx+0x08)); }
    cleanupFileContext(ctx);     // destroy critsec
    FreeMemory(ctx);             // free 0x60 struct
    // NOTE: does NOT free path at +0x0C — we must free it ourselves
}
```
FreeMemory (SMemFree) at **0x646430** — `__stdcall(ptr, src_str, flags)`.

### Crash: Hook Install Order Matters
**Symptom**: Crash on game load in `loadFileDetour` calling `file_hook.getTrampoline()`.
The trampoline memory (VirtualAlloc'd) contained zeros instead of the saved prologue.

**Analysis**:
- Crash at `0x075D5E88` (trampoline memory) — bytes: `00 00 00 00`
- Return address `0x04AA1542` in weirdutils.dll = `CALL *%eax` in `loadFileDetour`
- `getTrampoline` (compiled at DLL+0x3250) reads `file_hook.trampoline` field from `.data` section at `0x1015c0d8`, checks non-NULL, calls through it

**Root cause**: `LoadFileWithTextureResourceFallback` (0x648620) internally calls `openFileWithOptions` (0x6477c0). If `file_hook` is installed FIRST (copying the 0x648620 prologue to its trampoline), and THEN we patch 0x6477c0, the trampoline's execution context is disrupted. The `file_hook` trampoline runs the original 0x648620 prologue which eventually calls 0x6477c0 — but if 0x6477c0 was patched after the trampoline was built, there may be page-level or VirtualProtect interactions that corrupt the trampoline's allocated memory.

**Fix**: Install Storm I/O hooks (`installFileHooks`) BEFORE `file_hook` at 0x648620. Remove in reverse order.

### Two Async Systems (Confirmed)

There are TWO independent async systems for file I/O:

**1. High-level async task system** (used by M2 model + texture loading):
- Queue: `AsyncTask_QueueForExecution` (0x443ae0)
- Worker: `AsyncTaskWorkerThread` (0x443360) — calls **ReadFileFromMultipleSources** (our hook 3!)
- Main thread: `ProcessAsyncTasksWithTimeLimit` (0x443E70) — calls completion callbacks
- Task structure: `[0]=file_ctx, [1]=buffer, [2]=size, [3]=callback_ctx, [4]=callback_fn`
- For M2 models: callback = `onModelLoadComplete` (0x71d5e0), executor = `asyncFileReader` (0x71d610)
- For textures: callback = `TextureLoadCallback` (0x44a500), queued from `LoadTextureFromPath` (0x44a310)

**2. Low-level file async system** (NOT used for texture/M2 loading):
- `processAsyncFileOperation` (0x647350) — calls **fileReadWithLock** (0x740c97) directly
- Request: `+0x08=file_ctx, +0x0C=dest_buf, +0x10=read_size, +0x14=seek/event`
- Type-dispatched: type 0→fileReadWithLock, type 1→decompressFileData, type 2/3→stream, type 4→archive
- Has close-after-read flag at ctx+0x58, refcount at ctx+0x5c
- NOT installed as a hook — not needed since texture loading uses the high-level system

### onModelLoadComplete (0x71d5e0) — Verified Decompile
```c
void __fastcall onModelLoadComplete(void *modelObject) {
    CleanupFileHandleResources(**(int **)(modelObject + 0xc));  // free file handle via task
    ReturnAsyncTaskToPool(*(int *)(modelObject + 0xc));          // return task
    *(undefined4 *)(modelObject + 0xc) = 0;                      // clear task ptr
    processLoadedModelData(modelObject);                          // process M2 data
}
```
**Critical**: cleanup file handle BEFORE processLoadedModelData. Our hook matches this order.

### cleanupFileContext (0x6472d0) — Verified Decompile
```c
void __fastcall cleanupFileContext(int param_1) {
    if (*(param_1 + 0x1c)) { cleanupInflateContext(*(param_1+0x1c)); FreeMemory(*(param_1+0x1c)); }
    if (*(param_1 + 0x0c)) { FreeMemory(*(param_1 + 0x0c)); }  // path string
    if (*(param_1 + 0x10)) { FreeMemory(*(param_1 + 0x10)); }
    if (*(param_1 + 0x18)) { FreeMemory(*(param_1 + 0x18)); }
    DeleteCriticalSection(param_1 + 0x24);
}
```
NOTE: cleanupFileContext DOES free +0x0C (path string). Do NOT free it manually.

### TextureLoadCallback (0x44a500) — Verified Decompile
```c
void __fastcall TextureLoadCallback(int texture_obj) {
    puVar1 = ProcessTextureData(texture_obj);
    if (puVar1 == NULL) CreateSolidColorTexture(&fallback, texture_obj);
    CleanupFileHandleResources(**(int **)(texture_obj + 0x138));  // task[0] = file ctx
    **(int **)(texture_obj + 0x138) = 0;                          // clear file ctx in task
    ReturnAsyncTaskToPool(*(int *)(texture_obj + 0x138));
    *(int *)(texture_obj + 0x138) = 0;
}
```
Called by ProcessAsyncTasksWithTimeLimit on the main thread after worker completes.

### LoadTextureFromPath (0x44a310) — Texture Async Task Setup
```c
puVar5 = openFileWithOptions(NULL, path, flags, &file_handle);  // hook 1 creates fake
puVar7 = AllocateAsyncTaskObject();
texture_obj[0x4e] = puVar7;                // +0x138 = task ptr
puVar7[3] = texture_obj;                    // task[3] = texture obj
*(task + 0x10) = TextureLoadCallback;       // task[4] = completion callback
*(task + 0x00) = file_handle;               // task[0] = file context
size = GetFileSizeFromHandle(file_handle);  // hook 2 returns size
*(task + 0x08) = size;                      // task[2] = file size
*(task + 0x04) = global_buffer_pool_ptr;    // task[1] = buffer
AsyncTask_QueueForExecution(task);
```

### Current Crash: EIP=0 During TextureLoadCallback
- Crash at EIP=0x00000000 after processLoadedModelData returns 1
- Stack shows TextureLoadCallback (0x44A526 = after CALL CleanupFileHandleResources)
- File context 0x36596088 on stack (was M2 ctx, freed, reused as BLP ctx)
- EDX=0x36596080 (ctx-8), EBP=04AA3212 (in weirdutils.dll — corrupted frame ptr)
- Crash appears to be inside our cleanupFileHandleDetour during BLP context cleanup
- BLP data IS served correctly (AsyncTaskWorkerThread → ReadFileFromMultipleSources → hook 3)
- Investigation ongoing: possible stack corruption in callCleanupFileContext or freeGameBuffer

## Cursor Terrain Position

No single continuously-updated global stores the cursor terrain intersection point.
The raycast runs every frame in `WorldFrameUpdate` (0x481790) but the result is stored
on the stack (local `HitTestResult`) and discarded after dispatch.

### WorldFrameUpdate Flow (every frame)
```
WorldFrameUpdate(this, deltaTime):
  inputHandler = *(this + 0xA0)
  mouseNDC_X = *(inputHandler + 0x1118)
  mouseNDC_Y = *(inputHandler + 0x111C)
  NDCToDDC(&screenX, &screenY, mouseNDC_X, mouseNDC_Y)    // 0x4242F0
  hitType = HitTestPoint(this, screenX, screenY, &localResult)  // 0x481190
  if hitType == 1: HandleGroundTargeting(this, &localResult)    // AoE spell
  if hitType == 2: HandleTargetSelection(this, &localResult)    // object hover
```

### UpdateHitTest (0x481F00) — __fastcall(ECX=worldFrame)
Called on **click events** (not every frame). Performs the same raycast but stores
the result persistently at `worldFrame + 0x350`:
```c
void __fastcall UpdateHitTest(void *worldFrame) {
    NDCToDDC(&screenX, &screenY,
             *(float *)(*(worldFrame + 0xA0) + 0x1118),
             *(float *)(*(worldFrame + 0xA0) + 0x111C));
    hitType = HitTestPoint(worldFrame, screenX, screenY, worldFrame + 0x358);
    *(worldFrame + 0x350) = hitType;
}
```

### WorldFrame HitTestResult Layout (worldFrame + 0x350)
| Offset | Size | Type | Description |
|--------|------|------|-------------|
| +0x350 | 4 | u32 | Hit type (see below) |
| +0x358 | 8 | u64 | Hit object GUID (0 for terrain) |
| +0x360 | 4 | f32 | Terrain intersection X |
| +0x364 | 4 | f32 | Terrain intersection Y |
| +0x368 | 4 | f32 | Terrain intersection Z |
| +0x36C | 4 | f32 | Intersection distance |
| +0x370 | 12 | Vec3 | Ray origin (camera position) |
| +0x37C | 12 | Vec3 | Ray end point |
| +0x388 | 4 | f32 | Ray distance |

### AoE Targeting Reticle Globals (only during spell targeting)
- `0x00B4B3A0` Vec3 — terrain position under cursor (written by HandleGroundTargeting)
- `0x00B4B3B0` f32 — spell targeting radius
- `0x0083DC2C` u32 — validity: 0=valid, 1=out-of-range, 3=updating
- `0x00CECAC0` u16 — spell targeting state flags (0x20=terrain, 0x40=secondary)

### Click-to-Move Destination
- `0x00C4D890` Vec3 — destination (only when CTM initiated)
- `0x00C4D888` u32 — movement mode

### Key Functions
| Address | Name | Convention | Params |
|---------|------|------------|--------|
| 0x481190 | CGWorldFrame::HitTestPoint | __thiscall | ECX=worldFrame, screenX, screenY, *HitTestResult → hitType |
| 0x481790 | WorldFrameUpdate | __thiscall | ECX=worldFrame, deltaTime |
| 0x481F00 | UpdateHitTest | __fastcall | ECX=worldFrame → void |
| 0x4813B0 | GetWorldPositionFromScreenCoords | __thiscall | ECX=worldFrame, screenX, screenY, *rayStart, *rayEnd → bool |
| 0x480DF0 | WorldIntersectionTest | ??? | rayStart, rayEnd, flags, *result → hitType |
| 0x672170 | CWorld_Intersect | __fastcall | rayStart, rayEnd, ignored(0), *hitPoint, *distance, flags → bool |
| 0x4242F0 | NDCToDDC | ??? | outX*, outY*, inNDC_X, inNDC_Y |
| 0x4820F0 | HandleGroundTargeting | __thiscall | ECX=worldFrame, hitResultPtr |
| 0x6E60F0 | Spell_C_HandleTerrainClick | __fastcall | ECX=terrainClickEvent(Vec3*) |

### Approach for Markers
### HitTestPoint / WorldIntersectionTest Return Values
`WorldIntersectionTest(rayStart, rayEnd, gameStateFlags, result)` returns:
- `0` — no intersection (sky) — coords NOT written to result
- `gameStateFlags & 1` — terrain hit — coords written. Returns 1 only during
  AoE targeting (bit 0 set), otherwise returns 0 even on valid terrain hit
- `2` — object hit (closer than terrain)

So hitType=0 is ambiguous: either "terrain hit in normal mode" or "no hit at all".
To distinguish: zero the result coords before calling, then check if they were written.

### Approach for Markers
Call `UpdateHitTest(worldFrame)` to perform the raycast and store result at
`worldFrame+0x350`. Zero intersection coords before the call, then check if
they were populated. This is safe from Lua callbacks — `HitTestPoint`
saves/restores view matrices. The persistent result at `worldFrame+0x358` is
normally only click-updated, but overwriting it is harmless.

---

## Animation System -- Hold Loop Glitch Investigation

### Problem
Marker models have 3 animations: Stand (grow-in), Hold (idle), Decay (shrink-out).
Hold plays successfully after Stand, but has a visual glitch every ~4s where the
model briefly "rotates and changes scale" before recovering. Re-queuing Hold has
zero effect. Extending Hold duration to 300000ms also had zero effect.

### M2 File Analysis (Raid_UI_FX_Yellow.m2)

**Header structure** (v256 with vanilla-only `playableAnimLookup` field):
```
globalSequences: n=4, ofs=343
animations:      n=3, ofs=359
animationLookup: n=160, ofs=563
playableAnimLookup: n=226, ofs=883   (vanilla/BC only, 4 bytes each)
bones:           n=10, ofs=1787
keyBoneLookup:   n=1, ofs=4431
vertices:        n=562, ofs=4433
```

**Animation sequences** (68 bytes each at ofs 359):
| Seq | AnimID | Name  | Time Range        | Duration | Flags  | NextAnim | Alias |
|-----|--------|-------|-------------------|----------|--------|----------|-------|
| 0   | 0      | Stand | 3333-7333         | 4000ms   | 0x00A0 | 1        | 0     |
| 1   | 158    | Hold  | 10666-14666       | 4000ms*  | 0x0020 | 1        | 1     |
| 2   | 159    | Decay | 17999-18665       | 666ms    | 0x00A1 | -1       | 2     |

*Hold was temporarily extended to 300000ms for testing; had no effect on glitch.
The M2 file on disk may still have the extended duration -- needs revert.

**Flag meanings** (from decompiled GetAnimationPathData):
- 0x01: SetBlendTransition
- 0x10: Alternating (ping-pong -- negates direction in path resolution)
- 0x20: Looping (resets direction to 0 in path resolution)
- 0x40: IsAlias
- 0x80: Blended

**Animation lookup table** (160 entries of int16 at ofs 563):
- `animLookup[0] = 0` (Stand -> Seq 0) -- CONFIRMED working
- `animLookup[158] = 1` (Hold -> Seq 1) -- CONFIRMED working
- `animLookup[159] = 2` (Decay -> Seq 2) -- CONFIRMED working
- All other entries = -1

**Global sequences**: GS[0]=16033ms (rotation), GS[1]=3533ms, GS[2]=3867ms, GS[3]=2200ms

**NOTE**: Stand has `nextAnim=1` pointing to Hold. This is the M2 file's built-in
transition from Stand to Hold. The engine may use this for automatic chaining.

### Decompiled Animation Functions

#### GetAnimationPathData (0x711bf0) -- Inner resolver, 392 bytes
Resolves an animation index to a valid animation path. Called per-frame during
bone transform and also during PlayBoneAnimation setup.

**Logic flow**:
1. Check if `animationIndex < nGlobalSequences` (m2data+0x2c): if so, return
   global sequence data from array at m2data+0x30. This is for bone tracks
   driven by global sequences (indices 0-3 for our model).
2. Otherwise, look up in animation lookup table at m2data+0x28 (array of int16,
   indexed by animation ID). If `animLookup[animId] != -1`, found.
3. If not in local table, walk the GLOBAL animation table at PTR_00c0e070.
   Each entry has +0x14=flags and +0x18=nextAnimID. Follows chain with:
   - Flag 0x10: alternating (negate direction)
   - Flag 0x20: looping (stop advancing)
4. If chain dead-ends, falls back to default animation:
   - If animLookup[0] != -1 -> fallback = Stand (anim 0)
   - Else if animLookup[147] != -1 -> fallback = 147
   - Else -> first animation in sequence table

**For our model**: animLookup[158]=1, so Hold is found directly in step 2.
No fallback occurs. **Eliminates fallback-to-Stand as glitch cause.**

#### GetAnimationPathData wrapper (0x711a20) -- 392 bytes
Higher-level wrapper called by ApplyComplexTransformWithAnimation.
1. Calls inner resolver to get animation index
2. Calls `GetAnimationIndex` to convert to sequence index
3. Follows `nextAnimation` chain in M2 sequence data (param_2 times)
4. Returns sequence flags, duration, bounding box from 0x44-byte sequence record

**Sequence record layout** (at m2data+0x20, each 0x44 bytes):
- +0x04/+0x08: startTimestamp/endTimestamp
- +0x0C: moveSpeed
- +0x10: flags
- +0x24..+0x3B: bounding box
- +0x3C: nextAnimation field
- +0x40: aliasNext

#### SetBoneAnimationTiming (0x7127f0) -- 275 bytes, __thiscall
Sets timing offsets for a bone animation. When model+0x10==0, buffers command.
Otherwise: resolves bone index, checks bone+0xA4 != -1 (active anim), updates
timing offsets at bone+0xA8 and bone+0xAC via __ftol conversions.
**NOT the animation timer advance function.**

#### SetBoneAnimationSpeed (0x712910) -- 373 bytes, __thiscall
Similar structure to SetBoneAnimationTiming. Sets speed-related values at
bone+0xB0 and bone+0xB4. **NOT the animation timer advance function.**

#### PrepareModelForRender (0x710450) -- 193 bytes, __thiscall
Per-frame entry for texture readiness. When model+0x10==0, calls LoadPlayerModelData.
Iterates texture array at this+0xA4, calls GetTextureBuffer for each.
Recursively prepares attached models via linked list at this+0x1DC.
Returns 0 (not ready) or 1 (ready). **Textures only, no animation logic.**

#### ApplyComplexTransformWithAnimation (0x7106c0) -- 951 bytes, __thiscall
Per-bone transform computation. Called during rendering.
1. Sets identity matrix at this+0xBC
2. Applies translation, rotation from params
3. Handles billboard types (model type flags & 3)
4. Calls `GetModelAnimationDataAtIndex(this, 0xFFFFFFFF, &local_2c)` to get
   current bone animation state
5. Calls wrapper `GetAnimationPathData(this, animId, count, &outData)` to
   resolve animation path
6. Extracts movement type from flags (bits 1-3)
7. Calculates blend factor based on movement type
8. Blends between rest matrix and animation target matrix
**Calls**: ApplyTranslationMatrix, rotateParticleMatrixByAxisAngle,
CreateOrthonormalBasis, GetModelAnimationDataAtIndex, GetAnimationPathData,
scaleMatrix4x4, addMatrix4x4, scaleMatrix3x3ByVector

#### updateAnimationTransform (0x714000) -- 521 bytes, __fastcall
Parent transform propagation for scene objects. Checks transform_sync_value
against animation_context_ptr+0x10. Calls transformMatrix4x4 with various
matrix parameters. Handles parent-child bone attachment transforms.

#### transformMatrix4x4 (0x714260) -- 17703 bytes!, __thiscall
The MAIN per-frame bone transform function. Iterates all bones (0x118 stride),
reads animation state, samples keyframes, computes final bone matrices.
Called by renderFrame (0x707680) twice per frame, and by updateAnimationTransform.
**Too large for full decompilation -- needs targeted analysis of the timer
advance and loop handling code within it.**

### Key Functions in Animation Range (0x710000-0x715000)

| Address    | Name                               | Size    | Role |
|------------|-------------------------------------|---------|------|
| 0x7106c0   | ApplyComplexTransformWithAnimation  | 951     | Per-bone transform with animation blend |
| 0x710450   | PrepareModelForRender               | 193     | Texture readiness check |
| 0x710b90   | CM2Model_ManageRenderListNode       | 90      | Render list add/remove |
| 0x711a20   | GetAnimationPathData (wrapper)      | 392     | Animation resolver + sequence data |
| 0x711bf0   | GetAnimationPathData (inner)        | ~350    | Animation ID fallback chain |
| 0x7119a0   | GetAnimationSequenceLength          | 122     | Duration query |
| 0x711fe0   | GetModelAnimationDataAtIndex        | ?       | Read bone animation state |
| 0x712090   | GetBoneCurrentAnimation             | 78      | Current anim ID for bone |
| 0x7120e0   | GetBoneAnimationTime                | 108     | Current timer for bone |
| 0x7121a0   | CM2Model__PlayBoneAnimation         | ~600    | Set/queue animation |
| 0x7127f0   | SetBoneAnimationTiming              | 275     | Timing offset adjustment |
| 0x712910   | SetBoneAnimationSpeed               | 373     | Speed adjustment |
| 0x712f70   | InitializeAnimationNode             | 168     | Initial bone setup |
| 0x713d50   | findInterpolationIndices            | 334     | Keyframe index lookup |
| 0x713ea0   | interpolateAnimationKeyframes       | 337     | Keyframe interpolation |
| 0x714000   | updateAnimationTransform            | 521     | Parent transform propagation |
| 0x714260   | transformMatrix4x4                  | 17703   | Main bone transform engine |

### Bone Entry Structure (0x118 bytes per bone, array at model+0x90)

From PlayBoneAnimation decompilation:
- +0x08..+0x28: active animation parameters
- +0xA4: animation ID or sequence index (checked against -1 for "none")
- +0xA8, +0xAC: timing offsets (set by SetBoneAnimationTiming)
- +0xB0, +0xB4: speed values (set by SetBoneAnimationSpeed)
- +0xD0..+0xE4: queued animation data (0xFFFFFFFF = empty)
- +0x100/+0x104: blend weight/timer (used by blendMode=1)
- +0x110: queue prev ptr (linked list)
- +0x114: queue next index

### Xref Map

**PlayBoneAnimation (0x7121a0) callers**:
- CM2Model_LoadInstanceData (0x70ebd0) -- during model init
- HandleUnitAnimationEvent (0x5fc3f0) -- twice
- PlayAnimationWithSpeed (0x76cf80) -- Lua/script wrapper
- RenderCharacterPortrait (0x524f60) -- character screen
- configureDebugOutput (0xd06060) -- debug

**GetAnimationPathData (0x711bf0) callers**:
- GetAnimationPathData wrapper (0x711a20) -- main per-frame path
- CM2Model__PlayBoneAnimation (0x7121a0) -- animation setup
- CM2Model_LoadInstanceData (0x70ebd0) -- model init
- GetAnimationSequenceLength (0x7119a0) -- duration query

**transformMatrix4x4 (0x714260) callers**:
- renderFrame (0x707680) -- twice per frame
- transformMatrix4x4 itself (recursive for children)
- renderSceneNode (0x718960)
- updateAnimationTransform (0x714000)

### Remaining Investigation

**The actual animation timer advance function has NOT been found yet.**
None of the decompiled functions contain the per-frame timer increment,
duration comparison, or loop-end handling logic. The timer advance is most
likely inside `transformMatrix4x4` (0x714260, 17703 bytes) which is too
large for a single decompilation pass. It needs targeted analysis:

1. Search within transformMatrix4x4 for duration comparison patterns
2. Find where bone+0xA8/0xAC timing values are read and updated
3. Find where the loop flag (0x20) is checked during playback
4. Find where queued animation (+0xD0) is activated

**Alternative approach**: Add runtime debug logging to dump bone entry fields
(active anim at +0x08, timer at bone+0xA8/+0xAC, queued at +0xD0) every frame
around the 4s mark to see what changes at the glitch point.

**Global sequence hypothesis**: GS[1]=3533ms and GS[2]=3867ms are close to
4s. Particle system or bone track resets at global sequence boundaries could
cause the visual glitch. Need to identify which bone tracks use global sequences.

---

## World Teardown — Entity Cleanup Crash Investigation

### Crash Details
- **Crash function**: 0x687220 — generic linked-list unlink operation
  - First crash at 0x687243: `mov [edx], esi` — write to freed memory
  - Second crash at 0x687221: `mov esi, [ecx]` — read from freed memory
- **When**: Logout to character select, map transitions — NOT during normal gameplay
- **Thread**: Background/worker thread (very short stack: WoW.exe → kernel32 → ntdll)
- **Root cause**: WDOODADDEF heap teardown iterates linked list, hits freed or corrupt node

### Decompiled Crash Function (0x687220)
```c
// Linked-list unlink — removes node from intrusive doubly-linked list
void __fastcall UnlinkFromList(int *param_1) {
    int prev = *param_1;        // param_1[0] = prev pointer
    if (prev != 0) {
        uint next = param_1[1]; // param_1[1] = next pointer
        int *target;
        if (((next & 1) == 0) && (next != 0)) {
            target = (int *)((int)param_1 + (next - *(int *)(prev + 4)));
        } else {
            target = (int *)(next & 0xfffffffe);
        }
        *target = prev;                    // target->prev = param_1->prev
        *(int *)(*param_1 + 4) = param_1[1]; // param_1->prev->next = param_1->next
        *param_1 = 0;
        param_1[1] = 0;
    }
}
```

### Crash Callers (who calls 0x687220)
- `CleanupMapDoodadContainer` (0x6a1280)
- `MapDoodadDestructor` (0x6a14d0)
- `CleanupDoodadList` (0x6a1725)
- `cleanup_data_structures` (0x67f4b5)
- `CreateUnitModelObject` (0x694c00)
- `FindOrCreateWorldUnit` (0x694f00)
- `InsertIntoHashTable` (0x696060)
- `RehashContainer`, `ResizeContainer`, `ReallocateContainer` (hash table ops)
- Two unnamed functions at 0x69f784 and 0x69f7b5 (the actual crash callers from stack)

### World Teardown Chain (Ghidra-verified)
```
CleanupWorldAndEntities (0x66fc40) — void(), no params, __stdcall
├── CleanupEntityList_ProcessAll()       ← iterates UNKNOWN list
└── CleanupWorldAndReleaseResources (0x697ac0)
    ├── ClearWorldObjectsAndResetState (0x6a6710)  ← iterates linked list at PTR_00c96088
    │   └── destroyPrimaryGameObject() on each
    ├── ... iterate PTR_00c92078 array ...
    ├── ComplexMemoryCleanupAndRelease on remaining
    └── destroyWorldEnvironment / cleanupGameObject on remaining
```

### Callers of CleanupWorldAndEntities (0x66fc40)
- `InitializeWorldScene` (0x401bc0) — **map change** (cleans old world before loading new)
- `ShutdownClientSystems` (0x401ee0) — **full game exit**

### Callers of ClearWorldObjectsAndResetState (0x6a6710)
- `LoadWorldMap` (0x6941f0) — map loading
- `UpdateWorldAndGameObjects` (0x698390) — periodic world update (chunk unloading?)
- `CleanupWorldAndReleaseResources` (0x697ac0) — full teardown
- `SimpleWorldUpdate` (0x694920)

### Entity Type Dispatch in CleanupEntity_ProcessAttachments (0x670d50)
```c
void __fastcall CleanupEntity_ProcessAttachments(entity) {
    // Walk and free attachment children via entity[8] linked list
    while (memoryObject = entity[8], ...) {
        ComplexMemoryCleanupAndRelease(memoryObject);
    }
    // Decrement refcount
    *(short *)(entity + 0x0E) -= 1;
    // Dispatch to type destructor
    if (entity[2] & 0x8) {
        destroyWorldEnvironment(entity);   // → DestroyDataStructureAndRelease
    } else if (entity[2] & 0x40) {
        cleanupGameObject(entity);         // → CleanupVisualEffectAndRelease
    }
}
```
- M2 entities (CreateWorldUnit → WDOODADDEF heap) have flag 0x40
- WMO entities (CreateGameObject → WMAPOBJDEF heap) have flag 0x8
- Ghidra names are misleading — `cleanupGameObject` handles M2/WDOODADDEF, `destroyWorldEnvironment` handles WMO/WMAPOBJDEF

### CleanupEntity_ProcessAttachments Callers (ONLY 3 in entire binary)
- `processCinematicExit` (0x6e4940)
- `executeSpellOrItem` (0x6e54f0)
- `DestroyPathObjectIfPresent` (0x5f4950)
- **NOT called by CleanupEntityList_ProcessAll** or any teardown function

### WDOODADDEF Heap (0xCA7E20) References
- `AllocateRenderableObject` (0x6a07f7) — allocates from heap
- `CleanupVisualEffectAndRelease` (0x6a0916) — frees to heap
- `InitializeWorldSystem` (0x691f4f) — initializes heap
- `CleanupWorldSystem` (0x692241) — tears down heap
  - Called by `ShutdownAllGameSystems` (0x66fb00)

### Other Key Addresses
- `ShutdownAllGameSystems` (0x66fb00) → calls CleanupWorldSystem
- `CleanupWorldSystem` (0x6920c0) → called by ShutdownAllGameSystems
- `cleanupSecondaryResources` (0x6a6c70) → called from CleanupWorldAndEntities + CleanupWorldSystem
  - This calls `cleanupGameObject` (0x6a67a0) and `destroyWorldEnvironment` (0x6a6870) on entities
- `gameQuit` (0x41f9b0) — fires on disconnect/quit (ref: UnitXP_SP3)

### World Unit Hash Table (0xCA7DC0) — The Crash Structure

The crash occurs during teardown of a **hash table at 0xCA7DC0** that tracks all world units
(doodads created via `CreateWorldUnit`). Our entities ARE in this table.

**Hash table structure** (globals at 0xCA7DC0-0xCA7DE4):
| Offset   | Global         | Purpose                                    |
|----------|----------------|--------------------------------------------|
| 0xCA7DC0 | vtable ptr     | Points to 0x0081089c (DestroyMapDoodadDef)  |
| 0xCA7DC4 | global list    | Head of "all entries" linked list           |
| 0xCA7DC8 | sentinel       | List sentinel/header                        |
| 0xCA7DCC | iteration ptr  | **Iterated during teardown crash loop**     |
| 0xCA7DD0 | count          | Zeroed during cleanup                       |
| 0xCA7DD4 | (unknown)      |                                             |
| 0xCA7DD8 | bucket count   | Array length                                |
| 0xCA7DDC | bucket array   | Hash buckets (0xC bytes each)               |
| 0xCA7DE4 | hash mask      | 0xFFFFFFFF = not initialized                |

**References to these globals**:
- `CreateWorldUnit` (0x694980): writes 0xCA7DC0, 0xCA7DC4, 0xCA7DDC (registers entities)
- `CreateUnitModelObject` (0x694c00): writes 0xCA7DC0, 0xCA7DDC
- `FindOrCreateWorldUnit` (0x694e90): reads 0xCA7DC4, 0xCA7DDC
- `complexListInitializerWithCleanup` (0x69f670): reads/writes ALL (init + teardown)

### CreateWorldUnit (0x694980) — Entity Registration (Decompiled)

`CreateWorldUnit` inserts entities into **three** linked lists:
```c
int *CreateWorldUnit(char *modelPath, float *pos, float facing, int param4) {
    // 1. Check if entity already exists in hash table (by path hash + param4)
    if (PTR_00ca7de4 != 0xFFFFFFFF) {
        // Search bucket: PTR_00ca7ddc[hash & mask].list
        // Compare entity[0x2d] == modelPath and entity[0x32] == param4
        // If found, return existing entity (no duplicate creation)
    }

    // 2. Allocate new entity from WDOODADDEF heap
    unitObject = AllocateRenderableObject();

    // 3. Initialize hash table if needed
    if (PTR_00ca7de4 == 0xFFFFFFFF) InitializeHashTable(0xca7dc0);

    // 4. INSERT into hash bucket linked list
    ManageLinkedList(PTR_00ca7ddc + bucket * 0xc, unitObject, 2, 0);

    // 5. INSERT into global "all entries" linked list (PTR_00ca7dc4)
    ManageLinkedList(&PTR_00ca7dc4, unitObject, 2, 0);

    // 6. INSERT into THIRD linked list (PTR_00c89f0c)
    piVar2 = PTR_00c89f08 + unitObject;  // node at entity + offset
    *piVar2 = PTR_00c89f0c;
    piVar2[1] = *(PTR_00c89f0c + 4);
    *(PTR_00c89f0c + 4) = unitObject;
    PTR_00c89f0c = piVar2;

    // 7. Store hash key and setup fields
    unitObject[0x2d] = modelPath;  // path hash for lookup
    unitObject[0x32] = param4;
    // ... copy position, set up model, etc.
}
```

**Critical**: Entity is in 3 lists. All 3 must be unlinked during cleanup.

### CleanupVisualEffectAndRelease (0x6a0840) — What It Unlinks

`CleanupVisualEffectAndRelease` unlinks from up to **three** linked lists:
```c
void CleanupVisualEffectAndRelease(entity) {
    // 1. Remove visual effect handle
    if (entity[0x5a]) RemoveVisualEffectByHandle(entity[0x5a]);

    // 2. Unlink from list at entity[4]/entity[5]  (PTR_00ca7dc4 global list?)
    if (entity[4] != NULL) { /* unlink prev/next */ }

    // 3. Unlink from list at entity[0x2e]/entity[0x2f]  (conditional)
    if (entity[0x2f] != NULL) {
        /* unlink entity[0x2e]/entity[0x2f] */
        /* unlink entity[0x30]/entity[0x31] */
    }

    // 4. Free entity back to WDOODADDEF heap
    // (via ObjectPool_Free or similar)
}
```

**Question**: Does this cover all 3 lists that `CreateWorldUnit` inserts into?
- entity[4]/[5] → PTR_00ca7dc4 global list ✓
- entity[0x2e]/[0x2f] and entity[0x30]/[0x31] → possibly hash bucket + PTR_00c89f0c lists
- But is the **hash bucket list** (inserted via `ManageLinkedList(PTR_00ca7ddc + bucket*0xc, ...)`) also unlinked?

### Crash Caller Disassembly (0x69f760-0x69f7b0)

The crash is in `complexListInitializerWithCleanup` (Ghidra: `registerInitializer5`, 0x69f730).
The specific loop that crashes:
```asm
; Loop: iterate PTR_00ca7dcc linked list, unlink each node
0x69f762: MOV [0xca7dd0], EBX           ; zero the count
0x69f768: MOV ECX, [0xca7dcc]           ; load list head
0x69f76e: TEST CL, 0x1                  ; check sentinel bit
0x69f771: JNZ 0x69f78b                  ; done if sentinel
0x69f773: CMP ECX, EBX                  ; check NULL
0x69f775: JZ 0x69f78b                   ; done if NULL
0x69f777: PUSH ECX                      ; arg: node from list
0x69f778: MOV ECX, 0xca7dc4             ; arg: container base
0x69f77d: CALL 0x687960                 ; ContainerLookup(container, node)
0x69f782: MOV ECX, EAX                  ; result = node in different list space
0x69f784: CALL 0x687220                 ; UnlinkFromList(result) *** CRASH ***
0x69f789: JMP 0x69f768                  ; loop

; Second loop: iterate bucket array
0x69f78b: MOV EAX, [0xca7dd8]           ; bucket count
0x69f797: MOV EAX, [0xca7ddc]           ; bucket array base
; ... iterate each bucket, unlink nodes ...
```

**Key insight**: The teardown iterates PTR_00ca7dcc AND the bucket array (PTR_00ca7ddc).
It uses `ContainerLookup(0xca7dc4, node)` to convert from the iteration list to the
global list, then calls `UnlinkFromList` on the global list node.

The crash: `UnlinkFromList` receives ECX pointing to freed heap memory.

### Stack Context from Crash #2 (0x687221)
```
0x40a3a6 in terminateProcessWithCleanup (0x40a34d)  ← atexit handler
0x40a33a in exitNormally (0x40a32f)                  ← game exit path
0x64cc46 in ??? (file I/O area)
```
This confirms the crash is during **game exit**, in the atexit cleanup chain.

### CreateEntityInstance_WithAttachment M2 Path (0x6707c0)

The M2 path (no ".wmo" in path) is straightforward:
```c
positionData = CreateWorldUnit(param_1, param_2, param_3, param_4);
positionData[0x61] = param_7;
positionData[0x60] = param_6;
positionData[0x24] |= 0x2000;  // set flag
if (updateNow) {
    UpdateWorldPosition(positionData, param_2, param_3);
    SetUnitPositionAndOrientation(positionData, param_2, param_3);
}
```
The WMO path additionally inserts into PTR_00c9e350/PTR_00c9e354 spatial grid list.

Only 3 CALLs visible in the function body: `FindSubstringInString`, `CreateGameObject`,
`ModelAttachment_CreateNode`. The M2 path (`CreateWorldUnit`) must be via tail-call or
the decompiler inlined it.

### CleanupWorldAndEntities (0x66fc40) — Full Chain (Decompiled)

```c
void CleanupWorldAndEntities(void) {
    CleanupEntityList_ProcessAll();       // 0x672c40 — iterates PTR_00c7b2dc (NOT hash table)
    CleanupWorldAndReleaseResources();    // 0x697ac0
    PTR_00c7b748 = 0;
}
```

### CleanupEntityList_ProcessAll (0x672c40) — Decompiled

Iterates the linked list at `PTR_00c7b2dc` (NOT the hash table at 0xCA7DC0).
For each entry, calls `CleanupObjectAttachments_FreeMemory` which ends with
`DestroyWorldObjectAndRelease`. Our entities are NOT in `PTR_00c7b2dc` —
they're only registered in the hash table. So this function doesn't touch them.

```c
void CleanupEntityList_ProcessAll(void) {
    puVar6 = PTR_00c7b2dc;  // scene entity list head
    while (puVar6 valid) {
        puVar1 = next_from_linked_list;
        CleanupObjectAttachments_FreeMemory(*puVar6);  // -> DestroyWorldObjectAndRelease
        // Inline unlink puVar6 from its list (puVar6[3]/[4])
        // Move puVar6 to free list at PTR_00c63188
        puVar6 = puVar1;
    }
}
```

**PTR_00c7b2dc xrefs** (who manages this list):
- `CleanupEntityList_ProcessAll` (0x672c40) — reads/iterates
- `UpdateFadeEffects_ProcessTimers` (0x672efe) — reads
- `DestroyFileMapping` (0x66f460) — reads + writes (teardown)
- `SetFileAttributes` (0x66f440) — writes (initialization)
- `CreateFadeEffect_EntityManagement` (0x672e76) — reads (entity insertion?)

Our entities created via `CreateEntityInstance_WithAttachment` are NOT added to this
list. The callers (`CastSpellByID_Extended`, `CreateGameObjectPathEffect`) probably add
the returned entity to PTR_00c7b2dc themselves. We don't.

### Vtable at 0x0081089c — Hash Table Entry Destructors

```
[0] 0x006a1170 DestroyMapDoodadDefinition  — WDOODADDEF destructor
[1] 0x006a11a0 LoadAndAddMapDoodadToList
[2] 0x006a14d0 MapDoodadDestructor
[3] 0x006a1260 CleanupMapDoodadContainer
[4] 0x006a1320 DestroyMapObjectDefinition  — WMAPOBJDEF destructor
[5] 0x006a1350 LoadAndAddMapObjectToList
[6] 0x006a1590 MapObjectDestructor
[7] 0x006a1410 CleanupMapObjectContainer
```

`DestroyMapDoodadDefinition` (vtable[0], 0x6a1170):
```c
void DestroyMapDoodadDefinition(undefined **param_1) {
    (**(code **)*param_1)(0);   // call entity's own virtual destructor
    FreeMemory(param_1, "?AVCMapDoodadDef@@", 0xfffffffe);
}
```
This is a simple destructor: calls entity vtable[0](0) then frees via SMemFree.
NOT the same as CleanupVisualEffectAndRelease — doesn't unlink from lists.

### hashTableTeardownLoop (0x69f740) — atexit Handler (Decompiled)

Registered via `validateMemoryOperation` (atexit) at 0x69f730. Runs during process exit.
```c
void hashTableTeardownLoop(void) {
    if ((DAT_00ca7cf0 & 1) == 0) {
        DAT_00ca7cf0 |= 1;  // mark as running
        _DAT_00ca7dc0 = &vtable_0081089c;
        _DAT_00ca7dd0 = 0;  // zero count

        // PHASE 1: Unlink all entries from global list (PTR_00ca7dcc)
        while (PTR_00ca7dcc valid) {
            piVar2 = ValidateLinkedList(&PTR_00ca7dc4, PTR_00ca7dcc);
            UnlinkFromList(piVar2);   // *** CRASH HERE ***
        }

        // PHASE 2: Unlink all entries from each hash bucket
        for each bucket in PTR_00ca7ddc (0xC bytes each) {
            while (bucket[8] valid) {
                piVar2 = ValidateLinkedList(bucket, bucket[8]);
                UnlinkFromList(piVar2);  // *** OR CRASH HERE ***
            }
        }

        // PHASE 3: Clear and free bucket array
        for each bucket: ClearLinkedList(bucket);
        FreeMemory(PTR_00ca7ddc);

        // PHASE 4: Unlink remaining from global list
        while (PTR_00ca7dcc valid) { unlink inline; }

        // PHASE 5: Reset sentinel
        PTR_00ca7dc8 = NULL; PTR_00ca7dcc = NULL;
    }
}
```

**Critical**: This iterates ALL entries in the hash table's global list AND bucket lists.
If an entity was freed (by our cleanup) but not unlinked from these lists, the teardown
follows dangling pointers into freed heap memory.

### cleanupGameObject (0x6a67a0) — Decompiled

```c
void __fastcall cleanupGameObject(undefined **param_1) {
    if (*(short*)(param_1 + 0xe) != 0) return;  // refcount check

    // Walk and cleanup child objects via param_1[0x21] list
    while (child in param_1[0x21]) {
        CleanupSpecializedObjectAndRelease(child);
    }

    // Detach model render context
    if (param_1[0x22] != NULL) {
        SetModelScale(param_1[0x22], NULL, NULL, NULL);
        SetCallbackFunctions(param_1[0x22], NULL, NULL, NULL);
        SetRenderCallbacks(param_1[0x22], NULL, NULL);
        DecrementReferenceCount(param_1[0x22]);
        param_1[0x22] = NULL;
    }

    // Unlink from ONE list: param_1[0x5b]/param_1[0x5c]
    if (param_1[0x5b] != NULL) { /* unlink */ }

    CleanupVisualEffectAndRelease(param_1);  // frees entity
}
```

### CleanupVisualEffectAndRelease (0x6a0840) — What It Actually Unlinks

```c
void __fastcall CleanupVisualEffectAndRelease(entity) {
    if (entity[0x5a]) RemoveVisualEffectByHandle(entity[0x5a]);

    // Unlink from list 1: entity[4]/entity[5]  (global list at PTR_00ca7dc4)
    if (entity[4] != NULL) { /* unlink */ }

    // Conditionally unlink from lists 2+3: entity[0x2e-0x31]
    if (entity[0x2f] != NULL) {
        // Unlink entity[0x2e]/entity[0x2f]
        // Unlink entity[0x30]/entity[0x31]
    }

    // Call virtual destructor and free to WDOODADDEF heap
    (**(code**)*entity)(0);
    ReleaseToHeap(WDOODADDEF, entity[1]);
}
```

**CONFIRMED**: `CleanupVisualEffectAndRelease` unlinks entity[4]/[5] (global list)
and conditionally entity[0x2e-0x31]. It does NOT unlink from the **hash bucket list**.

### ManageLinkedList (0x695ef0) — Intrusive List Insertion

```c
void __thiscall ManageLinkedList(void *this, int *entity, int mode, int insert_point) {
    // Compute node address: base_offset + entity_address
    // base_offset = *this (first dword of list header)
    piVar2 = (mode==0) ? this+4 : *this + entity;

    // First: unlink piVar2 from its current list (if linked)
    if (*piVar2 != 0) { /* unlink prev/next */ }

    // Compute insertion point
    piVar3 = (insert_point==0) ? this+4 : *this + insert_point;

    // Insert (mode 2 = insert before head)
    if (mode != 1) {
        node->next = *piVar3;
        node->prev = piVar3->prev;
        piVar3->prev->next = entity;
        *piVar3 = node;
    }
}
```

The node address within the entity = `*list_header + entity_ptr`. Each list stores its
own base offset at `*list_header`. The hash bucket list and global list use DIFFERENT
base offsets, so the intrusive nodes are at different positions within the entity struct.

### ROOT CAUSE ANALYSIS (2026-03-02)

**Root cause: Our cleanup via `CleanupEntity_ProcessAttachments` frees entities but
leaves them linked in the hash table's bucket list.**

**Full crash chain**:
1. We create entities via `CreateEntityInstance_WithAttachment` -> `CreateWorldUnit`
2. `CreateWorldUnit` registers entity in 3 intrusive linked lists:
   - Hash bucket list at `PTR_00ca7ddc + bucket*0xc` (node offset from `*bucket`)
   - Global list at `PTR_00ca7dc4` (node at entity[4]/[5])
   - Third list at `PTR_00c89f0c` (node offset from PTR_00c89f08)
3. When we clear a marker or on world cleanup, we call `CleanupEntity_ProcessAttachments`
4. This calls `cleanupGameObject` -> `CleanupVisualEffectAndRelease` which:
   - Unlinks entity[4]/[5] from global list -- OK
   - Frees entity memory back to WDOODADDEF heap
   - Does NOT unlink from hash bucket list or third list
5. Hash bucket list now has dangling pointer to freed memory
6. On game exit: atexit `hashTableTeardownLoop` iterates bucket list -> follows dangling
   pointer -> ACCESS_VIOLATION on freed heap memory

**Why normal game entities don't crash**: Spell entities created via
`CreateEntityInstance_WithAttachment` ARE also added to `PTR_00c7b2dc` by their
callers. During map change, `CleanupEntityList_ProcessAll` iterates `PTR_00c7b2dc`
and calls `DestroyWorldObjectAndRelease` which frees entities. But the hash table
teardown (`hashTableTeardownLoop`) only runs during atexit -- by which point
`CleanupWorldAndReleaseResources` has already cleaned up the hash table structure
itself (zeroed buckets, freed bucket array). So the atexit handler finds an empty
hash table and doesn't iterate any entries. Our entities bypass `PTR_00c7b2dc`
and survive into the atexit handler with dangling bucket list pointers.

**Alternative hypothesis**: Our cleanup during `worldCleanupDetour` (before the
original `CleanupWorldAndEntities`) frees entities. Then either
`CleanupWorldAndReleaseResources` or the atexit handler iterates the bucket list
and crashes on our freed entries.

**Test to confirm**: Remove ALL our cleanup (no `CleanupEntity_ProcessAttachments`,
no `worldCleanupDetour`), spawn markers, close the game. If the game's own teardown
can handle our entities naturally (they're properly registered in the hash table),
no crash. If it still crashes, the problem is in entity creation/registration.

### Callers of CreateEntityInstance_WithAttachment

Only 3 callers in the entire binary:
- `CastSpellByID_Extended` (0x6e518f) -- spell visual effects
- `CreateGameObjectPathEffect` (0x5f8076) -- path effects
- Unknown (0x6e5a6e) -- probably another spell effect

These callers likely add the returned entity to `PTR_00c7b2dc` (scene entity list)
so it gets cleaned up during `CleanupEntityList_ProcessAll`. We don't do this.

### Hash Table Bucket Base Offset: 0xB8 (CONFIRMED)

From `InitializeHashTable` (0x6962e0):
```c
*bucket = 0xb8;   // base offset for intrusive list nodes
```

From `RehashTableIfNeeded` (0x6964f0):
```c
ResetContainerState(bucket, 0xb8);  // all buckets use 0xB8
ManageLinkedList(bucket + (entity[0x2D] & mask) * 0xc, entity, 2, 0);
```

So the 3 intrusive list node offsets within a WDOODADDEF entity are:
- **0xB8** (entity[0x2E]/[0x2F]) = hash bucket list node
- **0xC0** (entity[0x30]/[0x31]) = hash global list node
- **0x10** (entity[4]/[5]) = third list (PTR_00c89f0c, base PTR_00c89f08)

`CleanupVisualEffectAndRelease` unlinks all 3 (conditionally on entity[0x2F] != 0).
After `ManageLinkedList` insertion, entity[0x2F] should always be non-zero
(sentinel has bit 0 set = odd address).

### InitializeRenderableObject (0x6a7d00) — Entity Initialization

Called from `AllocateRenderableObject`. Zeroes most fields including:
- entity[0x2E] = 0, entity[0x2F] = 0 (bucket list node — zeroed before insertion)
- entity[0x30] = 0, entity[0x31] = 0 (global list node — zeroed before insertion)
- entity[2] |= 0x40 (sets the M2/WDOODADDEF flag)
- entity[0] = vtable PTR_DestroyRenderableObject_00810a74

### Callers of CreateEntityInstance_WithAttachment — What They Do After

Only 3 callers in entire binary:

1. **`CreateGameObjectPathEffect` (0x5f8030)** — `__thiscall` on a game object
   - Does NOT save the return value! Fire-and-forget.
   - Passes `(path, pos, facing, 0, 0, param_1, param_2)` — param_6/7 are parent refs

2. **`CastSpellByID_Extended` (0x6e4b60)** — spell casting
   - Stores in global `PTR_00ceca8c`
   - Calls `SetEntityFlag_ToggleBit(entity, 0)` = sets `entity[0xD] |= 1`
   - Cleaned up by `processCinematicExit` → `CleanupEntity_ProcessAttachments(PTR_00ceca8c)`
   - Passes `(path, pos, 0.0, 0, 0, 0, 0)` — update_now=0!

3. **Unknown (0x6e5a6e)** — likely another spell effect

**Key differences from our call**:
- Both native callers pass `update_now=0` (param_5). We pass `update_now=1`.
- Spell caller calls `SetEntityFlag_ToggleBit(entity, 0)`. We don't.
- Neither caller registers entity in any extra tracking list.

### CreateWorldUnit Has Only ONE Caller

`CreateWorldUnit` (0x694980) is ONLY called from `CreateEntityInstance_WithAttachment`.
Map doodads use `FindOrCreateWorldUnit` (0x694e90) called from `AttachDoodadObjects` (0x695b1e).
These are separate creation paths that both register in the hash table but through different code.

### CleanupWorldAndReleaseResources (0x697ac0) — Full Chain

```c
void CleanupWorldAndReleaseResources(void) {
    ClearWorldObjectsAndResetState();     // iterates PTR_00c96088
    // iterate PTR_00c92078[0..0x1000]    // world chunk cleanup
    // iterate PTR_00c9e358               // WMO entities → destroyWorldEnvironment
    // iterate PTR_00c962bc               // some entities → cleanupGameObject
    CleanupWorldObjectList();
    // ... graphics cleanup ...
}
```

PTR_00c962bc is NOT for WDOODADDEF entities from CreateWorldUnit. It has its own
atexit teardown at 0x691830 (separate from hash table teardown). Base offset is 0xC
(set by InitializeDataPointers2 at 0x6917f0).

### TEST RESULT: No-cleanup build still crashes

Disabled ALL our cleanup (no CleanupEntity_ProcessAttachments, no world_cleanup_hook,
no removeHooks cleanup). Created 5 markers, replaced with 5 more, closed game.
**Still crashed.** This means the crash is NOT caused by our cleanup — the game's
own atexit handler can't handle our entities even when they're fully intact.

The WDOODADDEF heap is destroyed by `CleanupWorldSystem` (called from
`ShutdownAllGameSystems`) BEFORE the atexit `hashTableTeardownLoop` runs.
Our entities' memory becomes invalid while they're still in the hash table.

Normal map doodads presumably get removed from the hash table during
`ClearWorldObjectsAndResetState` or earlier in `CleanupWorldAndReleaseResources`,
so the hash table is empty before heap destruction.

### OPEN QUESTION: How do spell-spawned entities survive teardown?

Spell entities (from CastSpellByID_Extended) also use CreateEntityInstance_WithAttachment
and are NOT registered in any cleanup tracking list. They're cleaned up explicitly by
`processCinematicExit` when the spell ends. If a spell entity is still active during
map change/exit, it would have the same crash problem as our entities.

The game avoids this because spells always end before map transitions. But we don't
have that guarantee — our markers persist across frames until explicitly cleared.

### TODO
- [x] Decompile 0x672c40 (CleanupEntityList_ProcessAll) — iterates PTR_00c7b2dc, not hash table
- [x] Decompile hashTableTeardownLoop (0x69f740) — atexit handler, iterates all hash entries
- [x] Check vtable at 0x0081089c — DestroyMapDoodadDefinition, simple free
- [x] Decompile ContainerLookup (0x687960) — converts between list spaces
- [x] Decompile cleanupGameObject + CleanupVisualEffectAndRelease — handles all 3 lists IF entity[0x2F]!=0
- [x] Decompile ManageLinkedList (0x695ef0) — intrusive list with base offset
- [x] Confirm bucket base offset = 0xB8 from InitializeHashTable
- [x] TEST: no-cleanup build still crashes — crash is NOT from our cleanup
- [x] Decompile native callers — neither registers in extra lists
- [x] **Investigate spell-spawned game objects (e.g. mailbox summon) as reference**
  - Spell entities are NOT "persistent game objects" — they're client-side visual effects only
  - `processCinematicExit` (0x6e4940) explicitly cleans them: `CleanupEntity_ProcessAttachments(entity); entity = NULL;`
  - Called before every new spell cast — spell entities NEVER survive to teardown
  - If a spell entity survived to atexit, it would crash too (same bug as ours)
- [x] Check what `ClearWorldObjectsAndResetState` (PTR_00c96088) contains
  - PTR_00c96088 is a **terrain chunk list**, NOT a WDOODADDEF entity list
  - Initialized by `InitializeDataPointers` (0x6916e0): offset=0xC, sentinel pattern
  - `LoadWorldTerrainChunk` writes to PTR_00c96084 (the list head)
  - Map doodads are attached to parent chunks via `ModelAttachment_CreateNode` in `AttachDoodadObjects`
  - `destroyPrimaryGameObject` (0x6a69f0) destroys the parent chunk, which walks attachment children
  - We CANNOT participate in this list — it's for terrain chunks, not standalone entities
- [x] Determine proper entity lifecycle for persistent world objects
  - **There is no native path for standalone persistent WDOODADDEF entities**
  - All native callers either: (a) attach to parent chunks, or (b) explicitly clean up before teardown
  - Correct approach: explicit cleanup via `CleanupEntity_ProcessAttachments` before teardown
  - Hook point: `CleanupWorldAndEntities` (0x66fc40) PRE-hook — fires for exit, logout, AND map change

## Entity Lifecycle Solution (Confirmed)

### Root Cause (Fully Traced)
The WDOODADDEF hash table at 0xCA7DC0 has an atexit handler (`hashTableTeardownLoop` at 0x69f740)
that iterates ALL entries via the global list (PTR_00ca7dcc) and every hash bucket. By the time this
runs, `ShutdownAllGameSystems` has already destroyed the WDOODADDEF heap. Accessing any entity
still in the hash table hits freed memory → ACCESS_VIOLATION at 0x687220.

### How Native Code Avoids This
1. **Map doodads** (`FindOrCreateWorldUnit` via `AttachDoodadObjects`):
   - Attached to parent terrain chunks via `ModelAttachment_CreateNode`
   - Parent chunks are in PTR_00c96088 (terrain chunk list)
   - `ClearWorldObjectsAndResetState` iterates chunks → `destroyPrimaryGameObject` → walks attachments
   - Each doodad's `CleanupVisualEffectAndRelease` unlinks from hash table
   - Hash table is empty before heap destruction

2. **Spell effects** (`CastSpellByID_Extended` → `CreateEntityInstance_WithAttachment`):
   - Stored in PTR_00ceca8c (single global pointer)
   - `processCinematicExit` (0x6e4940) called before every new spell cast
   - Explicitly calls `CleanupEntity_ProcessAttachments(PTR_00ceca8c); PTR_00ceca8c = NULL;`
   - Spell entities NEVER survive to teardown

3. **Our markers** (standalone WDOODADDEF, no parent, no tracking):
   - Created via `CreateEntityInstance_WithAttachment` → `CreateWorldUnit`
   - Registered in hash table only (bucket + global list)
   - NOT attached to any parent chunk, NOT tracked in any game-managed cleanup list
   - Must be explicitly cleaned up before `CleanupWorldAndReleaseResources` runs

### Correct Fix: Pre-hook on CleanupWorldAndEntities
Hook `CleanupWorldAndEntities` (0x66fc40). Before calling the original:
1. Call `CleanupEntity_ProcessAttachments` on all active marker entities
2. Call `CleanupEntity_ProcessAttachments` on all despawning entities
3. Null all entity pointers / reset state
4. Call original — hash table no longer contains our entries → no crash

This handles ALL scenarios: game exit, logout, map change.

### Key Decompilations

#### destroyPrimaryGameObject (0x6a69f0)
```c
void __fastcall destroyPrimaryGameObject(undefined **param_1) {
    cleanupPrimaryResources((int)param_1);
    UnlinkAndFreeNode(param_1);
}
```

#### processCinematicExit (0x6e4940) — Spell Entity Cleanup
```c
// After handling cinematic/targeting state...
if (PTR_00ceca8c != NULL) {
    CleanupEntity_ProcessAttachments(PTR_00ceca8c);
    PTR_00ceca8c = NULL;
}
```

#### CreateEntityInstance_WithAttachment (0x6707c0) — M2 Path
```c
int * __fastcall CreateEntityInstance_WithAttachment(
    char *modelPath, float *pos, float facing, int flags, int updateNow, int p6, int p7) {
    // M2 path (no ".wmo" in path):
    positionData = CreateWorldUnit(modelPath, pos, facing, flags);
    positionData[0x61] = p7;
    positionData[0x60] = p6;
    positionData[0x24] |= 0x2000;
    if (updateNow != 0) {
        UpdateWorldPosition(positionData, pos, facing);
        SetUnitPositionAndOrientation(positionData, pos, facing);
    }
    *(short *)(positionData + 0x0E) += 1;  // refcount: 0 -> 1
    return positionData;
}
```

#### hashTableTeardownLoop (0x69f740) — The Crash Site
```c
void hashTableTeardownLoop(void) {
    if ((DAT_00ca7cf0 & 1) == 0) {
        DAT_00ca7cf0 |= 1;
        _DAT_00ca7dc0 = &PTR_DestroyMapDoodadDefinition_0081089c;
        // Walk global list — crashes here if entries point to freed heap
        while (PTR_00ca7dcc is valid) {
            piVar2 = ValidateLinkedList(&PTR_00ca7dc4, PTR_00ca7dcc);
            CalculateDistance3D(piVar2);  // reads from freed entity memory
        }
        // Walk each hash bucket — also crashes
        for each bucket in PTR_00ca7ddc {
            while (bucket entry is valid) {
                piVar2 = ValidateLinkedList(bucket, entry);
                CalculateDistance3D(piVar2);
            }
        }
        // Clear buckets, free bucket array, unlink remaining global entries
    }
}
```

#### FindOrCreateWorldUnit (0x694e90) vs CreateWorldUnit (0x694980)
Key difference: `FindOrCreateWorldUnit` additionally registers in the third list
(PTR_00c89f08/PTR_00c89f0c via entity[4]/[5]), while `CreateWorldUnit` only registers
in the hash bucket and global lists. Both are cleaned up through `CleanupVisualEffectAndRelease`
which handles all three list types.

#### ClearWorldObjectsAndResetState (0x6a6710)
```c
void ClearWorldObjectsAndResetState(void) {
    // Iterates PTR_00c96088 (terrain chunk list, NOT entity list)
    for each chunk in list {
        ppuVar1 = chunk[1];  // parent object
        // Clear lookup tables indexed by ppuVar1[0x26]
        ComplexMemoryCleanupAndRelease(chunk);      // free the list node
        destroyPrimaryGameObject(ppuVar1);          // destroy parent + attachments
    }
}
```

### Complete Entity Lifecycle Audit (All Native Callers)

**Every native M2 entity created via `CreateEntityInstance_WithAttachment` is explicitly cleaned up
by a parent.** The atexit handler (hashTableTeardownLoop) is a safety net for the hash table data
structure — it should NEVER encounter live entities in normal operation.

#### All 3 callers of CreateEntityInstance_WithAttachment:

1. **CastSpellByID_Extended (0x6e4b60)** — spell targeting reticle
   - Stores entity in global `PTR_00ceca8c`
   - Cleaned up by `processCinematicExit` before every new spell cast
   - Also cleaned up by `executeSpellOrItem` (0x6e54f0)

2. **CreateGameObjectPathEffect (0x5f8030)** — game object visual effect
   - Called by `CreatePathObjectByUnitType` (0x5f4970)
   - Return value saved at parent+0x10 (despite Ghidra typing it as void)
   - Cleaned up by `DestroyPathObjectIfPresent` (0x5f4950) → `CleanupEntity_ProcessAttachments`
   - Parent is a spell effect object (SpellEffectWithPath class at ~0x5f4800)
   - `SpellEffectWithPathDestructor` (0x5f48d0) destroys parent during spell teardown

3. **Unknown caller (0x6e5a6e)** — likely in `executeSpellOrItem` (0x6e54f0)
   - Same pattern as #1

#### All 3 callers of CleanupEntity_ProcessAttachments (0x670d50):
- `processCinematicExit` (0x6e4940) — spell cleanup
- `executeSpellOrItem` (0x6e54f0) — spell/item cleanup
- `DestroyPathObjectIfPresent` (0x5f4950) — path effect cleanup

#### CleanupVisualEffectAndRelease has only ONE caller:
- `cleanupGameObject` (0x6a67a0) — the M2/WDOODADDEF cleanup function

So the full cleanup chain is always:
```
Parent destroyed
  → CleanupEntity_ProcessAttachments (0x670d50)
    → cleanupGameObject (0x6a67a0)          [entity flags & 0x40]
      → CleanupVisualEffectAndRelease (0x6a0840)
        → unlink entity[4]/[5] from third list
        → if entity[0x2F] != 0: unlink entity[0x2E-0x31] from hash bucket + global list
        → call vtable destructor
        → ReleaseToHeap(WDOODADDEF, entity)
```

### Cleanup Lists Summary (what gets iterated during CleanupWorldAndReleaseResources)
| List | Offset | Contains | Cleanup Function | Heap |
|------|--------|----------|-----------------|------|
| PTR_00c96088 | 0xC | Terrain chunk wrappers → doodad parents | destroyPrimaryGameObject | various |
| PTR_00c9e358 | via PTR_00c9e350 | WMO entity wrappers (from CreateEntityInstance_WithAttachment WMO path) | destroyWorldEnvironment | WMAPOBJDEF |
| PTR_00c962bc | 0xC | **Empty in 1.12.1** — no insertion code found, only init+atexit | cleanupGameObject (conditional) | WDOODADDEF |
| PTR_00ca8044 | via PTR_00ca803c | Map manager objects | CleanupAndReleaseMemoryBlock | PTR_00ca7e10 (4th heap) |
| PTR_00c7b2dc | 0xC | WENTITY fade effect wrappers | CleanupObjectAttachments_FreeMemory → DestroyWorldObjectAndRelease | WENTITY |

**None of these lists iterate the WDOODADDEF hash table.** The hash table is ONLY iterated by the
atexit handler. All native entities are removed from the hash table via explicit
`CleanupEntity_ProcessAttachments` calls from their parents BEFORE heap destruction.

### Refcount Verification
- `AllocateRenderableObject` zeroes the entire struct → entity+0x0E = 0
- `CreateWorldUnit` sets entity[3] lower 2 bytes to 1 (byte offset 0x0C, NOT 0x0E) → entity+0x0E still = 0
- `CreateEntityInstance_WithAttachment` increments: `*(short*)(entity+0x0E) += 1` → entity+0x0E = 1
- `CleanupEntity_ProcessAttachments` decrements: `*(short*)(entity+0x0E) -= 1` → entity+0x0E = 0 → proceeds to destroy
- Single call to CleanupEntity_ProcessAttachments is sufficient (refcount goes 1→0)

### Our Creation vs Native Spell Path
| Parameter | Our markers | CastSpellByID_Extended |
|-----------|------------|----------------------|
| path | "Spells\\Raid_UI_FX_*.m2" | game object model path |
| pos | world position | caster position |
| facing | 0.0 | caster facing |
| flags | 0 | 0 |
| updateNow | **1** | **0** |
| p6 | 0 | 0 (or GUID low) |
| p7 | 0 | 0 (or GUID high) |
| post-create | (none) | `SetEntityFlag_ToggleBit(entity, 0)` = entity[0xD] \|= 1 |

Difference: we pass `updateNow=1` (which calls `UpdateWorldPosition` + `SetUnitPositionAndOrientation`),
spell caster passes `updateNow=0`. Spell caster also calls `SetEntityFlag_ToggleBit` which sets
`entity[0xD] |= 1` (byte offset 0x34, flag byte). Neither difference should affect cleanup.
