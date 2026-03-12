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
**Our event**: `COMBAT_LOG_MELEE` (slot 554)
**Fields**: targetGUID, attackerGUID, totalDamage, school, absorb, resist, blocked, hitInfo, victimState

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
- [x] CHAT_MSG_COMBAT_SELF_HITS
- [x] CHAT_MSG_COMBAT_SELF_MISSES
- [x] CHAT_MSG_COMBAT_PARTY_HITS
- [x] CHAT_MSG_COMBAT_PARTY_MISSES
- [x] CHAT_MSG_COMBAT_FRIENDLYPLAYER_HITS
- [x] CHAT_MSG_COMBAT_FRIENDLYPLAYER_MISSES
- [x] CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS
- [x] CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES
- [x] CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS
- [x] CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES
- [x] CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS
- [x] CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES
- [x] CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS
- [x] CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES
- [x] CHAT_MSG_COMBAT_PET_HITS
- [x] CHAT_MSG_COMBAT_PET_MISSES

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

### Category 4: Direct Heals — DONE ✓

**Packet**: SMSG_SPELLHEALLOG (opcode 0x150, handler 0x5E89C0)
**Our event**: `COMBAT_LOG_HEAL` (slot 553)
**Fields**: targetGUID, casterGUID, spellId, healAmount, isCrit

Covers these DPSMate events:
- [x] CHAT_MSG_SPELL_SELF_BUFF (heal component: "Your X heals Y for Z")
- [x] CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF (heal component: "X's Y heals Z for W")
- [x] CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF (heal component)
- [x] CHAT_MSG_SPELL_PARTY_BUFF (heal component)

### Category 5: Environmental Damage — DONE ✓

**Handler**: `ProcessEnvironmentalDamage` (0x62aac0) — downstream function, not a packet handler
**Our event**: `COMBAT_LOG_ENV_DMG` (slot 555)
**Fields**: victimGUID, damageType, baseDamage, absorb

damageType values: 0=EXHAUSTED(fatigue), 1=DROWNING, 2=FALL, 3=LAVA, 4=SLIME, 5=FIRE

Hook approach: direct hook on ProcessEnvironmentalDamage (called from SMSG_ENVIRONMENTALDAMAGELOG
packet handler chain). Already has parsed structured data — no CDataStore parsing needed.
__fastcall(ECX=victimGuidPtr, EDX=damageType, stack: damageSource, baseDamage, absorb), returns void.

### Category 6: Aura Gain/Loss — DONE ✓

Hooked via object field update callbacks (no packet handler — vanilla uses SMSG_UPDATE_OBJECT):
- [x] SPELL_AURA_APPLIED: SetSpellTarget (0x6123F0) — aura field inactive→active transition
- [x] SPELL_AURA_REMOVED: CastSpell (0x612320) — aura field active→inactive transition
- [x] SPELL_AURA_APPLIED_DOSE: ValidateSpellSlot (0x612450) — stack count increase
- [x] SPELL_AURA_REMOVED_DOSE: ValidateSpellSlot (0x612450) — stack count decrease
- [x] SPELL_DISPEL: ProcessAuraDispelMessage (0x62D480) — from SMSG_SPELLDISPELLOG

Aura type heuristic: slot < 40 = "BUFF", slot >= 40 = "DEBUFF" (vanilla aura slot layout).
Source GUID unknown for field update hooks — passed as GUID_ZERO (no UNIT_FIELD_AURA_CREATOR in vanilla).

Still missing:
- [ ] SPELL_AURA_REFRESH: no callback for same-spell re-application
- [ ] SPELL_AURA_BROKEN / BROKEN_SPELL: CC break detection

### Category 7: Deaths — DONE ✓

- [x] UNIT_DIED: HandleUnitDeath (0x605860) — called from HandleUnitHealthChange on death transition
- [x] PARTY_KILL: PartyKillLogHandler (0x628890) — from SMSG_PARTYKILLLOG packet

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

## FrameScript_CreateEvents Crash — Root Cause (2026-03-10)

### The Crash
- Address 0x703E19 inside `FrameScript_CreateEvents` (0x703D90)
- ACCESS_VIOLATION reading 0x451C4000 (garbage pointer as event name string)
- Deterministic: EAX=0x451C4000, EBX=0x1A0(416), ESI=0x1A(26) in both crashes

### Root Cause (TWO bugs)

**Bug 1: Second call site with different event table.**
`FrameScript_CreateEvents` is `__fastcall(ECX=eventNameArray, EDX=eventCount)`. There are
TWO call sites:
- 0x48FEAB: `MOV ECX, 0xBE1198` (main event table, 549 entries)
- 0x46A88F: `MOV ECX, 0xB41E70` (secondary event table, much smaller)

Our hook bumped maxEventId unconditionally. When the secondary call came through with
ECX=0xB41E70 and a small count, we bumped it to 557. The function iterated 557 entries
from a much smaller array, reading garbage at index 26. EBX=0x1A0 = 26*0x10 (destination
offset), ESI=0x1A = 26 (loop counter).

