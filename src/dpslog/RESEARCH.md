# DPS Log Module Research

## Goal
Provide structured Lua objects for combat log events so addons can read parsed
fields directly instead of re-parsing localized combat log strings. Modeled
after TBC's `COMBAT_LOG_EVENT_UNFILTERED`.

## The Problem
Vanilla 1.12.1 fires `CHAT_MSG_COMBAT_*` events with localized text in `arg1`.
Addons like DPSMate parse these with 5-15 `strfind` calls per event across
2177 lines of locale-specific pattern matching. In 40-man raids this causes
measurable frame rate impact.

---

## Two Pipelines

### Pipeline 1: Chat-type combat messages (the Lua events addons see)

```
Server (SMSG_MESSAGECHAT)
  -> ProcessIncomingChatPacket (0x0049d560)
    -> AddChatMessageToQueue (0x0049cae0)  [enqueue with type + text + GUIDs]
      -> queue at PTR_00b4fdc0
        -> ProcessChatText (0x0049b560)    [dequeue, fire Lua events]
          -> CHAT_MSG_COMBAT_SELF_HITS, CHAT_MSG_SPELL_SELF_DAMAGE, etc.
```

- `AddChatMessageToQueue`: `__fastcall(ECX=msgType, EDX=textPtr, stack: guid_lo, guid_hi, ...)`
  ~13 params, allocates 0xC8-byte queue entry, stores type + text + GUIDs
- `ProcessChatText` (0x0049b560): dequeues messages, fires Lua events
- These are the **formatted localized strings** DPSMate has to parse

### Pipeline 2: Spell/combat log display (structured data)

```
Server (SMSG_SPELLLOGEXECUTE / SMSG_ATTACKERSTATEUPDATE / etc.)
  -> ProcessUnitUpdateWithTimingValidation (0x00618c30)
  -> ProcessUnitActionWithSpellCastingAndValidation (0x0061a820)
  -> PacketHandler_Wrapper_Generic2 (0x00602d00)
    -> ProcessComplexSpellCast (0x00629b60)
      -> ProcessSpellDamageWithLocalization (0x00629d30)
      -> ProcessEnchantmentApplication
      -> DisplaySpellLogMessage
      -> etc.
        -> LogCombatMessage (0x006268f0)
          -> FireLuaEvent(0x21e, formatted_text)
```

- `ProcessComplexSpellCast` (0x629b60): `__fastcall(ECX=spellData)`, dispatches
  by spell flags to sub-handlers. Calls `ValidateSpellCastAndGetObjects` first
  to resolve source/target GUIDs and spell info.
- `ProcessSpellDamageWithLocalization` (0x629d30): `__fastcall(ECX=spellEffectData,
  EDX=sourceGuid, stack: targetGuid, combatFlags, damageAmount, absorptionAmount,
  resistAmount)` -- has ALL the structured data before string formatting.
- `LogCombatMessage` (0x6268f0): `__fastcall(ECX=msgTypeIndex, EDX=unused,
  stack: extraText)`. Reads format string from table at `[ESI*4 + 0x862920]`,
  copies from g_LuaEventData (0x835154), fires `FireLuaEvent(0x21e, ...)`.

### Format String Table at 0x862920

Index -> string (used by LogCombatMessage to select combat result type):

```
 [0]  INTERRUPT
 [1]  DAMAGE_CRIT
 [2]  DAMAGE
 [4]  BLOCK
 [5]  ABSORB
 [6]  RESIST
 [7]  EVADE
 [8]  DODGE
 [9]  PARRY
[10]  IMMUNE
[11]  DEFLECT
[12]  ENCHANTMENT_REMOVED
[31]  SPELL_PARRIED
[32]  SPELL_BLOCKED
[33]  SPELL_EVADED
[34]  SPELL_IMMUNE
[35]  SPELL_DEFLECTED
[36]  SPELL_REFLECTED
[37]  SPELL_MISSED
[38]  SPELL_ACTIVE
[39]  FACTION
```

---

## Key Addresses

