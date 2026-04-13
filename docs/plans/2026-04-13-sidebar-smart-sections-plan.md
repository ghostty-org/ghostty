---
title: "feat: Workspace Sidebar Smart Sections"
type: feat
status: active
date: 2026-04-13
origin: docs/brainstorms/2026-04-13-sidebar-sort-requirements.md
---

# feat: Workspace Sidebar Smart Sections

## Overview

Replace the current alphabetical pinned/unpinned sidebar with a four-section auto-sorting model (Pinned / Active Now / Recent / All). Sections are membership-only sort — internal order stays stable. Anti-jump rules (2-minute grace period, freeze-on-focus, sections re-evaluate only on blur/structural events) prevent the list from thrashing under bursty agent output. The existing ghost icon absorbs the activity signal (terracotta = running, normal = recent, muted = idle). Expanded projects mirror the same three-bucket grouping for their sessions.

## Problem Frame

User juggles 4–8 active agents across 14+ projects. The current sidebar (`WorkspaceStore.sortedProjects` — pinned-alpha then unpinned-alpha) buries live work and gives no at-a-glance signal that a collapsed project has running agents. `Project.isPinned` currently defaults to `true` on every new project, so the pinned/unpinned split is effectively meaningless as a ranking signal. See origin: `docs/brainstorms/2026-04-13-sidebar-sort-requirements.md`.

## Requirements Trace

- R1. Four sections (Pinned, Active Now, Recent, All) with the membership rules in the origin doc's "Core Idea" table
- R2. A project lives in exactly one section — highest-priority match
- R3. Active Now entry is instant; exit requires a 2-minute grace period of total session silence
- R4. Sidebar does not reorder while it has keyboard focus or while a session inside it is active
- R5. Pinned projects never move, always sit at the top; `isPinned` default becomes `false`
- R6. Existing `workspace.json` files load without error; missing `lastActiveAt` degrades gracefully (treated as stale → All)
- R7. Ghost icon color binds to project activity state (terracotta / normal / muted)
- R8. Expanded projects group sessions into Active / Recent / Idle using the same rules; headers hidden when only one bucket is populated
- R9. Empty sections hide their headers entirely
- R10. Opening the app with 4+ running agents shows all active projects in the top section without expansion
- R11. Reorder animation respects `accessibilityDisplayShouldReduceMotion`

## Scope Boundaries

- No manual drag-drop ordering of projects (pin is the escape hatch)
- No user-facing sort-mode switcher
- No per-project sort modes
- The existing per-session drag-drop `sortOrder` within a project is **not** reworked; session reordering inside a bucket stays alphabetical (stable), consistent with the origin doc

### Deferred to Separate Tasks

- Grace-period configurability as a user setting — hardcoded to 2 minutes for v1 (see Open Question)
- Migration UX — resolved to Option B (one-time toast + silent unpin); handled in Unit 6 (see Open Questions)

## Context & Research

### Relevant Code and Patterns

- `macos/Sources/Features/Ghostties/Models/Project.swift` — Codable model; custom `init(from:)` uses `decodeIfPresent` for `ghostCharacter` and `defaultTemplateId`. Follow this exact pattern for `lastActiveAt`.
- `macos/Sources/Features/Ghostties/Models/AgentSession.swift` — Same `decodeIfPresent` pattern already used for `sortOrder`. `SessionIndicatorState` enum defines `.processing`, `.waiting`, `.longRunning`, `.needsAttention`, etc. — `.processing` and `.waiting` are the "active" states per the origin doc.
- `macos/Sources/Features/Ghostties/WorkspaceStore.swift` — `sortedProjects` computed property (line ~71) is the replacement target. `@Published private(set) var globalIndicatorStates: [UUID: SessionIndicatorState]` already aggregates per-session indicator state across windows — this is the authoritative source for "is any session in this project processing/waiting".
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — `startActivityTimer()` fires every 1s and pushes indicator states into `WorkspaceStore.globalIndicatorStates`. Output timestamps tracked in `lastOutputTimestamps: [UUID: ContinuousClock.Instant]`. This is where `lastActiveAt` writes hook in.
- `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` — Renders `LazyVStack(ForEach(store.sortedProjects))`. Replace with section-grouped rendering that hides empty sections.
- `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift` — Renders ghost icon and session children. Ghost color already exists as a render input; bind it to project-level activity state. Session grouping within the expanded view is a new concern.
- `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` — `State.init(from:)` uses `decodeIfPresent` for every field. `validate(_:)` scrubs referential integrity. `dateEncodingStrategy = .iso8601` already set.
- `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` — Shared tokens (sidebar width 220pt, terracotta `#C97350`, 0.2s animation). Reuse for section header styling and ghost color.
- `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift` — `transitionTo(_:)` uses `NSAnimationContext 0.2s easeInOut` and respects `accessibilityDisplayShouldReduceMotion`. Mirror for the reorder animation decision.

### Institutional Learnings

- `docs/solutions/` was checked (via user CLAUDE.md convention) — no existing entry covers sidebar sectioning or anti-jump logic. No prior art to reuse.
- From `.claude/projects/-Users-seansmith-Code-ghostties/memory/agent-workspace-sidebar.md` — Cross-cutting checklist for `WorkspaceStore` edits: persistence round-trip, backward compatibility with old JSON, `sidebarMode` mutation discipline. All three apply here.
- From the same file — `SidebarMode` decodes raw Int with safe fallback instead of throwing, so unknown values don't wipe state. Use the same defensive pattern for any new enum.

