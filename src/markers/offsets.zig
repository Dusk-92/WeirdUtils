//! Offsets for marker/game object system

// =============================================================================
// Unit position
// =============================================================================

/// Unit + this → movement struct pointer
pub const UNIT_MOVEMENT_OFFSET: usize = 0x118;

/// Movement struct + this → X coordinate (float)
pub const MOVEMENT_POS_X: usize = 0x10;

/// Movement struct + this → Y coordinate (float)
pub const MOVEMENT_POS_Y: usize = 0x14;

/// Movement struct + this → Z coordinate (float)
pub const MOVEMENT_POS_Z: usize = 0x18;

// =============================================================================
// Entity creation (high-level API)
// =============================================================================

/// CreateEntityInstance_WithAttachment - __fastcall, RET 0x14 (5 stack params).
/// ECX = modelPath (char*), EDX = position (float[3]*)
/// Stack: facing (float), flags (int), updateNow (int), param6 (int), param7 (int)
/// Returns: entity pointer (int*).
///
/// Routes M2 models (no ".wmo" in path) through CreateWorldUnit.
/// Routes WMO models (".wmo" in path) through CreateGameObject + ModelAttachment_CreateNode
/// + global list insertion + SetObjectTransformation.
///
/// Both paths call UpdateWorldPosition when updateNow != 0.
/// Increments refcount at entity+0x0E.
pub const FN_CREATE_ENTITY_INSTANCE: usize = 0x006707c0;

// =============================================================================
// World teardown (map unload / logout / exit)
// =============================================================================

/// CleanupWorldAndEntities - void(), no params, __stdcall.
/// Top-level world teardown: calls CleanupEntityList_ProcessAll, then
/// CleanupWorldAndReleaseResources (which iterates heaps and force-frees).
/// Called from InitializeWorldScene (map change) and ShutdownClientSystems (exit).
/// Hook this to destroy custom entities BEFORE the game's teardown begins.
pub const FN_CLEANUP_WORLD_AND_ENTITIES: usize = 0x0066fc40;

// =============================================================================
// World object lifecycle
// =============================================================================

/// AllocateAndInitializeWorldObject(initializeFlag)
/// __fastcall returns void**
pub const FN_ALLOCATE_WORLD_OBJECT: usize = 0x006a0930;

/// DestroyWorldObjectAndRelease(object) - __fastcall, ECX=obj, no stack params.
/// Unlinks from world object list (+0x10/+0x14), calls virtual destructor, frees heap.
/// ONLY for objects on WENTITY heap (from AllocateAndInitializeWorldObject).
pub const FN_DESTROY_WORLD_OBJECT: usize = 0x006a0a70;

/// CleanupEntity_ProcessAttachments(entity) - __fastcall, ECX=entity, no stack params.
/// High-level destructor counterpart to CreateEntityInstance_WithAttachment.
/// Walks and frees attachment children, decrements refcount at +0x0E, then
/// dispatches to type-specific destructor based on flags at +0x8:
///   flag 0x8 (M2):  destroyWorldEnvironment (0x6a6870) - scene graph removal + free
///   flag 0x40 (WMO): cleanupGameObject (0x6a67a0) - render detach + spatial unlink + free
/// Only actually frees when refcount reaches 0.
pub const FN_CLEANUP_ENTITY: usize = 0x00670d50;

/// DecrementReferenceCount(obj) - __fastcall, ECX=obj, no stack params.
/// Decrements ref count; when it reaches 0, calls virtual destructor to free.
pub const FN_DECREMENT_REFCOUNT: usize = 0x007103a0;

// =============================================================================
// Cursor terrain position
// =============================================================================

/// WorldFrame global pointer - *(u32*)PTR = worldFrame object.
pub const PTR_WORLD_FRAME: usize = 0x00B4B2BC;

/// UpdateHitTest - __fastcall(ECX=worldFrame), no stack params.
/// Raycasts from camera through mouse cursor, stores result at worldFrame+0x350.
pub const FN_UPDATE_HIT_TEST: usize = 0x00481F00;