| Address | Function | Calling Convention | Notes |
|---------|----------|--------------------|-------|
| 0x0049cae0 | AddChatMessageToQueue | __fastcall(ECX,EDX + 11 stack) | Enqueue combat msg |
| 0x0049b560 | ProcessChatText | __fastcall | Dequeue + fire Lua events |
| 0x0049d560 | ProcessIncomingChatPacket | ?? | SMSG_MESSAGECHAT handler |
| 0x00629b60 | ProcessComplexSpellCast | __fastcall(ECX=data) | Main spell dispatch |
| 0x00629d30 | ProcessSpellDamageWithLocalization | __fastcall(ECX,EDX + 5 stack) | Structured damage data |
| 0x00628100 | ExecuteSpellWithLocalizedText | ?? | Called for periodic |
| 0x0062aac0 | ProcessEnvironmentalDamage | ?? | Fall/fire/lava/drown |
| 0x0062cd80 | ProcessSpellCastEffect | ?? | Spell cast results |
| 0x006268f0 | LogCombatMessage | __fastcall(ECX=index, stack: text) | Format + fire 0x21e |
| 0x00703f50 | FireLuaEvent | __cdecl(eventId, eventData) | Generic event fire |
| 0x0051ab30 | InitializeGameEventTable | ?? | Registers CHAT_MSG_* names |
| 0x00862920 | (data) | -- | Combat result format string table |
| 0x00835154 | g_LuaEventData | -- | Global combat msg text buffer |
| 0x00b4fdc0 | PTR_00b4fdc0 | -- | Chat message queue head |

---

## Event System

- `FireLuaEvent` (0x703f50): `__cdecl(eventId, eventDataFmtStr, ...)`
  Looks up event handler list at `PTR_00ceef68 + eventId * 0x10`.
  Pushes event name as Lua global, iterates callback linked list, calls each.
- Event 0x21e (542): used by `LogCombatMessage` -- appears to be a general
  combat log display event.
- `CHAT_MSG_COMBAT_SELF_HITS` etc. are registered in `InitializeGameEventTable`
  with their own event IDs. The mapping from queue message type to event ID
  happens in `ProcessChatText`.

---

## Hook Strategy Options

### Option A: Hook AddChatMessageToQueue (0x0049cae0)
- **Pro**: Single funnel point for ALL chat-type combat messages
- **Pro**: Has message type ID + formatted text + GUIDs
- **Con**: Text is already formatted -- we'd need to either parse it ourselves
  (defeats the purpose) or capture structured data from upstream before it reaches here
- **Con**: __fastcall with ~13 params, complex signature

### Option B: Hook upstream structured functions
- Hook `ProcessSpellDamageWithLocalization` (0x629d30) and siblings
- **Pro**: Has raw structured data (source, target, spell, damage, absorb, resist, flags)
- **Con**: Multiple functions to hook (damage, periodic, environmental, cast effects)
- **Con**: Need to correlate with the eventual CHAT_MSG event type

### Option C: Hook ProcessChatText (0x0049b560)
- **Pro**: Where events actually fire to Lua -- can inject additional data here
- **Pro**: Has the message type -> event name mapping
- **Con**: By this point the text is formatted, structured data is lost

### Option D: Hybrid -- capture structured data upstream, attach at dispatch
- Hook the structured functions to capture data into a ring buffer
- Hook ProcessChatText to attach the captured data as extra Lua globals
  when firing the event
- **Pro**: Best of both worlds -- structured data + correct event correlation
- **Con**: Most complex, need to match upstream captures to downstream events

### Option E: Fire a new custom event alongside existing ones
- Hook at the structured data level, fire our own `COMBAT_LOG_EVENT_UNFILTERED`
  event with structured args (like TBC) in addition to the normal events
- **Pro**: Cleanest API, addons opt in, existing behavior unchanged
- **Con**: Need to hook multiple upstream functions, need our own event registration

---

## Nampower Reference (reference/nampower/)

Nampower already implements partial structured combat events. Key patterns:

### Custom Event Registration via Unused Slots

The event table has unused slots. Nampower repurposes them by overwriting
the event name string pointer:

```
Event 369 (0x171) -> "SPELL_QUEUE_EVENT"    at 0xBE175C
Event 540 (0x21C) -> "SPELL_CAST_EVENT"     at 0xBE1A08
Event 549 (0x225) -> "SPELL_DAMAGE_EVENT_SELF"  at 0xBE1A2C
Event 550 (0x226) -> "SPELL_DAMAGE_EVENT_OTHER" at 0xBE1A30
```

