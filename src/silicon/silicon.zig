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
//   __stdcall(float angle, float* outSin, float* outCos), RET 0xC
//   Uses x87 FSINCOS to compute sin/cos, stores to output pointers.
//   Silicon: does not hook directly, uses SSE internally
//   Status: stub

// 0x40CF81: GetFPUControlWord (NOT ftol — silicon mislabel)
//   __stdcall(uint mask, uint newBits), RET (callee cleanup)
//   Reads/modifies FPU control word via FSTCW/FLDCW. Returns old CW as int.
//   24 callers — FP error handling and rounding support routines.
//   Silicon: hook_ftol (misleading name — this is the CW helper, not ftol itself)
//   Status: probed
//
// 0x40A2B0: __ftol (the REAL float-to-long truncation)
//   __cdecl(), RET (no stack cleanup). Input: x87 ST(0). Output: EAX:EDX (int64).
//   Classic MSVC CRT: FSTCW/OR AH,0x0C/FLDCW/FISTP/FLDCW restore. 51+ callers
//   across Lua, text rendering, camera, terrain, animation, coordinates.
//   SSE2 replacement: single CVTTSS2SI eliminates the rounding mode dance.
//   Status: probed

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
//   __fastcall(vecA_ECX, vecB_EDX), RET (no stack cleanup)
//   Classic dot product: a.z*b.z + a.y*b.y + a.x*b.x. Returns f64 via x87 ST(0).
//   14 bytes, 9 instructions. Tiny leaf function.
//   Silicon: not hooked (different from NTempest Dot)
//   Status: stub

// 0x686640: ComputeFrustumPlanesFromVertices (misnamed SetVector3 in Ghidra)
//   __fastcall(this_ECX), RET (no stack cleanup)
//   Computes 4 clipping plane equations (normal+distance) from 8 corner vertices
//   using cross products + NormalizeVector3_InPlace + DotProduct. Also computes negated 5th plane.
//   Silicon: hook_sub_686640, sub_686640_sse2
//   Status: stub

// 0x686820: TranslateBoundingVolume (misnamed NormalizeVector3 in Ghidra)
//   __thiscall(this_ECX, offsetVec3_stack), RET 0x4
//   Translates all 8 corner vertices (+0x60..+0xB4) by offset, recomputes 6 plane
//   distances, translates min/max bounds (+0xC0, +0xCC).
//   Silicon: not directly hooked
//   Status: stub

// 0x6868E0: TransformBoundingVolume (misnamed DotProductVector3 in Ghidra)
//   __thiscall(this_ECX, matrix3x3_stack), RET 0x4
//   Transforms all 8 corners via transformVector3InPlace, calls ComputeFrustumPlanes
//   (0x686640), transforms min/max bounds.
//   Silicon: not directly hooked
//   Status: stub

// 0x6720F0: NormalizeVector3_InPlace
//   __fastcall(vec3_ECX), RET (no stack cleanup)
//   In-place normalize: sqrt(x²+y²+z²), scale = 1/len, xyz *= scale.
//   58 bytes, pure FPU, no div-by-zero guard.
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
//   __thiscall(matrixA_ECX, matrixB_stack), RET 0x4. Returns this.
//   Calls MultiplyMatrix3x4 (0x7BAE60) into stack temp, copies 48 bytes back to this.
//   Silicon: hook_MatrixMultiply (shared hook)
//   Status: stub

// 0x7BDFC0: multiplyMatrix3x3
//   __fastcall(dst_ECX, lhs_EDX, rhs_stack), RET 0x4
//   3x3 matrix multiply: dst = lhs * rhs (9 floats each). Aliasing-safe (loads all
//   before storing). All x87 scalar — strong SSE candidate.
//   Silicon: hook_sub_7BDFC0, sub_7BDFC0 (no _sse2)
//   Status: stub

// 0x7BCEF0: getTransposedMatrix4x4
//   __thiscall(srcMatrix_ECX, dstMatrix_stack), RET 0x4
//   Transposes 4x4 matrix from this to dst. Uses x87 loads + integer register shuffling.
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
//   __fastcall(p0_ECX, p1_EDX, hitPoint_stack, dist_stack, flags_stack), RET 0xC
//   Ray intersection from p0→p1 against world map. Dispatches to terrain LOS (flags & 0xF000FF)
//   and/or ADT rasterization (flags & 0xF00F0F). Interpolates hit as p0+(p1-p0)*dist.
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
//   __thiscall(this_ECX, particleData_stack, vertexBuffers_stack), RET 0x8
//   Core particle sprite renderer. Per-particle: depth culling, color/scale calc,
//   world matrix transform, texture atlas UV, rotation via sin/cos, builds 4 corner
//   vertices with pos/color/UV. Large function (~400+ lines).
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
//   __fastcall(obj_ECX, floatR_stack, floatG_stack, floatB_stack), RET 0xC
//   Reads alpha byte at obj+0x12F, multiplies by 255. Packs ARGB into u32 at obj+0x12C.
//   NOTE: floats are normal stack params (FLD [EBP+0x8] etc), NOT FPU register params.
//   Silicon: hook_sub_7B7A80
//   Status: stub

// 0x7B7B10: setParticleAlphaFromFloat
//   __fastcall(obj_ECX, floatAlpha_stack), RET 0x4
//   Multiplies float by 255.0, rounds, stores as byte at obj+0x12F.
//   Normal stack float param, not FPU register.
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

// 0x7BE5B0: createZRotationMatrix3x3
//   __thiscall(outMat3x3_ECX, angle_stack), RET 0x4. Returns this.
//   Builds 3x3 Z-axis rotation matrix via FSINCOS: [cos,sin,0,-sin,cos,0,0,0,1].
//   Status: stub
//
// 0x7BE5B0-7BF7B0: series of related axis rotation matrices
//   Silicon hooks all of these individually
//   Status: remaining in series need decompilation

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
//   __fastcall(ptr_ECX, lightingCtx_EDX, sceneObj_stack), RET 0x4
//   Configures lighting on model. If flag bit 0 at sceneObj+0x3A4, converts RGB byte
//   color to float, clamps, calls setupCameraParameters with light direction.
//   Silicon: hook_CM2Lighting_SetupSunlight, etc.
//   Status: stub

// 0x7786A0: SetModelLighting (actually UI model constructor/initializer)
//   __thiscall(this_ECX, initParam_stack), RET 0x4. Returns this.
//   Constructor for ~0x4D8 byte UI model object. Sets up vtables (0x81C7F8, 0x81C7C8),
//   initializes sub-objects at +0x33C/+0x3B8/+0x434, sets LOD=2. Ghidra mislabel.
//   Silicon: hook_CM2Lighting_AddLight, AddDiffuse, SetupGxLights
//   Status: stub

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
//   __fastcall(keyframeArray_ECX, count_EDX, t_float_stack), RET 0x4
//   3 params (not 4). Keyframe lerp: clamps t to [0,1], finds bracketing pair in
//   {time,value}[count] array (8 bytes/entry), linearly interpolates. Returns f32 via x87.
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
// Probe hooks — call-counting detours to verify functions are actually called
// =============================================================================

// Calling convention shorthands
const FC = hook.cc.fastcall;
const TC = hook.cc.thiscall;
const SC = hook.cc.stdcall;

// Function type aliases — {CC}{paramCount}{return}: r=u32, v=void, d=f64(x87)
const FC1v = fn (u32) callconv(FC) void;
const FC1r = fn (u32) callconv(FC) u32;
const FC2v = fn (u32, u32) callconv(FC) void;
const FC2r = fn (u32, u32) callconv(FC) u32;
const FC3v = fn (u32, u32, u32) callconv(FC) void;
const FC3r = fn (u32, u32, u32) callconv(FC) u32;
const FC2d = fn (u32, u32) callconv(FC) f64;
const FC3d = fn (u32, u32, u32) callconv(FC) f64;
const FC4r = fn (u32, u32, u32, u32) callconv(FC) u32;
const FC4d = fn (u32, u32, u32, u32) callconv(FC) f64;
const FC5v = fn (u32, u32, u32, u32, u32) callconv(FC) void;
const FC5r = fn (u32, u32, u32, u32, u32) callconv(FC) u32;
const FC6r = fn (u32, u32, u32, u32, u32, u32) callconv(FC) u32;
const TC1v = fn (u32) callconv(TC) void;
const TC1r = fn (u32) callconv(TC) u32;
const TC2v = fn (u32, u32) callconv(TC) void;
const TC2r = fn (u32, u32) callconv(TC) u32;
const TC2d = fn (u32, u32) callconv(TC) f64;
const TC3v = fn (u32, u32, u32) callconv(TC) void;
const TC3r = fn (u32, u32, u32) callconv(TC) u32;
const TC4v = fn (u32, u32, u32, u32) callconv(TC) void;
const TC4r = fn (u32, u32, u32, u32) callconv(TC) u32;
const TC5v = fn (u32, u32, u32, u32, u32) callconv(TC) void;
const TC6v = fn (u32, u32, u32, u32, u32, u32) callconv(TC) void;
const SC0v = fn () callconv(SC) void;
const SC1d = fn (u32) callconv(SC) f64;
const SC2r = fn (u32, u32) callconv(SC) u32;
const SC3v = fn (u32, u32, u32) callconv(SC) void;
const FC4v = fn (u32, u32, u32, u32) callconv(FC) void;
// __cdecl for CRT functions (caller cleanup)
const CD0r = fn () callconv(hook.cc.cdecl) u32; // ftol: no params, returns EAX (ST(0) implicit)

// =============================================================================
// SSE math replacements — ordered by call frequency (highest first)
// =============================================================================

// --- transformVector3ByMatrix4x4 (10.8M calls/7.5s) ---
// __fastcall(outVec3_ECX, inVec3_EDX, matrix_stack), RET 0x4
// Affine: out[i] = dot(vec4(in, 1.0), matrix_row[i])
fn sseTransformVec3Mat4(out: u32, in_vec: u32, mat: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const src: [*]const f32 = @ptrFromInt(in_vec);
    const m: [*]const f32 = @ptrFromInt(mat);
    const v: @Vector(4, f32) = .{ src[0], src[1], src[2], 1.0 };
    const r0: @Vector(4, f32) = .{ m[0], m[1], m[2], m[3] };
    const r1: @Vector(4, f32) = .{ m[4], m[5], m[6], m[7] };
    const r2: @Vector(4, f32) = .{ m[8], m[9], m[10], m[11] };
    dst[0] = @reduce(.Add, v * r0);
    dst[1] = @reduce(.Add, v * r1);
    dst[2] = @reduce(.Add, v * r2);
    return out;
}

