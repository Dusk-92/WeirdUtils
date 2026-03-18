# DPSLog Warden Concerns

Hooks and patterns that could trigger Warden false positives. Our addon is legitimate
(combat log enhancement), but we should understand the detection surface to reduce
headaches for server admins reviewing client modifications.

## What Warden Covers

Warden is Blizzard's anti-cheat system. On vanilla private servers, implementations vary
(some use stock mangos Warden, some extend it, some disable it). The main detection
vectors are:

1. **Memory scanning**: Warden reads specific addresses and compares against known-good
   values. Patched bytes at scanned addresses trigger detection.
2. **Module scanning**: Warden enumerates loaded DLLs and checks against blocklists
   (by name or hash). Our DLL loads via injection, so it shows up in the module list.
3. **Window enumeration**: Checks for known cheat tool windows (not relevant to us).
4. **Driver checks**: Checks for known cheat drivers (not relevant).
5. **Timing checks**: Detects speed hacks via tick count validation (not relevant).

### What We Should Avoid

- **Patching packet handler dispatch tables**: The opcode-to-handler mapping tables are
  commonly scanned. Modifying entries there is high risk.
- **Patching Warden itself**: Obvious detection surface; we don't touch it.
- **Known DLL names**: Some servers blocklist specific DLL names. Our DLL name
  ("weirdutils") is not on any known list.
- **Hooking at addresses that overlap with known Warden scan points**: If Warden reads
  the first N bytes of a function and we've overwritten them with a JMP, it detects the
  modification. We use zhook's Detour which patches the function prologue.

### What's Generally Safe

- **Calling game functions** via indirect CALL: No memory modification, just normal
  function calls. GetSpellNameById, getNameByGUID, etc.
- **Reading game memory**: Simple pointer dereferences. Descriptor reads, object manager
  traversal, aura slot reads.
- **Hooking internal processing functions** (not packet handlers): These are deep inside
  the call chain, less likely to be scanned.
- **Registering custom Lua events**: We modify the event count but don't patch any
  Warden-monitored jump tables.

## Current Hook Strategy

We hook **downstream processing functions** (0x62xxxx range) rather than packet handlers
(0x5Exxxx range) where possible. Downstream hooks are lower risk because:
- They're internal client functions, not dispatch table entries
- Warden scans typically check packet handler jump tables
- The downstream functions are called after packet validation

## Hooks That Are Packet Handlers (Higher Risk)

| Address | Function | Why packet-level |
|---------|----------|-----------------|
| 0x5E85E0 | SpellNonMeleeDmgLogHandler | Downstream loses school field; no viable alternative |
| 0x626DD0 | PeriodicAuraLogHandler | IS the handler; no downstream exists |
| 0x6255B0 | MeleeDispatcher | Shared handler for opcode range 0x143-0x14A |
| 0x6E7640 | SpellStartHandler | SPELL_CAST_START/SUCCESS |
| 0x6E7330 | CastResultHandler | SPELL_CAST_FAILED |

**Mitigation**: These are all registered via `setClientIndexedPointers` (0x5AB650), not
in a flat dispatch table. Warden typically scans flat opcode tables, not the indexed
handler registration system. Risk is moderate, not high.

## Hooks That Are Safe (Downstream)

| Address | Function | Subevent |
|---------|----------|----------|
| 0x62C770 | ProcessSpellPowerDrainMessage | SPELL_HEAL |
| 0x62BAB0 | ProcessSpellCombatResult | SPELL_MISSED |
| 0x62CA20 | ProcessSpellDrainEffectMessage | DAMAGE_SHIELD |
| 0x626A10 | DisplaySpellInterruptMessage | SPELL_INTERRUPT |
| 0x62CBE0 | ProcessInstaKillSpellMessage | SPELL_INSTAKILL |
| 0x62D9F0 | (extra attacks handler) | SPELL_EXTRA_ATTACKS |
| 0x62AAC0 | ProcessEnvironmentalDamage | ENVIRONMENTAL_DAMAGE |
| 0x628890 | PartyKillLogHandler | PARTY_KILL |
| 0x605860 | HandleUnitDeath | UNIT_DIED |
| 0x6123F0 | SetSpellTarget | SPELL_AURA_APPLIED |
| 0x612320 | CastSpell (aura remove) | SPELL_AURA_REMOVED |
| 0x628C20 | ProcessMultipleSpellInterrupts | SPELL_DISPEL_FAILED |
| 0x6E75F0 | HandleSpellInterruptUpdate | SPELL_CAST_FAILED (others) |
| 0x62CA00 | ProcessStandardPowerGainMessage | SPELL_ENERGIZE |

## Event Registration

We register COMBAT_LOG_EVENT at slot 549 by hooking FrameScript_CreateEvents (0x703D90)
and bumping the event count. This modifies the event table size but doesn't patch any
Warden-monitored code.

## Memory Reads

All descriptor reads (health, power, aura slots) use `readMem` which is a simple
pointer dereference -- no API hooking involved.

## GetSpellNameById (0x6264B0) / getNameByGUID (0x55F080)

Called via `hook.call` (indirect CALL instruction). Not hooked/patched -- we just call
them as normal functions. No Warden concern.

## Remaining WotLK Parity Gaps

Features not yet implemented, with notes on Warden implications:

### amountMissed (partial absorb/block/resist on misses)

The downstream hook ProcessSpellCombatResult (0x62BAB0) doesn't receive the miss amount.
Options:
1. Hook SMSG_SPELLLOGMISS packet handler (0x5E7E00) -- **higher Warden risk**
2. Access the CDS buffer from the downstream hook -- needs investigation, the buffer
   may still be readable if the packet handler hasn't cleaned it up
3. Track state: when we see a partial absorb/block in a damage event that also has a
   miss component, carry the amount forward

**Recommendation**: Option 2 first (no new hooks). If CDS is stale, option 3.

### sourceFlags / destFlags (COMBATLOG_OBJECT_* bitfield)

Constructable from GUID type bits and descriptor flags. No new hooks needed -- pure
memory reads. Requires defining the WotLK COMBATLOG_OBJECT_* constants and mapping
vanilla unit types to them.

### Boolean 1/nil (critical, glancing, crushing)

SignalEventParam always pushes numbers via `%d`. To push nil for false booleans, we'd
need to bypass SignalEventParam and push args directly onto the Lua stack using
`lua_pushnil` / `lua_pushnumber`. Requires finding the Lua state pointer and calling
Lua C API functions directly. No Warden concern (just function calls), but invasive
change to the event-push mechanism.

### Interrupter / Dispeller / Damage Shield spell IDs

Solvable with a cast tracking ring buffer -- no new hooks. On SPELL_CAST_SUCCESS, record
(casterGUID, spellId, timestamp) for interrupt-type, dispel-type, and damage-shield-type
spells. When the corresponding event fires, look up the most recent matching cast by the
same caster. Pure memory tracking, no Warden concern.

### SPELL_ENERGIZE amount (RESOLVED)

Now hooked via ProcessStandardPowerGainMessage (0x62CA00), downstream of
SMSG_SPELLENERGIZELOG (opcode 0x151). Receives spellId, powerType, and display amount
directly. Safe downstream hook -- no Warden concern.
