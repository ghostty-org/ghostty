# Kanban GUI Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing SidePanel Kanban UI with the full KanbanBoard UI from `/Users/hue/Desktop/kanbangui`, integrating all views, components, models, and utilities into the SidePanel directory.

**Architecture:** Copy all kanbangui source files (Models, ViewModels, Views, Components, Utilities) into `macos/Sources/Ghostty/SidePanel/`. Strip `GhosttyKit` imports. Replace `SidePanelView.body` with `KanbanBoardView` wrapped in a theme-aware container. The existing `SidePanelViewModel` is retained for project/shell integration but the kanban board uses its own `BoardState`.

**Tech Stack:** SwiftUI, Combine, Foundation (no GhosttyKit in new files)

---

## File Map

### Files to Copy from kanbangui (destination: `macos/Sources/Ghostty/SidePanel/`)

| Source | Destination | Responsibility |
|--------|-------------|----------------|
| `Models/Task.swift` | `KanbanModels.swift` | Priority, Status, Session, KanbanTask |
| `Utilities/Theme.swift` | `KanbanTheme.swift` | Theme colors, light/dark palettes |
| `Utilities/Persistence.swift` | `KanbanPersistence.swift` | JSON file persistence |
| `ViewModels/BoardState.swift` | `KanbanBoardState.swift` | Task CRUD, session CRUD, theme toggle |
| `Components/PriorityBadge.swift` | `PriorityBadge.swift` | Priority badge component |
| `Views/KanbanBoardView.swift` | `KanbanBoardView.swift` | Main board (horizontal scroll) |
| `Views/ColumnView.swift` | `ColumnView.swift` | Single status column with drag-drop |
| `Views/TaskCardView.swift` | `TaskCardView.swift` | Task card with expand/hover |
| `Views/SessionPanelView.swift` | `SessionPanelView.swift` | Expanded session list |
| `Views/TaskModalView.swift` | `TaskModalView.swift` | Add/edit task sheet |
| `Views/SessionModalView.swift` | `SessionModalView.swift` | Add session sheet |

### Files to Replace

| File | Action |
|------|--------|
| `SidePanelView.swift` | Replace body with `KanbanBoardView` |
| `KanbanToolbar.swift` | Delete (toolbar is inside KanbanBoardView now) |
| `KanbanColumn.swift` | Delete (replaced by ColumnView) |
| `CardView.swift` | Delete (replaced by TaskCardView) |
| `CardEditSheet.swift` | Delete (replaced by TaskModalView) |
| `AddSessionSheet.swift` | Delete (replaced by SessionModalView) |
| `Models.swift` | Delete (replaced by KanbanModels) |
| `ProjectTabBar.swift` | Keep — still needed for project tabs |

### Files to Keep Unchanged

- `SidePanelViewModel.swift` — retained for project management shell integration
- `SessionRowView.swift` — used by shell

---

## Task 1: Copy and Adapt Models + Utilities

**Files:**
- Copy: `/Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Models/Task.swift` → `macos/Sources/Ghostty/SidePanel/KanbanModels.swift`
- Copy: `/Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Utilities/Theme.swift` → `macos/Sources/Ghostty/SidePanel/KanbanTheme.swift`
- Copy: `/Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Utilities/Persistence.swift` → `macos/Sources/Ghostty/SidePanel/KanbanPersistence.swift`

- [ ] **Step 1: Copy Task.swift → KanbanModels.swift**

Read the source file, copy it verbatim to `macos/Sources/Ghostty/SidePanel/KanbanModels.swift`. No changes needed — it has no GhosttyKit dependency.

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Models/Task.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanModels.swift
```

- [ ] **Step 2: Copy Theme.swift → KanbanTheme.swift**

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Utilities/Theme.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanTheme.swift
```

- [ ] **Step 3: Copy Persistence.swift → KanbanPersistence.swift**

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Utilities/Persistence.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanPersistence.swift
```

- [ ] **Step 4: Verify no GhosttyKit references in new files**

```bash
grep -r "GhosttyKit" /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanModels.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanTheme.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanPersistence.swift
```
Expected: no output (no matches).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanModels.swift macos/Sources/Ghostty/SidePanel/KanbanTheme.swift macos/Sources/Ghostty/SidePanel/KanbanPersistence.swift
git commit -m "feat(kanban): add kanbangui models and utilities"
```

---

## Task 2: Copy ViewModel

**Files:**
- Copy: `/Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/ViewModels/BoardState.swift` → `macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift`

- [ ] **Step 1: Copy BoardState.swift → KanbanBoardState.swift**

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/ViewModels/BoardState.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift
```

- [ ] **Step 2: Verify no GhosttyKit references**

```bash
grep "GhosttyKit" /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/KanbanBoardState.swift
git commit -m "feat(kanban): add BoardState view model"
```

---

## Task 3: Copy UI Components

**Files:**
- Copy: `Components/PriorityBadge.swift` → `macos/Sources/Ghostty/SidePanel/PriorityBadge.swift`

- [ ] **Step 1: Copy PriorityBadge.swift**

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Components/PriorityBadge.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/PriorityBadge.swift
```

