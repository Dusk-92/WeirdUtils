# SceneObject Field Offsets -- Assembly-Verified

Extracted from `[EBX+N]` patterns in transformMatrix4x4 (0x714260, 17703 bytes).
EBX = this pointer (set at prologue: `MOV EBX, ECX`).

**WARNING**: Ghidra struct field names like `field_0x184` do NOT encode the actual
byte offset. The Ghidra struct has been modified over time and field names are
inconsistent with their positions. ONLY assembly `[EBX+N]` is authoritative.

**WARNING**: RESEARCH.md previously claimed bone_runtime_base at +0x80. Assembly
confirms it is actually at +0x090.

## Complete Offset Map (51 unique offsets)

| Offset | Type | Semantic Name | Evidence |
|--------|------|---------------|----------|
| +0x010 | ptr | model_data_ptr | NULL check for early bail |
| +0x02C | ptr | animation_context_ptr | +0xC=timestamp, +0x10=sync_value |
| +0x030 | ptr | model_container_ptr | +0x130=M2 header. Ghidra SWAPS label as "ptr_at_2c" |
| +0x040 | u32 | transform_sync_value | Compared with *(anim_ctx+0x10) |
| +0x04C | u32 | search_data_base_ptr | Previous timestamp for delta computation |
| +0x050 | u32 | emitter_enable_flag | Written 0 or 1 |
| +0x064 | ptr | search_data_count / gs_values_ptr | Pointer to global sequence value array |
| +0x068 | u32 | gs_time_base / position_x | Subtracted from timestamp for GS modulo |
| +0x084 | u32 | child_objects_padding | len_sq of world_transform translation row |
| +0x08C | u32 | animation_frame_counter | CMP against bone def limits for skip checks |
| +0x090 | ptr | bone_runtime_base | Array of 0x118-byte per-bone runtime structs |
| +0x094 | ptr | bone_out_ptr / transform_vec2_x | Output bone matrices (bone_idx * 0x40) |
| +0x0A0 | ptr | tex_anim_out / transform_vec2_y | Texture animation output |
| +0x0A8 | ptr | color_anim_out / transform_vec2_z | Color animation output |
| +0x0AC | f32 | scale_factor_1 | |
| +0x0B0 | f32 | scale_factor_2 | |
| +0x0B4 | f32 | scale_factor_3 | |
| +0x0BC | ptr | particle_shader_arg1 | LEA, passed to initParticlePixelShaderGeneration |
| +0x0FC | f32 | billboard_row0[0] / model_attachment_list1 | Camera forward direction X |
| +0x100 | f32 | billboard_row0[1] / unknown_0xe4 | Camera forward Y |
| +0x104 | f32 | billboard_row0[2] / attachment_list1 | Camera forward Z |
| +0x108 | f32 | billboard_row0[3] | |
| +0x10C | f32[16] | world_transform_matrix | Billboard/camera reference matrix rows 1-3 |
| +0x17C | u32 | field_17c | Copied from emitter_ctx+0x17C |
| +0x180 | f32 | field_180 | Scale multiplier for render_scale_z |
| +0x184 | f32 | field_184 | Per-axis scale factor (X) |
| +0x188 | f32 | field_188 | Per-axis scale factor (Y) / emitter intensity |
| +0x18C | f32 | global_scale_factor | Per-axis scale factor (Z) |
| +0x190 | f32 | field_190 | Used in offset computation (FADD with param_4[0]) |
| +0x194 | f32 | render_scale_x | Added to param_4[1] |
| +0x198 | f32 | render_scale_y | Added to param_4[2] |
| +0x19C | f32 | render_scale_z | Computed: param_5 * field_180 |
| +0x1A0 | f32[3] | world_position | Vec3, passed as param_3 to child recursive calls |
| +0x1AC | f32[3] | render_priority | Vec3, passed as param_4 to child recursive calls |
| +0x1C8 | ptr | hierarchy_ptr / final_world_pos_z | Attachment hierarchy data |
| +0x1CC | ptr | emitter_context_ptr | Emitter/particle context |
| +0x1D8 | u32 | field_1d8 | Read in emitter setup |
| +0x1DC | u32 | hierarchy_idx | Linked list of child SceneObjects |
| +0x200 | ptr | ribbon_emitter_out | Ribbon emitter output base |
| +0x3C4 | ptr | particle_data1 | Particle emitter data array 1 |
| +0x3C8 | ptr | particle_data2 | Particle emitter data array 2 |
| +0x3D0 | ptr | particle_data3 | Particle emitter data array 3 |
| +0x3D4 | ptr | particle_data4 | Particle emitter data array 4 |
| +0x3D8 | u32 | additional_remaining | Written 0, then OR'd with particle active flags |

## world_transform_matrix Detail (+0x10C, float[16])

Row-major 4x4. Only 3x3 rotation + translation accessed (columns 3 are 0):

| Index | Offset | Used for |
|-------|--------|----------|
| [0] | +0x10C | Row 1 col 0 (billboard) |
| [1] | +0x110 | Row 1 col 1 |
| [2] | +0x114 | Row 1 col 2 |
| [4] | +0x11C | Row 2 col 0 |
| [5] | +0x120 | Row 2 col 1 |
| [6] | +0x124 | Row 2 col 2 |
| [8] | +0x12C | Translation X (also used for child_padding len_sq) |
| [9] | +0x130 | Translation Y |
| [10]| +0x134 | Translation Z |

## Model Header Offsets (from *(*(this+0x30) + 0x130))

| Offset | Field |
|--------|-------|
| +0x14 | Global sequence count |
| +0x18 | Global sequence durations array ptr |
| +0x20 | Animation lookup table |
| +0x34 | Bone count |
| +0x38 | Bone definition array ptr |
| +0x54 | Texture animation count |
| +0x58 | Texture animation data ptr |
| +0x64 | Color animation count |
| +0x68 | Color animation data ptr |
| +0x6C | Bone keyframe count |
| +0x70 | Bone keyframe data ptr |
| +0x74 | Bone keyframe count 2 |
| +0x78 | Bone keyframe data ptr 2 |
| +0x104 | Attachment count |
| +0x108 | Attachment data ptr |
| +0x11C | Ribbon emitter count |
| +0x120 | Ribbon emitter data ptr |
| +0x124 | Particle emitter count |
| +0x128 | Particle emitter data ptr |
| +0x134 | Additional particle count |
| +0x138 | Additional particle data ptr |
| +0x13C | Final particle section count |
| +0x140 | Final particle section data ptr |

## Method

1. Ghidra headless script extracted all `[EBX + offset]` from function instructions
2. Cross-referenced with decompilation flow to assign semantic meaning
3. Assembly disassembly at key addresses confirmed field mapping
4. Ghidra struct definition found to be INCONSISTENT with assembly (field names
   shifted from their actual byte positions) -- do not use Ghidra struct for offsets
