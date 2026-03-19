<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Native Windows port of the Ghostty terminal emulator.
    <br />
    <a href="#status">Status</a>
    ·
    <a href="#building">Building</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="https://ghostty.org/docs">Upstream Docs</a>
  </p>
</p>

## About

This is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds **native Windows support** via a Win32 application runtime. It runs as a standalone `.exe` — no WSL, no Cygwin, no compatibility layers.

The goal is to track the upstream main branch while maintaining a native Windows port that leverages Ghostty's cross-platform core (terminal emulation, renderer, font system).

> **Upstream Ghostty** supports Linux (GTK) and macOS natively. This fork adds a `win32` application runtime alongside those existing backends. See the [upstream repository](https://github.com/ghostty-org/ghostty) for the original project.

## Status

**Functional proof-of-concept** — the terminal works for daily use but some features are still missing.

### Working

- Native Win32 window with OpenGL 4.6 rendering (WGL)
- Terminal emulation (full VT sequence support, colors, scrollback)
- Font rendering via FreeType + HarfBuzz (bundled JetBrains Mono + system font discovery via DirectWrite)
- Keyboard input with full modifier support
- Mouse input (click, drag selection, scroll wheel)
- Shell spawning via Windows ConPTY (cmd.exe, PowerShell, WSL)
- Win32 Input Mode (mode 9001) for full Unicode support through ConPTY
- IME support for CJK input (Japanese, Chinese, Korean)
- Window resize with terminal grid reflow
- Per-monitor DPI awareness
- Clipboard copy/paste (Ctrl+Shift+C/V)
- Window title updates from shell
- Process exit detection
- Multiple windows with proper lifecycle management
- Config file loading (`%LOCALAPPDATA%\ghostty\config`)
- Shell integration for PowerShell (prompt marking, CWD tracking, title)
- Dark mode window chrome (DWM)
- Configurable quit-after-last-window-closed with delay
- Fullscreen toggle (Ctrl+Enter)
- Background opacity / transparency (`background-opacity` config)
- Scrollbar (native Win32 scrollbar synced with terminal scrollback)
- Close confirmation dialog when a process is still running

### Not Yet Implemented

- Tabs and splits
- URL detection (clickable hyperlinks)
- Desktop notifications (Windows toast)
- Release build + installer (MSI/MSIX)

## Building

Requires [Zig](https://ziglang.org/download/) 0.15.2 or newer.

### Cross-compile from Linux/WSL2

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows
```

The executable is at `zig-out/bin/ghostty.exe`. Copy it to a Windows path and run it.

### Release build

```bash
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

## Configuration

Ghostty reads its config file from `%LOCALAPPDATA%\ghostty\config` (or `%XDG_CONFIG_HOME%\ghostty\config` if set). Example:

```
# Font
font-family = JetBrains Mono
font-size = 14

# Colors
background = #1e1e2e
foreground = #cdd6f4

# Shell
command = powershell.exe

# Behavior
quit-after-last-window-closed = true
```

See the [upstream documentation](https://ghostty.org/docs/config) for the full list of config options. Most settings work on Windows — the exceptions are platform-specific options (GTK, macOS).

## Architecture

The Windows port adds a `win32` application runtime (`src/apprt/win32/`) alongside the existing GTK (Linux) and AppKit (macOS) runtimes. It reuses Ghostty's cross-platform core:

- **Terminal emulation**: Shared VT parser, screen, scrollback (`src/terminal/`)
- **Rendering**: OpenGL 4.3+ with WGL context management (`src/renderer/`)
- **Fonts**: FreeType rasterization + HarfBuzz shaping + DirectWrite discovery (`src/font/`)
- **PTY**: Windows ConPTY via `CreatePseudoConsole` (`src/pty.zig`)
- **I/O**: libxev with IOCP backend (`src/termio/`)

### Key files

```
src/apprt/win32/
  App.zig       — Win32 message loop, window class, action dispatch
  Surface.zig   — HWND wrapper, WGL context, input translation, clipboard
  win32.zig     — Win32 API type definitions and extern declarations

src/shell-integration/powershell/
  ghostty-shell-integration.ps1  — PowerShell prompt marking, CWD, title
```

## Testing

A test harness runs from WSL2 using PowerShell automation:

```bash
bash test/win32/ghostty_test.sh all
```

Tests cover: launch/close, window properties, keyboard input, multiple windows, clipboard, config file loading, scrollbar, and close confirmation.

## Syncing with Upstream

This fork tracks `ghostty-org/ghostty` main branch. To sync:

```bash
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
git merge upstream/main
```

Conflicts will mainly be in files where `.win32` switch arms were added. The `src/apprt/win32/` directory is entirely new code.

## License

Same as upstream Ghostty — see [LICENSE](LICENSE).
