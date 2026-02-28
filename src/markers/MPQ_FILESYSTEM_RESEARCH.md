# MPQ Filesystem Research: Alternatives to Multi-Hook File Serving

## Problem Statement

WeirdUtils currently hooks **6 functions** to serve ~20 embedded files (M2 models, skins, textures) from DLL memory:

| Hook | Target | Purpose |
|------|--------|---------|
| `openFileDetour` | 0x6477c0 | Create fake file context |
| `getFileSizeDetour` | 0x6487f0 | Return embedded size |
| `readFileDetour` | 0x648460 | memcpy embedded data |
| `processAsyncDetour` | 0x647350 | Handle async executor path |
| `cleanupFileHandleDetour` | 0x648730 | Free fake context |
| `loadModelAsyncDetour` | 0x71d4e0 | Bypass M2 async loading |

Plus `loadFileDetour` at 0x648620 for addon files (.toc/.lua/.xml).

The async hooks (4 and 6) exist because the async file executor calls `fileReadWithLock` directly, bypassing our `readFileDetour`. This entire system is fragile, requires careful critical section management, refcount tracking, and event signaling. This document researches alternatives.

---

## WoW 1.12.1 File I/O Architecture (Verified via Ghidra)

### Storm Is Statically Linked

WoW 1.12.1 does **not** use Storm.dll. All MPQ/file code is compiled directly into wow.exe. The Storm source path string `"E:\build\buildWoW\WoW\Source\..."` at 0x865b94 confirms this. Our existing hooks at `0x6477xx`-`0x6487xx` ARE the Storm SFile functions.

### The File Open Pipeline

```
openFileWithOptions(archive_ptr, path, flags, handle_out)  [0x6477c0]
│
├─ if archive_ptr == NULL:
│   └─ locateFileInDirectories(path, ...)                   [0x647e60]
│       ├─ 1. Absolute path? → SearchFileInMultipleDirectories
│       ├─ 2. Check disk file hash table (PTR_00c521e8)
│       │      (populated once by scanDirectoriesForFiles @ 0x646ea0)
│       ├─ 3. FindFileInArchive(0, path, flags, &archive_ref) [0x654920]
│       │      └─ File_FindInArchive(0, path, ...)            [0x6549a0]
│       │          └─ Recursively searches archive chain
│       └─ Returns: type code (0=disk, 3=archive) + resolved path
│
├─ Allocate 0x60-byte file context
├─ initializeFileContext(ctx, type)                          [0x647290]
│
└─ switch(type):
    case 0: openFileHandle(path, ...)          → disk file
    case 1: (validated disk)
    case 2/3: (storage/stream)
    case 4: readFromArchiveFile(...)           → MPQ archive read
    case 5: return NULL (error)
```

### The Global Archive Array

Archives are stored in a **dynamic array** managed as a struct:

```
Global archive array struct at 0x8826b4:
  +0x00 [0x8826b4]: capacity     (max slots)
  +0x04 [0x8826b8]: count        (current number of archives)
  +0x08 [0x8826bc]: array_ptr    (SArchive** — pointer to array of SArchive pointers)
  +0x0C [0x8826c0]: growth_incr  (allocation growth increment)

RTTI tag: ".PAVSArchive@@" at 0x82e248
```

Managed by:
- `GrowArchiveArray` (0x4045a0) — __thiscall, resizes the array
- `ResizeArchiveArray` (0x4046f0) — sets initial capacity
- `MPQ_CleanupAllArchives` (0x403c70) — iterates count→0 calling Archive_Close

### SArchive Object (Minimal Wrapper)

From `Archive_Close` (0x648ef0):
```c
void Archive_Close(int *archive) {
    if (archive[0] == 1) {           // +0x00: type (1 = MPQ)
        MPQ_CloseArchive(archive[1]); // +0x04: internal handle
    } else {
        CheckStreamBounds(archive[1]);
    }
    FreeMemory(archive, "delete", -1);
}
```

`Archive_OpenUnified` (0x648dd0) allocates an 8-byte SArchive wrapper:
```c
uint Archive_OpenUnified(char *path, int *param_2, uint flags, uint **outArchive) {
    SArchive *archive = AllocateBuffer(8, ...);
    *outArchive = archive;
    archive->field_0x4 = 0;
    // ... opens file, validates MPQ, builds internal structures
}
```

### The Internal MPQ Archive Structure

From `InitializeArchiveStructure` (0x655bf0), the full MPQ handle (pointed to by `SArchive[1]`) is a large struct:

| Offset | Field | Description |
|--------|-------|-------------|
| +0x14C | `[0x53]` | Magic: `0x1a51504d` ("MPQ\x1a") |
| +0x150 | `[0x54]` | Header size (must be > 0x1f) |
| +0x158 | `[0x56]` | Hash table offset in file |
| +0x15A | `[0x56+2]` | Sector size shift (byte) |
| +0x164 | `[0x59]` | Version (< 0x10001) |
| +0x168 | `[0x5a]` | Hash table entry count (< 0x10001) |
| +0x140 | `[0x50]` | I/O vtable pointer (for reading archive data) |
| +0x27C | `[0x9f]` | Computed sector size: `0x200 << (shift & 0x1f)` |
| +0x280 | `[0xa0]` | Current file position |
| +0x288 | `[0xa2]` | Read context |
| +0x28C | `[0xa3]` | Allocated sector buffer |
| +0x290 | `[0xa4]` | Attributes offset |
| +0x294 | `[0xa5]` | Hash table allocated buffer |

The I/O vtable at `+0x140 [0x50]` is critical — it provides the read callbacks that Storm uses to access the archive data. Read calls go through `(*(code **)(*param_1[0x50] + 4))(...)`.

### Archive Registration (How MPQs Are Opened)

```
MPQ_InitializeArchives (0x403740)
│
├─ ResizeArchiveArray(...)               — allocate the global array
│
├─ For each base MPQ (model, texture, terrain, wmo, sound, misc, interface, fonts, dbc):
│   └─ OpenMPQArchiveWithPaths(name, param2, index)  [0x403b00]
│       ├─ FormatPath(buf, 0x104, pathIndex, name)    — tries "Data\name" then "..\Data\name"
│       └─ Archive_OpenUnified(path, ..., &PTR_008826bc[index])  [0x648dd0]
│           └─ OpenFileWithValidation(path, ..., &archive)  [0x655690]
│               └─ InitializeArchiveStructure(archive, ...) [0x655bf0]
│                   ├─ Read MPQ header, validate magic
│                   ├─ Allocate and read hash table
│                   ├─ Allocate and read block table
│                   └─ Archive_ReadAttributes(...)
│
├─ MPQArchiveEnumerator(...)  [0x4039b0]
│   └─ Discovers patch archives matching "patch-?.MPQ" pattern
│      (glob pattern byte at 0x82edc2: '?' = single char)
│
└─ Opens patch.MPQ and discovered patch-X.MPQ archives
```

### MPQ Filename Table (Verified)

```
0x82e12c → "model.MPQ"
0x82e130 → "texture.MPQ"
0x82e134 → "terrain.MPQ"
0x82e138 → "wmo.MPQ"
0x82e13c → "sound.MPQ"
0x82e140 → "misc.MPQ"
0x82e144 → "interface.MPQ"
0x82e148 → "fonts.MPQ"
0x82e14c → "speech.MPQ"
0x82e150 → "dbc.MPQ"
0x82e154 → "speech2.MPQ"
```

Patch glob pattern: `"patch.MPQ"` at 0x82edb0, `"patch-?.MPQ"` at 0x82edbc.
Format string: `"Data\%s"` at 0x82edc8.

### Storm's I/O Provider System (The Extensibility Point)

Storm does NOT have a virtual filesystem plugin API. However, it does have a **two-layer I/O abstraction** for archive data access:

#### IO Object (0x118 bytes)

Created by `CreateIOObject` (0x66dfa0), initialized by `InitializeIOObject` (0x66dfe0):

```c
struct IOObject {                          // 0x118 bytes total
    void**   vtable;           // +0x00: → IOVtable at 0x80fddc
    void*    inner_provider;   // +0x04: secondary vtable for actual I/O dispatch
    int      flags;            // +0x08: initialized to 1
    AsyncMgr async_mgr;        // +0x0C: async I/O manager (large sub-struct)
    uint     buffer_size;      // +0x110: max read buffer size
    void*    buffer;           // +0x114: allocated read buffer (size = buffer_size)
};
```

#### IO Vtable (at 0x80fddc)

```
[0] +0x00: 0x66e040 = Destructor_WithCleanup
[1] +0x04: 0x66e0c0 = Resource_Load        ← THE READ FUNCTION
[2] +0x08: 0x66e130 = Resource_Unload
[3] +0x0C: 0x66e1b0 = (unknown)
[4] +0x10: 0x66e1c0 = IOManagerDestructor
[5] +0x14: 0x66e1e0 = IOManagerCleanup
[6] +0x18: 0x66e200 = (unknown)
[7] +0x1C: 0x7f800000 = (float NaN — padding/sentinel)
[8] +0x20: 0x66e2d0 = ValidateIOOperation
[9] +0x24: 0x66e310 = GetIOResult
[10]+0x28: 0x66e340 = CancelIOOperation
[11]+0x2C: 0x66e360 = (unknown)
```