**Bug 2: Stomping float globals beyond the event array.**
Slots 551-555 (addresses 0xBE1A34-0xBE1A44) are NOT free space. Ghidra xrefs show:
- 0xBE1A34: float written by 0x51C2CC (FSTP)
- 0xBE1A40: float written by 0x51BE5C (FSTP)
- 0xBE1A44: float written by 0x51C09C (FSTP)
All in the 0x51xxxx addon/UI system. Zeroing/overwriting these corrupts game state.

### Fix
1. Guard count bump: `if (param1 == 0xBE1198 and new_max < 551)` — only expand main table
2. Single event slot 549 (verified safe by nampower) instead of 551-555
3. Unified COMBAT_LOG_EVENT with WotLK-style subevent strings, bump to 551

## Implementation Status

### Done — 32 subevents across 23 hooks (22 hook addresses + wow.zig import)

**Infrastructure:**
- [x] Unified COMBAT_LOG_EVENT at slot 549 (WotLK-style subevents)
- [x] FrameScript_CreateEvents hook — guarded for main table only, bump to 550
- [x] CDataStore read helpers (cdsGet, cdsGetPackedGuid, save/restore m_read)
- [x] GUID-to-string conversion (4-buffer rotating hex formatter)
- [x] Fire functions: fireCombatLog, fireSwingMissed, fireSpellStr, fireSpell, fireBase, fireSpellStrD, fireSpellDispel
- [x] Event string pointer base verified: 0xBE1198 (derived from nampower 549→0xBE1A2C)

**Phase 1-2 — Packet handler hooks:**
- [x] SpellNonMeleeDmgLogHandler (0x5E85E0) → SPELL_DAMAGE + RANGE_DAMAGE (opcode 0x250)
- [x] PeriodicAuraLogHandler (0x626DD0) → SPELL_PERIODIC_DAMAGE/HEAL/ENERGIZE/LEECH (opcode 0x24E)
- [x] MeleeDispatcher (0x6255B0) → SWING_DAMAGE / SWING_MISSED (opcode 0x14A filter)
- [x] PartyKillLogHandler (0x628890) → PARTY_KILL (opcode 0x1F5)
- [x] SpellStartHandler (0x6E7640) → SPELL_CAST_START (0x131) / SPELL_CAST_SUCCESS (0x132)
- [x] CastResultHandler (0x6E7330) → SPELL_CAST_FAILED (opcode 0x130, status != 0)

**Phase 3 — Downstream hooks (Warden-safe):**
- [x] ProcessSpellPowerDrainMessage (0x62C770) → SPELL_HEAL (migrated from packet handler)
- [x] ProcessSpellCombatResult (0x62BAB0) → SPELL_MISSED
- [x] ProcessSpellDrainEffectMessage (0x62CA20) → DAMAGE_SHIELD
- [x] DisplaySpellInterruptMessage (0x626A10) → SPELL_INTERRUPT
- [x] ProcessInstaKillSpellMessage (0x62CBE0) → SPELL_INSTAKILL
- [x] ~~ProcessEnergize (0x62DC10)~~ → removed, was OPEN_LOCK (effectType 33), not energize
- [x] ProcessEnvironmentalDamage (0x62AAC0) → ENVIRONMENTAL_DAMAGE

**Phase 4 — Death and aura field change hooks:**
- [x] HandleUnitDeath (0x605860) → UNIT_DIED (fastcall, ECX=unit, plain RET)
- [x] SetSpellTarget (0x6123F0) → SPELL_AURA_APPLIED (thiscall, RET 0x8)
- [x] CastSpell (0x612320) → SPELL_AURA_REMOVED (thiscall, RET 0x8)

**Phase 5 — Dose, extra attacks, dispel, ranged detection:**
- [x] ValidateSpellSlot (0x612450) → SPELL_AURA_APPLIED_DOSE / SPELL_AURA_REMOVED_DOSE (thiscall, RET 0x8)
- [x] ProcessExtraAttacksSpellMessage (0x62D9F0) → SPELL_EXTRA_ATTACKS (fastcall, RET 0x4)
- [x] ProcessAuraDispelMessage (0x62D480) → SPELL_DISPEL (fastcall, RET 0x4)
- [x] RANGE_DAMAGE — detected via spell ID check (75=Auto Shot, 5019=Shoot) in spell damage hook
- [x] RANGE_MISSED — detected via spell ID check (75/5019) in spell missed hook
- [x] ProcessSpellEffect (0x62ACE0) → SPELL_SUMMON / SPELL_RESURRECT / SPELL_ENERGIZE (spell DB Effect[] lookup)
  - ENERGIZE moved here: effectType 30 falls to default case → ProcessSpellEffect, not 0x62DC10

