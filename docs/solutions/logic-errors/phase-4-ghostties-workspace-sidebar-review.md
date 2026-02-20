---
title: Multi-window keyboard routing, surface lifecycle, and state persistence issues in Phase 4 session management
date: 2026-02-20
category: logic-errors
tags: [notification-scoping, window-lifecycle, persistence, dark-mode, race-condition, keyboard-routing, code-review]
severity: critical
component: SessionCoordinator, TerminalController, WorkspaceSidebarView, WorkspaceViewContainer
symptoms:
  - Project navigation shortcuts (Cmd+Shift+]/[) route to wrong windows in multi-window contexts
  - Window closes unexpectedly when last surface exits, despite relaunchable sessions in sidebar
  - Stale project UUIDs persist in workspace.json after project deletion
  - Notification delivery race between SessionCoordinator and BaseTerminalController on surface close
  - Divider color frozen on light/dark mode toggle
  - Unused properties and inconsistent identifier naming
root_causes:
  - Notifications lack originating window context; broadcasted to all windows instead of scoped
  - TerminalController.replaceSurfaceTree closes window without checking sidebar session state
  - lastSelectedProjectId not cleared in removeProject or validated on load
  - NotificationCenter delivery order assumed but not guaranteed between handlers
  - NSColor.separatorColor captured as static CGColor; dynamic appearance changes not observed
  - Dead code deferred from earlier phases
resolution_type: code_fix
estimated_impact: high
files_changed: 8
insertions: 64
deletions: 41
build_status: clean
---

# Phase 4 Review Fixes: Ghostties Workspace Sidebar

## Summary

After implementing Phase 4 (split tree preservation, 3-state status indicators, sidebar toggle, keyboard shortcuts, persistence) of the Ghostties workspace sidebar, a 7-agent code review identified 6 issues across 3 severity levels. All were fixed in a single pass: 8 files changed, 64 insertions, 41 deletions. Build passes clean.

| Severity | Count | Issues |
|----------|-------|--------|
| P1 Critical | 2 | Multi-window notification scoping, empty tree closes window |
| P2 Important | 3 | Orphaned lastSelectedProjectId, notification ordering race, divider dark mode |
| P3 Cleanup | 1 | Dead code batch (4 sub-items) |

---

## P1-001: Multi-window Notification Scoping

**Root Cause:** `WorkspaceSidebarView`'s `.onReceive` for project navigation notifications didn't filter by window. `TerminalController` posted notifications with `object: window`, but the receiver ignored the notification object, causing project changes in one window to affect all windows.

**Fix:** Added `@EnvironmentObject private var coordinator: SessionCoordinator` to `WorkspaceSidebarView` and filtered notifications by window identity.

```swift
// WorkspaceSidebarView.swift
.onReceive(NotificationCenter.default.publisher(for: .workspaceSelectNextProject)) { notification in
    guard notification.object as? NSWindow === coordinator.containerView?.window else { return }
    selectAdjacentProject(offset: 1)
}
```

**Key insight:** The coordinator already has `containerView` (a weak NSView reference set in `viewDidMoveToWindow`), which provides the window identity needed for filtering. No new state was required.

---

## P1-002: Empty Tree Closes Window When Sidebar Exists

**Root Cause:** Two code paths in `TerminalController` close the window when the surface tree becomes empty: `surfaceTreeDidChange` calls `self.window?.close()` and `replaceSurfaceTree` calls `closeTabImmediately()`. Neither checked whether a workspace sidebar was present with relaunchable sessions.

**Fix:** Both paths now check `window?.contentView is WorkspaceViewContainer<TerminalController>`. If workspace sidebar is present, `surfaceTreeDidChange` skips the close, and `replaceSurfaceTree` calls `super.replaceSurfaceTree` to install the empty tree without closing.

```swift
// TerminalController.swift — surfaceTreeDidChange
if to.isEmpty {
    if !(window?.contentView is WorkspaceViewContainer<TerminalController>) {
        self.window?.close()
    }
}

// TerminalController.swift — replaceSurfaceTree
if newTree.isEmpty {
    if window?.contentView is WorkspaceViewContainer<TerminalController> {
        super.replaceSurfaceTree(newTree, moveFocusTo: newView, moveFocusFrom: oldView, undoAction: undoAction)
        return
    }
    closeTabImmediately()
    return
}
```

**Key insight:** Non-workspace windows still close normally — the guard is specifically for the workspace context where the sidebar provides alternative interaction.

---

