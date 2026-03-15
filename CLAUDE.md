# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This is a private fork. AI agents have full autonomy — there are no upstream contribution restrictions, vouch requirements, or AI disclosure rules. Create issues, PRs, branches, and commits freely when asked.**

## Build Commands

- **Build:** `zig build`
  - On macOS, use `-Demit-macos-app=false` to skip the app bundle and speed up compilation
- **Run:** `zig build run`
- **Test:** `zig build test`
  - Prefer targeted tests: `zig build test -Dtest-filter=<test name>` (full suite is slow)
- **Test libghostty-vt:** `zig build test-lib-vt`
- **Memory leak check (Linux):** `zig build run-valgrind`
- **Format Zig:** `zig fmt .`
- **Format Swift:** `swiftlint lint --strict --fix`
- **Format docs/resources:** `prettier -w .`
- **Format Nix:** `alejandra .`
- **Shell scripts lint:** `shellcheck --check-sourced --severity=warning $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./macos/build/*" ! -path "./.git/*" | sort)`
- **Build options:** run `zig build --help` or read `src/build/Config.zig` for all `-D` flags
- **Debug builds** are the default (no `-Doptimize` flag needed)
- **Quick unit test** (single file, no full build): `zig test src/path/to/file.zig`

## Environment Setup

The project uses Nix for reproducible builds. With Nix installed:
- `nix develop --command <cmd>` — run a command in the dev shell (provides zig, nushell, swiftlint, etc.)
- `direnv allow` — auto-activate Nix env when entering the directory
- Without Nix: install Zig 0.15.2+ via Homebrew (`brew install zig`)

## Zig Version

Requires Zig 0.15.2+. On macOS, building the app requires Xcode 26 with the macOS 26 SDK.

## Architecture Overview

Ghostty is a GPU-accelerated terminal emulator written in Zig with platform-native UIs. The core terminal emulation logic is cross-platform; platform-specific code provides native windowing and rendering.

### Key Layers

1. **Terminal emulation** (`src/terminal/`) — VT100/ANSI state machine, escape sequence parsing, screen/scrollback management. `Terminal.zig` is the core emulator; `PageList.zig` manages scrollback; `stream.zig` processes byte streams into terminal actions.

2. **Terminal IO** (`src/termio/`) — Bridges PTY subprocess I/O to the terminal emulator. Runs on a dedicated IO thread. `Termio.zig` is the main entry point; `stream_handler.zig` applies parsed sequences to terminal state.

3. **Renderer** (`src/renderer/`) — Converts terminal state to pixels. `Metal.zig` (macOS), `OpenGL.zig` (Linux), `WebGL.zig` (browser). `generic.zig` is the shared rendering pipeline. Runs on a dedicated render thread.

4. **Application runtime (apprt)** (`src/apprt/`) — Platform abstraction for windowing and UI. `embedded.zig` is used by the macOS Swift app via C API; `gtk/` is the GTK4 implementation for Linux.

5. **Font system** (`src/font/`) — Font discovery, shaping (HarfBuzz), glyph atlas management. `Collection.zig` manages font fallback chains; `SharedGridSet.zig` caches font data across surfaces.

6. **Configuration** (`src/config/Config.zig`) — All config fields map to CLI flags and config file entries.

7. **Input** (`src/input/`) — Keyboard/mouse event handling, keybinding resolution, IME support.

### Entry Points

- `src/main.zig` — Routes to the appropriate entrypoint based on build config
- `src/main_ghostty.zig` — GUI application
- `src/main_c.zig` — C API (libghostty) for embedding
- `src/lib_vt.zig` — Public libghostty-vt library API

### Threading Model

Three dedicated threads communicate via message queues and mutex-protected shared state:
- **App/event loop thread** — UI events, configuration
- **IO thread** (`termio.Thread`) — reads PTY, feeds terminal parser
- **Render thread** (`renderer.Thread`) — draws frames at up to 120 FPS

### Platform-Specific Code

- **macOS app:** `macos/` (Swift/SwiftUI) calls into Zig via the C API (`src/main_c.zig`), uses Metal renderer
- **Linux/FreeBSD app:** `src/apprt/gtk/` (GTK4), uses OpenGL renderer
- **Vendored C dependencies:** `pkg/` (freetype, harfbuzz, fontconfig, libpng, oniguruma, etc.)