// --- scaleMatrix3x3ByVector (1.3M calls/7.5s) ---
// __thiscall(matrix_ECX, scaleVec3_stack), RET 0x4
// In-place: row0 *= s.x, row1 *= s.y, row2 *= s.z
fn sseScaleMat3x3(mat: u32, scale: u32) callconv(TC) u32 {
    const m: [*]f32 = @ptrFromInt(mat);
    const s: [*]const f32 = @ptrFromInt(scale);
    // Row 0 *= s.x
    m[0] *= s[0];
    m[1] *= s[0];
    m[2] *= s[0];
    // Row 1 *= s.y
    m[3] *= s[1];
    m[4] *= s[1];
    m[5] *= s[1];
    // Row 2 *= s.z
    m[6] *= s[2];
    m[7] *= s[2];
    m[8] *= s[2];
    return mat;
}

// --- ClassifyPointAgainstFrustum (3.2M calls/7.5s) ---
// __thiscall(frustumPlanes_ECX, pointVec3_stack, outBitmask_stack), RET 0x8
// Tests point against 6 frustum planes, produces 6-bit outcode bitmask.
fn sseClassifyPointFrustum(planes_ptr: u32, point: u32, out_mask: u32) callconv(TC) u32 {
    const p: [*]const f32 = @ptrFromInt(point);
    const mask: *u32 = @ptrFromInt(out_mask);
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const px = p[0];
    const py = p[1];
    const pz = p[2];
    var bits: u32 = 0;
    // 6 planes, each is {nx, ny, nz, d} = 4 floats
    inline for (0..6) |i| {
        const pl = planes + i * 4;
        const dist = px * pl[0] + py * pl[1] + pz * pl[2] + pl[3];
        if (dist < 0) bits |= (@as(u32, 1) << @intCast(i));
    }
    mask.* = bits;
    return planes_ptr;
}

// --- CheckBoxLineIntersection (2.7M calls/7.5s) ---
// __fastcall(boxMin_ECX, lineStart_EDX, lineEnd_stack), RET 0x4
// Slab-method AABB-line intersection. Box is min[3] at +0, max[3] at +0xC.
fn sseCheckBoxLineIntersect(box_ptr: u32, line_start: u32, line_end: u32) callconv(FC) u32 {
    const bmin: [*]const f32 = @ptrFromInt(box_ptr);
    const bmax: [*]const f32 = @ptrFromInt(box_ptr + 0xC);
    const start: [*]const f32 = @ptrFromInt(line_start);
    const end: [*]const f32 = @ptrFromInt(line_end);

    var tmin: f32 = 0.0;
    var tmax: f32 = 1.0;

    inline for (0..3) |i| {
        const dir = end[i] - start[i];
        if (@abs(dir) < 1.0e-20) {
            // Ray parallel to slab — check if origin is within
            if (start[i] < bmin[i] or start[i] > bmax[i]) return 0;
        } else {
            const inv_dir = 1.0 / dir;
            var t0 = (bmin[i] - start[i]) * inv_dir;
            var t1 = (bmax[i] - start[i]) * inv_dir;
            if (t0 > t1) {
                const tmp = t0;
                t0 = t1;
                t1 = tmp;
            }
            if (t0 > tmin) tmin = t0;
            if (t1 < tmax) tmax = t1;
            if (tmin > tmax) return 0;
        }
    }
    return 1;
}

// --- CalculateDistanceToPlane (525K calls/7.5s) ---
// __fastcall(point_ECX, plane_EDX, direction_stack), RET 0x4
// Returns (dot(point,normal)+d) / dot(direction,normal) via x87 ST(0)
fn sseDistanceToPlane(point: u32, plane: u32, direction: u32) callconv(FC) f64 {
    const p: [*]const f32 = @ptrFromInt(point);
    const pl: [*]const f32 = @ptrFromInt(plane);
    const dir: [*]const f32 = @ptrFromInt(direction);
    const dot1 = p[0] * pl[0] + p[1] * pl[1] + p[2] * pl[2] + pl[3];
    const dot2 = dir[0] * pl[0] + dir[1] * pl[1] + dir[2] * pl[2];
    if (@abs(dot2) < 1.0e-20) return 0.0;
    return @floatCast(dot1 / dot2);
}

// --- normalizeVector3 (137K calls/7.5s) ---
// __thiscall(Vec3_ECX, length_stack), RET 0x4
// Divides each component by length: xyz *= 1.0/length
fn sseNormalizeVec3(vec: u32, length_bits: u32) callconv(TC) void {
    const v: [*]f32 = @ptrFromInt(vec);
    const length: f32 = @bitCast(length_bits);
    const scale = 1.0 / length;
    v[0] *= scale;
    v[1] *= scale;
    v[2] *= scale;
}

// --- ApplyTranslationMatrix (182K calls/7.5s) ---
// __thiscall(matrix_ECX, vec3_stack), RET 0x4
// mat[12] += dot(row0, vec), mat[13] += dot(row1, vec), mat[14] += dot(row2, vec)
fn sseApplyTranslation(mat: u32, vec: u32) callconv(TC) u32 {
    const m: [*]f32 = @ptrFromInt(mat);
    const v: [*]const f32 = @ptrFromInt(vec);
    m[12] += m[0] * v[0] + m[4] * v[1] + m[8] * v[2];
    m[13] += m[1] * v[0] + m[5] * v[1] + m[9] * v[2];
    m[14] += m[2] * v[0] + m[6] * v[1] + m[10] * v[2];
    return mat;
}

// --- MultiplyMatrix3x4 (hooked but low count — still pure math) ---
// __fastcall(out_ECX, matA_EDX, matB_stack), RET 0x4
fn sseMulMat3x4(out: u32, a_ptr: u32, b_ptr: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const a: [*]const f32 = @ptrFromInt(a_ptr);
    const b: [*]const f32 = @ptrFromInt(b_ptr);
    // 3x3 rotation block
    inline for (0..3) |row| {
        inline for (0..3) |col| {
            dst[row * 3 + col] = a[col] * b[row * 3] + a[col + 3] * b[row * 3 + 1] + a[col + 6] * b[row * 3 + 2];
        }
    }
    // Translation row (indices 9-11): same multiply + add B's translation
    inline for (0..3) |col| {
        dst[9 + col] = a[9] * b[col] + a[10] * b[col + 3] + a[11] * b[col + 6] + b[9 + col];
    }
    return out;
}

// --- multiplyMatrix3x3 (low count but trivial) ---
// __fastcall(dst_ECX, lhs_EDX, rhs_stack), RET 0x4
fn sseMulMat3x3(out: u32, a_ptr: u32, b_ptr: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const a: [*]const f32 = @ptrFromInt(a_ptr);
    const b: [*]const f32 = @ptrFromInt(b_ptr);
    inline for (0..3) |row| {
        inline for (0..3) |col| {
            dst[row * 3 + col] = a[col] * b[row * 3] + a[col + 3] * b[row * 3 + 1] + a[col + 6] * b[row * 3 + 2];
        }
    }
    return out;
}

// --- transformVector4ByMatrix4x4 (120K calls/7.5s) ---
// __fastcall(outVec4_ECX, inVec4_EDX, matrix_stack), RET 0x4
fn sseTransformVec4Mat4(out: u32, in_vec: u32, mat: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const src: [*]const f32 = @ptrFromInt(in_vec);
    const m: [*]const f32 = @ptrFromInt(mat);
    const v: @Vector(4, f32) = .{ src[0], src[1], src[2], src[3] };
    inline for (0..4) |i| {
        const row: @Vector(4, f32) = .{ m[i * 4], m[i * 4 + 1], m[i * 4 + 2], m[i * 4 + 3] };
        dst[i] = @reduce(.Add, v * row);
    }
    return out;
}

// --- TestSphereAgainstFrustum (375K calls/7.5s) ---
// __thiscall(frustumPlanes_ECX, sphere_stack), RET 0x4
// Tests sphere (xyz + radius at [3]) against 6 planes. Returns 0 (outside) / 3 (inside).
fn sseTestSphereFrustum(planes_ptr: u32, sphere: u32) callconv(TC) u32 {
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const s: [*]const f32 = @ptrFromInt(sphere);
    const cx = s[0];
    const cy = s[1];
    const cz = s[2];
    const r = s[3];
    inline for (0..6) |i| {
        const pl = planes + i * 4;
        const dist = cx * pl[0] + cy * pl[1] + cz * pl[2] + pl[3];
        if (dist < -r) return 0; // fully outside this plane
    }
    return 3;
}

// --- IsPointInsideBounds (1.7M calls/7.5s) ---
// __fastcall(vec3A_ECX, vec3B_EDX), RET (no stack cleanup)
// Returns 1 if all components of B <= A
fn sseIsPointInsideBounds(a: u32, b: u32) callconv(FC) u32 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    if (vb[0] <= va[0] and vb[1] <= va[1] and vb[2] <= va[2]) return 1;
    return 0;
}

// --- createAxisAngleRotationMatrix (304K calls/7.5s) ---
// __fastcall(outMatrix4x4_ECX, axisVec3_EDX, angle_stack, isNormalized_stack), RET 0x8
// Rodrigues' formula: R = cos(a)*I + (1-cos(a))*outer(axis) + sin(a)*skew(axis)
fn sseCreateAxisAngleRotMat4(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) callconv(FC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0];
    var y = ax[1];
    var z = ax[2];
    // Normalize axis if not already
    if (is_normalized == 0) {
        const len = @sqrt(x * x + y * y + z * z);
        if (len > 1.0e-20) {
            const inv = 1.0 / len;
            x *= inv;
            y *= inv;
            z *= inv;
        }
    }
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle);
    const s = @sin(angle);
    const t = 1.0 - c;
    // Row 0
    m[0] = t * x * x + c;
    m[1] = t * x * y + s * z;
    m[2] = t * x * z - s * y;
    m[3] = 0;
    // Row 1
    m[4] = t * x * y - s * z;
    m[5] = t * y * y + c;
    m[6] = t * y * z + s * x;
    m[7] = 0;
    // Row 2
    m[8] = t * x * z + s * y;
    m[9] = t * y * z - s * x;
    m[10] = t * z * z + c;
    m[11] = 0;
    // Row 3 — identity
    m[12] = 0;
    m[13] = 0;
    m[14] = 0;
    m[15] = 1;
    return out;
}

// --- createAxisAngleRotationMatrix3x3 (13K calls/7.5s) ---
// __fastcall(outMat3x3_ECX, axisVec3_EDX, angle_stack, isNorm_stack), RET 0x8
fn sseCreateAxisAngleRotMat3x3(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) callconv(FC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0];
    var y = ax[1];
    var z = ax[2];
    if (is_normalized == 0) {
        const len = @sqrt(x * x + y * y + z * z);
        if (len > 1.0e-20) {
            const inv = 1.0 / len;
            x *= inv;
            y *= inv;
            z *= inv;
        }
    }
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle);
    const s = @sin(angle);
    const t = 1.0 - c;
    m[0] = t * x * x + c;
    m[1] = t * x * y + s * z;
    m[2] = t * x * z - s * y;
    m[3] = t * x * y - s * z;
    m[4] = t * y * y + c;
    m[5] = t * y * z + s * x;
    m[6] = t * x * z + s * y;
    m[7] = t * y * z - s * x;
    m[8] = t * z * z + c;
    return out;
}

