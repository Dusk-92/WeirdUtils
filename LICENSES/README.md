# Third-party license records

The root `LICENSE` contains the WeirdUtils public-domain dedication, but its
scope is limited to material for which the applicable WeirdUtils authors have
the rights to make that dedication.

Third-party material keeps its own terms.

## Preserved records

- `libdeflate-MIT.txt`
  - applies to vendored `src/weirdperformance/libdeflate/`
  - upstream: https://github.com/ebiggers/libdeflate

- `VanillaFixes-MIT.txt`
  - relevant to the timer implementation explicitly ported from VanillaFixes
  - upstream: https://github.com/hannesmann/vanillafixes

## Existing in-tree license

- `../src/dpslog/WeirdDPSMate/LICENSE`
  - GNU GPL v3
  - applies to the WeirdDPSMate / DPSMate code as documented by that subtree

## Unresolved / external

The 2026-08-31 audit did not independently establish a project-wide license
for:

- bundled `src/dpslog/WSBT/` material;
- `brues-code/UnitXP_SP3`, used as a behavior/formula reference;
- the externally fetched Codeberg `zhook` dependency.

No license is invented for those components.

See `../THIRD_PARTY_NOTICES.md` for scope and provenance.
