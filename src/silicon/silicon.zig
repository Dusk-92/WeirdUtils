//! silicon -- SSE2 math replacements for WoW 1.12.1 x87 FPU code
//!
//! Ported from libSiliconPatch240.dll (turtle silicon patch).
//! Each function replaces an x87 FPU implementation with SSE2 equivalent.
//! Addresses verified via Ghidra analysis of both WoW.exe and libSiliconPatch.
//!
//! This module is a catalog of all functions that silicon hooks. Functions
//! are organized by category. Each entry includes the WoW.exe address,
//! silicon's hook name, whether silicon has an SSE2 replacement (vs just
//! an x87 rewrite), and implementation status.
//!
//! To implement: decompile the WoW.exe function via ghidra-cli skill,
//! verify calling convention from prologue/epilogue, write SSE2 replacement.

const std = @import("std");
const hook = @import("zhook");
const logging = @import("../logging.zig");
const mod_mutex = @import("../mutex.zig");

pub const module_name: [*:0]const u8 = "silicon";

var g_mutex: ?*anyopaque = null;
var g_is_hook_owner: bool = false;
var log_state: logging.Logger = .{};

// =============================================================================
// Category 1: Low-level scalar math (ftol, sincos, facing)
// =============================================================================

// 0x749280: calculateSinCos
//   Silicon: does not hook directly, uses SSE internally
//   Status: stub

// 0x40CF81: ftol (float-to-long truncation)
//   Silicon: hook_ftol -- replaces x87 FISTP with SSE2 CVTTSS2SI
//   Status: stub

// 0x4183D0: WritePointerToStream
//   __thiscall(this_ECX, pointer_stack), RET 0x4
//   Writes 4-byte pointer into stream buffer. Bounds-checks write position (this+0x10),
//   calls virtual resize if needed, stores and advances cursor by 4. Not pure math.
//   Silicon: hook_sub_4183D0
//   Status: stub

// =============================================================================
// Category 2: Vector operations (C3Vector, C2Vector)
// =============================================================================

// 0x4549C0: normalizeVector3
//   __thiscall(Vec3* ECX, float length_stack), RET 0x4
//   Divides each Vec3 component by pre-computed length: scale = 1.0/length, xyz *= scale
//   Pure x87 scalar (FLD/FDIV/FMUL/FSTP) — trivial SSE2 candidate
//   Silicon: hook_sub_4549C0, sub_4549F0_sse2
//   Status: stub

// 0x602630: Vector3_DotProduct
//   Silicon: not hooked (different from NTempest Dot)
//   Status: stub

// 0x686640: SetVector3
//   Silicon: hook_sub_686640, sub_686640_sse2
//   Status: stub -- we already profile this in transform44

// 0x686820: NormalizeVector3
//   Silicon: not directly hooked
//   Status: stub

// 0x6868E0: DotProductVector3
//   Silicon: not directly hooked
//   Status: stub

// 0x6720F0: NormalizeVector3_InPlace
//   Silicon: not directly hooked
//   Status: stub

// =============================================================================
// Category 3: NTempest vector/matrix operators
// Silicon hooks these as named exports with SSE2 replacements.
// =============================================================================

// NTempest::C3Vector::Dot -- hooked
// NTempest::C3Vector::Cross -- hooked
// NTempest::C3Vector::Max -- hooked
// NTempest::C3Vector::Min -- hooked
// NTempest::C3Vector::Normalize -- hooked
// NTempest::C3Vector::SquaredMag -- hooked
// NTempest::C2Vector::SquaredMag -- hooked
// NTempest::C3Vector::operator+= -- hooked
// NTempest::C3Vector::operator*=(float) -- hooked
// NTempest::operator+(C3Vector, C3Vector) -- hooked
// NTempest::operator-(C3Vector, C3Vector) -- hooked
// NTempest::operator*(C3Vector, float) -- hooked
// NTempest::operator*(C44Matrix, C3Vector) -- hooked
// NTempest::operator*(c3vector, c44matrix) -- hooked (lowercase variant)
// NTempest::operator*(C34Matrix, C34Matrix) -- hooked
// NTempest::operator*=(C3Vector, C34Matrix) -- hooked
// NTempest::operator*=(C3Vector, C44Matrix) -- hooked
// NTempest::operator+(C44Matrix, C44Matrix) -- hooked
// NTempest::operator*(C44Matrix, float) -- hooked
// NTempest::operator*(C33Matrix, float) -- hooked
// NTempest::C44Matrix::Det -- hooked
// NTempest::C44Matrix::Scale -- hooked
// NTempest::C34Matrix::Translate -- hooked
// NTempest::CAaBox::Bounding -- hooked
//
// These are all small inline-style functions. Silicon replaces x87 with SSE2.
// WoW.exe addresses need to be resolved per-function via Ghidra xref from
// silicon's hook targets. The hook names encode the WoW addresses in some
// cases via the sub_XXXXXX pattern.
//
// Status: all stubs -- need address resolution + decompilation

// =============================================================================
// Category 4: Matrix multiply variants
// =============================================================================

// 0x7BC6A0: multiplyMatrix4x4 (SSE optimized)
//   Silicon: hook_sub_7BC6A0, sub_7BC6A0 (hook_wrapper_7BC6A0)
//   Status: DONE -- already in clip_sse.zig

// 0x7BAE60: MultiplyMatrix3x4
//   __fastcall(out_ECX, matA_EDX, matB_stack), RET 0x4
//   Affine 3x4 matrix multiply: 3x3 rotation block + translation row (indices 9-11 add B's translation)
//   All x87 scalar — strong SSE candidate, regular structure, no branches
//   Silicon: hook_MatrixMultiply
//   Status: stub

// 0x7BB420: MultiplyMatrix3x4InPlace
//   Silicon: hook_MatrixMultiply (shared hook)
//   Status: stub

// 0x7BDFC0: multiplyMatrix3x3
//   __fastcall(dst_ECX, lhs_EDX, rhs_stack), RET 0x4
//   3x3 matrix multiply: dst = lhs * rhs (9 floats each). Aliasing-safe (loads all
//   before storing). All x87 scalar — strong SSE candidate.
//   Silicon: hook_sub_7BDFC0, sub_7BDFC0 (no _sse2)
//   Status: stub

// 0x7BCEF0: getTransposedMatrix4x4
//   Silicon: not directly hooked
//   Status: stub

