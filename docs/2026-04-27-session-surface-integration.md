# Ghostty Session-Surface Integration Design

## Overview

Integrate Ghostty terminal splits with Claude Code CLI sessions, enabling users to manage Claude conversations from a kanban board sidebar. Sessions are linked to terminal splits for navigation, and status is tracked in real-time via JSONL file watching.

## Architecture

### Storage Strategy

| Data | Location | Scope |
|------|----------|-------|
| Kanban (projects, cards) | `~/.config/ghostty/tasks.json` | Global |
| Session↔Surface mapping | `.ghostty/sessions.json` | Per-project |
| Claude session history | `~/.claude/projects/*/.jsonl` | Global (read-only) |

### Data Model

**`.ghostty/sessions.json`**
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
      "status": "in-progress",
      "cwd": "/Users/hue/project",
      "createdAt": 1745740800
    }
  ]
}
```

**Session Status** (derived from JSONL parsing):
- `idle` - No activity > 2 minutes
- `in-progress` - Activity within 2 minutes
- `needs-input` - Claude waiting for user response (detected via `AskUserQuestion` tool or `?` patterns)

### Key Components

```
┌─────────────────────────────────────────────────────────┐
│                    SwiftUI Layer                        │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────┐  │
│  │ SidePanel   │  │ SessionCard │  │ ProjectTabBar │  │
│  │ View        │  │ View        │  │               │  │
│  └─────────────┘  └─────────────┘  └───────────────┘  │
│         │                │                   │         │
│         └────────────────┼───────────────────┘         │
│                          ▼                             │
│              ┌───────────────────────┐                │
│              │ SidePanelViewModel    │                │
│              │ - sessions[]          │                │
│              │ - projects[]          │                │
│              │ - load/save sessions  │                │
│              └───────────────────────┘                │
└─────────────────────────┬───────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────┐
│                    Zig Layer        │                  │
│                          ▼                             │
│              ┌───────────────────────┐                │
│              │ ghostty_surface_*    │                │
│              │ C API functions       │                │
│              └───────────────────────┘                │
└────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────┐
│                 File System                           │
│                          ▼                             │
│  ┌─────────────────┐    ┌─────────────────────────┐  │
│  │.ghostty/sessions│    │~/.claude/projects/*/.jsonl│  │
│  │.json (RW)       │    │ (read by FileWatcher)    │  │
│  └─────────────────┘    └─────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

## SwiftUI Components

### Session Model (Swift)

```swift
struct Session: Identifiable, Codable {
    let id: String           // Local UUID
    var sessionId: String   // Claude session UUID from JSONL
    var surfaceId: UInt64?  // Ghostty surface ID (nil if split closed)
    var title: String        // First 10 chars of first user message
    var branch: String?
    var isWorktree: Bool
    var worktreeName: String?
    var status: SessionStatus
    var cwd: String
    var createdAt: Date
}

enum SessionStatus: String, Codable {
    case idle
    case inProgress = "in-progress"
    case needsInput = "needs-input"
    case finished
}
```

### SessionFileWatcher

Monitors Claude JSONL files for status changes:
- Uses `DispatchSource.makeFileSystemObjectSource` or `FSEvents` (macOS)
- Watches `~/.claude/projects/*/*.jsonl`
- Debounces changes (200ms)
- Parses JSONL to derive session status

### SessionManager

```swift
class SessionManager {
    // Load/save to .ghostty/sessions.json
    func loadSessions() -> [Session]
    func saveSessions([Session])

    // Surface lifecycle
    func createSession(cwd: String, isWorktree: Bool, worktreeName: String?) -> Session
    func linkSessionToSurface(sessionId: String, surfaceId: UInt64)
    func unlinkSurface(surfaceId: UInt64)

    // Navigation
    func navigateToSession(_ session: Session)  // Create split + launch claude or focus existing

    // Status
    func updateSessionStatus(_ sessionId: String, status: SessionStatus)
}
```

## Zig/C API Extensions

### New Functions

```c
// Create split with command, return surface ID
uint64_t ghostty_surface_split_with_command(
    void *surface_ptr,
    int direction,           // 0=right, 1=down, 2=left, 3=up
    const char *command,     // NULL for default shell
    const char *cwd,         // NULL to inherit
    const char *title        // NULL for default
);

// Send text to surface (for pasting claude command)
void ghostty_surface_text(void *surface_ptr, const char *text, size_t len);

// Get surface ID
uint64_t ghostty_surface_get_id(void *surface_ptr);

// Focus surface by ID
void ghostty_app_focus_surface(void *app_ptr, uint64_t surface_id);
```

### Command Sending Flow

When creating a new session:
1. `ghostty_surface_split_with_command()` creates split with default shell
2. Wait 100ms for surface to initialize
3. `ghostty_surface_text()` sends: `claude --session-id <uuid> --worktree <name>\r`

When resuming a session:
1. `ghostty_surface_split_with_command()` creates split
2. `ghostty_surface_text()` sends: `claude --session-id <uuid> --resume\r`

## JSONL Parsing

### Status Detection Rules

From `ConversationParser.ts` (Claudine):

1. **`needs-input`** when:
   - `AskUserQuestion` or `ExitPlanMode` tool in last assistant message
   - Text ends with `?` and matches question patterns
   - Rate limit active

2. **`in-progress`** when:
   - Last message is from user
   - Last message is from assistant with `toolUses` and timestamp < 2 min ago
   - Any background agent still running

3. **`idle`** when:
   - No messages < 2 minutes ago

### Title Extraction

- First `type: "user"` entry's `message.content` field
- Truncate to 10 characters
- If no content, use `"New Session"`

## File Structure

```
Ghostty/
├── macos/Sources/Ghostty/
│   ├── SidePanel/
│   │   ├── SidePanelView.swift       # Main panel
│   │   ├── SidePanelViewModel.swift  # State + session management
│   │   ├── SessionCardView.swift     # Session card component
│   │   ├── SessionFileWatcher.swift # JSONL file monitoring
│   │   └── SessionManager.swift      # Session↔Surface mapping
│   └── GhosttyApp.swift              # Integrate session management
│
├── src/
│   └── apprt/
│       └── embedded.zig              # Add ghostty_surface_* C APIs
│
├── include/
│   └── ghostty.h                    # Add C API declarations
│
docs/superpowers/
├── specs/
│   └── 2026-04-27-session-surface-integration.md
└── plans/
    └── 2026-04-27-session-surface-integration.md
```

## Implementation Phases

### Phase 1: C API Extensions
- Add `ghostty_surface_split_with_command()`
- Add `ghostty_surface_text()`
- Add `ghostty_surface_get_id()`
- Add `ghostty_app_focus_surface()`

### Phase 2: Swift Session Management
- Session model and `SessionManager`
- Load/save to `.ghostty/sessions.json`
- Session creation and surface linking

### Phase 3: JSONL Watching
- `SessionFileWatcher` using FSEvents
- Status detection from JSONL
- Title extraction

### Phase 4: UI Integration
- `SessionCardView` component
- Real-time status display
- Click to navigate/create session
