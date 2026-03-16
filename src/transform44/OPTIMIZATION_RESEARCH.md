# Bone Transform Optimization Research
## `transformImpl_SSE` in `bone_sse.zig`

**Date:** 2026-03-16
**Baseline:** ~3700 cycles / call, 18-bone model, full section functions
**Constraint summary:** x86-32, SSE4.1+FMA, 8 XMM registers, byte-identical output required, game data layout is fixed

---

## 1. Executive Summary

After exhausting per-instruction micro-optimizations (FMA, V4 matmul, register allocation, inlining), the remaining gains must come from **reducing total work**, not making existing work cheaper. Three structural changes have real potential:

1. **Early-out on static bones** — skip ~30-60% of the bone loop body when `nTimestamps == 0` for all three tracks.
2. **findInterpIdx call deduplication** — the function is called ~30 times per invocation, many with identical `(this, prim_time, prim_track, anim_data)` inputs. Deduplicate by caching the result per `(search_value, anim_data)` tuple.
3. **SoA quaternion batching** — process 4 bones simultaneously through quaternion→matrix using vertical SIMD (one component per XMM lane). Eliminates the primary bottleneck in the rotation path.

The other commonly-cited ideas (dirty flags, ACL-style uniform keyframe arrays) do not apply here without violating constraints.

---

## 2. Code Structure Analysis

### 2.1 Per-bone work breakdown (hot path, bone with full animation)

Each animated bone in Section 7 executes:

| Step | Work | Approx. cycles |
|------|------|---------------|
| Anim slot time computation (primary) | conditional ftol, modulo | ~20-40 |
| Anim slot time computation (secondary) | same | ~20-40 |
| Blend weight Hermite | multiply, clamp, polynomial | ~15 |
| findInterpIdx (rotation) | forward scan + t compute | ~30-60 |
| interpAnimKF (rotation) | 4-wide lerp + optional crossfade | ~40-80 |
| buildRotationMatrix / rotateByQuaternion | 9 multiply, 9 FMA, 3 stores | ~35-50 |
| findInterpIdx (scale) | same as rotation | ~30-60 |
| interpVec3Track (scale) | 3-wide lerp + optional crossfade | ~25-40 |
| scaleMatrix3x3 | 9 loads, 9 mul, 9 stores | ~30 |
| findInterpIdx (translation) | same | ~30-60 |
| interpVec3Track (translation) | 3-wide lerp + optional crossfade | ~25-40 |
| applyTranslation / pivot math | 3 dot products | ~20 |
| matMul4x4 (bone_local * parent) | 4×(1 mul + 3 FMA) = 16 SIMD ops | ~40-60 |

**Total per animated bone: ~350-600 cycles** (variance driven by crossfade, billboard, temporal cache miss).

For 18 bones at ~450 cycles average: ~8100 cycles in the bone loop alone. The quoted 3700 cycles total suggests many bones hit early-outs (`rot_kf_count == 0` or `flags & 0x280 == 0`).

### 2.2 findInterpIdx call frequency

Per invocation, `findInterpIdx` is called:
- Bone loop: up to **3 calls per bone × 2 (crossfade)** = 6/bone × 18 bones = ~108 potential calls (most gated, realistically ~30-50 active)
- texAnimLoop: 1-2 per tex entry
- colorAnimLoop: 1-2 per color entry
- wordAnimLoop: 1-2 per word entry
- boneKeyframeLoop: 1-3 per kf entry
- ribbonEmitterLoop: 4-8 per ribbon
- particleEmitterLoop: 3 per particle
- additionalParticleLoops: 6-10 per emitter

Each call does: 1-4 reads to determine range, 1 branch on delta, 1-8 reads for forward scan (typical case), 2 reads + 1 fdiv for t computation. On a temporal-coherent forward scan, this is ~30-40 cycles. On a binary search (cold): ~60-100 cycles.

**This function is the single most-called leaf in the entire engine.**

### 2.3 Post-bone-loop section cost

Texture/color/word animation loops are typically small (1-4 entries), cheap. The large cost is in `additionalParticleLoops` section 12e, which calls `interpFloatTrack` 10 times per particle emitter. On a model with 2 particle emitters, that is 20 more `findInterpIdx` calls.

### 2.4 Billboard path

