# Clickthrough Module Research

## Goal
Make game objects (mailboxes, refreshment tables, summon portals, etc.) clickable through units (players, pets) standing on top of them.

---

## Hit-test / Raycast Pipeline (Ghidra-verified)

### Full pipeline (every frame)
```
WorldFrameUpdate (0x481790) -- __thiscall(worldFrame, deltaTime)
  DispatchHeartbeatEvent()
  NameplateManager_UpdateAll()
  NDCToDDC(mouseNDC -> screenCoords)
  GetGameStateFlags() -> flag bits:
      0x04 = GOs, 0x08 = units, 0x10 = players, 0x40 = corpses
      Normal gameplay: 0x5c | terrain_bits
  HitTestPoint(worldFrame, screenX, screenY, &hitResult) -> hitType
    GetWorldPositionFromScreenCoords -> rayStart, rayEnd
    WorldIntersectionTest(rayStart, rayEnd, flags, &hitResult) -> hitType
      CWorld_Intersect(rayStart, rayEnd, 0, &hitPoint, &dist, queryFlags) -> terrain
      PerformRaycast(this, rayStart, rayEnd, flags, &hitDist, hitPos) -> GUID
        iterate renderable list at worldFrame+0x31c:
          CheckObjectTypePermissions(obj, flags) -- type bit filter
          IsValidInteractionTarget(obj) -- interactability check
          SearchNodeRecursive(node, interactable, obj) -- mark for spatial query
        raycastPickObjects(renderer, start, end, &dist, hitPos) -> closest hit
      closer-wins comparison: object dist vs terrain dist
      return 0 (nothing/terrain-normal), 1 (terrain-AoE), 2 (object)
  hitType dispatch:
    0: ResetCursor(), SetTargetGUID(0,0)
    1: HandleGroundTargeting (AoE spell reticle)
    2: HandleTargetSelection (0x4828D0) -- cursor + mouseover
```

### HandleTargetSelection (0x4828D0) -- __thiscall(worldFrame, hitResult*)
Resolves hit GUID to object, switches on type mask `*(*(obj+8)+8)`:
- `0x09` (OBJECT|UNIT): `SetCursorType(8)` -- attack/interact cursor
- `0x19` (OBJECT|UNIT|PLAYER): same handler -- `UpdateTargetInteractionCursor`
- `0x21` (OBJECT|GAMEOBJECT): `UpdateCursorForObject` -- GO-specific cursor
- `0x81` (OBJECT|CORPSE): `HandleTargetInteraction` -- loot cursor
- default: `ResetCursor()`
Then: `SetTargetGUID(worldFrame, guidLo, guidHi)` -- sets mouseover at worldFrame+0x340

### UpdateHitTest (0x481F00) -- __fastcall(worldFrame)
Called on **click events** (not every frame). Runs HitTestPoint and stores result
persistently at worldFrame+0x350 (hitType), +0x358 (GUID), +0x360 (position).

### CheckObjectTypePermissions (0x480780)
Switches on object type mask, checks flag bits:
- 0x09 (unit): allowed if `flags & 0x08`, then `CanTargetEntity`
- 0x19 (player): allowed if `flags & 0x10`, then `CanTargetEntity`
- 0x21 (GO): allowed if `flags & 0x04`, always true in normal mode
- 0x81 (corpse): allowed if `flags & 0x40`

### IsValidInteractionTarget (0x480C90)
- Units (0x09/0x19): health > 0 OR connection state valid
- GOs (0x21): `CallSpellCastHandler(obj)` -- same as minimapicons uses
- Corpses (0x81): `IsTargetInteractable(obj)`

### HitTestResult struct layout (from hitResult*)
| Offset | Type | Field |
|--------|------|-------|
| +0x00 | u64 | GUID (lo + hi) |
| +0x08 | Vec3 | Hit position (X, Y, Z) |
| +0x14 | f32 | Hit distance |
| +0x18 | Vec3 | Ray origin |
| +0x24 | Vec3 | Ray end |
| +0x30 | f32 | Ray length |

---

## Bounding Sphere / Click Volume (Ghidra-verified)

### How raycastPickObjects tests each object
`raycastPickObjects` (0x7089C0) iterates nodes linked via `node+0x418`.
For each node, it reads bounding data and performs a **bounding sphere test**:

