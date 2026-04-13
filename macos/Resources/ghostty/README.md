# Vendored Ghostty resources

This directory holds resources that are normally produced by the upstream
`zig build` into `zig-out/share/ghostty/`. We vendor them into the repo
so the Xcode build can bundle them into `Ghostties.app` independently
of the zig build.

## Why

`zig build` is broken on macOS 26 (undefined libc symbols like `_abort`,
`_free`, `_malloc` — see `docs/SESSION_NOTES.md` session 14). When the
build fails, `zig-out/share/ghostty/themes/` ends up empty. Xcode copies
from there into the app bundle, so the app then has no bundled themes
and errors out on launch with:

    theme "3024 Day" not found, tried path "…/.config/ghostty/themes/…"

Rather than block all Xcode builds on a zig fix, we vendor the two
directories that actually get consumed at runtime:

- `themes/` — 463 color scheme files from iTerm2-Color-Schemes
- `shell-integration/` — bash, fish, zsh, elvish, nushell hooks

Both are copied into `Ghostties.app/Contents/Resources/ghostty/` at
build time by `scripts/embed-ghostty-resources.sh`, wired up as an
Xcode "Run Script" build phase.

## Updating

These files originate from the upstream
[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
and [ghostty](https://github.com/ghostty-org/ghostty) repos. To refresh:

```bash
# Easiest path: copy from an installed upstream Ghostty build.
rsync -a --delete \
  /Applications/Ghostty.app/Contents/Resources/ghostty/themes/ \
  macos/Resources/ghostty/themes/
rsync -a --delete \
  /Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/ \
  macos/Resources/ghostty/shell-integration/
```

## When zig build is fixed

Once `zig build` works on macOS 26 again, this directory can be deleted
along with the `Run Script: Embed Ghostty Resources` build phase in
`macos/Ghostties.xcodeproj`. The existing folder reference at
`../zig-out/share/ghostty` will take over again.

Total size: ~1.9 MB, mostly tiny text files.