**Phase 6 — Aura refresh + bug fixes:**
- [x] SetActionCooldownTimer (0x4E4390) → SPELL_AURA_REFRESH (⚠ LOCAL PLAYER ONLY)
  - Hooked from SMSG_UPDATE_AURA_DURATION (opcode 0x137) handler
  - Detects refresh by checking if aura slot already has active spell in descriptors
  - Vanilla only sends duration updates to the buffed player — other units' refreshes are invisible
- [x] SPELL_AURA_REFRESH heuristic for all other units via SPELL_GO hit target parsing
  - Extended spellStartDetour to parse SMSG_SPELL_GO (0x132) hit target list
  - For aura spells (APPLY_AURA/APPLY_AREA_AURA effects), checks if hit target already has the aura
  - Skips local player (handled by SetActionCooldownTimer), fires for all other units
  - Helpers: hasApplyAuraEffect(spellId), unitHasAura(guid, spellId) → ?slot
- [x] SPELL_AURA_BROKEN_SPELL heuristic via damage ring buffer (16 entries)
  - Damage hooks record {target, source, spellId} into ring buffer
  - auraRemovedDetour checks SpellRec.AuraInterruptFlags (+0x58) for damage-break flags
  - If breakable + recent damage → fire SPELL_AURA_BROKEN_SPELL before SPELL_AURA_REMOVED
- [x] ENERGIZE false-fire bug fixed: removed 0x62DC10 hook, moved detection to ProcessSpellEffect with spell DB filter
- [x] Aura BUFF/DEBUFF detection improved: uses spell DB Attributes flag 0x4000000 (SPELL_ATTR_NEGATIVE) with slot < 40 fallback

### Known Issues — Fixed
- ~~**SPELL_ENERGIZE false fires**~~: Fixed. Removed 0x62DC10 hook (was OPEN_LOCK/effectType 33).
  ENERGIZE now detected via spell DB Effect[] check in ProcessSpellEffect (0x62ACE0).

### Known Limitations
- **SPELL_AURA_REFRESH heuristic for other units**: For non-local units, vanilla sends NO
  refresh notification at all (no packet, no descriptor change). We use a SPELL_GO heuristic:
  when a buff spell hits a target that already has that aura in their descriptors, we infer
  a refresh. This is best-effort and has known limitations:
  - False positives: spell hits target but aura was actually removed and re-applied (rare)
  - False negatives: procs, channeled refreshes, or any refresh without a SPELL_GO packet
  - Only works for spells with APPLY_AURA (6) or APPLY_AREA_AURA (27) effects in spell DB
  - Local player excluded (uses reliable SetActionCooldownTimer path instead)

### SPELL_AURA_BROKEN_SPELL — Heuristic via Damage Ring Buffer
- [x] Implemented as heuristic: damage ring buffer (16 entries) + aura removal correlation
- Damage hooks (SPELL_DAMAGE, SWING_DAMAGE, SPELL_PERIODIC_DAMAGE, ENVIRONMENTAL_DAMAGE)
  record {targetGUID, sourceGUID, spellId} into ring buffer via recordDamage()
- In auraRemovedDetour: if removed aura has AURA_INTERRUPT_FLAG_DAMAGE (0x02) or
  AURA_INTERRUPT_FLAG_DIRECT_DAMAGE (0x01000000) in SpellRec.AuraInterruptFlags (+0x58),
  check ring buffer for recent damage to same target
- If match: fire SPELL_AURA_BROKEN_SPELL with breaking source info, then SPELL_AURA_REMOVED
- Server confirms: AuraRemoveMode is tracked internally but NEVER sent to client
- No timestamp needed: damage packets arrive BEFORE descriptor updates (same server tick)
- Known limitations: false positives if damage + unrelated aura removal happen in same batch;
  no coverage for SPELL_AURA_BROKEN (without spell — melee break) since we pass spellId=0 for melee

### Completed reference
- [x] RANGE_MISSED: Detected via spell ID check (75/5019) in ProcessSpellCombatResult hook.
- [x] SPELL_SUMMON / SPELL_RESURRECT / SPELL_ENERGIZE: Hook ProcessSpellEffect (0x62ACE0),
  spell DB Effect[] lookup. Summon: 28, 42, 56, 85-88, 104-107, 109. Resurrect: 18, 113.
  Energize: 30. SpellRec via WowClientDB 0xC0D780: m_recordsById(+8), m_maxId(+C),
  Effect[3] at +0xF4, School at +0x04, Attributes at +0x18.

### SMSG_UPDATE_AURA_DURATION (opcode 0x137) — Aura Refresh Research
- Packet: `uint8 slot` + `uint32 duration_ms` (5 bytes)
- Handler: multi-opcode dispatcher at 0x5E38C0, case at 0x5E3BA9
- Calls `SetActionCooldownTimer` (0x4E4390): `__fastcall(ECX=slot, EDX=duration_ms)`
- Stores `current_timestamp + duration_ms` into expiry array at 0xBC5F68 (48 entries)
- Server sends on both initial application AND refresh (Refresh() in SpellAuras.cpp:362)
- Server only sends to the player themselves (GetTarget()->GetTypeId() == TYPEID_PLAYER)
- On initial application: SMSG_UPDATE_AURA_DURATION sent BEFORE SMSG_UPDATE_OBJECT
  (duration sent immediately from AddSpellAuraHolder, descriptors batched at end of tick)
  → client descriptor slot is still empty when handler fires → detectable as "not refresh"