// 0x7BDB00: createAxisAngleRotationMatrix (Rodrigues' formula)
//   __fastcall(outMatrix4x4_ECX, axisVec3_EDX, angle_stack, isNormalized_stack), RET 0x8
//   Builds 4x4 rotation matrix from axis+angle. Normalizes axis if flag==0.
//   310 bytes, bottom row = [0,0,0,1]. Returns outMatrix ptr.
//   Related: rotateMatrixByAxisAngle in clip_sse.zig calls multiplyMatrix4x4 after this
//   Silicon: hook_sub_7BDB00
//   Status: stub

// =============================================================================
// Category 5: Collision / spatial / terrain
// =============================================================================

// 0x632830: RayPolygonIntersectionTest
//   __fastcall(planes_ECX, ray_EDX, verts_stack, index_stack, maxDist_stack), RET 0xC
//   Iterates polygon planes (count at ECX+0xF0, stride 0xC), calls CalculateDistanceToPlane
//   per plane. Tracks min positive distance. Returns 1 (hit) / 0 (miss).
//   Silicon: hook_sub_632830, sub_632830_sse2
//   Status: stub

// 0x6329E0: CalculateDistanceToPlane (actually ray-plane intersection distance)
//   __fastcall(point_ECX, plane{nx,ny,nz,d}_EDX, direction_stack), RET 0x4
//   Returns (dot(point,normal)+d) / dot(direction,normal) via x87 ST(0)
//   Early-exits if ray parallel (abs(dot2) < epsilon at 0x8029d4)
//   77 bytes, pure x87 math — excellent SSE2 candidate, called in hot loop
//   Silicon: hook_sub_6329E0
//   Status: stub

// 0x632700: (already in clip_sse.zig as rayTriangleIntersection)
//   Silicon: hook_sub_632700, sub_632700_sse2
//   Status: DONE

// 0x632460: BuildTrianglePlanes (already in clip_sse.zig)
//   Silicon: hook_sub_632460
//   Status: DONE

// 0x6318C0: ClipPolygonToSinglePlane (already in clip_sse.zig)
//   Silicon: hook_sub_6318C0, sub_6318C0_sse2
//   Status: DONE

// 0x632F80: CalculateTrianglePlanesFromVertices
//   __fastcall(vertexBuffer_ECX, vertexIndices_EDX, planeNormal_stack, offsetVector_stack, outputPlanes_stack), RET 0xC
//   Builds 5 clipping planes from extruded triangle: 4 side planes + 1 cap plane.
//   636 bytes. Indexes vertices by byte values (stride 0xC), cross products, plane flipping.
//   Silicon: hook_sub_632F80, sub_632F80_sse2
//   Status: stub

// 0x6335D0: testPointTriangleCollision
//   __fastcall(triangleIndex_ECX, point_EDX), RET (no stack cleanup, 2 reg params only)
//   Tests point against 3 half-planes built from triangle data at g_collisionMeshTriangleData (0xc4e534).
//   Triangle stride 0x34. Returns 1 (inside) / 0 (outside). Epsilon at 0x80e004.
//   Silicon: hook_sub_6335D0
//   Status: stub

// 0x681B50: ProjectVerticesAndUpdateDepth
//   __fastcall(vertexBasePtr_ECX, indexArray_EDX, vertexCount_stack, worldPos_stack, ???_stack), RET 0xC
//   Transforms vertices through view-proj matrix (0xC7B700), perspective divides,
//   updates 320-column depth/occlusion buffer at 0xC7B750. Paired with FrustumCullBoundingBox.
//   Silicon: hook_sub_681B50
//   Status: stub

// 0x686C20: ClassifyPointAgainstFrustum (not GetLinkedListHead)
//   __thiscall(frustumPlanes_ECX, pointVec3_stack, outBitmask_stack), RET 0x8
//   Classifies 3D point against 6 frustum planes, produces 6-bit outcode bitmask.
//   Each bit = point behind that plane. Cohen-Sutherland style clipping.
//   Silicon: hook_sub_686C20
//   Status: stub

// 0x6856C0: ValidateGameObject (frustum cull + render setup)
//   __fastcall(objPtr_ECX, posBounds_EDX), RET (no stack cleanup)
//   Iterates linked list of WMO groups, performs IsSphereInFrustum + FrustumCullBoundingBox,
//   sets up camera-relative transforms for visible objects, registers for rendering.
//   Silicon: hook_sub_6856C0
//   Status: stub

// 0x686000: FrustumCullBoundingBox
//   __fastcall(bbox_ECX, flags_EDX, float_stack), RET 0x4
//   Transforms bbox through view-proj matrix (0xc7b700), projects to screen-space
//   column indices (320-column occlusion buffer at 0xc7b750). Returns 0 (culled) / 2 (visible).
//   Complex: transforms + loops + global state. High-value (per-object per-frame).
//   Silicon: hook_sub_686000, sub_686000_sse2 (via sub_6B8B70_sse2?)
//   Status: stub

// 0x686180: FrustumCullBoundingBox (8-corner AABB variant)
//   __fastcall(bbox_ECX, flags_EDX), RET (no stack cleanup, 2 reg params only)
//   Tests all 8 AABB corners via lookup tables (0x868628/48/68), transforms through
//   view-proj matrix (0xC7B700), perspective divides, checks 320-column occlusion buffer.
//   Returns 0 (visible) / 2 (fully occluded). Software occlusion culling (horizon buffer).
//   Silicon: hook_sub_686180
//   Status: stub

// 0x6DC5A0: CheckBoxLineIntersection
//   __fastcall(boxMin_ECX, lineStart_EDX, lineEnd_stack), RET 0x4
//   Slab-method AABB-line intersection test. Box is 6 floats (min+max at +0xC).
//   Iterates 3 axes, computes intersection t for each slab. Returns 1 (hit) / 0 (miss).
//   Silicon: hook_sub_6DC5A0
//   Status: stub

// 0x69BFF0: CMap::VectorIntersect
//   Silicon: hook_CWorldMath_VectorIntersectAABox2
//   Status: stub

// 0x50A840: CalculateOrthonormalBasis (C3Vector::BuildOrthonormalBasis)
//   __fastcall(dir_ECX, outBasis1_EDX, outBasis2_stack, outBasis3_stack), RET 0x8
//   Builds orthonormal basis from direction vector. Normalizes if needed,
//   constructs perpendicular via XY rotation or {1,0,0} fallback, cross product for third.
//   236 bytes. Calls SetErrorCode(0x57) on zero-length input.
//   Silicon: hook_C3Vector_BuildOrthonormalBasis
//   Status: stub

// =============================================================================
// Category 6: Rendering pipeline
// =============================================================================