#### How Archive Reads Dispatch

`InitializeArchiveStructure` reads data through the IO provider at `archive+0x140`:
```c
// archive[0x50] = *(archive + 0x140) = IO object pointer
(**(code **)(*archive[0x50] + 4))(buffer, position, 0, 0x1000, &bytes_read);
//            ^-- IO vtable[1] = Resource_Load
```

`Resource_Load` (0x66e0c0) then:
1. Bounds-checks against `this->buffer_size` (+0x110)
2. Copies source data into `this->buffer` (+0x114)
3. Dispatches through the **inner provider** at `this->inner_provider` (+0x04):
   ```c
   result = (*(*(this->inner_provider))[2])(this->buffer, dest, offset, size);
   ```

So there are **two** levels of vtable indirection. The inner provider at `+0x04` holds the actual read-from-disk callbacks. For disk-backed MPQs, this eventually calls `ReadFile`/`SetFilePointer`.

#### Low-Level MPQ System (0x668xxx)

Separate from the high-level IO provider, the low-level `ZipFileArchive` system uses plain Windows file handles:

```c
// MPQ_OpenArchive (0x668360) allocates 0x110-byte ZipFileArchive struct
// openArchiveFile (0x667bd0):
openArchiveFile(this, path):
    this->file_handle = openFileReadOnly(path);  // → CreateFileA wrapper
    strcpy(this->path, path);                     // store path at +0x0C
```

The `SArchive` wrapper at the top level (8 bytes: `{type, handle}`) bridges these:
- `type == 1`: handle points to a `ZipFileArchive` (low-level MPQ)
- `type != 1`: handle points to a stream object

#### Conclusion: No Virtual FS, But I/O Is Abstracted

Storm has no "register a provider" API. Every type code (0-4) is hardcoded to specific OS handle types. The I/O vtable exists but is deeply intertwined with async thread managers and buffer management (0x118 bytes of state). Creating a custom IO object is theoretically possible but requires replicating the async infrastructure.

The most practical "virtual filesystem" approaches use **real OS handles** that Storm can consume natively — either through temp files or through MPQ archives that Storm opens and manages itself.

---

## Approach E: Windows Temp File Handles (Recommended)

### Concept

Use Windows `CreateFile` with `FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE` to create **real OS file handles** backed primarily by the filesystem cache (RAM). Then hook only `openFileWithOptions` to redirect Storm to our temp files.

Windows `FILE_ATTRIBUTE_TEMPORARY` tells the cache manager to avoid flushing to disk if possible — the data lives in RAM. `FILE_FLAG_DELETE_ON_CLOSE` auto-deletes the file when the last handle closes, even on crash.

### Implementation

1. **DLL init** — for each embedded asset:
   ```c
   // Get temp directory
   GetTempPath(MAX_PATH, tempDir);

   // Create temp file with auto-delete
   handle = CreateFile(
       tempPath,
       GENERIC_READ | GENERIC_WRITE,
       FILE_SHARE_READ | FILE_SHARE_DELETE,  // allow Storm to open it too
       NULL,
       CREATE_ALWAYS,
       FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE,
       NULL
   );

   // Write embedded data
   WriteFile(handle, embedded_data, size, &written, NULL);

   // Store mapping: "Spells\\WU_XYZ.m2" → tempPath
   ```

2. **Hook `openFileWithOptions` (0x6477c0)** — single hook:
   ```
   openFileDetour(archive, path, flags, handle_out):
       if path matches our asset map:
           // Redirect to temp file path
           return original(archive, temp_path, flags, handle_out)
       return original(archive, path, flags, handle_out)
   ```

3. **No other hooks needed** — Storm opens the temp file with `CreateFileA`, gets a real handle. All native I/O works:
   - `GetFileSizeFromHandle` → type-0 dispatch → `fstat` on real handle ✓
   - `ReadFileFromMultipleSources` → type-0 dispatch → `fileReadWithLock` on real handle ✓
   - `processAsyncFileOperation` → reads from real handle via worker thread ✓
   - `CleanupFileHandleResources` → closes real handle ✓
   - `loadModelFromFileAsync` → async task reads real handle ✓

