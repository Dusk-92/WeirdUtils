//! Markers-specific WoW 1.12.1 memory addresses and struct offsets.
//!
//! Shared addresses (object manager, game functions, map/zone, etc.) live in src/offsets.zig.

// =============================================================================
// Entity creation (high-level API)
// =============================================================================

/// CreateEntityInstance_WithAttachment - __fastcall, RET 0x14 (5 stack params).
/// ECX = modelPath (char*), EDX = position (float[3]*)
/// Stack: facing (float), flags (int), updateNow (int), param6 (int), param7 (int)
/// Returns: entity pointer (int*).
pub const FN_CREATE_ENTITY_INSTANCE: usize = 0x006707c0;

// =============================================================================
// World teardown (map unload / logout / exit)
// =============================================================================

/// CleanupWorldAndEntities - void(), no params, __stdcall.
pub const FN_CLEANUP_WORLD_AND_ENTITIES: usize = 0x0066fc40;

// =============================================================================
// World object lifecycle
// =============================================================================

pub const FN_ALLOCATE_WORLD_OBJECT: usize = 0x006a0930;
pub const FN_DESTROY_WORLD_OBJECT: usize = 0x006a0a70;

/// CleanupEntity_ProcessAttachments(entity) - __fastcall, ECX=entity.
pub const FN_CLEANUP_ENTITY: usize = 0x00670d50;

pub const FN_DECREMENT_REFCOUNT: usize = 0x007103a0;

// =============================================================================
// Cursor terrain position
// =============================================================================

pub const PTR_WORLD_FRAME: usize = 0x00B4B2BC;
pub const FN_UPDATE_HIT_TEST: usize = 0x00481F00;

pub const WF_HIT_TYPE: usize = 0x350;
pub const WF_HIT_GUID: usize = 0x358;
pub const WF_HIT_TERRAIN_X: usize = 0x360;
pub const WF_HIT_TERRAIN_Y: usize = 0x364;
pub const WF_HIT_TERRAIN_Z: usize = 0x368;

// =============================================================================
// Per-frame world update
// =============================================================================

pub const FN_ON_WORLD_UPDATE: usize = 0x00482EA0;

// =============================================================================
// Model creation
// =============================================================================

pub const FN_CM2_CREATE_FOR_MODEL_OBJECT: usize = 0x00695100;

// =============================================================================
// Animation
// =============================================================================

/// CM2Model__PlayBoneAnimation - __thiscall(ECX=modelRenderCtx), RET 0x1c (7 stack params).
pub const FN_PLAY_BONE_ANIMATION: usize = 0x007121a0;

// =============================================================================
// Transform and position
// =============================================================================

pub const FN_UPDATE_OBJECT_TRANSFORM: usize = 0x006717d0;

// =============================================================================
// File I/O (Storm) - for in-memory file serving
// =============================================================================

pub const FN_OPEN_FILE_WITH_OPTIONS: usize = 0x006477c0;
pub const FN_GET_FILE_SIZE: usize = 0x006487f0;
pub const FN_READ_FILE: usize = 0x00648460;
pub const FN_CLEANUP_FILE_HANDLE: usize = 0x00648730;
pub const FN_PROCESS_ASYNC_FILE_OP: usize = 0x00647350;
pub const FN_INIT_FILE_CONTEXT: usize = 0x00647290;
pub const FN_CLEANUP_FILE_CONTEXT: usize = 0x006472d0;
pub const FN_FREE_MEMORY: usize = 0x00646430;

// =============================================================================
// M2 model loading (async pipeline)
// =============================================================================

pub const FN_LOAD_MODEL_ASYNC: usize = 0x0071d4e0;
pub const FN_PROCESS_LOADED_MODEL_DATA: usize = 0x0071d640;

// =============================================================================
// Permission check - leader / raid officer
// =============================================================================

pub const LEADER_GUID: usize = 0x00bc75f8;
pub const RAID_ROSTER_ARRAY: usize = 0x00b712a8;
pub const RAID_MEMBER_COUNT: usize = 0x00b713e0;
pub const ROSTER_ENTRY_RANK: usize = 0x0C;
pub const PARTY_MEMBER_GUIDS: usize = 0x00bc6f48;

/// RetrieveNPCDataFromCache - __thiscall(ECX=cache_obj), 6 stack params, RET 0x18.
pub const FN_NAME_CACHE_LOOKUP: usize = 0x0055f080;
pub const NAME_CACHE_OBJ: usize = 0x00c0e228;
