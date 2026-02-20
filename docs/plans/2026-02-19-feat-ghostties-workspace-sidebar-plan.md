---
title: "feat: Ghostties — Workspace sidebar for Ghostty"
type: feat
date: 2026-02-19
brainstorm: docs/brainstorms/2026-02-19-ghostties-brainstorm.md
---

# Ghostties — Multi-project workspace sidebar for Ghostty

## Overview

Fork Ghostty and add a native sidebar for managing multiple projects and terminal sessions (AI agents, dev servers, shells) from a single integrated window. The sidebar has a hover-expand icon rail on the far left and a session detail panel, with Ghostty's native terminal + splits on the right.

**Brainstorm:** [2026-02-19-ghostties-brainstorm.md](../brainstorms/2026-02-19-ghostties-brainstorm.md)

## Problem Statement

When running 3-5+ projects with multiple Claude Code agents and dev servers, there's no native way to organize and switch between them. Existing solutions (Roro) are Electron-based and glitchy. Ghostty is an excellent terminal but has no concept of projects or session management.

## Proposed Solution

Minimal Ghostty fork — modify only 2 upstream files, add a new `Ghostties/` feature directory. Uses SwiftUI `NavigationSplitView` inside Ghostty's existing AppKit window, following the pattern validated by Ghostree.

---

## Technical Approach

### Fork Setup

1. **Fork Ghostty via GitHub** (not clone — preserves MIT license chain)
   - `github.com/SeanSmithDesign/ghostties` forked from `github.com/ghostty-org/ghostty`
2. **Remote strategy:**
   - `origin` = your fork
   - `upstream` = ghostty-org/ghostty
   - `upstream-main` branch = pure fast-forward mirror of upstream
3. **Branch strategy:**
   - `upstream-main` — only fast-forward merges from upstream
   - `main` — your customizations on top
   - Feature branches → squash merge into `main`

### Build Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Zig** | 0.14.1 (for Ghostty 1.2.x) | Download from ziglang.org, don't use Homebrew |
| **Xcode** | 15 or 16 | With macOS SDK + iOS SDK + Metal toolchain |
| **Homebrew dep** | `gettext` | Only external dependency |
| **macOS** | 13.1+ | Deployment target |

```bash
# Install Zig 0.14.1 (arm64 macOS)
curl -L https://ziglang.org/download/0.14.1/zig-macos-aarch64-0.14.1.tar.xz -o zig.tar.xz
tar -xf zig.tar.xz && sudo mv zig-macos-aarch64-0.14.1 /usr/local/zig-0.14.1
export PATH="/usr/local/zig-0.14.1:$PATH"

# Verify
zig version  # must print 0.14.1
sudo xcode-select --switch /Applications/Xcode.app
brew install gettext
```

### Build Commands

```bash
zig build                          # debug build → zig-out/Ghostty.app
zig build -Doptimize=ReleaseFast   # release build
zig build run                      # build + launch
open macos/Ghostty.xcodeproj       # Xcode iteration (after first zig build)
```

**Dev workflow:** Run `zig build` once to produce `GhosttyKit.xcframework`, then iterate on Swift code in Xcode.

### Architecture

**Files to modify (upstream Ghostty — 2 files):**

1. `macos/Sources/Features/Terminal/TerminalController.swift`
   - In `windowDidLoad()`: replace the line that creates `TerminalViewContainer(ghostty:surfaceView:)` with `WorkspaceViewContainer(ghostty:surfaceView:)` — same init signature, drop-in swap
   - Add toolbar installation for sidebar toggle button
   - Add Combine sync for sidebar state across tabs (so all tabs share the same sidebar selection)
   - **Note:** Ghostty's existing tab bar remains untouched — tabs and the workspace sidebar are independent. Each tab gets its own `WorkspaceViewContainer` but they share the same `WorkspaceStore`

2. `macos/Sources/App/macOS/AppDelegate.swift`
   - Create and hold `WorkspaceStore.shared` singleton (one line in `applicationDidFinishLaunching`)
   - Pass store reference when creating window controllers

**Files to create (new feature directory):**

```
macos/Sources/Features/Ghostties/
  WorkspaceView.swift              ← HStack: icon rail + NavigationSplitView(sidebar + terminal)
  WorkspaceViewContainer.swift     ← NSHostingView wrapper (sizingOptions: [.minSize])
  WorkspaceStore.swift             ← @Observable singleton: projects, sessions, templates
  WorkspaceToolbar.swift           ← SwiftUI .toolbar with sidebar toggle
  WorkspacePersistence.swift       ← JSON file in ~/Library/Application Support/Ghostties/
  IconRailView.swift               ← .onHover + animated .frame(width:) expand
  ProjectRailItem.swift            ← Icon + label per project
  SessionDetailView.swift          ← Session list for selected project
  SessionTemplate.swift            ← Per-project launch templates (Codable)
  StatusIndicator/
    StatusIndicatorView.swift      ← Animated status ring
  Models/
    Project.swift                  ← id, name, rootPath, isPinned, templates
    AgentSession.swift             ← id, templateId, projectId (persistent, Codable)
    AgentSessionRuntime.swift      ← surfaceView reference, live status, exitCode (runtime only)
```

