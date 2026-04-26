---
title: "feat: Row-click behavior v0 — lane-aware dispatch + composer + orphan triage + Graveyard expansion"
type: feat
status: active
date: 2026-04-25
origin: docs/brainstorms/2026-04-25-row-click-behavior-requirements.md
---

# feat: Row-click behavior v0 — lane-aware dispatch + composer + orphan triage + Graveyard expansion

## Overview

Reshapes the task-first sidebar's row-click model around a single intent — **"I'm picking this up and starting now"** — replacing today's overloaded behavior (open `.md` externally + silent-no-op terminal spawn). Click is dispatched lane-aware via a small router to five named handlers; new column-1 UI surfaces (orphan triage card, Graveyard inline expansion, new-task composer) cover the cases the click no longer overloads. Frontmatter gains a `priority` field and Inbox sorts by priority. MCP gains `task.create` and `task.set_project` to keep three-surface coherence honest where it matters. Note `.md` access remains, but only via the `📝` chip and `⌘O` — never on a row click.

The work touches all three surfaces (macOS app + `gt` CLI + Ghostties MCP server), though the bulk is macOS SwiftUI. The macOS `TaskStore` becomes write-capable for the first time by linking the existing `GhosttiesCore` Swift package into the app target (the `XCLocalSwiftPackageReference` is already in the pbxproj per ORCHESTRATOR.md).

---

## Problem Frame

Today's row-click does two unrelated things — opens the task's `.md` in whatever app the OS hands `.md` to, AND tries to spawn-or-focus a terminal session at the task's project path. The terminal half silently no-ops when the task lacks a resolvable `project-path` (the default for Linear-imported tasks), so the typical first experience is: external editor steals focus, no terminal appears, Sean has to manually edit frontmatter before clicking again does anything.

The sidebar is a queue of work, not references to browse. The first verb a row should answer to is "start this," not "open this in some other app." This v0 also enforces the column model: column 1 (sidebar) navigates → column 2 (terminal canvas) executes → column 3 (browser) is auxiliary, untouched in v0. Column-1-internal behaviors (inline expand, triage card, composer) handle anything that isn't a terminal session.

(see origin: [docs/brainstorms/2026-04-25-row-click-behavior-requirements.md](../brainstorms/2026-04-25-row-click-behavior-requirements.md))

---

## Requirements Trace

- R1. Lane-aware dispatch via `handleRowClick(task)` router → five named handlers (`startInboxTask`, `triageOrphanTask`, `focusRunningTask`, `focusNeedsYouTask`, `expandGraveyardTask`).
- R2. Inbox-with-project click writes `status: running`, spawns/focuses terminal, routes column 2.
- R3. Lane migration is file-watcher-driven, not direct UI mutation.
- R4. Orphan Inbox click opens inline triage card (project picker + optional template + optional title edit).
- R5. Confirming triage writes `project-path` (and optional `template`) to frontmatter, then continues as F1.
- R6. Running click is idempotent: route column 2 + focus cursor; no respawn, no status flip.
- R7. Needs-you click identical to R6; no auto-scroll. Lane membership = `task.status == .needsYou` from frontmatter, not the live heuristic.
- R8. Graveyard click opens net-new per-row inline expansion in column 1 (animated chevron + frontmatter chips + first ~8 lines body). Column 2 not touched.
- R9. Three triggers open the same composer: `[+ Start]` button, empty Inbox area click, `⌘N`.
- R10. Composer is inline in column 1; fields = title (required), project (required), template (optional).
- R11. Confirming composer creates `.md` with `status: running`; watcher drives row appearance + spawn.
- R12. Three-surface coherence is **design intent, not blocking rule**. Per-handler mappings: `startInboxTask` → MCP `update_task_status` (exists); `triageOrphanTask` → `task.set_project` (new); composer → MCP `task.create` (new) + existing `gt new`. Focus + Graveyard expand are pure UI, exempt.
- R13. `.md` opens externally only via `📝` chip or `⌘O`. Never on row click. Never rendered in-app in v0.
- R14. Keyboard parity in v0: `⌘N`, `⌘O`, `Return`. Row navigation (`j`/`k`) deferred.
- R15. Frontmatter `priority: high|medium|low|none` (default `none`); Inbox sort = `priority desc, created desc`; `linear-sync` preset extends `system.md` with priority mapping.

**Origin actors:** A1 (Sean — primary clicker), A2 (coding agent — writes tasks, no v0 click rights), A3 (`gt` CLI — parallel surface), A4 (Ghostties MCP — parallel surface).

**Origin flows:** F1 (Inbox click w/ project), F2 (Inbox click orphan), F3 (Running click), F4 (Needs-you click), F5 (Graveyard click), F6 (new task), F7 (open `.md` without starting).

**Origin acceptance examples:** AE1 (covers R2/R3), AE2 (covers R4/R5), AE3 (covers R6), AE4 (covers R8), AE5 (covers R9/R10/R11), AE6 (covers R13).

---

## Scope Boundaries

