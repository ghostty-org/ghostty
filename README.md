<h1 align="center">winghostty</h1>

<p align="center">
  <em>A Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end.</em>
  <br />
  Native Win32 runtime · OpenGL renderer · Shared terminal core with Ghostty
</p>

<p align="center">
  <a href="https://github.com/amanthanvi/winghostty/releases">Releases</a>
  ·
  <a href="docs/getting-started.md">Getting started</a>
  ·
  <a href="docs/status.md">Status</a>
  ·
  <a href="HACKING.md">Hacking</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
  ·
  <a href="SECURITY.md">Security</a>
</p>

---

## What is winghostty?

winghostty is a terminal emulator for Windows. It pairs:

- The **Ghostty terminal core** — VT parser, screen and scrollback, font
  pipeline, and renderer — forked from
  [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty).
- A **native Win32 application runtime** written for this fork: real Windows
  tab bar, per-monitor DPI scaling, DWM dark title bar, IME, drag-and-drop,
  native right-click menus, and a WSL-aware shell picker.

It also ships `libghostty-vt`, the Ghostty VT library, as a retained
deliverable for Zig and C consumers.

It is intended for developers who are comfortable editing a plain-text
configuration file and clicking through a SmartScreen warning on first
install.

## Project status

winghostty is a young, single-maintainer fork. First fork commit: 2026-04-06.
First public releases: 2026-04-16.

- **Supported platform:** Windows 10 and Windows 11 on x64.
- **Releases:** unsigned installer + portable ZIP. Windows SmartScreen will
  warn on first run; that is expected until code signing lands.