## P2-003: Orphaned lastSelectedProjectId

**Root Cause:** `WorkspaceStore.removeProject(id:)` didn't clear `lastSelectedProjectId` when the matching project was deleted. `WorkspacePersistence.validate()` didn't check it against known project IDs. The stale UUID persisted in `workspace.json` indefinitely.

**Fix:** Two additions (~5 lines total):

```swift
// WorkspaceStore.swift — removeProject
if lastSelectedProjectId == id { lastSelectedProjectId = nil }

// WorkspacePersistence.swift — validate
if let lastId = validated.lastSelectedProjectId,
   !knownProjectIds.contains(lastId) {
    validated.lastSelectedProjectId = nil
}
```

**Key insight:** The view layer already handled this gracefully (falls back to first project), but the persistence layer violated referential integrity. Defense in depth: cleanup on delete + validation on load.

---

## P2-004: Notification Ordering Race

**Root Cause:** Both `SessionCoordinator` and `BaseTerminalController` observe `ghosttyCloseSurface`. `NotificationCenter` delivery order depends on registration order, which isn't guaranteed. If the coordinator fires first, `controller.surfaceTree` still contains the closed surface, and the coordinator snapshots a stale tree.

**Fix:** Wrapped the coordinator's handler in `DispatchQueue.main.async` to defer by one run-loop tick. `BaseTerminalController` processes synchronously, so it always completes before the deferred handler runs.

```swift
// SessionCoordinator.swift
@objc private func surfaceDidClose(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
        self?.handleSurfaceClose(notification)
    }
}
```

**Key insight:** This is a classic AppKit idiom — deferring by one tick makes you order-independent without coupling to another observer's implementation. The stale-tree issue self-healed on the next session switch (via `snapshotActiveTree()`), but the async defer eliminates the staleness window entirely.

---

## P2-005: Divider Dark Mode

**Root Cause:** `NSColor.separatorColor.cgColor` captures a static `CGColor` at call time. Unlike `NSColor` (which is dynamic-appearance-aware), `CGColor` is a fixed RGBA tuple. When the system switches light/dark, the `CALayer.backgroundColor` stays stale.

**Fix:** Override `viewDidChangeEffectiveAppearance()` in `WorkspaceViewContainer`:

```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    dividerView.layer?.backgroundColor = NSColor.separatorColor.cgColor
}
```

**Key insight:** AppKit calls this method on every appearance change. Re-resolving the `CGColor` at that point picks up the new appearance's color value.

---

## P3-006: Dead Code and Cleanup

Four independent sub-items:

**A. Unused menu item properties** — Removed 3 stored `NSMenuItem?` properties and their assignments from `AppDelegate`. `NSMenu` retains the items; the stored references were never read.

**B. Dead `setSidebarVisible` method** — Removed from `WorkspaceViewContainer`. Initial state is set via constraint constants in `setup()`.

**C. Two-step State construction** — Added `sidebarVisible` and `lastSelectedProjectId` params to `WorkspacePersistence.State.init`, making `persist()` use single-step construction:

```swift
// Before
var state = WorkspacePersistence.State(projects: projects, sessions: sessions, templates: customTemplates)
state.sidebarVisible = sidebarVisible
state.lastSelectedProjectId = lastSelectedProjectId

// After
let state = WorkspacePersistence.State(
    projects: projects, sessions: sessions, templates: customTemplates,
    sidebarVisible: sidebarVisible, lastSelectedProjectId: lastSelectedProjectId
)
```

**D. Id vs ID naming** — Standardized `selectedProjectID` to `selectedProjectId` across `WorkspaceSidebarView` and `IconRailView` (matches majority lowercase `Id` convention in `lastSelectedProjectId`, `activeSessionId`, `projectId`).

---

## Files Changed

| File | Changes |
|------|---------|
| `WorkspaceSidebarView.swift` | P1-001: window filter + coordinator env object; P3-006D: rename |
| `TerminalController.swift` | P1-002: workspace guard in surfaceTreeDidChange + replaceSurfaceTree |
| `WorkspaceStore.swift` | P2-003: cleanup in removeProject; P3-006C: single-step persist |
| `WorkspacePersistence.swift` | P2-003: validation; P3-006C: init params |
| `SessionCoordinator.swift` | P2-004: async defer in surfaceDidClose |
| `WorkspaceViewContainer.swift` | P2-005: viewDidChangeEffectiveAppearance; P3-006B: remove dead method |
| `AppDelegate.swift` | P3-006A: remove unused stored properties |
| `IconRailView.swift` | P3-006D: rename selectedProjectID |

