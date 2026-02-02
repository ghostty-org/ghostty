# Ghostree

Fork of [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) with [worktrunk](https://worktrunk.dev/) integration.

## Git setup

Two remotes:
- `origin` = `sidequery/ghostree` (SSH: `git@github.com:sidequery/ghostree.git`)
- `upstream` = `ghostty-org/ghostty` (HTTPS)

Two key branches:
- `main`: Ghostree, our customizations on top of upstream Ghostty
- `upstream-main`: pure mirror of `upstream/main`, fast-forward only

## Versioning and tags

Ghostree uses `v0.x.y` tags (v0.1.0, v0.2.4, v0.3.0, etc.). Upstream Ghostty `v1.x.y` tags also exist in the repo history from merges. These are separate version lines, don't confuse them. Ghostree version is defined in:
- `build.zig.zon` (.version): canonical source
- `macos/Ghostty.xcodeproj/project.pbxproj` (MARKETING_VERSION): 6 occurrences for the main app targets. Other targets (tests, iOS, UITests) use upstream's `MARKETING_VERSION` values, leave those alone.

## Syncing with upstream

Always sync upstream-main first, then merge into main. Never merge upstream/main directly into main.

```bash
git fetch upstream
git checkout upstream-main
git merge upstream/main --ff-only
git push origin upstream-main
git checkout main
git merge upstream-main
# resolve conflicts keeping our customizations (bundle ID, version, agent integration, etc.)
```

When resolving conflicts: upstream may change indentation or restructure files. Keep our Ghostree-specific code but adopt upstream's style changes.

## Git rules

- Never rebase after merge. Never merge both pre-rebase and post-rebase versions.
- upstream-main is fast-forward only.
- Prefer squash merges for feature work into main.
- Don't force-push main. If history surgery is needed, create `legacy/...` backup ref first.
- `gh release create` requires commits to be pushed to origin first. The misleading "workflow scope" error usually means the target commit doesn't exist on remote.
- Use `gh api` to create releases if `gh release create` fails, then `gh release upload` for assets.

## Releases

Release title format: `Ghostree v0.X.Y` (always include "Ghostree" prefix and "v" before the version number). Update the homebrew cask in `sidequery/homebrew-tap` with the new version, sha256, and asset ID after uploading the DMG.

## History cleanup (2026-01-30)

`main` was rewritten to remove duplicated rebased commits. Backup ref: `legacy/main-pre-cleanup-2026-01-30`

## Bundle Identifier

Changed from `com.mitchellh.ghostty` to `dev.sidequery.Ghostree` in:
- Xcode project (project.pbxproj)
- Info.plist
- src/build_config.zig
- Swift source files (notifications, identifiers, etc.)

## Building

```bash
./scripts/release_local.sh
```

## Installing

```bash
brew install sidequery/tap/ghostree
```
