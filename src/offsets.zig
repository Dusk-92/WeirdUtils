//! Shared WoW 1.12.1 (build 5875) memory addresses and struct offsets.
//!
//! Contains only addresses/offsets duplicated across 2+ modules.
//! Module-specific offsets remain in their own files.

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

/// object + this → pointer to descriptor block (m_data).
pub const UNIT_DESCRIPTOR_OFFSET: usize = 0x110;

/// Alternate descriptor offset used by items/corpses (at +0x08).
pub const OBJECT_DATA_OFFSET: usize = 0x08;

// =============================================================================
// Descriptor field indices (byte offset = index * 4 from descriptor base)
// =============================================================================

/// OBJECT_FIELD_ENTRY (index 0x03)
pub const DESC_ENTRY: usize = 0x03 * 4;

/// UNIT_NPC_FLAGS = OBJECT_END(0x06) + 0x8D = 0x93
pub const DESC_NPC_FLAGS: usize = 0x93 * 4;

/// UNIT_DYNAMIC_FLAGS = OBJECT_END(0x06) + 0x90 = 0x96
pub const DESC_UNIT_DYNAMIC_FLAGS: usize = 0x96 * 4;

/// Bit 0: unit corpse is lootable by the local player.
pub const UNIT_DYNFLAG_LOOTABLE: u32 = 0x01;

/// GAMEOBJECT_TYPE_ID (index 0x15)
pub const DESC_GO_TYPE: usize = 0x15 * 4;

/// UNIT_FIELD_SUMMONEDBY (index 0x0C, GUID = 8 bytes)
pub const DESC_SUMMONEDBY: usize = 0x0C * 4;

/// UNIT_FIELD_BYTES_0: race|class|gender|power (index 0x24)
pub const DESC_BYTES_0: usize = 0x24 * 4;

/// GAMEOBJECT_FLAGS (index 0x09)
pub const DESC_GO_FLAGS: usize = 0x09 * 4;

/// GAMEOBJECT_DYN_FLAGS (index 0x13)
pub const DESC_GO_DYN_FLAGS: usize = 0x13 * 4;

// =============================================================================
// Unit descriptor fields (byte offsets from descriptor base)
// =============================================================================

/// Descriptor + this → unit flags (uint32). Test with UNIT_FLAG_DEAD.
pub const UNIT_FLAGS_OFFSET: usize = 0x224;

/// Bit mask: unit is dead.
pub const UNIT_FLAG_DEAD: u32 = 0x20;

/// Descriptor + this → current HP (int32).
pub const UNIT_HP_OFFSET: usize = 0x40;

// =============================================================================
// Corpse descriptor fields
// =============================================================================

/// Corpse descriptor + this → owner GUID (8 bytes).
pub const CORPSE_FIELD_OWNER: usize = 0x18;

/// Corpse descriptor + this → corpse flags (uint32).
pub const CORPSE_FIELD_FLAGS: usize = 0x8C;

/// Bit mask: corpse is a skeleton (not resurrectable).
pub const CORPSE_FLAG_BONE: u32 = 0x01;

// =============================================================================
// Unit position (movement struct)
// =============================================================================

/// Unit + this → movement struct pointer
pub const UNIT_MOVEMENT_OFFSET: usize = 0x118;

/// Movement struct position offsets
pub const MOVEMENT_POS_X: usize = 0x10;
pub const MOVEMENT_POS_Y: usize = 0x14;
pub const MOVEMENT_POS_Z: usize = 0x18;

// =============================================================================
// Map / Zone identification
// =============================================================================

/// Current zone area ID — numeric, locale-safe zone identifier.
pub const ZONE_AREA_ID: usize = 0x00B4E314;

/// ObjMgr + this → current map ID (u32).
pub const OBJMGR_MAP_ID_OFFSET: usize = 0xCC;

/// Pointer to Map.dbc indexed lookup table.
pub const MAP_DBC_DATA: usize = 0x00C0DAA8;

/// Pointer to Map.dbc max valid index.
pub const MAP_DBC_MAX: usize = 0x00C0DAAC;

/// Map.dbc row + this → mapType (u32). 0=world, 1=instance, 2=raid, 3=battleground.
pub const MAP_DBC_MAP_TYPE_OFFSET: usize = 0x08;

/// MapType value for battleground instances.
pub const MAP_TYPE_BATTLEGROUND: u32 = 3;

// =============================================================================
// Game state
// =============================================================================

/// Non-zero when the player is logged in and in the world.
pub const IS_IN_WORLD: usize = 0xB4B424;

// =============================================================================
// Raid targets
// =============================================================================

/// Static array of 8 GUIDs (64 bytes total). Index 0 = Star, 7 = Skull.
pub const RAID_TARGET_ARRAY: usize = 0x00B71368;

// =============================================================================
// Core function addresses
// =============================================================================

/// __stdcall(guidLo, guidHi) → object pointer. RET 8.
pub const FN_GET_OBJECT_BY_GUID: usize = 0x464870;

/// __fastcall(unitIdStr_ECX) → GUID in EAX:EDX.
pub const FN_UNIT_GUID: usize = 0x515970;

/// __thiscall(localPlayer_ECX, targetUnit_stack) → reaction int. >=4 = friendly.
pub const FN_UNIT_REACTION: usize = 0x6061E0;

/// __fastcall(), no params, returns EAX(low):EDX(high).
pub const FN_GET_PLAYER_GUID: usize = 0x00468550;

/// __fastcall(obj_ECX) → bool. GO interactability check.
pub const FN_CALL_SPELL_CAST_HANDLER: usize = 0x5F8800;

/// CVar lookup: __fastcall(name_ECX) → CVar* or 0.
pub const FN_CVAR_LOOKUP: usize = 0x0063DEC0;

/// SceneEnd: __thiscall(device). Per-frame hook point.
pub const FN_SCENE_END: usize = 0x5A17A0;

// =============================================================================
// D3D9 / GxDevice
// =============================================================================

/// Game's GxDevice global pointer.
pub const GX_DEVICE_PTR: usize = 0xC0ED38;

/// GxDevice + this → IDirect3DDevice9*.
pub const GX_DEVICE_D3D_OFFSET: usize = 0x38A8;