// 0x6ABC40: processLinkedListCollision (profiled in transform44)
//   __fastcall(listHead_ECX, queryBox_EDX, resultBuf_stack, flags_stack), RET 0x8
//   Walks intrusive linked list (link at *ECX+4), per-node: checks flags at obj+0xC,
//   copies 6-dword AABB from obj+0x14C, tests overlap against queryBox, calls
//   addGeometryToBuffer on hit. 329 bytes. AABB overlap test is the SSE2 target.
//   Silicon: hook_sub_6ABC40, sub_6ABC40_sse2
//   Status: stub

// 0x6ABE60: processSpecialObjectsCollision
//   __fastcall(listHead_ECX, bounds_EDX, geomBuf_stack, flags_stack), RET 0x8
//   Linked list walk, per-node: callback via PTR_00c91f54, 6-component bbox test,
//   addObjectToGeometryBuffer on hit. 322 bytes. Same AABB pattern as 0x6ABC40.
//   Silicon: hook_sub_6ABE60, sub_6ABE60_sse2
//   Status: stub

// 0x6AD7E0: frustumCullGeometry
//   __fastcall(renderCtx_ECX, bounds_EDX, frustumPlanes_stack, ???_stack), RET 0x8
//   2D tile grid frustum culling. Builds 6-bit Cohen-Sutherland outcodes per vertex
//   against 6 frustum planes (sign-bit extraction). Tests triangles, allocates visible
//   geometry batches from global pools. 947 bytes. Same outcode pattern as 0x6B88E0/0x6B8C60.
//   Silicon: hook_sub_6AD7E0, sub_6AD7E0_sse2
//   Status: stub

// 0x6AFAD0: UpdateEntityAndChunksPositions (profiled in transform44)
//   __fastcall(entityPtr_ECX), RET (no stack cleanup, 1 reg param)
//   Height/position update (dot product against plane at 0xC7BCB0), render flag selection,
//   fade timer accumulation, 4-chunk spatial bounds registration loop. ~770 bytes.
//   SSE targets: plane dot product, center point computation from bounds.
//   Silicon: hook_sub_6AFAD0_sse2
//   Status: stub

// 0x6B7070: calculateWaterHeight
//   __fastcall(posVec3_ECX, outHeight_EDX, threshold_stack), RET 0x4
//   Water/terrain height query. Converts world pos to tile coords (origin 0x7FFAB4, scale
//   0x810D2C, 64x64 grid at 0xC96318), calls getTerrainHeightAtPoint + getFluidHeightAtPoint,
//   then collision raycast. Returns 1 (hit) / 0 (miss). Orchestrator — SSE in sub-calls.
//   Silicon: hook_sub_6B7070, sub_6B7070_sse2
//   Status: stub

// 0x6B8B70: checkBoundingBoxIntersection (SAT test, profiled in transform44)
//   __fastcall(bbox_ECX, corner1_EDX, corner2_stack, corner3_stack), RET 0x8
//   Separating axis test: for each of 3 axes, checks all 3 corners against min/max bounds
//   using sign-bit extraction (& 0x80000000). Returns 1 (separated) / 0 (intersecting).
//   Inner loop: 6 scalar float subs — vectorizable with SUBPS + sign-bit ANDPS.
//   Silicon: hook_sub_6B8B70, sub_6B8B70_sse2
//   Status: stub

// 0x6B88E0: performCollisionDetection (profiled in transform44)
//   __thiscall(this_ECX, ushort* keyData, float keySize), RET 0x8
//   653 bytes. Calls FindOrCreateHashEntry, builds 6-bit Cohen-Sutherland outcodes per vertex,
//   then iterates triangles: if (outcode[i0]&i1&i2 & 0x3f)==0, calls ray_triangle_intersection.
//   this+0x30=ray origin, this+0x48=scale, this+0x4c=best t, this+0x10=result ptr.
//   SSE targets: outcode computation (6 float cmps/vertex), AABB min/max setup.
//   Silicon: hook_sub_6B88E0, sub_6B88E0_sse2
//   Status: stub

// 0x6B8C60: PerformSpatialCulling (profiled in transform44)
//   __thiscall(this_ECX, ushort* keyData, uint keySize), RET 0x8
//   485 bytes. Same pattern as performCollisionDetection: FindOrCreateHashEntry, build
//   6-bit AABB outcodes per vertex (Cohen-Sutherland), iterate triangles checking visibility.
//   Writes visible triangles to globals at 0xce26e8 / 0xcde648. Overflow at 0x2000 entries.
//   SSE target: 6 float comparisons per vertex → vectorizable with packed SSE ops.
//   Silicon: hook_sub_6B8C60, sub_6B8C60_sse2
//   Status: stub

// 0x6BC370: SetupCylinderFrustum (BSP tree traversal for frustum culling)
//   __thiscall(this_ECX, nodeIndex_stack, param2_stack, param3_stack), RET 0xC
//   Recursive BSP traversal: leaf nodes call performCollisionDetection (0x6B88E0),
//   interior nodes split AABB along axis, recurse children with clipped bounds.
//   16-byte BSP nodes. SSE: bound splitting + 6-float AABB copies.
//   Silicon: hook_sub_6BC370, sub_6BC370_sse2
//   Status: stub

// 0x6C15D0: executeRenderCommands (terrain vertex projection)
//   __fastcall(chunkData_ECX), RET (no stack cleanup)
//   Projects terrain chunk vertices using camera-relative offsets. Selects vertex stride
//   based on +0xB8, iterates 9 vertices calling ProjectVerticesAndUpdateDepth twice.
//   Silicon: hook_sub_6C15D0
//   Status: stub

// =============================================================================
// Category 7: M2 model / bone transforms
// =============================================================================

// 0x714260: transformMatrix4x4 (profiled in transform44, bone_sse WIP)
//   Silicon: hook_sub_714260, sub_714260 (full replacement)
//   Status: WIP in bone_sse.zig

// 0x713EA0: interpKeyframe (profiled in transform44)
//   Silicon: hook_sub_713EA0, sub_713EA0 (interp replacement)
//   Status: evaluated -- hook overhead exceeds savings

// 0x71AE90: extractAnimationByteFromKeyframes
//   __fastcall(animObj_ECX, animState_EDX, animData_stack, outBuf_stack), RET 0x8
//   Looks up byte-typed keyframe value, resolves secondary track for blending when
//   blend threshold at animState+0x10C is active.
//   Silicon: hook_wrapper_71AE90, hook_sub_71AE90
//   Status: stub

