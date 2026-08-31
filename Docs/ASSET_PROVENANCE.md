# WeirdUtils asset provenance

Audit date: 2026-08-31

No visual or font asset is intended to be modified during this documentation
pass.

The root WeirdUtils public-domain dedication does **not** automatically apply
to bundled third-party or game-facing assets.

## MinimapIcons assets

Path:

- `src/minimapicons/assets/`

Git tree SHA-1:

- `4d3848aa2ba1e32b8cfb5a8d4d67eaf4ead09e31`

The tracking directory contains 21 BLP resources under a game-style path:

- `Interface/Minimap/Tracking/`

Examples include `Banker.blp`, `FlightMaster.blp`,
`QuestAvailable.blp`, `Repair.blp`, and `ObjectIcons.blp`.

Immediate repository provenance is known, but this audit does not establish
the original creator or redistribution license of every underlying image.

## WorldMarkers assets

Path:

- `src/worldmarkers/assets/`

Known subtrees:

- `Spells/`:
  `5a3628820673332f3fdd481e80f3f6e81efed9e8`
- `World/`:
  `9783e9c15f31a527c9d6f81e45b6c7ba251f27e3`

Files include game-facing names such as raid-target textures, spell/VFX
textures, and resources under:

- `World/Expansion01/Doodads/Zulaman/Doors/`

These paths strongly indicate compatibility with game resource naming, but the
documentation does not assert a specific extraction history without stronger
evidence.

No ownership or public-domain claim is made over underlying Blizzard or other
third-party artwork.

## WeirdDPSMate fonts

Path:

- `src/dpslog/WeirdDPSMate/fonts/`

Git tree SHA-1:

- `48374570b2c9659e1d781d4014c17fecd1b0f7f1`

The directory contains 13 TTF/OTF font files.

Their individual font licenses were not independently established during this
audit. They are therefore not treated as public-domain material merely because
they are bundled in WeirdUtils or inside the GPL-licensed DPSMate subtree.

## WeirdDPSMate images

Path:

- `src/dpslog/WeirdDPSMate/images/`

Git tree SHA-1:

- `bd649c1cffffc9b7d9b92fc001748531cb4ffa92`

The directory includes UI images, class icons, status-bar textures, and other
TGA resources.

The immediate bundled provenance is documented, while underlying visual rights
remain separate from the WeirdUtils root license.

## GraphLib textures

WeirdDPSMate also bundles GraphLib texture resources under:

- `src/dpslog/WeirdDPSMate/libs/GraphLib/GraphTextures/`

These include pie/line/triangle and related TGA resources. Their presence is
not used to infer a new license from WeirdUtils.

## Rights boundary

World of Warcraft, Warcraft, Blizzard Entertainment, and associated names,
marks, artwork, interface resources, client data, and game assets remain the
property of their respective rights holders.

An exact Git tree or blob hash establishes file identity/provenance at a point
in history. It does not by itself establish ownership or a right to relicense
the underlying work.

## Maintenance

When assets are added, removed, or replaced:

1. record source and creation history where known;
2. record hashes/tree identity where practical;
3. preserve font/image license notices when available;
4. do not place unresolved third-party/game-facing assets under the root
   public-domain dedication by implication.
