# Assembly vs REF Divergence List

Full stepthrough of `t44_full_asm.txt` (5317 insns) vs `bone_sse_reference.zig` (~2298 lines).
Each issue marked with severity estimate (CRASH / WRONG / COSMETIC).

---

## ISSUE 1 — CRASH: Missing prim_time write when anim_start >= anim_end (primary slot)

**Assembly** (0x7145F1-0x714633): The looping path always ends at 0x714633 which writes `prim_time`. When `anim_end <= anim_start` (JLE at 0x7145FF), it jumps to 0x714631 which sets `EDX = anim_start`, then falls through to 0x714642: `MOV [ESI+0x98], EDX`.

**REF** (line ~1066-1077): The `if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end)))` block is the ONLY place `brt + 0x98` gets written. When `anim_start >= anim_end`, `prim_time` is **never written**.

**Impact**: On newly loaded SceneObjects, `brt+0x98` contains uninitialized garbage. The original always writes `anim_start` as a fallback. The REF leaves it as garbage, which propagates through `findInterpIdx` → `extractByte` → crash at 0x71AEBC with ECX=0x7FFFFFFF.

**Fix**: After the `if` block, add an `else` that writes `anim_start`:
```zig
if (@as(i32, @bitCast(anim_start)) < @as(i32, @bitCast(anim_end))) {
    // ...existing code...
    wu32(brt + 0x98, anim_start +% frame);
} else {
    wu32(brt + 0x98, anim_start);
}
```

Same fix needed in the clamped-not-passed branch (line ~1093-1100) which shares the same looping code.

---

## ISSUE 2 — CRASH: Missing sec_time write when anim_start >= anim_end (secondary slot)

**Assembly** (0x714757-0x714799): Identical pattern to primary. When `anim_end <= anim_start` (JLE at 0x714765), jumps to 0x714797: `MOV EDX, EAX` (EDX = anim_start), falls through to 0x7147A5: `MOV [ESI+0xC4], EDX`.

**REF** (line ~1162-1167 and ~1177-1183): Same bug — `brt + 0xC4` (`sec_time`) not written when `anim_start >= anim_end`.

**Impact**: Same as Issue 1 — stale sec_time causes bad findInterpIdx results in crossfade paths.

**Fix**: Same pattern — add `else { wu32(brt + 0xC4, anim_start); }` after each inner `if`.

---

## ISSUE 3 — WRONG: Missing cur_time clamp to sec_start in clamped-not-passed path (primary)

**Assembly** (0x7145E5-0x7145EB): When `sec_end > cur_time` AND `sec_start > cur_time`:
```asm
SUB EDX, ECX          ; sec_start - cur_time
TEST EDX, EDX
JLE looping           ; if sec_start <= cur_time, use cur_time
MOV ECX, [ESI+0xA8]  ; CLAMP: replace cur_time with sec_start
```
Then at 0x714601: `delta = ECX - sec_start` = 0 (since ECX = sec_start).

**REF** (line ~1086-1096): The inner `if (sec_start_val != cur_time ...)` block is empty — does nothing. Then `const delta = cur_time -% ru32(brt + 0xA8)` uses the UNCLAMPED cur_time.

**Impact**: When sec_start > cur_time (uncommon edge case after time delta adjustment), delta wraps to a huge unsigned value. The modulo operation may still produce a valid result, but the ftol intermediate could overflow. Lower severity than Issues 1-2 since the modulo clamps the final result.

**Fix**: Before computing delta, clamp: `const effective_time = if (sec_start_val > cur_time) sec_start_val else cur_time;` then `const delta = effective_time -% ru32(brt + 0xA8);`

---

## ISSUE 4 — WRONG: Missing cur_time clamp to sec_start in clamped-not-passed path (secondary)

**Assembly** (0x71474B): Same pattern for secondary slot.

**REF** (line ~1174-1180): Same bug — empty inner `if` block, no clamp applied.

**Fix**: Same as Issue 3 but for secondary slot variables.

---

## ISSUE 5 — WRONG: interpVec3Track36 `else return` skips crossfade for unknown modes

**Assembly** (0x716B98): For unknown interp modes (not 0, 1, 2, or 3):
```asm
DEC EDX           ; mode - 3
JNZ 0x716D1D      ; if mode != 3, jump to CROSSFADE CHECK (not return!)
```
The assembly skips primary interpolation but STILL checks and applies crossfade at 0x716D1D.

**REF** (line 695): `} else return;` — exits the entire function, skipping crossfade.

**Impact**: For models with unusual interp modes (rare), crossfade blending is skipped. Primary interpolation output is whatever was there from mode 0 (which returned earlier) or from the previous frame. The secondary crossfade result won't be blended in.

**Fix**: Replace `else return;` with `else {}` (empty block, fall through to crossfade):
```zig
} else if (mode == 2) {
    // ...bezier...
} else {
    // Unknown mode: skip primary interp, but still check crossfade below
}
// crossfade section runs regardless
```

---

## ISSUE 6 — WRONG: interpFloatTrack12 `else return` skips crossfade for unknown modes

**Assembly**: Same pattern as Issue 5 — unknown modes skip primary interp but fall through to crossfade.

**REF** (line 766): `} else return;` — same bug as Issue 5.