The billboard post-processing path (`combined_flags & 0x78`) calls `normalizeVec3InPlace` 2-3 times per billboard bone, each involving `callVec3SqMag` + `@sqrt` + `1/x` + 3 multiplies. `@sqrt` on x87/SSE is 10-20 cycles. On a model with 0-2 billboard bones this is minor.

---

## 3. Research Findings

### 3.1 SoA / Vertical SIMD for Bone Transforms

**Reference:** ozz-animation (https://guillaumeblanc.github.io/ozz-animation/), Arseny Kapoulkine / zeux.io slerp batch work.

The canonical modern approach is **vertical SIMD**: pack the same component from 4 different bones into one XMM register, then process 4 bones per SIMD instruction.

For `SoaFloat4` quaternion layout:
```
xmm0 = [q0.x, q1.x, q2.x, q3.x]
xmm1 = [q0.y, q1.y, q2.y, q3.y]
xmm2 = [q0.z, q1.z, q2.z, q3.z]
xmm3 = [q0.w, q1.w, q2.w, q3.w]
```

ozz-animation's `SamplingJob` processes **4 bones per SIMD iteration** through lerp/nlerp. Its `SimdFloat4` is `__m128` (exactly SSE). The SSE2 implementation processes 4 quaternions in the same register count that scalar processes 1, giving roughly **3-4x throughput for the interpolation step** alone.

**Applicability here:** The constraint is x86-32 with 8 XMM registers. A 4-bone vertical SIMD pass uses:
- 4 XMM registers for quaternion components (x, y, z, w)
- 4 XMM registers for computation scratch

That fits exactly in 8 registers with zero spilling — but only if no other live values need registers at the same time. The complication is that each bone's quaternion comes from a different address (bone_rt[i] + BR.rot_x), so the gather phase (4 scalar loads → shuffle into 4 XMM registers) costs ~12-16 cycles. On x86-32 without AVX, there's no VGATHERDPS, so this is manual.

**The more realistic gain here:** Use vertical SIMD for the `buildRotationMatrix` step applied to 4 bones simultaneously. After gathering 4 quaternions, the 9-product rotation matrix computation on 4 bones simultaneously costs ~40 cycles vs ~160 cycles scalar (4×40). Net gain: ~120 cycles per 4-bone group = ~30 cycles/bone on average.

### 3.2 SoA Layout for Bone Data (Input Format)

ozz-animation stores bone transforms in SoA layout — all translations.x together, then all translations.y, etc. This is optimal for interpolation because lerp on 4 bones reads 4 consecutive floats per component.

**Not applicable here:** The game's `BR` (bone runtime) struct is 0x118 bytes per bone, AoS. We cannot change this layout — the game engine reads and writes it directly. The bone output matrices at `bone_out_base + bone_idx * 0x40` are also fixed game memory.

However, a **local SoA staging buffer** is feasible: gather 4 bones' quaternion components into 4 XMM registers, process them in vertical SIMD, then scatter the 4 output matrices. The gather/scatter overhead (~24-32 cycles) must be less than the SIMD speedup (~120 cycles saved). Net: +88-96 cycles saved per 4-bone group, assuming no bank conflicts.

### 3.3 Early-Out on Non-Animated Bones

**Reference:** GameDev.net "Skeletal Animation Optimization Tips and Tricks"

When `rot_kf_count == 0 AND scale_kf_count == 0 AND trans_kf_count == 0`:
- The bone loop body reduces to: check flags, copy parent matrix (`copyMat4`).
- The existing code already gates each interpolation step behind its count check.
- However, the **anim slot time computation** (Section 7, primary + secondary slot logic) runs regardless of kf counts.

For non-animated bones where `anim_slot_val == -1` (inherit from parent) AND `flags & 0x280 == 0` (no rotation animation) AND no billboard flags, the only output is `copyMat4(bone_out_base + bone_idx * 0x40, src_mat)`.

**The current code already has the right gates** — `frame_ctr < kf_count` before each interp call. But the anim slot time computation (roughly 60-80 cycles of conditionals and arithmetic) runs even when none of the resulting prim_time/prim_track values will ever be used by this bone's interpolation. The gate on `anim_slot_val == -1` handles the inheritance path cheaply, so the cost only hits bones with their own slot.

**Real saving:** On models where many bones are unanimated (common for static attachments or simple effect models), adding an explicit early path:
```
if (flags & 0x280 == 0 and combined_flags & 0x78 == 0
    and trans_kf_count == 0 and scale_kf_count == 0) {
    copyMat4(bone_out_base + bone_idx * 0x40, src_mat);
    continue;
}
```
avoids the entire anim slot time block. This already nearly happens implicitly because `anim_slot_val == -1` for inherited bones skips the expensive looping/clamping logic. The remaining overhead for inherited-slot, no-animation bones is: 2 parent copies (fast), 1 blend weight inherit (fast), 1 `copyMat4`. This is already ~20-30 cycles — close to optimal.

**Actual target for early-out:** Bones where `anim_slot_val != -1` but all kf counts are 0 (rare — Blizzard doesn't typically store empty animation slots). Estimated savings: negligible in practice for WoW models.

### 3.4 findInterpIdx Call Deduplication / Caching

This is the highest-ROI structural change that stays within constraints.

**Current behavior:**
- Each call to `interpVec3Track`, `interpAnimKF`, `interpFloatTrack` calls `findInterpIdx` with `(this, bone_rt.prim_time, bone_rt.prim_track, anim_data, output)`.
- For a given bone with translation + rotation + scale tracks, all three call `findInterpIdx` with the **same `prim_time` and `prim_track`** but different `anim_data`.
- The `anim_data` structs have different `keyframe_ranges` pointers but often the same `time_index` (global sequence index). When `time_index == -1` (most bones), the `search` value = `prim_time` for all three.

**Key insight:** Two tracks on the same bone in the same animation will almost always have the same timestamp array (they share the same animation range). In practice, rotation and translation tracks of the same bone have the **same keyframe count and the same timestamps**. If so, the three `findInterpIdx` calls produce the same `(idx0, idx1, t)` result.

**Proposed fix:** Before the rotation/scale/translation interpolation block, compute `findInterpIdx` once into a local `bone_interp_cache: [3]u32` (indices + t), then pass the cached result directly to each interpolation kernel, skipping the search entirely. The interpolation kernels already store their results into `brt + BR.rot_idx0` etc., so the cache must write those output slots.

To implement cleanly: refactor `interpAnimKF` and `interpVec3Track` to accept a pre-computed `(idx0, idx1, t)` triple as an optional override. When anim_data for rotation and translation share the same `keyframe_ranges` pointer (checkable in O(1): `ru32(rot_anim + AD.keyframe_ranges) == ru32(trans_anim + AD.keyframe_ranges)`), skip the redundant searches.

**Estimated saving:** If 2 out of 3 findInterpIdx calls per bone are eliminated, and each costs ~35 cycles, that is **~70 cycles saved per bone**. For 18 bones: ~1260 cycles. This alone could reduce total time by ~30%.

**Risk:** This requires verifying that all three tracks of a bone truly share the same timestamp array in vanilla M2 format. From the M2CompBone structure (3×OldAnimationBlock, one per track), each track has its own `timestamps_ptr` and `keyframe_ranges`. They can differ. The safe version checks equality before skipping. The M2 format wiki notes that all three tracks belong to the same per-animation data, so in practice they share ranges — but must be validated before trusting.

### 3.5 ACL-Style Uniform Sampling (O(1) Seek)

**Reference:** Nicholas Frechette's Animation Compression Library (https://github.com/nfrechette/acl)

ACL stores keyframes at uniform intervals, making seek trivially `floor(t / frame_rate)` — a multiply and truncate, no search at all. This eliminates `findInterpIdx` entirely.

**Not applicable here:** The M2 format stores variable-interval timestamps, controlled by the game's content pipeline. We cannot change the on-disk data format. The `findInterpIdx` temporal coherence cache is the best we can do with variable timestamps.

The only partial applicability: if we could detect at load time that a given track has uniform timestamps, we could use the O(1) path. But "load time" doesn't exist for a runtime hook, and we cannot modify the game's asset files.

### 3.6 Animation Compression / Quaternion Quantization

**Reference:** nfrechette.github.io animation compression series, Riot Games (https://technology.riotgames.com/news/compressing-skeletal-animation-data)

Standard techniques: drop the largest quaternion component, store remaining 3 as 16-bit fixed-point. ACL uses 11-11-10 bit packing. Decompression is fast (integer unpack + float multiply + sqrt for dropped component).

**Not applicable:** The game uses its own quaternion storage — verified from assembly that `interpAnimKF` reads full 32-bit float quaternions at stride 16 bytes (`SHL EAX, 4`). The M2 format does support compressed quaternions in later versions but not in v256 (vanilla). Changing the runtime storage would require patching M2 load code, which is out of scope.

The existing `getShortToFloat()` path (used in texture/color animations for alpha values) shows the game already uses 16-bit shorts for scalar tracks — this is the M2 format's own compression, not something we can expand.

### 3.7 Dirty Flags / Skip Unchanged Bones

**Reference:** GameDev.net optimization tips, Unreal Engine animation system.

"If a bone's input (parent matrix, prim_time, prim_track) hasn't changed since last frame, skip it and reuse the previous output matrix."

**Not applicable here for two reasons:**

1. The output matrices (`bone_out_base`) are game memory read by the renderer every frame. The sync_value guard at the start (`if ru32(this + SO.sync_value) == ru32(anim_ctx + 0x10)) return`) already handles the global case. Per-bone skipping would require storing per-bone dirty state in an additional array we'd have to allocate, not in the fixed-layout `BR` struct.

2. Even if we could store dirty state, computing whether inputs changed (comparing parent matrix, prim_time, prim_track) costs ~15-20 cycles per bone — similar to just doing the `copyMat4` fast path. The payoff only materializes when we can skip expensive interpolation work, and that's already gated by `frame_ctr < kf_count`.

### 3.8 Quaternion NLERP vs LERP vs SLERP

**Reference:** zeux.io "Optimizing slerp" (https://zeux.io/2016/05/05/optimizing-slerp/)

The game uses raw 4-component linear lerp for quaternions (`interpAnimKF`: `@mulAdd(f32, b - a, t, a)` for each of x,y,z,w). This is "nlerp-without-renormalization" — the game never normalizes the interpolated quaternion before `buildRotationMatrix`.

The `buildRotationMatrix` formula is mathematically correct for unit quaternions but does not enforce unit length. The original game code has the same behavior. We have matched it exactly.

Switching to nlerp (normalize after lerp) would change output values and break parity. Switching to slerp would be more expensive and also break parity. This path is closed.

### 3.9 Batch Processing of Post-Bone-Loop Sections

The `texAnimLoop`, `colorAnimLoop`, `wordAnimLoop` sections each iterate over small counts (typically 1-4 entries) and make 1-2 `findInterpIdx` calls each. All use `bone_rt_base` (bone 0) for timing, not per-entry bone_rt. This means they all share the same `(prim_time, prim_track)` input.

**Proposed fix:** Compute the timing result for bone_rt_base once before all post-bone-loop sections:
```zig
// Before texAnimLoop / colorAnimLoop / wordAnimLoop:
var shared_idx0: u32 = undefined;
var shared_idx1: u32 = undefined;
var shared_t: f32 = undefined;
// ... call findInterpIdx once with a representative anim_data that has no global sequence
// pass cached result to all calls that share (prim_time, prim_track) and time_index == -1
```

This is simpler than the per-bone deduplication because all these sections use the same bone_rt. However, each loop entry still has its own `anim_data` with potentially different `keyframe_count` and `keyframe_ranges`, so the range selection in `findInterpIdx` still varies per entry. The savings are in the **search phase only** (forward scan / binary search), not in the range lookup.

Estimated saving: small (5-10 calls × ~15-20 cycles saved = ~100-200 cycles). Not a priority.

---

## 4. Proposed Changes with Estimated Impact

### Proposal A: findInterpIdx Deduplication Within Bone Loop

**Mechanism:** For each bone with `flags & 0x280 != 0` (animated), check if rotation and translation share the same `keyframe_ranges` pointer. If so, call `findInterpIdx` once and pass the result to both `interpAnimKF` and `interpVec3Track` for the translation track.

For rotation + scale, the check is similar. In practice all three tracks of a vanilla M2 bone share the same `keyframe_ranges` because they're stored sequentially in the same animation record.

**Implementation:** Add a `BoneInterpResult` struct `{idx0, idx1, t: f32}`. Modify `interpAnimKF` and `interpVec3Track` to accept an optional pre-computed result parameter (Zig: `?BoneInterpResult`). The call becomes:
```zig
const cached = if (rot_kf_count != 0 and frame_ctr < rot_kf_count) blk: {
    // findInterpIdx writes result directly to brt + BR.rot_idx0
    findInterpIdx(this, ru32(brt + BR.prim_time), ru32(brt + BR.prim_track), rot_anim, brt + BR.rot_idx0);
    break :blk BoneInterpResult{
        .idx0 = ru32(brt + BR.rot_idx0),
        .idx1 = ru32(brt + BR.rot_idx1),
        .t    = ufloat(ru32(brt + BR.rot_t)),
    };
} else null;

// For translation, check if timestamps match
const can_reuse = cached != null and
    ru32(rot_anim + AD.timestamps_ptr) == ru32(trans_anim + AD.timestamps_ptr);
```

The reuse is only valid when `time_index == -1` (both tracks are using `prim_time` not global sequence). This covers the vast majority of bones.

**Estimated saving:** 1-2 findInterpIdx calls eliminated per animated bone. At ~35 cycles each × ~12 animated bones (rough WoW model typical): **~420-840 cycles saved** (~11-23% of 3700 cycle baseline).

**Complexity:** Low-medium. Requires refactoring 3 function signatures.

**Risk:** Low. Guarded by pointer comparison, falls back to full search if timestamps differ.

**Parity:** Full — same results, just reusing already-computed indices.

---

### Proposal B: 4-Bone Vertical SIMD for Quaternion → Matrix

**Mechanism:** Instead of processing bones one at a time through `buildRotationMatrix`, buffer groups of 4 bones' quaternions in local variables, then use vertical SIMD to compute all four 3×3 rotation matrices simultaneously.

The per-bone quaternion→matrix kernel (`buildRotationMatrix`) computes 9 products and 6 additions. With 4 bones in vertical layout:
```
xmm_qx = {b0.qx, b1.qx, b2.qx, b3.qx}
xmm_qy = {b0.qy, b1.qy, b2.qy, b3.qy}
xmm_qz = {b0.qz, b1.qz, b2.qz, b3.qz}
xmm_qw = {b0.qw, b1.qw, b2.qw, b3.qw}
```
Then `xx2 = qx * (qx + qx)` becomes a V4 multiply operating on all 4 bones at once. All 9 terms of the rotation matrix are computed for 4 bones in the same time it currently takes for 1 bone.

**Critical constraint:** x86-32 has 8 XMM registers. The quaternion→matrix computation requires:
- 4 input registers (qx, qy, qz, qw)
- ~4 intermediate term registers minimum

This is right at the limit. LLVM will need to spill 2-3 values to stack at some point during the 9-term computation. At ~2-3 cycles per spill/reload, total spill cost for 4-wide = ~6-9 cycles vs saving ~3×35 cycles. Still net positive, but the register pressure must be carefully managed.

The scatter phase (writing 4 separate output matrices from vector results) requires 4 × 9 stores = 36 stores, same as scalar. But with shuffles, this can be done with fewer instructions using `_mm_shuffle_ps` to extract individual lanes.

**Implementation approach:** Restructure the bone loop to process bones in groups of 4:
```zig
var g: u32 = 0;
while (g + 4 <= bone_count) : (g += 4) {
    // Gather 4 quaternions
    // Batch vertical SIMD rotation matrix computation
    // Scatter to 4 output matrices
    // Handle scale/translation scalar (or also batch)
}
// Handle remainder (< 4 bones) with existing scalar path
```

**Estimated saving:** The SIMD path costs ~50-60 cycles for 4 bones vs ~140-160 cycles scalar. Saving: **~90-100 cycles per 4-bone group**. For 18 bones: ~4 groups × 95 = **~380 cycles** (~10% of baseline).

**Complexity:** High. Requires restructuring the bone loop, handling all the branch cases (billboard, crossfade, different flag combinations) that vary per-bone. Many bones have different flags, making the 4-wide path only applicable when all 4 bones have the same code path.

**Risk:** High. The billboard handling, flag-per-bone variability, and crossfade paths mean most groups of 4 bones will have at least one that diverges. A "peeling" strategy (check if 4 consecutive bones are all non-billboard, same flag class) reduces but does not eliminate this risk.

**Realistic estimate after flag divergence:** Only ~50% of bone groups will be eligible for the 4-wide path. Effective saving: ~5% of baseline.

**Recommendation:** Proposal B is complex and yields modest gains in practice for WoW models due to per-bone flag diversity. Do Proposal A first.

---

### Proposal C: Hoist Crossfade Guard

**Mechanism:** The crossfade check (`blend_weight != 0.0 and time_index == -1`) appears identically inside `interpAnimKF`, `interpVec3Track`, `interpFloatTrack`, and the post-bone-loop sections. When `blend_weight == 0.0` (the common case — crossfade only happens during animation transitions), the check fails immediately and the secondary `findInterpIdx` is never called.

However, the check **reads from memory** each time: `rf32(bone_rt + BR.blend_weight)`. LLVM should CSE this within a single inlined call but not across multiple calls (different addresses).

**Current behavior:** `blend_weight` is read from `brt + BR.blend_weight` once per `interpXxxTrack` call. With 3 calls per bone, it is read 3 times from the same address.

**Fix:** Read `blend_weight` once before the rotation/scale/translation block and pass it through. The code already does this for `interpVec3Track` via the parameter, but `interpAnimKF` reads it internally (`rf32(bone_rt + BR.blend_weight)`). Make `interpAnimKF` also accept an explicit `blend_weight` parameter.

**Estimated saving:** ~3 memory reads eliminated per animated bone → ~3 cycles × 12 animated bones = **~36 cycles** (negligible). Already partially done.

**Recommendation:** Do this as a cleanup, not a performance target.

---

### Proposal D: Remove getShortToFloat() / getBillboardEpsilon() Per-Call Overhead

**Mechanism:** `getShortToFloat()` reads from address `0x00811610` every call. It is called inside `shortInterpToFloat`, which is called inside `colorAnimLoop` and `texAnimLoop` for every keyframe lookup — potentially 3 times per call (`v0 * getShortToFloat()`, `v1 * getShortToFloat()`, and `primary` assignment).

Similarly `getBillboardEpsilon()` reads `0x008029d4` on every `normalizeVec3` call.

These are hot absolute addresses; they'll be in L1 cache after the first read, so the actual penalty is ~4 cycles per call rather than a cache miss. But they prevent constant propagation.

**Fix:** Read both values once at function entry and thread them through as parameters. Or use `comptime`-unreachable-but-runtime-constant pattern: read once per `transformImpl_SSE` call into a local `const short_to_float = getShortToFloat()`.

**Estimated saving:** Minimal (~20-40 cycles total across all calls). More valuable for code clarity and allowing LLVM to hoist the loads.

---

### Proposal E: Eliminate anim_slot_val == -1 Redundant Parent Reads

**Mechanism:** When `anim_slot_val == -1` and `parent_idx_raw >= 0`, the code reads `parent_rt + BR.prim_time/prim_track/prim_anim` and writes them to `brt`. The same is done for the secondary slot. These are consecutive reads from `bone_rt_base + parent * 0x118 + offset`.

For deeply inherited chains (Root → Torso → Spine → Neck → Head), each bone copies from the previous. The values propagate down one by one. After the first non-inherited bone, all descendants get the same `prim_time/prim_track` value.

**Fix:** Track the "current inherited time" as a local variable:
```zig
var inherited_prim_time: u32 = ru32(bone_rt_base + BR.prim_time);
var inherited_prim_track: u32 = ru32(bone_rt_base + BR.prim_track);
```
Update it when a bone has its own slot; otherwise use the local variable directly. Eliminates the parent read + write for all inherited bones.

**Estimated saving:** ~4-6 memory operations per inherited bone × 12-15 inherited bones = ~48-90 cycles. Minor.

---

## 5. Priority Order and Estimated Total Impact

| Proposal | Estimated Cycles Saved | Complexity | Risk |
|----------|----------------------|------------|------|
| A: findInterpIdx deduplication | 420–840 | Medium | Low |
| B: 4-wide SIMD quaternion batching | 150–380 (flag-divergent) | High | Medium |
| D: Hoist runtime constant reads | 20–40 | Low | None |
| E: Inherited slot local var | 50–90 | Low | None |
| C: Crossfade guard hoist | 30–50 | Low | None |

**Combined realistic saving:** Proposals A + D + E + C = **520–1020 cycles** off 3700 baseline = **14–28% reduction**.

To reach a hypothetical ~2700 cycles (target), Proposal B would also need to work cleanly, and only for models with many non-billboard bones in runs of 4+.

---

## 6. What Does NOT Apply Here

**SoA input data layout:** Requires changing the game's `BR` struct layout (0x118 bytes, AoS). Fixed by game code. Cannot change.

**ACL/uniform sampling O(1) seek:** Requires reformatting the M2 keyframe timestamp arrays. Fixed by game content. Cannot change.

**Multithreaded bone processing:** The function is called per-model per-frame from the game's render thread. The game engine has no worker thread pool we can dispatch to.

**GPU compute skinning:** We are inside the CPU animation preprocessing step that feeds the renderer's bone matrix array. The renderer then does vertex skinning on the GPU. The CPU step is sequential by design.

**Dirty flag per-bone skipping:** Would require allocating external state per bone, and the sync_value guard already handles the inter-frame case globally.

---

## 7. Implementation Plan for Proposal A

### Step 1: Verify timestamp sharing in M2 v256

Instrument the existing code to log, per bone, whether `ru32(rot_anim + AD.timestamps_ptr) == ru32(trans_anim + AD.timestamps_ptr)` and the same for scale. Run on a sample model. Expect near-100% match.

### Step 2: Add BoneInterpResult type

```zig
const BoneInterpResult = struct {
    idx0: u32,
    idx1: u32,
    t: f32,
};
```

### Step 3: Modify interpAnimKF to return its result

Currently `interpAnimKF` writes indices + t to `output` (which is `brt + BR.rot_idx0`). Add an optional override:

```zig
inline fn interpAnimKFWithCache(
    this: u32, bone_rt: u32, anim_data: u32, output: u32,
    cached: ?BoneInterpResult
) void {
    if (cached) |c| {
        wu32(output, c.idx0);
        wu32(output + 4, c.idx1);
        wu32(output + 8, fbits(c.t));
    } else {
        findInterpIdx(this, ru32(bone_rt + BR.prim_time), ru32(bone_rt + BR.prim_track), anim_data, output);
    }
    // ... rest of interpolation unchanged
}
```

### Step 4: In bone loop, compute cache on first track, reuse on subsequent

```zig
// Rotation (first — always finds)
if (rot_kf_count != 0 and frame_ctr < rot_kf_count) {
    interpAnimKFWithCache(this, brt, rot_anim, brt + BR.rot_idx0, null);
}
const rot_cached: ?BoneInterpResult = if (rot_kf_count != 0) .{
    .idx0 = ru32(brt + BR.rot_idx0),
    .idx1 = ru32(brt + BR.rot_idx1),
    .t    = ufloat(ru32(brt + BR.rot_t)),
} else null;

// Scale (reuse if timestamps match)
const scale_can_reuse = rot_cached != null and
    ri16(rot_anim + AD.time_index) == -1 and
    ri16(scale_anim + AD.time_index) == -1 and
    ru32(rot_anim + AD.timestamps_ptr) == ru32(scale_anim + AD.timestamps_ptr);
if (scale_kf_count != 0 and frame_ctr < scale_kf_count) {
    interpVec3TrackWithCache(this, brt, scale_anim, brt + BR.scale_idx0,
        ufloat(ru32(brt + BR.blend_weight)),
        if (scale_can_reuse) rot_cached else null);
}

// Translation (same check)
```

### Step 5: Measure with existing cycle counter infrastructure

Use the perf measurement setup already in place (see `cycles.out`). Compare before/after on the same model. Target: 14-28% cycle reduction.

---

## 8. Key References

- ozz-animation SoA documentation: https://guillaumeblanc.github.io/ozz-animation/documentation/animation_runtime/
- ozz-animation sampling_job.cc (vertical 4-wide SIMD): https://github.com/guillaumeblanc/ozz-animation/blob/master/src/animation/runtime/sampling_job.cc
- Arseny Kapoulkine, "Optimizing slerp": https://zeux.io/2016/05/05/optimizing-slerp/ — demonstrates 2.5-3x SSE2 speedup for 4-wide quaternion batch
- Animation Compression Library (ACL), uniform sampling design: https://github.com/nfrechette/acl
- nfrechette blog, animation compression: https://nfrechette.github.io/
- GameDev.net, "Skeletal Animation Optimization Tips and Tricks": https://www.gamedev.net/tutorials/programming/graphics/skeletal-animation-optimization-tips-and-tricks-r3988/
- J.M.P. van Waveren, "From Quaternion to Matrix and Back" (SSE quat batch): https://mrelusive.com/publications/papers/SIMD-From-Quaternion-to-Matrix-and-Back.pdf
- Riot Games, animation compression: https://technology.riotgames.com/news/compressing-skeletal-animation-data
- M2 file format (wowdev wiki): https://wowdev.wiki/M2
