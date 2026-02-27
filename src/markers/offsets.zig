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

/// CreateEntityInstance_WithAttachment — __fastcall, RET 0x14 (5 stack params).
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
// World object lifecycle
// =============================================================================

/// AllocateAndInitializeWorldObject(initializeFlag)
/// __fastcall returns void**
pub const FN_ALLOCATE_WORLD_OBJECT: usize = 0x006a0930;

/// DestroyWorldObjectAndRelease(object) — __fastcall, ECX=obj, no stack params.
/// Unlinks from world object list (+0x10/+0x14), calls virtual destructor, frees heap.
/// Ends with tail JMP to ReleaseToHeap — from caller's perspective, a normal return.
pub const FN_DESTROY_WORLD_OBJECT: usize = 0x006a0a70;

/// DecrementReferenceCount(obj) — __fastcall, ECX=obj, no stack params.
/// Decrements ref count; when it reaches 0, calls virtual destructor to free.
pub const FN_DECREMENT_REFCOUNT: usize = 0x007103a0;

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
// Transform and position
// =============================================================================

/// UpdateObjectTransform_CalculateBounds — __fastcall, RET 0x0C
/// ECX = world object, EDX = 4x4 transform matrix (float[16])
/// Stack: bounds (float[6] min/max), halfExtents (float[3]), forceUpdate (int)
pub const FN_UPDATE_OBJECT_TRANSFORM: usize = 0x006717d0;