// --- CreateRotationMatrix 3x4 (probe only, same Rodrigues) ---
// __fastcall(outMatrix_ECX, axisVec_EDX, angle_stack, isNorm_stack), RET 0x8
fn sseCreateRotMat3x4(out: u32, axis_ptr: u32, angle_bits: u32, is_normalized: u32) callconv(FC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const ax: [*]const f32 = @ptrFromInt(axis_ptr);
    var x = ax[0];
    var y = ax[1];
    var z = ax[2];
    if (is_normalized == 0) {
        const len = @sqrt(x * x + y * y + z * z);
        if (len > 1.0e-20) {
            const inv = 1.0 / len;
            x *= inv;
            y *= inv;
            z *= inv;
        }
    }
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle);
    const s = @sin(angle);
    const t = 1.0 - c;
    // 3x3 rotation block
    m[0] = t * x * x + c;
    m[1] = t * x * y + s * z;
    m[2] = t * x * z - s * y;
    m[3] = t * x * y - s * z;
    m[4] = t * y * y + c;
    m[5] = t * y * z + s * x;
    m[6] = t * x * z + s * y;
    m[7] = t * y * z - s * x;
    m[8] = t * z * z + c;
    // Translation column zeroed
    m[9] = 0;
    m[10] = 0;
    m[11] = 0;
    return out;
}

// --- quaternion_slerp (5.7K but foundational) ---
// __fastcall(outQuat_ECX, quatA_EDX, t_stack, quatB_stack), RET 0x8
fn sseQuatSlerp(out: u32, a_ptr: u32, t_bits: u32, b_ptr: u32) callconv(FC) u32 {
    const dst: [*]f32 = @ptrFromInt(out);
    const a: [*]const f32 = @ptrFromInt(a_ptr);
    const b_raw: [*]const f32 = @ptrFromInt(b_ptr);
    const t: f32 = @bitCast(t_bits);
    // Dot product
    var dot = a[0] * b_raw[0] + a[1] * b_raw[1] + a[2] * b_raw[2] + a[3] * b_raw[3];
    // Shortest path — negate b if dot < 0
    var sign: f32 = 1.0;
    if (dot < 0) {
        dot = -dot;
        sign = -1.0;
    }
    var s0: f32 = undefined;
    var s1: f32 = undefined;
    if (dot > 0.9995) {
        // Very close — linear interpolation
        s0 = 1.0 - t;
        s1 = t * sign;
    } else {
        const theta = std.math.acos(dot);
        const sin_theta = @sin(theta);
        const inv_sin = 1.0 / sin_theta;
        s0 = @sin((1.0 - t) * theta) * inv_sin;
        s1 = @sin(t * theta) * inv_sin * sign;
    }
    dst[0] = s0 * a[0] + s1 * b_raw[0];
    dst[1] = s0 * a[1] + s1 * b_raw[1];
    dst[2] = s0 * a[2] + s1 * b_raw[2];
    dst[3] = s0 * a[3] + s1 * b_raw[3];
    return out;
}

// --- NormalizeVector3_InPlace (29K calls/7.5s) ---
// __fastcall(vec3_ECX), RET (no stack cleanup)
fn sseNormalizeVec3InPlace(vec: u32) callconv(FC) void {
    const v: [*]f32 = @ptrFromInt(vec);
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len > 1.0e-20) {
        const inv = 1.0 / len;
        v[0] *= inv;
        v[1] *= inv;
        v[2] *= inv;
    }
}

// --- Vector3_DotProduct (31K calls/7.5s) ---
// __fastcall(vecA_ECX, vecB_EDX), RET (no stack cleanup). Returns f64 via x87.
fn sseVec3Dot(a: u32, b: u32) callconv(FC) f64 {
    const va: [*]const f32 = @ptrFromInt(a);
    const vb: [*]const f32 = @ptrFromInt(b);
    return @floatCast(va[0] * vb[0] + va[1] * vb[1] + va[2] * vb[2]);
}

// --- getTransposedMatrix4x4 ---
// __thiscall(srcMatrix_ECX, dstMatrix_stack), RET 0x4
fn sseTransposeMat4x4(src: u32, dst: u32) callconv(TC) u32 {
    const s: [*]const f32 = @ptrFromInt(src);
    const d: [*]f32 = @ptrFromInt(dst);
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            d[row * 4 + col] = s[col * 4 + row];
        }
    }
    return src;
}

// --- MultiplyMatrix3x4InPlace ---
// __thiscall(matrixA_ECX, matrixB_stack), RET 0x4. Returns this.
// this = this * matB. Uses stack temp for safe aliasing.
fn sseMulMat3x4InPlace(mat_a: u32, mat_b: u32) callconv(TC) u32 {
    const a: [*]f32 = @ptrFromInt(mat_a);
    const b: [*]const f32 = @ptrFromInt(mat_b);
    // Temp for result (12 floats)
    var tmp: [12]f32 = undefined;
    inline for (0..3) |row| {
        inline for (0..3) |col| {
            tmp[row * 3 + col] = a[col] * b[row * 3] + a[col + 3] * b[row * 3 + 1] + a[col + 6] * b[row * 3 + 2];
        }
    }
    inline for (0..3) |col| {
        tmp[9 + col] = a[9] * b[col] + a[10] * b[col + 3] + a[11] * b[col + 6] + b[9 + col];
    }
    // Copy back
    inline for (0..12) |i| {
        a[i] = tmp[i];
    }
    return mat_a;
}

// --- TestOrientedBoundingBoxAgainstFrustum ---
// __thiscall(frustumPlanes_ECX, aabb_stack, rotMatrix_stack, transVec_stack), RET 0xC
// Tests OBB against 6 frustum planes. Returns 0 (rejected) / 3 (inside).
fn sseTestOBBFrustum(planes_ptr: u32, aabb_ptr: u32, rot_ptr: u32, trans_ptr: u32) callconv(TC) u32 {
    const planes: [*]const f32 = @ptrFromInt(planes_ptr);
    const aabb: [*]const f32 = @ptrFromInt(aabb_ptr); // min[3] at +0, max[3] at +3
    const rot: [*]const f32 = @ptrFromInt(rot_ptr); // 3x3 rotation matrix
    const trans: [*]const f32 = @ptrFromInt(trans_ptr); // translation vec3
    // Build 8 corners from AABB min/max
    const min = [3]f32{ aabb[0], aabb[1], aabb[2] };
    const max = [3]f32{ aabb[3], aabb[4], aabb[5] };
    var corners: [8][3]f32 = undefined;
    inline for (0..8) |i| {
        const lx = if (i & 1 != 0) max[0] else min[0];
        const ly = if (i & 2 != 0) max[1] else min[1];
        const lz = if (i & 4 != 0) max[2] else min[2];
        // Transform: world = rot * local + trans
        corners[i][0] = rot[0] * lx + rot[3] * ly + rot[6] * lz + trans[0];
        corners[i][1] = rot[1] * lx + rot[4] * ly + rot[7] * lz + trans[1];
        corners[i][2] = rot[2] * lx + rot[5] * ly + rot[8] * lz + trans[2];
    }
    // Test against 6 planes
    inline for (0..6) |p| {
        const pl = planes + p * 4;
        var all_outside = true;
        inline for (0..8) |c| {
            const dist = corners[c][0] * pl[0] + corners[c][1] * pl[1] + corners[c][2] * pl[2] + pl[3];
            if (dist >= 0) all_outside = false;
        }
        if (all_outside) return 0;
    }
    return 3;
}

// --- createZRotationMatrix3x3 ---
// __thiscall(outMat3x3_ECX, angle_stack), RET 0x4. Returns this.
fn sseCreateZRotMat3x3(out: u32, angle_bits: u32) callconv(TC) u32 {
    const m: [*]f32 = @ptrFromInt(out);
    const angle: f32 = @bitCast(angle_bits);
    const c = @cos(angle);
    const s = @sin(angle);
    m[0] = c;
    m[1] = s;
    m[2] = 0;
    m[3] = -s;
    m[4] = c;
    m[5] = 0;
    m[6] = 0;
    m[7] = 0;
    m[8] = 1;
    return out;
}

// --- addVector3ToAccumulator (136K calls/7.5s) ---
// __thiscall(this_ECX, vec3_stack), RET 0x4
// Adds Vec3 to this+0x54, also adds scaled copy (global 0x81207C) into 3x3 diagonal
// at +0x84/+0xA8/+0xCC
fn sseAddVec3ToAccumulator(this: u32, vec: u32) callconv(TC) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const v: [*]const f32 = @ptrFromInt(vec);
    const scale: f32 = @as(*const f32, @ptrFromInt(0x81207C)).*;
    // Accumulate translation at +0x54 (offset in f32 = 0x54/4 = 21)
    obj[21] += v[0];
    obj[22] += v[1];
    obj[23] += v[2];
    // Scaled copy into 3x3 matrix diagonal: +0x84=33, +0xA8=42, +0xCC=51
    obj[33] += v[0] * scale;
    obj[42] += v[1] * scale;
    obj[51] += v[2] * scale;
}

// --- addToColorAccumulator (10K calls/7.5s) ---
// __thiscall(this_ECX, colorVec3_stack), RET 0x4
// Accumulates color/light into this+0x6C (offset in f32 = 0x6C/4 = 27)
fn sseAddToColorAccumulator(this: u32, color: u32) callconv(TC) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const c: [*]const f32 = @ptrFromInt(color);
    obj[27] += c[0];
    obj[28] += c[1];
    obj[29] += c[2];
}

// --- calculateSinCos ---
// __stdcall(float angle, float* outSin, float* outCos), RET 0xC
fn sseCalculateSinCos(angle_bits: u32, out_sin: u32, out_cos: u32) callconv(SC) void {
    const angle: f32 = @bitCast(angle_bits);
    const s: *f32 = @ptrFromInt(out_sin);
    const c: *f32 = @ptrFromInt(out_cos);
    s.* = @sin(angle);
    c.* = @cos(angle);
}

