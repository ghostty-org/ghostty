# Session Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement full session lifecycle management - delete closes split, resume recreates split, surface close auto-unlinks session.

**Architecture:** Add notifications for close/resume, implement handlers in TerminalController, add surface-to-session linking, and wire up Ghostty surface close events to auto-unlink sessions.

**Tech Stack:** Swift (Ghostty API), NotificationCenter for cross-component messaging

---

## File Structure

| File | Responsibility |
|------|----------------|
| `macos/Sources/Ghostty/SidePanel/SessionManager.swift` | Add `kanbanCloseSurface`, `kanbanResumeSession` notifications |
| `macos/Sources/Features/Terminal/TerminalController.swift` | Add close/resume handlers, `findSurfaceView`, auto-unlink on surface close |
| `macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift` | Add `kanbanCloseSurface` notification definition |

---

## Task 1: Add `kanbanCloseSurface` Notification Definition

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift:1-30` (notification definitions area)

- [ ] **Step 1: Find the existing notification definitions**

Read `SidePanelViewModel.swift` and locate where `kanbanCreateSplit`, `kanbanResumeSession` notifications are defined (around lines 15-30).

- [ ] **Step 2: Add `kanbanCloseSurface` notification definition**

```swift
extension Notification.Name {
    static let kanbanCloseSurface = Notification.Name("kanbanCloseSurface")
    static let kanbanResumeSession = Notification.Name("kanbanResumeSession")
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SidePanelViewModel.swift
git commit -m "feat(session): add kanbanCloseSurface and kanbanResumeSession notification names"
```

---

## Task 2: Update SessionManager to Post Close/Resume Notifications

**Files:**
- Modify: `macos/Sources/Ghostty/SidePanel/SessionManager.swift` (deleteSession and navigateToSession methods)

- [ ] **Step 1: Read SessionManager.swift to find deleteSession and navigateToSession methods**

```bash
grep -n "func deleteSession\|func navigateToSession" macos/Sources/Ghostty/SidePanel/SessionManager.swift
```

- [ ] **Step 2: Update `deleteSession` to post `kanbanCloseSurface` before removing**

Find the `deleteSession` method (around line 60-70) and add:

```swift
// 2. Close surface if linked
if let surfaceId = session.surfaceId {
    NotificationCenter.default.post(
        name: .kanbanCloseSurface,
        object: nil,
        userInfo: ["surfaceId": surfaceId]
    )
}
```

Insert this BEFORE `sessions.removeAll`.

- [ ] **Step 3: Update `navigateToSession` to post `kanbanResumeSession`**

Find `navigateToSession` (around line 90-100) and replace the print stub with:

```swift
NotificationCenter.default.post(
    name: .kanbanResumeSession,
    object: nil,
    userInfo: ["sessionId": id]
)
```

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Ghostty/SidePanel/SessionManager.swift
git commit -m "feat(session): post kanbanCloseSurface/kanbanResumeSession notifications"
```

---

## Task 3: Add `findSurfaceView(by surfaceId:)` Method

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

- [ ] **Step 1: Find where surface-related properties are defined**

Search for `focusedSurface`, `surface`, or similar in TerminalController.swift.

- [ ] **Step 2: Add the `findSurfaceView` helper method**

Add this method to TerminalController class (around line 300, after other surface methods):

```swift
private func findSurfaceView(by surfaceId: UInt64) -> SurfaceView? {
    for child in surfaceSplitViewController.children {
        if let surfaceView = child as? SurfaceView,
           UInt64(surfaceView.surface) == surfaceId {
            return surfaceView
        }
    }
    return nil
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift
git commit -m "feat(terminal): add findSurfaceView(by surfaceId:) method"
```

---

## Task 4: Add `onKanbanCloseSurface` Handler

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

- [ ] **Step 1: Find where `onKanbanCreateSplit` is defined (as reference)**

```bash
grep -n "onKanbanCreateSplit\|NotificationCenter.default.addObserver" macos/Sources/Features/Terminal/TerminalController.swift | head -20
```

- [ ] **Step 2: Add observer registration in init (after `onKanbanCreateSplit` registration)**

Around line 150 in init:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(onKanbanCloseSurface(_:)),
    name: .kanbanCloseSurface,
    object: nil
)
```

- [ ] **Step 3: Add `onKanbanCloseSurface` handler method**

Add after `onKanbanCreateSplit` (around line 200):

```swift
@objc private func onKanbanCloseSurface(_ notification: Notification) {
    guard let surfaceId = notification.userInfo?["surfaceId"] as? UInt64 else { return }

    if let surfaceView = findSurfaceView(by: surfaceId) {
        ghostty.requestClose(surface: surfaceView.surface)
    }

    SessionManager.shared.unlinkSurface(surfaceId: surfaceId)
}
```

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift
git commit -m "feat(terminal): add onKanbanCloseSurface handler"
```