/// Offsets from worldFrame base to HitTestResult fields.
pub const WF_HIT_TYPE: usize = 0x350; // 0=terrain, 1=ground-target, 2=object
pub const WF_HIT_GUID: usize = 0x358; // u64 object GUID (0 for terrain)
pub const WF_HIT_TERRAIN_X: usize = 0x360;
pub const WF_HIT_TERRAIN_Y: usize = 0x364;
pub const WF_HIT_TERRAIN_Z: usize = 0x368;

// =============================================================================
// Zone / area identification
// =============================================================================

/// Current zone area ID - numeric, locale-safe zone identifier.
/// Updated by the game as the player moves between areas.
pub const ZONE_AREA_ID: usize = 0x00B4E314;

// =============================================================================
// Per-frame world update
// =============================================================================

/// OnWorldUpdate - __fastcall(ECX=worldFrame), no stack params, void return.
/// Called every frame while the world is active (in-game, not login screen).
/// Part of CGWorldFrame update pipeline.
pub const FN_ON_WORLD_UPDATE: usize = 0x00482EA0;

// =============================================================================
// Model creation
// =============================================================================

/// CM2Model_CreateForModelObject(modelPath_ECX, worldObj_EDX, forceInit)
/// __fastcall, RET 0x04. ECX=modelPath(char*), EDX=worldObject, 1 stack param.
/// Complete model creation pipeline: createModelAttachment, SetModelScale,
/// SetCallbackFunctions, SetRenderCallbacks, PlayBoneAnimation, CM2Model_Initialize.
/// Returns 1 on success, 0 on failure. Stores render context at worldObj+0x88.
pub const FN_CM2_CREATE_FOR_MODEL_OBJECT: usize = 0x00695100;

// =============================================================================
// Animation
// =============================================================================

/// CM2Model__PlayBoneAnimation - __thiscall(ECX=modelRenderCtx), RET 0x1c (7 stack params).
/// (boneIndex, animId, sequenceIndex, animData*, speed, blendMode, queueAnimation)
///   boneIndex:     0xFFFFFFFF = all bones
///   animId:        M2 animation ID (0=Stand, 158=Hold, 159=Decay for Raid_UI_FX)
///   sequenceIndex: -1 = random sub-sequence
///   animData:      NULL for default timing
///   speed:         1.0 = normal
///   blendMode:     0 = hard cut, 1 = smooth blend
///   queueAnimation: 0 = set immediately, 1 = queue after current
pub const FN_PLAY_BONE_ANIMATION: usize = 0x007121a0;

// =============================================================================
// Transform and position
// =============================================================================

/// UpdateObjectTransform_CalculateBounds - __fastcall, RET 0x0C
/// ECX = world object, EDX = 4x4 transform matrix (float[16])
/// Stack: bounds (float[6] min/max), halfExtents (float[3]), forceUpdate (int)
pub const FN_UPDATE_OBJECT_TRANSFORM: usize = 0x006717d0;

// =============================================================================
// File I/O (Storm) - for in-memory file serving
// =============================================================================

/// openFileWithOptions - __stdcall(4), RET 0x10, prologue=9
/// (archive_ptr, path, flags, handle_out) → type_code (0=fail, 1-4=success)
pub const FN_OPEN_FILE_WITH_OPTIONS: usize = 0x006477c0;

/// GetFileSizeFromHandle - __stdcall(2), RET 0x08, prologue=6
/// (file_context, high_size_out) → size
pub const FN_GET_FILE_SIZE: usize = 0x006487f0;

/// ReadFileFromMultipleSources - __stdcall(6), RET 0x18, prologue=6
/// (context, buffer, size, bytes_read_out, async_ptr, param6) → bool
/// async_ptr==NULL: synchronous read. Non-NULL: queues async operation.
pub const FN_READ_FILE: usize = 0x00648460;