```
model_data = *(*(node+0x30) + 0x130)

if *(node+0x410) == 3:
    bounds_ptr = model_data + 0xd0       // collision bounds
else:
    geoset_idx = *(*(node+0x90) + 0xa4)
    array_base = *(model_data + 0x20)
    bounds_ptr = array_base + geoset_idx * 0x44 + 0x24   // submesh bounds

// bounds_ptr points to 7 floats: AABB min(3), AABB max(3), radius(1)
center = (min + max) * 0.5
radius = bounds_ptr[6]

// Fallback when radius == 0: use model-level bounds
if radius == 0:
    min = model_data+0xb4, max = model_data+0xc0
    radius = *(model_data+0xcc)

// Transform center by per-instance world matrix at node+0xFC
world_center = transform(center, node+0xFC)

// Scale radius by matrix scale
scale_sq = mat[0]^2 + mat[1]^2 + mat[2]^2
sphere_radius_sq = scale_sq * radius^2

// Standard ray-sphere intersection test
if perpendicular_distance^2 <= sphere_radius_sq:
    add to hit list with entry/exit distances
```

After all nodes tested: `heapSort` by distance, test detailed geometry for top hits.

### Scene node structure (partial)
| Offset | Type | Field |
|--------|------|-------|
| +0x10 | u32 | Some flags (checked != 0 as prerequisite) |
| +0x2c | u32* | Parent container pointer |
| +0x30 | u32* | Model/resource pointer (->+0x130 = model data) |
| +0x40 | u32 | Some ID (compared to renderer+0x10) |
| +0x90 | u32* | Geoset/animation state pointer (->+0xa4 = geoset index) |
| +0xFC | mat4 | Per-instance world transform matrix (16 floats) |
| +0x1cc | u32 | Additional flag for type==3 path |
| +0x1dc | u32* | Child list head (for SearchNodeRecursive) |
| +0x1e4 | u32* | Next sibling |
| +0x410 | u32 | Enable flag (1=normal, 3=collision bounds, set by setPositionAndListStatus) |
| +0x414 | u32* | Spatial query linked list prev |
| +0x418 | u32* | Spatial query linked list next |
| +0x41c | u32* | Parent render object pointer |
| +0x420 | u32* | Interactability flag pointer |

### Model data bounding offsets (at *(*(node+0x30) + 0x130))
| Offset | Type | Field |
|--------|------|-------|
| +0x20 | u32 | Offset to submesh/geoset data array |
| +0xb4 | Vec3 | Model bounding box min (fallback) |
| +0xc0 | Vec3 | Model bounding box max (fallback) |
| +0xcc | f32 | Model bounding sphere radius (fallback) |
| +0xd0 | 7xf32 | Collision bounds: AABB min, max, radius |

### Submesh entry (0x44 bytes each, at *(model_data+0x20))
| Offset | Type | Field |
|--------|------|-------|
| +0x24 | Vec3 | Submesh AABB min |
| +0x30 | Vec3 | Submesh AABB max |
| +0x3c | f32 | Submesh bounding sphere radius |

### Key insight: bounds are per-MODEL, not per-instance
The bounding data comes from model data (shared by all instances of the same
model). Per-instance differences are only in the world transform matrix at
node+0xFC (position, rotation, scale).

For our target GOs (mailboxes, portals, refreshment tables), each GO type uses
a **unique model**, so modifying the model bounding radius effectively targets
only that GO type. No other objects share these models.

### Modification strategy
1. Use ManageRenderListNode hook (already exists in outline) to identify models
   owned by target GOs (resolve model+0x28 -> game object -> check type/entry)
2. Locate model data via `*(*(node+0x30) + 0x130)` or equivalent from model ptr
3. Enlarge bounding sphere radius at model_data+0xcc (and/or submesh radius at
   submesh+0x3c) to extend the clickable volume above/around units
4. Only needs to be done once per model (cached), not every frame

**Pros**: No function hooks needed for the actual click path, purely data
modification on model load. Uses existing ManageRenderListNode hook pattern.
The raycast engine naturally picks the GO because its enlarged bounds overlap
the unit's position.

**Cons**: Per-model (not per-instance), but target GO models are unique.
Need to determine appropriate radius enlargement values. Visual rendering
is NOT affected -- only the click/pick bounding sphere changes.

---

## Approach 1: Hook RightClickUnit (REJECTED -- Warden risk)

Hook `RightClickUnit` (0x60BEA0) `__thiscall(unit, autoloot)`. When a player
right-clicks a friendly player or player-summoned unit, search for nearby
interactable GOs and redirect to `RightClickObject` (0x5F8660) instead.

**Pros**: Simple, clean, only affects right-clicks on units
**Cons**: Hooking RightClickUnit is a sensitive game function that Warden may
monitor. Could cause false positives for server anti-cheat.