- On refresh: descriptor already has the spell from earlier application → detectable as refresh

### CRITICAL: Wrong opcode labels from Ghidra handler dump
Many labels in `/tmp/handlers_output.txt` were user-applied and WRONG. The server source
(`reference/server/src/game/Protocol/Opcodes_1_12_1.h`) is the definitive reference:
- 0x15B = SMSG_RESURRECT_REQUEST (was labeled "handleSpellMiss" — **WRONG**)
- 0x12A = SMSG_INITIAL_SPELLS (was labeled "applySpellAura" — **WRONG**)
- 0x129 = SMSG_ACTION_BUTTONS (was labeled "removeSpellAura" — **WRONG**)
- 0x1F1 = MSG_SAVE_GUILD_EMBLEM (was labeled "applyDamageShield" — **WRONG**)
- The SPELL_MISSED hook on 0x5E7BC0 was removed — it was hooking the resurrect handler

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

### Verified Opcode → Handler Map (from server Opcodes_1_12_1.h)

| Opcode | Packet Name | Client Handler | Status |
|--------|-------------|----------------|--------|
| 0x130 | SMSG_CAST_RESULT | 0x6E7330 | Hooked (SPELL_CAST_FAILED) |
| 0x131 | SMSG_SPELL_START | 0x6E7640 | Hooked (SPELL_CAST_START) |
| 0x132 | SMSG_SPELL_GO | 0x6E7640 | Hooked (SPELL_CAST_SUCCESS) |
| 0x14A | SMSG_ATTACKERSTATEUPDATE | 0x6255B0 | Hooked (SWING_DAMAGE/MISSED) |
| 0x150 | SMSG_SPELLHEALLOG | 0x5E89C0 | Hooked (SPELL_HEAL) |
| 0x1F5 | SMSG_PARTYKILLLOG | 0x628890 | Hooked (PARTY_KILL) |
| 0x24B | SMSG_SPELLLOGMISS | 0x5E7E00 | Downstream hooked (0x62BAB0 → SPELL_MISSED) |
| 0x24C | SMSG_SPELLLOGEXECUTE | 0x5E7F90 | Downstream: 0x626A10 (INTERRUPT), 0x62DC10 (ENERGIZE), 0x62D9F0 (EXTRA_ATTACKS) |
| 0x24E | SMSG_PERIODICAURALOG | 0x626DD0 | Hooked (SPELL_PERIODIC_*) |
| 0x24F | SMSG_SPELLDAMAGESHIELD | 0x5E84E0 | Downstream hooked (0x62CA20 → DAMAGE_SHIELD) |
| 0x250 | SMSG_SPELLNONMELEEDAMAGELOG | 0x5E85E0 | Hooked (SPELL_DAMAGE) |
| 0x260 | SMSG_PROCRESIST | — | Low priority |
| 0x262 | SMSG_DISPEL_FAILED | — | Low priority (failed dispels, not successful) |
| 0x27B | SMSG_SPELLDISPELLOG | 0x5E8B60 | Downstream hooked (0x62D480 → SPELL_DISPEL) |
| 0x32F | SMSG_SPELLINSTAKILLLOG | 0x5E85A0 | Downstream hooked (0x62CBE0 → SPELL_INSTAKILL) |

### Server Packet Formats (from tortoise-wow source)

**SMSG_SPELLLOGMISS (0x24B)**: `u32 spellId, u64 casterGuid, u8 unk8, u32 targetCount,
  [targetCount]: u64 targetGuid, u8 missInfo, (if unk8==1: 2*f32)`

**SMSG_SPELLLOGEXECUTE (0x24C)**: `PackedGuid casterGuid, u32 spellId, u32 effectCount,
  [effectCount]: u32 effectType, u32 entryCount, [entryCount]: (per-effect data)`
  Effect types (vanilla numbering — differs from WotLK!): INSTAKILL(1), POWER_DRAIN(8),
  RESURRECT(18), EXTRA_ATTACKS(19), CREATE_ITEM(24), OPEN_LOCK(33), ENERGIZE(59?),
  INTERRUPT_CAST(68), FEED_PET(101), DISMISS_PET(102), DURABILITY_DAMAGE(111).
  DISPEL(38), DISPEL_MECHANIC(108) route through generic ProcessSpellEffect.
  See "SPELLLOGEXECUTE Dispatch Table" section for full mapping.

**SMSG_SPELLDAMAGESHIELD (0x24F)**: `u64 victimGuid, u64 casterGuid, u32 damage, u32 school`

