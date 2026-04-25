---
date: 2026-04-25
topic: row-click-behavior
---

# Row-Click Behavior — v0 Requirements

## Problem Frame

Today, clicking a task row in the Ghostties task-first sidebar overloads two unrelated effects: it opens the task's `.md` in whatever app the OS hands `.md` to (typically Obsidian or another text editor) AND attempts to spawn-or-focus a terminal session for the task's project. The terminal half silently no-ops when the task lacks a resolvable `project-path` (which is the default for Linear-imported tasks), so the typical user experience is: external-editor steals focus, no terminal appears, and the user has to manually edit the .md frontmatter before clicking again does anything.

The sidebar is a **queue of work**, not a list of references to browse — its purpose is to surface prioritized tasks and let the user kick them off in the terminal with minimum friction. The first verb a row should answer to is "I'm picking this up and starting now," not "open this in some other app." This v0 reshapes the click model around that intent, baked into the existing column layout: **column 1 (sidebar) navigates → column 2 (terminal canvas) executes → column 3 (browser) is auxiliary, untouched in v0.**

Click effects must obey the column model — column 2 stays terminal-shaped (no in-app .md viewer), and column-1-internal behaviors (inline expand, composer) handle anything that isn't a terminal session.

---

## Actors

- A1. **Sean (human user)**: the primary actor. Picks tasks from the sidebar, starts them, finishes them. Designer-led workflow; prefers UI-discoverable interactions over hidden ones.
- A2. **Coding agent (Claude Code, Codex, etc.)**: writes tasks into the Ghostties MCP server (e.g., from Linear or GitHub). May appear as the source of an inbox row. In v0 the agent does not mutate task status from clicks (no auto-pilot); the human is the sole click-actor.
- A3. **`gt` CLI**: parallel surface. Future commands (`gt promote`, `gt new`) must produce the same disk-state changes as the GUI's click for three-surface coherence.
- A4. **Ghostties MCP server**: parallel surface. JSON-RPC verbs (`task.promote`, etc.) must produce the same disk-state changes as the GUI's click.

---

## Key Flows

- F1. **Click an Inbox row that has a project context**
  - **Trigger:** A1 clicks a row whose lane is Inbox and whose `.md` frontmatter contains a `project-path` (or whose `project` resolves via `WorkspaceStore.projects`).
  - **Actors:** A1
  - **Steps:** Click → frontmatter `status` flips to `running` → file watcher emits change → row migrates from Inbox to Running lane (existing spatial-stability animation) → `SessionCoordinator.startOrFocusSession` spawns a terminal at the resolved project path → column 2 routes to the new terminal session → cursor focuses the terminal.
  - **Outcome:** Task is Running; column 2 shows its terminal; user can begin work immediately.
  - **Covered by:** R1, R2, R3, R12

- F2. **Click an Inbox row that is an orphan (no project context)**
  - **Trigger:** A1 clicks a row whose lane is Inbox and whose `.md` has neither `project-path` nor a `project` matching `WorkspaceStore.projects`.
  - **Actors:** A1
  - **Steps:** Click → an inline triage card opens in column 1 attached to the row (project picker + optional template + optional title edit) → A1 confirms → `project-path` (and optional `template`) are written back to the .md frontmatter → flow continues as F1 from the spawn step.
  - **Outcome:** Task is Running; column 2 shows its terminal; the .md now carries project context for any future click.
  - **Failure path:** A1 cancels the triage card → no frontmatter write, no spawn, row stays in Inbox unchanged.
  - **Covered by:** R4, R5

- F3. **Click a Running row**
  - **Trigger:** A1 clicks a row currently in the Running lane.
  - **Actors:** A1
  - **Steps:** Click → column 2 routes to the existing terminal session bound to this task (idempotent — no new spawn, no status flip).
  - **Outcome:** Column 2 shows the task's terminal; cursor focuses it.
  - **Covered by:** R6