To register events beyond the default max (549), hook `FrameScript_CreateEvents`
(0x703D90) and increase `maxEventId`. Nampower bumps 549 -> 551.

### Packet Handler Hooks (from nampower offsets.hpp)

| Address | Handler | Packet | Conv |
|---------|---------|--------|------|
| 0x626DD0 | PeriodicAuraLogHandler | SMSG_PERIODICAURALOG | FastCall(unk,opCode,unk2,CDataStore*) |
| 0x5E85E0 | SpellNonMeleeDmgLogHandler | SMSG_SPELLNONMELEEDAMAGELOG | FastCall(unk,opCode,unk2,CDataStore*) |
| 0x6E7640 | SpellStartHandler | SMSG_SPELL_START (0x131) | FastCall(unk,opCode,unk2,CDataStore*) |
| 0x6E7330 | CastResultHandler | SMSG_CAST_RESULT | PacketHandler(opCode*,CDataStore*) |
| 0x6E8D80 | SpellFailedHandler | SMSG_SPELL_FAILURE | PacketHandler(opCode*,CDataStore*) |
| 0x6E7550 | SpellChannelStartHandler | SMSG_CHANNEL_START | PacketHandler(opCode*,CDataStore*) |
| 0x6E75F0 | SpellChannelUpdateHandler | SMSG_CHANNEL_UPDATE | PacketHandler(opCode*,CDataStore*) |
| 0x6E9460 | SpellCooldownHandler | SMSG_SPELL_COOLDOWN | PacketHandler(opCode*,CDataStore*) |

### SMSG_SPELLNONMELEEDAMAGELOG Packet Format

```
targetGuid      : PackedGuid
casterGuid      : PackedGuid
spellId         : u32
damage          : u32
school          : u8
absorb          : u32
resist          : i32
periodicLog     : u8
unused          : u8
blocked         : u32
hitInfo         : u32  (flags: 0x1=crit, 0x4000=crushing, etc.)
extendData      : u8
```

### SMSG_PERIODICAURALOG Packet Format

```
targetGuid      : PackedGuid
casterGuid      : PackedGuid
spellId         : u32
count           : u32
auraType        : u32
  case 3/89 (PERIODIC_DAMAGE/PERIODIC_DAMAGE_PERCENT):
    amount      : u32
    spellSchool : u32
    absorb      : u32
    resist      : i32
  case 8/20 (PERIODIC_HEAL/OBS_MOD_HEALTH):
    amount      : u32
  case 21/24 (OBS_MOD_MANA/PERIODIC_ENERGIZE):
    powerType   : u32
    amount      : u32
  case 64 (PERIODIC_MANA_LEECH):
    powerType   : u32
    amount      : u32
    multiplier  : u32
```

### Nampower TriggerSpellDamageEvent Format

Fires via `SignalEventParam(eventId, fmt, args...)`:
```
format: "%s%s%d%d%s%d%d%s"
args:   targetGuidStr, casterGuidStr, spellId, amount,
        "absorb,blocked,resist", hitInfo, spellSchool,
        "effect0,effect1,effect2,auraType"
```

### SignalEvent Signatures

- `SignalEvent` (0x703E50): `__fastcall(eventId)` -- no params, just fires event
- `SignalEventParam` (0x703F50): `__cdecl(eventId, fmtStr, ...)` -- variadic,
  pushes formatted string args as Lua event args (arg1, arg2, ...)

---

## Packets NOT Covered by Nampower (DPSMate needs these too)

Based on DPSMate's 54 registered events, we still need handlers for:

### Melee Combat
- SMSG_ATTACKERSTATEUPDATE -- melee hits/crits/misses/dodges/parries/etc.
  Handler likely in the 0x62xxxx range. Contains source/target GUIDs,
  damage, school, hitInfo flags, blocked/absorbed/resisted amounts.

### Healing
- SMSG_SPELLHEALLOG -- direct heals
  Contains casterGuid, targetGuid, spellId, healAmount, critFlag

### Deaths
- SMSG_DESTRUCTOBJ or similar -- unit deaths

