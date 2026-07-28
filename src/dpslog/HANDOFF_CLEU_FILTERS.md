# Handoff: COMBAT_LOG_EVENT Filtering (CLEU vs CLEUF)

## Goal

Implement Blizzard's TBC/WotLK event filtering system so we provide both:
- `COMBAT_LOG_EVENT` -- filtered version (only events relevant to the player's group)
- `COMBAT_LOG_EVENT_UNFILTERED` -- all events in range (everything the client sees)

This matches how TBC and WotLK work: addons register for whichever they need. DPS meters
use UNFILTERED for complete data, while UI elements use the filtered version to reduce noise.

## Background

### How Blizzard Did It

In TBC (2.4.0), Blizzard introduced `COMBAT_LOG_EVENT_UNFILTERED` which fires for ALL
combat events the client receives. They also provided `COMBAT_LOG_EVENT` which fires only
for events passing a set of filters.

The filtering is controlled by:
- `CombatLogClearEntries()` -- clears the combat log
- `CombatLogAddFilter(...)` -- adds a filter rule
- `CombatLogResetFilter()` -- resets to default filters
- `CombatLogGetCurrentEntry(...)` -- reads the current event (deprecated by WotLK)
- `CombatLogGetNumEntries()` -- count of buffered events

Default filters include:
- Source or dest is the player
- Source or dest is in the player's party/raid
- Source or dest is the player's pet/guardian
- Events within a certain range

### What We Currently Have

We fire a single `COMBAT_LOG_EVENT` at slot 549 via SignalEventParam. Every hook fires
every event it sees -- no filtering. This is effectively UNFILTERED behavior under the
FILTERED event name.

## Implementation Plan

### Phase 1: Register Both Events

Add a second event slot for `COMBAT_LOG_EVENT_UNFILTERED`:
- `COMBAT_LOG_EVENT` at slot 549 (existing) -- will become the filtered version
- `COMBAT_LOG_EVENT_UNFILTERED` at slot 550 -- fires everything (current behavior)

In `createEventsDetour`, bump the event count by 2 instead of 1 and register both names.
Update all fire functions to fire both events (or fire UNFILTERED always and FILTERED
conditionally).

**IMPORTANT**: Slot 550 was previously identified as a float global (0x3E800000 = 0.25).
Need to verify this is still the case or find a different slot. May need to search for
two consecutive free slots.

### Phase 2: Implement Filtering Logic

The filter checks whether source or dest is "interesting" to the local player:

```zig
fn shouldFilter(src_guid: u64, dst_guid: u64) bool {
    // Always pass if source or dest is the local player
    if (src_guid == getPlayerGUID() or dst_guid == getPlayerGUID()) return false;
    // Always pass if source or dest is in the player's group
    if (isGroupMember(src_guid) or isGroupMember(dst_guid)) return false;
    // Always pass if source or dest is a pet owned by a group member
    if (isPetOfGroupMember(src_guid) or isPetOfGroupMember(dst_guid)) return false;
    // Filter out (don't fire COMBAT_LOG_EVENT)
    return true;
}
```

Requires:
- `getPlayerGUID()` -- already have this (0x468550)
- `isGroupMember(guid)` -- check party (0xBC6F48) and raid (0xB712A8) GUID arrays
- `isPetOfGroupMember(guid)` -- check UNIT_FIELD_SUMMONEDBY descriptor, resolve owner

### Phase 3: Fire Functions

Two approaches:

**Option A: Double-fire**
Every fire function fires the event twice -- once for UNFILTERED (always), once for
FILTERED (if passes filter). Simple but doubles the SignalEventParam calls.

**Option B: Conditional fire with shared push**
Push args to Lua stack once, then call SignalEvent for each registered event that should
receive it. Requires understanding SignalEventParam internals more deeply.

Option A is simpler and the performance cost of an extra SignalEventParam call per event
is negligible compared to the Lua handler execution.

### Phase 4: sourceFlags / destFlags

With filtering in place, we can also construct the COMBATLOG_OBJECT_* bitfield that
WotLK addons use for their own filtering:

```
COMBATLOG_OBJECT_AFFILIATION_MINE     = 0x0001
COMBATLOG_OBJECT_AFFILIATION_PARTY    = 0x0002
COMBATLOG_OBJECT_AFFILIATION_RAID     = 0x0004
COMBATLOG_OBJECT_AFFILIATION_OUTSIDER = 0x0008
COMBATLOG_OBJECT_REACTION_FRIENDLY    = 0x0010
COMBATLOG_OBJECT_REACTION_NEUTRAL     = 0x0020
COMBATLOG_OBJECT_REACTION_HOSTILE     = 0x0040
COMBATLOG_OBJECT_CONTROL_PLAYER       = 0x0100
COMBATLOG_OBJECT_CONTROL_NPC          = 0x0200
COMBATLOG_OBJECT_TYPE_PLAYER          = 0x0400
COMBATLOG_OBJECT_TYPE_NPC             = 0x0800
COMBATLOG_OBJECT_TYPE_PET             = 0x1000
COMBATLOG_OBJECT_TYPE_GUARDIAN        = 0x2000
COMBATLOG_OBJECT_TYPE_OBJECT          = 0x4000
```

These can be constructed from:
- GUID type bits (high nibble of GUID encodes player/creature/pet/gameobject)
- Group membership (party/raid roster arrays)
- Reaction (UnitReaction at 0x6061E0)
- Ownership (UNIT_FIELD_SUMMONEDBY descriptor)

This is the same data needed for filtering, so it comes naturally after Phase 2.

### Phase 5: Lua API (Optional)

Provide the filter configuration API for full parity:
- `CombatLogAddFilter(srcFlags, dstFlags, eventType)`
- `CombatLogResetFilter()`
- `CombatLogGetNumEntries()`

Most addons don't use these -- they just register for UNFILTERED and do their own
filtering. Low priority.

## Key Addresses

- Event slot 549: COMBAT_LOG_EVENT (existing)
- Event slot 550: needs verification (was float 0.25 in earlier research)
- Player GUID: 0x468550 (ClntObjMgrGetActivePlayer)
- Party GUIDs: 0xBC6F48 (array of 4 u64 GUIDs)
- Raid roster: 0xB712A8 (array of ptrs), count at 0xB713E0
- UnitReaction: 0x6061E0
- UNIT_FIELD_SUMMONEDBY: descriptor offset 0x30 (index 0x0C)

## Dependencies

- Phase 1 can start immediately
- Phase 2 needs isGroupMember which uses existing known addresses
- Phase 3 trivial once Phase 1+2 done
- Phase 4 is independent enhancement, can parallelize with Phase 2

## Risk

- Slot 550 conflict with float global -- may need to find a safe slot
- Double-firing events may interact poorly with addons that register for both
  (they'd see every event twice) -- need to ensure the events have distinct IDs
- Performance of filter check per event should be negligible (few memory reads)