**SMSG_SPELLINSTAKILLLOG (0x32F)**: `u64 casterGuid, u32 spellId` (no victim — client-only)

### Downstream Hook Targets (Warden-safe)

Hooking packet handlers directly risks Warden false flags. Instead hook the downstream
functions called AFTER packet parsing with already-parsed data:

**ProcessSpellCombatResult (0x62BAB0)** — SPELL_MISSED
  `__fastcall(missType_ECX, spellId_EDX, casterGuidLo, casterGuidHi, targetGuidLo, targetGuidHi, isFromSpellLogMiss)`
  Called by SPELLLOGMISS handler (0x5E7E00) per target. Dispatches by missType to
  GetSpellResistString/DodgeString/etc, then DisplayColoredMessage + LogSpellCastError(0x21E).
  missType enum: 2=RESIST, 3=DODGE, 4=PARRY, 5=BLOCK, 6=EVADE, 7/8=IMMUNE, 9=DEFLECT, 11=REFLECT, default=MISS

**ProcessSpellDrainEffectMessage (0x62CA20)** — DAMAGE_SHIELD
  `__fastcall(ECX=victimGuid*, EDX=casterGuid*, stack: damage, school)`
  Called by SPELLDAMAGESHIELD handler (0x5E84E0). Resolves GUIDs via ValidateSpellCastAndGetObjects,
  displays via DisplayColoredMessage. Also fires UNIT_COMBAT (0xB6) via InitMemoryPoolWrapper.

**ProcessInstaKillSpellMessage (0x62CBE0)** — SPELL_INSTAKILL
  `__fastcall(ECX=casterGuid*, EDX=spellId)`
  Called by SPELLINSTAKILLLOG handler (0x5E85A0). Only has caster + spellId, no victim.
  Displays via DisplayColoredMessage, no UNIT_COMBAT event.

**DisplaySpellInterruptMessage (0x626A10)** — SPELL_INTERRUPT (from SPELLLOGEXECUTE)
  `__fastcall(ECX=casterGuid*, EDX=targetGuid*, stack: interruptedSpellId)` RET 0x4
  Called from SPELLLOGEXECUTE handler for effectType 32 (INTERRUPT_CAST).
  Missing the interrupting spell's ID (only has interrupted spell).
  Ghidra name: DisplaySpellInterruptMessage. Verified: ECX→[EBP-0x10], EDX→[EBP-0xC], [EBP+0x8]=spellId.

**ProcessEnergize (0x62DC10)** — SPELL_ENERGIZE (from SPELLLOGEXECUTE)
  `__fastcall(ECX=casterGuid*, EDX=targetGuid*, stack: spellId)` RET 0x4
  Called from SPELLLOGEXECUTE for effectType 64 (TRIGGER_SPELL).
  Ghidra name: ProcessLockPickingValidationMessage (mislabeled). Unusual prologue: PUSH EBX; MOV EBX,ESP; AND ESP,-8.
  Stack param via [EBX+0x8]. Amount/powerType not available at this call site.

**ProcessSpellCastEffect (0x62CD80)** — existing SPELL_DAMAGE downstream
  `__fastcall(ECX=targetGuid*, EDX=casterGuid*, stack: spellId, damage, casterId, resist, absorb, blocked, flags)` RET 0x1c
  Called by SPELLNONMELEEDAMAGELOG handler for direct (non-periodic) damage.
  Ghidra decompile confirms: [EBP+0x8]=spellId (DB index), [EBP+0xC]=damage, [EBP+0x10]=casterId
  (passed to GetSpellNameById AND compared to GetCurrentPlayerId for message formatting),
  [EBP+0x14]=resist, [EBP+0x18]=absorb, [EBP+0x1C]=blocked, [EBP+0x20]=flags (&2=crit).
  Internally calls ProcessSpellCombatResult(5,...) for full-block case.
  NOTE: "casterId" is NOT spell school -- it's a caster entity identifier. School is looked up
  from the spell DB entry, not passed as a parameter. Migration would lose school from our event.
  DECISION: Do NOT migrate -- uncertain param3, lose school field, existing packet parser works.

**ProcessSpellPowerDrainMessage (0x62C770)** — SPELL_HEAL downstream (Ghidra mislabel, actually heal display)
  `__fastcall(ECX=casterGuid*, EDX=targetGuid*, stack: spellId, healAmount, isCrit)` RET 0xC
  Called by SpellHealLogHandler (0x5E89C0) after packet parsing.
  Verified from call site disassembly: ECX=LEA[EBP-0x18]=casterGuid, EDX=LEA[EBP-0x28]=targetGuid,
  push1=[EBP-0xC]=spellId, push2=[EBP-0x8]=healAmount(EDI), push3=isCrit(ESI, normalized bool).
  Calls ValidateSpellCastAndGetObjects to resolve GUIDs, then GetHealingMessageConfigString or
  GetCriticalHealingMessageConfigString based on isCrit. MIGRATED: replaces packet handler hook.

### Phase 3 Migration Assessment