// --- rotateMatrixByQuaternion (5.7K calls/7.5s) ---
// __thiscall(matrix_ECX, quat_stack), RET 0x4
// Builds rotation matrix from quaternion, multiplies with existing matrix.
fn sseRotateMatByQuat(mat: u32, quat: u32) callconv(TC) u32 {
    const m: [*]f32 = @ptrFromInt(mat);
    const q: [*]const f32 = @ptrFromInt(quat);
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    // Build rotation matrix from quaternion
    const x2 = x + x;
    const y2 = y + y;
    const z2 = z + z;
    const xx = x * x2;
    const xy = x * y2;
    const xz = x * z2;
    const yy = y * y2;
    const yz = y * z2;
    const zz = z * z2;
    const wx = w * x2;
    const wy = w * y2;
    const wz = w * z2;
    var r: [16]f32 = undefined;
    r[0] = 1.0 - (yy + zz);
    r[1] = xy + wz;
    r[2] = xz - wy;
    r[3] = 0;
    r[4] = xy - wz;
    r[5] = 1.0 - (xx + zz);
    r[6] = yz + wx;
    r[7] = 0;
    r[8] = xz + wy;
    r[9] = yz - wx;
    r[10] = 1.0 - (xx + yy);
    r[11] = 0;
    r[12] = 0;
    r[13] = 0;
    r[14] = 0;
    r[15] = 1;
    // Multiply: result = quat_matrix * existing_matrix, store back to m
    var tmp: [16]f32 = undefined;
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            tmp[row * 4 + col] = r[row * 4] * m[col] + r[row * 4 + 1] * m[4 + col] + r[row * 4 + 2] * m[8 + col] + r[row * 4 + 3] * m[12 + col];
        }
    }
    inline for (0..16) |i| {
        m[i] = tmp[i];
    }
    return mat;
}

// --- packParticleColorToBytes (2K calls/7.5s) ---
// __fastcall(obj_ECX, unused_EDX, floatR_stack, floatG_stack, floatB_stack), RET 0xC
// Reads alpha at obj+0x12F, packs ARGB into u32 at obj+0x12C
fn ssePackParticleColor(obj: u32, _: u32, r_bits: u32, g_bits: u32, b_bits: u32) callconv(FC) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const out: *u32 = @ptrCast(@alignCast(base + 0x12C));
    const alpha = base[0x12F];
    const r: f32 = @bitCast(r_bits);
    const g: f32 = @bitCast(g_bits);
    const b: f32 = @bitCast(b_bits);
    const rb: u8 = @intFromFloat(std.math.clamp(r * 255.0, 0.0, 255.0));
    const gb: u8 = @intFromFloat(std.math.clamp(g * 255.0, 0.0, 255.0));
    const bb: u8 = @intFromFloat(std.math.clamp(b * 255.0, 0.0, 255.0));
    out.* = @as(u32, alpha) << 24 | @as(u32, rb) << 16 | @as(u32, gb) << 8 | @as(u32, bb);
}

// --- setParticleAlphaFromFloat (2K calls/7.5s) ---
// __fastcall(obj_ECX, unused_EDX, floatAlpha_stack), RET 0x4
fn sseSetParticleAlpha(obj: u32, _: u32, alpha_bits: u32) callconv(FC) void {
    const base: [*]u8 = @ptrFromInt(obj);
    const alpha: f32 = @bitCast(alpha_bits);
    base[0x12F] = @intFromFloat(std.math.clamp(alpha * 255.0, 0.0, 255.0));
}

// --- TranslateBoundingVolume (2K calls/7.5s) ---
// __thiscall(this_ECX, offsetVec3_stack), RET 0x4
// Translates 8 corners (+0x60..+0xB4, stride 12), recomputes 6 plane distances,
// translates min/max bounds (+0xC0, +0xCC)
fn sseTranslateBoundingVol(this: u32, offset: u32) callconv(TC) void {
    const obj: [*]f32 = @ptrFromInt(this);
    const off: [*]const f32 = @ptrFromInt(offset);
    const dx = off[0];
    const dy = off[1];
    const dz = off[2];
    // 8 corners: +0x60 = float offset 24, stride 3 floats
    inline for (0..8) |i| {
        const base = 24 + i * 3;
        obj[base] += dx;
        obj[base + 1] += dy;
        obj[base + 2] += dz;
    }
    // 6 plane distances: planes start at +0x0, each plane is {nx,ny,nz,d} = 4 floats
    // d -= dot(normal, offset)
    inline for (0..6) |i| {
        const base = i * 4;
        obj[base + 3] -= obj[base] * dx + obj[base + 1] * dy + obj[base + 2] * dz;
    }
    // Min bounds at +0xC0 = float offset 48, Max at +0xCC = float offset 51
    obj[48] += dx;
    obj[49] += dy;
    obj[50] += dz;
    obj[51] += dx;
    obj[52] += dy;
    obj[53] += dz;
}

// --- TransformBoundingVolume (3K calls/7.5s) ---
// __thiscall(this_ECX, matrix3x3_stack), RET 0x4
// Transforms 8 corners via 3x3 matrix, recomputes planes and bounds.
fn sseTransformBoundingVol(this: u32, mat: u32) callconv(TC) u32 {
    const obj: [*]f32 = @ptrFromInt(this);
    const m: [*]const f32 = @ptrFromInt(mat);
    // Transform 8 corners in-place
    inline for (0..8) |i| {
        const base = 24 + i * 3; // +0x60 / 4
        const x = obj[base];
        const y = obj[base + 1];
        const z = obj[base + 2];
        obj[base] = m[0] * x + m[3] * y + m[6] * z;
        obj[base + 1] = m[1] * x + m[4] * y + m[7] * z;
        obj[base + 2] = m[2] * x + m[5] * y + m[8] * z;
    }
    // Recompute planes from transformed corners — call ComputeFrustumPlanes logic
    // This is equivalent to calling 0x686640 on self, which we've also hooked.
    // For correctness, call the original ComputeFrustumPlanes via its hook trampoline.
    h109.callOriginal(.{this});
    // Transform min/max bounds
    const mnx = obj[48];
    const mny = obj[49];
    const mnz = obj[50];
    obj[48] = m[0] * mnx + m[3] * mny + m[6] * mnz;
    obj[49] = m[1] * mnx + m[4] * mny + m[7] * mnz;
    obj[50] = m[2] * mnx + m[5] * mny + m[8] * mnz;
    const mxx = obj[51];
    const mxy = obj[52];
    const mxz = obj[53];
    obj[51] = m[0] * mxx + m[3] * mxy + m[6] * mxz;
    obj[52] = m[1] * mxx + m[4] * mxy + m[7] * mxz;
    obj[53] = m[2] * mxx + m[5] * mxy + m[8] * mxz;
    return this;
}

// --- ComputeFrustumPlanesFromVertices (7K calls/7.5s) ---
// __fastcall(this_ECX), RET (no stack cleanup)
// Computes 4 clipping planes from 8 corner vertices using cross products + normalize.
// Keep as probe — complex geometry with cross products, normalize calls, and
// plane distance computation. The 8 corners are already transformed by our hooks above.

// =============================================================================
// Probe infrastructure (for functions not yet SSE-replaced)
// =============================================================================

fn probeDetour(
    comptime FnType: type,
    comptime detour_hook: *hook.Detour(FnType),
    comptime counter: *u32,
) *const FnType {
    const info = @typeInfo(FnType).@"fn";
    const Ret = info.return_type.?;
    const nparams = info.params.len;
    const cc = info.calling_convention;
    const S = struct {
        fn d0() callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{});
        }
        fn d1(a: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{a});
        }
        fn d2(a: u32, b: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b });
        }
        fn d3(a: u32, b: u32, c: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b, c });
        }
        fn d4(a: u32, b: u32, c: u32, d: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b, c, d });
        }
        fn d5(a: u32, b: u32, c: u32, d: u32, e: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b, c, d, e });
        }
        fn d6(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b, c, d, e, f });
        }
        fn d10(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32, g: u32, i: u32, j: u32, k: u32) callconv(cc) Ret {
            _ = @atomicRmw(u32, counter, .Add, 1, .monotonic);
            return detour_hook.callOriginal(.{ a, b, c, d, e, f, g, i, j, k });
        }
    };
    return switch (nparams) {
        0 => @ptrCast(&S.d0),
        1 => @ptrCast(&S.d1),
        2 => @ptrCast(&S.d2),
        3 => @ptrCast(&S.d3),
        4 => @ptrCast(&S.d4),
        5 => @ptrCast(&S.d5),
        6 => @ptrCast(&S.d6),
        10 => @ptrCast(&S.d10),
        else => @compileError("unsupported param count for probe"),
    };
}

// --- Probe table: { index, name, address, hook_var, fn_type } ---
// Grouped by calling convention type for readability.
// Total: 60 probes covering all explored functions (minus non-math and 7+ param outliers).

const NUM_PROBES = 116;
var cnt = [1]u32{0} ** NUM_PROBES;

