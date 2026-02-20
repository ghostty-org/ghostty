---
status: complete
priority: p1
issue_id: "001"
tags: [code-review, architecture, correctness, multi-window]
dependencies: []
---

# Multi-Window Project Navigation Notifications Are Unscoped

## Problem Statement

The `workspaceSelectNextProject` and `workspaceSelectPreviousProject` notifications posted by `TerminalController` include `object: window`, but the `.onReceive` handlers in `WorkspaceSidebarView` ignore the notification object. In a multi-window setup, pressing Cmd+Shift+] in Window A will advance the project selection in **all** windows' sidebars simultaneously.

This directly undermines the Phase 2 review fix that moved `selectedProjectID` to per-window `@State`.

## Findings

- **Pattern Recognition**: Flagged as P2 functional bug in multi-window
- **Architecture Strategist**: Flagged as P1 correctness + "Risk 5"
- **Security Sentinel**: Flagged as behavioral correctness (Finding 3)
- **Performance Oracle**: Flagged as correctness + performance multiplier
- **Data Integrity**: Confirmed unscoped notifications (Finding 7)
- **Code Simplicity**: Recommended replacing notifications with direct method calls entirely
- **Git History**: Notes this undermines the per-window `@State` work from Phase 2 audit

## Proposed Solutions

### Option A: Filter notifications by window (Low effort)
Pass coordinator reference to filter window identity:
```swift
.onReceive(NotificationCenter.default.publisher(for: .workspaceSelectNextProject)) { notification in
    guard notification.object as? NSWindow === coordinator.containerView?.window else { return }
    selectAdjacentProject(offset: 1)
}
```
**Pros:** Minimal change, keeps notification pattern
**Cons:** Requires coordinator to expose window, still indirect
**Effort:** Small
**Risk:** Low

### Option B: Replace notifications with direct method calls (Medium effort, recommended)
Mirror the `toggleWorkspaceSidebar` pattern — `TerminalController` calls into `WorkspaceViewContainer`, which delegates to a method on a hosted SwiftUI coordinator. Eliminates the 2 `Notification.Name` constants, 2 `onReceive` handlers, and 2 `post` calls.
**Pros:** Fixes bug, simpler, consistent with toggle pattern, removes ~18 lines
**Cons:** Requires adding methods to WorkspaceViewContainer + bridging to SwiftUI state
**Effort:** Medium
**Risk:** Low

## Recommended Action

Option B — direct method calls following the existing toggleSidebar pattern.

## Technical Details

**Affected files:**
- `macos/Sources/Features/Terminal/TerminalController.swift` (lines 1189-1195)
- `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` (lines 42-47)
- `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` (notification constants)
- `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift` (new methods)

## Acceptance Criteria

- [ ] Pressing Cmd+Shift+] in Window A does NOT change project in Window B
- [ ] Pressing Cmd+Shift+[ in Window A does NOT change project in Window B
- [ ] Single-window project cycling still works correctly
- [ ] Menu items still function

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by 7/7 review agents | Consensus finding |

## Resources

- Commit: `765fb0fd5`
- Phase 2 audit fix: `4c746e302` (per-window `@State`)
