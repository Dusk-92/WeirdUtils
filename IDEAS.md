# Ideas

## Transmog Toggle
Add an option to the TW Options menu to disable all transmogs. Works for the
local player (we have the real item objects and can look up base entry IDs from
descriptors). Does NOT work for other players -- the server only sends the
transmogged item entry in VISIBLE_ITEM fields, and the real entry is never
transmitted to other clients. Would need server-side support (e.g. a packet
flag or CVar the server respects) to strip transmogs on other players.

## Minimap Icon Tooltips
Mouseover popups on minimap tracking blips showing NPC/object name and type.
Reference implementation already exists -- check how it's done there.

## Unusable Portal Visual + Click Blocking
Covers summoned ritual objects (type 18: healthstone, summoning portal, ritual
of refreshment/doom) and mage portals (type 22: GAMEOBJECT_TYPE_SPELLCASTER).

Three states to distinguish:
1. **Interactable** -- usable, normal rendering
2. **Not interactable** -- `CallSpellCastHandler` (0x5f8800) returns 0 (wrong faction, not in group)
3. **Interactable but locked** -- `CallSpellCastHandler` returns 1, `GAMEOBJECT_FLAGS & 0x02` (GO_FLAG_LOCKED) set

Goals:
- Prevent clicking GOs in states 2 and 3 (clickthrough module, GO filter pass)
- Render states 2/3 in greyscale or desaturated to visually distinguish from usable ones

Click blocking fits in clickthrough's existing cascade filter (checkObjTypeDetour).
Greyscale rendering needs research into the client's GO model draw path -- may need
to intercept material/texture setup or set a per-object color tint before the draw call.

Module: clickthrough (own file, e.g. portal_filter.zig)
