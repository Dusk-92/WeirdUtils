# Data Flow Map: Outline and Overlay Detection System

This document maps how the DLL detects and gathers information for rendering outlines on corpses, targets, and raid-marked units.

## Overview

The system uses multiple data sources and hooks to identify which models should receive outline rendering:

1. **Object Manager Iteration** - Scans all visible game objects each frame
2. **WoW Function Calls** - Uses native game functions for GUID/object resolution
3. **Direct Memory Reads** - Reads game structures at known offsets
4. **Model Render Hooks** - Intercepts WoW's rendering pipeline to associate models with objects

---

## High-Level Data Flow

```mermaid
flowchart TB
    subgraph FrameStart["Frame Start (RenderDeadOverlay)"]
        Reset["ModelOutline_ResetFrame()"]
        ClearTarget["ModelOutline_ClearTarget()"]
        ClearRaid["ModelOutline_ClearRaidMarked() (throttled 100ms)"]
        CacheRaid["wow_cache_raid_targets()"]
    end

    subgraph Detection["Object Detection Loop"]
        ObjFirst["wow_object_first()"]
        ObjNext["wow_object_next()"]
        ObjType["wow_object_type()"]

        subgraph PlayerCheck["Player Processing"]
            IsDead["wow_unit_is_dead()"]
            IsFriendly["wow_unit_is_friendly()"]
            GetGUID["wow_object_guid()"]
            GetModel["Read model ptr @ +0xD8, +0xDC"]
            GetRaidMark["wow_get_raid_target_index()"]
        end

        subgraph CorpseCheck["Corpse Processing"]
            IsSkeleton["wow_corpse_is_skeleton()"]
            OwnerGUID["wow_corpse_owner_guid()"]
            OwnerLookup["wow_get_object_by_guid()"]
            GroupCheck["wow_is_guid_in_group()"]
        end

        subgraph TargetCheck["Target Processing"]
            GetTarget["wow_get_target()"]
            TargetType["wow_object_type()"]
            IsEnemy["!wow_unit_is_friendly()"]
            IsEnemyPet["wow_unit_is_enemy_pet()"]
        end

        subgraph UnitCheck["NPC/Unit Processing"]
            UnitGUID["wow_object_guid()"]
            UnitRaidMark["wow_get_raid_target_index()"]
        end
    end

    subgraph Registration["Model Registration"]
        AddDead["ModelOutline_AddDeadPlayer(GUID)"]
        AddDeadModel["ModelOutline_AddDeadPlayerModel(ptr)"]
        AddRaidMark["ModelOutline_AddRaidMarkedModel(ptr, index)"]
        SetTarget["ModelOutline_SetTargetModel(ptr)"]
        SetOwner["ModelOutline_SetModelOwner(ptr, obj)"]
    end

    subgraph RenderHooks["Render Hook Pipeline"]
        ManageRender["CM2Model_ManageRenderListNode Hook"]
        DrawBatchProj["DrawBatchProj Hook"]
        DIPHook["DrawIndexedPrimitive Hook"]
    end

    subgraph Storage["Tracking Storage"]
        GUIDSet["g_deadPlayerGUIDs (unordered_set)"]
        ModelSet["g_deadPlayerModels (unordered_set)"]
        RaidMap["g_raidMarkedModels (unordered_map)"]
        OwnerMap["g_modelToOwner (unordered_map)"]
        TargetVar["g_targetModel, g_targetModelAlt"]
        FrameSet["g_frameDeadModels (per-frame)"]
    end

    FrameStart --> Detection
    Detection --> Registration
    Registration --> Storage
    Storage --> RenderHooks
```

---

## Memory Address Sources