### Key Architecture Patterns

**Layout:** Top-level `HStack` with icon rail as a width-animating leading child. The icon rail is NOT a NavigationSplitView column — it's a custom SwiftUI view that animates between 52pt (collapsed) and 220pt (expanded) on hover.

```
HStack(spacing: 0) {
  IconRailView (52pt ↔ 220pt on hover)
  NavigationSplitView(columnVisibility:) {
    SessionDetailView    ← sidebar column
  } detail: {
    TerminalView         ← Ghostty's existing terminal
  }
}
```

**State management:** `@Observable` singleton `WorkspaceStore` created in `AppDelegate`, injected via `.environment()` into each tab's `NSHostingView`. All tabs share the same store — sidebar state syncs automatically.

**Session launching:** Use Ghostty's `SurfaceConfiguration` to create new terminal surfaces with a specific `workingDirectory` and `command`. Insert into the existing `SplitTree` via `surfaceTree.inserting()` or post `Notification.ghosttyNewSplit` with config.

**Persistence:** JSON file at `~/Library/Application Support/Ghostties/workspace.json`. `Codable` models, atomic writes. `@AppStorage` only for scalar prefs (sidebar width, last project ID).

**Icon rail hover:** Pure SwiftUI `.onHover` + `.spring(response: 0.3, dampingFraction: 0.75)` animation. 100ms delay before expanding to prevent accidental triggers. Labels use `.transition(.opacity.combined(with: .move(edge: .leading)))`.

### Forked Identifiers to Change

| File | Find | Replace |
|------|------|---------|
| `macos/Ghostty.xcodeproj/project.pbxproj` | `com.mitchellh.ghostty` | `com.seansmithdesign.ghostties` |
| `macos/Ghostty.xcodeproj/project.pbxproj` | `MARKETING_VERSION = 1.2.0` | `MARKETING_VERSION = 0.1.0` |
| `macos/Ghostty-Info.plist` | `Ghostty` (display name) | `Ghostties` |
| `src/build_config.zig` | `com.mitchellh.ghostty` | `com.seansmithdesign.ghostties` |

**Note:** Search the entire codebase for `com.mitchellh.ghostty` — there may be additional occurrences in entitlements or notification identifiers.

---

## Implementation Phases

### Phase 1: Foundation (1-2 sessions)

- [x] Fork Ghostty on GitHub → `SeanSmithDesign/ghostties`
- [x] Clone fork, add upstream remote, create `upstream-main` branch
- [x] Install Zig 0.15.2, verify build from source (`zig build`)
- [x] Update bundle identifiers (ghostty → ghostties) — 11 files, all macOS + Zig identifiers
- [ ] Open Xcode project, verify Swift iteration loop works
- [x] Create empty `Ghostties/` feature directory
- [x] Create `WorkspaceViewContainer.swift` (NSView wrapper with sidebar + TerminalViewContainer)
- [x] Create `WorkspaceSidebarView.swift` — hardcoded List with project/session placeholders
- [x] Modify `TerminalController.swift` — swap contentView to WorkspaceViewContainer (one-line change in `windowDidLoad()`)
- [x] Note: no WorkspaceStore yet — Phase 1 sidebar is static/hardcoded. AppDelegate changes happen in Phase 2. Tab bar remains unchanged.
- [x] Verify: app launches with a visible (placeholder) sidebar + working terminal.

### Phase 2: Icon Rail + Project Management (2 sessions)

- [x] Create `Project` model (Codable)
- [x] Create `WorkspaceStore` (ObservableObject singleton — macOS 13 compat)
- [x] Create `WorkspacePersistence` (JSON in App Support)
- [x] Create `IconRailView` with hover-expand animation
- [x] Create `ProjectRailItem` (icon + label)
- [x] Implement "Add Project" (folder picker → pin to rail)
- [x] Implement pinned vs recent project ordering
- [x] Inject `WorkspaceStore` via @EnvironmentObject
- [ ] Verify: icon rail shows projects, hover expands, selection works

### Phase 3: Session Management (2-3 sessions)

