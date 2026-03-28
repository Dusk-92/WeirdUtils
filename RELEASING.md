# Releasing WeirdUtils

> **Remote:** https://codeberg.org/MarcelineVQ/WeirdUtils

## How the remote repo works

This project is developed entirely locally. The remote repo is **only** a
distribution point for releases - no source code is pushed.

The remote `main` branch contains `README.md` (built from the local
`DLL_README.md`), `weirdutils_api.h`, and issue templates under `.gitea/`.

A local clone of the remote repo lives at `remote/WeirdUtils/`. The wiki
lives at `remote/wiki/`. Use these for all remote operations - no tmp clones
needed.

## 1. Bump module versions

Each module has a `version` field in `build.zig`'s `module_list`. This is what
`GetWeirdUtilsVersion()` reports to Lua addons. Before building, bump the
version for any module that has changed since the last release:

```zig
// build.zig — module_list
.{ .name = "minimapicons", .version = "1.1", ... },
```

Only bump modules that actually changed. Use `git log --oneline -- src/<module>/`
to check what changed since the last release tag.

## 2. Build DLLs

Decide which modules to include in this release. Check `build.zig` for the
current list of module flags (`b.option(bool, ...)` declarations) and their
defaults. List them with:

```sh
zig build --help 2>&1 | grep 'Enable'
```

`all-variants` builds everything in one command: the combined DLL, the noperf
variant, and a standalone DLL per module. `-D` flags control which modules are
included across all of them -- disabled modules are excluded from the combined
DLL, noperf, and won't get a standalone variant built.

```sh
zig build all-variants -Doptimize=ReleaseSmall \
  -Dworldmarkers=false -Dinteract=false -Doutline=false \
  -Dframecrash=false -Ddpslog=false -Daddonperf=false \
  -Dssemaths=false -Dsilicon=false -Dtransform44=false
```

### Output locations

| Artifact | Path |
|----------|------|
| Combined DLL | `zig-out/bin/weirdutils.dll` |
| Variant DLLs | `zig-out/variants/<name>.dll` |

Verify:

```sh
ls -lh zig-out/bin/weirdutils.dll zig-out/variants/*.dll
```

## 3. Update the remote README

The remote README should match the features in this release. Start from
`DLL_README.md` and remove the sections for modules not being released -
keep the header, install instructions, and included feature sections exactly
as they are. Do NOT remove trailing spaces in `DLL_README.md` - they are
intentional Markdown line breaks.

The module name list in the Developer Notes section must also only list
released module names.

```sh
cd remote/WeirdUtils
# edit README.md: remove sections for modules not in this release
git add README.md
git commit -m "Update README for vX.Y.Z"
git push origin main
cd ../..
```

## 4. Write the release notes

Use this template - fill in the sections that apply, delete the rest.
Use `-` (not em dash) anywhere a dash would be used.

Always include an **Included** section listing every module in this release,
not just what changed. Users downloading a release should see the full list
of what they're getting:

```markdown
## What's New

- ...

## Bug Fixes

- ...

## Included

- **Module Name** - one-line description
- ...

## Notes

- Place DLLs next to `WoW.exe` and add to `dlls.txt`
- `weirdutils.dll` includes all features; individual DLLs are also provided
```

## 5. Create the release and upload DLLs

Uses `tea` (Gitea/Forgejo CLI) which handles release creation, tagging, and
asset upload in one command. The tag is created on the remote automatically.

Run from a clone of the remote repo, or specify `--repo` explicitly.
Only attach the combined DLL and the variant DLLs for modules in this release.

Only attach DLLs to the release - do NOT attach `weirdutils_api.h` as a
release asset. The header belongs in the repo itself (pushed to `main`),
not in the release downloads.

```sh
# Example: transmogfix + customassets + healtextfix release
tea release create \
  --repo MarcelineVQ/WeirdUtils \
  --tag vX.Y.Z \
  --target main \
  --title "vX.Y.Z" \
  --note-file release-notes.md \
  --asset zig-out/bin/weirdutils.dll \
  --asset zig-out/variants/transmogfix.dll \
  --asset zig-out/variants/customassets.dll \
  --asset zig-out/variants/healtextfix.dll
```

### Replacing a DLL on an existing release

Delete the old asset by name, then upload the new one:

```sh
tea release assets delete --repo MarcelineVQ/WeirdUtils -y v0.4.0 minimapicons.dll
tea release assets create --repo MarcelineVQ/WeirdUtils v0.4.0 zig-out/variants/minimapicons.dll
```

## 6. Hide source archives

Codeberg attaches empty source tar/zip by default. Hide them via API:

Get your token from the tea config:

```sh
grep 'token:' ~/.config/tea/config.yml | head -1 | awk '{print $2}'
```

Then hide the archives:

```sh
curl -s -X PATCH \
  -H "Authorization: token <your-token>" \
  -H "Content-Type: application/json" \
  -d '{"hide_archive_links":true}' \
  "https://codeberg.org/api/v1/repos/MarcelineVQ/WeirdUtils/releases/<release-id>"
```

Get the release ID using the API (not `tea release list --output json`, which
mangles keys like `tag-_name`):

```sh
tea api repos/MarcelineVQ/WeirdUtils/releases | python3 -c "
import sys,json; releases=json.load(sys.stdin)
r=[x for x in releases if x['tag_name']=='vX.Y.Z']
print(r[0]['id']) if r else print('not found')
"
```

## Known Issues

- **vanillafixes launcher**: Incompatible with WeirdUtils DLL injection. Users
  should load the DLL via WoW.exe + `dlls.txt` or another loader instead.

## Checklist

- [ ] Module versions bumped in `build.zig` for changed modules
- [ ] Check `RELEASE_NOTES.md` for unreleased changes — move into release notes
- [ ] Built with `ReleaseSmall` (both default and `all-variants`)
- [ ] Remote README updated — no unreleased module sections or names
- [ ] `weirdutils_api.h` trimmed to released DLL names only and uploaded
- [ ] Release created and DLLs uploaded via `tea`
- [ ] Source archives hidden
