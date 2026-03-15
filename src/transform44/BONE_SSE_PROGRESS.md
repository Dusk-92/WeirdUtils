# bone_sse.zig — Faithful Reproduction Progress

## Principle

Exact reproduction of transformMatrix4x4 (0x714260, 17703 bytes) in Zig.
Every section verified against assembly at src/transform44/decompiled/t44_full_asm.txt.
The decompilation is NOT the primary source — assembly is authoritative.

## Assembly References

- `decompiled/t44_full_asm.txt` — 5317 instructions, complete function
- `decompiled/t44_helpers_asm.txt` — 11 helper functions
- `SCENEOBJECT_OFFSETS.md` — 51 [EBX+N] offsets

## Section Status

### Section 1: Entry checks (asm lines 5-16)
- `[EBX+0x10]` NULL check, `[EBX+0x40]` vs `[EAX+0x10]` sync check
- **VERIFIED** ✓

### Section 2: Emitter setup (asm lines 17-36)
- emitter_ctx+0x50 AND this+0x1D8 check (NOT +0x188!)
- emitter_flag at this+0x50, copy emitter_ctx+0x17C to this+0x17C
- **VERIFIED** ✓ — bug fixed: was using +0x188, now +0x1D8

### Section 3: World position/scale (asm lines 37-74)
- pos = mat2[i] * this[0x184/0x188/0x18C], stored at this+0x1A0
- offset = mat3[i] + this[0x190/0x194/0x198], stored at this+0x1AC
- render_scale_z = mat4 * this[0x180], stored at this+0x19C
- **VERIFIED** ✓

### Section 4: Global sequences (asm lines 75-95)
- count/durations from model_hdr+0x14/0x18
- timestamp from anim_ctx+0xC, base from this+0x68
- values ptr at this+0x64, unsigned DIV for modulo
- **VERIFIED** ✓

### Section 5: initPPSG matrix multiply (asm lines 96-102)
- output=this+0xFC, left=this+0xBC, right=mat1
- Calling multiplyMatrix4x4_Basic (0x7507BB) directly
- **VERIFIED** ✓

### Section 6: child_objects_padding (asm lines 103-126)
- emitter_ctx NULL or bit0 set: len_sq of world_xform[8,9,10]
- else: copy from emitter_ctx+0x84
- Stored at this+0x84
- **VERIFIED** ✓

### Section 7: Identity matrices + timestamp delta (asm lines 127-175)
- Two 4x4 identity matrices (EBP-0x70 and EBP-0xE4)
- Time delta from this+0x4C (search_data_base_ptr)
- Bone loop setup: count from model_hdr+0x34, defs from +0x38
- **VERIFIED** ✓

### Section 8a: Bone loop start (asm lines 177-189)
- bone_def = defs + idx*0x6C, bone_rt = base + idx*0x118
- anim_slot at bone_rt+0xA4, checked against -1
- **VERIFIED** ✓

### Section 8b: Animation time computation (asm lines 190-262)
- FILD * time_scale(+0xB0) → __ftol pattern for time conversion
- Looping vs clamped via anim_entry+0x10 bit 0
- **VERIFIED** ✓ — bug fixed: was missing time_scale multiplication

### Section 8c: Secondary animation time (asm lines 284-364)
- Same pattern with time_scale at +0xDC
- Expiry check: timestamp - crossfade_end(+0x100) >= 0 → expire slot
- **VERIFIED** ✓ — bug fixed: was "copy from primary", now full computation

### Section 8d: Blend weight / crossfade (asm lines 382-447)
- Hermite: (3.0 - 2*t) * t * t * crossfade_weight(+0x108)
- t = (float)remaining * crossfade_inv(+0x104)
- Clamped to [ZERO_THRESHOLD, 1.0]
- **PARTIALLY VERIFIED** — formula matches, float comparison semantics unchecked

### Section 8e: Parent inheritance + billboard PRE-processing (asm lines 448-478+)
- Root: src = this+0xFC. Child: src = bone_out + parent*0x40
- combined_flags = bone_rt[0xF4] | bone_def[0x04]
- Billboard types 2/4/6 via (flags & 6)
- **PARTIALLY VERIFIED** — offsets correct, billboard math from decompilation

### Section 8f: Animation flags check (asm ~0x714D11)
- (combined_flags & 0x280) == 0: copy parent directly
- **VERIFIED** ✓

### Section 8g: Rotation (asm 0x714D1F-0x714D52)
- rot_nts at bone_def+0x34, rot AnimData at bone_def+0x28
- buildRotMatFromQuat at 0x74B6B5 OVERWRITES matrix (does NOT multiply)
- **VERIFIED** ✓

### Section 8h: Scale + conditional multiply (asm 0x714DF7-0x714FA1)
- scale_nts at bone_def+0x50, scale AnimData at bone_def+0x44
- Conditional: if (char)flags < 0 AND bone_rt[0xF0] != 0:
  bone_local *= *(bone_rt+0xF0) via matmul 0x74A7C0
- **VERIFIED** ✓ — bug fixed: conditional multiply was missing