// 0x71AF20: getInterpolatedFloat
//   __fastcall(sceneObj_ECX, animState_EDX, trackDef_stack, outBuf_stack), RET 0x8
//   Resolves and lerps a single float keyframe value. Mode 0 = raw keyframe,
//   else lerp(keyA, keyB, t). Secondary track blending support.
//   Silicon: hook_wrapper_71AF20, hook_sub_71AF20
//   Status: stub

// 0x71B6A0: normalizeVector3 (bone context)
//   __thiscall(this_ECX, sourceVec3_stack), RET 0x4
//   Copies Vec3 to this+0x24, computes magnitude, normalizes in-place.
//   Skips if magnitude < epsilon (0x8029D4).
//   Silicon: hook_sub_71B6A0
//   Status: stub

// 0x71BC70: addVector3ToAccumulator
//   __thiscall(this_ECX, vec3_stack), RET 0x4
//   Adds Vec3 to translation accumulator at this+0x54, also adds scaled copy
//   (global 0x81207C) into 3x3 matrix diagonal at +0x84/+0xA8/+0xCC.
//   Silicon: hook_sub_71BC70
//   Status: stub

// 0x71BF60: addToColorAccumulator
//   __thiscall(this_ECX, colorVec3_stack), RET 0x4
//   Simple Vec3 add — accumulates color/light into this+0x6C. Three float adds.
//   Silicon: hook_sub_71BF60
//   Status: stub

// 0x71C160: transformLightsAndPlanes
//   __fastcall(sceneData_ECX), RET (no stack cleanup)
//   Transforms attached light positions and clipping plane from local to world space
//   using bone's 4x4 matrix at *sceneData+0x9C. Calls transformVector3ByMatrix4x4.
//   Silicon: hook_sub_71C160
//   Status: stub

// 0x71C2F0: calculateFrustumPlanes
//   __fastcall(this_ECX), RET (no stack cleanup)
//   Computes derived frustum/view-direction from bone orientation matrix.
//   Copies direction from +0x3C to +0x78, normalizes, transforms through basis at +0x18.
//   Silicon: hook_sub_71C2F0
//   Status: stub

// 0x71C4E0: calculateSphericalHarmonics
//   __thiscall(this_ECX, outCoeffs_stack), RET 0x4
//   Computes 28 SH coefficients from 3x4 lighting matrix (this+0x84..+0xEC).
//   Order-2 SH for RGB (3x9=27 + W=1.0). Constants at 0x8120A8-0x8120C4.
//   Silicon: hook_sub_71C4E0
//   Status: stub

// 0x718960: renderSceneNode (profiled in transform44)
//   __thiscall(sceneObj_ECX), RET (no stack cleanup)
//   ~2400 bytes. Scene graph update: light attachment transforms, particle attachment
//   positioning, ribbon/emitter loop (packColor, setAlpha, rotateByAxisAngle, UpdateEmitter),
//   recursive calls on children. Hot math: 4x transformVector3ByMatrix4x4, inline 3x3 matmul.
//   Silicon: hook_sub_718960, sub_718960_sse2 (via sub_719370_sse2)
//   Status: stub

// 0x719370: updateAnimationSystem (animation event updater)
//   __thiscall(sceneObj_ECX, timeDelta_stack), RET 0x4
//   1470 bytes. Advances animation time, iterates bone chain (link via +0x114), fires scene
//   callbacks at keyframe boundaries, transforms event positions via transformVector3ByMatrix4x4
//   (bone matrix at +0x94, model-to-world at anim_context+0xDC). Recursive on children at +0x1DC.
//   Silicon: hook_sub_719370, sub_719370_sse2
//   Status: stub

// 0x712D50: GetTransformedAnimationPosition
//   __thiscall(this_ECX, outPosition_stack, animId_stack), RET 0x8
//   Resolves attachment position in world space: looks up animation index, gets bone matrix
//   (boneIdx * 0x40 + this+0x94), two transformVector3ByMatrix4x4 calls (bone→world).
//   SSE win is entirely in the two transform calls (0x7BCA80).
//   Silicon: hook_sub_712D50, sub_712D50_sse2
//   Status: stub

// 0x713680: GetBoundingSphere
//   __thiscall(this_ECX, outSphere_stack), RET 0x4
//   Reads M2 bounding box (header+0xB4, 6 floats min/max), computes center = (min+max)*0.5,
//   reads radius at header+0xCC. Writes {cx,cy,cz,r} to outSphere. Trivial SSE:
//   load min+max as packed, ADDPS, MULPS by 0.5, store.
//   Silicon: hook_sub_713680, sub_713680_sse2
//   Status: stub

// =============================================================================
// Category 8: Particle / effect rendering
// =============================================================================

// 0x7B2A50: RenderParticleSprites (profiled in transform44)
//   Silicon: sub_7B2A50_sse2 (via hook_sub_7B4BF0?)
//   Status: stub

// 0x7B3A10: RenderParticleSystemSorted
//   __thiscall(this_ECX, renderContext_stack), RET 0x4
//   573 bytes. Unsorted path: direct RenderParticleSprites loop. Sorted path (flag 0x10
//   at this+0x1AC): computes per-particle depth via dot product with view matrix row
//   (0xCF5B78), max-heap sort, renders back-to-front. SSE: depth dot product.
//   Silicon: hook_sub_7B3A10, sub_7B3A10_sse2
//   Status: stub

// 0x7B4BF0: SetParticleLifetime
//   __thiscall(this_ECX, lifetime_stack), RET 0x4
//   Sets particle lifetime at this+0xA8. Clamps to zero below collision threshold.
//   Silicon: hook_sub_7B4BF0
//   Status: stub

// 0x7B5A10: ProcessActiveParticles (profiled in transform44)
//   __thiscall(this_ECX, float deltaTime, int param2), RET 0x8
//   ~560 bytes. Particle system tick: emit if param2==0, iterate active particles
//   (pool at +0x3C/+0x4C, indices at +0x5C, count at +0x64), accumulate lifetime,
//   kill expired (vtable+0xC), call UpdateParticlePhysics/Rotation, propagate to
//   child emitters at +0x80. Hot inner loop with physics updates = SSE target.
//   Silicon: hook_sub_7B5A10, sub_7B5A10_sse2
//   Status: stub

// 0x7B76C0: applyParticleWorldTransform
//   __thiscall(this_ECX, matrixData_stack, translationVec_stack, additionalTransform_stack), RET 0xC
//   Applies world transform + translation to particle emitter. Copies 4x4 matrix,
//   optionally multiplies by inverse additional transform. Handles first-frame vs interp.
//   Silicon: hook_sub_7B76C0
//   Status: stub

