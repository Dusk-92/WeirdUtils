# Releasing WeirdUtils

> **Remote:** https://codeberg.org/MarcelineVQ/WeirdUtils

## How the remote repo works

This project is developed entirely locally. The remote repo is **only** a
distribution point for releases - no source code is pushed.

The remote `main` branch contains a single file: `README.md` (built from the
local `DLL_README.md`). This must be set up once when creating the repo:

```sh
tea repo create --name WeirdUtils --description "Vanilla WoW 1.12.1 utility DLLs" --login MarcelineVQ
```

Codeberg disables releases on new repos by default. Enable via API
(get your token from `grep 'token:' ~/.config/tea/config.yml | head -1 | awk '{print $2}'`):

```sh
curl -s -X PATCH \
  -H "Authorization: token <your-token>" \
  -H "Content-Type: application/json" \
  -d '{"has_releases":true}' \
  "https://codeberg.org/api/v1/repos/MarcelineVQ/WeirdUtils"
```

Then push the initial README:

```sh
# In a temporary directory:
git init && git remote add origin ssh://git@codeberg.org/MarcelineVQ/WeirdUtils.git && git checkout -b main
cp /path/to/weirdutils/DLL_README.md README.md
git add README.md
git commit -m "Add README"
git push origin main
```

After that, the remote `main` only needs updating when `DLL_README.md` changes.

## 1. Build DLLs

Decide which modules to include in this release. Check `build.zig` for the
current list of module flags (`b.option(bool, ...)` declarations) and their
defaults. List them with:

```sh
zig build --help 2>&1 | grep 'Enable'
```

### Combined DLL

Build `weirdutils.dll` with only the modules for this release. Explicitly
disable everything not being included - defaults may enable modules you don't
want:

```sh
# Example: only transmogfix + customassets + healtextfix
zig build -Doptimize=ReleaseSmall \
  -Dscreenshot=false -Dinteract=false -Doutline=false \
  -Dworldmarkers=false -Dframecrash=false -Dlogsessions=false \
  -Dminimapicons=false \
  -Dtransmogfix=true -Dcustomassets=true -Dhealtextfix=true
```

### Individual variant DLLs

```sh
zig build all-variants -Doptimize=ReleaseSmall
```

This builds all variants - you only attach the ones for this release.

### Output locations

| Artifact | Path |
|----------|------|
| Combined DLL | `zig-out/bin/weirdutils.dll` |
| Variant DLLs | `zig-out/variants/<name>.dll` |

Verify:

```sh
ls -lh zig-out/bin/weirdutils.dll zig-out/variants/*.dll
```

## 2. Update the remote README

The remote README should match the features in this release. Start from
`DLL_README.md` and remove the sections for modules not being released -
keep the header, install instructions, and included feature sections exactly
as they are. Do NOT remove trailing spaces in `DLL_README.md` - they are
intentional Markdown line breaks.

The module name list in the Developer Notes section must also only list
released module names.

```sh
# from a clone or worktree of the remote repo
# edit README.md: remove sections for modules not in this release
git add README.md
git commit -m "Update README for vX.Y.Z"
git push origin main
```

## 3. Write the release notes

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

## 4. Create the release and upload DLLs

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

## 5. Hide source archives

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

## Checklist

- [ ] Built with `ReleaseSmall` (both default and `all-variants`)
- [ ] Remote README updated — no unreleased module sections or names
- [ ] `weirdutils_api.h` trimmed to released DLL names only and uploaded
- [ ] Release created and DLLs uploaded via `tea`
- [ ] Source archives hidden