### External References

External research skipped — the codebase has strong local patterns for every touchpoint (Codable-with-decodeIfPresent migrations, `@Published` ObservableObject flow, `@MainActor` state mutation, section-style SwiftUI rendering via `LazyVStack`). No unfamiliar territory.

## Key Technical Decisions

- **Compute sections, don't store them.** Sections are derived state. Store only raw fields (`isPinned`, `lastActiveAt`, session indicator states) and compute the four-section layout on read. Keeps persistence minimal and avoids drift.
- **Snapshot pattern for freeze-on-focus.** When the sidebar gains focus (or a session in it becomes active), snapshot the current section-bucket layout into `WorkspaceStore`. Re-renders read from the snapshot instead of recomputing until a release trigger fires (blur, new session created, project added/removed, explicit refresh). The underlying activity-state ghost color keeps updating live; only the bucketing is frozen.
- **Grace period is per-project, not per-session.** Track "last moment any session in this project was processing/waiting" as an ephemeral timestamp in `WorkspaceStore`. A project is Active Now if that timestamp is within the last 2 minutes _or_ any current session indicator state is `.processing`/`.waiting`/`.longRunning`/`.needsAttention`. This prevents flapping when a single session briefly silences.
- **Clock abstraction for testability.** Inject a clock (`() -> Date` closure defaulting to `Date.init`) into the section-computation helpers so unit tests can assert grace-period behavior deterministically without `Thread.sleep`.
- **Sidebar focus detection via first-responder, not window key.** Per the origin doc open question — window `didResignKey` fires too broadly. Track first-responder changes scoped to the sidebar hosting view. Window blur is treated as implied sidebar blur.
- **Reorder animation: keep instantaneous for v1.** The existing `NSAnimationContext 0.2s easeInOut` pattern is for container mode transitions, not list reordering. SwiftUI's implicit list animation on identifier-keyed `ForEach` can cause motion. Apply `.animation(nil, value: sectionLayout)` unless reduce-motion is off _and_ reorder-on-blur explicitly ran (i.e., animate the big commit, not the incremental ghost-color changes). Respects `accessibilityDisplayShouldReduceMotion`.
- **Migration: one-time toast + silent unpin (Option B).** On first load after upgrade, flip all existing projects to `isPinned = false` and show a one-time toast explaining the new pin semantics. Track a `hasShownPinMigrationNotice` flag so the toast never re-appears. The `Project.isPinned` default value also changes to `false` for newly created projects going forward. See Unit 6 for implementation detail.

## Open Questions

### Resolved During Planning

- **Blur detection mechanism** → Use first-responder tracking scoped to the sidebar hosting view. Window `didResignKey` is a coarser fallback that also triggers a blur-reorder but isn't the primary signal. (Origin doc Q1.)
- **Reorder animation** → Keep reorders instantaneous for v1. The only animated reorder is the blur-commit, and it respects `accessibilityDisplayShouldReduceMotion`. (Origin doc Q2.)
- **Grace period configurability** → Hardcoded at 2 minutes for v1, exposed as a single named constant (`WorkspaceStore.activeGracePeriod: TimeInterval = 120`) so it's trivial to flip later. (Origin doc Q3 — recommendation accepted.)

### Deferred to Implementation

- **Exact blur/focus notification plumbing** — depends on how the sidebar's `NSHostingController` surfaces first-responder transitions. Resolve while wiring Unit 4; fall back to `NSWindow` delegate if first-responder scoping is more invasive than expected.
- **Snapshot data shape** — could be `[SectionKey: [UUID]]` or a typed struct. Pick the simpler option during Unit 2 once the computation helpers settle.
- **Empty-section header gating strategy in SwiftUI** — either conditional view or `ForEach` over non-empty sections. Decide during Unit 3 when the rendering code is in front of us.
- **Section header visual tokens and ghost color states** — the origin doc shows emoji section markers (📌 ⚡ 🕑 📚) but doesn't specify: (a) whether to render emoji vs SF Symbols vs custom glyphs, (b) section-header type ramp / spacing / color, (c) specific tokens for the "normal" and "muted" ghost colors (Unit 3 references them but they don't yet exist in `WorkspaceLayout`). Resolve during Unit 3 by adding the missing tokens to `WorkspaceLayout.swift` and matching the Paper design file's Design System artboard if it specifies them. Call this out during Unit 3 kickoff so a design pass happens before the rendering is finalized.
- **Shape of the optional `SessionCoordinator` activity test extraction** — if the activity write-through in Unit 5 can't be tested without pulling AppKit surface types into tests, extract a small protocol (e.g., `SessionActivityRecording`) that `WorkspaceStore` conforms to, and have tests verify the coordinator calls it correctly via a mock. Decide during Unit 5; skip the extraction if the existing in-process tests on `WorkspaceStore.recordActivity` give enough coverage.

### Blocking — Needs User Answer Before Implementation

- **Migration UX** (origin doc Q4) → **RESOLVED: Option B — one-time toast explaining the new pin semantics.** On first app launch after upgrade, flip all existing projects to `isPinned = false` and show a one-time toast/banner: _"Pin now means 'always on top.' Re-pin the projects you want above the smart sections."_ (copy can be wordsmithed). Track a one-time-shown flag (`hasShownPinMigrationNotice: Bool` in user defaults or workspace persistence) so the toast never re-appears. Intent: explain the new meaning so users aren't confused about where their pins went.

## High-Level Technical Design

> _This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce._