### Section 8i: Translation (asm 0x714FA1-0x7151BA)
- trans_nts at bone_def+0x18, trans AnimData at bone_def+0x0C
- offset = (pivot + interp) - matrix * pivot
- Final multiply: output = bone_local × parent via matmul 0x74A7C0
- **PARTIALLY VERIFIED** — structure matches, inline SSE multiply used

### Section 8k: Billboard POST-processing (asm 0x7151F9-0x71594E)
- flags & 0x78, switch on types 8/16/32/64
- Scale lengths preserved, translation recomputed
- **IMPLEMENTED** — from assembly, cross product formulas need double-check

### Section 9: Texture animation (asm 0x715966-0x715C87)
- count=model_hdr+0x54, data=+0x58, output=this+0xA0
- Data stride 0x38, output stride 0x50
- **VERIFIED** ✓ (strides confirmed from asm 0x715C70/0x715C73)

### Section 10: Color animation (asm 0x715C87-0x715F1F)
- Entry gate=model_hdr+0x64, loop bound=model_hdr+0x6C, data=+0x68
- output=this+0xA8, data stride 0x1C, output stride 0x20
- **VERIFIED** ✓ — bug fixed: loop bound was +0x64, now +0x6C

### Section 11: Bone keyframe processing (asm 0x715F25-0x7163BC)
- count=model_hdr+0x74, data=+0x78
- Data stride 0x54, output stride 0x98, matrix stride 0x40
- **VERIFIED** ✓ — bug fixed: data stride was 0x24, now 0x54

### Section 12a: Ribbon emitters (asm 0x7163BC-0x716AD9)
- count=model_hdr+0x11C, data=+0x120, output=this+0x200
- Data stride 0xD4, output stride 0x170
- **VERIFIED** ✓ — bug fixed: output stride was 0x15C, now 0x170

### Section 12b: Particle emitters (asm 0x716AD9-0x71763E)
- count=model_hdr+0x124, data=+0x128, output=this+0x3C4
- Data stride 0x7C, output stride 0x84
- **VERIFIED** ✓

### Section 12c: Additional particles — model_hdr+0x134 (asm 0x71763E-0x717D6A)
- count=model_hdr+0x134, data=+0x138, output=this+0x3C8
- Data stride 0xDC, output stride 0xD0
- Tracks: visibility(+0xC0/+0xCC), position(+0x24/+0x30), alpha(+0x40/+0x4C),
  speed(+0x5C/+0x68), emission(+0x78/+0x84), scale(+0xA4/+0xB0)
- **IMPLEMENTED** — visibility + 5 tracks from assembly

### Section 12d: additional_remaining reset (asm 0x717D6A-0x717D6F)
- `[EBX+0x3D8] = 0` between sections 12c and 12e
- **FIXED** — now correctly placed between 0x134 and 0x13C sections

### Section 12e: Final particle section — model_hdr+0x13C (asm 0x717D6A-0x7185E3)
- count=model_hdr+0x13C, data=+0x140
- output1=this+0x3D0, output2=this+0x3D4
- Data stride 0x1F8, output stride 0x16C
- All 10 tracks + visibility implemented from assembly:
  visibility(+0x1DC/+0x1E8), emission(+0x34/+0x40), speed(+0x50/+0x5C),
  color(+0x6C/+0x78), track4(+0x88/+0x94), Vec3_spline(+0xA4/+0xB0),
  track6(+0xC0/+0xCC), track7(+0xDC/+0xE8), track8(+0xF8/+0x104),
  track9(+0x114/+0x120), track10(+0x130/+0x13C)
- IsParticleBufferEmpty call at 0x7B5F60
- additional_remaining OR at [EBX+0x3D8]
- **VERIFIED** ✓ (strides and track offsets from assembly)

### Section 13: Attachment recursion (asm 0x7185E3-0x718784)
- Child attach_idx at child+0x1D4, next_sibling at child+0x1E4
- **VERIFIED** ✓

### Section 14: Sync update (asm 0x718775-0x718784)
- this+0x40 = *(anim_ctx + 0x10)
- **VERIFIED** ✓

## Bug Fix Log

| # | Bug | Wrong | Correct | Assembly ref |
|---|-----|-------|---------|-------------|
| 1 | Emitter check field | this+0x188 | this+0x1D8 | line 28 |
| 2 | Primary anim time | no time_scale | FILD*[brt+0xB0] | 0x7145AB |
| 3 | Secondary anim time | copy from primary | full w/ [brt+0xDC] | 0x714711 |
| 4 | Conditional multiply | missing | bone_local*=*(brt+0xF0) | 0x714F8D |
| 5 | Billboard post-proc | TODO/missing | 4 switch cases | 0x7151F9 |
| 6 | Color loop bound | model_hdr+0x64 | +0x6C | 0x715F0A |
| 7 | Bone KF data stride | 0x24 | 0x54 | 0x7163A2 |
| 8 | Ribbon output stride | 0x15C | 0x170 | 0x716AC2 |
| 9 | Final particle data | 0x1FC | 0x1F8 | 0x7185CD |
| 10 | Final particle output | 0x17C | 0x16C | 0x7185BA |
| 11 | Child attach_idx | +0x184 | +0x1D4 | 0x718668 |
| 12 | Child next_sibling | +0x190 | +0x1E4 | 0x718764 |
| 13 | Root bone parent | identity | this+0xFC | 0x714945 |