---

## Prevention Strategies

### 1. Notification Scoping in Multi-Window Apps

**Pattern:** Posting notifications globally without window context, then observing without filtering.
**Rule:** When posting notifications for a specific window, always pass the window as `object:`. When observing, always filter by comparing the notification's object to the receiver's window.
**Review trigger:** Any `.onReceive(NotificationCenter.default)` call that doesn't filter by window in a multi-window app.

### 2. Upstream Code Path Assumptions

**Pattern:** Upstream code assumes a particular UI context (no sidebar) and closes windows unconditionally.
**Rule:** When overriding upstream behavior, check for all contexts where the override will be called. If context varies, branch explicitly.
**Review trigger:** Any `window?.close()` or `closeTabImmediately()` call — ask "what if a sidebar/panel is still usable?"

### 3. Persistence Referential Integrity

**Pattern:** Storing foreign keys without cascade-delete or validation-on-load.
**Rule:** When storing references to deletable entities, implement both: cleanup on delete + validation on load.
**Review trigger:** Any `removeX(id:)` method — check if other stored state references the deleted entity.

### 4. Notification Observer Ordering

**Pattern:** Multiple observers on the same notification with implicit ordering assumptions.
**Rule:** Never assume observer ordering in `NotificationCenter`. Defer with `DispatchQueue.main.async` if you depend on another observer's side effects.
**Review trigger:** Two classes observing the same notification name, especially if one reads state that the other modifies.

### 5. Dynamic Colors on CALayer

**Pattern:** Calling `.cgColor` on `NSColor` captures a static value that doesn't respond to appearance changes.
**Rule:** Never store `.cgColor` from a dynamic `NSColor`. Re-resolve in `viewDidChangeEffectiveAppearance()` or `updateLayer()`.
**Review trigger:** Any `layer?.backgroundColor = NSColor.xxx.cgColor` — if it's set once, it needs an appearance observer.

### 6. Dead Code Discipline

**Pattern:** Stored properties never read, methods never called, multi-step initialization.
**Rule:** Use "Find References" for every property and method. Remove anything with zero readers. Consolidate multi-step init into single-step.
**Review trigger:** Any `private var` with no reader, any `func` with no caller.

---

## Code Review Checklist for macOS AppKit/SwiftUI Hybrid Apps

### Notifications & Multi-Window
- [ ] Every notification includes window identity in `object:` or `userInfo`
- [ ] Every `.onReceive` filters by window before acting
- [ ] No implicit ordering between notification observers
- [ ] Async safety: notifications posted/observed across threads

### Window Lifecycle
- [ ] Before closing windows, check for active sidebar/panel state
- [ ] Callbacks validate current UI context before side effects
- [ ] Window close is undoable where appropriate

### Data & Persistence
- [ ] Foreign key references cleaned up on entity deletion
- [ ] Validation on load catches stale references
- [ ] No two-step construction when single-step is possible

### Colors & Appearance
- [ ] Dynamic NSColors not captured as static CGColor
- [ ] `viewDidChangeEffectiveAppearance()` refreshes layer properties
- [ ] SwiftUI `Color` preferred over `NSColor.cgColor` where possible

### Code Quality
- [ ] Every stored property has at least one reader
- [ ] Every method has at least one caller
- [ ] Naming conventions consistent within and across types

---

## Related Documentation

- **Phase 1 solution:** `docs/solutions/integration-issues/ghostty-fork-workspace-sidebar-phase1.md`
- **Phase 2 solution:** `docs/solutions/integration-issues/ghostty-fork-workspace-sidebar-phase2.md`
- **Architecture doc:** `docs/solutions/architecture/two-layer-state-architecture-swiftui-appkit-session-management.md`
- **Master plan:** `docs/plans/2026-02-19-feat-ghostties-workspace-sidebar-plan.md`
- **Review findings:** `todos/001-complete-p1-multi-window-notification-scoping.md` through `todos/006-complete-p3-dead-code-and-cleanup.md`
- **Brainstorm:** `docs/brainstorms/2026-02-19-ghostties-brainstorm.md`

## Dependency Chain

```
Phase 1 Solution (fork/build findings)
  → Phase 2 Solution (timer, state, YAGNI findings)
    → Phase 3 Architecture Doc (two-layer state, known issues)
      → Phase 4 Review (this document: 6 findings, all resolved)
```

Each phase's review findings informed the next phase's implementation, creating a continuous improvement cycle.