### Buffs/Debuffs (aura application/removal)
- Aura gain/loss events -- DPSMate tracks buff uptime, dispels

### Environmental Damage
- SMSG_ENVIRONMENTALDAMAGELOG -- fall, lava, drown, fire
  Already partially handled via ProcessEnvironmentalDamage (0x62aac0)

---

## DPSMate Coverage Matrix

DPSMate registers 54 events across these categories. Our goal: provide structured
data for each so addons skip the 2177-line locale-specific string parser.

### Category 1: Spell Damage (direct) — DONE ✓

**Packet**: SMSG_SPELLNONMELEEDAMAGELOG (handler 0x5E85E0)
**Our event**: `COMBAT_LOG_SPELL_DMG` (slot 551)
**Fields**: targetGUID, casterGUID, spellId, damage, school, absorb, resist, blocked, hitInfo

Covers these DPSMate events:
- [x] CHAT_MSG_SPELL_SELF_DAMAGE (spell hits/crits/misses/parries/dodges/resists/absorbs)
- [x] CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE
- [x] CHAT_MSG_SPELL_PARTY_DAMAGE
- [x] CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE
- [x] CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE
- [x] CHAT_MSG_SPELL_CREATURE_VS_PARTY_DAMAGE
- [x] CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE
- [x] CHAT_MSG_SPELL_PET_DAMAGE
- [x] CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF (damage shields are spell damage)
- [x] CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS

### Category 2: Periodic Damage/Heal Ticks — DONE ✓

**Packet**: SMSG_PERIODICAURALOG (handler 0x626DD0)
**Our event**: `COMBAT_LOG_PERIODIC` (slot 552)
**Fields**: targetGUID, casterGUID, spellId, amount, school, absorb, resist, auraType, powerType

auraType distinguishes: 3=PERIODIC_DAMAGE, 89=PERIODIC_DAMAGE_PERCENT,
8=PERIODIC_HEAL, 20=OBS_MOD_HEALTH, 21=OBS_MOD_MANA, 24=PERIODIC_ENERGIZE,
64=PERIODIC_MANA_LEECH

Covers these DPSMate events:
- [x] CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE
- [x] CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE
- [x] CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE
- [x] CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE
- [x] CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE
- [x] CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS (periodic heal component)
- [x] CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS (periodic heal component)
- [x] CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS (periodic heal component)
- [x] CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS (periodic heal component)

### Category 3: Melee Damage — DONE ✓

**Packet**: SMSG_ATTACKERSTATEUPDATE (opcode 0x14A)
**Needed event**: `COMBAT_LOG_MELEE` (allocate slot 554)
**Fields needed**: targetGUID, casterGUID, damage, school, hitInfo, blocked, absorbed, resisted, victimState

**Handler found**: Opcode 0x14A dispatches through a large switch at **0x6255B0**
(registered in `UpdateBindLocation`, shared with opcodes 0x143-0x149).
Jump table: byte lookup at 0x625B0C, jump at 0x625AEC. Case 5 -> **0x62578D**.

The actual **packet parser** is at **0x625C60** -- `__thiscall(ECX=struct_out, stack=CDataStore*)`.
After parsing, calls `ClntObjMgrObjectPtr` then **0x625E20** (post-parse handler).

**Verified packet wire format** (from Ghidra disassembly of 0x625C60):
```
hitInfo          : u32
attackerGuid     : PackedGuid
targetGuid       : PackedGuid
totalDamage      : u32
subDamageCount   : u8
  per subDamage (5 fields each):
    school       : u32
    damageFP     : f32
    damage       : u32
    absorb       : u32
    resist       : u32
victimState      : u32  (0=hit,1=dodge,2=parry,3=interrupt,4=block,5=evade,6=immune,7=deflect)
unknown1         : u32
unknown2         : u32
spellId          : u32  (0 for melee)
if hitInfo & 0x1:
  blocked        : u32
  ... extended block data
```

**HitInfo flags** (from mangos):
  0x00001=NORMALSWING (block data present), 0x00002=OFFHAND, 0x00004=MISS,
  0x00008=FULL_ABSORB, 0x00010=FULL_RESIST, 0x00020=CRIT, 0x00200=CRUSHING,
  0x00400=GLANCING