```mermaid
flowchart LR
    subgraph GlobalPointers["Global Pointers (wow_1121.h)"]
        ObjMgr["0x00B41414 - Object Manager Ptr"]
        WorldFrame["0x00B4B2BC - World Frame Ptr"]
        RaidArray["0x00B71368 - Raid Target Array (8 GUIDs)"]
        RaidTex["0x00CE878C - Raid Target Texture Ptr"]
    end

    subgraph Functions["Native WoW Functions"]
        WorldToScreen["0x00483EE0 - WorldToScreen"]
        DDCtoNDC["0x0041ADE0 - DDC_to_NDC"]
        UnitGUIDFunc["0x00515970 - UnitGUID('player','target')"]
        GetObjByGUID["0x00464870 - GetObjectByGUID"]
        UnitReaction["0x006061E0 - UnitReaction"]
        GetUnitName["0x00609210 - CGUnit::GetUnitName"]
        GetObjName["0x006264E0 - GetObjectName"]
    end

    subgraph HookTargets["Hook Target Addresses"]
        RenderDraw["0x0070B360 - CM2SceneRenderDraw"]
        ManageList["0x00710B90 - CM2Model_ManageRenderListNode"]
        DrawBatch["0x0070CF70 - DrawBatch"]
        DrawBatchP["0x0070CB30 - DrawBatchProj"]
        NameplateVB["0x006C724A - Nameplate VB Hook"]
    end

    subgraph ObjectOffsets["Object Memory Offsets"]
        ObjType2["Object+0x14 - Type"]
        ObjGUID["Object+0x30 - GUID (8 bytes)"]
        UnitDesc["Unit+0x110 - Descriptor Ptr"]
        UnitMove["Unit+0x118 - Movement Ptr"]
        ModelD8["Unit+0xD8 - Model Ptr (primary)"]
        ModelDC["Unit+0xDC - Model Ptr (secondary)"]
        Scale1["Unit+0x90 - Scale Factor 1"]
        Scale2["Unit+0xBC - Scale Factor 2"]
    end

    subgraph DescriptorOffsets["Descriptor Field Offsets"]
        HP["Descriptor+0x40 - Current HP"]
        MaxHP["Descriptor+0x48 - Max HP"]
        Flags["Descriptor+0x224 - Unit Flags"]
        Summoned["Descriptor+0x18 - UNIT_FIELD_SUMMONEDBY"]
        DuelArb["Descriptor+0x2D8 - PLAYER_DUEL_ARBITER"]
    end

    subgraph CorpseOffsets["Corpse Field Offsets"]
        CorpseDesc["Corpse+0x8 - Descriptor Ptr"]
        CorpseOwner["Desc+0x18 - Owner GUID"]
        CorpsePosX["Desc+0x24 - Position X"]
        CorpsePosY["Desc+0x28 - Position Y"]
        CorpsePosZ["Desc+0x2C - Position Z"]
        CorpseFlags["Desc+0x8C - Corpse Flags"]
    end
```

---

## Detection Flow by Category

### Dead Player Detection

```mermaid
flowchart TB
    Start["Object Iteration"] --> CheckType{"Object Type?"}

    CheckType -->|"Type 4 (Player)"| CheckDead{"wow_unit_is_dead()"}
    CheckType -->|"Type 7 (Corpse)"| ProcessCorpse
    CheckType -->|Other| NextObj

    CheckDead -->|Dead| CheckFriendly{"wow_unit_is_friendly()"}
    CheckDead -->|Alive| RemoveTracking["Remove from tracking<br/>(handles resurrection)"]

    CheckFriendly -->|Friendly| ReadPlayerData["Read GUID @ +0x30<br/>Read Model @ +0xD8, +0xDC"]
    CheckFriendly -->|Enemy| NextObj["Next Object"]

    ReadPlayerData --> RegisterDead["ModelOutline_AddDeadPlayer(GUID)<br/>ModelOutline_AddDeadPlayerModel(ptr)<br/>ModelOutline_SetModelOwner(ptr, obj)"]

    subgraph CorpseFlow["Corpse Processing"]
        ProcessCorpse --> CheckSkeleton{"wow_corpse_is_skeleton()?"}
        CheckSkeleton -->|Yes| NextObj
        CheckSkeleton -->|No| GetOwner["wow_corpse_owner_guid()"]

        GetOwner --> FindOwner{"wow_get_object_by_guid()"}
        FindOwner -->|Found| CheckOwnerFriendly{"wow_unit_is_friendly(owner)"}
        FindOwner -->|Not Found| CheckGroup{"wow_is_guid_in_group(guid)"}

        CheckOwnerFriendly -->|Friendly| ReadCorpseModel["Read Model @ +0xD8, +0xDC"]
        CheckOwnerFriendly -->|Enemy| NextObj

        CheckGroup -->|In Group| ReadCorpseModel
        CheckGroup -->|Not In Group| NextObj

        ReadCorpseModel --> RegisterCorpse["ModelOutline_AddDeadPlayer(ownerGUID)<br/>ModelOutline_AddDeadPlayerModel(ptr)"]
    end

    RegisterDead --> NextObj
    RegisterCorpse --> NextObj
    RemoveTracking --> NextObj
```

### Target Detection

