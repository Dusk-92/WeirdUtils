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
// GameObject creation functions
// =============================================================================

/// CreateGameObject_WithProperties(model_ECX, callback1_EDX, callback2, x, y, z, flags)
/// __fastcall — ECX=model, EDX=callback1, 5 stack params. Callee cleans (RET 0x14).
/// Ghidra: 55 8B EC 83 EC 14 ... 89 4D FC (saves ECX) ... 89 55 F8 (saves EDX) ... C2 14 00.
pub const FN_CREATE_GAMEOBJECT: usize = 0x00670db0;

/// AllocateAndInitializeWorldObject(initializeFlag)
/// __fastcall returns void**
pub const FN_ALLOCATE_WORLD_OBJECT: usize = 0x006a0930;

/// CleanupWorldObject(object)
/// __thiscall
pub const FN_CLEANUP_WORLD_OBJECT: usize = 0x0069d730;

/// DestroyWorldObjectAndRelease(object)
/// __fastcall
pub const FN_DESTROY_WORLD_OBJECT: usize = 0x006a0a70;

// =============================================================================
// Model loading
// =============================================================================

/// loadModelByName(path)
/// __fastcall returns model cache entry
pub const FN_LOAD_MODEL_BY_NAME: usize = 0x006d4640;

/// createModelAttachment(resourceManager, path, flags)
/// __thiscall returns render context
pub const FN_CREATE_MODEL_ATTACHMENT: usize = 0x00707350;

// =============================================================================
// Animation control
// =============================================================================

/// PlayAnimation(object, animId)
/// __thiscall
pub const FN_PLAY_ANIMATION: usize = 0x0076cf50;

/// CM2Model__PlayBoneAnimation(model, boneIndex, animId, seqIndex, animData, speed, blend, queue)
/// __thiscall
pub const FN_PLAY_BONE_ANIMATION: usize = 0x007121a0;

/// HasAnimation(model, animId)
/// __thiscall returns bool
pub const FN_HAS_ANIMATION: usize = 0x00711960;

// =============================================================================
// Animation IDs (from string table)
// =============================================================================

pub const ANIM_SPAWN: u32 = 0;      // TODO: find actual ID
pub const ANIM_DESPAWN: u32 = 0;    // TODO: find actual ID
pub const ANIM_BIRTH: u32 = 0;      // TODO: find actual ID

// =============================================================================
// Object structure offsets (from CreateGameObject_WithProperties analysis)
// =============================================================================

/// WorldObject + this → model pointer
pub const OBJ_MODEL: usize = 0x88;

/// WorldObject + this → position X (float*)
pub const OBJ_POS_X: usize = 0xC0;

/// WorldObject + this → position Y (float*)
pub const OBJ_POS_Y: usize = 0xC4;

/// WorldObject + this → position Z (float*)
pub const OBJ_POS_Z: usize = 0xC8;

/// WorldObject + this → color ARGB (alpha in high byte)
pub const OBJ_COLOR: usize = 0x24;

/// WorldObject + this → flags
pub const OBJ_FLAGS: usize = 0x90;