- [ ] **Step 2: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/PriorityBadge.swift
git commit -m "feat(kanban): add PriorityBadge component"
```

---

## Task 4: Copy Views

**Files:**
- Copy: `Views/SessionPanelView.swift` → `macos/Sources/Ghostty/SidePanel/SessionPanelView.swift`
- Copy: `Views/TaskCardView.swift` → `macos/Sources/Ghostty/SidePanel/TaskCardView.swift`
- Copy: `Views/ColumnView.swift` → `macos/Sources/Ghostty/SidePanel/ColumnView.swift`
- Copy: `Views/KanbanBoardView.swift` → `macos/Sources/Ghostty/SidePanel/KanbanBoardView.swift`
- Copy: `Views/TaskModalView.swift` → `macos/Sources/Ghostty/SidePanel/TaskModalView.swift`
- Copy: `Views/SessionModalView.swift` → `macos/Sources/Ghostty/SidePanel/SessionModalView.swift`

- [ ] **Step 1: Copy all views**

```bash
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/SessionPanelView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/SessionPanelView.swift
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/TaskCardView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/TaskCardView.swift
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/ColumnView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/ColumnView.swift
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/KanbanBoardView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanBoardView.swift
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/TaskModalView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/TaskModalView.swift
cp /Users/hue/Desktop/kanbangui/KanbanBoard/KanbanBoard/Views/SessionModalView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/SessionModalView.swift
```

- [ ] **Step 2: Verify no GhosttyKit in any copied view files**

```bash
grep -l "GhosttyKit" /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/SessionPanelView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/TaskCardView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/ColumnView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/KanbanBoardView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/TaskModalView.swift /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel/SessionModalView.swift
```
Expected: no output (no matches). If any file contains GhosttyKit, remove that import line.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SessionPanelView.swift macos/Sources/Ghostty/SidePanel/TaskCardView.swift macos/Sources/Ghostty/SidePanel/ColumnView.swift macos/Sources/Ghostty/SidePanel/KanbanBoardView.swift macos/Sources/Ghostty/SidePanel/TaskModalView.swift macos/Sources/Ghostty/SidePanel/SessionModalView.swift
git commit -m "feat(kanban): add kanbangui views"
```

---

## Task 5: Replace SidePanelView

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/SidePanelView.swift`

- [ ] **Step 1: Read current SidePanelView.swift**

- [ ] **Step 2: Replace body**

Replace the current `SidePanelView` body to use `KanbanBoardView` wrapped in a `BoardState` environment. The `SidePanelViewModel` is kept as a property but the body delegates entirely to the new kanban board.

```swift
import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()

    var body: some View {
        KanbanBoardView(boardState: boardState)
            .environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
            .frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/hue/Documents/ghostty-kanban/macos && env -i HOME=/Users/hue PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=build build 2>&1 | tail -20
```
Expected: **BUILD SUCCEEDED**

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SidePanelView.swift
git commit -m "feat(kanban): replace SidePanelView body with KanbanBoardView"
```

---

## Task 6: Delete Old Kanban Files

**Files:**
- Delete: `KanbanToolbar.swift`
- Delete: `KanbanColumn.swift`
- Delete: `CardView.swift`
- Delete: `CardEditSheet.swift`
- Delete: `AddSessionSheet.swift`
- Delete: `Models.swift`

- [ ] **Step 1: Delete old files**

```bash
cd /Users/hue/Documents/ghostty-kanban/macos/Sources/Ghostty/SidePanel
rm -f KanbanToolbar.swift KanbanColumn.swift CardView.swift CardEditSheet.swift AddSessionSheet.swift Models.swift
```

- [ ] **Step 2: Verify Xcode project still builds**

```bash
cd /Users/hue/Documents/ghostty-kanban/macos && env -i HOME=/Users/hue PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=build build 2>&1 | tail -10
```
Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(kanban): remove old kanban implementation files"
```

---

## Verification Checklist

After all tasks:
- [ ] `KanbanModels.swift` — Priority, Status, Session, KanbanTask
- [ ] `KanbanTheme.swift` — Light/dark theme colors
- [ ] `KanbanPersistence.swift` — JSON persistence
- [ ] `KanbanBoardState.swift` — BoardState view model
- [ ] `PriorityBadge.swift` — Priority badge component
- [ ] `KanbanBoardView.swift` — Main board (horizontal scroll)
- [ ] `ColumnView.swift` — Single column with drag-drop
- [ ] `TaskCardView.swift` — Task card with expand/hover
- [ ] `SessionPanelView.swift` — Session list in expanded card
- [ ] `TaskModalView.swift` — Add/edit task sheet
- [ ] `SessionModalView.swift` — Add session sheet
- [ ] `SidePanelView.swift` — Updated to embed KanbanBoardView
- [ ] Old files deleted: KanbanToolbar, KanbanColumn, CardView, CardEditSheet, AddSessionSheet, Models
- [ ] No GhosttyKit imports in any new file
- [ ] BUILD SUCCEEDED