**CDataStore read functions** (verified byte sizes from disassembly):
- 0x418EB0 (ReadPointerFromBuffer): reads 4 bytes (u32)
- 0x418E30 (ReadPointerFromStream): reads 4 bytes (u32)
- 0x418CB0 (ReadByteFromBuffer): reads 1 byte (u8)
- 0x419130 (ReadPointerFromData): reads 4 bytes (f32)
- 0x642ED0 (GetPackedGuid): reads packed GUID

**Hooking strategy -- IMPORTANT**: Do NOT hook the packet handler (0x6255B0) or
parser (0x625C60) directly. Packet handler hooks are sensitive to Warden detection.
Prefer hooking slightly further downstream -- e.g., the post-parse handler at
**0x625E20** which receives the already-parsed struct and resolved unit pointer.
Research needed: verify 0x625E20 signature, what data is accessible, whether it's
safe as a hook target.

Covers these DPSMate events (the largest group -- 16 events):
- [ ] CHAT_MSG_COMBAT_SELF_HITS
- [ ] CHAT_MSG_COMBAT_SELF_MISSES
- [ ] CHAT_MSG_COMBAT_PARTY_HITS
- [ ] CHAT_MSG_COMBAT_PARTY_MISSES
- [ ] CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS
- [ ] CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES
- [ ] CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS
- [ ] CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS
- [ ] CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES
- [ ] CHAT_MSG_COMBAT_PET_HITS
- [ ] CHAT_MSG_COMBAT_PET_MISSES

**SMSG_ATTACKERSTATEUPDATE packet format** (from mangos/wowdev):
```
hitInfo         : u32  (flags: 0x1=normal, 0x2=offhand, 0x4=miss, etc.)
attackerGuid    : PackedGuid
targetGuid      : PackedGuid
totalDamage     : u32
subDamageCount  : u8
  per subDamage:
    school      : u32
    damageFP    : f32
    damage      : u32
    absorb      : u32
    resist      : u32
victimState     : u32  (0=hit, 1=dodge, 2=parry, 3=interrupt, 4=block, 5=evade, 6=immune, 7=deflect)
unknown1        : u32
spellId         : u32  (0 for melee)
blocked         : u32  (if hitInfo & BLOCK)
```

Tracing approaches:
- Search for opcode 0x14A in packet dispatch table
- Trace from `ProcessUnitUpdateWithTimingValidation` (0x618c30)
- Search for callers of functions that reference melee hit strings

### Category 4: Direct Heals — TODO

**Packet**: SMSG_SPELLHEALLOG
**Handler**: Trace from `ProcessHealingSpell` (0x622420) callers
**Our event**: `COMBAT_LOG_HEAL` (slot 553 — already registered, no hook yet)
**Fields needed**: targetGUID, casterGUID, spellId, healAmount, isCrit

Covers these DPSMate events:
- [ ] CHAT_MSG_SPELL_SELF_BUFF (heal component: "Your X heals Y for Z")
- [ ] CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF (heal component: "X's Y heals Z for W")
- [ ] CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF (heal component)
- [ ] CHAT_MSG_SPELL_PARTY_BUFF (heal component)

### Category 5: Environmental Damage — TODO (low priority)

**Handler**: `ProcessEnvironmentalDamage` (0x62aac0)
**Fields needed**: targetGUID, damageType (fall/fire/lava/drown/slime), amount

DPSMate currently infers these from CHAT_MSG_COMBAT_SELF_HITS / FRIENDLYPLAYER_HITS
by matching strings like "fall and lose", "swimming in lava", "suffer X points of
fire damage", "drowning and lose". Our melee/spell hooks won't cover these since
they come from a separate opcode (SMSG_ENVIRONMENTALDAMAGELOG).

### Category 6: Aura Gain/Loss — TODO (low priority)

No single packet handler — these are derived from SMSG_AURA_UPDATE and various
spell effect handlers. DPSMate uses:
- [ ] CHAT_MSG_SPELL_AURA_GONE_SELF
- [ ] CHAT_MSG_SPELL_AURA_GONE_OTHER
- [ ] CHAT_MSG_SPELL_AURA_GONE_PARTY
- [ ] CHAT_MSG_SPELL_BREAK_AURA (dispel confirmation)
- [ ] PLAYER_AURAS_CHANGED