// 0x7B7A80: packParticleColorToBytes
//   __fastcall(targetObj_ECX), RET 0xC
//   Converts 4 x87 FPU stack color channels to bytes, packs into u32 at targetObj+0x12C.
//   NOTE: floats come from FPU stack, not regular stack (despite RET 0xC).
//   Silicon: hook_sub_7B7A80
//   Status: stub

// 0x7B7B10: setParticleAlphaFromFloat
//   __fastcall(targetObj_ECX), RET 0x4
//   Converts FPU float to int via __ftol, stores low byte as alpha at targetObj+0x12F.
//   Silicon: hook_sub_7B7B10
//   Status: stub

// 0x7B7E60: AdvanceParticles
//   __thiscall(this_ECX, deltaTime_stack, param2_stack), RET 0x8
//   Main per-frame particle update. Clamps dt to [0, this+0xF8], removes expired
//   particles, spawns new via InterpolateParticlePosition, advances live particles
//   (gravity at +0x164, aging, color/size interpolation). 0x28-byte per-particle array.
//   Silicon: hook_sub_7B7E60
//   Status: stub

// 0x7B8890: GenerateSphereParticle
//   __thiscall(this_ECX, particleOut_stack, speed_stack, transformMatrix_stack), RET 0xC
//   Generates particle with random spherical distribution. RNG via CryptoStateUpdate
//   at this+0x2C. Ellipsoid radii at +0x290/0x294, optional aim at +0x188.
//   Silicon: hook_sub_7B8890
//   Status: stub

// 0x7B8D70: updateRibbonParticle
//   __thiscall(this_ECX, particleOut_stack, speed_stack, transformMatrix_stack), RET 0xC
//   Generates ribbon/trail particle with random spherical position. Similar to
//   GenerateSphereParticle but distinct angle parameterization. Flag 0x4000 = up-axis mode.
//   Silicon: hook_sub_7B8D70
//   Status: stub

// 0x7BA200: generateRandomParticle (plane/spray emitter type)
//   __thiscall(this_ECX, particleOut_stack, lifetime_stack, originPos_stack), RET 0xC
//   Sets initial position from remaining lifetime distance (this+0x14), computes velocity
//   from random yaw/pitch angles (+0x24/+0x28), applies physics, stores scale at +0x20.
//   Silicon: hook_sub_7BA200
//   Status: stub

// 0x7BB860: CreateRotationMatrix (3x4 Rodrigues)
//   __fastcall(outMatrix_ECX, axisVec_EDX, angle_stack, isNorm_stack), RET 0x8
//   Builds 3x4 rotation matrix from axis+angle. Normalizes if flag==0. Returns ECX.
//   Similar to 0x7BDB00 (4x4 version) and 0x7BE490 (3x3 version).
//   Silicon: hook_sub_7BB860
//   Status: stub

// =============================================================================
// Category 9: Matrix/geometry math (7Bxxxx-7Cxxxx range)
// =============================================================================

// 0x7BCA80: transformVector3ByMatrix4x4
//   __fastcall(outVec3_ECX, inVec3_EDX, matrix_stack), RET 0x4
//   Affine position transform: multiplies 3x3 rotation + adds translation column.
//   Called by many other silicon hooks. Core SSE target.
//   Silicon: hook_sub_7BCA80
//   Status: stub

// 0x7BCB40: transformVector4ByMatrix4x4
//   __fastcall(outVec4_ECX, inVec4_EDX, matrix_stack), RET 0x4
//   Full 4-component vector-matrix multiply (includes W, no implicit translation add).
//   Silicon: hook_sub_7BCB40
//   Status: stub

// 0x7BDC40: ApplyTranslationMatrix
//   __thiscall(matrix_ECX, vec3_stack), RET 0x4
//   In-place: multiplies 3x3 rotation by translation vec, adds to elements [12-14].
//   Silicon: hook_sub_7BDC40
//   Status: stub

// 0x7BDCA0: scaleMatrix3x3ByVector
//   __thiscall(matrix_ECX, scaleVec3_stack), RET 0x4
//   In-place scale of 3x3 submatrix: row0 *= s.x, row1 *= s.y, row2 *= s.z.
//   Silicon: hook_sub_7BDCA0
//   Status: stub

// 0x7BDDB0: rotateMatrixByQuaternion
//   __thiscall(matrix_ECX, quat_stack), RET 0x4
//   Builds rotation matrix from quaternion, multiplies with existing matrix via
//   multiplyMatrix4x4, stores back. Allocates 0x9C bytes stack for temps.
//   Silicon: hook_sub_7BDDB0
//   Status: stub

// 0x7BE490: createAxisAngleRotationMatrix3x3
//   __fastcall(outMat3x3_ECX, axisVec3_EDX, angle_stack, isNorm_stack), RET 0x8
//   Rodrigues' formula for 3x3 rotation matrix. Returns ECX. Normalizes axis if flag==0.
//   Silicon: hook_sub_7BE490
//   Status: stub

// 0x7BE5B0-7BF7B0: series of related math functions
//   Silicon hooks all of these individually
//   Status: all stubs

// 0x7C0570: quaternion_slerp
//   __fastcall(outQuat_ECX, quatA_EDX, t_stack, quatB_stack), RET 0x8
//   Spherical linear interpolation between two quaternions. Handles negative dot
//   (shortest path), fallback to direct copy when sin(angle) near zero.
//   Silicon: hook_sub_7C0570
//   Status: stub

// 0x7C2040: point_sphere_collision_test (sphere-AABB overlap)
//   __fastcall(aabb_ECX, sphere_EDX, testMode_stack), RET 0x4
//   Tests point/sphere against AABB with 4 modes (switch on param3): full overlap,
//   partial containment, partial overlap (min<r^2<max), outside-only. Accumulates
//   squared distances per axis. Returns 1 (collision) / 0 (miss). Good SSE candidate.
//   Silicon: hook_sub_7C2040, sub_7C2040_sse2
//   Status: stub

// 0x7C22B0: ray_plane_intersection
//   __fastcall(ray6f_ECX, plane4f_EDX, outT_stack, outHitPt_stack, epsilon_stack), RET 0xC
//   Standard ray-plane intersection: t = -(dot(origin,normal)+d) / dot(dir,normal).
//   Handles parallel rays (dot near zero). Outputs nullable t and hit point.
//   Returns 1 (hit) / 0 (miss). Uses double-precision epsilon at 0x811658.
//   Silicon: hook_sub_7C22B0, sub_7C22B0_sse2
//   Status: stub

