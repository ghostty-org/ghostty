# Windows Port — Technical Details

This document covers technical details specific to the Windows port. For an overview, see [README.md](README.md).

## How It Works

The Windows port is implemented as a `win32` application runtime (`src/apprt/win32/`). Like the GTK runtime on Linux, it handles:

- Window creation and lifecycle (Win32 API)
- OpenGL context management (WGL)
- Input translation (Win32 messages → Ghostty key/mouse events)
- Clipboard (Win32 clipboard API)
- Shell spawning (ConPTY, already existed upstream)

Everything else — terminal emulation, rendering, font shaping, I/O — is shared with Linux and macOS.

## Win32 Input Mode (Mode 9001)

ConPTY has a known limitation where CJK/Unicode characters get truncated during console input event generation. Win32 Input Mode (escape sequence `\x1b[?9001h`) solves this by sending key events as VT sequences that include the full Unicode codepoint:

```
\x1b[Vk;Sc;Uc;Kd;Cs;Rc_
```

ConPTY requests this mode automatically. Ghostty checks keybindings first (e.g., Ctrl+Shift+C for copy) and only sends Win32 input sequences if no binding matched. Sequences are written directly to the PTY to avoid side effects like selection clearing.

## IME Support

CJK input method support via:
- `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` / `WM_IME_ENDCOMPOSITION`
- `VK_PROCESSKEY` detection to skip IME-intercepted keys
- `WM_CHAR` deduplication (suppressed when `handleKeyEvent` already produced text via `ToUnicode`)
- IME candidate window positioning via `ImmSetCompositionWindow`

## Shell Integration

PowerShell integration is automatically injected when `shell-integration = detect` and `command = powershell.exe` (or `pwsh.exe`). The integration script provides:

- **OSC 133** semantic prompt marking (prompt start/end, command start/end with exit status)
- **OSC 7** current working directory reporting
- **OSC 2** window title updates
- **Cursor shape** changes (bar at prompt, reset on command execution)

Injection mechanism: the command is modified to `powershell.exe -NoExit -Command ". '<script path>'"`.

## Resize Flicker Mitigation

Several techniques reduce visible flicker during window resize:

1. **WM_ERASEBKGND** handler fills with the configured terminal background color
2. **DWM dark mode** (`DWMWA_USE_IMMERSIVE_DARK_MODE`) for dark window chrome
3. **Synchronous resize** during live drag: the main thread waits (via a Windows Event) for the renderer to present one frame before returning from `WM_SIZE`
4. **WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE** tracking to only block during user-initiated resize

Some DWM compositor flicker remains — this is a known limitation of OpenGL + DWM interaction.

## Font Discovery

System font discovery uses DirectWrite COM APIs:
- `IDWriteFactory` → `GetSystemFontCollection`
- `IDWriteFontCollection` → enumerate font families
- `IDWriteFont` → get style, weight, stretch properties
- `IDWriteFontFace` → `TryGetFontTable` for raw font data

Falls back to bundled JetBrains Mono if no system font matches.

## Build Targets

| Target | Command |
|--------|---------|
| Windows debug (cross-compile from Linux) | `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows` |
| Windows release | `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows -Doptimize=ReleaseFast` |
| Linux/GTK (unchanged) | `zig build` |

## Linked Libraries

The Win32 runtime links: `opengl32`, `gdi32`, `user32`, `dwrite`, `dwmapi`, `imm32` (via `src/build/SharedDeps.zig`).