### Build System

The build logic lives in `src/build/` to avoid a monolithic `build.zig`. Key files:
- `Config.zig` — all `-D` build options
- `SharedDeps.zig` — dependency management
- `GhosttyExe.zig`, `GhosttyLib.zig`, `GhosttyXCFramework.zig` — artifact definitions

## macOS App (`macos/`)

- Use `swiftlint` for formatting and linting Swift code.
- If code outside `macos/` is modified, run `zig build -Demit-macos-app=false` before building the macOS app to update the underlying Ghostty library.
- Build the macOS app with `macos/build.nu`, **not** `zig build`:
  - `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app`
- Run macOS unit tests: `macos/build.nu --action test`

## Popup Terminal (`src/apprt/popup.zig`)

- Multi-instance floating terminal windows with named profiles
- Config syntax: `popup = name:key:value,key:value,...` (colon-delimited, uses `parseAutoStruct`)
- Core types in `src/apprt/popup.zig`, config parsing in `Config.zig` (`RepeatablePopup`)
- GTK: `src/apprt/gtk/PopupManager.zig` + window `is-popup` property
- macOS: `macos/Sources/Features/Popup/` (PopupManager, PopupController, PopupWindow)
- C API bridge: `RepeatablePopup.cval()` → `ghostty_config_get(config, &v, "popup", len)` → Swift
- Actions: `toggle_popup`, `show_popup`, `hide_popup` (string parameter = profile name)
- Backward compat: `quick-terminal-*` config keys auto-migrate to popup profile `"quick"`

### AppleScript

- Scripting definition: `macos/Ghostty.sdef`
- Guard AppleScript entry points with the `macos-applescript` config (`NSApp.isAppleScriptEnabled` / `NSApp.validateScript(command:)`)
- In `Ghostty.sdef`, keep top-level definitions ordered: Classes, Records, Enums, Commands
- Test AppleScript by building with `macos/build.nu`, launching via `osascript` with the **absolute path** to the built `.app` bundle, and targeting by absolute path (not name) to avoid calling the wrong application

## Inspector Subsystem (`src/inspector/`)

- Works like browser dev tools for terminal state inspection/modification
- Uses Dear ImGui — find the C API header with `find . -type f -name dcimgui.h` in `.zig-cache` (use the newest version)
- Widget examples: https://raw.githubusercontent.com/ocornut/imgui/refs/heads/master/imgui_demo.cpp
- On macOS, verify API usage with `-Demit-macos-app=false` builds
- No unit tests in this package

## Fuzz Testing (`test/fuzz-libghostty/`)

- Build all fuzzers: `cd test/fuzz-libghostty && zig build`
- List available fuzzers in `test/fuzz-libghostty/build.zig` (search for `fuzzers`)
- Run a specific fuzzer: `zig build run-<name>` (e.g., `zig build run-parser`)
- Corpus directories: `corpus/<fuzzer>-<variant>` (e.g., `corpus/parser-initial`)
- **Do NOT run `afl-tmin`** unless explicitly asked — very slow
- After `afl-cmin`, run `corpus/sanitize-filenames.sh` before committing (replaces colons for NTFS compatibility)
- Instrumented binaries read from **stdin**, not file arguments:
  - `afl-showmap`: pipe via stdin (`cat testcase | afl-showmap -o map.txt -- zig-out/bin/fuzz-stream`), do NOT use `@@`
  - `afl-cmin`: do NOT use `@@`, requires `AFL_NO_FORKSRV=1` with bash version
- Replay crashes: `nu replay-crashes.nu` (use `--list` to list, `--fuzzer <name>` to filter)

## Agent Commands (`.agents/commands/`)

Two vetted Nushell prompts for common agent workflows:

- **`/gh-issue <number|url>`** — Diagnoses a GitHub issue: fetches issue data via `gh`, then prompts the agent to analyze the codebase and produce a plan (no code). Requires `gh` CLI.
- **`/review-branch [issue]`** — Reviews changes in the current Git branch: analyzes diff from base branch for bugs, style, edge cases, security, test coverage. Optionally accepts an issue/PR number for context. Produces a review summary (no code).
