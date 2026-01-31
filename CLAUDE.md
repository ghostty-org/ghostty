# Ghostree

Fork of [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) with [worktrunk](https://worktrunk.dev/) integration.

## Branches

- `main` - Our customized version with Ghostree branding and worktrunk sidebar
- `upstream-main` - Tracks `ghostty-org/ghostty` main branch (no customizations)

## Syncing with upstream

```bash
git fetch upstream
git checkout upstream-main
git merge upstream/main --ff-only
git push origin upstream-main
```

To merge upstream changes into main:
```bash
git checkout main
git merge upstream-main
# resolve conflicts, keeping our customizations
```

## Git workflow (avoid duplicate commits)

This repo is a fork and upstream moves fast. To avoid “same patch twice” history:

- Never rebase a branch after it has been merged, and never merge both the pre-rebase and post-rebase versions.
- Keep upstream syncing in `upstream-main` only (fast-forward only), then merge `upstream-main` into `main`.
- Prefer squash merges for feature work into `main` (one commit per PR).
- Avoid force-pushing `main`. If history surgery is required, create and push a `legacy/...` backup ref first.

## History cleanup (2026-01-30)

`main` was rewritten to remove duplicated rebased commits while keeping identical content (tree hash match). Backup ref:

- `legacy/main-pre-cleanup-2026-01-30`

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