// Hook variables — one per probed function
// Cat 1: Scalar math
var h00: hook.Detour(TC2v) = .{}; // 0x4549C0 normalizeVector3
var h01: hook.Detour(SC1d) = .{}; // 0x41AE40 ScaleCoord div0.8
var h02: hook.Detour(SC1d) = .{}; // 0x41AE50 ScaleCoord div0.6
var h03: hook.Detour(SC1d) = .{}; // 0x41AE60 ScaleCoord mul0.8
var h04: hook.Detour(SC1d) = .{}; // 0x41AE70 ScaleCoord mul0.6
// Cat 4: Matrix multiply
var h05: hook.Detour(FC3r) = .{}; // 0x7BCA80 transformVector3ByMatrix4x4
var h06: hook.Detour(FC3r) = .{}; // 0x7BCB40 transformVector4ByMatrix4x4
var h07: hook.Detour(FC3r) = .{}; // 0x7BAE60 MultiplyMatrix3x4
var h08: hook.Detour(FC3r) = .{}; // 0x7BDFC0 multiplyMatrix3x3
var h09: hook.Detour(FC4r) = .{}; // 0x7BDB00 createAxisAngleRotationMatrix
var h10: hook.Detour(TC2r) = .{}; // 0x7BDC40 ApplyTranslationMatrix
var h11: hook.Detour(TC2r) = .{}; // 0x7BDCA0 scaleMatrix3x3ByVector
var h12: hook.Detour(TC2r) = .{}; // 0x7BDDB0 rotateMatrixByQuaternion
var h13: hook.Detour(FC4r) = .{}; // 0x7BE490 createAxisAngleRotMat3x3
var h14: hook.Detour(FC4r) = .{}; // 0x7BB860 CreateRotationMatrix 3x4
// Cat 5: Collision/spatial
var h15: hook.Detour(FC5r) = .{}; // 0x632830 RayPolygonIntersectionTest
var h16: hook.Detour(FC3d) = .{}; // 0x6329E0 CalculateDistanceToPlane
var h17: hook.Detour(FC5r) = .{}; // 0x632F80 CalcTrianglePlanesFromVerts
var h18: hook.Detour(FC2r) = .{}; // 0x6335D0 testPointTriangleCollision
var h19: hook.Detour(FC5r) = .{}; // 0x681B50 ProjectVerticesAndUpdateDepth
var h20: hook.Detour(TC3r) = .{}; // 0x686C20 ClassifyPointAgainstFrustum
var h21: hook.Detour(FC2r) = .{}; // 0x6856C0 ValidateGameObject
var h22: hook.Detour(FC3r) = .{}; // 0x686000 FrustumCullBoundingBox_0
var h23: hook.Detour(FC2r) = .{}; // 0x686180 FrustumCullBoundingBox_1
var h24: hook.Detour(FC3r) = .{}; // 0x6DC5A0 CheckBoxLineIntersection
var h25: hook.Detour(FC4r) = .{}; // 0x50A840 CalcOrthonormalBasis
var h26: hook.Detour(FC4r) = .{}; // 0x509220 CheckBoundingBoxCollision
var h27: hook.Detour(TC4r) = .{}; // 0x6869C0 TestOBBAgainstFrustum
var h28: hook.Detour(TC2r) = .{}; // 0x686B80 TestSphereAgainstFrustum
// Cat 6: Rendering pipeline
var h29: hook.Detour(FC4r) = .{}; // 0x6ABC40 processLinkedListCollision
var h30: hook.Detour(FC4r) = .{}; // 0x6ABE60 processSpecialObjCollision
var h31: hook.Detour(FC4r) = .{}; // 0x6AD7E0 frustumCullGeometry
var h32: hook.Detour(FC1v) = .{}; // 0x6AFAD0 UpdateEntityAndChunksPos
var h33: hook.Detour(FC3r) = .{}; // 0x6B7070 calculateWaterHeight
var h34: hook.Detour(FC4r) = .{}; // 0x6B8B70 checkBoundingBoxIntersect
var h35: hook.Detour(TC3r) = .{}; // 0x6B88E0 performCollisionDetection
var h36: hook.Detour(TC3r) = .{}; // 0x6B8C60 PerformSpatialCulling
var h37: hook.Detour(TC4v) = .{}; // 0x6BC370 SetupCylinderFrustum
var h38: hook.Detour(FC1v) = .{}; // 0x6C15D0 executeRenderCommands
// Cat 7: Bone/model
var h39: hook.Detour(FC4r) = .{}; // 0x71AE90 extractAnimByteFromKeyframes
var h40: hook.Detour(FC4r) = .{}; // 0x71AF20 getInterpolatedFloat
var h41: hook.Detour(TC2v) = .{}; // 0x71B6A0 normalizeVector3 (bone)
var h42: hook.Detour(TC2v) = .{}; // 0x71BC70 addVector3ToAccumulator
var h43: hook.Detour(TC2v) = .{}; // 0x71BF60 addToColorAccumulator
var h44: hook.Detour(FC1v) = .{}; // 0x71C160 transformLightsAndPlanes
var h45: hook.Detour(FC1v) = .{}; // 0x71C2F0 calculateFrustumPlanes
var h46: hook.Detour(TC2r) = .{}; // 0x71C4E0 calcSphericalHarmonics
var h47: hook.Detour(TC1v) = .{}; // 0x718960 renderSceneNode
var h48: hook.Detour(TC2v) = .{}; // 0x719370 updateAnimationSystem
var h49: hook.Detour(TC3r) = .{}; // 0x712D50 GetTransformedAnimPos
var h50: hook.Detour(TC2r) = .{}; // 0x713680 GetBoundingSphere
// Cat 8: Particle
var h51: hook.Detour(TC2r) = .{}; // 0x7B3A10 RenderParticleSystemSorted
var h52: hook.Detour(TC3v) = .{}; // 0x7B5A10 ProcessActiveParticles
var h53: hook.Detour(TC3v) = .{}; // 0x7B7E60 AdvanceParticles
// Cat 9: Geometry math
var h54: hook.Detour(FC4r) = .{}; // 0x7C0570 quaternion_slerp
var h55: hook.Detour(FC3r) = .{}; // 0x7C2040 point_sphere_collision_test
var h56: hook.Detour(FC5r) = .{}; // 0x7C22B0 ray_plane_intersection
var h57: hook.Detour(FC1v) = .{}; // 0x7C5880 calc_animation_orientation
// Misc
var h58: hook.Detour(FC3r) = .{}; // 0x70A060 compareRayHitData
var h59: hook.Detour(FC3r) = .{}; // 0x70AE10 compareRenderItemsExtended
// --- Batch 2: remaining explored functions ---
var h60: hook.Detour(TC2r) = .{}; // 0x4183D0 WritePointerToStream
var h61: hook.Detour(TC4r) = .{}; // 0x453480 AudioCallback_SetVolume
var h62: hook.Detour(TC5v) = .{}; // 0x453580 Vector3_InterpolateWeighted
var h63: hook.Detour(TC4r) = .{}; // 0x4541B0 interpolateVector3
var h64: hook.Detour(FC5r) = .{}; // 0x483340 UpdateLightingData
var h65: hook.Detour(FC6r) = .{}; // 0x509BF0 ClampBounds
var h66: hook.Detour(TC2r) = .{}; // 0x593040 VertexData_UpdateRenderState
var h67: hook.Detour(TC2d) = .{}; // 0x5C7010 ConvertPixelsToScreenAlt (returns float via x87)
var h68: hook.Detour(FC2r) = .{}; // 0x5E22D0 CheckPlayerInTriggerZone
var h69: hook.Detour(TC3r) = .{}; // 0x5F6280 InterpolateSpellPosition
var h70: hook.Detour(TC6v) = .{}; // 0x5F8DC0 CalculateRenderingBounds
var h71: hook.Detour(FC3r) = .{}; // 0x614CD0 UpdateObjectTransform (3 params, RET 0x4)
var h72: hook.Detour(TC4r) = .{}; // 0x616AF0 ValidatePositionUpdate
var h73: hook.Detour(FC1r) = .{}; // 0x616BF0 ValidateCoordinateBounds
var h74: hook.Detour(FC1r) = .{}; // 0x618920 GetUnitPositionBufIfValid
var h75: hook.Detour(FC1v) = .{}; // 0x675AC0 Weather_ProcessEnvironment
var h76: hook.Detour(TC2d) = .{}; // 0x67C820 GetCachedHeightValue
var h77: hook.Detour(TC2d) = .{}; // 0x67CA00 GetHeightFromCachedMap
var h78: hook.Detour(TC3v) = .{}; // 0x67CA90 SampleAndCacheHeightData
var h79: hook.Detour(TC4r) = .{}; // 0x67CB60 RaycastLineWithHeightCheck
var h80: hook.Detour(FC2v) = .{}; // 0x6818B0 AddObjectToSpatialList
var h81: hook.Detour(SC0v) = .{}; // 0x683F80 AllocateGameObject
var h82: hook.Detour(TC6v) = .{}; // 0x68B0D0 CalculateDetailDistances
var h83: hook.Detour(FC1v) = .{}; // 0x68D540 CalculateChunkVertices
var h84: hook.Detour(FC2r) = .{}; // 0x699330 IsPointInsideBounds
var h85: hook.Detour(FC2r) = .{}; // 0x69B1C0 GetTerrainDataAtPosition
var h86: hook.Detour(FC5r) = .{}; // 0x69B6D0 GetWaterSurfaceData
var h87: hook.Detour(TC2r) = .{}; // 0x6A8050 SetupRenderingTransforms
var h88: hook.Detour(FC6r) = .{}; // 0x6AADC0 procTerrainChunkMeshGen
var h89: hook.Detour(FC3d) = .{}; // 0x6CF6C0 interpolateKeyframes (3 params, not 4)
var h90: hook.Detour(FC2r) = .{}; // 0x6FA1A0 lua_table_hash_index
var h91: hook.Detour(FC2r) = .{}; // 0x6FA700 lua_table_get_array_elem
var h92: hook.Detour(FC2r) = .{}; // 0x6FA7A0 lua_table_lookup_key
var h93: hook.Detour(TC2r) = .{}; // 0x7B4BF0 SetParticleLifetime
var h94: hook.Detour(TC4v) = .{}; // 0x7B76C0 applyParticleWorldTransform
var h95: hook.Detour(TC4v) = .{}; // 0x7B8890 GenerateSphereParticle
var h96: hook.Detour(TC4v) = .{}; // 0x7B8D70 updateRibbonParticle
var h97: hook.Detour(TC4v) = .{}; // 0x7BA200 generateRandomParticle
// --- Batch 3: newly explored + previously skipped ---
var h98: hook.Detour(SC3v) = .{}; // 0x749280 calculateSinCos
var h99: hook.Detour(TC2r) = .{}; // 0x7BE5B0 createZRotationMatrix3x3
var h100: hook.Detour(FC3r) = .{}; // 0x76D680 SetupModelLighting
var h101: hook.Detour(TC2r) = .{}; // 0x7786A0 SetModelLighting (UI model ctor)
var h102: hook.Detour(FC5r) = .{}; // 0x69BFF0 CMap::VectorIntersect
var h103: hook.Detour(TC2r) = .{}; // 0x7BCEF0 getTransposedMatrix4x4
var h104: hook.Detour(TC2r) = .{}; // 0x7BB420 MultiplyMatrix3x4InPlace
var h105: hook.Detour(TC3r) = .{}; // 0x7B2A50 RenderParticleSprites
var h106: hook.Detour(FC5v) = .{}; // 0x7B7A80 packParticleColorToBytes (5 params, RET 0xC)
var h107: hook.Detour(FC3v) = .{}; // 0x7B7B10 setParticleAlphaFromFloat (3 params, RET 0x4)
var h108: hook.Detour(FC2d) = .{}; // 0x602630 Vector3_DotProduct
var h109: hook.Detour(FC1v) = .{}; // 0x686640 ComputeFrustumPlanesFromVerts
var h110: hook.Detour(TC2v) = .{}; // 0x686820 TranslateBoundingVolume
var h111: hook.Detour(TC2r) = .{}; // 0x6868E0 TransformBoundingVolume
var h112: hook.Detour(FC1v) = .{}; // 0x6720F0 NormalizeVector3_InPlace
// RenderTextToVertexBuffer: __thiscall, 10 params total (ECX + 9 stack)
const TC10r = fn (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32) callconv(TC) u32;
var h113: hook.Detour(TC10r) = .{}; // 0x5C8710 RenderTextToVertexBuffer
var h114: hook.Detour(SC2r) = .{}; // 0x40CF81 GetFPUControlWord
var h115: hook.Detour(CD0r) = .{}; // 0x40A2B0 __ftol (real)

/// Hand-written __ftol probe. ST(0) holds the implicit float input and must be
/// preserved across the counter increment. Saves/restores EAX as scratch to
/// hold absolute addresses — EAX is caller-saved in cdecl so this is safe
/// for the counter, then we restore it before jumping to the original.
fn ftolProbe() callconv(.naked) void {
    asm volatile (
        \\push %%eax
        \\mov %[cnt], %%eax
        \\lock addl $1, (%%eax)
        \\mov %[orig], %%eax
        \\mov (%%eax), %%eax
        \\xchg %%eax, (%%esp)
        \\ret
        :
        : [cnt] "i" (&cnt[115]),
          [orig] "i" (&h115.inner.trampoline),
    );
}

