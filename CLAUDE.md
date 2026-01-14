# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Vision

Terminaut is a Ghostty fork that transforms a MacBook Pro 16" into a dedicated Claude Code appliance with **game controller navigation** and **voice-first input**. The goal: use Claude Code without touching the keyboard.

**Core UX principles:**
- 8-bit game controller as primary navigation (PlayStation-style)
- One-button voice dictation for all text input
- Always-visible control panel replacing Claude Code's hidden/toggle UI
- Fullscreen-only, optimized for MacBook Pro 16"

**Two main screens:**

1. **Launcher** (LauncherView) - fullscreen grid of ALL projects, controller-navigable home screen
2. **Session View** - active Claude Code session with terminal + control panel

**Session layout: 2/3 + 1/3 split**
- Left (2/3): Ghostty terminal + tab bar (tabs = ACTIVE sessions only, not all projects)
- Right (1/3): **Control Panel** - interactive panels navigable with controller:
  1. **Project** - current project, switch projects
  2. **Context** - context % usage, manage context
  3. **Tools** - browse tools, enable/disable with button press
  4. **Todos** - select todos, mark complete, add new
  5. **Git/PRs** - select PR to jump into, view status
  6. **Agents/Background** - start/stop agents, kill tasks, view output

Controller navigates between panels (D-pad up/down) and within panels (D-pad left/right or A/B to act).

**Why wrap Claude Code?** Native Claude Code hides useful info behind toggles (context %, tool list). Terminaut surfaces this in always-visible panels. Also integrates Teleport (CLI ↔ web session switching) into controller-friendly UI.

## Workflow

**Always run `zig build` after making code changes.** Don't wait to be asked - build automatically to catch compile errors early.

## Build Commands

```bash
# Prerequisites
brew install zig
xcodebuild -downloadComponent MetalToolchain

# Build (creates zig-out/Ghostty.app)
zig build -Doptimize=ReleaseFast

# Debug build (default, better for development)
zig build

# Run directly
zig build run

# Run tests
zig build test
zig build test -Dtest-filter=<filter>

# Format code
zig fmt .              # Zig files
prettier --write .     # Everything else

# Clean
make clean
```

**macOS app notes:**
- Use `zig build`, NOT `xcodebuild` directly
- Requires Xcode 26 and macOS 26 SDK (can build on macOS 15)
- Built app outputs to `zig-out/Ghostty.app`

## Architecture

### Tech Stack
- **Core terminal (libghostty)**: Zig + Metal GPU rendering
- **macOS app shell**: Swift/SwiftUI
- **Terminaut UI**: SwiftUI (new code in `macos/Sources/Terminaut/`)

### Key Directories

```
src/                    # Shared Zig core (libghostty)
include/                # C API headers
macos/
├── Sources/
│   ├── App/macOS/      # Main app (AppDelegate.swift modified for Terminaut)
│   ├── Ghostty/        # Original Ghostty Swift UI
│   └── Terminaut/      # NEW: All Terminaut-specific code
│       ├── TerminautCoordinator.swift  # Main coordinator, keyboard/controller handling
│       ├── LauncherView.swift          # Fullscreen project grid
│       ├── ProjectStore.swift          # Project list (~/.terminaut/projects.json)
│       ├── SessionState.swift          # Reads dashboard state from Claude Code
│       ├── TerminautTerminalWrapper.swift  # Terminal + dashboard layout
│       └── Panels/                     # Dashboard panel components
```

### Data Flow

```
App Launch
    ↓
LauncherView (fullscreen project grid, controller-navigable)
    ↓
User selects project (controller or keyboard)
    ↓
TerminautCoordinator.launchProject()
    ↓
Creates Ghostty terminal with:
  - workingDirectory = project.path
  - command = /Users/pete/.local/bin/claude
    ↓
TerminautTerminalWrapper (2/3 terminal + 1/3 dashboard)
    ↓
Claude Code statusline.sh → ~/.terminaut/states/state-{window_id}.json
    ↓
Dashboard panels read JSON, display context/tools/todos/etc.
```

### State File Format

Claude Code's statusline writes to `~/.terminaut/states/state-{window_id}.json`:

```json
{
  "cwd": "~/project",
  "git_branch": "main",
  "model": "Claude Opus 4.5",
  "context_pct": 39,
  "weekly_pct": 6,
  "uncommitted": 2,
  "todos": [...]
}
```

## Key Modifications from Ghostty

**AppDelegate.swift** - Shows Terminaut launcher instead of default terminal:
```swift
if TerminalController.all.isEmpty && derivedConfig.initialWindow {
    TerminautCoordinator.shared.showLauncherWindow()
}
```

**TerminautCoordinator** - Central hub for:
- Launcher window management
- Project launch (creates terminal + dashboard wrapper)
- Keyboard/controller event handling
- Session lifecycle (returns to launcher when all sessions close)

## Current Status

**Built:**
- Ghostty fork builds and runs
- LauncherView - fullscreen project grid
- ProjectStore - project management, persists to ~/.terminaut/projects.json
- TerminautCoordinator - launcher/session orchestration
- Project selection launches Claude Code in correct directory
- Basic keyboard navigation in launcher
- Panel components started: StatusPanel, VitalsPanel, GitPanel, TodosPanel

**Needs Work:**
- Dashboard sidebar not attaching properly to terminal (TerminautTerminalWrapper)
- Tab bar for multiple active sessions
- Arrow key events not reaching launcher window consistently
- Cmd+L global shortcut to return to launcher
- Tools panel, Agents/Background panel (not yet created)
- Game controller input handling
- Voice dictation integration
- Accessibility permission shows "ghostty" instead of "terminaut"

## Related Files

- `~/.terminaut/projects.json` - Persisted project list
- `~/.terminaut/states/` - Per-window state files from Claude Code
- `~/.claude/statusline.sh` - Claude Code statusline that writes dashboard state

## Bundle Identity

- **Bundle ID**: `com.peteknowsai.terminaut`
- **Display Name**: Terminaut
- Designed to coexist with regular Ghostty installation
