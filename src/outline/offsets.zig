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