// 0x7C29F0: ray_triangle_intersection (already in clip_sse.zig)
//   Silicon: hook_sub_7C29F0, sub_7C29F0_sse2
//   Status: DONE

// 0x7C5880: calculate_animation_orientation
//   __fastcall(animStruct_ECX), RET (no stack cleanup)
//   Computes sin/cos of facing angle at +0x50, stores at +0x68/0x6c.
//   If flag 0x200000 at +0x40 and pitch at +0x54 non-trivial, computes combined
//   facing+pitch orientation at +0x5c/0x60/0x64.
//   Silicon: hook_sub_7C5880
//   Status: stub

// =============================================================================
// Category 10: Lighting
// =============================================================================

// 0x76D680: SetupModelLighting
//   Silicon: hook_CM2Lighting_SetupSunlight, etc.
//   Status: stub -- complex, many sub-functions

// 0x7786A0: SetModelLighting
//   Silicon: hook_CM2Lighting_AddLight, AddDiffuse, SetupGxLights
//   Status: stub -- complex

// =============================================================================
// Category 11: Movement / spline
// =============================================================================

// Silicon hooks: CMovement_SetOrientation, CMovement_PlotUnitSplineMovement
// Silicon hooks: CParticleKey_Interpolate
// Silicon hooks: NTempest C3Spline EvaluateDer1, ArclengthSegT, CatmullRom variants
// Status: all stubs -- spline math could benefit from SSE

// =============================================================================
// Category 12: Misc
// =============================================================================

// Silicon hooks: CalculateFacingTo, EvaluatePolynomial, InterpTable
// Silicon hooks: TransformAABox, SetArgbIntensity
// Silicon hooks: DNClouds_Update, DNClouds_BumpMap
// Silicon hooks: GxTexUpdate
// Silicon hooks: M2HeapSort
// Silicon hooks: SMemAlloc, SMemFree (allocation wrappers)
// Silicon hooks: hook_CWFrustum_Cull, hook_CMapObj_TestBounds
// Status: all stubs

// =============================================================================
// Category 13: Early-address hooks (0x40xxxx-0x5xxxxx range)
// =============================================================================

// 0x41AE40-41AE70: coordinate scaling (NDC<->pixel)
//   All four: __stdcall(float), RET 0x4, returns float via x87 ST(0). 16 bytes each.
//   0x41AE40: param / 0.8 (global at 0x832a44)
//   0x41AE50: param / 0.6 (global at 0x832a48)
//   0x41AE60: 0.8 * param (inverse of 0x41AE40)
//   0x41AE70: 0.6 * param (inverse of 0x41AE50)
//   Trivial — single MULSS/DIVSS each. Hook as fn(f32) callconv(.stdcall) f32.
//   Silicon: hook_sub_41ae40/50/60/70, sub_41ae40_sse2 etc.
//   Status: stubs

// 0x453480: AudioCallback_SetVolume
//   __thiscall(this_ECX, float volume, ptr param2, int param3), RET 0xC
//   Clamps volume to [0.0, 1.0] via x87 FCOMP, dispatches vtable[0x18] if param3==1.
//   74 bytes. SSE2: replace FLD/FCOMP/FNSTSW with COMISS/MAXSS/MINSS. Minimal savings.
//   Silicon: hook_sub_453480, sub_453480_sse2
//   Status: stub

// 0x453580: Vector3_InterpolateWeighted (cubic B-spline Vec3 evaluator)
//   __thiscall(this_ECX, int startIndex, float* weights, uint knotCount, float* outVec3), RET 0x10
//   4 iterations, each calling Math_PowerFunction (0x453620, Horner polynomial, 32 bytes).
//   145 bytes. Inner loop: 3 FLD/FMUL/FADD per iter. Straightforward SSE2.
//   Silicon: hook_sub_453580, sub_453580_sse2
//   Status: stub

// 0x4541B0: interpolateVector3 (Vec3 lerp / weighted interpolation)
//   __thiscall(this_ECX, int keyframeIdx, float* t, float* outVec3), RET 0xC
//   Linear path (this+0x28==0): out = key[n] + (key[n+1] - key[n]) * t. Pure x87 lerp.
//   Weighted path: delegates to Vector3_InterpolateWeighted with static table at 0xb05e10.
//   Silicon: hook_sub_4541B0, sub_4541B0_sse2
//   Status: stub

// 0x483340: UpdateLightingData
//   __fastcall(ECX=unused, outBuf_EDX, guid_lo_stack, guid_hi_stack, param5_stack), RET 0xC
//   Resolves object by GUID via ClntObjMgrObjectPtr, copies 6 dwords from obj+0x98 to outBuf,
//   computes lighting scale (obj+0x24/25/26/27), copies 64 bytes via vtable[0x64].
//   Returns EAX: 1 (success) / 0 (failure). Not pure math — mixed logic + data copy.
//   Silicon: hook_sub_483340, sub_483340_sse2
//   Status: stub

// 0x509220: CheckBoundingBoxCollision
//   __fastcall(index_ECX, boxA_EDX, axis_stack, outDepth_stack), RET 0x8
//   AABB overlap test against global array at 0xbe0b8c (indexed by ECX*16, entries: count+0x4,
//   box_array+0x8, 16-byte stride). 4 x87 float comparisons per entry, switch on axis for
//   penetration depth. 197 bytes. SSE2: CMPPS/MOVMSKPS for all 4 comparisons at once.
//   Silicon: hook_sub_509220, sub_509220_sse2
//   Status: stub

// 0x509BF0: ClampBounds
//   __fastcall(outRect_ECX, mode_EDX, rect4f_stack), RET 0x10
//   Clamps bounding rect to visible screen/map bounds. If mode==0, shifts rect to fit.
//   Returns bitmask of out-of-bounds edges.
//   Silicon: hook_sub_509bf0, sub_509bf0_sse2
//   Status: stub

// 0x5E22D0: CheckPlayerInTriggerZone
//   __fastcall(triggerZone_ECX, posVec3_EDX), RET (no stack cleanup, 2 reg params)
//   Tests if position is inside trigger zone. Supports sphere (radius at +0x14) and
//   oriented box (dims at +0x18-0x20, rotation at +0x24). Returns 1 (inside) / 0 (outside).
//   Silicon: hook_sub_5E22D0
//   Status: stub