- [x] Create `SessionTemplate` model (Codable)
- [x] Create `AgentSession` model (links to SurfaceView)
- [x] Create `SessionDetailView` (list for selected project)
- [x] Implement "New Session" with template picker
- [x] Wire template → `SurfaceConfiguration` → new Ghostty surface
- [x] Track session lifecycle (surface created → running → exited)
- [x] Implement click-to-focus (sidebar click → focus surface in terminal area)
- [x] Default templates: "Shell", "Claude Code"
- [x] Template CRUD: edit, duplicate, delete via context menu
- [x] Handle session exit: clean (Done), crash (Failed + Relaunch), user-closed (remove)
- [ ] Verify: can create sessions from templates, switch between them, relaunch failed ones

### Phase 4: Status + Polish (2 sessions)

- [ ] **Known limitation from Phase 3:** Switching sessions replaces the entire split tree. Split layouts are not preserved per-session. Fix: save/restore `SplitTree` snapshots when switching.
- [ ] Create `StatusIndicatorView` (running/idle/done states)
- [ ] Add status indicators to session list items
- [ ] Sidebar toggle toolbar button
- [ ] Keyboard shortcuts (sidebar toggle, project switching)
- [ ] Cross-tab state sync (verify multiple tabs share sidebar state)
- [ ] Handle surface close → update session status
- [ ] Persist sidebar collapsed/expanded state
- [ ] Verify: status indicators update live, keyboard nav works

### Phase 5: Migration Test (1 session)

- [ ] When Ghostty 1.3 releases (March 2026):
- [ ] `git fetch upstream && git checkout upstream-main && git merge upstream/main --ff-only`
- [ ] `git checkout main && git merge upstream-main`
- [ ] Resolve any conflicts in the 2 modified files
- [ ] Verify everything still works
- [ ] Document merge experience for future reference

---

## Success Criteria

### Functional
- [ ] App launches and shows icon rail + session panel + terminal
- [ ] Can add projects via folder picker
- [ ] Can pin/unpin projects
- [ ] Icon rail expands on hover, collapses on mouse leave
- [ ] Can create new terminal sessions from templates
- [ ] Can click a session to focus it in the terminal area
- [ ] Splits work across different projects
- [ ] Session status (running/idle/done) updates in real time
- [ ] State persists across app restarts

### Non-Functional
- [ ] Only 2 upstream files modified (TerminalController, AppDelegate)
- [ ] Terminal rendering performance identical to stock Ghostty
- [ ] App bundle builds with `zig build`

---

## Design Decisions (from spec review)

These were identified as critical gaps and resolved here:

### Session restoration on restart
**Decision: Metadata-only restoration.** On restart, sessions show as "Exited" in the sidebar with a "Relaunch" button. We do NOT auto-relaunch commands or try to restore terminal state. Projects and templates persist; live sessions don't. This keeps persistence simple (just JSON) and avoids surprising the user with auto-launched processes.

### Click-to-focus behavior
**Decision: Focus existing surface.** Clicking a session in the sidebar calls `surface.becomeFirstResponder()` to focus that terminal pane. If the session's surface isn't visible in the current split layout, it gets brought into view by replacing the currently focused pane. No new splits are created by clicking — the user creates splits explicitly via Ghostty's existing split shortcuts.

