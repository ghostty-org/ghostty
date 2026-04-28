# Ghostty Kanban - Project Documentation

## Overview

Ghostty Kanban is a sidebar kanban board integrated into the [Ghostty terminal emulator](https://ghostty.org), enabling developers to manage Claude Code CLI sessions directly within the terminal environment.

**Core Features:**
- Kanban board with Todo, In Progress, Review, Done columns
- Link Claude Code sessions to Ghostty terminal splits
- Real-time session status tracking via JSONL file monitoring
- Drag-and-drop task management
- Light/dark theme support
- Responsive layout adapting to sidebar width

## Architecture

### Hybrid Architecture

The UI uses a **hybrid WebView + Swift** approach:

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                         │
│  Web UI (HTML/CSS/JavaScript)                               │
│  - Renders kanban board, tasks, sessions                   │
│  - Handles all user interactions                           │
│  - Loaded via WKWebView                                    │
└────────────────────────┬────────────────────────────────────┘
                         │ webkit.messageHandlers bridge
┌────────────────────────┴────────────────────────────────────┐
│                    Bridge Layer (Swift)                       │
│  KanbanWebView                                              │
│  - Routes messages between JS and Swift                    │
│  - Syncs BoardState to WebView                             │
│  - Handles layout (width) propagation                      │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Data Layer (Swift)                        │
│  BoardState                                                   │
│  - Manages tasks, sessions, theme                          │
│  - Handles persistence                                      │
│  KanbanModels (Priority, Status, Session, KanbanTask)        │
└─────────────────────────────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Integration Layer                          │
│  SidePanelViewModel                                         │
│  - Bridge to Ghostty surface API                           │
│  - Session↔Surface mapping                                 │
└─────────────────────────────────────────────────────────────┘
```

**Why Hybrid?**
- **Rapid iteration**: UI changes don't require Swift recompilation
- **Prototype fidelity**: HTML/CSS prototype becomes production UI
- **Native performance**: Core logic remains in Swift
- **Flexibility**: Best tool for each layer

### Session-Surface Integration

Sessions are Claude Code conversations linked to Ghostty terminal splits:

```
┌──────────────────────────────────────────────────────────────┐
│                    Claude Session                             │
│  ~/.claude/projects/*/.jsonl (read-only)                    │
│  - Messages, status, timestamps                            │
└─────────────────────────┬────────────────────────────────────┘
                          │ SessionFileWatcher
┌─────────────────────────┴────────────────────────────────────┐
│                    SessionManager                             │
│  .ghostty/sessions.json                                     │
│  - Links sessionId ↔ surfaceId                             │
│  - Tracks cwd, branch, worktree                            │
└─────────────────────────┬────────────────────────────────────┘
                          │ ghostty_surface_* C APIs
┌─────────────────────────┴────────────────────────────────────┐
│                    Ghostty Surface                           │
│  Terminal split instances                                    │
│  - Create/focus splits                                      │
│  - Send commands                                            │
└─────────────────────────────────────────────────────────────┘
```

## Data Models

### Task

```swift
struct KanbanTask: Identifiable, Codable {
    var id: UUID
    var title: String
    var description: String
    var priority: Priority
    var status: Status
    var sessions: [Session]
    var isExpanded: Bool
}
```

### Priority

```swift
enum Priority: String, Codable, CaseIterable {
    case p0  // Critical - red
    case p1  // High - orange
    case p2  // Medium - yellow
    case p3  // Low - gray
}
```

### Status

```swift
enum Status: String, Codable, CaseIterable {
    case todo
    case inProgress
    case review
    case done
}
```

### Session

```swift
struct Session: Identifiable, Codable {
    var id: UUID
    var title: String              // First 10 chars of first user message
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String
}
```

### SessionStatus

```swift
enum SessionStatus: String, Codable {
    case running    // Green - active
    case idle       // Gray - no activity > 2 min
    case needInput  // Orange - waiting for user
}
```

## File Structure

```
macos/Sources/Ghostty/SidePanel/
├── KanbanWebView.swift         # WebView bridge + HTML/CSS/JS
├── SidePanelView.swift         # Sidebar container
├── SidePanelViewModel.swift    # Terminal bridge
├── KanbanBoardState.swift      # State management
├── KanbanModels.swift          # Data types
├── KanbanPersistence.swift     # JSON persistence
├── KanbanTheme.swift           # Theme colors
├── ThemeToggleButton.swift     # Theme toggle (SwiftUI, unused)
├── ColumnView.swift            # Column component (SwiftUI, unused)
├── TaskCardView.swift          # Task card (SwiftUI, unused)
├── TaskModalView.swift         # Task modal (SwiftUI, unused)
├── SessionPanelView.swift      # Session panel (SwiftUI, unused)
├── SessionModalView.swift      # Session modal (SwiftUI, unused)
└── PriorityBadge.swift         # Priority badge (SwiftUI, unused)

docs/
├── README.md                   # This file
├── old/                       # Historical documentation
│   ├── ghostty-kanban-full.md
│   ├── PLAN.md
│   ├── 2026-04-27-sidebar-kanban.md
│   └── 2026-04-27-session-surface-integration.md
└── superpowers/               # Agent guidance (if applicable)
```

> **Note**: SwiftUI components (ColumnView, TaskCardView, etc.) are retained for reference but replaced by the WebView implementation.

## UI Layout

### WebView HTML Structure

```html
<body>
  <div class="toolbar">
    <button id="newTaskBtn">New Task</button>
    <button id="themeToggle">Dark/Light</button>
  </div>
  <div class="kanban-board" id="board">
    <div class="column" data-status="todo">
      <div class="column-header">...</div>
      <div class="column-content">...</div>
    </div>
    <!-- More columns -->
  </div>
  <div class="modal-overlay" id="taskModal">...</div>
</body>
```

### Responsive Behavior

| Sidebar Width | Layout |
|---------------|--------|
| ≥ 600px | Horizontal scroll, columns side-by-side |
| < 600px | Vertical stack, full-width columns |

### Theme Variables

```css
:root {
  --bg-primary: #dcdcdc;
  --bg-secondary: #fff;
  --accent: #007aff;
  --danger: #ff3b30;
  --success: #34c759;
  /* ... */
}

