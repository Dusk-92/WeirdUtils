# WotLK 3.3.5 COMBAT_LOG_EVENT_UNFILTERED — Full Arg Specification

Sources:
- `Blizzard_CombatLog.lua` from tekkub/wow-ui-source 3.3.5 branch (authoritative)
- Validated against `bkader/Skada-WoTLK` parser (Core/Functions.lua suffix tables)

## Base Args (all events)

| Pos | Field | Type |
|-----|-------|------|
| 1 | timestamp | number |
| 2 | subevent | string |
| 3 | sourceGUID | string |
| 4 | sourceName | string |
| 5 | sourceFlags | number |
| 6 | destGUID | string |
| 7 | destName | string |
| 8 | destFlags | number |

After base args, events have prefix args then suffix args.

## Prefixes

**Spell prefix** (SPELL_, RANGE_, SPELL_PERIODIC_):
- spellId (number)
- spellName (string)
- spellSchool (number)

**Environmental prefix** (ENVIRONMENTAL_):
- environmentalType (string) — "Drowning", "Falling", "Fatigue", "Fire", "Lava", "Slime"

**Swing prefix** (SWING_):
- (none)

**Inline prefix** (DAMAGE_SHIELD, DAMAGE_SHIELD_MISSED, DAMAGE_SPLIT):
- spellId, spellName, spellSchool inlined before suffix (not a standard prefix)

## Suffixes

### _DAMAGE
Used by: SPELL_DAMAGE, RANGE_DAMAGE, SPELL_PERIODIC_DAMAGE, DAMAGE_SHIELD, DAMAGE_SPLIT,
SWING_DAMAGE, ENVIRONMENTAL_DAMAGE

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | damage dealt |
| 2 | overkill | number | -1 if target alive |
| 3 | school | number | damage school bitmask |
| 4 | resisted | number | 0 if none |
| 5 | blocked | number | 0 if none |
| 6 | absorbed | number | 0 if none |
| 7 | critical | 1/nil | |
| 8 | glancing | 1/nil | |
| 9 | crushing | 1/nil | |

### _MISSED
Used by: SPELL_MISSED, RANGE_MISSED, SPELL_PERIODIC_MISSED, DAMAGE_SHIELD_MISSED,
SWING_MISSED

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | missType | string | ABSORB, BLOCK, DEFLECT, DODGE, EVADE, IMMUNE, MISS, PARRY, REFLECT, RESIST |
| 2 | amountMissed | number/nil | only for ABSORB, BLOCK, RESIST |

Note: isOffHand was added in a later client version (post-3.3.5), not present in 3.3.5.

### _HEAL
Used by: SPELL_HEAL, SPELL_PERIODIC_HEAL

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | total heal |
| 2 | overhealing | number | overheal amount |
| 3 | absorbed | number | heal absorb (e.g. Necrotic Aura) |
| 4 | critical | 1/nil | |

### _ENERGIZE
Used by: SPELL_ENERGIZE, SPELL_PERIODIC_ENERGIZE

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | power gained |
| 2 | powerType | number | 0=mana, 1=rage, 2=focus, 3=energy, 4=combo, 5=runes, 6=runic |

### _DRAIN
Used by: SPELL_DRAIN, SPELL_PERIODIC_DRAIN

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | amount drained |
| 2 | powerType | number | power type |
| 3 | extraAmount | number | amount gained by drainer (typically 0) |

### _LEECH
Used by: SPELL_LEECH, SPELL_PERIODIC_LEECH

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | amount leeched |
| 2 | powerType | number | -2=health, 0=mana, etc. |
| 3 | extraAmount | number | amount gained by leecher |

### _INTERRUPT
Used by: SPELL_INTERRUPT

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | extraSpellId | number | interrupted spell |
| 2 | extraSpellName | string | |
| 3 | extraSchool | number | |

### _DISPEL
Used by: SPELL_DISPEL

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | extraSpellId | number | dispelled aura |
| 2 | extraSpellName | string | |
| 3 | extraSchool | number | |
| 4 | auraType | string | "BUFF" or "DEBUFF" |

### _STOLEN
Used by: SPELL_STOLEN (Spellsteal)

Same as _DISPEL: extraSpellId, extraSpellName, extraSchool, auraType

### _DISPEL_FAILED
Used by: SPELL_DISPEL_FAILED

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | extraSpellId | number | aura that resisted |
| 2 | extraSpellName | string | |
| 3 | extraSchool | number | |

### _EXTRA_ATTACKS
Used by: SPELL_EXTRA_ATTACKS

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | amount | number | number of extra attacks |

### _AURA_APPLIED / _AURA_REMOVED / _AURA_REFRESH
Used by: SPELL_AURA_APPLIED, SPELL_AURA_REMOVED, SPELL_AURA_REFRESH

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | auraType | string | "BUFF" or "DEBUFF" |

### _AURA_APPLIED_DOSE / _AURA_REMOVED_DOSE

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | auraType | string | "BUFF" or "DEBUFF" |
| 2 | amount | number | stack count |

### _AURA_BROKEN

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | auraType | string | "BUFF" or "DEBUFF" |

### _AURA_BROKEN_SPELL

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | extraSpellId | number | breaking spell |
| 2 | extraSpellName | string | |
| 3 | extraSchool | number | |
| 4 | auraType | string | "BUFF" or "DEBUFF" |

### No-suffix events
_CAST_START, _CAST_SUCCESS, _INSTAKILL, _SUMMON, _RESURRECT, _CREATE:
(no suffix args — spell prefix only)

### _CAST_FAILED

| # | Field | Type | Notes |
|---|-------|------|-------|
| 1 | failedType | string | localized failure reason |

### UNIT_DIED, PARTY_KILL, UNIT_DESTROYED
(base args only, no prefix, no suffix)

## Power Types
0=Mana, 1=Rage, 2=Focus, 3=Energy, 4=Combo Points, 5=Runes, 6=Runic Power, -2=Health

## School Bitmask
1=Physical, 2=Holy, 4=Fire, 8=Nature, 16=Frost, 32=Shadow, 64=Arcane

## Notes
- overkill added in WotLK (not in TBC)
- overhealing on _HEAL added in 3.2/3.3
- absorbed on _HEAL (heal absorb) added in 3.3
- Boolean fields are 1 or nil, not true/false
- DAMAGE_SPLIT exists as a distinct subevent, uses inline prefix + _DAMAGE suffix
- DAMAGE_SHIELD and DAMAGE_SHIELD_MISSED use inline prefix (not standard spell prefix)
- spellName is part of the prefix; our vanilla DLL omits it (addon can look up from spellId)
- hideCaster was added in 4.1.0 (Cata), NOT present in WotLK 3.3.5
- Skada aliases DAMAGE_SHIELD and DAMAGE_SPLIT to SPELL_DAMAGE layout (prefix+suffix)
- Skada reads _AURA_APPLIED/REMOVED/REFRESH with (auraType, amount) — amount is nil for non-dose