**Section computation data flow (conceptual):**

```
Inputs (live):                          Inputs (ephemeral):
  projects: [Project]                     globalIndicatorStates (per-session)
    .isPinned                             lastActiveAt (per-project, per-session)
    .lastActiveAt                         activeSinceTimestamps (grace-period tracker)
  sessions: [AgentSession]
                      │
                      ▼
        computeSections(now, frozen?)
                      │
         ┌────────────┼────────────┬─────────────┐
         ▼            ▼            ▼             ▼
      Pinned     Active Now      Recent          All
    isPinned    any session in   lastActiveAt    everything else
    (stable)    processing/      within 24h      (alpha)
                waiting OR       (chronological)
                grace-period
                active
                (alpha)
```

**Freeze-on-focus state machine (conceptual):**

```
              sidebar gains focus / session activates
         ┌──────────────────────────────────────────────┐
         ▼                                              │
   ┌─────────┐      blur | new session | project add/   │
   │ FROZEN  │ ──── remove | explicit refresh ────────▶ │
   │ (uses   │                                          │
   │ snapshot)│                                         ┌─────┐
   └─────────┘                                          │ LIVE│
         ▲                                              └─────┘
         └──────────────────────────────────────────────────┘
              sidebar gains focus / session activates
```

- While FROZEN: ghost color, badges, session-level state all keep updating. Only the `[SectionKey: [UUID]]` bucket layout is pinned.
- While LIVE: every mutation (indicator state push, project change, session add) re-runs `computeSections`.

## Implementation Units

- [x] **Unit 1: Data model additions and persistence round-trip**

**Goal:** Add `lastActiveAt: Date?` to both `Project` and `AgentSession`. Change `Project.isPinned` memberwise-init default from `true` to `false`. Keep existing `workspace.json` files loading cleanly.

**Requirements:** R5, R6

**Dependencies:** None

**Files:**

- Modify: `macos/Sources/Features/Ghostties/Models/Project.swift`
- Modify: `macos/Sources/Features/Ghostties/Models/AgentSession.swift`
- Modify: `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` (only if a new `CodingKeys` entry is needed; the `decodeIfPresent` pattern is already in the models themselves)
- Test: `macos/Tests/Workspace/WorkspacePersistenceTests.swift`
- Test: `macos/Tests/Workspace/AgentSessionTests.swift` (existing; extend)

**Approach:**

- Add `var lastActiveAt: Date?` to `Project` with memberwise default `nil`; decode via `decodeIfPresent` mirroring the `ghostCharacter` pattern already in the file.
- Add `var lastActiveAt: Date?` to `AgentSession` with the same pattern (mirrors `sortOrder`).
- Flip `Project.isPinned` default from `true` to `false` in the memberwise init. The call site in `WorkspaceStore.addProject(at:)` currently passes `isPinned: true` explicitly — leave that intact so "add project" still pins by user action; only the default for decoded/other construction changes.
- `CodingKeys` enums auto-synthesize; only add explicit cases if the decoder init enumerates them.

**Execution note:** Start with a failing persistence round-trip test for both new fields before touching the models.

**Patterns to follow:**

- `Project.init(from:)` `decodeIfPresent` pattern for `ghostCharacter` and `defaultTemplateId`
- `AgentSession.init(from:)` `decodeIfPresent` pattern for `sortOrder`
- `WorkspacePersistenceTests.decodingOldJsonWithoutNewFieldsUsesDefaults` as the template for backward-compat tests

**Test scenarios:**

- Happy path: encoding a `Project` with `lastActiveAt = Date(...)` and decoding it returns the same timestamp (ISO-8601 round-trip) → equal
- Happy path: encoding an `AgentSession` with `lastActiveAt = Date(...)` round-trips cleanly → equal
- Edge case: decoding a legacy `workspace.json` payload (no `lastActiveAt` key anywhere) → every project and session has `lastActiveAt == nil` and no error is thrown
- Edge case: decoding a legacy payload with `isPinned: true` → project still loads with `isPinned == true` (pre-upgrade pins are preserved)
- Edge case: memberwise-init of `Project` without `isPinned` argument → `isPinned == false` (default changed)
- Edge case: memberwise-init of `AgentSession` without `lastActiveAt` argument → `lastActiveAt == nil`
- Error path: decoding a payload where `lastActiveAt` is a malformed string → decoding fails with `DecodingError` (not silent `nil`) — verify we don't accidentally swallow type errors by overusing `try?`

**Verification:**

- `macos/Tests/Workspace/WorkspacePersistenceTests.swift` tests all pass under Cmd+U
- Launching the app against an existing `~/Library/Application Support/Ghostties/workspace.json` still shows all existing projects with their current pin state

---

- [x] **Unit 2: Section computation in WorkspaceStore**

**Goal:** Replace `WorkspaceStore.sortedProjects` (pinned-alpha + unpinned-alpha) with a four-section computed layout. Add the grace-period tracker and the freeze snapshot. Add a matching helper for expanded-project session grouping.

**Requirements:** R1, R2, R3, R5, R6, R8

**Dependencies:** Unit 1

**Files:**

- Modify: `macos/Sources/Features/Ghostties/WorkspaceStore.swift`
- Create: `macos/Tests/Workspace/WorkspaceStoreSectionsTests.swift`

**Approach:**