These track: buff uptime, debuff uptime, proc tracking, shield absorb tracking,
CC tracking, HoT application/removal. Complex — may be better to let addons
continue using the existing text events for these until we have more bandwidth.

### Category 7: Deaths — TODO (low priority)

- [ ] CHAT_MSG_COMBAT_FRIENDLY_DEATH ("X dies.", "X is slain by Y")
- [ ] CHAT_MSG_COMBAT_HOSTILE_DEATH ("X dies.")

DPSMate uses these to call `DB:UnregisterDeath(source)`. Could fire from
SMSG_DESTROYOBJECT or unit flag changes, but low impact — death events are
infrequent and the string parsing is trivial.

### Category 8: Interrupts — Embedded in spell damage events

DPSMate parses interrupts from SPELL_SELF_DAMAGE and SPELL_CREATURE_VS_SELF_DAMAGE
("You interrupt X's Y"). These are already covered by our `COMBAT_LOG_SPELL_DMG`
event since interrupts flow through the same packet handlers. The addon can detect
interrupts by checking hitInfo flags.

### Category 9: Power Gains — Partially covered

DPSMate parses "You gain X Mana/Rage/Energy from Y" from SPELL_SELF_BUFF and
SPELL_PERIODIC_SELF_BUFFS. Our PERIODIC hook already covers periodic energize
(auraType 21/24). Direct power gains from spell casts (e.g., Life Tap, mana gems)
would need a separate hook or could be left to text events.

---

## Implementation Status

### Done
- [x] Custom event registration (slots 551-554, FrameScript_CreateEvents hook, maxId 556)
- [x] CDataStore read helpers (cdsGet, cdsGetPackedGuid, save/restore m_read)
- [x] GUID-to-string conversion
- [x] SignalEventParam typed wrappers
- [x] SpellNonMeleeDmgLogHandler hook (0x5E85E0) → COMBAT_LOG_SPELL_DMG
- [x] PeriodicAuraLogHandler hook (0x626DD0) → COMBAT_LOG_PERIODIC
- [x] SpellHealLogHandler hook (0x5E89C0) → COMBAT_LOG_HEAL (opcode 0x150)
- [x] MeleeDispatcher hook (0x6255B0) → COMBAT_LOG_MELEE (opcode 0x14A filter)
- [x] Event string pointer base verified: 0xBE1198 (derived from nampower 549→0xBE1A2C)

### Melee Hook Research Findings
- 0x625E20 (originally targeted as "post-parse handler") is just a flag-setter — too simple
- Dispatcher 0x6255B0 handles opcodes 0x143-0x14A via switch/jump table (byte lookup at 0x625B0C, targets at 0x625AEC)
- Opcode 0x14A maps to case 5 → 0x62578D, which zeros struct, calls parser 0x625C60, then resolves unit via 0x468460
- Same FastCall(unk, opCode, unk2, CDataStore*) convention as other packet handlers
- Decision: hook the shared dispatcher with opcode filter (minimal overhead, proven pattern)
- Handler registered from `UpdateBindLocation` (0x625520) via `setClientIndexedPointers` (0x5AB650)

### Heal Handler Discovery
- `setClientIndexedPointers(opcode, handler, 0)` is the packet handler registration function at 0x5AB650
- Registration pattern: `PUSH 0x0; MOV EDX,handler; MOV ECX,opcode; CALL 0x5AB650`
- Opcode 0x150 (SMSG_SPELLHEALLOG) → handler 0x5E89C0 (registered in applySpellModifiers at 0x5E3010)
- Same prologue/convention as SpellNonMeleeDmgLogHandler
- Packet format verified from disassembly: targetGuid(PackedGuid), casterGuid(PackedGuid), spellId(u32), healAmount(u32), isCrit(u8)

### Next Steps (priority order)
1. [ ] Environmental damage hook via ProcessEnvironmentalDamage (0x62aac0)
2. [ ] Addon-side example code showing how to register for our events
3. [ ] Nampower conflict detection via GetModuleHandleA("nampower.dll") (low priority)

