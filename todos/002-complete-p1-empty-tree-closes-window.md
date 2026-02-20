---
status: complete
priority: p1
issue_id: "002"
tags: [code-review, architecture, correctness, session-lifecycle]
dependencies: []
---

# Empty Surface Tree Closes Window When Sessions Still Exist in Sidebar

## Problem Statement

`TerminalController.replaceSurfaceTree` has a special case: when the new tree is empty, it calls `closeTabImmediately()`. When the last surface in the active session exits naturally, `BaseTerminalController.ghosttyDidCloseSurface` removes the surface node, resulting in an empty tree passed to `replaceSurfaceTree`. This closes the window/tab even though the sidebar may still contain exited sessions the user wants to relaunch.

## Findings

- **Architecture Strategist**: Flagged as Risk 2 (P1) — "the sidebar still has exited sessions the user might want to relaunch"
- The `switchToNextSession()` method handles the case where no running sessions remain by setting `activeSessionId = nil`, but by then the controller has already closed the window via the empty-tree path

## Proposed Solutions

### Option A: Guard in TerminalController.replaceSurfaceTree (Low effort)
Check if a `WorkspaceViewContainer` is present. If so, allow empty trees without closing:
```swift
override func replaceSurfaceTree(_ newTree: ...) {
    if newTree.isEmpty {
        if window?.contentView is WorkspaceViewContainer<TerminalController> {
            super.replaceSurfaceTree(newTree, ...)
            return // Don't close — sidebar is still usable
        }
        closeTabImmediately()
        return
    }
    super.replaceSurfaceTree(...)
}
```
**Pros:** Minimal change, targeted fix
**Cons:** Adds workspace-awareness to TerminalController
**Effort:** Small
**Risk:** Low

### Option B: Coordinator installs placeholder tree (Medium effort)
When the last surface in the active session dies, the coordinator installs a lightweight placeholder surface instead of leaving the tree empty.
**Pros:** No empty-tree edge case at all
**Cons:** Requires creating a "blank" surface, more complex
**Effort:** Medium
**Risk:** Medium

## Recommended Action

Option A — guard in `replaceSurfaceTree` to skip window close when workspace sidebar is present.

## Technical Details

**Affected files:**
- `macos/Sources/Features/Terminal/TerminalController.swift` (lines 167-178)

## Acceptance Criteria

- [ ] Last surface in active session exits → window stays open with sidebar visible
- [ ] User can click "Relaunch" on exited session from sidebar
- [ ] Non-workspace windows still close when tree is empty (no regression)

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by Architecture Strategist | P1 finding |

## Resources

- Commit: `765fb0fd5`
- `TerminalController.replaceSurfaceTree` override at line 167
