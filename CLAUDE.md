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