// 0x593040: VertexData_UpdateRenderState
//   __thiscall(this_ECX, renderData_stack), RET 0x4
//   Updates vertex render state (~0x54 bytes) from source struct. Unpacks RGBA from
//   packed u32s scaled by float intensity. Sets dirty flags at +0x50.
//   Silicon: hook_sub_593040
//   Status: stub

// 0x5C7010: ConvertPixelsToScreenAlt
//   __thiscall(this_ECX, coord_stack), RET 0x4
//   Pixel-to-screen coordinate conversion. Multiplies by global scale factor (0xC2B9A4),
//   truncates via __ftol. Returns early if this != NULL.
//   Silicon: hook_sub_5C7010
//   Status: stub

// 0x5C8710: RenderTextToVertexBuffer
//   __thiscall(this_ECX, 9 stack params: outBuf, colorArr, posPtrs, charColor, offsetXY,
//   shadowFlag, alphaFlag, startIdx, count), RET 0x24
//   Renders text glyphs into vertex buffer. Reads glyph geometry from font (this+0x10,
//   20 bytes/glyph), applies position, optional 3D rotation, alpha blending. 24-byte vertices.
//   Silicon: hook_sub_5C8710, sub_5C8710_sse2
//   Status: stub

// 0x5F6280: InterpolateSpellPosition
//   __thiscall(this_ECX, outVec3_stack, timeOffset_stack), RET 0x8
//   Interpolates spell projectile world position along waypoint path (0x1C bytes/waypoint).
//   Applies parent object's quaternion rotation (descriptor +0x110). Triggers animation
//   changes at waypoint boundaries.
//   Silicon: hook_sub_5F6280, sub_5F6280_sse2
//   Status: stub

// 0x5F8DC0: CalculateRenderingBounds (LOD selection)
//   __thiscall(this_ECX, 5 stack params), RET 0x14
//   Determines LOD level from distance: compares against this+0x18/this+0x20 ratio.
//   Returns status 0xA2 (near), 0xA3 (transition), 0xA4 (far/culled).
//   Silicon: hook_sub_5F8DC0
//   Status: stub

// 0x614CD0: UpdateObjectTransformWithInterpolation
//   __fastcall(objPtr_ECX, ???_stack), RET 0x4
//   Updates game object's world transform with interpolated position and rotation.
//   Reads current pos via vtable+0x20, interpolates toward target at +0x104-0x10C.
//   Silicon: hook_sub_614CD0, sub_614CD0_sse2
//   Status: stub

// 0x616AF0: ValidatePositionUpdate
//   __thiscall(this_ECX, deltaTime_stack, flags_stack, posVec3_stack), RET 0xC
//   Validates movement update. Calls update_object_animation_state, checks movement
//   flags at +0x40, computes squared distance, rejects if exceeds velocity-scaled threshold.
//   Silicon: hook_sub_616AF0, sub_616AF0_sse2
//   Status: stub

// 0x616BF0: ValidateCoordinateBounds
//   __fastcall(objPtr_ECX), RET (no stack cleanup)
//   Validates XYZ position at +0x10/+0x14/+0x18 are valid floats (IsValidFloat)
//   and within loaded map bounds. Returns 1 (valid) / 0 (invalid).
//   Silicon: hook_sub_616BF0
//   Status: stub

// 0x618920: GetUnitPositionBufferIfValid
//   __fastcall(unitPtr_ECX), RET (no stack cleanup)
//   Checks if float at +0x148 is nonzero; returns ptr to +0x144 (position buffer)
//   or 0. Very small — essentially "has valid height" check.
//   Silicon: hook_sub_618920
//   Status: stub

// =============================================================================
// Category 14: Terrain / world rendering (0x67xxxx-0x6Fxxxx)
// =============================================================================

// 0x675AC0: Weather_ProcessEnvironment
//   __fastcall(weatherCtx_ECX), RET (no stack cleanup)
//   Large weather particle renderer. Sets up render states (blend, alpha, texture),
//   iterates weather particle groups, builds billboard triangle-strip vertex buffers
//   with distance-based opacity, draws with DrawPrimitive.
//   Silicon: hook_sub_675AC0
//   Status: stub

// 0x67C820: GetCachedHeightValue (terrain height cache)
//   __thiscall(this_ECX, coordPair_stack), RET 0x4
//   32x32 float cache at this+0x0, grid origin at this+0x1000/0x1004. On cache miss calls
//   SampleHeightAtPosition. 218 bytes. x87 FILD/FMUL/FSUB/FCOMP → SSE2 cvtsi2ss/mulss/comiss.
//   Silicon: hook_sub_67C820, sub_67C820_sse2
//   Status: stub

// 0x67CA00: GetHeightFromCachedMap (wrapper for GetCachedHeightValue)
//   __thiscall(this_ECX, coordPtr_stack), RET 0x4
//   Scales coords, bounds-checks 5-tile grid, dispatches to GetCachedHeightValue. 133 bytes.
//   Silicon: hook_sub_67CA00, sub_67CA00_sse2
//   Status: stub

// 0x67CA90: SampleAndCacheHeightData
//   __thiscall(this_ECX, gridCoords_stack, outBuf_stack), RET 0x8
//   Computes world-space center of grid cell, looks up cached height. 204 bytes.
//   Silicon: hook_sub_67CA90, sub_67CA90_sse2
//   Status: stub

// 0x67CB60: RaycastLineWithHeightCheck (terrain line-of-sight)
//   __thiscall(this_ECX, startPt_stack, endPt_stack, resultPt_stack), RET 0xC
//   Bresenham-style line walk across height grid, samples terrain height per cell.
//   Returns 1 (hit terrain) / 0 (clear). 752 bytes. Classic LoS check.
//   Silicon: hook_sub_67CB60, sub_67CB60_sse2
//   Status: stub

// 0x6818B0: AddObjectToSpatialList (spatial grid insertion)
//   __fastcall(objectPtr_ECX, posVec3_EDX), RET (no stack cleanup, 2 reg params)
//   186 bytes. Computes 1D grid index from 3D position via dot product with projection
//   vector (0xC7CFB8), scales/truncates, clamps to [0,31]. Inserts into doubly-linked
//   list at grid bucket (0xC7BD4C, stride 0x6C). SSE: 3-component dot + scale + cvt.
//   Silicon: hook_sub_6818B0, sub_6818B0_sse2
//   Status: stub

// 0x683F80: AllocateGameObject (doodad visibility + LOD)
//   __stdcall(), RET (no stack cleanup, no params)
//   Iterates global doodad list (PTR_00c7caec), calculates camera distance with LOD-based
//   fade, performs visibility culling, registers visible objects for rendering.
//   Not pure math — orchestrator function.
//   Silicon: hook_sub_683F80, sub_683F80_sse2
//   Status: stub