**Fix**: Same as Issue 5 — replace `else return` with `else {}`.

---

## Sections verified CORRECT

The following sections were compared instruction-by-instruction and match:

1. **Entry checks** (0x714260-0x714280): model_data_ptr null check, sync_value comparison ✅
2. **Emitter setup** (0x714286-0x7142C7): emitter_ctx flag logic, field copy ✅
3. **World position/scale** (0x7142C7-0x71434C): pos*scale, offset+field, render_scale_z ✅
4. **Global sequence loop** (0x714352-0x714389): unsigned modulo, gs_values write ✅
5. **MatMul call** (0x71438C-0x7143A0): 0x74A7C0(this+0xFC, this+0xBC, mat1) ✅
6. **child_padding len_sq** (0x7143A0-0x7143EE): emitter_ctx re-read, bit test, sqmag ✅
7. **Identity matrices** (0x7143EE-0x714503): both 16-float identity blocks ✅
8. **Timestamp delta** (0x714503-0x71451C): this+0x4C guard, delta, writeback ✅
9. **Bone loop parent inherit** (0x714650-0x7146B2): parent_idx bounds, bone_idx==0 fallback ✅
10. **Secondary slot inherit** (0x7147C5-0x714820): parent/bone0/self-primary paths ✅
11. **Blend weight computation** (0x714820-0x71492D): Hermite smoothstep, clamping to 0/1 ✅
12. **Parent matrix / billboard pre-processing** (0x71492D-0x714D0F): flag dispatch, normalize, scale preservation ✅
13. **Billboard types 2/4/6** (0x714A6E-0x714C8C): spherical/cylindrical/full camera copy ✅
14. **Translation re-computation** (0x714CAF-0x714D0C): pos - rot*pivot ✅
15. **Rotation/scale/translation interpolation** (0x714D0F-0x7151BA): interpAnimKF, interpVec3Track, matMul ✅
16. **Non-animated copyMat4** (0x7151C4-0x7151F7): 8×MOVSD equivalent ✅
17. **Billboard post-processing types 0x08/0x10/0x20/0x40** (0x7151F9-0x715868): all cross product signs verified ✅
18. **Post-billboard scale/translate** (0x715868-0x71594E): scale_len * normalized, pos - scaled*pivot ✅
19. **Bone loop increment** (0x71594E-0x715966): bone_count comparison, re-read ✅
20. **texAnimLoop** (0x715966-0x715C87): Vec3 track + alpha short-value interp + crossfade ✅
21. **colorAnimLoop** (0x715C87-0x715E46): model_hdr+0x64 count/gate, short interp + crossfade ✅
22. **wordAnimLoop** (0x715E46-0x715F25): word copy + crossfade skip for mode 0 ✅
23. **boneKeyframeLoop** (0x715F25-0x7163BC): global init, rot/scale/trans with 0xCF043C ✅
24. **ribbonEmitterLoop** (0x7163BC-0x716AD9): visibility byte, vec3/float tracks, post-processing ✅
25. **particleEmitterLoop 0x124** (0x716AD9-0x71763E): bone_rt_base (bone 0) usage, Vec3Track36/FloatTrack12 ✅
26. **Section 0x134 particles** (0x71763E-0x717D6A): all sub-tracks, strides 0xDC/0xD0 ✅
27. **additional_remaining reset** (0x717D6F): `this+0x3D8 = 0` between 0x134/0x13C sections ✅
28. **Section 0x13C particles** (0x717D75-0x7185E3): visibility, emitter_active, 10 sub-tracks, getInterpolatedFloat ✅
29. **Attachment byte animation loop** (0x7185E3-0x718657): data stride 0x30, output stride 0x20, extractByte call ✅
30. **Child traversal** (0x718657-0x718775): linked list, visibility check, matrix copy, offset translation, recursive call ✅
31. **Sync update** (0x718775-0x718784): `this+0x40 = anim_ctx+0x10` ✅
32. **Buffer sizes**: All particle output strides verified against maximum write offsets — no overflow ✅
33. **Hermite/Bezier basis**: h1-h4 and b0-b3 formulas match standard Bernstein/Hermite polynomials ✅
34. **Calling conventions**: All game function calls (0x713D50, 0x713EA0, 0x71AE90, 0x71AF20, 0x71AFF0, 0x71B010, 0x74A7C0, 0x74B6B5, 0x7BDC40, 0x7BDCA0, 0x7BDDB0, 0x7B5F60, 0x4549F0, 0x40A2B0, 0x409AEF, 0x714260) parameter order verified ✅
35. **Constants**: 0x7FFD74 = 0.0f, 0x7FF9D8 = 1.0f, 0x80297C = 3.0f, 0x802990 = 6.0f (runtime), 0x811610 = short-to-float (runtime), 0x8029D4 = billboard epsilon (runtime) — all verified ✅

---

## Priority

1. **ISSUE 1 + 2** (CRASH): Fix immediately — this is almost certainly the extractByte crash cause
2. **ISSUE 5 + 6** (WRONG): Fix next — affects crossfade correctness for edge-case modes
3. **ISSUE 3 + 4** (WRONG): Fix last — rare edge case, modulo likely prevents crash