4. **Cleanup** — on DLL unload, close our original handles. `FILE_FLAG_DELETE_ON_CLOSE` handles the rest. If the process crashes, Windows still cleans up temp files.

### Why This Works For Async

The entire reason our current approach needs 6 hooks is that fake type-0 contexts with NULL handles fail when the async executor calls `fileReadWithLock` directly. With real temp file handles, the async executor reads from a real OS handle — no hooks needed on the read path at all.

### Path Redirection Strategy

Two options for how the hook redirects paths:

**Option 1: Redirect in `openFileWithOptions`**
- Intercept at 0x6477c0, check path against our map
- If match, substitute the temp file path before calling original
- Storm's `locateFileInDirectories` runs with the temp path, finds the file on disk (type 0)
- Everything proceeds natively

**Option 2: Redirect in `locateFileInDirectories`**
- Hook at 0x647e60 instead
- When our path is requested, set output_path to the temp file's disk path
- Set type_out = 0 (disk file)
- Return success
- `openFileWithOptions` calls `openFileHandle` on the temp path natively

Option 2 is slightly cleaner since it hooks at the search level rather than the open level.

### Temp File Location

Files should go in the system temp directory (`GetTempPath`), NOT the game directory:
- No write permission issues
- No clutter in the game folder
- Windows manages cleanup
- Unique naming avoids conflicts: `GetTempFileName(tempDir, "WU_", 0, tempPath)`

### Memory Behavior

`FILE_ATTRIBUTE_TEMPORARY` is a hint to the Windows cache manager:
- Data is kept in the filesystem cache (RAM) and written to disk lazily
- For small files (~20 assets, totaling a few MB), Windows will almost certainly keep everything in cache
- This is NOT a guarantee — under memory pressure, Windows may flush to disk
- But for our use case (~2-3 MB total), the data effectively stays in RAM

### Key Addresses

Only one hook needed:

| Function | Address | Convention | Purpose |
|----------|---------|------------|---------|
| `openFileWithOptions` | 0x6477c0 | __stdcall(4) | Redirect path to temp file |

OR:

| Function | Address | Convention | Purpose |
|----------|---------|------------|---------|
| `locateFileInDirectories` | 0x647e60 | __fastcall(6) | Return temp path as disk file |

### Pros
- **Reduces from 6 hooks to 1** — the biggest win
- **All async I/O works natively** — real OS handles, no fake contexts
- No fake file contexts, no critical section management, no refcount tracking
- No MPQ building required — files are individual temp files
- Auto-cleanup via `FILE_FLAG_DELETE_ON_CLOSE`
- Temp files are invisible to the user (in system temp dir)
- The `loadFileDetour` (0x648620) for addon files could remain unchanged

### Cons
- Files technically touch disk (Windows may flush under memory pressure)
- Requires `CreateFile`/`WriteFile` Win32 calls from Zig (straightforward via `@import("std").os.windows`)
- ~20 temp files created at init (small overhead, ~2-3 MB total)
- Temp file creation adds a few ms to DLL init
- If DLL loads after `scanDirectoriesForFiles` (likely), the disk hash table won't have our files — must use path redirection hook rather than relying on native discovery

---

## Approach A: Temp MPQ on Disk + Native Patch Loading

### Concept

Build a real MPQ archive at compile time containing all embedded assets. Write it to disk as `Data\patch-W.MPQ`. The game's native patch system discovers and loads it automatically, or we register it manually via `Archive_OpenUnified`.

### Implementation

1. **Build time**: Use a build step (or comptime Zig) to create a valid V1 MPQ archive containing all marker assets
2. **DLL init**: Write the embedded MPQ blob to `Data\patch-W.MPQ` (single char matches the default `patch-?.MPQ` glob)
3. **Registration**: Either:
   - (a) Hook early enough that `MPQ_InitializeArchives` picks it up naturally, OR
   - (b) Call `Archive_OpenUnified` directly to register it in the array after init

4. **Cleanup**: Delete temp file on DLL unload / game shutdown

### Key Addresses

| Function | Address | Signature |
|----------|---------|-----------|
| `Archive_OpenUnified` | 0x648dd0 | `__stdcall(path, param2, flags, &outArchive) → uint` |
| `GrowArchiveArray` | 0x4045a0 | `__thiscall(ECX=&array_struct, count, grow_flag)` |
| `Archive_Close` | 0x648ef0 | `(SArchive* archive)` |
| Global array struct | 0x8826b4 | `{capacity, count, array_ptr, growth}` |