/// CleanupFileHandleResources - __stdcall(1), RET 0x04, prologue=7
/// (file_context) → 1
pub const FN_CLEANUP_FILE_HANDLE: usize = 0x00648730;

/// processAsyncFileOperation - __fastcall(ECX=request), plain RET, prologue=7
/// Request structure: +0x08=file_ctx, +0x0C=dest_buf, +0x10=read_size,
/// +0x14=seek/event_struct (*(+0x14)+4 = event handle)
pub const FN_PROCESS_ASYNC_FILE_OP: usize = 0x00647350;

/// initializeFileContext - __thiscall(ECX=ctx, type)
/// Sets context type, initializes critical section at +0x24, zeroes fields.
pub const FN_INIT_FILE_CONTEXT: usize = 0x00647290;

/// cleanupFileContext - __thiscall(ECX=ctx)
/// Destroys critical section, cleanup companion to initializeFileContext.
pub const FN_CLEANUP_FILE_CONTEXT: usize = 0x006472d0;

/// FreeMemory (SMemFree) - __stdcall(3): (ptr, src_str, flags)
pub const FN_FREE_MEMORY: usize = 0x00646430;

// =============================================================================
// M2 model loading (async pipeline)
// =============================================================================

/// loadModelFromFileAsync - __thiscall(ECX=model_obj), 2 stack params, RET 0x08
/// (fileHandle: **ctx, shouldUseCallback: int) → 1
/// Prologue: 55 8b ec 8b 55 0c 56 8b f1 - safe sizes: [6, 7, 9]
/// Allocates async task to read file and call onModelLoadComplete when done.
/// The async executor at 0x71d610 calls fileReadWithLock directly, bypassing
/// our ReadFileFromMultipleSources hook - hence this hook fills the buffer
/// synchronously for fake file contexts.
pub const FN_LOAD_MODEL_ASYNC: usize = 0x0071d4e0;

/// processLoadedModelData - __fastcall(ECX=model), no stack params, plain RET
/// Parses model header from buffer at model+0x130 (ptr) / model+0x134 (size),
/// initializes model resources, sets bit 0 of model+8 when done.
pub const FN_PROCESS_LOADED_MODEL_DATA: usize = 0x0071d640;

// =============================================================================
// Permission check - leader / raid officer
// =============================================================================

/// Group leader GUID (64-bit): low u32 at +0, high u32 at +4.
/// Valid for both party leader and raid leader.
pub const LEADER_GUID: usize = 0x00bc75f8;

/// Raid roster - array of 40 pointers to roster entry structs.
/// Entry layout: +0x00/+0x04 = GUID (u64), +0x08 = subgroup, +0x0C = rank.
/// Rank: 0 = member, 1 = assistant, 2 = leader.
pub const RAID_ROSTER_ARRAY: usize = 0x00b712a8;

/// Number of raid members (u32). 0 when not in a raid.
pub const RAID_MEMBER_COUNT: usize = 0x00b713e0;

/// Offset within a roster entry to the rank field (i32).
pub const ROSTER_ENTRY_RANK: usize = 0x0C;

/// Party member GUIDs - 4 slots, 8 bytes each (lo/hi u32 pairs).
/// Contains other party members (not local player). Stride = 8.
pub const PARTY_MEMBER_GUIDS: usize = 0x00bc6f48;

/// GetPlayerGUID - __fastcall(), no params, returns EAX(low):EDX(high).
pub const FN_GET_PLAYER_GUID: usize = 0x00468550;

/// RetrieveNPCDataFromCache - __thiscall(ECX=cache_obj), 6 stack params, RET 0x18.
/// (guid_low, guid_high, name_buf_ptr, 0, 0, 0) → char* name or NULL.
/// Used by GetRaidRosterInfo to resolve player names from GUIDs.
pub const FN_NAME_CACHE_LOOKUP: usize = 0x0055f080;

/// Name cache object - static instance at this address. Passed as ECX (this)
/// to RetrieveNPCDataFromCache.
pub const NAME_CACHE_OBJ: usize = 0x00c0e228;
