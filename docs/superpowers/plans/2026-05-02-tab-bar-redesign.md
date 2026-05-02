# Tab Bar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the demo app's tab bar management with Ghostty's native behavior — correct tab insertion position, autohide, expand-to-fill width, drag reorder, and fixed "+" button.

**Architecture:** Modify `TerminalTabManager` for tab insertion logic and reorder support. Rewrite `TabBarView` in `ContentView.swift` to use a `HStack` with a spacer that pushes the "+" button to the right, with expand-mode tab sizing and drag reorder via `onDrag`/`onDrop`.

**Tech Stack:** SwiftUI, GhosttyKit (GhosttySurfaceView)

---

## File Map

| File | Responsibility |
|------|---------------|
| `demo/Sources/GhosttyDemo/TerminalTabManager.swift` | Tab data model — insert position, reorder, autohide computed property |
| `demo/Sources/GhosttyDemo/ContentView.swift` | TabBarView UI — layout, expand sizing, drag reorder, fixed "+" button |

---

### Task 1: Tab insertion after current tab (current mode)

**Files:**
- Modify: `demo/Sources/GhosttyDemo/TerminalTabManager.swift:20-29`

- [ ] **Step 1: Add `insertAfterActive` method to TerminalTabManager**

Replace the `newTab` method in `TerminalTabManager.swift`:

```swift
// OLD:
func newTab(app: ghostty_app_t, workspacePath: String? = nil) {
    let sv = GhosttySurfaceView(app)
    let tab = Tab(surfaceView: sv)
    tabs.append(tab)
    activeTabID = tab.id
    if let ws = workspacePath {
        tab.surfaceView.sendText("cd \(ws)")
        tab.surfaceView.sendEnter()
    }
}

// NEW:
func newTab(app: ghostty_app_t, workspacePath: String? = nil) {
    let sv = GhosttySurfaceView(app)
    let tab = Tab(surfaceView: sv)

    // Insert after the currently active tab, or at end if none active.
    if let activeID = activeTabID,
       let idx = tabs.firstIndex(where: { $0.id == activeID }) {
        tabs.insert(tab, at: tabs.index(after: idx))
    } else {
        tabs.append(tab)
    }

    activeTabID = tab.id
    if let ws = workspacePath {
        tab.surfaceView.sendText("cd \(ws)")
        tab.surfaceView.sendEnter()
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `cd demo && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis
git add demo/Sources/GhosttyDemo/TerminalTabManager.swift
git commit -m "feat: insert new tab after active tab instead of at end"
```

---

### Task 2: Tab reorder support in TerminalTabManager

**Files:**
- Modify: `demo/Sources/GhosttyDemo/TerminalTabManager.swift` — add `moveTab(from:to:)` method

- [ ] **Step 1: Add `moveTab` method after `closeTab`**

Append this method to `TerminalTabManager` (after line 41):

```swift
func moveTab(from source: IndexSet, to destination: Int) {
    tabs.move(fromOffsets: source, toOffset: destination)
}
```

- [ ] **Step 2: Build and verify**

Run: `cd demo && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis
git add demo/Sources/GhosttyDemo/TerminalTabManager.swift
git commit -m "feat: add moveTab reorder support"
```

---

### Task 3: Autohide tab bar when single tab

**Files:**
- Modify: `demo/Sources/GhosttyDemo/TerminalTabManager.swift` — add computed property
- Modify: `demo/Sources/GhosttyDemo/ContentView.swift:31` — conditionally show tab bar

- [ ] **Step 1: Add `showTabBar` computed property to TerminalTabManager**

Add after the `activeTab` computed property (after line 17):

```swift
var showTabBar: Bool { tabs.count > 1 }
```

- [ ] **Step 2: Conditionally show TabBarView in ContentView**

In `ContentView.swift`, change the tab bar section (line 31):

```swift
// OLD:
VStack(spacing: 0) {
    // Tab Bar
    TabBarView(tabManager: tabManager, sessionManager: sessionManager)
        .environmentObject(boardState)

    // Terminal area (stacked views, only active is visible)
    ZStack { ... }

// NEW:
VStack(spacing: 0) {
    // Tab Bar (hidden when only one tab)
    if tabManager.showTabBar {
        TabBarView(tabManager: tabManager, sessionManager: sessionManager)
            .environmentObject(boardState)
    }

    // Terminal area (stacked views, only active is visible)
    ZStack { ... }
```

- [ ] **Step 3: Build and verify**

Run: `cd demo && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis
git add demo/Sources/GhosttyDemo/TerminalTabManager.swift demo/Sources/GhosttyDemo/ContentView.swift
git commit -m "feat: autohide tab bar when only one tab"
```

---

### Task 4: Expand-mode tab width + fixed "+" button + drag reorder

**Files:**
- Modify: `demo/Sources/GhosttyDemo/ContentView.swift:100-176` — rewrite TabBarView and TabButton

- [ ] **Step 1: Rewrite TabBarView**

Replace the entire `TabBarView` struct (lines 102-143) with:

```swift
struct TabBarView: View {
    @EnvironmentObject private var ghostty: GhosttyApp
    @EnvironmentObject private var boardState: BoardState
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 0) {
            // Draggable tab list — expands to fill available width
            ForEach(tabManager.tabs) { tab in
                TabButton(
                    title: tab.title,
                    isActive: tab.id == tabManager.activeTabID,
                    canClose: tabManager.tabs.count > 1,
                    onSelect: { tabManager.selectTab(id: tab.id) },
                    onClose: {
                        tabManager.closeTab(id: tab.id)
                        sessionManager.unlinkTab(tabID: tab.id)
                    }
                )
                .frame(maxWidth: .infinity)
                .onDrag {
                    NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(
                    tab: tab,
                    tabManager: tabManager
                ))
            }

            // "+" button — always fixed at the far right
            Button(action: {
                if let app = ghostty.app {
                    tabManager.newTab(app: app, workspacePath: boardState.workspacePath)
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 20)
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: 28)
        .background(Color(.controlBackgroundColor).opacity(0.8))
        .overlay(Divider(), alignment: .bottom)
    }
}
```

- [ ] **Step 2: Rewrite TabButton for expand mode**

Replace the entire `TabButton` struct (lines 146-176) with:

```swift
struct TabButton: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }
}
```

- [ ] **Step 3: Add TabDropDelegate**

Add this struct after `TabButton` and before `SurfaceViewWrapper` (after line 176):

```swift
struct TabDropDelegate: DropDelegate {
    let tab: TerminalTabManager.Tab
    let tabManager: TerminalTabManager

