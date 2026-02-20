---
status: complete
priority: p2
issue_id: "004"
tags: [code-review, architecture, race-condition]
dependencies: []
---

# surfaceDidClose Notification Ordering Race with BaseTerminalController

## Problem Statement

Both `SessionCoordinator.surfaceDidClose` and `BaseTerminalController.ghosttyDidCloseSurface` observe the same `ghosttyCloseSurface` notification. The coordinator assumes BaseTerminalController has already updated the live tree when it reads `controller.surfaceTree` (line 195). However, `NotificationCenter` delivery order depends on registration order, which is not guaranteed.

If the coordinator fires first, it snapshots a stale tree that still contains the closed surface. The snapshot self-heals on the next session switch (via `snapshotActiveTree()`), but there is a window where `sessionTrees` contains a dead surface.

## Findings

- **Architecture Strategist**: Risk 1 (Medium) — "notification ordering race"
- **Git History Analyzer**: Concern 2 in SessionCoordinator — "timing assumption"
- **Data Integrity Guardian**: Finding 4b — "subtle ordering dependency"

## Proposed Solutions

### Option A: Defer coordinator processing by one tick (Low effort)
```swift
@objc private func surfaceDidClose(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
        self?.handleSurfaceClose(notification)
    }
}
```
**Pros:** Ensures BaseTerminalController processes first (it runs synchronously)
**Cons:** Slightly delayed status update
**Effort:** Small
**Risk:** Low

### Option B: Filter closed surface from snapshotted tree (Low effort)
After reading `controller.surfaceTree`, remove the closed surface before storing:
```swift
let liveTree = controller.surfaceTree
// Defensive: ensure closed surface is not in snapshot
if let node = liveTree.root?.node(view: closedSurface) {
    sessionTrees[sessionId] = liveTree.removing(node)
} else {
    sessionTrees[sessionId] = liveTree
}
```
**Pros:** Correct regardless of notification order
**Cons:** Redundant removal if BaseTerminalController already processed
**Effort:** Small
**Risk:** Low

## Recommended Action

Option A — simplest and handles all edge cases.

## Acceptance Criteria

- [ ] Closing a split surface in the active session does not leave a stale surface in sessionTrees
- [ ] Status still updates correctly (running/exited/killed)

## Work Log

| Date | Action | Result |
|------|--------|--------|
| 2026-02-20 | Identified by 3 review agents | P2 consensus |