### Pros
- **Eliminates ALL 6 Storm I/O hooks** — game reads MPQ natively
- Zero fake file contexts, zero async handling
- Proven approach — this is how patch.MPQ works
- The `loadFileDetour` (0x648620) for addon files could remain unchanged

### Cons
- Requires write access to game directory
- Must clean up on exit (crash = orphaned file)
- Must build valid MPQ at compile time (non-trivial format)
- File on disk is visible to users and potentially other tools
- Timing: if loaded after `MPQ_InitializeArchives`, must manually call `Archive_OpenUnified`

### MPQ Build Complexity

A minimal V1 MPQ for ~20 uncompressed files requires:
- MPQ header (32 bytes)
- File data blocks (sequential, uncompressed)
- Hash table (encrypted, 4 entries per hash bucket × nearest power of 2)
- Block table (encrypted, 16 bytes per file)

The hash table uses a specific encryption algorithm (documented in wowdev.wiki and StormLib source). Could implement in Zig comptime or use a build-time tool.

### Assetfix Synergy

The [assetfix project](/media/storage/projects/zig/assetfix/) already implements the glob pattern patch (`0x82edc2: '?' → '*'`) for multi-character patch names. If combined with assetfix, the temp file could use any name like `patch-weirdutils.MPQ`.

---

## Approach B: Register In-Memory MPQ (No Disk Write)

### Concept

Embed a valid MPQ archive in the DLL. Instead of writing it to disk, directly construct an SArchive object that references the in-memory MPQ data and insert it into the global archive array.

### The Challenge: I/O Vtable

The internal MPQ struct uses an I/O vtable at `+0x140 [0x50]` for all data access:
```c
(**(code **)(*archive[0x50] + 4))(buffer, position, 0, 0x1000, &bytes_read);
```

For disk-based MPQs, this vtable points to functions that call `ReadFile`/`SetFilePointer` on a Windows file handle. For an in-memory MPQ, we'd need a **custom I/O vtable** that reads from our embedded data pointer instead.

### Implementation (Two Sub-Approaches)

#### B1: Fake the File Backing (Simpler)

1. Embed MPQ in DLL via `@embedFile`
2. Hook `openFileWithOptions` to intercept when Storm opens `"WeirdUtils.mpq"` — create a fake file context pointing to the embedded MPQ blob
3. Add **seek support** to the fake context (current implementation only does flat memcpy from offset 0)
4. Call `Archive_OpenUnified("WeirdUtils.mpq", ...)` — Storm reads the MPQ header, hash table, block table through our hooked I/O
5. For subsequent reads FROM the archive (when loading files within the MPQ), Storm seeks within the same archive file handle — our hook serves the right bytes

**Key difference from current approach**: Instead of matching ~20 individual paths and creating ~20 fake contexts, we serve **one** fake file (the MPQ itself). Storm handles all per-file hash lookup, decompression, and I/O natively.

**What changes**:
- Fake file context needs a **file position** field for seeking (use unused offset, e.g. +0x38)
- `readFileDetour` needs to read from `embedded_ptr + file_position` instead of always offset 0
- `getFileSizeDetour` returns the total MPQ size (one value, not per-file)
- File path matching reduces from ~20 paths to 1

**What we might drop**:
- `loadModelAsyncDetour` (0x71d4e0) — this hook exists because M2 async loading bypasses our read hook for type-0 fake contexts. But archive files go through Storm's type-4 read path, which reads from the archive handle. If the archive handle is our fake context with seek support, Storm's own async code should work.
- `processAsyncDetour` (0x647350) — same reasoning; the async executor reads from the archive file context, which goes through our hooked `readFileDetour`.

**Risk**: The async executor might call `fileReadWithLock` directly on the archive handle, bypassing `ReadFileFromMultipleSources`. This is the exact problem that forced hooks 4 and 6 in the current approach. Needs verification.

#### B2: Custom I/O Vtable (More Complex, Cleaner)

1. Embed MPQ in DLL
2. Parse the MPQ header/hash/block tables at DLL init (in Zig)
3. Allocate and populate the internal MPQ struct (~0x298+ bytes)
4. Create a custom I/O vtable with a read function that memcpys from the embedded data
5. Wrap in an 8-byte SArchive object (`{type=1, internal_handle}`)
6. Insert into global archive array at `PTR_008826bc[count]`, increment count

**What this eliminates**: ALL file I/O hooks for asset loading. Storm finds files through the hash table, reads through our custom I/O vtable. No fake file contexts at all.