[data-theme="dark"] {
  --bg-primary: #1e1e1e;
  --bg-secondary: #252525;
  --accent: #0a84ff;
  /* ... */
}
```

## Message Bridge Protocol

### JavaScript → Swift

Messages sent via `window.webkit.messageHandlers.kanbanBridge`:

```javascript
// Theme toggle
{ type: "themeToggle", isDark: true }

// Add task
{ type: "addTask", task: { title: "...", description: "...", priority: "p2" } }

// Update task
{ type: "updateTask", taskId: "uuid", task: { title: "...", priority: "p1" } }

// Move task (drag-drop)
{ type: "moveTask", taskId: "uuid", newStatus: "in-progress" }

// Toggle expand
{ type: "toggleExpand", taskId: "uuid" }

// Remove session
{ type: "removeSession", taskId: "uuid", sessionId: "uuid" }

// Add session
{ type: "addSession", taskId: "uuid" }
```

### Swift → JavaScript

```javascript
// State sync
updateBoardState({ tasks: [...] })
setDarkMode(true)

// Layout update
updateLayout(width, isNarrow)
```

## Session-Surface Integration

### SessionManager

```swift
class SessionManager {
    func loadSessions() -> [Session]
    func saveSessions([Session])

    func createSession(cwd: String, isWorktree: Bool, worktreeName: String?) -> Session
    func linkSessionToSurface(sessionId: String, surfaceId: UInt64)
    func unlinkSurface(surfaceId: UInt64)

    func navigateToSession(_ session: Session)
    func updateSessionStatus(_ sessionId: String, status: SessionStatus)
}
```

### Ghostty C API (Proposed)

```c
uint64_t ghostty_surface_split_with_command(
    void *surface_ptr,
    int direction,    // 0=right, 1=down, 2=left, 3=up
    const char *command,
    const char *cwd,
    const char *title
);

void ghostty_surface_text(void *surface_ptr, const char *text, size_t len);
uint64_t ghostty_surface_get_id(void *surface_ptr);
void ghostty_app_focus_surface(void *app_ptr, uint64_t surface_id);
```

### Session Status Detection

From JSONL parsing:

| Condition | Status |
|-----------|--------|
| `AskUserQuestion` tool in last message | `needInput` |
| Text ends with `?` pattern | `needInput` |
| Activity within 2 minutes | `inProgress` |
| No activity > 2 minutes | `idle` |

## Storage

| Data | Location | Scope |
|------|----------|-------|
| Kanban tasks | `~/.config/ghostty/tasks.json` | Global |
| Session↔Surface mapping | `.ghostty/sessions.json` | Per-project |
| Claude session history | `~/.claude/projects/*/*.jsonl` | Global (read-only) |

## Building

```bash
cd macos
xcodebuild -scheme Ghostty -configuration Debug build
```

Or via Zig (for core only):

```bash
zig build
```

## Development

### Commands

| Command | Description |
|---------|-------------|
| `zig build` | Build core |
| `zig build test` | Run tests |
| `swiftlint lint --strict` | Lint Swift |
| `prettier -w .` | Format other files |

### Debugging

- WebView console logs to Xcode console via `print()` in Swift
- BoardState changes trigger automatic WebView sync
- Use Safari Web Inspector for JS debugging

## Roadmap

- [ ] Ghostty C API integration (`ghostty_surface_*`)
- [ ] SessionFileWatcher for real-time status
- [ ] Git worktree creation from sessions
- [ ] Session resume/continue from sidebar
- [ ] Multiple project support
- [ ] Search and filter tasks
- [ ] Keyboard shortcuts

## References

- [Ghostty](https://ghostty.org) - Terminal emulator
- [Ghostty GitHub](https://github.com/ghostty-org/ghostty) - Source code
- [kanbangui](https://github.com/huerres/kanbangui) - Reference UI implementation