### Removing a project
**Decision: Confirm + terminate.** Removing a project shows a confirmation dialog listing active sessions. Confirming terminates all sessions and removes the project from the store. The surfaces close (triggering Ghostty's normal close flow).

### Exit status differentiation
**Decision: Three exit states.**
- Clean exit (code 0) → "Done" status, subtle indicator
- Crash/error (non-zero) → "Failed" status with red indicator + "Relaunch" button
- User closed → session removed from sidebar

### First-run empty state
**Decision: Welcome view in the detail panel** with a single "Add Project" button + folder picker. The icon rail shows a "+" icon as the only item.

### Template editing
**Decision: Phase 3 includes template CRUD.** Context menu on templates in the picker: Edit, Duplicate, Delete. Edit opens an inline form (name, command, env vars). Keep it simple — no separate preferences window.

### Sidebar toggle vs hover-expand relationship
**Decision: Independent controls.** Toolbar toggle hides/shows the entire sidebar (icon rail + detail, 0pt width). When visible, the icon rail hover-expand works normally (52pt ↔ 220pt). They don't conflict.

### Multi-window behavior
**Decision: Shared store, independent focus.** All windows see the same project list and sessions. Each window can have a different project focused in the icon rail. Sessions are global — they appear regardless of which window you're in.

### AgentSession model separation
**Decision: Split persistent vs runtime fields.**
```
AgentSession (persistent - Codable)     AgentSessionRuntime (runtime only)
  id: UUID                                surfaceView: SurfaceView?
  templateId: UUID                        status: .running/.idle/.done/.failed
  projectId: UUID                         startedAt: Date
  lastLaunchedAt: Date                    exitCode: Int32?
  lastExitCode: Int32?
```

## Design Brief

**Layers:** bringhurst + rams | **Aesthetic:** linear-mercury (adapted for SwiftUI) | **Strictness:** standard

### Craft (Bringhurst)
- **Rhythm base:** 8px grid. Spacing multiples: 4, 8, 12, 16, 24, 32
- **Type scale:** Minor third (1.2) — 11px (caption), 13px (body), 16px (headers), 19px (rare)
- **Weight palette:** `.semibold` (project names), `.medium` (emphasis), `.regular` (body)
- **Restraint:** SF Pro system font only. No custom fonts. Max 3 weights per view.

### Aesthetic (Linear Mercury → SwiftUI)
- **Color:** System semantic colors only — `.primary`, `.secondary`, `.accentColor`. 90% neutrals, 8% accent, 2% status. Status: system green (running), system red (failed), `.secondary` (idle/done).
- **Sidebar background:** `VisualEffectView` with `.sidebar` material (standard macOS vibrancy)
- **Icon rail:** `.windowBackgroundColor` or darker material for depth contrast
- **Elevation:** No custom shadows. macOS materials handle depth. Selected = accent background.
- **Motion:** Icon rail expand: `.spring(response: 0.3, dampingFraction: 0.75)`. Sidebar toggle: `0.2s` ease. Running status: subtle pulse. Hover highlight: instant. Respect `accessibilityDisplayShouldReduceMotion`.
- **Components:** Native macOS patterns — `.popover` for template picker, `.contextMenu` for CRUD, `NSAlert` for confirmations. No custom modals.
- **Anti-patterns:** No hardcoded colors, no custom fonts, no spring/bounce, no gradients, no `shadow-xl` equivalent.

### A11y (RAMS)
- **Touch targets:** 44px minimum hit area on all sidebar items
- **Focus:** Native SwiftUI focus ring. All items keyboard-navigable.
- **Accessibility labels:** Project icons, session items, status indicators all need labels (not color-only)
- **Reduced motion:** Check `accessibilityDisplayShouldReduceMotion` — if true, instant icon rail width change
- **Required states:** Sessions: running/idle/done/failed. Projects: selected/unselected/hover.

---

## Open Questions (defer to later phases)

- [ ] Session type auto-detection (detect Claude Code vs dev server)
- [ ] Icon rail session counts or status badges per project
- [ ] Ghostty 1.3 window naming integration
- [ ] Possible official add-on/plugin path (pending Mitchell conversation)
- [ ] Custom status indicator animation design
- [ ] **libghostty migration path** — Ghostty is being modularized into a family of libraries ([libghostty docs](https://libghostty.tip.ghostty.org/)). `libghostty-vt` (terminal emulator core) is in public alpha. A future Swift framework would let us embed Ghostty's terminal as a library instead of forking. Timeline is long (2027+), but worth tracking as a potential v2 architecture.

---

## References

### Ghostty Source (key files)
- `macos/Sources/Features/Terminal/TerminalController.swift` — window controller, `windowDidLoad()`
- `macos/Sources/Features/Terminal/TerminalViewContainer.swift` — current NSHostingView wrapper
- `macos/Sources/Features/Terminal/TerminalView.swift` — SwiftUI terminal view
- `macos/Sources/Ghostty/Ghostty.App.swift` — C bridge singleton
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — SurfaceConfiguration
- `macos/Sources/Features/Splits/SplitTree.swift` — split management

### Ghostree Reference (fork pattern)
- `github.com/sidequery/ghostree` — validated the 2-file modification approach
- `macos/Sources/Features/Worktrunk/` — their sidebar implementation
- `macos/Sources/Features/Terminal/TerminalWorkspaceView.swift` — NavigationSplitView wrapper

### Technical References
- SwiftUI NavigationSplitView: [useyourloaf.com](https://useyourloaf.com/blog/swiftui-split-view-configuration/)
- Three-column editors in SwiftUI: [msena.com](https://msena.com/posts/three-column-swiftui-macos/)
- NSHostingView sizing: [mjtsai.com](https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/)
- @Observable multi-window bug: [fatbobman.com](https://fatbobman.com/en/posts/the-state-specter-analyzing-a-bug-in-multi-window-swiftui-applications/)
- Ghostty build docs: [ghostty.org/docs/install/build](https://ghostty.org/docs/install/build)
- libghostty (modular library family): [libghostty.tip.ghostty.org](https://libghostty.tip.ghostty.org/index.html)