Downstream migration for Warden safety was evaluated for all 7 existing packet handler hooks:

| Hook | Downstream | Assessment |
|------|-----------|------------|
| SpellNonMeleeDmgLogHandler | ProcessSpellCastEffect (0x62CD80) | NOT migrated -- lose school field, uncertain casterId param |
| SpellHealLogHandler | ProcessSpellPowerDrainMessage (0x62C770) | MIGRATED -- clean 5-param interface |
| PeriodicAuraLogHandler | None -- IS the handler | Cannot migrate -- no downstream exists |
| MeleeDispatcher | 0x624F30 (thiscall, unit object ptr) | NOT migrated -- takes object pointer, not GUID |
| PartyKillLogHandler | Already minimal (display only) | Cannot simplify further |
| SpellStartHandler | processSpellImpactResults (0x6E7A70) | NOT migrated -- massive function (50+ vars) |
| CastResultHandler | Spell_C_SpellFailed (0x6E1A00) | NOT migrated -- current hook simpler |

Other downstream functions discovered during research:
- `ProcessSpellSplitDamageMessage` (0x62DE60): fastcall, 2+2 params, RET 0x8. Split damage display.
- `ValidatePeriodicSpellExecution` (0x62D9A0): fastcall, 2+5 params, RET 0x14. Periodic damage path.
- `ProcessExtraAttacksSpellMessage` (0x62D9F0): Not heal (Ghidra mislabel), actually extra attacks.
- `InitMemoryPoolWithFlag` (0x494740): UNIT_COMBAT event firing (separate from COMBAT_LOG_EVENT).

### Aura Events: No Dedicated Packets in Vanilla
Vanilla 1.12.1 has NO SMSG_AURA_UPDATE packet. Aura state is communicated via
SMSG_UPDATE_OBJECT (0x00A9) field updates to UNIT_FIELD_AURA slots. SPELL_AURA_APPLIED/REMOVED
would require hooking the internal aura field change processing, not a packet handler.
- Only sent to the casting player — source GUID from getActivePlayerGuid (0x468550)
- We fire SPELL_CAST_FAILED only when status != 0; pass generic "FAILED" string (no localized failure reason mapping yet)

### Calling Convention Research

All packet handlers registered via `setClientIndexedPointers` (0x5AB650) are dispatched
with the same FastCall(unk, opCode, unk2, CDataStore*) → u32 convention. This is confirmed
by 10 working hooks across 4 different registration callers:
- 0x5E3010: SpellNonMeleeDmgLogHandler, SpellHealLogHandler
- 0x626D00: PeriodicAuraLogHandler, PartyKillLogHandler
- 0x625520: MeleeDispatcher
- 0x6E7150: SpellStartHandler, CastResultHandler

Nampower uses two C++ types (FastCallPacketHandlerT and PacketHandlerT) but hadesmem's
detour system handles convention translation, so this doesn't reflect the actual dispatch ABI.

### Next Steps (priority order)
1. [x] Migrate existing packet handler hooks to downstream equivalents (Warden safety)
   - [x] SPELL_HEAL: 0x5E89C0 → ProcessSpellPowerDrainMessage (0x62C770). MIGRATED.
   - [x] SPELL_DAMAGE: Evaluated, NOT migrated (lose school field, uncertain params)
   - [x] All others: Evaluated, NOT migrated (see Phase 3 Migration Assessment above)
2. [x] Implement UNIT_DIED: hook HandleUnitDeath (0x605860), fastcall(ECX=unit), plain RET
3. [x] Implement SPELL_AURA_REMOVED: hook CastSpell (0x612320), thiscall(ECX=unit, slot, spellId), RET 0x8
4. [x] Implement SPELL_AURA_APPLIED: hook SetSpellTarget (0x6123F0), thiscall(ECX=unit, slot, spellId), RET 0x8
   - Aura type heuristic: slot < 40 = "BUFF", slot >= 40 = "DEBUFF"
5. [x] Implement SPELL_AURA_APPLIED_DOSE/REMOVED_DOSE: hook ValidateSpellSlot (0x612450)
   - requestedLevel param = OLD count, live descriptor has NEW count
   - Fires both directions: increase → APPLIED_DOSE, decrease → REMOVED_DOSE
6. [x] Implement SPELL_EXTRA_ATTACKS: hook ProcessExtraAttacksSpellMessage (0x62D9F0)
   - effectType 19 in vanilla's SPELLLOGEXECUTE dispatch (NOT 33 as in WotLK)
   - Extra attack count not available from downstream — passed as 0
7. [x] Implement SPELL_DISPEL: hook ProcessAuraDispelMessage (0x62D480)
   - Dedicated SMSG_SPELLDISPELLOG handler at 0x5E8B60 calls this per dispelled aura
   - Has caster GUID, target GUID, dispelled aura spell ID
   - Dispelling spell ID unknown — passed as 0
