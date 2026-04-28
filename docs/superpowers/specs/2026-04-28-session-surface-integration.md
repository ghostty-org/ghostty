# Ghostty Kanban - Session-Surface Integration Design

> **Date:** 2026-04-28
> **Status:** Draft
> **Architecture:** WebView Hybrid (HTML/CSS/JS + Swift)

## Overview

Integrate Ghostty terminal splits with Claude Code CLI sessions, enabling users to manage Claude conversations from the kanban board sidebar. Sessions are linked to terminal splits for navigation, and status is tracked via JSONL file watching.

**Key Change from 2026-04-27:** This design adapts to the WebView hybrid architecture where UI is rendered in HTML/CSS/JS loaded via WKWebView, with Swift handling native logic and bridge communication.

---

## Architecture

### Hybrid WebView Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    WebView UI Layer                              │
│  board.html (HTML/CSS/JavaScript)                               │
│  - Renders kanban columns, task cards, session items           │
│  - Handles user interactions locally                            │
│  - Sends/receives messages via JS bridge                        │
└────────────────────────────┬────────────────────────────────────┘
                             │ webkit.messageHandlers.kanbanBridge
┌────────────────────────────┴────────────────────────────────────┐
│                    Swift Bridge Layer                            │
│  KanbanWebView.swift                                            │
│  - Routes messages: JS ↔ Swift                                   │
│  - BoardState synchronization                                    │
│  - Layout propagation (width, narrow)                           │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────┴────────────────────────────────────┐
│                    Swift Data Layer                              │
│  KanbanBoardState.swift (BoardState)                            │
│  - Manages tasks, sessions, theme                               │
│  KanbanModels.swift (Session, KanbanTask, etc.)                 │
│  KanbanPersistence.swift (tasks.json, sessions.json)            │
└─────────────────────────────────────────────────────────────────┘
```

### Session-Surface Integration Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                    Claude Session                                 │
│  ~/.claude/projects/*/.jsonl (read-only)                        │
│  - Messages, status, timestamps                                 │
└─────────────────────────────┬────────────────────────────────────┘
                              │ SessionFileWatcher (FSEvents)
┌─────────────────────────────┴────────────────────────────────────┐
│                    SessionManager (Swift)                         │
│  .ghostty/sessions.json                                          │
│  - Links sessionId ↔ surfaceId                                  │
│  - Tracks cwd, branch, worktree                                  │
└─────────────────────────────┬────────────────────────────────────┘
                              │ ghostty_surface_* C APIs (Phase 1)
┌─────────────────────────────┴────────────────────────────────────┐
│                    Ghostty Surface                                │
│  Terminal split instances                                         │
│  - Create/focus splits                                           │
│  - Send commands                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Models

### Session (Swift)

```swift
struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String              // First 10 chars of first user message
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String
    var sessionId: String?          // Claude session UUID from JSONL
    var surfaceId: UInt64?         // Ghostty surface ID (nil if split closed)
    var cwd: String?
}

enum SessionStatus: String, Codable {
    case running    // Green - active (activity < 2 min)
    case idle       // Gray - no activity > 2 min
    case needInput  // Orange - waiting for user
}
```

### Session (JavaScript - board.html)

```javascript
const session = {
    id: "uuid-string",
    title: "Session title",
    status: "running" | "idle" | "needInput",
    relativeTimestamp: "2m ago",
    isWorkTree: false,
    branch: "main"
}
```

### sessions.json (Storage)

```json
{
  "sessions": [
    {
      "id": "local-uuid",
      "sessionId": "claude-session-uuid",
      "surfaceId": 1234567890,
      "title": "前10个字预览",
      "branch": "main",
      "isWorktree": false,
      "worktreeName": null,
      "status": "running",
      "cwd": "/Users/hue/project",
      "createdAt": 1745740800
    }
  ]
}
```

---

## File Structure

```
macos/Sources/Ghostty/SidePanel/
├── KanbanWebView.swift           # WebView bridge (EXISTING)
├── KanbanBoardState.swift        # BoardState with session management (MODIFY)
├── KanbanModels.swift            # Session, KanbanTask models (EXISTING)
├── KanbanPersistence.swift       # JSON persistence (MODIFY)
├── SessionManager.swift          # NEW: Session↔Surface mapping
├── SessionFileWatcher.swift      # NEW: JSONL file monitoring

macos/Resources/Kanban/
└── board.html                    # Web UI with session display (MODIFY)