// ftolSSE2 compare mode removed — using direct byte patching via si_ftol now

const ProbeInfo = struct { name: [*:0]const u8, idx: u32 };

const probe_infos = [NUM_PROBES]ProbeInfo{
    .{ .name = "normalizeVector3", .idx = 0 },
    .{ .name = "ScaleCoord_div0.8", .idx = 1 },
    .{ .name = "ScaleCoord_div0.6", .idx = 2 },
    .{ .name = "ScaleCoord_mul0.8", .idx = 3 },
    .{ .name = "ScaleCoord_mul0.6", .idx = 4 },
    .{ .name = "transformVec3ByMat4", .idx = 5 },
    .{ .name = "transformVec4ByMat4", .idx = 6 },
    .{ .name = "MultiplyMatrix3x4", .idx = 7 },
    .{ .name = "multiplyMatrix3x3", .idx = 8 },
    .{ .name = "createAxisAngleRotMat4", .idx = 9 },
    .{ .name = "ApplyTranslationMatrix", .idx = 10 },
    .{ .name = "scaleMatrix3x3ByVec", .idx = 11 },
    .{ .name = "rotateMatByQuaternion", .idx = 12 },
    .{ .name = "createAxisAngleRotMat3", .idx = 13 },
    .{ .name = "CreateRotationMat3x4", .idx = 14 },
    .{ .name = "RayPolygonIntersect", .idx = 15 },
    .{ .name = "DistanceToPlane", .idx = 16 },
    .{ .name = "CalcTriPlanes", .idx = 17 },
    .{ .name = "testPointTriCollision", .idx = 18 },
    .{ .name = "ProjectVertsUpdateDepth", .idx = 19 },
    .{ .name = "ClassifyPointFrustum", .idx = 20 },
    .{ .name = "ValidateGameObject", .idx = 21 },
    .{ .name = "FrustumCullBBox_0", .idx = 22 },
    .{ .name = "FrustumCullBBox_1", .idx = 23 },
    .{ .name = "CheckBoxLineIntersect", .idx = 24 },
    .{ .name = "CalcOrthonormalBasis", .idx = 25 },
    .{ .name = "CheckBBoxCollision", .idx = 26 },
    .{ .name = "TestOBBFrustum", .idx = 27 },
    .{ .name = "TestSphereFrustum", .idx = 28 },
    .{ .name = "procLinkedListColl", .idx = 29 },
    .{ .name = "procSpecialObjColl", .idx = 30 },
    .{ .name = "frustumCullGeometry", .idx = 31 },
    .{ .name = "UpdateEntityChunksPos", .idx = 32 },
    .{ .name = "calcWaterHeight", .idx = 33 },
    .{ .name = "checkBBoxIntersect", .idx = 34 },
    .{ .name = "performCollisionDetect", .idx = 35 },
    .{ .name = "PerformSpatialCulling", .idx = 36 },
    .{ .name = "SetupCylinderFrustum", .idx = 37 },
    .{ .name = "executeRenderCommands", .idx = 38 },
    .{ .name = "extractAnimByte", .idx = 39 },
    .{ .name = "getInterpolatedFloat", .idx = 40 },
    .{ .name = "normalizeVec3_bone", .idx = 41 },
    .{ .name = "addVec3ToAccumulator", .idx = 42 },
    .{ .name = "addToColorAccumulator", .idx = 43 },
    .{ .name = "transformLightsPlanes", .idx = 44 },
    .{ .name = "calcFrustumPlanes", .idx = 45 },
    .{ .name = "calcSphericalHarmonics", .idx = 46 },
    .{ .name = "renderSceneNode", .idx = 47 },
    .{ .name = "updateAnimationSystem", .idx = 48 },
    .{ .name = "GetTransformedAnimPos", .idx = 49 },
    .{ .name = "GetBoundingSphere", .idx = 50 },
    .{ .name = "RenderParticleSorted", .idx = 51 },
    .{ .name = "ProcessActiveParticles", .idx = 52 },
    .{ .name = "AdvanceParticles", .idx = 53 },
    .{ .name = "quaternion_slerp", .idx = 54 },
    .{ .name = "pointSphereCollision", .idx = 55 },
    .{ .name = "rayPlaneIntersection", .idx = 56 },
    .{ .name = "calcAnimOrientation", .idx = 57 },
    .{ .name = "compareRayHitData", .idx = 58 },
    .{ .name = "compareRenderItems", .idx = 59 },
    .{ .name = "WritePointerToStream", .idx = 60 },
    .{ .name = "AudioCB_SetVolume", .idx = 61 },
    .{ .name = "Vec3_InterpWeighted", .idx = 62 },
    .{ .name = "interpolateVector3", .idx = 63 },
    .{ .name = "UpdateLightingData", .idx = 64 },
    .{ .name = "ClampBounds", .idx = 65 },
    .{ .name = "VtxData_UpdateRender", .idx = 66 },
    .{ .name = "ConvertPixelsToScreen", .idx = 67 },
    .{ .name = "CheckPlayerInTrigger", .idx = 68 },
    .{ .name = "InterpSpellPosition", .idx = 69 },
    .{ .name = "CalcRenderingBounds", .idx = 70 },
    .{ .name = "UpdateObjTransform", .idx = 71 },
    .{ .name = "ValidatePositionUpd", .idx = 72 },
    .{ .name = "ValidateCoordBounds", .idx = 73 },
    .{ .name = "GetUnitPosBufIfValid", .idx = 74 },
    .{ .name = "Weather_ProcessEnv", .idx = 75 },
    .{ .name = "GetCachedHeightValue", .idx = 76 },
    .{ .name = "GetHeightFromCached", .idx = 77 },
    .{ .name = "SampleCacheHeightData", .idx = 78 },
    .{ .name = "RaycastLineHeight", .idx = 79 },
    .{ .name = "AddObjToSpatialList", .idx = 80 },
    .{ .name = "AllocateGameObject", .idx = 81 },
    .{ .name = "CalcDetailDistances", .idx = 82 },
    .{ .name = "CalcChunkVertices", .idx = 83 },
    .{ .name = "IsPointInsideBounds", .idx = 84 },
    .{ .name = "GetTerrainDataAtPos", .idx = 85 },
    .{ .name = "GetWaterSurfaceData", .idx = 86 },
    .{ .name = "SetupRenderTransforms", .idx = 87 },
    .{ .name = "procTerrainChunkMesh", .idx = 88 },
    .{ .name = "interpolateKeyframes", .idx = 89 },
    .{ .name = "lua_table_hash_index", .idx = 90 },
    .{ .name = "lua_table_get_array", .idx = 91 },
    .{ .name = "lua_table_lookup_key", .idx = 92 },
    .{ .name = "SetParticleLifetime", .idx = 93 },
    .{ .name = "applyParticleWorldTx", .idx = 94 },
    .{ .name = "GenerateSphereParticle", .idx = 95 },
    .{ .name = "updateRibbonParticle", .idx = 96 },
    .{ .name = "generateRandomParticle", .idx = 97 },
    .{ .name = "calculateSinCos", .idx = 98 },
    .{ .name = "createZRotMat3x3", .idx = 99 },
    .{ .name = "SetupModelLighting", .idx = 100 },
    .{ .name = "SetModelLighting_ctor", .idx = 101 },
    .{ .name = "CMap_VectorIntersect", .idx = 102 },
    .{ .name = "getTransposedMat4x4", .idx = 103 },
    .{ .name = "MulMatrix3x4InPlace", .idx = 104 },
    .{ .name = "RenderParticleSprites", .idx = 105 },
    .{ .name = "packParticleColor", .idx = 106 },
    .{ .name = "setParticleAlpha", .idx = 107 },
    .{ .name = "Vector3_DotProduct", .idx = 108 },
    .{ .name = "ComputeFrustumPlanes", .idx = 109 },
    .{ .name = "TranslateBoundingVol", .idx = 110 },
    .{ .name = "TransformBoundingVol", .idx = 111 },
    .{ .name = "NormalizeVec3_InPlace", .idx = 112 },
    .{ .name = "RenderTextToVtxBuf", .idx = 113 },
    .{ .name = "GetFPUControlWord", .idx = 114 },
    .{ .name = "__ftol", .idx = 115 },
};

// =============================================================================
// Periodic reporting via OnWorldUpdate (0x482EA0)
// =============================================================================

const REPORT_FRAMES: u32 = 450; // ~7.5s at 60fps
var frame_counter: u32 = 0;

const WorldUpdateFn = fn (u32) callconv(FC) void;
var world_update_hook: hook.Detour(WorldUpdateFn) = .{};

fn worldUpdateDetour(frame_count: u32) callconv(FC) void {
    world_update_hook.callOriginal(.{frame_count});

    frame_counter +%= 1;
    if (frame_counter >= REPORT_FRAMES) {
        reportProbes();
        frame_counter = 0;
    }
}

// =============================================================================
// Module lifecycle
// =============================================================================

pub fn isActive() bool {
    return g_is_hook_owner;
}

pub fn installHooks() void {
    const result = mod_mutex.acquire(module_name);
    g_mutex = result.handle;
    g_is_hook_owner = result.is_owner;
    if (!g_is_hook_owner) return;
    log_state = logging.Logger.open(module_name, .both);

    // Binary-patch SSE replacements immediately at DLL load
    const patched = installPatches();
    log_state.fmt("silicon: {d} JMP patches installed\n", .{patched});
}

// =============================================================================
// Binary patching: write JMP rel32 at each game function to our SSE replacement.
// No trampoline, no CC translation — our functions use the game's native CC.
// =============================================================================