8. [x] Implement RANGE_DAMAGE: detect Auto Shot (75) / Shoot (5019) in spell damage hook
9. [ ] Implement SPELL_AURA_REFRESH: no callback for same-spell-ID aura re-application
10. [ ] Implement SPELL_AURA_BROKEN/BROKEN_SPELL: CC break detection — deep aura system research
11. [ ] Implement SPELL_SUMMON: effectType 28+ → ProcessSpellEffect (0x62ACE0, generic — no effect type param)
12. [ ] Implement SPELL_RESURRECT: effectType 18/32/113 → ProcessSpellEffect (generic)
13. [ ] Implement RANGE_MISSED: detect Auto Shot/Shoot in SPELLLOGMISS downstream
14. [ ] Test in-game: verify all subevents fire correctly
15. [ ] Nampower conflict detection via GetModuleHandleA("nampower.dll")
16. [ ] Example addon code for COMBAT_LOG_EVENT consumption

### Phase 4: UNIT_DIED, SPELL_AURA_APPLIED/REMOVED, RANGE_DAMAGE

#### Object Field Update Callback System

The client registers field change callbacks via `ObjectData_UpdateField` (0x468070):
```
ObjectData_UpdateField(objectType, fieldOffset, dataSize, callbackFunc, context, flags)
```

Key registrations in `InitializeUnitEventHandlers` (0x6041F0):
- `(3, 0x40, 4, 0x6046F0, 0, 0)` -- UNIT_FIELD_HEALTH -> HandleUnitHealthChange
- `(3, 0xA4, 0xD8, 0x604D00, 0, 1)` -- UNIT_FIELD_AURA range -> compareAndUpdateObjectArrays
- `(3, eventId+0x1AC, 1, 0x604EA0, 0, 0)` -- UNIT_FIELD_AURAAPPLICATIONS -> updateObjectWithByteValue

Callbacks are `__stdcall(guidLo, guidHi, oldDataPtr, ???)` with RET 0x10 (4 stack params).
The oldDataPtr contains the PREVIOUS field values before the update was applied.

#### UNIT_DIED -- HandleUnitDeath (0x605860)

- `__fastcall(ECX=unitObject)`, plain RET (0 stack params)
- Called from `HandleUnitHealthChange` (0x6046F0) when `newHealth < 1 && oldHealth > 0`
- Single xref from HandleUnitHealthChange -- only fires on actual death transition
- GUID access: `*(*(unitObject+8))` = GUID lo, `*(*(unitObject+8)+4)` = GUID hi
- Also handles: spell interruption, target clearing, action queue cleanup, event notifications

```
HandleUnitHealthChange (0x6046F0)  __stdcall(guidLo, guidHi, oldHealthPtr, ???)
  -> resolves unit object via ClntObjMgrObjectPtr
  -> if newHealth < 1 && oldHealth > 0:
       HandleUnitDeath(unitObject)
  -> if newHealth > 0 && oldHealth < 1:
       HandleUnitResurrection(unitObject)
```

Hook target: `HandleUnitDeath` (0x605860) -- fire `UNIT_DIED` with target GUID, no source.

#### SPELL_AURA_APPLIED/REMOVED -- Aura Field Change Callback

The aura callback at 0x604D00 (`compareAndUpdateObjectArrays`) is called when UNIT_FIELD_AURA
descriptor fields change (offsets 0xA4-0x17B, 48 spell ID slots + flags). It receives:
- `dataArray` = pointer to OLD aura data (before update was applied)
- Current (NEW) data is in the live descriptor at `*(unitObject+0x110)`

The callback iterates all 48 slots in two passes:
1. **Pass 1 (removal)**: old aura active + new NOT active -> `CastSpell(unit, slot, oldSpellId)`
2. **Pass 2 (application)**: old NOT active + new IS active -> `SetSpellTarget(unit, slot, newSpellId)`

Active check: spellId != 0 AND aura flags byte has bits set.
Aura flags at old offset 0xC0 relative to dataArray, at 0x164 relative to live descriptor.
Flags are packed: 2 aura slots per byte, 4 bits each, mask 0x0E for flag bits.

**CastSpell (0x612320)** -- AURA REMOVED notification
- `__thiscall(ECX=unitObject, stack: slotIndex, spellId)`, RET 0x8
- Single xref from compareAndUpdateObjectArrays (safe to hook)
- Does: IsActivePlayer check, camera FOV reset (for certain effects), UpdateActionsBySpellId

**SetSpellTarget (0x6123F0)** -- AURA APPLIED notification
- `__thiscall(ECX=unitObject, stack: slotIndex, spellId)`, RET 0x8
- Single xref from compareAndUpdateObjectArrays (safe to hook)
- Does: SetUnitTargetById, CGUnit_ProcessAuraSlot, HandleSpellManaCost, UpdateActionsBySpellId
- slotIndex 0x20-0x2F (32-47) treated as "valid spell range" for mana cost handling