**Note**: `interact.zig` does NOT hook RightClickUnit -- it calls it directly
from Lua-triggered functions (InteractNearest, LootAllCorpses). Those are
player-initiated, not intercepting game click dispatch.

---

## Approach 2: Hit-test post-processing (VIABLE -- cursor-level filtering)

Hook `HandleTargetSelection` (0x4828D0, per-frame) and `UpdateHitTest`
(0x481F00, on-click) to post-process the raycast result. When the hit object
is a unit/player, scan for a nearby interactable GO and swap the GUID.

### HandleTargetSelection hook
- Read GUID from hitResult[0..1]
- Resolve to object, check type mask
- If unit (0x09) or player (0x19): scan visible GOs near hit position
- If interactable GO found within ~3-5 yards, write GO GUID into hitResult
- Call original -- now sees the GO, sets GO cursor + mouseover

### UpdateHitTest hook
- Call original (stores result at worldFrame+0x350/0x358/0x360)
- Read hitType from worldFrame+0x350; if type 2 (object):
- Read GUID from worldFrame+0x358; resolve, check type
- If unit/player, scan for nearby GO
- If found, overwrite worldFrame+0x358 with GO GUID

### GO scan
Iterate object manager for type 5 (game_object) within radius of hit position.
Check interactability with `CallSpellCastHandler` (0x5f8800). Return closest.

**Pros**: UI-level hooks (not security-sensitive), handles both cursor and click,
transparent to the player
**Cons**: Two hooks, per-frame GO scan when hovering units (mitigated: only scans
when cursor is over a unit, and the scan is a simple object list iteration)

---

## Approach 3: Model bounding radius enlargement (PREFERRED)

Enlarge the bounding sphere radius in model data for specific GO models so the
GO's clickable volume extends above/around units standing on it. The raycast
engine naturally picks the GO because its enlarged bounds encompass the cursor
position that would otherwise hit the unit.

### Implementation
1. Hook ManageRenderListNode (already hooked by outline module)
2. When a model is added to the render list, resolve its owner (model+0x28)
3. If owner is a GO of interest (mailbox, portal, refreshment table):
   a. Get model data: `*(model + 0x130)` (or via node+0x30 chain)
   b. Read current radius at model_data+0xcc
   c. If not already enlarged, multiply by enlargement factor (e.g. 3x-5x)
   d. Mark as modified (avoid re-enlarging)
4. The GO is now clickable over a much larger area

### What to enlarge
- `model_data+0xcc`: model-level bounding sphere radius (fallback path)
- Submesh bounds at `*(model_data+0x20) + geoset*0x44 + 0x3c`: per-geoset radius
- Both should be enlarged for consistent behavior

### Target GOs (unique models -- safe to modify)
- Mailboxes (GO type 19): unique mailbox models
- Refreshment Table (summoned by mage): unique table model
- Meeting Stone / Summon Portal: unique portal model
- Healthstone / Soulwell: unique cauldron model
- Other player-summoned utility GOs

### Open questions
- What is the relationship between model ptr (from ManageRenderListNode)
  and the model data buffer? Is model+0x130 always the M2 loaded data?
  (Confirmed in main.zig loadModelAsyncDetour: model+0x130 = buffer ptr)
- What enlargement factor is needed to reliably extend above a player model?
  Player bounding sphere is ~2 yards radius. GO might need 5-8 yard radius.
- Does enlarging radius affect anything other than click picking? (Probably
  not -- the render pipeline uses its own bounds for culling, separate from
  the pick bounds in the spatial query system)

**Pros**: No hooks on click/interaction functions. Purely data modification.
Uses existing ManageRenderListNode hook. Transparent to player. No per-frame
scanning cost. Warden-safe (modifying model data, not game functions).

**Cons**: Per-model not per-instance (acceptable for unique GO models).
Need to verify model data pointer chain from ManageRenderListNode context.

### Lifecycle: per-frame flag/restore pattern
Models whose bounding radius we enlarge must be restored when the GO is no
longer present (despawned, out of range, logout). The pattern:

1. **Pre-render hook** (e.g. WorldFrameUpdate or SceneEnd): clear a "seen this
   frame" flag on all tracked modified models.
2. **Object enumeration** (same style as minimapicons per-frame GO iteration):
   iterate visible objects, identify target GOs, resolve to model, set flag.
   If model radius not yet enlarged, enlarge it now. Mark model as "seen".
