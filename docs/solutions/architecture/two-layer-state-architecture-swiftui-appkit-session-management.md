---
title: "Two-Layer State Architecture for SwiftUI-AppKit Session Management"
date: 2026-02-20
category: architecture
tags:
  - SwiftUI
  - AppKit
  - state-management
  - terminal-emulator
  - sidebar-navigation
  - observable-objects
  - window-scoped-coordination
  - session-lifecycle
  - template-crud
component: "Workspace Sidebar Session Management (Phase 3)"
severity: high
time_to_solve: "3-4 hours"
root_cause: "SwiftUI and AppKit maintain separate state graphs — sidebar is SwiftUI (ObservableObject), terminal surface is AppKit (SurfaceView), and session processes need to persist across surface switches. Required dual-layer state architecture: persistent store layer (WorkspaceStore) + runtime coordination layer (SessionCoordinator)."
---

# Two-Layer State Architecture for SwiftUI-AppKit Session Management

## Problem Statement

The Ghostties workspace sidebar needed session management: creating terminal sessions from templates, switching between them (vertical tab model), and tracking lifecycle (running/exited). The core challenge was bridging SwiftUI sidebar state with Ghostty's AppKit-based terminal surface system, where:

- The sidebar (SwiftUI) manages the session list, template picker, and user interactions
- The terminal area (AppKit) owns `SurfaceView` instances that run actual processes
- Background sessions must keep their processes alive when not displayed
- Session metadata must persist across app restarts, but runtime references (SurfaceViews) cannot be serialized

## Solution

### Architecture: Two-Layer State Model

**Layer 1: WorkspaceStore (Persistent)**
- Singleton shared instance across all windows
- Holds projects, sessions, and templates as `@Published` properties
- Persists workspace state to `~/Library/Application Support/Ghostties/workspace.json`
- Manages CRUD operations for all workspace entities
- Default templates (Shell, Claude Code) are immutable; custom templates support full lifecycle management

```swift
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var templates: [SessionTemplate] = []
}
```

**Layer 2: SessionCoordinator (Runtime, Per-Window)**
- One instance per window, injected via `.environmentObject()`
- Tracks active session ID and maintains dictionary of `SurfaceView` instances
- Holds strong references to `SurfaceView` objects to keep background session processes alive
- Lazily discovers its parent window controller through `containerView?.window?.windowController`
- Observes `Ghostty.Notification.ghosttyCloseSurface` for lifecycle tracking

```swift
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var activeSessionId: UUID?
    @Published private(set) var surfaceViews: [UUID: Ghostty.SurfaceView] = [:]
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]
}
```

### Key Code Patterns

**Session Creation Flow:**
1. User clicks "New Session" -> template picker popover displays available templates
2. User selects template -> `WorkspaceStore.addSession()` creates persistent session record
3. `SessionCoordinator.createSession()` instantiates `SurfaceConfiguration` from template, creates `SurfaceView`, replaces the window's split tree
4. Previous session's surface remains alive in `surfaceViews` dictionary

**Session Switching (Vertical Tab Model):**
- Clicking a session in sidebar calls `coordinator.focusSession(id:)`
- This replaces `controller.surfaceTree` with `SplitTree(view: surfaceView)`
- Previous surface stays alive in memory — processes keep running in background

**Template Management:**
- Default templates marked with `isDefault` flag cannot be edited or deleted
- Custom templates support: Edit (name, command, env vars), Duplicate, Delete
- Delete shows confirmation with in-use warning if sessions reference the template
- Environment variables parsed from newline-separated `KEY=VALUE` text format

### Design Decisions

1. **ObservableObject over @Observable** — macOS 13 compatibility (Ghostty supports 13+); `@Observable` requires macOS 14+
2. **Singleton WorkspaceStore** — Simple shared state across windows with single persistence point
3. **Per-window SessionCoordinator** — Each window independently manages which session is visible, preventing unwanted cross-window switching
4. **Strong SurfaceView references** — Dictionary prevents deallocation of inactive sessions, keeping processes alive (matches native terminal tab behavior)
5. **Lazy window controller discovery** — Avoids initialization-order issues and strong reference cycles between SwiftUI and AppKit layers

### Ghostty APIs Used