const sse = struct {
    // silicon_sse.zig exports (linked via object file)
    extern fn si_normalizeVec3(u32, u32) callconv(TC) void;
    extern fn si_mulMat3x4(u32, u32, u32) callconv(FC) u32;
    extern fn si_rotateMatByQuat(u32, u32) callconv(TC) u32;
    extern fn si_createRotMat3x4(u32, u32, u32, u32) callconv(FC) u32;
    extern fn si_distanceToPlane() callconv(.naked) void;
    extern fn si_classifyPointFrustum(u32, u32, u32) callconv(TC) u32;
    extern fn si_checkBoxLineIntersect(u32, u32, u32) callconv(FC) u32;
    extern fn si_testOBBFrustum(u32, u32, u32, u32) callconv(TC) u32;
    extern fn si_testSphereFrustum(u32, u32) callconv(TC) u32;
    extern fn si_quatSlerp(u32, u32, u32, u32) callconv(FC) u32;
    extern fn si_isPointInsideBounds() callconv(.naked) void;
    extern fn si_calculateSinCos(u32, u32, u32) callconv(SC) void;
    extern fn si_createZRotMat3x3(u32, u32) callconv(TC) u32;
    extern fn si_transposeMat4x4(u32, u32) callconv(TC) u32;
    extern fn si_mulMat3x4InPlace(u32, u32) callconv(TC) u32;
    extern fn si_normalizeVec3InPlace(u32) callconv(FC) void;
    extern fn si_addVec3ToAccumulator(u32, u32, u32) callconv(TC) void;
    extern fn si_addToColorAccumulator(u32, u32) callconv(TC) void;
    extern fn si_packParticleColor(u32, u32, u32, u32) callconv(FC) void;
    extern fn si_setParticleAlpha(u32, u32) callconv(FC) void;
    extern fn si_ftol() callconv(.naked) void;
    extern fn si_vec3Dot() callconv(.naked) void;
    extern fn si_translateBoundingVol(u32, u32) callconv(TC) void;
};

const PatchEntry = struct {
    target: u32,
    replacement: u32,
    name: [*:0]const u8,
    direct_size: u8 = 0, // >0: copy this many bytes directly (naked asm, no JMP)
};

fn getPatchTable() []const PatchEntry {
    const table = [_]PatchEntry{
        .{ .target = 0x4549C0, .replacement = @intFromPtr(&sse.si_normalizeVec3), .name = "normalizeVec3" },
        .{ .target = 0x7BAE60, .replacement = @intFromPtr(&sse.si_mulMat3x4), .name = "mulMat3x4" },
        .{ .target = 0x7BDDB0, .replacement = @intFromPtr(&sse.si_rotateMatByQuat), .name = "rotateMatByQuat" },
        .{ .target = 0x7BB860, .replacement = @intFromPtr(&sse.si_createRotMat3x4), .name = "createRotMat3x4" },
        // distanceToPlane (0x6329E0): removed — at parity, division dominates both versions
        .{ .target = 0x686C20, .replacement = @intFromPtr(&sse.si_classifyPointFrustum), .name = "classifyPointFrustum" },
        .{ .target = 0x6DC5A0, .replacement = @intFromPtr(&sse.si_checkBoxLineIntersect), .name = "checkBoxLineIntersect" },
        .{ .target = 0x6869C0, .replacement = @intFromPtr(&sse.si_testOBBFrustum), .name = "testOBBFrustum" },
        .{ .target = 0x686B80, .replacement = @intFromPtr(&sse.si_testSphereFrustum), .name = "testSphereFrustum" },
        .{ .target = 0x7C0570, .replacement = @intFromPtr(&sse.si_quatSlerp), .name = "quatSlerp" },
        // isPointInsideBounds (0x699330): removed — at parity, not worth patching
        .{ .target = 0x749280, .replacement = @intFromPtr(&sse.si_calculateSinCos), .name = "calculateSinCos" },
        .{ .target = 0x7BE5B0, .replacement = @intFromPtr(&sse.si_createZRotMat3x3), .name = "createZRotMat3x3" },
        .{ .target = 0x7BCEF0, .replacement = @intFromPtr(&sse.si_transposeMat4x4), .name = "transposeMat4x4", .direct_size = 64 },
        .{ .target = 0x7BB420, .replacement = @intFromPtr(&sse.si_mulMat3x4InPlace), .name = "mulMat3x4InPlace" },
        .{ .target = 0x6720F0, .replacement = @intFromPtr(&sse.si_normalizeVec3InPlace), .name = "normalizeVec3InPlace" },
        .{ .target = 0x71BC70, .replacement = @intFromPtr(&sse.si_addVec3ToAccumulator), .name = "addVec3ToAccumulator" },
        .{ .target = 0x71BF60, .replacement = @intFromPtr(&sse.si_addToColorAccumulator), .name = "addToColorAccumulator" },
        .{ .target = 0x7B7A80, .replacement = @intFromPtr(&sse.si_packParticleColor), .name = "packParticleColor" },
        .{ .target = 0x7B7B10, .replacement = @intFromPtr(&sse.si_setParticleAlpha), .name = "setParticleAlpha" },
        .{ .target = 0x40A2B0, .replacement = @intFromPtr(&sse.si_ftol), .name = "__ftol", .direct_size = 9 },
        // vec3Dot (0x602630): removed — 0.6x regression, x87 is optimal for this ABI
        .{ .target = 0x686820, .replacement = @intFromPtr(&sse.si_translateBoundingVol), .name = "translateBoundingVol" },
    };
    return &table;
}

fn installPatches() u32 {
    var count: u32 = 0;
    for (getPatchTable()) |entry| {
        if (entry.direct_size > 0) {
            // Direct byte copy: naked asm replacement fits in original
            const src: [*]const u8 = @ptrFromInt(entry.replacement);
            hook.writeProtected(entry.target, src[0..entry.direct_size]);
        } else {
            // JMP rel32: E9 XX XX XX XX
            const rel = @as(i32, @bitCast(entry.replacement -% entry.target -% 5));
            var patch = [5]u8{ 0xE9, 0, 0, 0, 0 };
            @as(*align(1) i32, @ptrCast(patch[1..5])).* = rel;
            hook.writeProtected(entry.target, &patch);
        }
        count += 1;
    }
    return count;
}