- F4. **Click a Needs-you row**
  - **Trigger:** A1 clicks a row in the Needs-you lane (lane membership is `task.status == .needsYou` from the task's frontmatter; the agent or `gt`/MCP wrote that status).
  - **Actors:** A1
  - **Steps:** Click → column 2 routes to the task's terminal → cursor focuses it. The user looks at the terminal to find what the agent is asking for; v0 does not auto-scroll to the prompt or otherwise highlight the prompt line.
  - **Outcome:** Column 2 shows the terminal; user can read context and respond.
  - **Covered by:** R7

- F5. **Click a Graveyard row**
  - **Trigger:** A1 clicks a row in the Graveyard lane (`status: done`).
  - **Actors:** A1
  - **Steps:** Click → a new per-row inline expansion UI opens within column 1 (animated chevron + frontmatter chips + first ~8 lines of `.md` body). Column 2 is **not** touched. Note: `TaskRowView` does not currently have an expansion affordance — this row-expansion component is net-new UI for v0.
  - **Outcome:** User sees a peek of the archived task without leaving the sidebar; column 2 still shows whatever was previously routed to it.
  - **Covered by:** R8

- F6. **Create a new task from scratch**
  - **Trigger:** A1 invokes any of three triggers: (a) the persistent `[+ Start]` button in the sidebar header, (b) clicking the empty Inbox lane area when Inbox is empty, (c) the `⌘N` keyboard shortcut from anywhere.
  - **Actors:** A1
  - **Steps:** Trigger → an inline composer opens in column 1 (title input, project picker, optional template picker) → A1 fills in title, picks project, optionally picks template → A1 clicks `[▶ Start]` (or presses Return) → a new `.md` is created in `.ghostties/tasks/` with `status: running` and the chosen project/template → file watcher picks it up → row appears in Running lane → terminal spawns at the project path → column 2 routes to it.
  - **Outcome:** New task is Running; column 2 shows its terminal.
  - **Failure path:** A1 cancels the composer → no .md is written, no spawn.
  - **Covered by:** R9, R10, R11

- F7. **Open a task's note (.md) without starting it**
  - **Trigger:** A1 hovers a row and clicks the `📝` chip, OR focuses a row and presses `⌘O`.
  - **Actors:** A1
  - **Steps:** The .md file is opened via `NSWorkspace.shared.open(url)` in whatever app the OS has registered for `.md`.
  - **Outcome:** External editor (Obsidian / etc.) opens the file. Column 2 is not affected. Row status is not changed.
  - **Covered by:** R13

---

## Requirements

**Click semantics (lane-aware dispatch)**

- R1. A click on a row dispatches via a small router (`handleRowClick(task)`) to a lane-specific handler. v0 implements five handlers, each owning its own effect:
  - `startInboxTask` (Inbox with project context — R2)
  - `triageOrphanTask` (Inbox without project context — R4/R5)
  - `focusRunningTask` (Running — R6)
  - `focusNeedsYouTask` (Needs-you — R7; identical to `focusRunningTask` in v0)
  - `expandGraveyardTask` (Graveyard — R8)

  The router is a `switch` on lane; each handler is its own function. The user-facing mental model is "click acts on this task per its lane state" — the doc no longer claims a single internal verb (`promote`) since per-lane code paths share no implementation. Three-surface coherence (R12) applies per-handler where the action has a meaningful CLI/MCP equivalent — see R12.

- R2. **Inbox click on a task with project context** writes `status: running` to the .md frontmatter, spawns or focuses a terminal session at the resolved project path via `SessionCoordinator.startOrFocusSession`, and routes column 2 to that session.
- R3. The row's lane migration from Inbox to Running is driven by the file watcher reacting to the frontmatter status change — not by direct UI mutation. The existing spatial-stability animation provides the user-visible feedback.
- R6. **Running click** is idempotent: it routes column 2 to the task's existing terminal session and focuses the cursor. No status flip, no respawn.
- R7. **Needs-you click** behaves identically to Running click (route column 2, focus cursor). v0 ships no auto-scroll or prompt-highlight logic — the user reads the terminal to find context. Lane membership is purely `task.status == .needsYou`; the live `isLikelyPromptingForInput` heuristic continues to drive the per-session `.needsAttention` indicator dot but does **not** auto-flip task status (auto-status-flip is queued with the auto-pilot deferral).
- R8. **Graveyard click** opens a new per-row inline expansion UI (animated chevron + frontmatter chips + first ~8 lines of `.md` body) within column 1. `TaskRowView` does not currently have an expansion affordance — this expansion component is net-new UI for v0. **Column 2 must not be touched** by Graveyard clicks.

**Orphan task triage (Inbox tasks without project context)**

- R4. When a click hits an Inbox row whose .md has neither `project-path` nor a resolvable `project`, the click does **not** silently no-op. Instead, an inline triage card opens in column 1 attached to the row, containing: (a) a project picker populated from `WorkspaceStore.projects`, (b) an optional template picker, (c) an optional title-edit field.
- R5. Confirming the triage card writes `project-path` (and optional `template`) into the .md frontmatter, then proceeds with the standard Inbox-click flow (R2). Cancelling the card writes nothing and leaves the row in Inbox.

**New task creation (layered triggers)**

- R9. The sidebar must offer three triggers that all open the same inline composer: (a) a persistent `[+ Start]` button in the sidebar header, (b) clicking the empty Inbox lane area when Inbox is empty, (c) the `⌘N` keyboard shortcut.
- R10. The composer is rendered inline in column 1 (not a sheet over column 2). Fields: title (required), project picker (required), template picker (optional).
- R11. Confirming the composer creates a new `.md` in `.ghostties/tasks/` with `status: running`, the chosen project and template, and the entered title; the file watcher then drives the row appearance and terminal spawn (same path as R2/R3).

**Three-surface coherence (design intent, not a hard rule)**

- R12. **Design intent, not a blocking rule.** When a click handler performs an action with meaningful data semantics (status flip, file create, frontmatter mutation), it should be designed so a CLI / MCP equivalent exists or could exist with low effort. UI-only gestures (Graveyard expansion, hover-revealed affordances, micro-animations) are explicitly exempt — they have no meaningful CLI/MCP analogue and forcing one creates ceremony without value. Today's MCP surface already exposes `update_task_status` which covers Inbox-promote and orphan-triage status writes; new task creation will need a `task.create` MCP tool when implemented. v0 ships these mappings:
  - `startInboxTask` (R2) → MCP `update_task_status(id, "running")` (already exists). `gt` CLI: planner choice (rename `gt focus` semantics, or add `gt promote`).
  - `triageOrphanTask` (R4/R5) → no direct CLI/MCP equivalent for the modal UX itself; the underlying frontmatter writes are exposed via `update_task_status` + a new `task.set_project` MCP tool (v0-required).
  - `focusRunningTask` / `focusNeedsYouTask` (R6/R7) → pure UI; exempt.
  - `expandGraveyardTask` (R8) → pure UI; exempt.
  - New-task composer (R9–R11) → `gt new` (already exists) and a `task.create` MCP tool (v0-required to ship in parallel).

**Note access (secondary affordance)**

- R13. The .md file is opened externally via `NSWorkspace.shared.open(url)` from two affordances only: (a) the `📝` chip revealed on row hover, (b) the `⌘O` keyboard shortcut on a focused row. The .md is **never** opened on a row click, and **never** rendered inside the Ghostties app in v0.

**Keyboard parity (v0 scope)**

- R14. v0 ships these keyboard shortcuts: `⌘N` (open new-task composer), `⌘O` (open the focused row's .md externally), `Return` (activate the focused row — same effect as a click on it). Row navigation (`j`/`k` etc.) is out of v0 scope.

**Priority slice (minimal prioritization for v0)**

- R15. The frontmatter schema gains a `priority` field with values `high | medium | low | none` (default `none` when absent). Inbox is sorted by `priority desc` (high first), then `created desc` (newest first within the same priority). The richer prioritization brainstorm (next-up indicators, urgency color, deadline-aware sort, learned priors) stays deferred. The `linear-sync` preset's `system.md` is extended to map Linear's native priority field (`Urgent` / `High` → `high`, `Medium` → `medium`, `Low` → `low`, `No priority` → `none`) when writing tasks. The new-task composer (R10) does not surface a priority picker in v0 — manual priority is set by editing the `.md` directly.

---

## Acceptance Examples

- AE1. **Covers R2, R3.** Given an Inbox row with `project-path: ~/Code/ghostties` in its .md, when the user clicks the row, then the .md frontmatter is updated to `status: running`, a terminal session spawns at `~/Code/ghostties`, the row animates from Inbox to Running, and column 2 displays the new terminal with cursor focus.
- AE2. **Covers R4, R5.** Given an Inbox row whose .md has `source: linear` and no `project-path`, when the user clicks the row, then an inline triage card opens in column 1 attached to that row showing a project picker. When the user picks "ghostties" and confirms, the .md is updated to include `project-path: ~/Code/ghostties`, then the standard Inbox-click flow runs (status flips to running, terminal spawns, lane migrates, column 2 routes).
- AE3. **Covers R6.** Given a Running row whose terminal session exists, when the user clicks the row twice in succession, then no new terminal spawns, no frontmatter changes, and column 2 remains routed to the same session.
- AE4. **Covers R8.** Given a Graveyard row, when the user clicks the row, then the row's disclosure expands inline within column 1 showing the .md preview, and column 2's existing contents are unchanged.
- AE5. **Covers R9, R10, R11.** Given Inbox is empty, when the user clicks anywhere in the empty Inbox lane area, then an inline composer opens in column 1 with title/project/template fields. When the user fills in "Refactor sidebar row", picks "ghostties", leaves template blank, and confirms, then a new .md is written to `.ghostties/tasks/` with `status: running`, project: ghostties, title: "Refactor sidebar row", a Running row appears, a terminal spawns at the ghostties project path, and column 2 routes to it.
- AE6. **Covers R13.** Given a row in any lane, when the user hovers the row and clicks the `📝` chip, then the task's .md opens in the OS's default app for `.md` (Obsidian, TextEdit, etc.). Column 2 contents are unchanged. Row status is unchanged.

---

## Success Criteria

- **Human outcome:** Sean can see Inbox tasks ordered by a meaningful priority signal and start any of them with one click — no Obsidian tab explosion, no silent no-ops on Linear-imported tasks, no friction to start something new when Inbox is empty. ("Meaningful priority signal" in v0 = the small priority slice in R15; the richer prioritization brainstorm — next-up indicators, deadlines, learned priors — stays deferred.)
- **Handoff quality:** A downstream implementer reading this doc can build the click handler without inventing per-lane semantics, composer fields, or triage card UI. The implementation seam (`promote(taskId)` as the single internal verb, file-watcher-driven lane migration) is named and bounded.

---

## Scope Boundaries

- **Soft-claim with TTL (idea #3 in the ideation doc)** is deferred to v1+ — the multi-actor coordination primitive isn't load-bearing while the audience is one human. It can be layered on top of `promote(taskId)` later without breaking v0.
- **Workspace context loading (idea #7)** — full task = terminal + branch checkout + editor + linked PR — is deferred. Right direction long-term, wrong shape for v0; most of the surface area (col-3 PR pane, in-app editor) doesn't exist yet.
- **`⌘Z` to abort a just-started task** is deferred. v0 ships **no row-click undo**. Recovery paths after a misclick:
  - `exit` the spawned terminal (kills the session; status stays `running` until the file-watcher migration triggers Graveyard via the surface-close handler).
  - Edit the task's `.md` frontmatter directly to roll status back.
  - `gt done <id>` to archive (no `gt status` subcommand exists today; adding one is a separate decision).
  - Re-clicking the row does **not** undo — per R6, re-click on a Running row is focus-only, not a status revert.

  ⌘Z + a CLI `gt status` (or equivalent) verb are queued for v1+.

- **Rich Graveyard read-mode (col 3 markdown render OR col 2 glow-style render)** is deferred to a separate brainstorm queued under "How should archived task notes render?" — see Outstanding Questions.
- **Richer Inbox prioritization** — next-up indicators, urgency color, deadline-aware sort, learned priors — stays a separate brainstorm. v0 ships the minimal priority slice in R15 (priority field + `priority desc, created desc` sort + Linear-priority mapping in the preset). The richer brainstorm picks up after v0 lands and real Linear-driven volume is observed.
- **Auto-pilot agents pulling from Inbox autonomously.** The technical capability already exists today: the MCP server's `update_task_status` tool lets any external agent write `status: running` to a task without a human click. v0 doesn't ship auto-pilot patterns or presets that exercise this — but the wire is in place. The real deferral is the **safety primitive** (soft-claim with TTL — idea #3 from ideation) that would gate auto-pilot collisions when the audience grows beyond Sean alone. Pickup soft-claim + auto-pilot presets together when (a) audience >1, or (b) auto-pilot loops become a load-bearing pattern.
- **`j`/`k` row navigation and other power-user keyboard** — out of v0. `⌘N`/`⌘O`/`Return` cover the must-haves.
- **Project-as-mode (project view replacing task view)** — already parked in `parked-project-view-mode.md`. Project labels remain row metadata in v0; clicking a project label is not in scope here.

---

## Key Decisions

- **Lane-aware Promote vs. Peek-vs-Commit (VS Code preview-tab pattern):** chose Lane-aware Promote. Sean's reframe — "the sidebar is a queue of work, not references to browse" — picks intent-clarity over browse-safety. The disclosure triangle already serves the peek case; double-click as primary action would dilute the click verb.
- **Bake orphan-triage modal (#5) into v0 vs. defer:** baked in. Linear-imported tasks are the most-broken click today; shipping promote without triage would replace one silent no-op (Obsidian only) with another (no triage prompt either).
- **Layered new-task triggers (header + empty-area + ⌘N) vs. single trigger:** chose Layered. Sean's note: "I won't always have tasks premade and I wouldn't want to create that blocker." Empty Inbox has to be a usable starting point, not a dead state.
- **Editor opens externally vs. in-app .md viewer:** chose external (`NSWorkspace.shared.open`). An in-app md viewer would either live in column 2 (violating the column-2-stays-terminal rule) or column 3 (premature; col 3 is for the browser pane). External keeps v0 small; the "rich render" decision is queued as its own brainstorm.
- **Graveyard read-mode = col 1 inline expand vs. col 3 markdown viewer vs. col 2 glow render:** chose col 1 inline expand for v0. Cheapest, reversible, lets real Graveyard usage inform the richer-view decision.
- **MCP-mirror discipline (#4) shipped vs. enforced as rule:** downgraded to **design intent** — not a blocking code-review rule. UI-only gestures (Graveyard expansion, hover affordances) are exempt; gestures with meaningful data semantics should be mirrored when there's a useful CLI/MCP equivalent. Doc-review pushback (3 reviewers) was that a permanent MUST overconstrains v0 before MCP/CLI have real consumers. The honest framing is: design surfaces should converge over time, but v0 is allowed to ship UI-only behaviors without ceremony.
- **Soft-claim (#3) defer:** deferred. Right primitive, wrong moment for an audience of one.

---

## Dependencies / Assumptions

- **Existing `SessionCoordinator.startOrFocusSession` (async, with resolved-paths cache + 3s timeout)** is reused for all spawn-or-focus paths (R2, R3, R6, R7, R11). Do not regress to a synchronous spawn from the click handler — a prior incident froze the UI on a synchronous `Process.waitUntilExit()` call.
- **Existing `isLikelyPromptingForInput` heuristic** drives the per-session `.needsAttention` indicator dot in `SessionCoordinator`. It does **NOT** drive Needs-you lane membership in v0 — lane membership is `task.status == .needsYou` from frontmatter, written by an agent or by `gt`/MCP. Wiring the heuristic to auto-flip task status is queued alongside the auto-pilot deferral.
- **File watcher on `.ghostties/tasks/*.md`** is the source of truth for row lane membership in v0. Click handlers write to disk; the watcher reflects state. This implies the watcher must be debounced enough to avoid jitter on rapid status changes, but tight enough that a click feels instant. Existing watcher tunings are assumed adequate; verify under load during planning.
- **Permissive `Codable` decode for status** is assumed (per `docs/solutions/logic-errors/codable-enum-raw-value-wipes-state.md`) — strict decode would wipe TaskStore on any unknown future status value. Adding `running` was already done; future lanes must follow the same pattern.
- **Multi-window notification scoping** is assumed (per `phase-4-ghostties-workspace-sidebar-review.md` P1-001). A click in window A must not migrate the same row in window B; status-flip notifications must filter by `coordinator.containerView?.window`.
- **Surface-close race needs `DispatchQueue.main.async` defer** (per the same review doc, P2-004) — when terminal exits and the row should auto-migrate, wrap status-flip handlers in main-async.
- **SwiftUI gesture-order rule** (per `sidebar-code-review-remediation.md`): if double-click is added later (e.g., for inline rename), `onTapGesture(count: 2)` must be declared **before** the count-1 handler or it dies silently. Not relevant for v0 (no double-click), but flagged for future work.
- **`.ghostties/tasks/` directory exists and is writable.** Existing `TasksDirectory.findOrCreate(...)` (recently refactored to be cwd-free per PR #9) handles this.
- **`gt mcp install` and the linear-sync preset** are out of scope for this brainstorm but their existence is what makes orphan-triage (R4/R5) load-bearing — Linear-imported tasks are the highest-frequency orphan-task source.

---

## Outstanding Questions

### Resolve Before Planning

- _(none — Sean explicitly accepted defaults to move to capture; all product decisions are made.)_

### Deferred to Planning

- [Affects R3, R11][Technical] How does the file watcher interact with the click handler to avoid a double-render: click writes status, watcher reads file, sidebar re-renders — is there a path where the click's own UI animation and the watcher-driven re-render race? Likely solved by routing all UI updates through the watcher and treating the click as write-only, but verify the existing event flow during planning.
- [Affects R4, R5][Technical] Triage card UI shape — popover vs inline-expand-into-row vs sheet-attached-to-row. UX intent is "inline in column 1 attached to the row" but the SwiftUI implementation pattern needs a small spike during planning.
- [Affects R10, R11][Technical] Composer file naming — what's the `id` of a newly-created task? UUID? slugified title? Needs a brief check of how existing tasks are named.
- [Affects R12][Technical] How does the existing `gt` CLI map to the new `task.promote` verb? Today `gt` has `new`, `list`, `focus`, `done`, `notes`, `mcp` (no `status` subcommand). The MCP server already exposes `update_task_status` which already does what `task.promote` would do — `task.promote` is a rename / semantic harmonization, not a new feature. Plan must decide whether to introduce `task.promote` as a new MCP tool alongside `update_task_status`, alias one to the other, or just rename in-place.
- [Affects R2, R5, R11][Technical] **macOS `TaskStore` is currently read-only.** The CLI-side `cli/Sources/GhosttiesCore/TaskStore.swift` has write APIs (`Frontmatter.assemble`, `store.write`, `store.create`); the macOS app target does not yet import `GhosttiesCore`. Plan must choose: (a) build write APIs into the macOS `TaskStore` directly, or (b) link `GhosttiesCore` into the macOS app target via the existing `XCLocalSwiftPackageReference`. Both have non-trivial integration cost.
- [Affects R8][Technical] `TaskRowView` does not currently have an expansion affordance (no `DisclosureGroup`, no per-row expand state). The Graveyard inline-expand UI is net-new — plan must specify the SwiftUI shape (custom expansion w/ animated chevron, or `DisclosureGroup` wrapper).
- [Affects all Inbox/Running/Needs-you click paths][Needs research] What's the existing keyboard focus behavior on column 1 row navigation? Required for R14's `Return = activate focused row` behavior.

### Queued as separate brainstorms (not blocking v0)

- _"Richer Inbox prioritization"_ — next-up indicators, urgency color, deadline-aware sort, learned priors. (v0 ships the minimal slice in R15.)
- _"How should archived task notes render?"_ — col 1 inline (current v0) vs col 3 markdown viewer vs col 2 glow-style terminal render. Decision based on real Graveyard usage data.
- _"Soft-claim with TTL"_ (#3 from ideation) — multi-actor coordination primitive. Pickup when audience >1 or auto-pilot agents become real.

### From 2026-04-25 review (ce-doc-review pass)

Appended after the Q1–Q5 walkthrough resolved the highest-impact correctness and strategic findings. The items below were flagged by reviewer agents (coherence, feasibility, product-lens, design-lens, scope-guardian, adversarial) and accepted as Deferred-to-Planning rather than walked through individually. Planner should resolve before/during implementation.

**Operational gaps (need design or technical decisions during planning):**

- [Affects R2, R5, R11][Technical] **Disk-write failure error states.** Frontmatter write fails (permissions, full disk, iCloud sync conflict, atomic-rename failure). v0 specifies no UX. Click handler should surface a toast or row-level error chip; otherwise the failure recreates the silent-no-op pattern this doc was written to fix.
- [Affects R3, R6][Technical] **Click-during-animation race.** User clicks an Inbox row, then clicks the same row (or another) before the watcher migrates lanes. The second click sees the row as still-Inbox and may re-fire `startInboxTask`. Specify a guard: debounce per `taskId` until the file watcher confirms the new status, or disable the row's click target during the migration animation window.
- [Affects R4, R10][Design] **Empty `WorkspaceStore.projects` is a first-run dead-end.** Both orphan triage and the new-task composer require a project picker. First-run user with no projects has no in-flow path to add one. Empty-state UX needed (e.g., "+ Add project" affordance inside the picker).
- [Affects R1][Technical] **Backlog and Review lane click semantics are unspecified.** MEMORY.md notes the v0 sidebar has lanes Inbox · Backlog · Running · Needs-you · Review · Graveyard. R2/R6/R7/R8 cover Inbox/Running/Needs-you/Graveyard. Backlog and Review are absent. Plan must specify (likely: Backlog click behaves like Inbox; Review click behaves like Graveyard with a richer expansion).
- [Affects R4, R5, R10][Design] **Spatial mechanics of triage card, composer, and disclosure expansion.** "Inline in column 1 attached to the row" doesn't specify push (rows below reflow down) vs. overlay (z-axis above other rows) vs. replace (row becomes the card temporarily). All three feel different. Needs a UX-level decision before SwiftUI implementation.
- [Affects R9][Design] **`[+ Start]` button placement and visibility rules.** "In the sidebar header" is ambiguous: above all lanes (sticky), inside Inbox lane only, scrollable vs. pinned. Specify position, scroll behavior, and visibility when sidebar is in non-Inbox-focused states.
- [Affects sidebar UI in general][Design] **Empty states for Running / Needs-you / Graveyard / all-empty.** Only empty Inbox is covered (R9b). Specify visual treatment for each empty lane: collapsed, hidden, or quiet placeholder. The all-empty first-run state needs an explicit onboarding path.
- [Affects R10][Design] **Required project picker in composer creates friction.** v0 marks project picker required. Title-only composer with cwd-default may be sufficient for "no friction to start something new" success criterion. Plan can either: (a) keep required, (b) make optional with cwd default, (c) keep required but pre-select most-recently-used project.
- [Affects R3 + multi-window][Technical] **Multi-window watcher race.** File watcher is per-process. Window B's watcher will migrate the row to Running when window A writes status:running, but window A's terminal session lives in window A's `SessionCoordinator`. Click in window B on the now-Running row tries to focus a session that doesn't exist in B. Specify whether the click in B re-spawns, queries A via IPC, or shows a "this task is running in another window" affordance.
- [Affects R6][Technical] **Killed/exited terminal during idempotent Running click.** R6 says click routes column 2 to "the task's existing terminal session." If the user typed `exit` or the session crashed but the surface-close handler hasn't fired yet (or the status is still `running` but no live `SurfaceView` exists), click on the Running row finds nothing to focus. Plan must specify: respawn? show error? auto-migrate to Graveyard immediately?
- [Affects existing fixtures][Technical] **Status migration of existing tasks.** 12 fixture tasks exist on `feat/task-first-sidebar-v0` with various statuses. Plan should audit fixtures, decide whether they need a one-time migration (e.g., `inbox` stays as-is; tasks created with old default may need rewriting), and whether new statuses (`running`) introduced by v0 require any backward-compat handling.

**FYI / advisory observations (low impact, can be addressed during implementation or skipped):**

- [Editorial] R4/R5 logically belong inside the "Click semantics (lane-aware dispatch)" subsection, not a separate "Orphan task triage" subsection — the orphan case is one of the lane-aware variants. Restructure when polishing the doc.
- [Accessibility] VoiceOver labels for row click action, `📝` chip, disclosure expansion, `[+ Start]` button, and inline composer fields are absent. Add during implementation; reduced-motion behavior for the spatial-stability animation also needed.
- [Discoverability] `⌘N` / `⌘O` / Return shortcuts ship with no specified discovery surface (menu bar items, tooltips, onboarding hint). Contradicts A1's "UI-discoverable interactions over hidden ones" preference. Add tooltips on `[+ Start]` button (`⌘N`) and on the `📝` chip (`⌘O`) at minimum.
- [Microcopy] Triage card heading, composer heading, button labels (`[▶ Start]` vs `[▶ Assign + Start]` for triage), error states all need copy decisions during implementation.
- [Editorial] Prior art citations (VS Code preview tab, PagerDuty, Ableton) in the brainstorm conversation are rhetorical, not load-bearing — the actual constraint is "peek without commit already has a widget (disclosure / inline expansion); the primary click doesn't need to serve that purpose." Doesn't appear in the doc itself, so no edit needed.
- [Edge case] Re-click on an already-expanded Graveyard row: toggle to collapse? No-op? Implementer choice; likely toggle, but specify in the inline-expansion component spec.
- [Edge case] Title collision / concurrent composers: two `⌘N` presses, or `⌘N` + empty-area click both opening composers simultaneously. Likely guard: only one composer open at a time, second trigger focuses the existing composer.
- [Doc accuracy] Dependencies/Assumptions cites "Permissive Codable decode for status" via `docs/solutions/logic-errors/codable-enum-raw-value-wipes-state.md`. The macOS `TaskStore` actually parses `TaskStatus` via `TaskStatus(rawValue:)` (strict-with-skip) — not a Codable path. Adding `running` is fine, but the cited mitigation pattern doesn't apply. Update the dependencies bullet during planning if a new lane is added later.
- [Trajectory] When Workspace Context Loading (#7 from ideation, deferred) eventually ships, this v0 commits to "click is the row's primary verb" — future Workspace Context Loading either replaces what click means (breaks muscle memory) or ships on a different gesture (modifier-click, double-click, separate target). Worth a paragraph in the next brainstorm that picks up #7.
- [Identity] "Click = start a terminal session" positions Ghostties closer to Raycast / Warp's command-surface ethos than to Linear's triage queue or Obsidian's notes-with-actions. Implicit positioning bet; not a finding to fix, but a decision to be aware of when feature debates arise later.

---

## Next Steps

→ `/ce-plan` for structured implementation planning.