---

## Task 5: Add `onKanbanResumeSession` Handler

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

- [ ] **Step 1: Add observer registration in init**

Add after the `kanbanCloseSurface` observer:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(onKanbanResumeSession(_:)),
    name: .kanbanResumeSession,
    object: nil
)
```

- [ ] **Step 2: Add `onKanbanResumeSession` handler method**

Add after `onKanbanCloseSurface` (around line 220):

```swift
@objc private func onKanbanResumeSession(_ notification: Notification) {
    guard let sessionId = notification.userInfo?["sessionId"] as? UUID,
          let session = SessionManager.shared.session(for: sessionId) else { return }

    guard let sourceSurface = focusedSurface?.surface else { return }

    // 1. Create split
    ghostty.split(surface: sourceSurface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)

    // 2. Wait for split creation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let newSurface = self?.focusedSurface?.surface else { return }

        // 3. Build resume command (use --resume, NOT --session-id)
        var command = "claude --resume \(session.sessionId ?? sessionId.uuidString)"
        if session.isWorkTree {
            command += " --worktree \(session.branch)"
        }
        command += " --permission-mode bypassPermissions\r"

        // 4. Send command
        Ghostty.Surface(cSurface: newSurface).sendText(command)

        // 5. Update surfaceId association
        SessionManager.shared.linkSessionToSurface(
            sessionId: sessionId,
            surfaceId: UInt64(newSurface)
        )
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift
git commit -m "feat(terminal): add onKanbanResumeSession handler with --resume command"
```

---

## Task 6: Wire Up Surface Close Auto-Unlink

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

- [ ] **Step 1: Find where `ghosttyCloseSurface` notification is handled**

```bash
grep -n "ghosttyCloseSurface" macos/Sources/Features/Terminal/TerminalController.swift
```

- [ ] **Step 2: Find the handler that processes surface close events**

Look for existing surface close handler (around line 250-280).

- [ ] **Step 3: Add unlink call to surface close handler**

In the `ghosttyCloseSurface` handler, after the surface is closed, add:

```swift
// Auto-unlink session associated with this surface
if let surfaceView = notification.object as? SurfaceView {
    SessionManager.shared.unlinkSurface(surfaceId: UInt64(surfaceView.surface))
}
```

Place this before any surface cleanup code.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift
git commit -m "feat(terminal): auto-unlink session on surface close"
```

---

## Task 7: Fix onKanbanCreateSplit to Use linkSessionToSurface

**Files:**
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

- [ ] **Step 1: Find `onKanbanCreateSplit` handler**

```bash
grep -n "onKanbanCreateSplit" macos/Sources/Features/Terminal/TerminalController.swift
```

- [ ] **Step 2: Read the method to find where it creates the session**

The method creates a session via SessionManager but never links the surfaceId after the split is created.

- [ ] **Step 3: Add `linkSessionToSurface` call after sending the command**

After `Ghostty.Surface(cSurface: newSurface).sendText(command)` (around line 175), add:

```swift
// Link session to new surface
if let sessionId = UUID(uuidString: sessionIdString) {
    SessionManager.shared.linkSessionToSurface(
        sessionId: sessionId,
        surfaceId: UInt64(newSurface)
    )
}
```

Note: You may need to capture `sessionIdString` from the session creation context.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Terminal/TerminalController.swift
git commit -m "fix(terminal): link session to surface after createSplit"
```

---

## Task 8: Verify Build

- [ ] **Step 1: Build the project**

```bash
cd macos && xcodebuild -scheme Ghostty -configuration Debug build 2>&1 | tail -50
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: If build fails, diagnose and fix**

Common issues:
- Missing import for SessionManager
- Type mismatch for surfaceId (UInt64 vs Int)

---

## Self-Review Checklist

1. **Spec coverage:** All requirements from session-lifecycle.md implemented:
   - [x] Delete session closes surface (`onKanbanCloseSurface`)
   - [x] Resume session creates surface (`onKanbanResumeSession`)
   - [x] Surface close auto-unlinks (`ghosttyCloseSurface` handler)
   - [x] `--resume` command used (not `--session-id`)
   - [x] Worktree support with `--worktree` flag

2. **Placeholder scan:** No "TBD", "TODO", or incomplete steps

3. **Type consistency:** 
   - `surfaceId: UInt64` matches Session model
   - `sessionId: UUID` matches Session model
   - Notification names match between SessionManager and TerminalController

---

**Plan complete.** Saved to `docs/superpowers/plans/2026-04-28-session-management.md`

Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
