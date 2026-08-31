# WeirdUtils binary and release provenance

Audit date: 2026-08-31

## Source repository

At the audited pre-documentation head
`947056f1c22c4816f85038dfb78abe61c1e4133b`, the source tree contains no
committed release `.dll` or `.exe` files.

Release DLLs are packaging/build outputs rather than checked-in binaries.

## GitHub Actions release workflow

`.github/workflows/release.yml` builds the standard public module DLLs with:

- Zig 0.16.0
- target/build configuration defined by the repository source
- `zig build all-variants -Doptimize=ReleaseSmall`

The workflow collects the generated DLLs and creates `SHA256SUMS.txt` before
publishing release assets.

## WeirdPerformance release exception

The GitHub release workflow intentionally excludes the normal
`weirdperformance` variant from the standard source build.

Instead, it downloads:

- `weirdperformance.dll`
- from a Codeberg release under `Dusk92/WeirdUtils`
- tag `0.7.3` as configured by
  `CUSTOM_WEIRDPERFORMANCE_TAG`

The workflow validates that the downloaded file has a plausible Windows PE
header and then includes it in the generated SHA-256 manifest.

Therefore a GitHub WeirdUtils release is not composed exclusively of DLLs
compiled in that same workflow: `weirdperformance.dll` is a separately
sourced prebuilt release artifact.

This distinction should remain documented whenever the release workflow
changes.

## Build-time zhook dependency

`build.zig.zon` pins zhook to:

- source:
  `https://codeberg.org/marcelinevq/zhook/archive/f1b252ed61ad839f00310c386761d068f293ad0f.tar.gz`
- Zig package hash:
  `zhook-0.1.0-pFkSYC6FAACAnkqu0k_DJBWdL0gJjrM22IfXeQPJAMov`

The source is fetched during a build and is not vendored into this GitHub
repository.

## Vendored libdeflate

`src/weirdperformance/libdeflate/` contains libdeflate source code (version
1.25 according to the bundled header). The build compiles the required C files
into the WeirdPerformance module.

libdeflate is MIT-licensed and is documented separately in
`THIRD_PARTY_NOTICES.md` and `LICENSES/libdeflate-MIT.txt`.

## Release maintenance rule

For each release:

1. retain the exact source ref used for compiled DLLs;
2. retain the source/tag of any prebuilt imported DLL;
3. publish or retain SHA-256 checksums;
4. keep third-party license records alongside the source project;
5. do not describe a prebuilt imported artifact as compiled from the current
   GitHub commit unless that has actually been verified.
