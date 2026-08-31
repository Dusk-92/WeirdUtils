# WeirdUtils third-party notices

Audit date: 2026-08-31

The root `LICENSE` contains a public-domain dedication for WeirdUtils-authored
material. That dedication does **not** override the licenses or rights of
third-party code, assets, fonts, game-derived media, or reference material.

## Source project history

The Git history imported into this repository contains substantial development
by MarcelineVQ and references the source project at:

- https://codeberg.org/MarcelineVQ/WeirdUtils

The later Dusk-92 GitHub commits are documented separately in
`Docs/SOURCE_PROVENANCE.md`.

## libdeflate

Vendored path:

- `src/weirdperformance/libdeflate/`

The bundled headers identify libdeflate version 1.25.

Upstream:

- https://github.com/ebiggers/libdeflate

License:

- MIT
- Copyright 2016 Eric Biggers
- Copyright 2024 Google LLC

A verbatim copy of the upstream license is preserved at:

- `LICENSES/libdeflate-MIT.txt`

The WeirdUtils public-domain dedication does not replace libdeflate's MIT
notice.

## VanillaFixes

The performance timer implementation explicitly identifies itself as:

- `src/weirdperformance/timer_fix.zig`
- "ported from VanillaFixes"

Upstream:

- https://github.com/hannesmann/vanillafixes

License:

- MIT
- Copyright (c) 2022 Hannes Mann

A verbatim copy is preserved at:

- `LICENSES/VanillaFixes-MIT.txt`

## WeirdDPSMate / DPSMate

Bundled path:

- `src/dpslog/WeirdDPSMate/`

The subtree identifies DPSMate as originally by Shino <Synced> - Kronos, with
later contributors including Torio.

License:

- GNU General Public License v3

The authoritative license is already bundled at:

- `src/dpslog/WeirdDPSMate/LICENSE`

The root public-domain dedication does not apply to this subtree.

The subtree also contains fonts, images, GraphLib textures, and bundled
libraries. The presence of the DPSMate GPL file is not used here to make an
unsupported claim about the separate underlying rights of every font or visual
asset. See `Docs/ASSET_PROVENANCE.md`.

## WSBT / Mik's Scrolling Battle Text material

Bundled path:

- `src/dpslog/WSBT/`

The source headers identify:

- Title: Mik's Combat Event Helper / Mik's Scrolling Battle Text
- Author: Mik
- Maintainer: Athene

No standalone license file was identified in this bundled WSBT subtree during
this audit.

Accordingly, the WeirdUtils public-domain dedication does not claim to
relicense this inherited material. Its exact licensing status remains
unresolved unless stronger upstream evidence is later preserved.

## zhook

Build dependency:

- https://codeberg.org/marcelinevq/zhook
- pinned commit: `f1b252ed61ad839f00310c386761d068f293ad0f`
- Zig package hash:
  `zhook-0.1.0-pFkSYC6FAACAnkqu0k_DJBWdL0gJjrM22IfXeQPJAMov`

`build.zig.zon` downloads zhook at build time; it is not committed as a
vendored source tree in this repository.

Its license was not independently verified during this GitHub-focused audit.
The WeirdUtils root license therefore makes no licensing claim over zhook.

## UnitXP_SP3 reference material

`src/ssemaths/math_sse.zig` explicitly identifies
`brues-code/UnitXP_SP3/polyfill.cpp` as a reference source for some function
behavior and formulas.

Reference repository:

- https://github.com/brues-code/UnitXP_SP3

No root project-wide license file was identified in UnitXP_SP3 during this
audit. Reference provenance is preserved without asserting that UnitXP_SP3
material is public domain under WeirdUtils' root license.

## libSiliconPatch reference

The SSE research comments also identify libSiliconPatch as a closed-source
symbol/export reference.

No libSiliconPatch binary is identified as a vendored dependency in the
WeirdUtils source tree. Reference to its symbols or behavior does not imply
ownership, affiliation, or a right to relicense that project.

## Game-facing visual assets

WeirdUtils bundles BLP/TGA assets under areas including:

- `src/minimapicons/assets/`
- `src/worldmarkers/assets/`
- `src/dpslog/WeirdDPSMate/images/`
- `src/dpslog/WeirdDPSMate/libs/GraphLib/GraphTextures/`

It also bundles fonts under:

- `src/dpslog/WeirdDPSMate/fonts/`

These materials are excluded from the root public-domain dedication unless a
specific file's rights are independently established.

Some paths and filenames correspond closely to World of Warcraft client
resource naming. This provenance audit does not claim that Dusk-92 or
MarcelineVQ owns the underlying Blizzard or third-party artwork.

See `Docs/ASSET_PROVENANCE.md`.

## SuperWoW and server compatibility

WeirdUtils contains compatibility logic and references for SuperWoW and
community-server environments.

Compatibility does not imply affiliation or endorsement. SuperWoW itself is
not relicensed by WeirdUtils.

## World of Warcraft / Blizzard

World of Warcraft, Warcraft, Blizzard Entertainment, and associated names,
marks, artwork, client data, and game assets remain the property of their
respective rights holders.

## Preservation rule

When third-party material is updated, replaced, or removed:

1. preserve its source and attribution;
2. preserve the applicable license or permission where known;
3. do not expand the root public-domain dedication to material whose rights are
   not held by WeirdUtils contributors;
4. keep provenance records even when a component stops being bundled.