- **Soft-claim with TTL** (#3 from ideation) — deferred to v1+ when audience >1.
- **Workspace context loading** (#7 from ideation) — deferred (col-3 PR pane, in-app editor don't exist).
- **`⌘Z` row-click undo** — deferred. Recovery via `exit` / edit `.md` / `gt done`. Re-click is focus-only.
- **Rich Graveyard read-mode** (col-3 markdown viewer or col-2 glow render) — separate brainstorm.
- **Richer Inbox prioritization** (next-up indicators, urgency color, deadline-aware sort, learned priors) — separate brainstorm; v0 ships the minimal slice in R15.
- **Auto-pilot agents pulling from Inbox autonomously** — wire already exists via `update_task_status`; the deferral is the soft-claim safety primitive, not the wire.
- **`j`/`k` row navigation** — out of v0.
- **Project-as-mode** — already parked.
- **In-app `.md` viewer** — out of v0 by column-model rule.

### Deferred to Follow-Up Work

- **Multi-window cross-IPC for "task is running in another window"** — v0 takes the cheap path: window B's click on a Running row whose live `SurfaceView` lives in window A respawns locally in B. Cross-window IPC and a "running in another window" affordance queue for v1+. (See U12 race-guards note.)
- **Status flow-back into Linear** when a Ghostties task moves to Done with `source: linear` — already a Phase 5 stretch in `phases-plan.md`.

---

## Context & Research

### Relevant Code and Patterns

- `macos/Sources/Features/Ghostties/TaskSidebarView.swift` — sidebar composition (Inbox → Running → Needs-you → Graveyard with Backlog/Review as sub-lanes inside `ArchiveZoneView`).
- `macos/Sources/Features/Ghostties/TaskStore.swift` — read-only today; gains write capability via `GhosttiesCore` link in U2.
- `macos/Sources/Features/Ghostties/TaskRowView.swift` — has `📝` chip on hover; **no expansion affordance today** (per origin's verified claim).
- `macos/Sources/Features/Ghostties/TaskFileWatcher.swift` — debounced watcher driving lane migration.
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — `startOrFocusSession` (async, resolved-paths cache, 3s timeout); `isLikelyPromptingForInput` heuristic drives the per-session `.needsAttention` indicator only (NOT lane membership).
- `macos/Sources/Features/Ghostties/Needs/Active/ArchiveZoneView.swift` — Graveyard zone container; expansion UI lives here at the row level.
- `macos/Sources/Features/Ghostties/WorkspaceStore.swift` — `projects` enumeration drives picker UIs.
- `macos/Sources/Features/Ghostties/WorkspaceLayout.swift` — design tokens (chrome / canvas / terracotta); never hardcode colors or spacing.
- `cli/Sources/GhosttiesCore/TaskStore.swift` — already has write APIs (`Frontmatter.assemble`, `store.write`, `store.create`); reused via package link in U2.
- `cli/Sources/GhosttiesCore/Frontmatter.swift` — schema parser/writer; gains `priority` in U1.
- `cli/Sources/ghostties-mcp/Tools/` — existing tool registration pattern; new tools follow this in U9.
- `cli/Sources/gt/Commands/` — existing subcommand pattern; consulted in U10 for `gt` parity.
- `macos/Resources/presets/linear-sync/system.md` — priority mapping addendum lives here in U10.
- `macos/Sources/Features/Ghostties/MainMenu.xib` — keyboard shortcut registration in U11.

### Institutional Learnings

- `docs/solutions/logic-errors/codable-enum-raw-value-wipes-state.md` — permissive decode pattern for any new enum lane. The macOS `TaskStore` parses `TaskStatus` via `TaskStatus(rawValue:)` (strict-with-skip), not Codable. **The cited mitigation pattern doesn't strictly apply** (FYI item 7 from origin); for `priority` we use `TaskPriority(rawValue:) ?? .none` to match the existing strict-with-skip style.
- `docs/solutions/logic-errors/phase-4-ghostties-workspace-sidebar-review.md` — P1-001 (multi-window notification scoping by `coordinator.containerView?.window`) and P2-004 (`DispatchQueue.main.async` defer for surface-close races) — both load-bearing for U4 and U12.
- `docs/solutions/logic-errors/sidebar-code-review-remediation.md` — SwiftUI `onTapGesture(count:)` ordering rule. Not relevant for v0 (no double-click), but flagged if rename-on-double-click is added later.
- `docs/solutions/architecture/two-layer-state-architecture-swiftui-appkit-session-management.md` — explains why click → `SessionCoordinator` (NSWindow-bound) instead of mutating SwiftUI state directly.
- `docs/solutions/ui-bugs/session-status-needs-attention-indicator.md` — confirms `isLikelyPromptingForInput` is per-session indicator dot (not lane membership).

### External References

- None used. Codebase has dense local patterns for SwiftUI inline expansion, file-watcher-driven view updates, and three-surface schema coherence.

---

## Key Technical Decisions

- **D1. Macos write API source: link `GhosttiesCore` into the macOS target.** The pbxproj already has `XCLocalSwiftPackageReference` pointing at `../cli` (added by Wave 2c per ORCHESTRATOR.md). Importing `GhosttiesCore` from the macOS target gives us a single Frontmatter parser/writer across the three surfaces, eliminates a chunk of Fragile Area #14 (schema coherence), and avoids re-implementing write paths that already exist and are tested. Alternative (build native write APIs in macOS `TaskStore`) was rejected: forks the schema parser, doubles the test surface, and the only "win" would be slightly faster compile times.
- **D2. No `task.promote` MCP tool.** `update_task_status` already covers the status-flip semantics. Renaming/aliasing is ceremony without value. `task.create` and `task.set_project` are genuinely new; ship those.
- **D3. New task `id` is a UUIDv4 (lowercased, no dashes — first 8 hex chars used as the visible filename slug after the title slug).** Matches the existing fixture pattern (`{slug}-{shortid}.md`). Avoids title-collision corner cases when two composers fire close together. **Verify during U8 implementation** by reading existing fixture filenames.
- **D4. Triage card spatial mechanic: push (rows below reflow down).** Most consistent with the existing spatial-stability animation already in the sidebar. Overlay/replace would fight that animation system. Implementation rides the same `.transition` modifiers used for lane migration.
- **D5. Composer placement: pinned at the top of the Inbox lane when triggered.** Pushes Inbox rows down (same mechanic as D4). Closing the composer collapses the slot.
- **D6. Project picker required, pre-selected to most-recently-used.** Origin's three options were (a) keep required, (b) make optional with cwd default, (c) keep required with MRU pre-selection. Picked (c): "no project" tasks are exactly the orphan-Inbox case this plan was written to fix; making them creatable from the composer would re-introduce the silent-no-op pattern. MRU pre-selection keeps friction near zero for the common case.
- **D7. Empty `WorkspaceStore.projects` first-run path: out-of-flow.** The picker shows an "Add project…" affordance that opens the existing Workspace Settings sheet. v0 doesn't ship in-flow project creation. If the user adds a project and returns, the picker re-populates.
- **D8. Killed/exited terminal during Running click: respawn at `project-path`, status stays `running`.** Auto-migrating to Graveyard belongs to the surface-close handler, not the click. Click is action-shaped, not state-correction-shaped.
- **D9. Multi-window: cheap path for v0.** File-driven status flip + watcher migration is naturally cross-window. Click in window B on a now-Running row whose live `SurfaceView` lives in window A respawns locally in B. Accept the duplicate-session edge case in v0; queue cross-window IPC for v1+ (deferred to follow-up).
- **D10. Re-click on expanded Graveyard row: toggle (collapse).** Matches user intuition; cheaper than a separate "close expansion" affordance. (FYI item 5 from origin.)
- **D11. Concurrent composer triggers: only one composer open at a time; second trigger focuses the existing composer's title field.** (FYI item 6 from origin.)
- **D12. Backlog and Review lane click semantics:** Backlog click → behaves like Inbox click (same router, project-vs-orphan branch). Review click → behaves like Graveyard click (inline expansion). Both are sub-lanes inside `ArchiveZoneView` per MEMORY.md, and "Review" is for tasks marked `status: review` — clicking shouldn't restart a terminal that already finished its work.
- **D13. Disk-write failure UX: row-level error chip + toast.** When the click handler's frontmatter write fails (permissions, full disk, atomic-rename failure), show a transient toast and a persistent error chip on the row until the next successful write. This is the explicit anti-pattern the doc was written to fix; silent-no-op is unacceptable.
- **D14. Click-during-animation race: per-`taskId` debounce, 250ms.** Disable the row's click target from the moment the handler fires until the watcher confirms the new status (or 250ms elapses, whichever first). Cheap, local, no global lock.
- **D15. Status-flip writes happen on a background queue; UI updates on main.** Per the existing `DispatchQueue.main.async` defer pattern in P2-004 — surface-close handlers must wrap status-flip notifications in `main.async` to avoid the race when terminal exits and a click handler is mid-flight.
- **D16. Priority field: parsed permissively, defaults to `.none` on missing or unknown values.** Mirrors the existing `TaskStatus(rawValue:)` strict-with-skip pattern. Adding new priority levels later won't wipe state.

---

## Open Questions

### Resolved During Planning

- **macOS write API source** → D1 (link `GhosttiesCore`).
- **task.promote vs alias vs new** → D2 (no rename; add `task.create` + `task.set_project`).
- **Composer file naming** → D3 (UUIDv4 short suffix; verify during U8).
- **Triage card spatial mechanic** → D4 (push, ride existing animation).
- **`[+ Start]` button placement** → D5 (sticky at top of Inbox lane when triggered) + composer placement clarified in U8.
- **Project picker required vs optional** → D6 (required, MRU pre-selected).
- **Empty `WorkspaceStore.projects` first-run** → D7 (out-of-flow Settings link).
- **Killed/exited Running click** → D8 (respawn).
- **Multi-window race** → D9 (cheap path; cross-window IPC deferred).
- **Backlog/Review lane click semantics** → D12 (Backlog like Inbox, Review like Graveyard).
- **Disk-write failure UX** → D13 (row-level error chip + toast).
- **Click-during-animation race** → D14 (250ms per-taskId debounce).
- **Re-click on expanded Graveyard row** → D10 (toggle).
- **Concurrent composer triggers** → D11 (single composer, focus existing).
- **Permissive Codable note from origin Dependencies** → cited solution doesn't strictly apply (parser is `rawValue:`, not Codable); priority addition uses the same strict-with-skip pattern.

### Deferred to Implementation

- **Exact filename slug algorithm** for new tasks (U8) — pick during implementation by reading 5–10 existing fixture filenames.
- **`gt` CLI surface for triage and priority** — `gt new` already accepts `--project`; whether to extend with `--priority` and how `gt set-project <id>` should be named (vs. inline `gt edit`) is a small ergonomic call best made when writing U10.
- **Toast component reuse vs new** (D13) — there's no toast component today in macOS Ghostties module; either build a minimal one in U12 or land error state as row-chip-only and skip the toast for v0. Decide after implementing U4.
- **VoiceOver label copy** (U12) — settle exact strings during implementation review with Sean.
- **Animation timings** for chevron + composer push (U7, U8) — match existing sidebar animation timings; choose specific easing/duration when building.
- **Most-recently-used project storage** (D6) — UserDefaults vs in-memory `WorkspaceStore` property; pick during U8.

---

## Output Structure

This plan modifies many existing files and creates a small set of new ones. New files cluster in two locations:

```
macos/Sources/Features/Ghostties/
  RowClick/
    RowClickRouter.swift            (U3 — handleRowClick + dispatch)
    RowClickHandlers.swift          (U4–U7 — five named handlers)
  Composer/
    NewTaskComposerView.swift       (U8 — composer UI)
    NewTaskComposerStore.swift      (U8 — composer state + write)
  Triage/
    OrphanTriageCardView.swift      (U6 — triage card UI)
  Graveyard/
    GraveyardRowExpansionView.swift (U7 — net-new expansion UI)

cli/Sources/ghostties-mcp/Tools/
  CreateTask.swift                  (U9 — task.create)
  SetTaskProject.swift              (U9 — task.set_project)
```

Folder structure is a recommendation; implementer may flatten if the surrounding `Features/Ghostties/` directory convention prefers fewer subfolders.

---

## High-Level Technical Design

> _This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce._

### Click router — lane-aware dispatch

```text
handleRowClick(task) =
  switch task.lane                 // derived from task.status + presence-of-project-path
    case .inbox where hasProjectContext(task) -> startInboxTask(task)
    case .inbox                                -> triageOrphanTask(task)
    case .backlog where hasProjectContext(task) -> startInboxTask(task)   // D12
    case .backlog                              -> triageOrphanTask(task)
    case .running                              -> focusRunningTask(task)
    case .needsYou                             -> focusNeedsYouTask(task)
    case .review                               -> expandGraveyardTask(task) // D12
    case .graveyard                            -> expandGraveyardTask(task)
```

Each handler is its own function. They share no implementation. This is dispatch, not abstraction.

### Click → file → watcher loop (the existing event flow)

```text
[user click]
   |
   v
RowClickRouter.handleRowClick(task)
   |
   v
[handler — e.g., startInboxTask]
   |  (write status:running to .md frontmatter via GhosttiesCore.TaskStore.write)
   |  (start session via SessionCoordinator.startOrFocusSession — async)
   |  (debounce row click target for 250ms or until watcher confirms — D14)
   v
[disk: .ghostties/tasks/<id>.md mutated]
   |
   v
TaskFileWatcher (debounced, per-process)
   |
   v
TaskStore.reload(file)
   |
   v
[SwiftUI re-render — row migrates to Running lane via spatial-stability animation]
```

The handler is **write-only** with respect to UI state. UI updates flow through the watcher. This is the same pattern Phase 1's task-first sidebar shipped — extending, not replacing it.

### Composer / triage card / Graveyard expansion (column-1-internal UI)

All three are column-1-only — none touches column 2. They use the same SwiftUI `.transition` family the sidebar uses for lane migration:

| Surface             | Trigger                                     | Spatial mechanic                              | Closes via                                              |
| ------------------- | ------------------------------------------- | --------------------------------------------- | ------------------------------------------------------- |
| Composer            | `[+ Start]` button, empty Inbox click, `⌘N` | Push at top of Inbox lane                     | Confirm (creates task), Cancel, `Escape`                |
| Triage card         | Click on orphan Inbox row                   | Push: row expands in place, rows below reflow | Confirm (writes project-path + continues as F1), Cancel |
| Graveyard expansion | Click on Graveyard/Review row               | Push: row expands in place                    | Re-click (toggle, D10)                                  |

---

## Implementation Units

### Phase 1 — Foundation

- [ ] U1. **Frontmatter `priority` field across three surfaces**

**Goal:** Add `priority: high | medium | low | none` to the task schema; default `.none`. Makes the field readable by all three surfaces and writable by CLI/MCP. UI-side priority editing is out (per R10 — composer doesn't surface it).

**Requirements:** R15.

**Dependencies:** None.

**Files:**

- Modify: `cli/Sources/GhosttiesCore/Frontmatter.swift` — add `priority` parse + serialize.
- Modify: `cli/Sources/GhosttiesCore/Task.swift` — add `priority: TaskPriority` property; `enum TaskPriority: String, Codable { case high, medium, low, none }`.
- Modify: `macos/Sources/Features/Ghostties/TaskModel.swift` — mirror `TaskPriority` (until U2 makes the macOS type a re-export of `GhosttiesCore.TaskPriority`).
- Modify: `macos/Sources/Features/Ghostties/TaskStore.swift` — parse priority in fixture parser using `TaskPriority(rawValue:) ?? .none` (strict-with-skip per D16).
- Test: `cli/Tests/GhosttiesCoreTests/FrontmatterTests.swift` — round-trip priority across all four values + missing case.
- Test: `macos/Tests/Ghostties/TaskFixtureParserTests.swift` (or wherever the fixture parser tests live) — same coverage.

**Approach:**

- D16: parse permissively. Missing or unknown values → `.none`. Adding higher levels later doesn't wipe state.
- Three-surface coherence test (`MCPProtocolTests` or its CLI equivalent — confirm location during impl) extends to assert priority round-trips through gt and MCP writes.

**Patterns to follow:**

- `cli/Sources/GhosttiesCore/Task.swift` `TaskStatus` enum and its parsing.
- `docs/solutions/logic-errors/codable-enum-raw-value-wipes-state.md` (pattern, even though we use `rawValue:` not Codable).

**Test scenarios:**

- Happy path: parse `priority: high` → `.high`. Parse `priority: medium` → `.medium`. Parse `priority: low` → `.low`. Parse `priority: none` → `.none`.
- Edge case: missing `priority` key → defaults to `.none`. Empty string → `.none`. Whitespace-only → `.none`.
- Edge case: unknown value (`priority: urgent`) → `.none` (no crash, no rejection of the rest of the file).
- Integration: `Frontmatter.assemble` round-trips all four levels without loss when re-parsed.
- Integration: a fixture `.md` with `priority: high` parses identically through gt CLI, MCP, and macOS `TaskFixtureParser`.

**Verification:**

- All three surfaces parse and (where applicable) write priority. Round-trip tests pass. Existing tasks without priority still load and lane-migrate correctly.

---

- [ ] U2. **Link `GhosttiesCore` into the macOS app target**

**Goal:** Make `GhosttiesCore` types (`Task`, `TaskStore` writer, `Frontmatter`) importable from the macOS app target so the macOS module can write `.md` files. Enables U4–U8.

**Requirements:** R2, R5, R11. (Origin Deferred-to-Planning: macOS `TaskStore` is currently read-only.)

**Dependencies:** U1 (schema changes land first to keep the package consistent).

**Files:**

- Modify: `macos/Ghostties.xcodeproj/project.pbxproj` — add `GhosttiesCore` to the macOS target's frameworks/libraries phase. The `XCLocalSwiftPackageReference` already exists per ORCHESTRATOR.md / Wave 2c; this unit only adds the **product dependency** for the macOS target.
- Modify: `macos/Sources/Features/Ghostties/TaskStore.swift` — `import GhosttiesCore`. Add `func writeStatus(_ status: TaskStatus, for taskId: String) async throws` and `func writeProjectPath(_ path: String, for taskId: String) async throws` and `func createTask(...) async throws -> Task` thin wrappers that delegate to `GhosttiesCore.TaskStore`.
- Modify: `macos/Sources/Features/Ghostties/TaskModel.swift` — collapse local `TaskStatus` / `TaskPriority` into `typealias`es of the `GhosttiesCore` types if signatures match cleanly; if not, keep two enums and document the bridge in a comment.
- Test: `macos/Tests/Ghostties/TaskStoreWriteTests.swift` (new) — write-path tests at the macOS-target boundary.

**Approach:**

- D1: link, don't fork. The package reference is already in the pbxproj; this is just adding the product dependency for the macOS target (not a new package).
- Wrap `GhosttiesCore.TaskStore` operations in `async throws` macOS-side methods so calls from click handlers (U4, U6, U8) read naturally.
- Permission failures, sandbox issues, atomic-rename failures must surface as throwable errors (not silently absorbed). Caller (D13) renders the error chip + toast.

**Execution note:** Before adding the dependency, confirm the package builds clean in the macOS scheme (`xcodebuild build` with `ONLY_ACTIVE_ARCH=YES ARCHS=arm64` — Fragile Area #4 from ORCHESTRATOR.md). pbxproj edits are fragile per Fragile Area #16; commit pbxproj changes in their own atomic commit so a rollback is surgical.

**Patterns to follow:**

- pbxproj surgery pattern from `feat/mcp-source-auth-ui` (Wave 2c) — see ORCHESTRATOR.md Decision Log 2026-04-23 (late) for the original `XCLocalSwiftPackageReference` precedent.
- `cli/Sources/GhosttiesCore/TaskStore.swift` write API — already has `Frontmatter.assemble`, `store.write`, `store.create`.

**Test scenarios:**

- Happy path: macOS-side `writeStatus(.running, for: id)` updates the `.md` and the `TaskFileWatcher` picks up the change. Round-trip via macOS read confirms.
- Error path: write to a sandboxed/read-only directory throws a typed error. Caller can catch and surface a row-level error chip.
- Error path: atomic-rename collision with concurrent writer (simulated) throws cleanly without corrupting the file.
- Integration: after U2 lands, gt CLI writing to a task and macOS reading via `TaskStore` both see identical frontmatter for `priority` (catches divergence between local `TaskStatus` enum and `GhosttiesCore.TaskStatus`).

**Verification:**

- `import GhosttiesCore` compiles in macOS target. Macos module can write `.md` files. Existing read-path tests remain green. CLI cross-surface coherence test still passes.

---

- [ ] U3. **Click router skeleton — `handleRowClick(task)` lane dispatch**

**Goal:** Stand up the dispatch surface that all five handlers will plug into, with stub implementations for each lane. Existing `TaskRowView` click action is rewired to call the router. This unit ships with the existing behavior preserved (so `main` doesn't regress mid-stack); subsequent units replace each stub with a real handler.

**Requirements:** R1.

**Dependencies:** U2 (router will need write APIs in subsequent units; landing the skeleton on top of U2 keeps the stack additive).

**Files:**

- Create: `macos/Sources/Features/Ghostties/RowClick/RowClickRouter.swift`.
- Create: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — stubs for `startInboxTask`, `triageOrphanTask`, `focusRunningTask`, `focusNeedsYouTask`, `expandGraveyardTask`.
- Modify: `macos/Sources/Features/Ghostties/TaskRowView.swift` — replace existing tap action with `RowClickRouter.shared.handleRowClick(task)` (or `@EnvironmentObject` injection if ownership analysis says so during impl).
- Test: `macos/Tests/Ghostties/RowClickRouterTests.swift` (new) — dispatch correctness for each lane × project-context combination.

**Approach:**

- The router is a `switch` on a derived `lane` value, not stored state. `lane` derives from `task.status` + `hasProjectContext(task)` (returns `true` if `project-path` is set or `project` resolves via `WorkspaceStore.projects`).
- Stubs in U3 preserve current behavior: `startInboxTask` calls the existing tap action; the others are no-ops with TODO logs. This keeps `main` shippable mid-stack.
- Router is `@MainActor` per existing convention for sidebar state objects.

**Patterns to follow:**

- Existing dispatch in `WorkspaceStore` / `SessionCoordinator` — `@MainActor` + actor-isolated state.

**Test scenarios:**

- Happy path: row in Inbox with `project-path` set → router calls `startInboxTask`.
- Happy path: row in Inbox without `project-path` and no resolvable `project` → router calls `triageOrphanTask`.
- Happy path: row with `status: running` → router calls `focusRunningTask`.
- Happy path: row with `status: needs-you` → router calls `focusNeedsYouTask`.
- Happy path: row with `status: done` → router calls `expandGraveyardTask`.
- Edge case (D12): row with `status: backlog` and project context → router calls `startInboxTask`. Without project → `triageOrphanTask`.
- Edge case (D12): row with `status: review` → router calls `expandGraveyardTask`.
- Edge case: project resolution path — `project` field set, `project-path` missing, and `WorkspaceStore.projects` contains a matching name → `startInboxTask` (project context present via resolution).
- Edge case: same `project` name but `WorkspaceStore.projects` doesn't contain it → `triageOrphanTask`.

**Verification:**

- Router dispatches correctly for every lane × project-context combination. Existing Inbox-with-project click behavior is preserved (existing fixture tasks still spawn terminals on click). Stub handlers log their invocation so the next units can replace them surgically.

---

### Phase 2 — Core handlers

- [ ] U4. **`startInboxTask` — Inbox click with project context**

**Goal:** Replace the U3 stub with the real handler. Click writes `status: running` to frontmatter (via U2 write API), spawns/focuses the terminal session via `SessionCoordinator.startOrFocusSession`, routes column 2. File-watcher migrates the row to Running.

**Requirements:** R2, R3.

**Dependencies:** U2, U3.

**Files:**

- Modify: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — `startInboxTask` real implementation.
- Modify: `macos/Sources/Features/Ghostties/TaskStore.swift` — surface the write helper from U2 with the right error semantics.
- Modify: `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — confirm `startOrFocusSession(at: projectPath, taskId:)` signature accepts a `taskId` for binding (probably already does — verify in impl).
- Test: `macos/Tests/Ghostties/StartInboxTaskTests.swift` (new) — full handler coverage.

**Approach:**

- Handler is **write-only** w.r.t. UI state — the watcher is the single source of UI truth (R3).
- Per-`taskId` debounce (D14): set a "promotion in-flight" flag for 250ms or until the watcher confirms `status: running`; during that window, the row's click target is disabled.
- Per P1-001 from `docs/solutions/logic-errors/phase-4-ghostties-workspace-sidebar-review.md`: status-flip notifications are filtered by `coordinator.containerView?.window` — multi-window safe.
- Per D8: if `startOrFocusSession` reports the resolved-paths cache has a stale entry (terminal exited but row still says running), respawn at `project-path`.
- Per D13: write-failure → throws → caller renders row-level error chip + toast.

**Patterns to follow:**

- `SessionCoordinator.startOrFocusSession` async path — do **not** revert to synchronous `Process.waitUntilExit()` (Dependencies/Assumptions item 1 in origin).
- `phase-4-ghostties-workspace-sidebar-review.md` P2-004 — wrap status-flip notifications in `DispatchQueue.main.async`.

**Test scenarios:**

- Covers AE1. Happy path: Inbox row with `project-path: ~/Code/ghostties` clicked → `.md` shows `status: running`, terminal session spawns at the path, row migrates to Running, column 2 shows the new terminal.
- Edge case (D14): rapid double-click on the same Inbox row → only one status-flip write, only one spawn.
- Edge case (D14): click row A then row B within 200ms → both fire (debounce is per-`taskId`, not global).
- Error path (D13): write to `.md` fails (simulated `EACCES`) → no spawn, no migration, error chip appears on the row, toast shown.
- Error path: `startOrFocusSession` returns within 3s timeout but reports failure → row migrates (status was written) but column 2 shows session-spawn error state.
- Integration: click → write → file-watcher fires → `TaskStore.reload` → row reappears in Running lane with the spatial-stability animation.
- Integration (multi-window, D9 + P1-001): click in window A → window A's session, window A's column 2. Window B's watcher migrates the row to Running; clicking it in window B respawns locally in B.

**Verification:**

- AE1 passes by hand. Tests pass. The original silent-no-op pattern (Linear orphan tasks) is gone — orphan clicks now fall through to U6, not into a dead end.

---

- [ ] U5. **`focusRunningTask` and `focusNeedsYouTask` — Running + Needs-you click**

**Goal:** Replace U3 stubs. Both handlers route column 2 to the task's existing terminal session and focus the cursor. No status flip, no respawn, no auto-scroll.

**Requirements:** R6, R7.

**Dependencies:** U3. (Independent of U4 — these handlers don't write.)

**Files:**

- Modify: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — both handlers' real implementations.
- Test: `macos/Tests/Ghostties/FocusRunningTaskTests.swift` (new) — covers both handlers since they're identical in v0.

**Approach:**

- `focusNeedsYouTask` calls `focusRunningTask` (or both share a private `routeToExistingSession(task)` helper). Origin explicitly says they're identical in v0; planner won't fight that.
- Per D8: if no live `SurfaceView` exists for the task (`exit`ed or crashed but `surface-close` handler hasn't fired), respawn at `project-path` — keep status as `running`. Don't auto-migrate to Graveyard.
- Lane membership for Needs-you is `task.status == .needsYou` (R7) — the live `isLikelyPromptingForInput` heuristic stays per-session indicator only. **No code change to the heuristic in this unit.**

**Patterns to follow:**

- `SessionCoordinator.startOrFocusSession` already handles "focus existing if present, spawn if not" — reuse that path.

**Test scenarios:**

- Covers AE3 (R6). Happy path: click Running row → column 2 routes to the existing session, cursor focuses, no status flip, no respawn (assert spawn count unchanged).
- Happy path (R7): click Needs-you row → column 2 routes to the existing session, cursor focuses. (No auto-scroll asserted — visual behavior, but ensure the test doesn't accidentally couple to a future auto-scroll feature.)
- Edge case: idempotent re-click — clicking a Running row twice in succession produces zero spawns.
- Edge case (D8): Running row whose live `SurfaceView` was closed by `exit` but `surface-close` handler hasn't fired → respawns at `project-path`, status stays `running`. (Surface-close handler later migrates to Graveyard via the existing path — not this handler's job.)
- Edge case (D9): click in window B on a Running row whose live session lives in window A → respawns locally in B. (V0 acceptance; cross-window IPC deferred.)

**Verification:**

- Tests pass. Manual: starting a task then clicking its Running row never spawns a duplicate. Needs-you row click routes column 2 without surprise.

---

### Phase 3 — Net-new column-1 UI

- [ ] U6. **Orphan triage card + `triageOrphanTask`**

**Goal:** Net-new inline UI for clicking an Inbox/Backlog row without project context. Card opens attached to the row (push mechanic D4); fields = project picker (required, MRU pre-selected per D6), optional template picker, optional title edit. Confirm writes `project-path` (and optional `template`) to frontmatter, then continues as F1 (status flip, spawn, migrate).

**Requirements:** R4, R5, R12 (`task.set_project` MCP equivalence — see U9).

**Dependencies:** U2 (write API), U3 (router stub), U4 (continuation flow).

**Files:**

- Create: `macos/Sources/Features/Ghostties/Triage/OrphanTriageCardView.swift` — SwiftUI card.
- Create: `macos/Sources/Features/Ghostties/Triage/OrphanTriageStore.swift` — picker state + commit logic.
- Modify: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — `triageOrphanTask` real implementation.
- Modify: `macos/Sources/Features/Ghostties/TaskSidebarView.swift` — slot for the inline card attached to the active orphan row (push mechanic).
- Modify: `macos/Sources/Features/Ghostties/Needs/Active/InboxZoneView.swift` (or equivalent — confirm during impl) — render the triage card slot inline when an orphan row is in triage state.
- Test: `macos/Tests/Ghostties/TriageOrphanTaskTests.swift` (new).

**Approach:**

- D4: card pushes Inbox rows below it down — same `.transition` family as lane migration. No overlay, no sheet.
- D6: project picker pre-selects most-recently-used project. MRU storage decision deferred (UserDefaults vs in-memory; pick during impl).
- D7: empty `WorkspaceStore.projects` — picker shows "Add project…" affordance opening Workspace Settings sheet. No inline project creation.
- Confirm flow:
  1. Validate fields (project required, title non-empty if title was edited).
  2. Write frontmatter: `project-path`, optional `template`, optional renamed `title`.
  3. Call `startInboxTask(task)` (U4) for the rest of the flow.
  4. Close the card.
- Cancel flow: close card, no writes, row stays in Inbox.
- Per D11: only one triage card open at a time. Clicking another orphan row while a card is open closes the first and opens the second.

**Patterns to follow:**

- Existing pickers in `WorkspaceSettings` for the project list rendering.
- Spatial-stability animation in `TaskSidebarView` for the push mechanic.

**Test scenarios:**

- Covers AE2. Happy path: orphan Inbox row clicked → triage card opens, project "ghostties" picked, confirm → `.md` updated with `project-path: ~/Code/ghostties`, status flips to `running`, terminal spawns, row migrates.
- Happy path: card pre-selects MRU project. Sean confirms without changing → uses the MRU. (This is the friction-reduction win.)
- Happy path: optional template picker filled in → `.md` includes `template: <name>` after confirm.
- Happy path: optional title edit → `.md` `title:` is rewritten before status flip.
- Edge case: cancel → no writes, row stays in Inbox unchanged. (Failure path of F2.)
- Edge case (D11): click orphan row A → card opens. Click orphan row B without confirming → row A's card closes, row B's card opens.
- Edge case (D7): `WorkspaceStore.projects` empty → "Add project…" appears. Tapping it opens Workspace Settings (don't assert the sheet's contents, just that it opens).
- Error path (D13): frontmatter write fails → row gets error chip, card stays open showing the error, no spawn.
- Integration: confirming card → `.md` written → file-watcher fires → row migrates → terminal spawns. End-to-end happy path.

**Verification:**

- AE2 passes by hand. Linear-imported orphan tasks become triageable — the highest-frequency orphan source per origin's "Dependencies / Assumptions."

---

- [ ] U7. **Graveyard inline expansion + `expandGraveyardTask`**

**Goal:** Net-new per-row inline expansion UI. Click on Graveyard or Review row opens a collapsible panel within column 1 showing animated chevron, frontmatter chips, first ~8 lines of `.md` body. Column 2 must not be touched.

**Requirements:** R8, D12 (Review lane).

**Dependencies:** U3.

**Files:**

- Create: `macos/Sources/Features/Ghostties/Graveyard/GraveyardRowExpansionView.swift` — expansion panel SwiftUI view.
- Create: `macos/Sources/Features/Ghostties/Graveyard/GraveyardRowExpansionState.swift` — per-row expansion state (or hold it on `TaskStore` as `expandedTaskIds: Set<String>`; pick during impl).
- Modify: `macos/Sources/Features/Ghostties/TaskRowView.swift` — render expansion panel below the row when expanded; add animated chevron affordance.
- Modify: `macos/Sources/Features/Ghostties/Needs/Active/ArchiveZoneView.swift` — accommodate per-row expansion (the row + its panel reflow as one unit).
- Modify: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — `expandGraveyardTask` toggles expansion state.
- Test: `macos/Tests/Ghostties/ExpandGraveyardTaskTests.swift` (new).

**Approach:**

- TaskRowView has no expansion affordance today — this is net-new. Pick a custom expansion (animated chevron + reflow) over `DisclosureGroup` because the row has bespoke layout (chips, hover affordance, status indicator); `DisclosureGroup` would fight that.
- Body preview: read `.md` body excluding frontmatter, first ~8 lines, render as plain text with monospace styling. Don't render markdown; this is preview, not viewer.
- Frontmatter chips: title, status, project (or "no project"), `source` if present, `created` date.
- D10: re-click on expanded row toggles to collapse.
- Column 2 untouched — this handler does not call `SessionCoordinator` at all.
- Reduced-motion: disable the chevron animation when `accessibilityReduceMotion` is on (covered in U12).

**Patterns to follow:**

- `WorkspaceLayout` tokens for chip styling, monospace font, spacing.
- Existing chevron-using affordances in macOS (search the codebase during impl; if none, ship a custom one).

**Test scenarios:**

- Covers AE4. Happy path: click Graveyard row → expansion opens below the row, body preview visible, column 2 unchanged.
- Happy path (D12): click Review row → expansion opens (same UI as Graveyard).
- Edge case (D10): click expanded row → toggles to collapse. Click again → toggles to expand.
- Edge case: row with empty `.md` body → expansion shows frontmatter chips only, no preview pane (or "(no notes)" placeholder — choose during impl).
- Edge case: multiple rows expanded simultaneously is allowed (each row owns its own expansion state).
- Edge case: very long body — preview clamps to ~8 lines + ellipsis, doesn't blow out the sidebar height.
- Edge case: row migrates to a different lane while expanded (e.g., agent re-opens a Review task) → expansion collapses gracefully (or persists if status stays in Graveyard; pick during impl, but the test asserts "doesn't crash").
- Integration: click Graveyard row → assert column 2 contents are byte-identical before and after.

**Verification:**

- AE4 passes. Click Graveyard row never touches column 2. Toggle works. Body preview renders without rendering markdown (no link parsing, no headings).

---

- [ ] U8. **New-task composer + three triggers**

**Goal:** Inline composer in column 1 with three triggers: persistent `[+ Start]` button in sidebar header, click on empty Inbox lane area, `⌘N` from anywhere. Composer fields: title (required), project (required, MRU pre-selected per D6), optional template picker. Confirm creates `.md` with `status: running` + chosen project + chosen template + title; file-watcher drives row appearance and terminal spawn.

**Requirements:** R9, R10, R11.

**Dependencies:** U2 (write API), U4 (continuation flow). Independent of U6/U7.

**Files:**

- Create: `macos/Sources/Features/Ghostties/Composer/NewTaskComposerView.swift` — composer SwiftUI view.
- Create: `macos/Sources/Features/Ghostties/Composer/NewTaskComposerStore.swift` — composer state, validation, write logic, MRU project tracking.
- Modify: `macos/Sources/Features/Ghostties/TaskSidebarView.swift` — add `[+ Start]` button to the sidebar header; render composer slot at top of Inbox lane when active.
- Modify: `macos/Sources/Features/Ghostties/Needs/Active/InboxZoneView.swift` — empty-area click target opens composer.
- Modify: `macos/Sources/Features/Ghostties/MainMenu.xib` — add `New Task` menu item with `⌘N` shortcut.
- Modify: `macos/Sources/Features/Ghostties/AppDelegate.swift` — wire menu item to composer trigger.
- Test: `macos/Tests/Ghostties/NewTaskComposerTests.swift` (new).

**Approach:**

- D5: composer pinned at top of Inbox lane when triggered. Pushes Inbox rows down. Closes via Confirm, Cancel, or `Escape`.
- Per origin and D6: project picker required, MRU pre-selected.
- D11: only one composer open at a time. Second trigger focuses the existing composer's title field.
- D3: filename = `<title-slug>-<uuid-short>.md` (8 hex chars from a UUIDv4). Verify exact slug algorithm by reading existing fixture filenames during impl.
- Cancellation: no `.md` written, no spawn. Title drafts are not preserved across composer sessions in v0.
- After confirm: composer closes, file-watcher picks up the new file, row appears in Running lane (NOT Inbox — `status: running` is written directly), terminal spawns at the project path, column 2 routes.
- Discovery (FYI item 3, see U12): tooltip on `[+ Start]` button shows "New task — ⌘N".
- Tooltip on `📝` chip (already added in TaskRowView) shows "Open notes — ⌘O" (also U12).

**Patterns to follow:**

- Existing pickers in Workspace Settings for the project + template lists.
- Existing menu shortcut wiring in `MainMenu.xib` / `AppDelegate.swift`.

**Test scenarios:**

- Covers AE5. Happy path: empty Inbox → click empty area → composer opens at top of Inbox lane → fill title "Refactor sidebar row", pick "ghostties", leave template blank, confirm → `.md` written with `status: running, project: ghostties, title: "Refactor sidebar row"`, Running row appears, terminal spawns at the ghostties project path, column 2 routes.
- Happy path: `[+ Start]` button click → composer opens. Same behavior as empty-area click.
- Happy path: `⌘N` from a non-Inbox lane → composer opens, sidebar scrolls to show the composer at top of Inbox.
- Happy path: composer pre-selects MRU project. Sean confirms without changing → uses MRU.
- Edge case (D11): `⌘N` while composer is already open → focuses composer's title field, doesn't open a second composer.
- Edge case (D11): empty-area click while composer is open via `⌘N` → focuses composer title field, doesn't open a second composer.
- Edge case: empty title → `[▶ Start]` button disabled. Whitespace-only title → disabled.
- Edge case: cancel via `Escape` → no `.md`, no spawn, composer closes.
- Edge case (D7): empty `WorkspaceStore.projects` → project picker shows "Add project…" affordance opening Workspace Settings.
- Edge case (D3): two `⌘N` invocations close together each producing a task → both files have unique filenames (UUIDv4 short suffix).
- Error path (D13): `.md` write fails → composer stays open, error message shown, no spawn.
- Integration: confirm composer → `.md` written to `.ghostties/tasks/` with all fields → watcher fires → row appears in Running lane → terminal spawns at project path → column 2 routes.

**Verification:**

- AE5 passes. Three triggers all open the same composer. Empty-Inbox dead-end is gone. New tasks with `priority` field absent default to `.none` (covered by U1 tests).

---

### Phase 4 — Cross-surface parity

- [ ] U9. **MCP tools: `task.create` and `task.set_project`**

**Goal:** Add two new MCP tools to the Ghostties MCP server so the GUI's composer (U8) and triage card (U6) have CLI/MCP equivalents per R12.

**Requirements:** R12 (design intent — not blocking, but worth shipping for `composer` and `triage` since both have meaningful data semantics).

**Dependencies:** U1 (priority field).

**Files:**

- Create: `cli/Sources/ghostties-mcp/Tools/CreateTask.swift` — `task.create` tool.
- Create: `cli/Sources/ghostties-mcp/Tools/SetTaskProject.swift` — `task.set_project` tool.
- Modify: `cli/Sources/ghostties-mcp/Server.swift` (or wherever tools are registered — confirm during impl) — register both tools in the manifest.
- Modify: `cli/Tests/GhosttiesMCPTests/MCPProtocolTests.swift` — bump tool count assertion (Fragile Area #14 / cross-surface coherence test). Per ORCHESTRATOR.md, prior count was 10; this lands at 12.
- Test: `cli/Tests/GhosttiesMCPTests/CreateTaskTests.swift` (new).
- Test: `cli/Tests/GhosttiesMCPTests/SetTaskProjectTests.swift` (new).
- Modify: `cli/scripts/smoke-mcp.sh` — add smoke calls for both tools.

**Approach:**

- D2: keep `update_task_status` as-is; no rename to `task.promote`.
- `task.create` parameters: `title` (required), `project` (required), `template` (optional), `priority` (optional, default `.none`), `source` (optional, e.g., `linear`, `shell`).
- `task.set_project` parameters: `id` (required), `project_path` (required), `template` (optional).
- Both tools delegate to `GhosttiesCore.TaskStore` writers — same code path the macOS app uses after U2. Three-surface coherence is automatic.
- Stdout discipline: only JSON-RPC on stdout; all logs to stderr (Fragile Area #13).

**Patterns to follow:**

- Existing tool implementations in `cli/Sources/ghostties-mcp/Tools/` — specifically `UpdateTaskStatus.swift` for write-tool shape.
- `MCPProtocolTests` count-assertion pattern.

**Test scenarios:**

- Happy path (`task.create`): valid params → `.md` created in `.ghostties/tasks/`, response contains the new task's `id` + `path`.
- Happy path (`task.create`): with `priority: high` → `.md` includes `priority: high`.
- Happy path (`task.set_project`): valid `id` + `project_path` → `.md` updated, response contains updated task.
- Edge case (`task.create`): missing required `title` → error response with clear message.
- Edge case (`task.create`): unknown `priority` value → error response (or coerce to `.none`; pick during impl, but test the chosen behavior).
- Edge case (`task.set_project`): `id` doesn't exist → error response.
- Error path: write to read-only `.ghostties/tasks/` → error response, no partial write.
- Integration: `task.create` via MCP, then read same task via `gt list` → identical fields. (Cross-surface coherence test extension.)
- Integration: `task.create` via MCP, then macOS app reads via `TaskStore` → identical fields.

**Verification:**

- 62 + 2 = 64+ CLI tests pass (Fragile Area #14 — new schema additions need to land in all surfaces). MCP tool count bumped in MCPProtocolTests. `smoke-mcp.sh` exercises both new tools.

---

- [ ] U10. **`gt` CLI updates + `linear-sync` preset priority mapping**

**Goal:** Bring `gt` CLI to parity with the new MCP tools where useful, and extend the `linear-sync` preset to map Linear's native priority field.

**Requirements:** R12, R15 (Linear priority mapping).

**Dependencies:** U1, U9.

**Files:**

- Modify: `cli/Sources/gt/Commands/New.swift` — add `--priority high|medium|low|none` flag (default `none`).
- Decide during impl whether to add a `gt set-project <id> <path>` subcommand (parallel to `task.set_project`) or extend an existing `gt edit`-style verb. Either way, modify the relevant file under `cli/Sources/gt/Commands/`.
- Modify: `macos/Resources/presets/linear-sync/system.md` — add priority mapping section. `Urgent` / `High` → `high`, `Medium` → `medium`, `Low` → `low`, `No priority` → `none`.
- Test: `cli/Tests/GtTests/NewCommandTests.swift` — add `--priority` coverage.
- Test (if `gt set-project` is added): `cli/Tests/GtTests/SetProjectCommandTests.swift` (new).

**Approach:**

- `gt new --priority` writes through `GhosttiesCore.TaskStore.create` — same path as MCP `task.create`.
- `linear-sync` preset addendum: tell the agent to read Linear's `priority` field and translate per the mapping. Don't ship code that does the translation; the preset is a prompt + config, not code (per the architectural pivot in ORCHESTRATOR.md Decision Log 2026-04-23-late).

**Patterns to follow:**

- Existing `gt` flag parsing in `cli/Sources/gt/Commands/New.swift`.
- Existing preset structure in `macos/Resources/presets/linear-sync/`.

**Test scenarios:**

- Happy path: `gt new "test task" --project ghostties --priority high` → `.md` written with `priority: high`.
- Happy path: `gt new` without `--priority` → `.md` defaults to `priority: none`.
- Edge case: `gt new --priority urgent` → error: unknown priority value.
- Test expectation for the preset addendum: none — it's a prompt change, not code. Verify by hand in U12's manual smoke test (see Verification).

**Verification:**

- `gt new --priority` works. `linear-sync` preset's `system.md` includes the mapping. Manual smoke: paste preset into Sean's Claude Code, sync a Linear task with `Urgent` priority, confirm Ghostties task lands with `priority: high`.

---

### Phase 5 — Polish & robustness

- [ ] U11. **Keyboard shortcuts + row focus model**

**Goal:** Ship `⌘N` (composer), `⌘O` (open focused row's `.md` externally), `Return` (activate focused row — same as click). Establish a row-focus model for keyboard navigation. `j`/`k` row navigation explicitly out of v0 (R14).

**Requirements:** R13 (`⌘O` is one of the two `.md`-open affordances), R14.

**Dependencies:** U3 (router for `Return = activate`), U8 (composer for `⌘N`).

**Files:**

- Modify: `macos/Sources/Features/Ghostties/MainMenu.xib` — register `⌘N` (already added in U8), add `⌘O` and `Return` row-action menu items.
- Modify: `macos/Sources/Features/Ghostties/TaskRowView.swift` — focus state, `Return` triggers `RowClickRouter.handleRowClick`.
- Modify: `macos/Sources/Features/Ghostties/AppDelegate.swift` — wire menu items.
- Test: `macos/Tests/Ghostties/KeyboardShortcutsTests.swift` (new) — XCTest-shaped where possible; some shortcuts may need UI tests deferred to manual coverage.

**Approach:**

- Origin Deferred-to-Planning question: existing keyboard focus behavior on column 1 — there's no formal row-focus model today (sidebar uses pointer-driven focus). v0 ships a minimal `@FocusState` model on the sidebar list: when the sidebar has key focus, one row is "focused" (default = first row of the active lane), `Return` activates it. Tab cycles through the lanes' first focusable row only. `j`/`k` deferred per R14.
- `⌘O` opens the focused row's `.md` via `NSWorkspace.shared.open(url)` — identical code path to the existing `📝` chip.
- Discovery: tooltips on `[+ Start]` (`⌘N`) added in U8; tooltip on `📝` chip (`⌘O`) added in U12.

**Patterns to follow:**

- SwiftUI `@FocusState` for the focus model.
- `NSWorkspace.shared.open(url)` for `.md` opening (already used by the `📝` chip).

**Test scenarios:**

- Happy path: `⌘N` opens composer (covered by U8 tests; assert via menu item invocation here).
- Happy path: row focused, `Return` pressed → router fires `handleRowClick` (assert dispatch by lane).
- Happy path: row focused, `⌘O` pressed → `NSWorkspace.open` called with the row's `.md` URL.
- Edge case: no row focused (sidebar lost focus or empty) → `⌘O` and `Return` are no-ops, not crashes.
- Edge case: `⌘N` from any context (composer not in focus) → opens composer.

**Verification:**

- All three shortcuts work. Manual: `⌘O` opens Obsidian/TextEdit on the focused row's `.md`. `Return` on a focused Inbox row spawns a terminal.

---

- [ ] U12. **Cross-cutting polish — empty states, error handling, race guards, multi-window scoping, accessibility, discoverability, fixture audit**

**Goal:** Address the residual polish + robustness items from origin's review section so v0 ships production-shaped, not feature-complete-but-fragile.

**Requirements:** Operational gaps 1–11 + FYI items 2–8 from origin's "From 2026-04-25 review" section.

**Dependencies:** U4–U11 (most polish hangs off the new UI).

**Files:** wide.

- Modify: `macos/Sources/Features/Ghostties/TaskSidebarView.swift` — empty states for Running / Needs-you / Graveyard / all-empty.
- Modify: `macos/Sources/Features/Ghostties/TaskRowView.swift` — error chip on disk-write failure (D13), tooltip on `📝` chip (`⌘O`).
- Modify: `macos/Sources/Features/Ghostties/RowClick/RowClickHandlers.swift` — per-`taskId` debounce (D14), 250ms.
- Modify: `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — confirm multi-window notification scoping by `coordinator.containerView?.window` (per P1-001) is in place; add tests if gaps.
- Modify: `macos/Sources/Features/Ghostties/Composer/NewTaskComposerView.swift`, `OrphanTriageCardView.swift`, `GraveyardRowExpansionView.swift`, `TaskRowView.swift`, `TaskSidebarView.swift` — VoiceOver labels, reduced-motion gates.
- Audit: `macos/Resources/fixtures/tasks/*.md` (location TBD — confirm during impl) — verify all 12 v0 fixtures parse cleanly with `priority` absent (defaults to `.none`) and lane-migrate correctly with the new router.
- Test: `macos/Tests/Ghostties/EmptyStatesTests.swift` (new), `MultiWindowScopingTests.swift` (new — may already exist; merge if so), `AccessibilityTests.swift` (new — minimal label assertions).

**Approach:**

- **Empty states (op gap 7):** Inbox empty already covered (R9 — empty-area click opens composer). Add: Running empty → quiet placeholder ("Nothing running."), Needs-you empty → hidden (no quiet placeholder; lane appears only when a task has `status: needs-you`), Graveyard empty → hidden. All-empty first-run → onboarding hint pointing at `[+ Start]` button.
- **Disk-write failure UX (op gap 1, D13):** error chip on the row + transient toast. Toast component decision: minimal new toast or row-chip-only (open question, decide during impl based on time budget).
- **Click-during-animation race (op gap 2, D14):** per-`taskId` debounce flag; cleared by file-watcher confirmation or 250ms timeout.
- **Empty `WorkspaceStore.projects` first-run dead-end (op gap 3, D7):** "Add project…" affordance covered in U6 and U8; verify the same affordance shows in both pickers and routes to the same Settings sheet.
- **Backlog/Review lane click semantics (op gap 4, D12):** covered by U3's router. This unit only verifies the dispatch test coverage exists.
- **Spatial mechanics for triage / composer / Graveyard expansion (op gap 5, D4 + D5):** covered by U6, U7, U8. This unit verifies they all use the same push mechanic so the sidebar feels coherent.
- **`[+ Start]` placement (op gap 6, D5):** covered by U8.
- **Composer required-project + MRU (op gap 8, D6):** covered by U8.
- **Multi-window watcher race (op gap 9, D9 + P1-001):** verify notification scoping is in place. Add a test if missing.
- **Killed/exited Running click (op gap 10, D8):** covered by U5.
- **Fixture migration audit (op gap 11):** read all 12 fixtures, confirm none have a stale status that the new router can't route. Migrate (or delete + re-create) any that do. Document outcome in the audit step.
- **Editorial restructure (FYI 1):** R4/R5 should logically live inside "Click semantics" — origin doc's structure decision, not this plan's. Skip.
- **VoiceOver + reduced-motion (FYI 2):** label every clickable surface. Reduced-motion: gate the chevron animation in U7 and the spatial-stability animation in the sidebar by `\.accessibilityReduceMotion`.
- **Discoverability tooltips (FYI 3):** `[+ Start]` ("New task — ⌘N") covered in U8. `📝` chip ("Open notes — ⌘O") covered here.
- **Microcopy (FYI 4):** triage card heading, composer heading, button labels — settle with Sean during implementation review. Default working copy: triage card "Pick a project to start" / "Assign + Start" button; composer "New task" / "Start" button.
- **Re-click on expanded Graveyard (FYI 5, D10):** covered by U7.
- **Concurrent composer triggers (FYI 6, D11):** covered by U8.
- **Doc accuracy on Permissive Codable cite (FYI 7):** the cite is misleading — strict `rawValue:` parser is the actual pattern. Acknowledged in U1 and D16; no separate work in this unit.
- **Trajectory note on Workspace Context Loading (FYI 8):** out of scope for v0; flagged for the next brainstorm that picks up #7.

**Patterns to follow:**

- `phase-4-ghostties-workspace-sidebar-review.md` P1-001 + P2-004 (multi-window scoping + main-async defer).
- Existing `WorkspaceLayout` tokens for empty-state typography and color.

**Test scenarios:**

- Happy path: empty Running lane shows quiet placeholder; clicking the placeholder is a no-op (or opens composer; pick during impl).
- Happy path: empty Needs-you lane is hidden (no row, no header). Same for empty Graveyard.
- Happy path (D14): click row → 200ms later click again → second click is no-op (debounced). 300ms later click again → fires (debounce expired).
- Error path (D13): write fails → row shows error chip. Next successful write clears the chip.
- Edge case: focused row gets deleted while focus is on it → focus moves to neighbor, no crash.
- Integration (multi-window, P1-001): two windows open, click row in window A, assert window B's `SessionCoordinator` does not receive the spawn notification (status-flip is file-driven, lane migration in B is fine; spawn must not fire in B).
- Integration (fixture audit): all 12 v0 fixtures load via `TaskStore`, dispatch via the router without dropping any, all priority fields default to `.none`.
- Accessibility: `OrphanTriageCardView`, `NewTaskComposerView`, `GraveyardRowExpansionView`, `[+ Start]` button, `📝` chip, row click action all have VoiceOver labels (assert at least the label is non-empty and includes the action verb).
- Accessibility: reduced-motion preference disables the Graveyard expansion's chevron animation and the sidebar's spatial-stability animation.

**Verification:**

- All operational gaps from origin review covered. v0 ships without the silent-failure modes the origin doc was written to fix. Manual smoke: click every fixture row in the populated sidebar, confirm each does what its lane says, no console errors, no UI freezes.

---

## System-Wide Impact

- **Interaction graph:** `RowClickRouter` is the new central hub. Every row click goes through it. `SessionCoordinator.startOrFocusSession` is reused (not modified semantically). `TaskFileWatcher` continues to drive lane migration (R3 — file is source of truth). `WorkspaceStore.projects` is read by triage card, composer, and an MRU tracker.
- **Error propagation:** Disk-write failures from `GhosttiesCore.TaskStore` propagate as throwable errors from the macOS-side wrappers (U2). Click handlers catch and surface via row chip + toast (D13). Spawn failures from `SessionCoordinator` propagate via the existing async error path; column 2 shows session-spawn error state.
- **State lifecycle risks:** Click-during-animation race guarded by per-`taskId` debounce (D14). Surface-close race guarded by `DispatchQueue.main.async` defer (D15, P2-004). Composer concurrent triggers guarded by single-composer rule (D11).
- **API surface parity:** Three-surface schema gains `priority` (U1). MCP gains `task.create` and `task.set_project` (U9). `gt` gains `--priority` and possibly `gt set-project` (U10). Macos module gains write capability via `GhosttiesCore` link (U2).
- **Integration coverage:** `MCPProtocolTests` cross-surface coherence test extends to cover `priority` and the two new tools. CLI smoke (`smoke-mcp.sh`) exercises both new tools. Manual integration: live `linear-sync` end-to-end test (already on the orchestrator's queue per ORCHESTRATOR.md item 3) extends to validate priority mapping.
- **Unchanged invariants:**
  - `TaskFileWatcher` semantics: still debounced, per-process, drives all lane migration. Click handlers do **not** mutate sidebar state directly.
  - `SessionCoordinator.startOrFocusSession` async signature: unchanged. Click handlers do not regress to synchronous spawn (the prior incident this plan respects).
  - `isLikelyPromptingForInput` heuristic: still drives the per-session indicator dot. Does **not** drive Needs-you lane membership in v0 (R7).
  - `update_task_status` MCP tool: unchanged. No rename, no alias.
  - Column 2 contract: terminal-only. Graveyard expansion is column-1-internal. `.md` viewing in-app is **not** added in v0.
  - `CFBundleName` / `CFBundleExecutable` / module name (`Ghostty`) / config paths / UserDefaults keys / upstream URLs: untouched (per ORCHESTRATOR.md conventions).

---

## Risks & Dependencies

| Risk                                                                                                            | Mitigation                                                                                                                                                                      |
| --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GhosttiesCore` link in pbxproj (U2) breaks the macOS build via product-dependency mismatch (Fragile Area #16). | Atomic pbxproj commit. Build with `ONLY_ACTIVE_ARCH=YES ARCHS=arm64`. Roll back surgically if needed. Resolve `Package.resolved` conflicts deliberately.                        |
| File-watcher debounce too tight → click feels laggy. Too loose → click-during-animation race (D14).             | 250ms debounce per `taskId` is the safer side; tune during U4 hand-testing.                                                                                                     |
| Multi-window file-driven status flips cause B's terminal to spawn for A's click.                                | P1-001 scoping: status-flip notifications filter by `coordinator.containerView?.window`. Lane migration in B happens (file-driven, fine); spawn does not (notification-scoped). |
| New-task `id` collision (D3) under fast composer use.                                                           | UUIDv4 short suffix gives 32 bits of entropy per task — sufficient for human-driven creation rates.                                                                             |
| Empty `WorkspaceStore.projects` traps first-run users in triage/composer (D7).                                  | "Add project…" affordance opens Workspace Settings. Out-of-flow but discoverable.                                                                                               |
| Disk-write failure silently no-ops (the very anti-pattern this plan was written to fix).                        | D13: throws → row chip + toast. Tested in U4 error-path scenarios.                                                                                                              |
| Cross-window IPC needed for "task is running in another window" (D9 deferred).                                  | V0 accepts duplicate-session edge case. Queued for v1+. Not blocking.                                                                                                           |
| pbxproj merge conflicts with the parallel DMG/release work (orchestrator note: parallel session running).       | This plan is scoped to NOT commit while the parallel session runs. Coordinate merge order with Sean before either branch lands on `main`.                                       |
| Macos `TaskFixtureParser` and `GhosttiesCore.Frontmatter` drift on `priority` parsing.                          | U1 lands schema in both places. U2 collapses macOS types to typealiases of `GhosttiesCore` types where possible. Cross-surface coherence test catches drift.                    |
| Reduced-motion gates missed → animation-induced motion sickness.                                                | U12 explicit accessibility coverage; tests assert reduced-motion disables the Graveyard chevron animation and sidebar spatial-stability animation.                              |

---

## Documentation / Operational Notes

- **`agent-experience.md`** (sidebar UX context): add a section on the new click model (router + 5 handlers + 3 column-1 UIs + composer triggers).
- **`agent-build.md`**: note that macOS now imports `GhosttiesCore`; future schema changes ride that surface.
- **`agent-craft.md`**: ensure design tokens for the new UIs (triage card, composer, Graveyard expansion, `[+ Start]` button) get added to `WorkspaceLayout`.
- **`MEMORY.md`**: add a row-click-v0 entry with link to this plan + completion status when shipped.
- **Manual smoke after merge:** click every fixture row and verify each lane behaves per its handler. Confirm `linear-sync` priority mapping works end-to-end (gates `v0.1.0-beta.1` per ORCHESTRATOR.md item 3).
- **Rollout:** feature ships entire (no flag). Existing fixture tasks load with `priority: .none` by default — backward compatible.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-25-row-click-behavior-requirements.md](../brainstorms/2026-04-25-row-click-behavior-requirements.md)
- **Ideation:** `docs/ideation/2026-04-24-row-click-behavior-ideation.md` (7 ranked survivors; Lane-aware Promote chosen).
- **Sidebar brief:** `docs/brainstorms/brief-sidebar-task-view.md` (locked design brief).
- **Phases plan:** `docs/brainstorms/phases-plan.md` (v0 → v1 phase roadmap).
- **Orchestrator state:** `.claude/projects/-Users-seansmith-Code-ghostties/memory/ORCHESTRATOR.md` — architecture summary, fragile areas, decision log.
- **Institutional learnings:**
  - `docs/solutions/logic-errors/codable-enum-raw-value-wipes-state.md`
  - `docs/solutions/logic-errors/phase-4-ghostties-workspace-sidebar-review.md` (P1-001, P2-004)
  - `docs/solutions/logic-errors/sidebar-code-review-remediation.md`
  - `docs/solutions/architecture/two-layer-state-architecture-swiftui-appkit-session-management.md`
  - `docs/solutions/ui-bugs/session-status-needs-attention-indicator.md`
- **Cross-surface coherence test:** `cli/Tests/GhosttiesMCPTests/MCPProtocolTests.swift` (extend with new schema/tool counts).
- **CI status:** `docs/solutions/architecture/project-ci-host-app-hang.md` and ORCHESTRATOR.md In-Flight Work — CI is green on `main` but UI tests are IDE-only; new XCTests for U3/U4/U5/U6/U7/U8/U11/U12 must run under the existing `xcodebuild test` flow without requiring UI automation, OR be marked IDE-only and excluded from CI per the existing pattern.
