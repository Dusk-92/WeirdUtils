# Unreleased Changes

Track notable changes here between releases. Clear this file when cutting a new release
(move contents into the release notes on Codeberg).

## What's New

- **World Markers** - place up to 5 animated Cataclysm-style markers at any position in
  the world. Slash commands (`/wm 1`, `/cwm`), keybindings, full Lua API, and automatic
  group sync between WeirdUtils users. Requires party/raid leader or raid assist.

- **DPSLog (COMBAT_LOG_EVENT)** - WotLK 3.3.5 CLEU parity for vanilla 1.12.1. 37 subevents
  across 24 hooks with full structured data: source/dest names via name cache, spell names
  via SpellRec, overkill/overheal from unit descriptors, WotLK-standard field ordering
  (blocked before absorbed, separate glancing/crushing booleans). Drain Life reclassified
  as SPELL_PERIODIC_LEECH. SPELL_ENERGIZE with actual amount/powerType via dedicated
  SMSG_SPELLENERGIZELOG hook. Periodic energize divides by power display factor (rage/10).
  Includes `GetSpellInfo(spellId)` Lua API (name, rank, icon, castTime, minRange, maxRange)
  with verified SpellRec/SpellIcon/SpellRange/SpellCastTimes DBC offsets.
  Embedded tracker addon (`/dpslog`). Full event reference in wiki.

- **Interact** - smart interaction helpers: "Interact Nearest" right-clicks the closest
  interactable NPC or object within 5 yards, "Loot All Corpses" bulk loots nearby corpses.
  Keybindings and Lua API. Already documented in DLL_README but not yet released.

- **Crash Fix (framecrash)** - prevents crashes from stale UI frame anchor pointers.
  Already documented in DLL_README but not yet released.

- **Outlines** - renders glowing colored outlines around units. Already documented in
  DLL_README but not yet released.

- **Addon Profiling Stub (addonperf)** - TBC+ addon CPU profiling API stub
  (GetScriptCPUUsage). Internal/experimental, not in DLL_README.

- **Minimap Quest Tracking** - shows nearby NPCs with available quests (yellow !) on the
  minimap. Reads the per-player quest status cached on unit objects by the client's
  SMSG_QUESTGIVER_STATUS handler. Enabled by default in the tracking dropdown, togglable
  like other NPC tracking categories.