/// Called from engineInitDetour after engine is fully initialized.
pub fn lateInit() void {
    if (!g_is_hook_owner) return;

    var installed: u32 = 0;

    // Detour hooks for profiling probes (functions without SSE replacements)
    const INSTALL_PROBES = false; // disable probes when patching
    if (INSTALL_PROBES) {
        if (h00.attach(0x4549C0, &sseNormalizeVec3) == .ok) installed += 1; // 137K/7.5s
        if (h01.attach(0x41AE40, probeDetour(SC1d, &h01, &cnt[1])) == .ok) installed += 1;
        if (h02.attach(0x41AE50, probeDetour(SC1d, &h02, &cnt[2])) == .ok) installed += 1;
        if (h03.attach(0x41AE60, probeDetour(SC1d, &h03, &cnt[3])) == .ok) installed += 1;
        if (h04.attach(0x41AE70, probeDetour(SC1d, &h04, &cnt[4])) == .ok) installed += 1;
        // Cat 4: Matrix — SSE replacements
        if (h05.attach(0x7BCA80, &sseTransformVec3Mat4) == .ok) installed += 1; // 10.8M/7.5s
        if (h06.attach(0x7BCB40, &sseTransformVec4Mat4) == .ok) installed += 1; // 120K/7.5s
        if (h07.attach(0x7BAE60, &sseMulMat3x4) == .ok) installed += 1;
        if (h08.attach(0x7BDFC0, &sseMulMat3x3) == .ok) installed += 1;
        if (h09.attach(0x7BDB00, &sseCreateAxisAngleRotMat4) == .ok) installed += 1; // 304K/7.5s
        if (h10.attach(0x7BDC40, &sseApplyTranslation) == .ok) installed += 1; // 182K/7.5s
        if (h11.attach(0x7BDCA0, &sseScaleMat3x3) == .ok) installed += 1; // 1.3M/7.5s
        if (h12.attach(0x7BDDB0, &sseRotateMatByQuat) == .ok) installed += 1;
        if (h13.attach(0x7BE490, &sseCreateAxisAngleRotMat3x3) == .ok) installed += 1; // 13K/7.5s
        if (h14.attach(0x7BB860, &sseCreateRotMat3x4) == .ok) installed += 1;
        // Cat 5: Collision/spatial — SSE replacements
        if (h15.attach(0x632830, probeDetour(FC5r, &h15, &cnt[15])) == .ok) installed += 1; // RayPolygonIntersect — complex, keep probe
        if (h16.attach(0x6329E0, &sseDistanceToPlane) == .ok) installed += 1; // 525K/7.5s
        if (h17.attach(0x632F80, probeDetour(FC5r, &h17, &cnt[17])) == .ok) installed += 1;
        if (h18.attach(0x6335D0, probeDetour(FC2r, &h18, &cnt[18])) == .ok) installed += 1;
        if (h19.attach(0x681B50, probeDetour(FC5r, &h19, &cnt[19])) == .ok) installed += 1;
        if (h20.attach(0x686C20, &sseClassifyPointFrustum) == .ok) installed += 1; // 3.2M/7.5s
        if (h21.attach(0x6856C0, probeDetour(FC2r, &h21, &cnt[21])) == .ok) installed += 1;
        if (h22.attach(0x686000, probeDetour(FC3r, &h22, &cnt[22])) == .ok) installed += 1;
        if (h23.attach(0x686180, probeDetour(FC2r, &h23, &cnt[23])) == .ok) installed += 1;
        if (h24.attach(0x6DC5A0, &sseCheckBoxLineIntersect) == .ok) installed += 1; // 2.7M/7.5s
        if (h25.attach(0x50A840, probeDetour(FC4r, &h25, &cnt[25])) == .ok) installed += 1;
        if (h26.attach(0x509220, probeDetour(FC4r, &h26, &cnt[26])) == .ok) installed += 1;
        if (h27.attach(0x6869C0, &sseTestOBBFrustum) == .ok) installed += 1;
        if (h28.attach(0x686B80, &sseTestSphereFrustum) == .ok) installed += 1; // 375K/7.5s
        // Cat 6: Rendering
        if (h29.attach(0x6ABC40, probeDetour(FC4r, &h29, &cnt[29])) == .ok) installed += 1;
        if (h30.attach(0x6ABE60, probeDetour(FC4r, &h30, &cnt[30])) == .ok) installed += 1;
        if (h31.attach(0x6AD7E0, probeDetour(FC4r, &h31, &cnt[31])) == .ok) installed += 1;
        if (h32.attach(0x6AFAD0, probeDetour(FC1v, &h32, &cnt[32])) == .ok) installed += 1;
        if (h33.attach(0x6B7070, probeDetour(FC3r, &h33, &cnt[33])) == .ok) installed += 1;
        if (h34.attach(0x6B8B70, probeDetour(FC4r, &h34, &cnt[34])) == .ok) installed += 1;
        if (h35.attach(0x6B88E0, probeDetour(TC3r, &h35, &cnt[35])) == .ok) installed += 1;
        if (h36.attach(0x6B8C60, probeDetour(TC3r, &h36, &cnt[36])) == .ok) installed += 1;
        if (h37.attach(0x6BC370, probeDetour(TC4v, &h37, &cnt[37])) == .ok) installed += 1;
        if (h38.attach(0x6C15D0, probeDetour(FC1v, &h38, &cnt[38])) == .ok) installed += 1;
        // Cat 7: Bone/model
        if (h39.attach(0x71AE90, probeDetour(FC4r, &h39, &cnt[39])) == .ok) installed += 1;
        if (h40.attach(0x71AF20, probeDetour(FC4r, &h40, &cnt[40])) == .ok) installed += 1;
        if (h41.attach(0x71B6A0, probeDetour(TC2v, &h41, &cnt[41])) == .ok) installed += 1;
        if (h42.attach(0x71BC70, &sseAddVec3ToAccumulator) == .ok) installed += 1; // 136K/7.5s
        if (h43.attach(0x71BF60, &sseAddToColorAccumulator) == .ok) installed += 1;
        if (h44.attach(0x71C160, probeDetour(FC1v, &h44, &cnt[44])) == .ok) installed += 1;
        if (h45.attach(0x71C2F0, probeDetour(FC1v, &h45, &cnt[45])) == .ok) installed += 1;
        if (h46.attach(0x71C4E0, probeDetour(TC2r, &h46, &cnt[46])) == .ok) installed += 1;
        if (h47.attach(0x718960, probeDetour(TC1v, &h47, &cnt[47])) == .ok) installed += 1;
        if (h48.attach(0x719370, probeDetour(TC2v, &h48, &cnt[48])) == .ok) installed += 1;
        if (h49.attach(0x712D50, probeDetour(TC3r, &h49, &cnt[49])) == .ok) installed += 1;
        if (h50.attach(0x713680, probeDetour(TC2r, &h50, &cnt[50])) == .ok) installed += 1;
        // Cat 8: Particle
        if (h51.attach(0x7B3A10, probeDetour(TC2r, &h51, &cnt[51])) == .ok) installed += 1;
        if (h52.attach(0x7B5A10, probeDetour(TC3v, &h52, &cnt[52])) == .ok) installed += 1;
        if (h53.attach(0x7B7E60, probeDetour(TC3v, &h53, &cnt[53])) == .ok) installed += 1;
        // Cat 9: Geometry
        if (h54.attach(0x7C0570, &sseQuatSlerp) == .ok) installed += 1;
        if (h55.attach(0x7C2040, probeDetour(FC3r, &h55, &cnt[55])) == .ok) installed += 1;
        if (h56.attach(0x7C22B0, probeDetour(FC5r, &h56, &cnt[56])) == .ok) installed += 1;
        if (h57.attach(0x7C5880, probeDetour(FC1v, &h57, &cnt[57])) == .ok) installed += 1;
        // Misc
        if (h58.attach(0x70A060, probeDetour(FC3r, &h58, &cnt[58])) == .ok) installed += 1;
        if (h59.attach(0x70AE10, probeDetour(FC3r, &h59, &cnt[59])) == .ok) installed += 1;
        // Batch 2: remaining explored functions
        if (h60.attach(0x4183D0, probeDetour(TC2r, &h60, &cnt[60])) == .ok) installed += 1;
        if (h61.attach(0x453480, probeDetour(TC4r, &h61, &cnt[61])) == .ok) installed += 1;
        if (h62.attach(0x453580, probeDetour(TC5v, &h62, &cnt[62])) == .ok) installed += 1;
        if (h63.attach(0x4541B0, probeDetour(TC4r, &h63, &cnt[63])) == .ok) installed += 1;
        if (h64.attach(0x483340, probeDetour(FC5r, &h64, &cnt[64])) == .ok) installed += 1;
        if (h65.attach(0x509BF0, probeDetour(FC6r, &h65, &cnt[65])) == .ok) installed += 1;
        if (h66.attach(0x593040, probeDetour(TC2r, &h66, &cnt[66])) == .ok) installed += 1;
        // h67 disabled: 0x5C7010 ConvertPixelsToScreenAlt called with ECX=0 (valid), crashes thiscall probe
        // if (h67.attach(0x5C7010, probeDetour(TC2d, &h67, &cnt[67])) == .ok) installed += 1;
        if (h68.attach(0x5E22D0, probeDetour(FC2r, &h68, &cnt[68])) == .ok) installed += 1;
        if (h69.attach(0x5F6280, probeDetour(TC3r, &h69, &cnt[69])) == .ok) installed += 1;
        if (h70.attach(0x5F8DC0, probeDetour(TC6v, &h70, &cnt[70])) == .ok) installed += 1;
        if (h71.attach(0x614CD0, probeDetour(FC3r, &h71, &cnt[71])) == .ok) installed += 1;
        if (h72.attach(0x616AF0, probeDetour(TC4r, &h72, &cnt[72])) == .ok) installed += 1;
        if (h73.attach(0x616BF0, probeDetour(FC1r, &h73, &cnt[73])) == .ok) installed += 1;
        if (h74.attach(0x618920, probeDetour(FC1r, &h74, &cnt[74])) == .ok) installed += 1;
        if (h75.attach(0x675AC0, probeDetour(FC1v, &h75, &cnt[75])) == .ok) installed += 1;
        if (h76.attach(0x67C820, probeDetour(TC2d, &h76, &cnt[76])) == .ok) installed += 1;
        if (h77.attach(0x67CA00, probeDetour(TC2d, &h77, &cnt[77])) == .ok) installed += 1;
        if (h78.attach(0x67CA90, probeDetour(TC3v, &h78, &cnt[78])) == .ok) installed += 1;
        if (h79.attach(0x67CB60, probeDetour(TC4r, &h79, &cnt[79])) == .ok) installed += 1;
        if (h80.attach(0x6818B0, probeDetour(FC2v, &h80, &cnt[80])) == .ok) installed += 1;
        if (h81.attach(0x683F80, probeDetour(SC0v, &h81, &cnt[81])) == .ok) installed += 1;
        if (h82.attach(0x68B0D0, probeDetour(TC6v, &h82, &cnt[82])) == .ok) installed += 1;
        if (h83.attach(0x68D540, probeDetour(FC1v, &h83, &cnt[83])) == .ok) installed += 1;
        if (h84.attach(0x699330, &sseIsPointInsideBounds) == .ok) installed += 1; // 1.7M/7.5s
        if (h85.attach(0x69B1C0, probeDetour(FC2r, &h85, &cnt[85])) == .ok) installed += 1;
        if (h86.attach(0x69B6D0, probeDetour(FC5r, &h86, &cnt[86])) == .ok) installed += 1;
        if (h87.attach(0x6A8050, probeDetour(TC2r, &h87, &cnt[87])) == .ok) installed += 1;
        if (h88.attach(0x6AADC0, probeDetour(FC6r, &h88, &cnt[88])) == .ok) installed += 1;
        if (h89.attach(0x6CF6C0, probeDetour(FC3d, &h89, &cnt[89])) == .ok) installed += 1;
        if (h90.attach(0x6FA1A0, probeDetour(FC2r, &h90, &cnt[90])) == .ok) installed += 1;
        if (h91.attach(0x6FA700, probeDetour(FC2r, &h91, &cnt[91])) == .ok) installed += 1;
        if (h92.attach(0x6FA7A0, probeDetour(FC2r, &h92, &cnt[92])) == .ok) installed += 1;
        if (h93.attach(0x7B4BF0, probeDetour(TC2r, &h93, &cnt[93])) == .ok) installed += 1;
        if (h94.attach(0x7B76C0, probeDetour(TC4v, &h94, &cnt[94])) == .ok) installed += 1;
        if (h95.attach(0x7B8890, probeDetour(TC4v, &h95, &cnt[95])) == .ok) installed += 1;
        if (h96.attach(0x7B8D70, probeDetour(TC4v, &h96, &cnt[96])) == .ok) installed += 1;
        if (h97.attach(0x7BA200, probeDetour(TC4v, &h97, &cnt[97])) == .ok) installed += 1;

        // Batch 3: newly explored + previously skipped
        if (h98.attach(0x749280, &sseCalculateSinCos) == .ok) installed += 1;
        if (h99.attach(0x7BE5B0, &sseCreateZRotMat3x3) == .ok) installed += 1;
        if (h100.attach(0x76D680, probeDetour(FC3r, &h100, &cnt[100])) == .ok) installed += 1;
        if (h101.attach(0x7786A0, probeDetour(TC2r, &h101, &cnt[101])) == .ok) installed += 1;
        if (h102.attach(0x69BFF0, probeDetour(FC5r, &h102, &cnt[102])) == .ok) installed += 1;
        if (h103.attach(0x7BCEF0, &sseTransposeMat4x4) == .ok) installed += 1;
        if (h104.attach(0x7BB420, &sseMulMat3x4InPlace) == .ok) installed += 1;
        if (h105.attach(0x7B2A50, probeDetour(TC3r, &h105, &cnt[105])) == .ok) installed += 1;
        if (h106.attach(0x7B7A80, &ssePackParticleColor) == .ok) installed += 1;
        if (h107.attach(0x7B7B10, &sseSetParticleAlpha) == .ok) installed += 1;
        if (h108.attach(0x602630, &sseVec3Dot) == .ok) installed += 1;
        if (h109.attach(0x686640, probeDetour(FC1v, &h109, &cnt[109])) == .ok) installed += 1;
        if (h110.attach(0x686820, &sseTranslateBoundingVol) == .ok) installed += 1;
        if (h111.attach(0x6868E0, &sseTransformBoundingVol) == .ok) installed += 1;
        if (h112.attach(0x6720F0, &sseNormalizeVec3InPlace) == .ok) installed += 1;
        if (h113.attach(0x5C8710, probeDetour(TC10r, &h113, &cnt[113])) == .ok) installed += 1;
        // h114 (GetFPUControlWord 0x40CF81) — modifies FPU control word via FLDCW as side
        // effect; generic probe callOriginal wrapper may emit FPU instructions that corrupt
        // the control word state after the original returns. Needs naked asm like ftol.
        // if (h114.attach(0x40CF81, probeDetour(SC2r, &h114, &cnt[114])) == .ok) installed += 1;
    }
    // ftol patched directly via installPatches(), no detour needed

    // Periodic reporting hook
    if (world_update_hook.attach(0x482EA0, &worldUpdateDetour) == .ok) {
        log_state.print("silicon: world update reporter installed\n");
    }

    log_state.fmt("silicon: {d}/{d} probe hooks installed\n", .{ installed, @as(u32, NUM_PROBES) });
}

/// Dump probe hit counts and reset. Called periodically from worldUpdateDetour
/// and once from removeHooks on shutdown.
fn reportProbes() void {
    log_state.print("silicon: probe hit counts:\n");
    for (&probe_infos) |*info| {
        const c = @atomicRmw(u32, &cnt[info.idx], .Xchg, 0, .monotonic);
        if (c > 0) {
            log_state.fmt("  {s}: {d}\n", .{ info.name, c });
        }
    }
}

pub fn removeHooks() void {
    if (g_is_hook_owner) {
        world_update_hook.detach();
        reportProbes();
        log_state.close();
        mod_mutex.release(&g_mutex);
    }
    g_is_hook_owner = false;
}