// 0x6869C0: TestOrientedBoundingBoxAgainstFrustum
//   __thiscall(frustumPlanes_ECX, aabb_stack, rotMatrix_stack, transVec_stack), RET 0xC
//   Tests OBB against 6 frustum planes. Transforms AABB corners by rotation + translation,
//   dot-products against each plane. Returns 0 (rejected) / 3 (fully inside).
//   Silicon: hook_sub_6869C0, sub_6869C0_sse2
//   Status: stub

// 0x686B80: TestSphereAgainstFrustum
//   __thiscall(frustumPlanes_ECX, sphere_stack), RET 0x4
//   Tests bounding sphere (xyz center + radius at [3]) against 6 frustum planes.
//   Returns 0 (fully outside) / 3 (inside). Classic sphere-frustum cull.
//   Silicon: hook_sub_686B80
//   Status: stub

// 0x68B0D0: CalculateDetailDistances
//   __thiscall(this_ECX, pos_stack, flags_stack, outDeltas_stack, outDists_stack, param5_stack), RET 0x14
//   603 bytes. Iterates 16x16 terrain tile grid, walks 4 sub-chunks each with 8x8 detail
//   grid. Computes squared distances to nearest instance of each detail type (up to 15).
//   Tile grid at this+0x278. Heavy distance computation loop — SSE candidate.
//   Silicon: hook_sub_68B0D0, sub_68B0D0_sse2
//   Status: stub

// 0x68D540: CalculateChunkVertices
//   __fastcall(chunkPtr_ECX), RET (no stack cleanup, 1 reg param)
//   329 bytes. Generates 9x9 vertex grid (81 vertices) for terrain chunk. Reads height
//   data from [ECX+0xC] (8 bytes/entry, float at +4), computes world-space positions
//   using scale (0x80FEE4) and origin (0x7FFAB4). Output at ECX+0x34 (Vec3 x 81).
//   Silicon: hook_sub_68D540, sub_68D540_sse2
//   Status: stub

// 0x699330: IsPointInsideBounds
//   __fastcall(vec3A_ECX, vec3B_EDX), RET (no stack cleanup)
//   Component-wise comparison: returns 1 if all components of B <= A. Bounding box
//   minimum-corner containment test.
//   Silicon: hook_sub_699330
//   Status: stub

// 0x69B1C0: GetTerrainDataAtPosition
//   __fastcall(posVec3_ECX, outPtr_EDX), RET (no stack cleanup)
//   Looks up terrain chunk data via ADT grid (PTR_00c96318), navigates tile/subtile
//   hierarchy. Returns terrain data pointer via param_2. Returns 1/0.
//   Silicon: hook_sub_69B1C0
//   Status: stub

// 0x69B6D0: GetWaterSurfaceData
//   __fastcall(pointVec3_ECX, liquidType_EDX, surfaceH_stack, waterX_stack, waterDir_stack), RET 0xC
//   Queries liquid surface data at world position: type, height, flow velocity/direction.
//   Handles ocean (type 1), river/lake interpolation, up to 4 liquid layers.
//   Silicon: hook_sub_69B6D0
//   Status: stub

// 0x6A8050: SetupRenderingTransforms
//   __thiscall(this_ECX, renderContext_stack), RET 0x4
//   Sets up world object rendering transforms (position/rotation/scale). Applies from
//   object's transform data or byte-packed orientation, recursively processes children.
//   Silicon: hook_sub_6A8050
//   Status: stub

// 0x6AADC0: processTerrainChunkMeshGeneration
//   __fastcall(chunkX_ECX, chunkY_EDX, param3-6_stack), RET 0x10
//   Generates collision mesh triangles for terrain chunk. Iterates vertices within
//   bounding box, constructs triangles with normals. Bitmask controls collision layers
//   (terrain 0xf00, liquid 0xf0000, objects 0xf00000).
//   Silicon: hook_sub_6AADC0
//   Status: stub

// 0x6CF6C0: interpolateKeyframes
//   __fastcall(outPtr_ECX, keyCount_EDX, normTime_stack, param3_stack), RET 0x4
//   Keyframe interpolation for M2 animation tracks. Searches (time,value) pairs for
//   bracketing keyframes, computes interpolated result.
//   Silicon: hook_sub_6CF6C0
//   Status: stub

// 0x6FA1A0: lua_table_hash_index
//   __fastcall(table_ECX, key_EDX), RET (no stack cleanup)
//   Computes Lua table hash bucket index. Dispatches by key type: boolean, string
//   (bitmasked hash), number (lua_table_hash_double), default (modulo).
//   Silicon: hook_sub_6FA1A0
//   Status: stub

// 0x6FA700: lua_table_get_array_element
//   __fastcall(table_ECX, intKey_EDX), RET (no stack cleanup)
//   Gets value from Lua table by integer key. Direct array access if within sizearray,
//   else falls back to hash lookup via lua_table_hash_double.
//   Silicon: hook_sub_6FA700, sub_6FA700_sse2
//   Status: stub

// 0x6FA7A0: lua_table_lookup_key
//   __fastcall(table_ECX, keyPtr_EDX), RET (no stack cleanup)
//   Generic Lua table key lookup dispatcher. Number keys → array access, string keys →
//   hash element, other types → generic hash search.
//   Silicon: hook_sub_6FA7A0
//   Status: stub

// 0x70A060: compareRayHitData (sort comparator)
//   __fastcall(hitIdxA_ECX, hitIdxB_EDX, hitArrayBase_stack), RET 0x4
//   Compares ray intersection hits by distance (+4), secondary float (+8), then index.
//   Each hit entry is 0x10 bytes. Returns -1/0/1.
//   Silicon: hook_sub_70A060, sub_70A060_sse2
//   Status: stub

// 0x70AE10: compareRenderItemsExtended (sort comparator)
//   __fastcall(itemIdxA_ECX, itemIdxB_EDX, renderCtx_stack), RET 0x4
//   Multi-key render item sort: layer, depth, material, texture, distance, batch key,
//   sub-mesh index. Items are 0x40 bytes each.
//   Silicon: hook_sub_70AE10, sub_70AE10_sse2
//   Status: stub

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn isActive() bool { return g_is_hook_owner; }

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
    log_state = logging.Logger.open(module_name, .console);
    log_state.print("silicon: module loaded (no hooks active yet -- stub catalog)\n");
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        log_state.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