- Introduce a `SidebarSection` enum (`.pinned`, `.activeNow`, `.recent`, `.all`) and a `SectionedProjects` return type — either `[(SidebarSection, [Project])]` preserving order, or a typed struct. Pick simpler at impl time.
- Replace `sortedProjects` with `sectionedProjects: SectionedProjects` (keep `sortedProjects` as a deprecated flat view during migration, or rename all call sites in Unit 3).
- Add a private `activeSinceTimestamps: [UUID: Date]` (project id → last moment any session was `.processing`/`.waiting`/`.longRunning`/`.needsAttention`). This is the grace-period tracker. Updated by a new method `updateProjectActivityFromIndicatorStates()` called whenever `globalIndicatorStates` changes or an activity timer tick fires.
- Add a private `frozenSnapshot: SectionedProjects?`. When non-nil, `sectionedProjects` returns the snapshot. Expose `freezeSnapshot()` and `releaseSnapshot()` methods for the view layer to call on focus/blur.
- Add a public constant `static let activeGracePeriod: TimeInterval = 120`.
- Add `sessionGroups(forProject:)` returning `[(SessionBucket, [AgentSession])]` where `SessionBucket` is `.active`/`.recent`/`.idle`. Reuses the same rules but at session scope.
- Inject `now: () -> Date = Date.init` into the computation helpers for test determinism.

**Execution note:** Implement section-membership unit tests first (happy paths + edge cases), then the grace-period logic, then the snapshot freeze/release. Test-first keeps anti-jump behavior from regressing silently.

**Patterns to follow:**

- `WorkspaceStore.sortedProjects` original for alphabetical sort style (`localizedCaseInsensitiveCompare`)
- `WorkspaceStore.sessions(for:)` for the sort-with-fallback pattern
- `SidebarMode` raw-value decoding defensiveness from `WorkspacePersistence`

**Test scenarios:**

- Happy path: one project with `isPinned = true` → appears in `.pinned`; not duplicated elsewhere
- Happy path: project with one session currently `.processing` → appears in `.activeNow`
- Happy path: project with no active sessions and `lastActiveAt` within 24h → `.recent`
- Happy path: project with no sessions and `lastActiveAt == nil` → `.all`
- Happy path: sessions inside an Active Now project group into `.active` / `.recent` / `.idle` buckets per the session-scoped rules
- Edge case: project in Active Now that just went silent → remains in `.activeNow` until grace period expires (123s elapsed with injected clock → moves to `.recent` or `.all`)
- Edge case: pinned project with no activity → still in `.pinned` (pin overrides state)
- Edge case: empty project list → returns an empty `SectionedProjects` with no sections
- Edge case: all 14 projects active simultaneously → all in `.activeNow`, other sections empty
- Edge case: `lastActiveAt` exactly at the 24h boundary → deterministic classification (define boundary as inclusive or exclusive; test asserts it)
- Edge case: session in `.needsAttention` state → counts toward "active" for project-level bucketing
- Integration: calling `freezeSnapshot()` then mutating `globalIndicatorStates` → `sectionedProjects` still returns the pre-freeze layout; ghost color via a separate accessor (simulated by reading `globalIndicatorStates` directly) has already changed
- Integration: calling `releaseSnapshot()` after a freeze → next read of `sectionedProjects` returns the freshly-computed layout reflecting the mutations that happened during the freeze
- Edge case: project transitions freeze → new session created during freeze → release triggered by "new session created" → new project appears in the correct section
- Error path: grace-period tracker entry for a project whose ID no longer exists in `projects` → computation ignores it silently (no crash)

**Verification:**

- All new unit tests pass
- Freezing the snapshot, mutating activity, releasing, and reading the layout produces the expected final order in every test case
- Hot path perf sanity: `sectionedProjects` computation for 50 projects × 200 sessions returns in well under 16ms (rough XCTest measure block)

---

- [x] **Unit 3: Sidebar rendering — sections, ghost color, expanded session groups**

**Goal:** Update the sidebar to render the four sections with headers, hide empty sections, bind each project's ghost icon color to its activity state (terracotta / normal / muted), and render session group headers inside expanded projects.

**Requirements:** R1, R2, R7, R8, R9, R10

**Dependencies:** Unit 1, Unit 2

**Files:**

- Modify: `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift`
- Modify: `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift`
- Modify: `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` (if new section-header tokens are needed)

**Approach:**

- Replace the single `LazyVStack(ForEach(store.sortedProjects))` with iteration over `store.sectionedProjects`: for each non-empty section, render a small header (section icon + label in the style specified by the origin doc) followed by that section's projects. Hide the header entirely when the section is empty.
- Add a `projectActivityColor(for:)` helper (either on `WorkspaceStore` or the view) that returns terracotta (`WorkspaceLayout.waitingTerracotta` / `#C97350`) when any session indicator is in an active state, a "normal" foreground color when `lastActiveAt` is within 24h, and a muted color otherwise. Pass this into `GhostCharacterView` via the existing color parameter.
- Inside `ProjectDisclosureRow`, when expanded, render `store.sessionGroups(forProject:)` instead of the flat session list. Render a small group header only when more than one bucket is populated. When only one bucket has sessions, render the flat list (no headers) to match the origin doc rule.
- Do not animate the section-bucketing change directly; let `freezeSnapshot()` gate re-renders so the list isn't visually thrashing. Use `.animation(.default, value: sectionSignature)` only on the release-triggered commit, guarded by `!accessibilityDisplayShouldReduceMotion`.
- Keep `selectedProjectId`, `expandedProjectIds`, and keyboard-nav behavior working across the new structure. `selectAdjacentProject(offset:)` should walk the flattened section order (same as current visual order).

