# Ghostty Kanban Board

## Overview

Native kanban board embedded in Ghostty's sidebar, allowing users to manage tasks with sessions directly within the terminal.

## Features

### Kanban Board
- Four status columns: **Todo**, **In Progress**, **Review**, **Done**
- Drag-and-drop cards between columns
- Color-coded priority indicators (P0/P1/P2/P3)
- Light/dark theme support

### Task Cards
- Title and description
- Priority badge (color-coded)
- Expandable session list
- Hover effects with shadow animation

### Sessions
- Multiple sessions per task
- Status indicators (running/idle/need-input)
- Worktree badge when applicable
- Branch display
- Relative timestamps

### Data Persistence
- Tasks stored in `~/Library/Application Support/KanbanBoard/tasks.json`
- Auto-save on changes
- Sample data on first launch

## Architecture

### File Structure

```
macos/Sources/Ghostty/SidePanel/
├── KanbanModels.swift        # Priority, Status, Session, KanbanTask
├── KanbanTheme.swift        # Light/dark theme colors + environment
├── KanbanPersistence.swift  # JSON persistence to Application Support
├── KanbanBoardState.swift   # BoardState view model (task CRUD, theme)
├── KanbanBoardView.swift    # Main board (responsive horizontal/vertical)
├── ColumnView.swift         # Single status column with drag-drop
├── TaskCardView.swift       # Task card with expand/hover
├── SessionPanelView.swift   # Expanded session list in card
├── PriorityBadge.swift      # Priority badge component
├── TaskModalView.swift     # Add/edit task sheet
├── SessionModalView.swift   # Add session sheet
├── SidePanelView.swift      # Sidebar container (280px)
└── SidePanelViewModel.swift # Terminal bridge (activate session)
```

### Data Models

```swift
enum Priority: String, Codable, CaseIterable {
    case p0, p1, p2, p3
}

enum Status: String, Codable, CaseIterable {
    case todo, inProgress, review, done
}

enum SessionStatus: String, Codable {
    case running, idle, needInput
}

struct Session: Identifiable, Codable {
    var id: UUID
    var title: String
    var status: SessionStatus
    var timestamp: Date
    var isWorkTree: Bool
    var branch: String
}

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

### Theme System

```swift
struct ThemeColors {
    let bgPrimary: Color
    let bgSecondary: Color
    let accent: Color      // #0a84ff (dark) / #007aff (light)
    let danger: Color      // #ff3b30 (dark) / #ff3b30 (light)
    let success: Color    // #34c759 (dark) / #34c759 (light)
    let warning: Color    // #ff9500 (dark) / #ff9500 (light)
    let worktree: Color   // #bf94ff (dark) / #af52de (light)
    // ... 25+ color properties
}
```

Injected via SwiftUI Environment:
```swift
.environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
```

## Usage

### Toggle Dark Mode
Call `boardState.toggleTheme()` — persists to UserDefaults.

### Add Task
```swift
boardState.addTask(KanbanTask(
    title: "New Feature",
    description: "Implement X",
    priority: .p1,
    status: .todo
))
```

### Move Task
```swift
boardState.moveTask(taskId, to: .inProgress)
```

### Add Session
```swift
boardState.addSession(to: taskId, session: Session(
    title: "Working on feature",
    status: .running,
    branch: "feature/x"
))
```

### Activate Session (Terminal Bridge)
```swift
viewModel.activate(session)
// Logs: [Kanban] activate session: Working on feature (status: running)
// [Kanban] createSplit() - PENDING Ghostty API integration
```

## Terminal Bridge

`SidePanelViewModel.activate()` is the integration point with Ghostty:

```swift
func activate(_ session: Session) {
    let newSplitId = createSplit()  // TODO: integrate with Ghostty API
    if session.isWorkTree {
        createWorktree(name: session.branch)
    }
}
```

Current implementation logs pending actions. Ghostty API integration required for:
- `createSplit()` — create terminal split
- `focusSplit(id)` — focus existing split
- `runCommand(split, cwd, command)` — execute in split

## Keyboard Shortcut

Sidebar toggle via Ghostty config (handled by Ghostty internals).

## Future Enhancements

- Ghostty split API integration (create/focus splits from sessions)
- Git worktree execution
- Search and filter tasks
- Card due dates
- Multiple board support
