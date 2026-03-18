# Ghostty Windows Port

This is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds native Windows support via a Win32 application runtime.

The goal is to track the upstream main branch while maintaining a native Windows port that runs as a standalone `.exe` — no WSL, no Cygwin, no compatibility layers.

## Status

**Early development** — the terminal is functional but many features are missing.

### Working
- Native Win32 window with OpenGL 4.6 rendering
- Terminal emulation (VT sequences, colors, scrollback)
- JetBrains Mono font rendering via FreeType + HarfBuzz
- Keyboard input with full modifier support (Ctrl, Alt, Shift)
- Mouse input (click, move, scroll wheel)
- Shell spawning via Windows ConPTY (cmd.exe, PowerShell, WSL)
- Window resize with terminal grid reflow
- Per-monitor DPI awareness
- Clipboard copy/paste (Ctrl+Shift+C/V)
- Window title updates from shell

### Known Issues
- Alignment panic on window close (shutdown ordering)
- Resize flicker (async rendering lag)
- No process exit detection (xev.Process type mismatch on Windows)
- No IME support for CJK input

### Not Yet Implemented
- Tabs and splits
- Font discovery (system fonts — currently uses bundled JetBrains Mono)
- Configuration UI
- Shell integration for PowerShell
- Multiple windows
- Custom key bindings
- Scrollbar
- Selection / URL detection
- Notifications

## Building

Requires [Zig](https://ziglang.org/download/) 0.15.2 or newer.

### Cross-compile from Linux/WSL (debug build)
```bash
zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32
```

### Cross-compile release build
```bash
zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=win32 -Doptimize=ReleaseFast
```

The executable is at `zig-out/bin/ghostty.exe`.

### Build Linux/GTK version (unchanged from upstream)
```bash
zig build "-fno-sys=gtk4-layer-shell"
```

## Architecture

The Windows port adds a `win32` application runtime (`src/apprt/win32/`) alongside the existing GTK (Linux) and embedded (macOS) runtimes. It reuses Ghostty's cross-platform core:

- **Terminal emulation**: Shared VT parser, screen, scrollback (`src/terminal/`)
- **Rendering**: OpenGL 4.3+ with WGL context management (`src/renderer/`)
- **Fonts**: FreeType rasterization + HarfBuzz shaping (`src/font/`)
- **PTY**: Windows ConPTY via `CreatePseudoConsole` (`src/pty.zig`)
- **I/O**: libxev with IOCP backend (`src/termio/`)

### Key files
```
src/apprt/win32/
  App.zig       — Win32 message loop, window class, action dispatch
  Surface.zig   — HWND wrapper, WGL context, input translation, clipboard
  win32.zig     — Win32 API type definitions and extern declarations
```

## Syncing with Upstream

This fork tracks `ghostty-org/ghostty` main branch. To sync:

```bash
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream
git merge upstream/main
```

Resolve any conflicts in `src/apprt/win32/` (our code) and files where we added `.win32` switch arms.

## Contributing

Contributions to the Windows port are welcome. Key areas that need work:

1. **Process exit detection** — fix xev.Process type mismatch or implement alternative
2. **Font discovery** — enumerate Windows system fonts via registry or DirectWrite
3. **Clean shutdown** — fix alignment panic during window close
4. **IME support** — WM_IME_* message handling for CJK input
5. **Tabs/splits** — Win32 tab control or custom implementation
6. **Shell integration** — PowerShell integration scripts

## License

Same as upstream Ghostty — see [LICENSE](LICENSE).
