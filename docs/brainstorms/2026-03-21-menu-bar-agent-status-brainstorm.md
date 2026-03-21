# Menu Bar Agent Status Brainstorm — 2026-03-21

> macOS menu bar extra showing global agent session status across all windows — upleveling the sidebar's session indicators into an always-visible dashboard.

## What We're Building

A macOS menu bar extra (NSStatusItem) that shows a global view of all running agent sessions across all windows. The menu bar icon reflects aggregate agent activity. Clicking opens a dropdown showing each active session with its status.

The sidebar already has rich session status indicators with 6 states (inactive, idle, processing, longRunning, waiting, error), computed by SessionCoordinator from output timestamps, shell prompt detection, and exit codes. The menu bar takes this per-window data and surfaces it globally.

## Why

- **Sidebar is per-window** — you can't see agents in background windows. If an orchestrator finishes in window 2 while you're focused on window 1, you have no signal.
- **Power users with multiple windows/projects** want a global dashboard. Running 5 agents across 3 projects is normal. Switching windows to check status is friction.
- **Menu bar is always visible**, even when Ghostties windows are hidden or minimized. You can be in Safari and see your agents are still working.
- **Matches existing macOS patterns** — Docker Desktop, Homebrew Services, Xcode (build status), Raycast. Users already know to glance at the menu bar for background process status.

## Key Questions

### 1. Menu bar icon — What should it show?

Options to consider:

- **Static ghost icon with color-coded dot** (like Docker's whale + green/red dot). Simple, unambiguous. Dot color maps to aggregate state. Doesn't fight for attention.
- **Animated ghost** that bounces or pulses based on aggregate state. More expressive but potentially distracting. Could annoy users who don't want motion in their menu bar.
- **Badge count** of active agents (like Mail's unread count). Quick signal of "how many things are working." Less info about what state they're in.
- **Multiple options — user configurable**. Let user pick in preferences. More work, more flexibility.

Lean: Static ghost + color dot for v1. It's the lowest-friction option and doesn't require animation infrastructure in NSStatusItem (which is more constrained than SwiftUI views).

### 2. Dropdown content — What appears when clicked?

Thinking through the information hierarchy:

- **Grouped by project** — each project shows its ghost character + name as a section header, with sessions listed underneath. Mirrors the sidebar's disclosure row pattern.
- **Each session row**: ghost character (small) + session name + status dot + template name (e.g., "Claude Code", "Orchestrator"). The status dot reuses the same color scheme from SessionDetailView.
- **Quick actions per session**: focus (bring window to front + select session), relaunch, stop. These are read-then-act — you see status, then decide what to do.
- **Footer**: "New Session" shortcut, maybe "Open Ghostties" if all windows are hidden.

Open question: NSMenu (standard menu dropdown) vs NSPopover (custom SwiftUI view). NSMenu is simpler and feels native. NSPopover allows richer layout (ghost characters, animations, grouping) but is more work and can feel non-standard.

### 3. Aggregate status logic — How to summarize N sessions into one icon?

The icon needs to collapse N session states into a single signal. Priority ordering (highest wins):

```
error         → red dot       (something broke, needs attention)
longRunning   → amber dot     (been going a while, FYI)
processing    → green dot     (active work happening)
waiting       → terracotta    (agent asked a question / needs input)
idle          → gray dot      (at shell prompt, nothing happening)
inactive      → no dot / dim  (no sessions running)
```

This mirrors SessionDetailView's existing 6-state enum but flattened to aggregate. The "worst" state wins — if any session is errored, the icon shows error regardless of other sessions.

Edge case: What about mixed states? 2 processing + 1 error = error. That's correct — the error demands attention. But should the dropdown sort errored sessions to the top? Probably yes.

### 4. Architecture — How to implement?

Current architecture gap: SessionCoordinator is per-window. Each window has its own coordinator tracking its own sessions. There's no global view.

Options:

- **A: Global SessionRegistry singleton** — A new `@MainActor` ObservableObject that all SessionCoordinators register with. Each coordinator pushes status updates to the registry. The menu bar observes only the registry. Clean separation, but introduces a singleton.
- **B: NotificationCenter pub/sub** — Each SessionCoordinator posts `agentStatusChanged` notifications. The menu bar controller observes these and builds its own state. Loose coupling, but notification-based state management gets messy.
- **C: WorkspaceStore extension** — WorkspaceStore already has `globalStatuses: [UUID: Status]`. Extend it to be accessible cross-window. But WorkspaceStore is also per-window today.

Lean: Option A (SessionRegistry). It's explicit, testable, and the menu bar is inherently a global concept that deserves a global data source.

For the view layer:

- **SwiftUI MenuBarExtra** (macOS 13+) — Clean SwiftUI integration, but limited customization of the menu bar icon itself.
- **AppKit NSStatusItem** — Full control over icon rendering, supports both NSMenu and NSPopover. More code but more flexibility.
- **Hybrid** — NSStatusItem for the icon (AppKit), NSPopover containing a SwiftUI hosting view for the dropdown content. Best of both worlds.

Lean: Hybrid approach. NSStatusItem gives control over the icon (important for the color dot), SwiftUI popover gives us the rich dropdown layout with ghost characters.

### 5. Relationship to sidebar indicators

The menu bar is a **read-only projection** of sidebar state. All mutations (create session, relaunch, stop) go through the sidebar's existing code paths. The menu bar just observes and displays.

Reuse opportunities:

- **SessionIndicatorState enum** — same 6 states, same color mapping. Don't duplicate the enum.
- **SessionDetailView animation patterns** — the status dot animations (bounce for processing, pulse for waiting) could be reused in the dropdown rows. But menu bar icon itself should probably not animate (see question 1).
- **GhostCharacterView** — each project's ghost character shows in the dropdown row. Reuse the vector rendering.
- **AgentTemplate.Kind** — menu bar could filter to only show `.claudeCode` and `.custom` sessions, hiding plain `.shell` sessions. Or show everything. User preference?

### 6. Scope — What's v1 vs future?

| Version | Scope | Notes |
|---------|-------|-------|
| v1 | Static ghost icon + color dot. Dropdown list with status dots. Click row to focus. | Minimal viable. Proves the pattern. |
| v2 | Animated icon reflecting aggregate state. Richer dropdown with ghost characters. | Polish pass. |
| v3 | Quick actions in dropdown (relaunch, stop). Keyboard navigation. | Power user features. |
| v4 | Notifications for state changes (agent finished, agent errored). macOS notification center integration. | "Your orchestrator finished" as a system notification. |
| v5 | Menu bar icon shows progress indicator for long-running agents. History of recent completions. | Dashboard-level features. |

v1 is the only thing worth planning for now. The rest emerges from usage.

## Open Questions

- **Icon design**: Should the menu bar icon be the Ghostties app icon (recognizable but large) or a minimal ghost silhouette (subtle, menu-bar-appropriate)? The app icon might be too detailed at 18x18pt.
- **Session filtering**: Should it show ALL sessions or only agent sessions (filter out plain Shell)? Shell sessions are noise if you're checking on your agents. But some users might want to see everything.
- **Scale**: How to handle 20+ sessions? Scrollable list? Grouped by project with collapse? At some point a dropdown becomes unwieldy. Maybe cap visible rows and add "Show all in sidebar" link.
- **Window focus**: Should clicking a session row bring that window to front and focus that session in the sidebar? This crosses window boundaries — the menu bar controller needs a reference to the window's SessionCoordinator to call `focusSession(id:)`.
- **Menubar persistence**: Should the menu bar extra be always-on, or togglable in preferences? Some users hate menu bar clutter.
- **Multiple Ghostties instances**: If someone runs two copies of the app (unlikely but possible), do we get conflicts? Probably not a concern for v1.
- **Agent-only vs all sessions**: The AgentTemplate model has `.shell`, `.claudeCode`, and `.custom` kinds. The menu bar probably only cares about `.claudeCode` and `.custom` — Shell sessions don't have meaningful "agent status." But the user might want to see if a shell session errored.

## Affected Files (likely)

| File | Impact |
|------|--------|
| New: `MenuBar/MenuBarController.swift` | NSStatusItem setup, icon management, aggregate state computation |
| New: `MenuBar/MenuBarDropdownView.swift` | SwiftUI view for the popover/menu content |
| New: `MenuBar/SessionRegistry.swift` | Global session state aggregator, observed by menu bar |
| Modified: `AppDelegate.swift` | Register menu bar extra on app launch |
| Modified: `SessionCoordinator.swift` | Register/deregister with SessionRegistry, publish status changes |
| Reuse: `SessionDetailView.swift` | Status dot colors/animations pattern |
| Reuse: `GhostCharacterView.swift` | Ghost rendering in dropdown rows |
| Reuse: `WorkspaceLayout.swift` | Color tokens (waitingTerracotta, etc.) |

Path convention: `macos/Sources/Features/Ghostties/MenuBar/` or `macos/Sources/Features/MenuBar/` — depends on whether this is a Ghostties-specific feature or could be a standalone feature module. Lean toward the former since it deeply depends on SessionCoordinator.

---

*Next: Discuss with user, then `/workflows:plan` when ready.*
