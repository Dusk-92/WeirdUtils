# WeirdUtils source provenance

Audit date: 2026-08-31

## Imported source history

The repository is not marked by GitHub as a fork, but its imported Git history
contains extensive source development authored by MarcelineVQ.

The repository documentation points to the historical/source project at:

- https://codeberg.org/MarcelineVQ/WeirdUtils

## Dusk-92 GitHub maintenance boundary

A comparison was made from the last inspected MarcelineVQ-authored baseline:

- base: `41191ce9a5b50cf38fc48f138b8339ed17f9cae8`
- pre-audit GitHub head:
  `947056f1c22c4816f85038dfb78abe61c1e4133b`

GitHub reports that the Dusk-92 head is four commits ahead of that baseline.

Only two paths differ in that comparison:

- `.github/workflows/release.yml`
- `src/main.zig`

The relevant later commits are:

- `82dc02e2e78ca43496286c14a732a562d2448570`
  — Add automated DLL release workflow
- `f4cbacb7f9e91f99e7409b3aa48a61fe6d96d978`
  — Fix DllMain return type for Zig 0.16
- `c4d133887a9730e346d0654031cfeefb7a77e065`
  — Run release build CI on main and support source refs
- `947056f1c22c4816f85038dfb78abe61c1e4133b`
  — Test full release packaging on main

This makes the authorship boundary unusually clear: the GitHub maintenance
layer should not be presented as authorship of the entire imported WeirdUtils
source tree.

## Third-party source boundaries

Known third-party or reference-derived areas include:

- `src/dpslog/WeirdDPSMate/` — DPSMate fork, GPL-3.0
- `src/dpslog/WSBT/` — Mik/Athene material, license unresolved in this audit
- `src/weirdperformance/libdeflate/` — libdeflate 1.25, MIT
- `src/weirdperformance/timer_fix.zig` — ported from VanillaFixes, MIT
- `src/ssemaths/math_sse.zig` — UnitXP_SP3 and libSiliconPatch references
- external `zhook` build dependency — pinned in `build.zig.zon`

See `THIRD_PARTY_NOTICES.md`.

## Documentation-pass boundary

No Zig, C, Lua, XML, build workflow, BLP, TGA, font, or other runtime asset is
intended to be modified by the 2026-08-31 licensing/provenance pass.

The final compare against the pre-audit head is the authoritative check for
that statement.