**Complexity**: The internal MPQ struct is ~0x298 bytes with many fields. Getting every field right (hash table decryption, block table setup, sector size computation, attribute reading) is extremely error-prone. Essentially reimplementing `InitializeArchiveStructure` (0x655bf0).

### Pros (Both B variants)
- No disk writes
- Assets stay embedded in DLL
- B2 eliminates all file hooks entirely

### Cons
- B1: Still needs ~4 hooks (open, size, read, cleanup) but for 1 file instead of 20; may still need async hooks
- B2: Requires precise RE of the ~0x298-byte internal struct; fragile
- Both: Must build valid MPQ at compile time
- B2: Must reimplement hash table decryption in Zig

---

## Approach C: Hook locateFileInDirectories (Single Hook Point)

### Concept

Instead of hooking individual I/O functions, hook `locateFileInDirectories` (0x647e60) — the single function that decides WHERE a file comes from (disk, hash cache, or archive). Make it return type=0 (disk) with a path that resolves to our embedded data.

### Why This Doesn't Quite Work

`locateFileInDirectories` only decides the file *location* — it doesn't serve data. After it returns type=0, `openFileWithOptions` calls `openFileHandle` to actually open the disk file. If there's no real file on disk, this fails.

However, this could work in combination with disk writes (see Approach A) or with a minimal I/O hook.

### Variant: Hook locateFileInDirectories + Inject Into Disk Hash Table

The disk file hash table at `PTR_00c521e8`/`PTR_00c521f0` is checked BEFORE the archive chain:
```c
// In locateFileInDirectories:
if (PTR_00c521f0 != 0xffffffff) {
    hash = String_ComputeHash(path);
    entry = hash_table[hash & PTR_00c521f0];
    if (entry.hash == hash && strcmp(entry.name, path) == 0) {
        strcpy(output_path, entry.disk_path);
        *type_out = entry.type;  // type stored at entry[7]
        return 1;
    }
}
```

If we could insert entries into this hash table mapping our asset paths to disk locations, AND write the files to disk, files would be found without any archive hooks.

### Key Addresses

| Symbol | Address | Notes |
|--------|---------|-------|
| `locateFileInDirectories` | 0x647e60 | __fastcall, 6 params |
| `scanDirectoriesForFiles` | 0x646ea0 | Populates disk hash table (called once) |
| `String_ComputeHash` | 0x64b3f0 | Storm hash function |
| `FindFileInArchive` | 0x654920 | Wrapper calling File_FindInArchive |
| `File_FindInArchive` | 0x6549a0 | Recursive archive chain search |
| Disk hash table ptr | 0xc521e8 | Hash table base pointer |
| Disk hash table mask | 0xc521f0 | Hash mask (0xffffffff = disabled) |

### Pros
- Single hook point for file discovery
- Leverages existing game code for all I/O

### Cons
- Still requires disk files OR additional I/O hooks
- Hash table struct needs reverse engineering
- Doesn't solve the fundamental problem (serving data from memory)

---

## Approach D: CheckFileExistence Hook (assetfix Pattern)

### Concept

The [assetfix project](/media/storage/projects/zig/assetfix/) takes a different approach entirely:

1. **NOP two gates** in `File_FindInArchive` (0x654b5c, 0x654b6a) that restrict `CheckFileExistence` to only "Interface/AddOns" paths
2. **Hook `CheckFileExistence`** (0x654DD0) to check a hash map of loose disk files
3. If found on disk, return the disk path; Storm loads it normally

This works for **disk-based** loose files but not for in-memory embedded data. However, combined with writing temp files to disk, it provides a clean single-hook solution.

### Key Addresses (from assetfix)

| Target | Address | Patch |
|--------|---------|-------|
| `CheckFileExistence` | 0x654DD0 | Hook target — `__fastcall(ECX=filename, EDX=flags, [esp+4]=output)` |
| Gate 1 (JZ) | 0x654b5c | `74 25 → 90 90` (NOP) |
| Gate 2 (JNZ) | 0x654b6a | `75 17 → 90 90` (NOP) |
| Glob pattern byte | 0x82edc2 | `3F → 2A` ('?' → '*') for multi-char patch names |

---

## Comparison Matrix