3. **Post-render hook** (or end of same frame): iterate tracked models. Any
   model NOT flagged this frame has its GO gone -- restore original radius,
   remove from tracking.

This ensures:
- Models are only enlarged while their GO is visible
- Logout/map change/despawn automatically restores all models
- No stale enlarged bounds persist across sessions
- Similar to how minimapicons tracks blips per-frame with a fresh scan

---

## Approach 4: Lua-only / Keybind approach (SAFE fallback)

Provide `InteractNearestGO()` Lua function (like InteractNearest but GO-only).
Player binds it to a key. When pressed, finds nearest interactable GO and calls
RightClickObject on it.

**Pros**: Zero Warden risk (same pattern as existing InteractNearest), player-initiated
**Cons**: Requires keybind, not transparent click-through

---

## Key Addresses

### Raycast pipeline
- `WorldFrameUpdate`: 0x481790 `__thiscall(worldFrame, deltaTime)`
- `HitTestPoint`: 0x481190 `__thiscall(worldFrame, screenX, screenY, *hitResult) -> hitType`
- `WorldIntersectionTest`: 0x480DF0 `(rayStart, rayEnd, flags, *hitResult) -> hitType`
- `PerformRaycast`: 0x480A50 `__thiscall(this, start, end, flags, *hitDist, hitPos) -> GUID`
- `CheckObjectTypePermissions`: 0x480780 `(objectData, permFlags) -> bool`
- `IsValidInteractionTarget`: 0x480C90 `__fastcall(obj) -> bool`
- `raycastPickObjects`: 0x7089C0 `__thiscall(renderer, start, end, *dist, hitPos) -> node*`
- `GetGameStateFlags`: 0x481050 `() -> uint`
- `SearchNodeRecursive`: 0x480D90
- `setPositionAndListStatus`: 0x713CB0 `__thiscall(node, enable, interactable, parent)`

### Cursor / mouseover
- `HandleTargetSelection`: 0x4828D0 `__thiscall(worldFrame, hitResult*)`
- `UpdateHitTest`: 0x481F00 `__fastcall(worldFrame)`
- `SetTargetGUID`: 0x482090 `__thiscall(worldFrame, guidLo, guidHi)`
- `SetCursorType`: 0x523C20 `__fastcall(cursorId)`
- `ResetCursor`: 0x523D30

### Interaction
- `RightClickUnit`: 0x60BEA0 `__thiscall(unit, autoloot)`
- `RightClickObject`: 0x5F8660 `__thiscall(obj, autoloot)`
- `CallSpellCastHandler`: 0x5F8800 `__fastcall(obj_ECX) -> char(bool)`
- `GetObjectPointer`: 0x464870 `__stdcall(guidLo, guidHi) -> objPtr`

### WorldFrame data
- WorldFrame ptr: `*(u32*)0xB4B2BC`
- Mouseover GUID: worldFrame+0x340 (8 bytes)
- Click hitType: worldFrame+0x350
- Click GUID: worldFrame+0x358
- Click hit pos: worldFrame+0x360 (Vec3)
- Renderable list: worldFrame+0x31c

### Object data
- `GetWorldPositionFromScreenCoords`: 0x4813B0
- `CWorld_Intersect`: 0x672170
- `Input_GetMouseScreenCoordinates`: 0x42CDE0
- Unit position: obj+0x9B8 (y), +0x9BC (x), +0x9C0 (z)
- GO position: *(obj+0x110)+0x24 (y), +0x28 (x), +0x2C (z)
- Object type at obj+0x14: 3=unit, 4=player, 5=game_object
- Type mask at *(obj+0x8)+0x8: 0x09=unit, 0x19=player, 0x21=GO, 0x81=corpse
- OBJECT_FIELD_SCALE_X: *(obj+0x8)+0x10 (float)
- UNIT_FIELD_SUMMONEDBY: *(obj+0x8)+0x30 (u64 GUID)

### Model / render pipeline (from outline module)
- `CM2Model_ManageRenderListNode`: 0x710B90 `__thiscall(model, addToList)`
- MODEL_OWNER_DIRECT: model+0x28
- MODEL_OWNER_CALLBACK: model+0x3C0
- Model data buffer: model+0x130 (ptr), model+0x134 (size)
- Model bounding box: model_data+0xb4 (min), +0xc0 (max), +0xcc (radius)
- Collision bounds: model_data+0xd0 (AABB min, max, radius -- 7 floats)
- Submesh array: *(model_data+0x20), each entry 0x44 bytes
- Submesh bounds: entry+0x24 (AABB min, max), entry+0x3c (radius)