    func performDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        guard let items = info.itemProviders(for: [.text]).first else { return }
        _ = items.loadObject(ofClass: NSString.self) { reading, _ in
            guard let uuidString = reading as? String,
                  let sourceID = UUID(uuidString: uuidString),
                  sourceID != tab.id else { return }
            DispatchQueue.main.async {
                guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == sourceID }),
                      let destIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                withAnimation {
                    tabManager.tabs.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destIndex > sourceIndex ? destIndex + 1 : destIndex)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
```

- [ ] **Step 4: Remove old TabMiddleClickView (dead code)**

Delete the `TabMiddleClickView` struct (lines 193-205) and `MiddleClickMonitor` class (lines 207-229) since the new `TabButton` uses `.contentShape(Rectangle()).onTapGesture` instead. The middle-click support is no longer wired up with the new design — if needed later it can be re-added via `onMiddleClick` gesture.

- [ ] **Step 5: Build and verify**

Run: `cd demo && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis
git add demo/Sources/GhosttyDemo/ContentView.swift
git commit -m "feat: expand tab width, fixed + button, drag reorder"
```

---

### Task 5: Full build and package verification

- [ ] **Step 1: Full build via run.sh**

Run: `cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis && bash demo/run.sh 2>&1 | tail -20`
Expected: App launches successfully

- [ ] **Step 2: Manual test checklist**

Verify these behaviors in the running app:
1. Only one tab → tab bar is hidden
2. Click "+" → new tab appears after the active tab, tab bar appears
3. Click "+" again → third tab appears after the second (active) tab
4. "+" button is always at the far right, not scrolling
5. Tabs fill the available width equally
6. Drag a tab left/right → tab reorders
7. Close a tab → remaining tabs still fill width

- [ ] **Step 3: Commit (if any fixes needed)**

```bash
cd /Users/hue/Documents/ghostty-kanban/.claude/worktrees/synchronous-swinging-sifakis
git add -A
git commit -m "fix: tab bar polish after manual testing"
```