| Criteria | Current (6 hooks) | E: Temp File Handles | A: Temp MPQ | B1: In-mem MPQ + hooks | B2: In-mem MPQ + struct | D: Disk + CFE |
|----------|-------------------|---------------------|-------------|----------------------|------------------------|--------------|
| Hook count | 6 (+1 addon) | **1** (+1 addon) | 0 (+1 addon) | ~4 (+1 addon) | 0 (+1 addon) | 1 (+1 addon) + 2 NOPs |
| Disk writes | None | ~20 temp files (cache-backed) | 1 MPQ file | None | None | ~20 files |
| Fake contexts | ~20 | **0** | 0 | 1 | 0 | 0 |
| Async handling | Manual | **Native** | Native | Uncertain | Native | Native |
| Build complexity | Low | **Low** | Medium (MPQ builder) | Medium (MPQ builder) | High (struct RE) | Low |
| RE work needed | Done | **Minimal** (verify path redirect) | Archive_OpenUnified conv | Same as A + async verify | Full struct layout | Already done (assetfix) |
| Risk | Proven but fragile | **Low** (real OS handles) | Low (native I/O) | Medium (async path?) | High (struct mismatch) | Low |
| Cleanup needed | None | **Auto** (DELETE_ON_CLOSE) | Delete temp file | None | Remove from array | Delete temp files |
| Purely in-memory | Yes | Mostly (cache-backed) | No | Yes | Yes | No |

---

## Recommendation

### Best Overall: Approach E (Windows Temp File Handles)

**Reasoning**:
1. **Reduces from 6 hooks to 1** — the single biggest complexity reduction possible
2. **All async I/O works natively** — real OS handles eliminate the entire class of async-bypass bugs that forced hooks 4, 5, and 6
3. **No MPQ building required** — avoids the entire hash table encryption / block table / header format complexity
4. **No new RE work** — we already know `openFileWithOptions` (0x6477c0) intimately
5. **Auto-cleanup** — `FILE_FLAG_DELETE_ON_CLOSE` handles cleanup even on crash
6. **Low risk** — we're giving Storm exactly what it expects (real disk files), just in a temp location
7. **Files live in RAM** — `FILE_ATTRIBUTE_TEMPORARY` keeps data in the filesystem cache for our small (~2-3 MB) asset set

**Next steps for Approach E**:
1. Write a prototype: create temp files from embedded data at DLL init
2. Hook `openFileWithOptions` to redirect matching paths to temp file paths
3. Verify M2 model loading works end-to-end (including textures via async path)
4. If successful, remove hooks 2-6 and the fake file context infrastructure
5. Keep `loadFileDetour` (0x648620) for addon files — these use a different pipeline

### Runner-Up: Approach A (Temp MPQ on Disk)

If a single-file solution is preferred over ~20 temp files, building a real MPQ and registering it via `Archive_OpenUnified` eliminates all hooks entirely. The cost is implementing an MPQ V1 builder (hash table encryption, block table, header). Could be combined with Approach E: use temp files now, migrate to MPQ later.

### Worth Combining With: Assetfix Integration

The assetfix project's `CheckFileExistence` hook and glob pattern patch could complement either approach, especially for supporting user-provided loose asset files alongside our embedded ones.

---

## Appendix: Key Function Reference

### Archive Management
| Function | Address | Convention | Notes |
|----------|---------|------------|-------|
| `MPQ_InitializeArchives` | 0x403740 | cdecl | Opens all base + patch MPQs |
| `OpenMPQArchiveWithPaths` | 0x403b00 | __fastcall | Wrapper: format path + open |
| `Archive_OpenUnified` | 0x648dd0 | __stdcall(4) | SFileOpenArchive equivalent |
| `Archive_Close` | 0x648ef0 | (ptr) | Closes archive, frees SArchive |
| `MPQ_CleanupAllArchives` | 0x403c70 | cdecl | Closes all in reverse order |
| `MPQArchiveEnumerator` | 0x4039b0 | __fastcall | Discovers patch-?.MPQ files |
| `GrowArchiveArray` | 0x4045a0 | __thiscall | Resizes archive pointer array |
| `ResizeArchiveArray` | 0x4046f0 | | Initial array allocation |

### Archive Internals
| Function | Address | Convention | Notes |
|----------|---------|------------|-------|
| `OpenFileWithValidation` | 0x655690 | (6 params) | Opens + validates MPQ file |
| `InitializeArchiveStructure` | 0x655bf0 | __fastcall | Reads header, hash, block tables |
| `Archive_ReadAttributes` | 0x6561c0 | | Reads archive attributes |
| `InitializeLookupTables` | 0x654f60 | | Lazy init for hash lookups |