**Execution note:** Snapshot-test the rendering with a stubbed `WorkspaceStore` returning each of the edge-case layouts from Unit 2.

**Patterns to follow:**

- `WorkspaceSidebarView.emptyState` for conditional view rendering
- `WorkspaceLayout` color tokens — do not hardcode hex in the view layer
- `GhostCharacterView` existing color-parameter API
- `ProjectDisclosureRow` existing disclosure/chevron + drag-drop session list

**Test scenarios:**

- Happy path: store with projects in all four sections → view renders four section headers in the specified order, each with the right children
- Happy path: store with only Active Now and All sections populated → only those two headers render; Pinned and Recent headers are absent
- Happy path: project with one active session and one idle session, expanded → renders two group headers ("Active", "Idle") and the two sessions under them
- Happy path: project with only idle sessions, expanded → renders a flat session list with no group headers
- Edge case: empty store → empty-state view renders (existing behavior preserved)
- Edge case: reduce-motion on → no animation modifier applied on the section commit
- Edge case: ghost color — project with a `.processing` session → ghost renders in terracotta; no active sessions but recent activity → normal color; nothing recent → muted color
- Integration: keyboard nav (`workspaceSelectNextProject` notification) with sectioned layout → selection walks the full flattened list in visual order, skipping no projects
- Integration: clicking a project in a section updates `selectedProjectId` and triggers `coordinator.focusLastSession(forProject:)` as it does today
- Edge case: section with zero projects does not render an empty header, empty spacer, or phantom divider

**Verification:**

- Manual visual check via Xcode preview and a Cmd+U build run
- Sidebar shows correct headers and counts given a test `WorkspaceStore` seeded with representative data
- Accessibility: VoiceOver announces each section header followed by its projects; empty sections are not announced at all

---

- [x] **Unit 4: Freeze-on-focus reorder gating and blur detection**

**Goal:** Wire first-responder and activity signals to `WorkspaceStore.freezeSnapshot()` / `releaseSnapshot()` so the sidebar stops reordering while the user is working in it, and commits the new layout on blur, new-session-created, project-added/removed, or explicit refresh.

**Requirements:** R3, R4, R10, R11

**Dependencies:** Unit 2, Unit 3

**Files:**

- Modify: `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` (focus detection plumbing)
- Modify: `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift` (window blur bridge, if needed)
- Modify: `macos/Sources/Features/Ghostties/SessionCoordinator.swift` (emit release triggers on session creation, project removal)
- Modify: `macos/Sources/Features/Ghostties/WorkspaceStore.swift` (ensure `addProject`, `removeProject`, `addSession` call `releaseSnapshot()` after mutation)
- Create: `macos/Tests/Workspace/WorkspaceStoreFreezeTests.swift`

**Approach:**

