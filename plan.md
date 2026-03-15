# tmux -CC Native Tabs/Splits Support — High-Level Plan

## Problem

Running `tmux -CC` in Ghostty does nothing visible to the user. Ghostty already has a complete tmux control mode protocol parser and a viewer state machine that captures pane content into internal `Terminal` instances, but these are never surfaced as native UI. The critical gap is the `// TODO` at `src/termio/stream_handler.zig:456` — the `.windows` action from the viewer is unimplemented.

## Goal

When a user runs `tmux -CC` in a Ghostty terminal:
- Each tmux **window** becomes a native Ghostty **tab**
- Each tmux **pane** becomes a native Ghostty **split**
- Keyboard input in a pane routes back to tmux via `send-keys`
- Tmux notifications (`%output`, `%layout-change`, etc.) update the correct pane in real time
- Standard shortcuts (Cmd+T, Cmd+D, Cmd+W) create/close tmux windows/panes
- Detaching or exiting tmux restores the original terminal

This mirrors iTerm2's tmux -CC integration.

## Architecture

```
Host Surface (hidden, PTY ↔ tmux process)
  ├── StreamHandler → Viewer (parses tmux protocol)
  │     └── Per-pane Terminal instances (already working)
  └── TmuxController (NEW — bridges viewer state to native UI)
        ├── tmux window @1 → Native Ghostty Tab 1
        │     ├── pane %0 → Surface (Tmux backend, no PTY)
        │     └── pane %1 → Surface (Tmux backend, no PTY)
        └── tmux window @2 → Native Ghostty Tab 2
              └── pane %2 → Surface (Tmux backend, no PTY)
```

### Key Concepts

- **Host surface**: The surface where `tmux -CC` was typed. Its PTY stays alive as the command channel to tmux. The tab is hidden from the user.
- **Pane surfaces**: New surfaces with a `tmux` backend (no PTY, no subprocess). They share the viewer's per-pane `Terminal` instance for rendering. User input is converted to `send-keys` commands written to the host PTY.
- **TmuxController**: New orchestration layer that diffs the viewer's window/pane state against the current native UI and emits apprt actions to create/close/rearrange tabs and splits.

## What Already Exists

| Component | File | Status |
|-----------|------|--------|
| Protocol parser (all notifications) | `src/terminal/tmux/control.zig` | Complete |
| Viewer state machine (lifecycle, pane capture, live updates) | `src/terminal/tmux/viewer.zig` | Complete |
| Layout parser (tmux layout strings with checksums) | `src/terminal/tmux/layout.zig` | Complete |
| DCS 1000p detection and routing | `src/terminal/dcs.zig` | Complete |
| Stream handler (creates Viewer, processes `.command` actions) | `src/termio/stream_handler.zig` | Partial — `.windows` is TODO |

## What Needs to Be Built

| Component | Purpose |
|-----------|---------|
| **`tmux` termio backend** | Surfaces without a real PTY. Input → `send-keys`, resize → `resize-pane`. |
| **TmuxController** | Diffs viewer state vs native UI. Creates/closes tabs and splits. |
| **New apprt actions** (`tmux_sync`, `tmux_exit`) | Platform layer responds to tmux lifecycle events. |
| **Surface.init dual path** | Create surfaces with either `exec` or `tmux` backend. |
| **macOS Swift handlers** | Respond to tmux actions by managing native tabs/splits. |
| **Host surface hiding** | Hide on tmux enter, restore on exit/detach. |
| **Keybinding interception** | Cmd+T/D/W → tmux commands instead of Ghostty actions in tmux mode. |

## Key Design Decisions

1. **Shared Terminal instances** — Pane surfaces share the viewer's `Terminal` (no duplication, no sync issues). The renderer reads directly from the viewer's per-pane Terminal.

2. **Host surface stays alive** — Its PTY is the only communication channel to tmux. Hiding the tab (not destroying the surface) is essential.

3. **macOS first** — Initial implementation targets the embedded apprt (macOS/Swift). GTK support can follow the same pattern.

4. **One backend addition** — Adding `tmux` to the existing `Backend` union in `backend.zig` is clean and follows the existing extensibility pattern. Each method has a clear tmux-specific behavior.

5. **Action-based communication** — The controller communicates with the platform layer through the existing apprt action system, keeping the architecture consistent.

## Data Flow

### Output: tmux → screen
```
tmux process → host PTY → StreamHandler → Viewer.receivedOutput()
  → viewer's pane Terminal updated via VT stream
  → controller triggers renderer_wakeup on the pane's Surface
  → renderer reads shared Terminal → pixels on screen
```

### Input: keyboard → tmux
```
user types in pane Surface → Tmux backend queueWrite()
  → formats "send-keys -t %<pane_id> -H <hex>\n"
  → writes to host PTY → tmux process
```

### Structural: tmux layout → native UI
```
tmux sends %layout-change → Viewer processes → emits .windows action
  → StreamHandler calls controller.syncWindows()
  → controller diffs old vs new → emits tmux_sync apprt action
  → macOS Swift creates/removes/rearranges tabs and splits
```
