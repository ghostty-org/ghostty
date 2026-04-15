# Developing winghostty

This fork is Windows-only. The native app target is Win32, the default build
is `winghostty.exe`, and the retained secondary deliverable is `libghostty-vt`.

If you plan to change code here, read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Build And Test

Use the standard Zig workflow from the repository root:

| Command | Description |
| --- | --- |
| `zig build` | Build the Win32 app and bundled resources |
| `zig build -Demit-exe=true` | Force-install `zig-out/bin/winghostty.exe` |
| `zig build test` | Run the full Zig test suite |
| `zig build test -Dtest-filter=win32` | Run Win32-focused tests |
| `zig build test -Dtest-filter=scroll` | Run scroll/input regression tests |
| `zig build test -Dtest-filter=keybind` | Run keybinding/default-behavior tests |
| `zig build -Demit-lib-vt` | Build the retained `libghostty-vt` library |

For normal development, prefer the narrowest verification that covers your
change, then run `zig build` before you finish.

## Toolchain

This fork is pinned to Zig `0.15.2` in CI. If you have multiple Zig versions
installed locally, verify the one on your PATH before debugging build issues.

If Zig fails before compilation because the dependency cache is empty or cannot
be hydrated automatically, seed it first from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
```

The repo also ships `scripts/dev-windows.ps1` and `scripts/dev-windows.cmd`
to open a Windows-native shell with the expected Visual Studio and Zig cache
environment already configured.

## Runtime Notes

- The application runtime is Win32.
- The renderer backend is OpenGL on Windows.
- The repo still retains `libghostty-vt` for Zig and C consumers.
- Cross-platform app packaging, GTK, and macOS app workflows have been removed
  from this fork and should not be reintroduced.

## Logging

Logging to `stderr` is always available. Debug builds also emit additional
diagnostic output.

Win32-specific local traces used during bring-up may also write to
`winghostty-win32.log` in the current working directory.

## Formatting

- Zig: `zig fmt .`
- Other docs/resources: `prettier -w .`

## Manual Validation

If your change touches input, rendering, or chrome behavior, manually verify:

1. Wheel mouse scrolling in a long buffer.
2. Precision touchpad scrolling, if available.
3. Fast sustained scrolling for flicker, title churn, or dropped repaint.
4. Keybindings affected by the change.
5. A fresh `zig build -Demit-exe=true` launch of `zig-out/bin/winghostty.exe`.

## Scope Guard

This fork is not trying to preserve the upstream macOS/GTK app surface.
When Windows-native behavior conflicts with upstream cross-platform behavior,
prefer the Windows-native result.