### CDataStore Structure

```
+0x00: vtable ptr
+0x04: m_buffer (u8 pointer)
+0x08: m_base
+0x0C: m_alloc
+0x10: m_size
+0x14: m_read (current read position)
```

### Event Slot Layout

```
Nampower:  549 → SPELL_DAMAGE_EVENT_SELF   (0xBE1A2C)
           550 → SPELL_DAMAGE_EVENT_OTHER  (0xBE1A30)
Ours:      551 → COMBAT_LOG_SPELL_DMG      (0xBE1A34)
           552 → COMBAT_LOG_PERIODIC        (0xBE1A38)
           553 → COMBAT_LOG_HEAL            (0xBE1A3C)
           554 → (reserved for COMBAT_LOG_MELEE)
FrameScript_CreateEvents maxEventId bumped to 555.
```

---

## Additional Function Map (from latest Ghidra analysis)

### Combat Message Formatting Chain

```
ProcessSpellDamageWithLocalization (0x629d30)
  -> GetCombatSchoolHitMessage (0x62a080) -- hit message key
  -> GetCombatMissMessage (0x62a0d0)      -- miss message key
  -> LogCombatMessage (0x6268f0)          -- fires event 0x21e
```

### Healing Functions

| Address | Function | Called By |
|---------|----------|-----------|
| 0x622420 | ProcessHealingSpell | UpdateSpellEffects, HandleCombatAction, ProcessSpellDamage, etc. |
| 0x62adc0 | ProcessHealingSpellEffect | ProcessSpellEffect (0x62ace0) |
| 0x62c940 | GetHealingMessageConfigString | |
| 0x62c9a0 | GetCriticalHealingMessageConfigString | |
| 0x627440 | GetPeriodicHealMessageKey | |

### Spell Effect Processing

| Address | Function | Notes |
|---------|----------|-------|
| 0x62ace0 | ProcessSpellEffect | Calls ProcessHealingSpellEffect |
| 0x629d30 | ProcessSpellDamageWithLocalization | __fastcall(spellData, sourceGuid, targetGuid, flags, dmg, absorb, resist) |
| 0x628100 | ExecuteSpellWithLocalizedText | Called for periodic effects |
| 0x62aac0 | ProcessEnvironmentalDamage | Fall/fire/lava/drown |
| 0x62cd80 | ProcessSpellCastEffect | |
| 0x626a10 | DisplaySpellInterruptMessage | |
| 0x62a710 | DisplayAdvancedSpellLogMessage | |

### Combat Message System Init

| Address | Function |
|---------|----------|
| 0x626d00 | InitializeCombatMessageSystem |
| 0x626810 | GetSpellTextByIndex |
| 0x626850 | DisplayColoredMessage |
| 0x6264b0 | GetSpellNameById |
| 0x6264e0 | GetObjectName |
| 0x626630 | ValidateSpellCastAndGetObjects |

### Melee Combat

- `ProcessPlayerAutoAttack` (0x5ecb70) -- called from SetPlayerTarget, UpdatePlayerState
- `processAutoAttack` (0x6e6900)
- Melee hits are part of SMSG_ATTACKERSTATEUPDATE (opcode 0x14A) -- handler not yet identified
- The packet comes through the general update pipeline:
  `ProcessComplexUnitUpdateWithCameraSync` (0x619320) ->
  `ProcessUnitUpdateWithTimingValidation` (0x618c30) ->
  `PacketHandler_Wrapper_Generic2` (0x602d00)

### Key Nampower-Confirmed Address Cross-References

| Our Name | Nampower Name | Address |
|----------|--------------|---------|
| FireLuaEvent | SignalEventParam | 0x703F50 |
| SignalEvent (no params) | SignalEvent | 0x703E50 |
| GetObjectByGUID | GetObjectPtr | 0x464870 |
| ClntObjMgrGetActivePlayer | GetActivePlayer | 0x468550 |
| FrameScript_CreateEvents | FrameScript_CreateEvents | 0x703D90 |
| FrameScript_RegisterFunction | FrameScript_RegisterFunction | 0x704120 |
| GetSpellNameById | (SpellDb at 0xC0D780) | 0x6264b0 |