```mermaid
flowchart TB
    Start["Frame Start"] --> GetTarget["wow_get_target()"]

    GetTarget --> CheckValid{"targetObj != 0 &&<br/>targetObj != localPlayer?"}
    CheckValid -->|No| ClearTarget["ModelOutline_ClearTarget()"]
    CheckValid -->|Yes| GetType["wow_object_type(target)"]

    GetType --> CheckUnit{"Type == Unit (3)?"}
    CheckUnit -->|No| ClearTarget
    CheckUnit -->|Yes| CheckHostile{"!wow_unit_is_friendly()?"}

    CheckHostile -->|Friendly| ClearTarget
    CheckHostile -->|Hostile| CheckPet{"!wow_unit_is_enemy_pet()?"}

    CheckPet -->|Enemy Pet| ClearTarget
    CheckPet -->|Not Pet| CheckAlive{"!wow_unit_is_dead()?"}

    CheckAlive -->|Dead| ClearTarget
    CheckAlive -->|Alive| ReadModel["Read Model @ +0xD8, +0xDC"]

    ReadModel --> RegisterTarget["ModelOutline_SetTargetModel(ptrD8)<br/>ModelOutline_SetTargetModelAlt(ptrDC)<br/>ModelOutline_SetModelOwner(ptr, obj)"]
```

### Raid Mark Detection

```mermaid
flowchart TB
    Start["Frame Start"] --> CheckThrottle{"Time since last check<br/>>= 100ms?"}

    CheckThrottle -->|No| SkipScan["Use cached data"]
    CheckThrottle -->|Yes| CacheTargets["wow_cache_raid_targets()<br/>(copies 8 GUIDs from 0x00B71368)"]

    CacheTargets --> ClearOld["ModelOutline_ClearRaidMarked()<br/>ModelOutline_ClearModelOwners()"]

    ClearOld --> ObjectLoop["Object Iteration Loop"]

    ObjectLoop --> CheckType{"Object Type?"}

    CheckType -->|"Type 4 (Player)"| ProcessPlayer
    CheckType -->|"Type 3 (Unit/NPC)"| ProcessNPC
    CheckType -->|Other| NextObj["Next Object"]

    subgraph PlayerMarks["Player Raid Mark Check"]
        ProcessPlayer --> CheckPlayerAlive{"Alive?"}
        CheckPlayerAlive -->|No| NextObj
        CheckPlayerAlive -->|Yes| CheckNotSelf{"Not LocalPlayer?"}
        CheckNotSelf -->|Self| NextObj
        CheckNotSelf -->|Other| GetPlayerGUID["wow_object_guid()"]
        GetPlayerGUID --> CheckPlayerMark{"wow_get_raid_target_index(guid)"}
        CheckPlayerMark -->|No Mark| NextObj
        CheckPlayerMark -->|Has Mark 1-8| ReadPlayerModel["Read Model @ +0xD8, +0xDC"]
        ReadPlayerModel --> RegisterPlayerMark["ModelOutline_AddRaidMarkedModel(ptr, index)"]
    end

    subgraph NPCMarks["NPC Raid Mark Check"]
        ProcessNPC --> CheckNPCAlive{"Alive?"}
        CheckNPCAlive -->|No| NextObj
        CheckNPCAlive -->|Yes| CheckNotPet{"!wow_unit_is_enemy_pet()?"}
        CheckNotPet -->|Enemy Pet| NextObj
        CheckNotPet -->|OK| GetNPCGUID["wow_object_guid()"]
        GetNPCGUID --> CheckNPCMark{"wow_get_raid_target_index(guid)"}
        CheckNPCMark -->|No Mark| NextObj
        CheckNPCMark -->|Has Mark 1-8| ReadNPCModel["Read Model @ +0xD8, +0xDC"]
        ReadNPCModel --> RegisterNPCMark["ModelOutline_AddRaidMarkedModel(ptr, index)"]
    end

    RegisterPlayerMark --> NextObj
    RegisterNPCMark --> NextObj
```

---

## Model-to-Object Linking

