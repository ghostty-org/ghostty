# Ghostty macOS GPU Selection Build

This artifact contains a local macOS ReleaseFast build of Ghostty with the
`macos-gpu = high-performance` configuration enabled.

Contents:

- `Ghostty.app.zip`: installable macOS app archive.
- `config/ApplicationSupport.config`: config from `~/Library/Application Support/com.mitchellh.ghostty/config`.
- `config/dotconfig.config`: config from `~/.config/ghostty/config`.
- `config/dotconfig-theme-assets.tar.gz`: `ghostty-theme`, `shaders/`, README, and reload script from `~/.config/ghostty`.

Install:

```sh
unzip Ghostty.app.zip
cp -R Ghostty.app /Applications/Ghostty.app
```

The app archive was built from branch `codex/macos-gpu-selection` with Zig 0.15.2
and `-Doptimize=ReleaseFast`.