**ValidateSpellSlot (0x612450)** -- AURA DOSE change (from aura count callback 0x604EA0)
- `__thiscall(ECX=unitObject, stack: slotIndex, requestedLevel)`, called when stack count changes
- Could be used for SPELL_AURA_APPLIED_DOSE/REMOVED_DOSE

**Limitation**: Source GUID (who applied the aura) is NOT available from field updates.
No UNIT_FIELD_AURA_CREATOR equivalent in vanilla 1.12.1. Fire with source=GUID_ZERO.

#### RANGE_DAMAGE -- Ranged Auto-Attack Detection

Vanilla ranged auto-attacks use the same SMSG_ATTACKERSTATEUPDATE packet as melee.
No distinct opcode or hitInfo flag for ranged. To distinguish:

- Check attacker's UNIT_VIRTUAL_ITEM_SLOT_DISPLAY[2] (ranged weapon slot)
  - Field index 0x14, byte offset 0x50 from descriptor start
  - From stored ptr at obj+0x110: offset 0x38
  - If non-zero, the unit has a ranged weapon equipped
- Cross-reference with the attack being an auto-attack (no spellId in the packet)

Lower priority -- most addons treat ranged auto-attacks as SWING_DAMAGE.

### SPELLLOGEXECUTE Dispatch Table (0x5E7F90 — Phase 5 Ghidra Analysis)

Jump table at 0x5E8430 with index byte table at 0x5E845B (126 entries, guard CMP ECX,0x7D).

| Case | effectTypes | Downstream Function |
|------|------------|-------------------|
| 0 | 0(NONE), 1(INSTAKILL) | ProcessSpellEffect (0x62ACE0) with target |
| 1 | 8(POWER_DRAIN) | ProcessStandardPowerDrainMessage (0x62DBF0) |
| 2 | 18(RESURRECT), 38(DISPEL), 63, 69, 79, 91, 108(DISPEL_MECHANIC), 113, 114, 116, 125 | ProcessSpellEffect (0x62ACE0) with target |
| 3 | 19(EXTRA_ATTACKS in vanilla!) | ProcessExtraAttacksSpellMessage (0x62D9F0) |
| 4 | 24(CREATE_ITEM) | ProcessEnchantItemValidationMessage (0x62D8D0) |
| 5 | 33(OPEN_LOCK in vanilla), 59 | 0x62DC10 (OPEN_LOCK display — NOT energize) |
| 6 | 68(INTERRUPT_CAST) | DisplaySpellInterruptMessage (0x626A10) |
| 7 | 101(FEED_PET) | ProcessFeedPetValidationMessage (0x62D800) |
| 8 | 102(DISMISS_PET) | ProcessPetDismissMessage (0x62E360) |
| 9 | 111(DURABILITY_DAMAGE) | ProcessAllDurabilityDamageMessage (0x62E190) |
| 10 | Everything else (default) | ProcessSpellEffect (0x62ACE0) with NULL target |

**CRITICAL**: Vanilla effectType numbering differs from WotLK! effectType 19 = EXTRA_ATTACKS (not 33).
effectType 33 = OPEN_LOCK (calls 0x62DC10, which we hook as SPELL_ENERGIZE — potential false fires).
effectType 30 (ENERGIZE) falls to default → ProcessSpellEffect, NOT 0x62DC10.

ProcessSpellEffect (0x62ACE0) is a generic display function: checks spell DB entry flags,
filters by effect slot types, then calls ProcessHealingSpellEffect (with target) or
CalculateSpellPower (without target). No effect type parameter — cannot distinguish
DISPEL/SUMMON/RESURRECT from inside this function.

### SMSG_SPELLDISPELLOG — Dedicated Dispel Handler

**Handler**: 0x5E8B60 (registered in applySpellModifiers 0x5E3010)
**Convention**: __stdcall(opcode, CDataStore*), RET 0x8
**Packet format**: PackedGuid casterGuid, PackedGuid targetGuid, u32 count, [count × u32 spellId]
**Downstream**: ProcessAuraDispelMessage (0x62D480) per dispelled aura

**ProcessAuraDispelMessage (0x62D480)**:
`__fastcall(ECX=casterGUID_ptr, EDX=targetGUID_ptr, stack: dispelledSpellId)`, RET 0x4
Displays AURADISPELSELF/AURADISPELOTHER. Only has the dispelled aura's spell ID,
not the dispelling spell. Hooked for SPELL_DISPEL.

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
Nampower:  549 → SPELL_DAMAGE_EVENT_SELF   (0xBE1A2C) [overwritten by us]
           550 → SPELL_DAMAGE_EVENT_OTHER  (0xBE1A30)
Ours:      549 → COMBAT_LOG_EVENT          (0xBE1A2C) [unified, overwrites nampower 549]
FrameScript_CreateEvents maxEventId bumped to 550 (NOT 551 — slot 550 is a float global).
0xBE1A30 (slot 550) = float 0.25 (0x3E800000). Addresses 0xBE1A30+ are float globals — DO NOT USE.
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