docs/superpowers/
├── specs/
│   └── 2026-04-28-session-surface-integration.md  # THIS FILE
└── plans/
    └── 2026-04-28-session-surface-integration.md   # Implementation plan
```

---

## Message Bridge Protocol

### JavaScript → Swift (Existing + New)

```javascript
// === EXISTING ===
{ type: "themeToggle", isDark: true }
{ type: "addTask", task: { title, description, priority } }
{ type: "updateTask", taskId, task: { title, description, priority } }
{ type: "moveTask", taskId, newStatus }
{ type: "toggleExpand", taskId }
{ type: "deleteTask", taskId }
{ type: "removeSession", taskId, sessionId }

// === NEW ===
{ type: "addSession", taskId }                           // Create new session
{ type: "openSession", taskId, sessionId }               // Open session in Ghostty split
{ type: "createSessionAndLink", taskId, cwd, isWorkTree, worktreeName }  // Create + link
{ type: "unlinkSession", sessionId }                     // Unlink session from surface
{ type: "refreshSessions" }                               // Force refresh from JSONL
```

### Swift → JavaScript (New)

```javascript
// === NEW ===
updateSessions(sessions)              // Update session list in UI
sessionStatusChanged(sessionId, status)  // Real-time status update
sessionLinked(sessionId, surfaceId)   // Session now has surface
sessionUnlinked(sessionId)            // Surface closed
```

---

## Implementation Phases

### Phase 1: Session Data Layer
- [ ] SessionManager.swift - Load/save sessions to `.ghostty/sessions.json`
- [ ] Integrate SessionManager with BoardState
- [ ] Add session creation and linking methods
- [ ] BoardState persistence for sessions

### Phase 2: JSONL Watching
- [ ] SessionFileWatcher.swift - FSEvents-based file monitoring
- [ ] JSONL parsing for session status detection
- [ ] Title extraction from first user message
- [ ] Real-time status updates to WebView

### Phase 3: Ghostty C API Integration
- [ ] Zig: Add `ghostty_surface_split_with_command()`
- [ ] Zig: Add `ghostty_surface_text()`
- [ ] Zig: Add `ghostty_surface_get_id()`
- [ ] Zig: Add `ghostty_app_focus_surface()`
- [ ] Swift: Import and call C APIs
- [ ] Wire up session creation to surface creation

### Phase 4: UI Integration
- [ ] board.html: Session item click handlers
- [ ] board.html: Add session flow (create + link)
- [ ] board.html: Session status indicators
- [ ] board.html: Link/unlink session UI

---

## Session Status Detection

From JSONL parsing:

| Condition | Status |
|-----------|--------|
| `AskUserQuestion` tool in last message | `needInput` |
| Text ends with `?` pattern | `needInput` |
| Activity within 2 minutes | `running` |
| No activity > 2 minutes | `idle` |

---

## Ghostty C API (Phase 3)

```c
// Create split with command, return surface ID
uint64_t ghostty_surface_split_with_command(
    void *surface_ptr,
    int direction,           // 0=right, 1=down, 2=left, 3=up
    const char *command,      // NULL for default shell
    const char *cwd,          // NULL to inherit
    const char *title         // NULL for default
);

// Send text to surface (for pasting claude command)
void ghostty_surface_text(void *surface_ptr, const char *text, size_t len);

// Get surface ID
uint64_t ghostty_surface_get_id(void *surface_ptr);

// Focus surface by ID
void ghostty_app_focus_surface(void *app_ptr, uint64_t surface_id);
```

---

## Command Sending Flow

### Creating a new session:
1. `ghostty_surface_split_with_command()` creates split with default shell
2. Wait 100ms for surface to initialize
3. `ghostty_surface_text()` sends: `claude --session-id <uuid> --worktree <name>\r`

### Resuming a session:
1. `ghostty_surface_split_with_command()` creates split
2. `ghostty_surface_text()` sends: `claude --session-id <uuid> --resume\r`

---

## Storage

| Data | Location | Scope |
|------|----------|-------|
| Kanban tasks | `~/.config/ghostty/tasks.json` | Global |
| Session↔Surface mapping | `.ghostty/sessions.json` | Per-project |
| Claude session history | `~/.claude/projects/*/*.jsonl` | Global (read-only) |

---

## Open Questions

1. **Phase 3 (C API)**: Does Ghostty upstream accept these changes? Should we use Swift Native APIs instead?
2. **Worktree handling**: Should sessions automatically detect if they're in a git worktree?
3. **Multiple projects**: Should `.ghostty/sessions.json` be per-project or global?