- **Feedback:** use
  [Discussions](https://github.com/amanthanvi/winghostty/discussions) for
  questions. GitHub Issues are reserved for reproducible bugs.
- **No cross-platform app:** macOS and Linux app runtimes are not shipped
  from this repo and are not planned. `libghostty-vt` remains portable for
  library consumers.
- **Coexistence:** winghostty runs as its own top-level app window. It does
  not register as a Windows Terminal profile provider; installing it
  alongside Windows Terminal, WezTerm, or Alacritty is fine.
- **Accessibility:** screen reader / UI Automation support is planned and
  is not yet shipping.

## What works today

- Native Win32 runtime: tab bar with overflow, horizontal / vertical splits,
  per-monitor DPI scaling, DWM dark title bar, right-click context menus,
  IME, drag-and-drop of files.
- OpenGL 4.3 renderer via WGL.
- Shared Ghostty terminal core: VT parsing, scrollback, bracketed paste,
  mouse tracking, OSC 8 hyperlinks, Kitty graphics protocol, shell
  integration for bash / zsh / fish / PowerShell.
- Windows-aware shell selection: PowerShell, `cmd`, Git Bash, opt-in WSL.
- In-app profile picker that auto-detects installed shells.
- GitHub Releases updater, notify-only, gated to one check per 24 hours.
- High-contrast (HC) mode detection and palette switching.
- `libghostty-vt` as a retained Zig / C library deliverable.

A precise list, including what is experimental and what is out of scope,
is in **[docs/status.md](docs/status.md)**.

## Install

Download the latest build from **[Releases](https://github.com/amanthanvi/winghostty/releases)**:

| File | Use when |
| --- | --- |
| `winghostty-<version>-windows-x64-setup.exe` | You want a normal install with a Start menu entry. |
| `winghostty-<version>-windows-x64-portable.zip` | You want to run without installing. |
| `SHA256SUMS.txt` | Verifying downloads. |

On first run, Windows SmartScreen may say *"Windows protected your PC"*.
Click **More info** → **Run anyway**. Releases are unsigned right now; code
signing is planned.

Full walk-through — installer, portable, uninstall —
**[docs/getting-started.md](docs/getting-started.md)**.

## First run

On first launch, winghostty creates its config folder and writes a template:

```
%LOCALAPPDATA%\winghostty\config.ghostty
```

The template sets no options — defaults live in the binary. To see every
option with inline docs:

```powershell
winghostty +show-config --default --docs | more
```

A minimal config:

```ini
font-family = JetBrains Mono
font-size   = 12
# Pick a theme from: winghostty +list-themes
theme       = Dracula
```

Reload config without restarting: **Ctrl + Shift + ,**

## Keybindings

Default keybindings follow Windows conventions. Common ones:

| Action | Binding |
| --- | --- |
| Copy | `Ctrl+Shift+C` |
| Paste | `Ctrl+Shift+V` |
| New tab | `Ctrl+Shift+T` |
| Close tab | `Ctrl+Shift+W` |
| Next / previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Split right / down | `Ctrl+Shift+O` / `Ctrl+Shift+E` |
| Start search | `Ctrl+Shift+F` |
| Increase / decrease font | `Ctrl+=` / `Ctrl+-` |
| Reload config | `Ctrl+Shift+,` |

Full list, plus the keybind grammar for chords and rebinding:

```powershell
winghostty +list-keybinds
winghostty +show-config --default --docs
```

## Profiles

winghostty auto-detects installed Windows shells (PowerShell, `cmd`, Git
Bash, opt-in WSL) and exposes them through an in-app profile picker. To
pin a specific shell, set `command = <path>` in your config.

## Privacy

winghostty does not send telemetry or analytics. The only outbound network
call from the app is the GitHub Releases updater (when enabled), which
hits GitHub's public API. Crash reports, when produced, are stored locally
and never uploaded (see below).

## Updates

```ini
auto-update = check
```

The updater checks `api.github.com/repos/amanthanvi/winghostty/releases/latest`
at most once every 24 hours. It is **notify-only**: it opens the release
page if a newer stable version exists and never replaces binaries silently.
`auto-update = download` currently behaves the same as `check`.

## Crash reports

winghostty does not upload crash reports. The app keeps a local directory:

```
%LOCALAPPDATA%\winghostty\crash
```

On Windows the Sentry initialization path is a no-op today, so some builds
may produce nothing in this directory in practice. The `+crash-report` CLI
reads anything that is there:

```powershell
winghostty +crash-report
```

Contents, if any, may include sensitive memory from the crashed process;
review before sharing.

## Build from source

Most users should install from Releases. If you want to build:

**Requirements**

- Windows 10 or 11 on x64
- **Zig 0.15.x (patch ≥ 2)** — enforced at compile time via
  `src/build/zig.zig::requireZig`. Newer 0.15 patch releases (`0.15.3`,
  etc.) are accepted; 0.15.0 / 0.15.1, 0.14.x, and 0.16.x will fail to
  compile.
- Visual Studio 2022 (Community is fine) — MSVC toolchain on PATH
- Git for Windows

The build script additionally rejects building the `win32` app runtime for
non-Windows targets, returning
`error.WindowsOnlyAppRuntimeRequiresWindowsTarget`.

**Build**

```powershell
zig build -Demit-exe=true
```

Output: `zig-out\bin\winghostty.exe`.

If Zig cannot reach `deps.files.ghostty.org` directly in your environment,
seed the dependency cache first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

For a pre-configured developer shell (Visual Studio + Git + Zig cache
environment variables):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/dev-windows.ps1
```

Build, test, and runtime notes for contributors are in **[HACKING.md](HACKING.md)**.
Packaging the installer and portable ZIP yourself is covered in
**[PACKAGING.md](PACKAGING.md)**.

## Relationship to Ghostty

winghostty is a fork, not a re-implementation. Upstream is tracked as the
`upstream` Git remote; the fork relationship is visible in full Git
history.

**Shared with upstream Ghostty**
- `src/terminal/` — VT parsing, screen state, scrollback, search, Kitty
  graphics protocol, OSC handling
- `src/font/` — font discovery and rasterization (HarfBuzz, FreeType)
- `src/renderer/` — OpenGL cell/image/shader pipeline
- `src/input/`, `src/config/`, `src/termio/`, `src/crash/`,
  `src/shell-integration/`, `src/inspector/`, `libghostty-vt`

**New in this fork**
- `src/apprt/win32.zig` — Win32 application runtime
- `src/apprt/win32_theme.zig` — theme tokens, DWM integration, accent
  helpers, HC handling (extracted from `win32.zig` in commit `a759eb6`)
- `src/update/github_releases.zig` — updater
- `dist/windows/` and `scripts/package-windows.ps1` — Windows packaging

**Removed from this fork**
- Upstream `macos/` Xcode project
- Upstream `src/apprt/gtk/` runtime
- Flatpak / Snap / Linux desktop packaging

Because the terminal core is shared, most Ghostty configuration options,
themes, and shell-integration behavior apply here directly. When
Windows-native behavior conflicts with upstream cross-platform behavior,
this fork prefers the Windows-native result.

## Contributing

Bug reports, reproducible issues, and focused PRs are welcome. Read
**[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AI_POLICY.md](AI_POLICY.md)**
first. For usage questions and design discussion, use
**[Discussions](https://github.com/amanthanvi/winghostty/discussions)**.

## License

MIT. Copyright © 2024 Mitchell Hashimoto, Ghostty contributors. See
**[LICENSE](LICENSE)**.

Fork-specific changes are contributed under the same license by the fork's
maintainer and contributors.
