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
