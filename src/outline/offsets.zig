//! WoW 1.12.1 (build 5875) memory addresses and struct offsets for the outline system.
//!
//! Sources: Ghidra analysis, UnitXP_SP3, Idris DLL reference implementation.

// =============================================================================
// Object Manager
// =============================================================================

/// Pointer to the Object Manager base. Dereference once to get the ObjMgr struct.
pub const OBJECT_MANAGER_PTR: usize = 0x00B41414;

/// ObjMgr + this → first object in the linked list.
pub const OBJECT_LIST_OFFSET: usize = 0xAC;

/// ObjMgr + this → base pointer for the next-object traversal table.
pub const OBJECT_NEXT_OFFSET: usize = 0xA4;

/// ObjMgr + this → local player GUID (8 bytes).
pub const LOCAL_PLAYER_GUID_OFFSET: usize = 0xC0;

// =============================================================================
// Object fields (from object base pointer)
// =============================================================================

pub const OBJECT_TYPE_OFFSET: usize = 0x14;
pub const OBJECT_GUID_OFFSET: usize = 0x30;

// =============================================================================
// Unit / Player descriptor fields
// =============================================================================

/// object + this → pointer to descriptor block.
pub const UNIT_DESCRIPTOR_OFFSET: usize = 0x110;

/// Descriptor + this → current HP (int32).
pub const UNIT_HP_OFFSET: usize = 0x40;

/// Descriptor + this → unit flags (uint32). Test with UNIT_FLAG_DEAD.
pub const UNIT_FLAGS_OFFSET: usize = 0x224;

/// Bit mask: unit is dead.
pub const UNIT_FLAG_DEAD: u32 = 0x20;

// =============================================================================
// Corpse descriptor fields
// =============================================================================

/// Corpse object + this → pointer to corpse descriptor.
pub const CORPSE_DESCRIPTOR_OFFSET: usize = 0x8;

/// Corpse descriptor + this → owner GUID (8 bytes).
pub const CORPSE_FIELD_OWNER: usize = 0x18;

/// Corpse descriptor + this → corpse flags (uint32).
pub const CORPSE_FIELD_FLAGS: usize = 0x8C;

/// Bit mask: corpse is a skeleton (not resurrectable).
pub const CORPSE_FLAG_BONE: u32 = 0x01;

// =============================================================================
// Raid targets
// =============================================================================

/// Static array of 8 GUIDs (64 bytes total). Index 0 = Star, 7 = Skull.
pub const RAID_TARGET_ARRAY: usize = 0x00B71368;

// =============================================================================
// Model ownership (offsets from model pointer)
// =============================================================================

/// model + this → direct owner object pointer (set by InitializeModelWithParameters).
pub const MODEL_OWNER_DIRECT: usize = 0x28;

/// model + this → render callback owner pointer (set by SetRenderCallbacks).
pub const MODEL_OWNER_CALLBACK: usize = 0x3C0;

// =============================================================================
// Render context
// =============================================================================

/// renderContext + this → current model pointer being rendered.
pub const RENDER_CONTEXT_MODEL_OFFSET: usize = 0x3310;

// =============================================================================
// Game state
// =============================================================================

/// Non-zero when the player is logged in and in the world.
pub const IS_IN_WORLD: usize = 0xB4B424;

// =============================================================================
// Function addresses
// =============================================================================

/// __stdcall(guidLo_stack, guidHi_stack) → object pointer (EAX). Returns 0 on miss.
/// Callee cleans 8 bytes (RET 8). NOT __fastcall — params on stack, not registers.
pub const FN_GET_OBJECT_BY_GUID: usize = 0x464870;

/// __fastcall(unitIdStr_ECX) → GUID in EAX:EDX. Accepts "player", "target", etc.
pub const FN_UNIT_GUID: usize = 0x515970;

/// __thiscall(localPlayer_ECX, targetUnit_stack) → reaction int (0-7). >=4 = friendly.
pub const FN_UNIT_REACTION: usize = 0x6061E0;

// =============================================================================
// Hooked function addresses (model rendering pipeline)
// =============================================================================

/// CM2SceneRenderDraw — main batch rendering entry point.
/// __thiscall(this, viewMatrix, batchData, batchIndices, batchCount)
pub const FN_CM2SCENE_RENDER_DRAW: usize = 0x0070b360;

/// CM2Model_ManageRenderListNode — called for every model added/removed from render list.
/// __thiscall(model_ECX, addToList_stack)
pub const FN_CM2MODEL_MANAGE_RENDER_LIST: usize = 0x00710b90;

/// CM2Scene_DrawModelBatchProjected — called per batch (type 0) during rendering.
/// __fastcall(renderContext_ECX)
pub const FN_DRAW_BATCH_PROJ: usize = 0x0070cb30;