```mermaid
flowchart TB
    subgraph Sources["Model Pointer Sources"]
        UnitD8["Unit Object + 0xD8<br/>(Primary Model)"]
        UnitDC["Unit Object + 0xDC<br/>(Secondary Model)"]
        CorpseD8["Corpse Object + 0xD8"]
        CorpseDC["Corpse Object + 0xDC"]
    end

    subgraph ModelOwnerLookup["Model -> Owner Lookup (in hooks)"]
        Callback["Model + 0x3C0<br/>(SetRenderCallbacks owner)"]
        Direct["Model + 0x28<br/>(InitializeModelWithParameters owner)"]
    end

    subgraph Storage2["Storage"]
        OwnerMap2["g_modelToOwner<br/>unordered_map<model_ptr, object_ptr>"]
    end

    subgraph Usage["Usage in Hooks"]
        ManageHook["ManageRenderListNode Hook"]
        BatchHook["DrawBatchProj Hook"]
        GetCategory["GetModelCategory()"]
    end

    Sources -->|"SetModelOwner()"| Storage2
    ModelOwnerLookup -->|"Fallback lookup"| Usage
    Storage2 -->|"GetModelOwner()"| Usage
```

---

## Hook Pipeline

```mermaid
flowchart TB
    subgraph WoWRender["WoW Render Pipeline"]
        AddModel["Model added to render list"]
        RenderScene["CM2SceneRenderDraw"]
        DrawBatchP["DrawBatchProj (batch type 0)"]
        DIP["IDirect3DDevice9::DrawIndexedPrimitive"]
    end

    subgraph OurHooks["Our Hooks"]
        ManageHook["ManageRenderListNode Hook<br/>@ 0x00710B90"]
        RenderHook["CM2SceneRenderDraw Hook<br/>@ 0x0070B360"]
        BatchProjHook["DrawBatchProj Hook<br/>@ 0x0070CB30"]
        DIPHook["D3D9 DIP Hook"]
    end

    subgraph Actions["Hook Actions"]
        CheckMatch["Check if model is tracked<br/>(dead/raid/target)"]
        AddToFrame["Add to g_frameDeadModels"]
        SetFlag["Set g_bRenderingCorpse = true<br/>Set g_currentRenderingModel"]
        ApplyStencil["Apply stencil outline effect"]
    end

    AddModel --> ManageHook
    ManageHook --> CheckMatch
    CheckMatch -->|Match| AddToFrame

    RenderScene --> RenderHook
    RenderHook --> BatchProjHook

    BatchProjHook --> SetFlag
    SetFlag --> DIP
    DIP --> DIPHook
    DIPHook --> ApplyStencil
```

---

## Group Membership Detection

```mermaid
flowchart TB
    subgraph Cache["Group Cache (refreshed every 5s)"]
        Party["UnitGUID('party1'..'party4')"]
        Raid["UnitGUID('raid1'..'raid40')"]
        Storage3["g_groupGUIDs[40]<br/>g_groupMemberCount"]
    end

    subgraph Lookup["wow_is_guid_in_group(guid)"]
        CheckStale{"Cache > 5s old?"}
        Refresh["wow_refresh_group_cache()"]
        Search["Linear search g_groupGUIDs"]
    end

    CheckStale -->|Yes| Refresh
    Refresh --> Search
    CheckStale -->|No| Search

    Party --> Storage3
    Raid --> Storage3
    Storage3 --> Search
```

---

## Summary: Memory Reads Per Frame

| Operation | Memory Source | Frequency |
|-----------|--------------|-----------|
| Object Iteration | Object Manager @ 0x00B41414 | Every frame, O(n) objects |
| Object Type | Object + 0x14 | Per object |
| Object GUID | Object + 0x30 | Per player/unit/corpse |
| Unit Dead Check | Descriptor + 0x40 (HP), + 0x224 (flags) | Per unit |
| Unit Friendly Check | UnitReaction function call | Per relevant unit |
| Model Pointer | Object + 0xD8, + 0xDC | Per tracked object |
| Raid Targets | 0x00B71368 (8 GUIDs) | Every 100ms |
| Current Target | UnitGUID("target") function | Every frame |
| Group Members | UnitGUID("party#", "raid#") | Every 5 seconds |
| Corpse Owner | Descriptor + 0x18 | Per corpse |
| Corpse Skeleton Flag | Descriptor + 0x8C | Per corpse |

---

## Potential Consolidation Opportunities

1. **Batch GUID Resolution**: Currently `wow_get_raid_target_index()` is called per-object. Could cache GUID->mark_index map once per 100ms.

2. **Unified Object Cache**: Could build a single per-frame cache of {object_ptr, guid, type, model_ptrs, is_dead, is_friendly} to avoid repeated reads.

3. **Reduce Hook Count**: Consider if ManageRenderListNode + DrawBatchProj could be consolidated into a single hook point.

4. **Group Cache Integration**: Group membership check could be integrated with the raid target cache refresh cycle.

5. **Model Owner Association**: Currently done both at detection time AND in hooks via fallback. Could be consolidated to detection-only.