| API | Purpose |
|-----|---------|
| `Ghostty.SurfaceConfiguration` | Configure command, env vars, working directory |
| `Ghostty.SurfaceView(app, baseConfig:)` | Create new terminal surface |
| `SplitTree(view:)` | Replace terminal area content |
| `BaseTerminalController.surfaceTree` | Set the active split tree |
| `BaseTerminalController.focusedSurface` | Track focused surface |
| `BaseTerminalController.closeSurface(_:withConfirmation:)` | Terminate a session |
| `Ghostty.Notification.ghosttyCloseSurface` | Surface lifecycle observation |
| `Ghostty.moveFocus(to:from:)` | Transfer focus between surfaces |

## Files Involved

**New (Phase 3):**
- `macos/Sources/Features/Ghostties/Models/AgentSession.swift` — Session model + `SessionStatus` enum
- `macos/Sources/Features/Ghostties/Models/SessionTemplate.swift` — Template model with defaults
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — Runtime bridge to Ghostty surfaces
- `macos/Sources/Features/Ghostties/SessionDetailView.swift` — Session list + `SessionRow`
- `macos/Sources/Features/Ghostties/TemplatePickerView.swift` — Template picker + `TemplateEditForm`

**Modified:**
- `macos/Sources/Features/Ghostties/WorkspaceStore.swift` — Added session + template CRUD
- `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` — Added session/template serialization
- `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` — Integrated SessionDetailView
- `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift` — Wired SessionCoordinator

## Prevention & Best Practices

### Two-Layer State Pattern

- Use **WorkspaceStore** for user-facing data that must survive app restarts (project names, session records, template configs)
- Use **SessionCoordinator** for transient references (SurfaceView objects, current focus state, live process status)
- Keep layers strictly separated: never serialize AppKit objects; never persist SwiftUI view state
- When a user creates a session: `UI -> WorkspaceStore.addSession() -> persist -> SessionCoordinator.createSession()`
- When a session closes: `Notification -> SessionCoordinator updates status -> user can delete from WorkspaceStore`

### SwiftUI-AppKit Bridging

- Use **weak reference** for `containerView` to avoid retain cycles
- Discover window controller as a **computed property** (not stored), traversing `containerView?.window?.windowController`
- Use `DispatchQueue.main.async` when crossing the AppKit-SwiftUI boundary for focus management
- Guard on nil early in methods that need the window controller

### Template System

- Built-in defaults must use **deterministic UUIDs** (fixed UUID literals, not `UUID()`)
- Sessions reference template IDs — if IDs change on relaunch, sessions lose their template association
- Merge strategy: `self.templates = SessionTemplate.defaults + customTemplates` ensures defaults always present
- Protect defaults with `isDefault` flag; reject edits/deletes on default templates

### Session Lifecycle

- Both `BaseTerminalController` and `SessionCoordinator` may observe `ghosttyCloseSurface`
- Each observer should have clear responsibility: controller handles splits/undo, coordinator handles tracking/switching
- Remove notification observers in `deinit` to prevent crashes
- When active session closes, automatically switch to the next running session

### Known Issues (from code review)

| Severity | Issue | Status |
|----------|-------|--------|
| P1 | Default template UUIDs regenerated on every launch | Needs fix: use deterministic UUIDs |
| P1 | Dual notification handlers may race on `ghosttyCloseSurface` | Needs verification |
| P1 | Direct `surfaceTree` mutation bypasses undo registration | Needs fix or undo disable |
| P2 | Synchronous I/O in `WorkspacePersistence.save()` on main thread | Should debounce to background queue |
| P2 | No validation of corrupt `workspace.json` | Should back up corrupt files, validate referential integrity |
| P2 | Environment variables not sanitized | Should validate keys/values before passing to Ghostty |

### Testing Checklist

- [ ] Create session from Shell and Claude Code templates
- [ ] Switch between sessions — background process keeps running
- [ ] Close active session — focus switches to next running session
- [ ] Relaunch exited session from context menu
- [ ] Create, edit, duplicate, delete custom templates
- [ ] Delete template with in-use warning
- [ ] Quit and relaunch — sessions show as "Exited" with correct metadata
- [ ] Force-quit and relaunch — workspace.json recovers all data
- [ ] Multi-window — each window manages sessions independently

## Related Documentation

- [Phase 1: Forking Ghostty and Adding a Workspace Sidebar](../integration-issues/ghostty-fork-workspace-sidebar-phase1.md)
- [Phase 2: Icon Rail, Project Management, and Persistence](../integration-issues/ghostty-fork-workspace-sidebar-phase2.md)
- [Master Plan: Ghostties Workspace Sidebar](../../plans/2026-02-19-feat-ghostties-workspace-sidebar-plan.md)
- [Brainstorm: Ghostties Concept](../../brainstorms/2026-02-19-ghostties-brainstorm.md)