- Track sidebar first-responder state via an `NSHostingController` child-view observer or a `.focused($isSidebarFocused)` SwiftUI binding. When the sidebar gains first-responder, call `store.freezeSnapshot()`. When it loses first-responder (or the window resigns key), call `store.releaseSnapshot()`.
- Also treat "a session inside the sidebar's project is the active session _and_ the user is interacting with it" as a freeze condition — reuse `SessionCoordinator.activeSessionId` as a proxy (freeze while that session's project is selected and the window is key).
- Explicit release triggers:
  - `WorkspaceStore.addProject(at:)` calls `releaseSnapshot()` after append
  - `WorkspaceStore.removeProject(id:)` calls `releaseSnapshot()` after removal
  - `WorkspaceStore.addSession(...)` calls `releaseSnapshot()` after append
  - Window `didResignKey` notification observer in the view triggers `releaseSnapshot()`
- Reorder commit: immediately after `releaseSnapshot()`, the view's next render reads fresh `sectionedProjects` and produces the new layout. Animate only this commit when reduce-motion is off.
- Fallback: if first-responder scoping proves fragile, fall back to window-level key-state detection via `NSWindowDelegate`. Document the fallback in code.

**Execution note:** Write freeze-release unit tests first against a pure `WorkspaceStore` (no view layer), then wire the view plumbing.

**Patterns to follow:**

- `WorkspaceViewContainer.transitionTo(_:)` — reduce-motion check pattern via `accessibilityDisplayShouldReduceMotion`
- Existing `NotificationCenter` patterns in `SessionCoordinator` (`observeLifecycle`, `observeProjectRemoval`) for any new notifications
- `WorkspaceStore.sidebarMode` private-setter discipline — expose mutation only through a dedicated method

**Test scenarios:**

- Happy path: freeze, mutate `globalIndicatorStates` for a project (promoting it to Active Now), release → next `sectionedProjects` read reflects the promotion
- Happy path: freeze, leave for longer than the grace period, release → demoted projects appear in the correct section
- Edge case: freeze while frozen (nested freeze) → second call is a no-op and does not clobber the original snapshot
- Edge case: release while not frozen → no-op, no crash
- Integration: `addProject(at:)` while frozen → snapshot is released automatically and the new project appears in its correct section
- Integration: `removeProject(id:)` while frozen → snapshot released; removed project disappears; remaining projects re-bucket correctly
- Integration: `addSession(...)` while frozen → snapshot released; parent project may move to Active Now once the session produces output (not immediately on mere creation — the session starts idle until output arrives)
- Error path: release triggered with no change since freeze → layout is identical, no spurious re-render (compare signatures)
- Integration (view): sidebar loses first-responder → `releaseSnapshot()` is invoked exactly once
- Integration (view): window resigns key while sidebar is not first-responder → `releaseSnapshot()` still runs

**Verification:**

- 10-minute soak: launch with 4+ running agents producing bursty output, click into the sidebar, keep focus there — sidebar position of focused project does not change. Blur the window → if state changed enough to warrant a reorder, the next focus shows the new order.
- All freeze/release unit tests pass under Cmd+U
- No retain-cycle warnings in Instruments around the new focus observers

---

- [x] **Unit 5: Activity write-throughs and hookup to SessionCoordinator**

**Goal:** Populate `Project.lastActiveAt` and `AgentSession.lastActiveAt` on the real triggers (output, focus, state change away from idle, session creation) and push per-project activity-since timestamps into the `WorkspaceStore` grace-period tracker.

**Requirements:** R3, R7, R10

**Dependencies:** Unit 1, Unit 2

**Files:**

- Modify: `macos/Sources/Features/Ghostties/SessionCoordinator.swift`
- Modify: `macos/Sources/Features/Ghostties/WorkspaceStore.swift` (add a public `recordActivity(sessionId:projectId:)` method that writes both timestamps and updates the grace-period tracker)
- Modify: `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift` (focus touches call `recordActivity`)
- Test: `macos/Tests/Workspace/WorkspaceStoreSectionsTests.swift` (extend)
- Create: `macos/Tests/Workspace/SessionCoordinatorActivityTests.swift` (only if testable in isolation — SessionCoordinator owns AppKit types, so this may need a thin extraction)

**Approach:**

- In `subscribeToOutput`'s `.sink` (where `lastOutputTimestamps[sessionId] = .now` is set), also call `WorkspaceStore.shared.recordActivity(sessionId:projectId:)`. This hits both `session.lastActiveAt` and `project.lastActiveAt` and refreshes the project's entry in `activeSinceTimestamps` whenever the session's current indicator state qualifies as "active".
- In `focusSession(id:)`, also call `recordActivity` after `activeSessionId` is updated — focusing counts as touch.
- In `createSession(...)`, set `lastActiveAt` for both the session and its project right after the session is added to the store.
- In the 1-second `startActivityTimer` tick, after updating `globalIndicatorStates`, run `WorkspaceStore.shared.updateProjectActivityFromIndicatorStates()` which scans all running sessions, and for any session in an active indicator state, refreshes the project's `activeSinceTimestamps[projectId] = now`. This is the grace-period feed.
- Persist `lastActiveAt` writes through the existing debounced `persist()` in `WorkspaceStore` — no new disk-write plumbing required. The 100ms debounce is adequate; bursty output writes coalesce.
- Ensure `recordActivity` does NOT call `releaseSnapshot()` — activity while frozen must keep feeding the timestamp tracker so that on release the layout is correct, but must not trigger an immediate reorder. This is the core anti-jump rule.

**Execution note:** Before wiring anything, extend the Unit 2 test helpers to assert that `recordActivity(sessionId:projectId:)` updates both the project's `lastActiveAt` and the grace-period tracker, and that it is a no-op on snapshot release (only the snapshot release itself reorders).

**Patterns to follow:**

- `SessionCoordinator.subscribeToOutput` — Combine subscription shape
- `WorkspaceStore.updateSessionStatus(id:status:)` — simple mutation-through-method pattern

**Test scenarios:**

- Happy path: `recordActivity(sessionId:projectId:)` updates both `project.lastActiveAt` and `session.lastActiveAt` to the injected clock's `now`
- Happy path: `recordActivity` on a session whose indicator state is `.processing` also updates `activeSinceTimestamps[projectId]`
- Happy path: `recordActivity` on a session whose indicator state is `.idle` updates `lastActiveAt` but does NOT touch `activeSinceTimestamps` (idle is not "active")
- Edge case: `recordActivity` for a session whose project doesn't exist (stale id) → no crash, no write
- Edge case: repeated `recordActivity` within the same millisecond → `lastActiveAt` advances monotonically (or at least never goes backward)
- Integration: during a snapshot freeze, `recordActivity` updates fields but `sectionedProjects` return still matches the snapshot → freeze honored
- Integration: session produces output → `subscribeToOutput` sink fires → project's `lastActiveAt` becomes now → on next `sectionedProjects` read (after release), project moves to `.recent` or `.activeNow` as appropriate
- Integration: `focusSession(id:)` on a previously idle project → project's `lastActiveAt` updates → project is no longer in `.all` after release (moves to `.recent`)

**Verification:**

- Launching the app, creating a session, producing output, waiting — `workspace.json` on disk contains updated `lastActiveAt` values for both the session and its project
- All Unit 2 + Unit 5 tests pass under Cmd+U
- The 10-minute soak test from Unit 4 also verifies grace-period behavior (project stays in Active Now for ~2 minutes after its session goes silent, then demotes on next blur-reorder)

---

- [x] **Unit 6: Migration polish and empty-section hiding QA**

**Goal:** Execute the chosen migration path (Option B — flip all existing pins to `false` and show a one-time toast), confirm empty-section hiding in every edge case, and verify reduce-motion behavior end-to-end.

**Requirements:** R5, R9, R11

**Dependencies:** Unit 1, Unit 3, Unit 4

**Files:**

- Modify: `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` (add one-time migration flipping all `isPinned` to `false` and set `hasShownPinMigrationNotice` flag)
- Modify: `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` (render the one-time toast/banner and dismiss wiring)
- Test: `macos/Tests/Workspace/WorkspacePersistenceTests.swift` (migration round-trip + one-time flag)

**Approach:**

- **Migration path locked in: Option B — one-time toast + silent unpin of existing projects.** See Open Questions section for the resolution record.
- Add a one-time flag `hasShownPinMigrationNotice: Bool` to the persistence `State` (or user defaults — pick the lower-friction storage during Unit 6 kickoff; persistence `State` keeps it self-contained with the workspace file, user defaults survives workspace resets). Default to `false` for legacy files.
- On first load after upgrade (flag is `false`): iterate all projects and set `isPinned = false`, set `hasShownPinMigrationNotice = true`, persist.
- In `WorkspaceSidebarView`, render a dismissible toast/banner when the flag transitions or is observed `true`-pending-dismiss — copy: _"Pin now means 'always on top.' Re-pin the projects you want above the smart sections."_ (final wording open to wordsmithing; intent is to explain the new meaning so users aren't confused about where their pins went). Dismissal writes the persisted dismissal state so the toast never re-appears.
- The `isPinned` memberwise-init default change from Unit 1 stands.
- Empty-section QA: walk through every edge case from the origin doc (all active, only pinned, only long-tail, brand-new project) and visually verify no phantom headers or dividers render.
- Reduce-motion QA: toggle `System Settings → Accessibility → Display → Reduce motion` and confirm no reorder animation fires; section content still updates on release.

**Execution note:** This unit is a decision + polish pass. Ship migration + toast together so users see the explanation the first time their pins disappear.

**Patterns to follow:**

- `WorkspacePersistence.State.init(from:)` + `validate(_:)` for the migration-marker plumbing
- Existing dismissible-banner patterns in the app (check `ProjectSettingsView.swift` and similar for popover/banner style)

**Test scenarios:**

- Happy path: load a legacy `workspace.json` with `isPinned: true` on every project and `hasShownPinMigrationNotice` absent → after migration, every `isPinned` is `false` and the flag is `true`
- Happy path: second load after migration → flag already `true`, no re-migration, pins chosen by the user in between are preserved
- Happy path: first-run-after-upgrade triggers the toast exactly once; dismissing persists and the toast does not re-appear on relaunch
- Edge case: corrupt/missing migration flag → treat as not-yet-migrated (safe side; migration is idempotent because the flag flips to `true` immediately on first run)
- Edge case: user re-pins a project after migration → flag stays `true`, no re-migration

**Verification:**

- Migration tests pass
- Visual QA against the edge-case checklist in the origin doc passes
- Reduce-motion System Settings toggle makes reorder commits instantaneous
- Toast appears exactly once on first post-upgrade launch and never again after dismissal

## System-Wide Impact

- **Interaction graph:** The activity-write path now runs on every surface-output `.sink` emission (bursty). The debounced 100ms `persist()` already coalesces these. Verify no additional disk-write pressure.
- **Error propagation:** `recordActivity` for a stale session id must not crash — return silently. Tested in Unit 5.
- **State lifecycle risks:**
  - `frozenSnapshot` must clear when the `WorkspaceStore` reloads state (e.g., `init()` from persistence). Ensure `init` does not inherit a stale snapshot across app restarts (it won't, since it's non-persisted, but the test should pin this).
  - `activeSinceTimestamps` is ephemeral and not persisted. On app relaunch every project starts without a grace-period entry — correct behavior (projects with no running sessions naturally fall out of Active Now).
  - Session removal (`removeSession`) must also drop any corresponding grace-period entry if it was the only active session.
  - **Snapshot staleness for in-place project edits:** the frozen snapshot captures `[Project]` value-type copies, so while frozen, edits to a project's name, `ghostCharacter`, or `defaultTemplateId` won't propagate into the rendered rows until the snapshot is released. Mitigation: have the snapshot store only the ordered `[UUID]` bucket layout, not full `Project` copies. The view then looks up live `Project` values by ID when rendering, so names and ghosts stay fresh while only the ordering is frozen. Confirm this shape during Unit 2 when the snapshot type is finalized.
- **API surface parity:** `sortedProjects` is consumed in at least `WorkspaceSidebarView`, `addProjectViaFolderPicker` (for the return lookup), and possibly test helpers. Either keep it as a deprecated flat accessor that concatenates sections, or rename all call sites. Pick during Unit 3.
- **Integration coverage:** Freeze-on-focus interaction with add/remove project (via `@MainActor` notifications) — covered in Unit 4 integration tests. Activity write through Combine sink under `@MainActor` isolation — covered in Unit 5.
- **Unchanged invariants:**
  - `AgentSession.sortOrder` and the per-session drag-drop reordering inside a project remain untouched
  - `WorkspaceStore.sidebarMode` and the three-state sidebar (pinned / closed / overlay) are untouched
  - `globalStatuses`, `globalIndicatorStates`, session-lifecycle notifications — untouched
  - Existing Codable round-trip for all other fields — untouched; only additive changes
- **Cross-cutting checklist** (from `agent-workspace-sidebar.md`):
  - [ ] `WorkspaceStore` mutations: persistence round-trip verified, backward compat tests added, `sidebarMode` private-set discipline preserved (no touch)
  - [ ] `SessionCoordinator`: notification observer cleanup in `deinit` still works after adding activity write-throughs; no new strong reference cycles from the activity timer's block
  - [ ] `WorkspaceViewContainer`: traffic lights, shadow path, tracking areas, safeAreaInsets override — all untouched by this plan (verify no regressions if focus plumbing routes through the container)

## Risks & Dependencies

| Risk                                                                                                           | Mitigation                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| First-responder detection inside `NSHostingController` proves unreliable                                       | Fallback to window-level `NSWindowDelegate` key-state; documented in Unit 4. Treat a live agent in the window as an implicit sidebar-focus signal so freeze still runs in the common case.                           |
| Grace-period tracker grows unbounded over long sessions                                                        | Entries keyed by project id; bounded by number of projects (≤ 20 in realistic usage). Cleaned in `removeProject`. Not a real risk; flagged for completeness.                                                         |
| Users with 14+ legacy "pinned" projects get a chaotic list on first load (option 1 migration)                  | Migration UX decision gated on Open Question. If option 1 is chosen, the brief moment of "all unpinned" is the intended new equilibrium.                                                                             |
| SwiftUI implicit animation on `ForEach` causes motion during bursty output despite `.animation(nil)`           | Freeze-on-focus is the primary defense. Ghost-color changes don't change ordering and don't animate. If residual animation appears, guard the `ForEach` with `.transaction { $0.animation = nil }` — noted for impl. |
| `lastActiveAt` write bursts under heavy output (every surface emission)                                        | Debounced persistence already in place; writes are to in-memory state, only disk is debounced. Profile if it shows up in traces.                                                                                     |
| Snapshot not released on edge-case triggers (e.g., project reordered indirectly) causes visual "stuck" sidebar | Belt-and-braces: the window-level `didResignKey` release covers all cases; test suite exercises add/remove/blur explicitly.                                                                                          |

## Documentation / Operational Notes

- Update `.claude/projects/-Users-seansmith-Code-ghostties/memory/agent-workspace-sidebar.md` — the "State Machine" section stays; add a new "Sidebar Sort" subsection describing the four-section model, grace period, and freeze-on-focus.
- On completion, run `/ce:compound` to document the anti-jump pattern in `docs/solutions/` (freeze-snapshot + grace-period is reusable).

## Sources & References

- **Origin document:** `docs/brainstorms/2026-04-13-sidebar-sort-requirements.md`
- Related code:
  - `macos/Sources/Features/Ghostties/Models/Project.swift`
  - `macos/Sources/Features/Ghostties/Models/AgentSession.swift`
  - `macos/Sources/Features/Ghostties/WorkspaceStore.swift`
  - `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift`
  - `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift`
  - `macos/Sources/Features/Ghostties/SessionCoordinator.swift`
  - `macos/Sources/Features/Ghostties/WorkspacePersistence.swift`
  - `macos/Sources/Features/Ghostties/WorkspaceLayout.swift`
  - `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift`
- Related memory: `.claude/projects/-Users-seansmith-Code-ghostties/memory/agent-workspace-sidebar.md` (cross-cutting checklist)
- Existing tests: `macos/Tests/Workspace/WorkspacePersistenceTests.swift`, `macos/Tests/Workspace/AgentSessionTests.swift`

## Additional Risks and Dependencies Beyond the Origin Doc

These were not surfaced in the requirements document but emerged from local research. Calling them out separately so the user can weigh them before implementation starts.

1. **`sortedProjects` has implicit callers beyond the sidebar view.** `WorkspaceStore.addProjectViaFolderPicker()` uses it to look up the newly-added project for its return value. Any replacement must either keep `sortedProjects` as a flattened accessor or update every call site. Grep for all callers during Unit 3.

2. **`@MainActor` isolation on the activity-write path.** `WorkspaceStore` is `@MainActor`. `SessionCoordinator.subscribeToOutput`'s `.sink` closure currently writes to `lastOutputTimestamps` on whatever actor Combine delivers to. `recordActivity` calls from that sink need to hop to `@MainActor`; verify no priority inversion or reentrancy issue under heavy bursty output.

3. **The per-session indicator-state timer runs at 1Hz.** The grace-period check is therefore also at 1Hz resolution, which is fine for a 2-minute window but worth noting: a project that flips active→silent at tick `t` won't demote until release and the computation uses the 2-minute boundary at release time. No user-visible bug, but worth testing explicitly.

4. **Reduce-motion is a system setting, not a per-window state.** The origin doc asks to respect `accessibilityDisplayShouldReduceMotion`; current code uses it in `WorkspaceViewContainer.transitionTo`. Make sure the sidebar reorder logic reads the same flag at commit time, not at view-mount time (user may toggle it between app launches).

5. **Snapshot memory semantics.** The frozen snapshot stores `[Project]` references. `Project` is a value type (`struct`), so the snapshot is a copy — mutations to `projects` during the freeze can diverge from the snapshot without corrupting it. Good. But snapshot restoration must NOT persist the snapshot to disk (the snapshot is ephemeral); confirm `persist()` reads from `projects`, not from the snapshot. It already does.

6. **Per-project `lastActiveAt` creates a silent disk-write multiplier.** Every session output emission also updates the parent project's timestamp. The debounced persistence coalesces, but this still means project records are re-serialized constantly. Consider only persisting `lastActiveAt` on a coarser cadence (e.g., once per minute) or only on session state transitions — worth thinking about during Unit 5 if traces show it.

7. **`agent-workspace-sidebar.md` is 22 days old** per the memory system warning. The file inventory and constants may have drifted. Verify each touchpoint file still matches the description before blindly following the cross-cutting checklist — especially line-number citations in the origin doc (e.g., the `Project.swift:22` and `WorkspaceStore.swift:72` references).