### File Search
| Function | Address | Convention | Notes |
|----------|---------|------------|-------|
| `locateFileInDirectories` | 0x647e60 | __fastcall(6) | Top-level: disk → hash → archive |
| `FindFileInArchive` | 0x654920 | (4 params) | Wrapper for File_FindInArchive |
| `File_FindInArchive` | 0x6549a0 | __fastcall(7) | Recursive archive chain search |
| `File_FindInStorage` | 0x656690 | | Storage-level file search |
| `File_OpenAdvanced` | 0x656590 | | Advanced open with validation |
| `CheckFileExistence` | 0x654dd0 | __fastcall(3) | Checks disk for loose files |
| `scanDirectoriesForFiles` | 0x646ea0 | | Populates disk file hash table |
| `String_ComputeHash` | 0x64b3f0 | | Storm string hash function |

### File I/O (Current Hooks)
| Function | Address | Convention | Notes |
|----------|---------|------------|-------|
| `openFileWithOptions` | 0x6477c0 | __stdcall(4) | Top-level file open |
| `GetFileSizeFromHandle` | 0x6487f0 | __stdcall(2) | Type-dispatched size query |
| `ReadFileFromMultipleSources` | 0x648460 | __stdcall(5) | Type-dispatched read |
| `processAsyncFileOperation` | 0x647350 | __fastcall(ECX) | Async executor low-level |
| `CleanupFileHandleResources` | 0x648730 | __stdcall(1) | Close + free file context |
| `initializeFileContext` | 0x647290 | __thiscall | Init critsec, set type |
| `cleanupFileContext` | 0x6472d0 | __thiscall | Destroy critsec, free path |

### I/O Provider System
| Function/Symbol | Address | Notes |
|-----------------|---------|-------|
| `CreateIOObject` | 0x66dfa0 | __cdecl, allocates 0x118-byte IO object |
| `InitializeIOObject` | 0x66dfe0 | __thiscall, sets vtable + async manager |
| `SetIOCallback` | 0x66e230 | __cdecl, creates callback-style IO object |
| IO vtable | 0x80fddc | 12-entry function pointer table |
| `Resource_Load` (vtable[1]) | 0x66e0c0 | __thiscall, the read dispatch function |
| `Resource_Unload` (vtable[2]) | 0x66e130 | __thiscall, unload/release |
| `ValidateIOOperation` (vtable[8]) | 0x66e2d0 | |
| `GetIOResult` (vtable[9]) | 0x66e310 | |
| `CancelIOOperation` (vtable[10]) | 0x66e340 | |

### Low-Level MPQ (ZipFileArchive)
| Function | Address | Notes |
|----------|---------|-------|
| `MPQ_OpenArchive` | 0x668360 | __fastcall, allocates 0x110 bytes |
| `MPQ_CloseArchive` | 0x668440 | |
| `openArchiveFile` | 0x667bd0 | __thiscall, calls `openFileReadOnly` → `CreateFileA` |
| `readArchiveHeader` | 0x667c10 | Reads + validates MPQ header |
| `MPQ_ProcessFileTable` | 0x667da0 | Processes hash/block tables |
| `readFromArchiveFile` | 0x668750 | __fastcall, sector-based read |
| `seekInArchiveFile` | 0x668650 | |
| `closeArchiveFile` | 0x668610 | |
| `findFileInArchive` (low-level) | 0x668470 | Hash table lookup |
| `extractFileFromArchive` | 0x668950 | Full file extraction |
| MPQ archive linked list | 0xc5a32c | Head of ZipFileArchive linked list |
| ZipFileArchive RTTI | 0x86709c | `".?AUZipFileArchive@@"` |

### Globals
| Symbol | Address | Description |
|--------|---------|-------------|
| Archive array capacity | 0x8826b4 | Max archive slots |
| Archive array count | 0x8826b8 | Current archive count |
| Archive array pointer | 0x8826bc | `SArchive**` — array of pointers |
| Archive array growth | 0x8826c0 | Growth increment |
| Disk hash table base | 0xc521e8 | File path → disk path hash table |
| Disk hash table mask | 0xc521f0 | Hash mask (0xffffffff = disabled) |
| Archive search critsec | 0xc54008 | Critical section for archive ops |
| Archive search state | 0xc53ff0 | Used by File_FindInArchive |
| Patch glob "patch-?.MPQ" | 0x82edbc | Glob pattern for patch discovery |
| Patch glob char | 0x82edc2 | The '?' byte (assetfix patches to '*') |
| Data path format | 0x82edc8 | `"Data\%s"` format string |
| SArchive RTTI | 0x82e248 | `".PAVSArchive@@"` |
