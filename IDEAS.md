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

Click blocking: DONE (portal_filter.zig in clickthrough module).

Greyscale rendering research:
- `SetModelAlpha` (0x710da0): writes float to sceneObject+0x1C4 (__thiscall). Alpha only.
- `SetAlphaValue` (0x76ac50): writes float to entity+0xBC, calls through vtable+0x8C.
- `SetModelAlpha_2` (0x76d120): reads byte at entity+0xC8, propagates to entity+0x318.
- Fade system (0x672ef0): writes alpha to entity[0x22] (entity+0x88) via SetMemoryPointer.
- D3D9 render states: outline module (d3d9_hook.zig) has full pattern for per-object
  D3D state manipulation via stencil buffer.
- Greyscale options:
  1. D3DRS_TEXTUREFACTOR + D3DTOP_MODULATE per draw call (set grey color before object draws)
  2. Pixel shader override (D3D9 SetPixelShader to a desaturation shader)
  3. Find an existing color tint field on the model instance (not found yet)
- `adjustColorSaturation` (0x74d794): client has a desaturation function built in.
  Takes (outputRGBA*, inputRGBA*, saturationFactor). 0.0 = greyscale, 1.0 = full color.
  Uses standard luminance weights at 0x818878/187c/1880. No xrefs found (may be unused).
- `GetModelDiffuseColor` / `SetModelDiffuseColor`: reads/writes sceneObject+0x184 (3 floats RGB).
  `GetModelAmbientColor` / `SetModelAmbientColor`: sceneObject+0x190 (3 floats RGB).
  `SetModelAlpha`: sceneObject+0x1C4 (1 float). These are data accessors, not code functions.
- M2 model rendering does NOT go through simple GxDevice SetTexture wrappers -- uses a
  different submission path. Only RenderTextureQuads (UI) calls GxDevice::SetTexture.
- Viable approaches:
  1. Write grey diffuse color (e.g. 0.3, 0.3, 0.3) to sceneObject+0x184 per frame
     for targeted GOs. Need to find the GO -> scene object pointer chain.
  2. Hook D3D9 DrawIndexedPrimitive (like outline module) and set D3DRS_TEXTUREFACTOR
     to grey for targeted objects. Requires identifying which DIP calls belong to which GO.
  3. Set alpha to 0.5 via sceneObject+0x1C4 for a simpler "faded" visual instead of greyscale.
- Next: find the GO -> entity -> scene object pointer chain so we can access +0x184.