### Vanilla 1.12.1 DBC note
GameObjectDisplayInfo.dbc does NOT contain geo box/bounds in vanilla (added in
WoTLK). Server uses custom `gameobject_display_info_addon` DB table. Client
derives clickable bounds from the M2 model header bounding data.

---

## GO Model Struct Investigation (2026-03-09)

### Problem: model+0x130 is NOT the M2 data pointer for GO models

The raycast research established `*(model + 0x130)` as the M2 data buffer for
unit models. However, runtime testing shows GO (mailbox) models have a **float**
at +0x130, not a pointer. The struct layout differs between unit and GO models.

### Hook architecture (working)

Three hooks, frame execution order:
1. **ManageRenderListNode** (0x710B90) — render phase, fires first
2. **CGObjectIsDisabled** (0x614EA0) — fires AFTER ManageRenderListNode
3. **SceneEnd** (0x5A17A0) — end of frame

Because CGObjectIsDisabled fires after ManageRenderListNode, target GO pointers
are collected one frame late. Solved with a deferred-clear flag: SceneEnd sets
`target_go_needs_clear`, first CGObjectIsDisabled call of next frame clears the
list. ManageRenderListNode sees previous frame's targets (GOs don't move).

### Model back-pointer matching (confirmed working)

- `model+0x28` (MODEL_OWNER_DIRECT) matches GO object pointers from object manager
- Value comparison only — no dereferencing of back-pointers needed
- `model+0x3C0` (MODEL_OWNER_CALLBACK) is garbage for GO models (unit-only field)

### CGObjectIsDisabled (0x614EA0) — per-object visibility hook

- `__thiscall(object_ECX) -> u32` (0=render, 1=disabled)
- Fires for every visible object (not just GOs — check obj+0x14 == 5)
- ~420-500 calls per frame in a typical scene
- ~280 of those are GOs
- Gives object pointer directly — no GUID resolution needed

### Matched GO model struct dump (mailbox, go_type=19, entry=173221)

Model at 0x34e46808, owner at +0x28 = GO object pointer (confirmed match).

```
+0x000: 00000002 00000000 34e47014 32a3d808   ; [0]=refcount/type?, [8]=nearby alloc, [C]=heap
+0x010: 00000001 00000001 00000001 00000000   ; flags
+0x020: 00000000 00000000 32a03a38 14692008   ; [28]=OWNER_DIRECT (GO ptr!), [2C]=heap
+0x030: 32948408 00000000 00000000 3b5b500c   ; [30]=heap
+0x040: 000000df 00000000 ...                 ; [40]=0xDF=223
+0x070: 005f7df0 ...                          ; [70]=code addr (CGGameObject method?)
+0x090: 3294500c 32944c10 32944808 32944818   ; cluster of heap ptrs (bone/submesh?)
+0x0a0: 00000000 32944828 329448c8 00000000
+0x0b0: ... 00000001 bf31d52a bf3826a5 ...    ; start of transform floats
+0x0c0: ... 3f3826a5 bf31d52a ...             ; rotation matrix
+0x0e0: 3f800000 00000000 44c9f28f c5893ccd   ; [E8]=world X≈1615.8, [EC]=Y≈-4391.6
+0x0f0: 4121ba5e ...                          ; [F0]=Z≈10.1
+0x0fc-0x13c: world transform matrix (identity-like with position)
+0x130: bd8bc000 41cdb480 3f800000 3f800000   ; [130]=FLOAT(-0.068), NOT a pointer!
+0x150-0x180: scale/blend floats (1.0f pattern)
+0x190: 3f0a8a8b 3ed8d8da 3f0a8a8b 3f800000   ; color/tint values
+0x1c0: ... 00000001 ...
+0x1f0: 00000000 005f7da0 ...                 ; [1F4]=code addr (CGGameObject vtable?)
```

### Key observation: raycast uses SCENE NODE, not model directly

Re-reading the raycast code: `raycastPickObjects` iterates **scene nodes**
linked via node+0x418. The model data path is:
```
model_data = *(*(node+0x30) + 0x130)
```
Where `node+0x30` is a "model/resource pointer" — this is NOT the same as the
CM2Model pointer from ManageRenderListNode ECX! The scene node at +0x30 points
to a different struct (the resource/loaded model), and THAT struct has the M2
data at +0x130.

**Next step**: Use Ghidra to trace from the GO object → scene node → +0x30
resource pointer → +0x130 M2 data, to find the correct indirection chain from
the CM2Model pointer we have in ManageRenderListNode.
