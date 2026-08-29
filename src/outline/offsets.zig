//! Outline-specific WoW 1.12.1 memory addresses and struct offsets.
//!
//! Shared addresses (object manager, game functions, etc.) live in src/offsets.zig.

// =============================================================================
// Model ownership (offsets from model pointer)
// =============================================================================

/// model + this → direct owner object pointer (set by InitializeModelWithParameters).
pub const MODEL_OWNER_DIRECT: usize = 0x28;

/// model + this → render callback owner pointer (set by SetRenderCallbacks).
pub const MODEL_OWNER_CALLBACK: usize = 0x3C0;

/// V40: parent/root CM2Model for an attached model.
/// Proven from WoW 1.12.1 build 5875 function 0x712F70:
/// child+0x1CC = root, child+0x1D0 = attachment id,
/// root+0x1DC = child-list head, child+0x1E4 = next sibling.
pub const MODEL_ATTACHMENT_PARENT: usize = 0x1CC;
pub const MODEL_ATTACHMENT_ID: usize = 0x1D0;
pub const MODEL_CHILD_HEAD: usize = 0x1DC;
pub const MODEL_NEXT_SIBLING: usize = 0x1E4;

// =============================================================================
// Render context
// =============================================================================

/// renderContext + this → current model pointer being rendered.
pub const RENDER_CONTEXT_MODEL_OFFSET: usize = 0x3310;

// =============================================================================
// Hooked function addresses (model rendering pipeline)
// =============================================================================

/// CM2SceneRenderDraw - main batch rendering entry point.
/// __thiscall(this, viewMatrix, batchData, batchIndices, batchCount)
pub const FN_CM2SCENE_RENDER_DRAW: usize = 0x0070b360;

/// CM2Model_ManageRenderListNode - called for every model added/removed from render list.
/// __thiscall(model_ECX, addToList_stack)
pub const FN_CM2MODEL_MANAGE_RENDER_LIST: usize = 0x00710b90;

/// CM2Scene_DrawModelBatchProjected - called per batch (type 0) during rendering.
/// __fastcall(renderContext_ECX)
pub const FN_DRAW_BATCH_PROJ: usize = 0x0070cb30;
