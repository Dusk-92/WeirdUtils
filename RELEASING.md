# Releasing WeirdUtils

> **Remote:** https://codeberg.org/MarcelineVQ/WeirdUtils

## How the remote repo works

`main` on the remote holds the full source, the user-facing `README.md`,
`include/weirdutils_api.h`, and issue templates under `.gitea/`. Releases
attach pre-built DLLs to a tag on `main`.

This was previously a distribution-only remote - source lived locally and only
a trimmed README plus binaries were pushed. That is no longer the case; develop
against `main` and push directly.

The wiki clone lives at `remote/wiki/`. `remote/WeirdUtils/` is the old
distribution-only clone and is obsolete - it can be deleted.

## 0. Sync tags

`tea` creates tags on Codeberg, so fetch them before comparing against the
previous release:

```sh
git fetch --tags
```

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

## 3. Update the README

`README.md` documents every module, not just the released subset - the source
is public, so there is nothing to trim. Add a section for any new module.

Do NOT remove trailing spaces in `README.md` - they are intentional Markdown
line breaks.

## 4. Write the release notes

Write the release notes to `/tmp/release-notes-vX.Y.Z.md` - NOT inside the
project directory. They are a transient artifact consumed by `tea --note-file`
and should not pollute the repo root or end up in git status.

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

## 6. Source archives

Codeberg attaches source tar/zip to each release automatically. Now that the
repo contains the source, leave them visible - they are a useful artifact.

To hide them anyway, get your token from the tea config:

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

- [ ] Remote clone tags synced (`cd remote/WeirdUtils && git fetch --tags`)
- [ ] Module versions bumped in `build.zig` for changed modules
- [ ] Check `RELEASE_NOTES.md` for unreleased changes — move into release notes
- [ ] Built with `ReleaseSmall` (both default and `all-variants`)
- [ ] `README.md` has a section for any new module
- [ ] `include/weirdutils_api.h` lists all module DLL names
- [ ] Release created and DLLs uploaded via `tea`
