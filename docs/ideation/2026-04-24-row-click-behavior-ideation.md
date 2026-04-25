---
date: 2026-04-24
topic: row-click-behavior
focus: What should happen when a user clicks a task row in the Ghostties task-first sidebar? Designer intent — click should mean "pick this up and start working," not "look at it."
mode: repo-grounded
---

# Ideation: Row-Click Behavior in the Task-First Sidebar

## Grounding Context

**Codebase context.** Click handler in `TaskRowView.swift:75-132`. Today: opens the task's `.md` via `NSWorkspace.shared.open` (which goes to whatever app the user has set as default — Obsidian, etc.) AND calls `coordinator.startOrFocusSession` (silently no-ops when the task lacks a resolvable project path). `SessionCoordinator.startOrFocusSession` is async with a resolved-paths cache + 3s timeout. Two-layer architecture: `TaskStore`/`WorkspaceStore` own persistence, `SessionCoordinator` owns runtime. `TaskItem` already carries `project`, `project-path`, `template`, `sourceTaskId`, `source` in frontmatter.

**Past learnings (`docs/solutions/`).** SwiftUI gesture-order (count:2 must precede count:1, or it dies silently). Async `createSession` with the resolved-paths cache + 3s timeout must stay (a prior synchronous spawn froze the UI). Multi-window notification scoping is required for cross-window safety. Surface-close race needs `DispatchQueue.main.async` defer. Codable status field MUST decode permissively with a safe default — strict decode wipes TaskStore on unknown values. Reuse the existing `isLikelyPromptingForInput` heuristic for the Needs-you signal; do not invent a parallel detector.

**External prior art.** VS Code preview-tab pattern (single-click = italicized preview, double-click = pin) is a widely-debated but established "peek without committing" pattern. PagerDuty Acknowledge/Resolve splits inspect from claim — clicking a row inspects, an explicit Acknowledge button claims ownership. Ableton launch quantization separates intent from execution (click registers, fires at next safe boundary). Distributed-systems pull-claim gives reversible TTL ownership. Linear is actually click-to-preview-panel + `S` keyboard for Start, not click-to-start. Airflow postmortems: no-op clicks cause repeated frustrated clicking — every click must give visible feedback.

**Multi-actor signal.** Today's tools have not solved "human and agent both might claim the same task." Warp avoids it by not letting humans click-to-start at all. Linear avoids it by giving the human authority over click semantics. Ghostties' agent-as-middleman pivot means this collision will arrive — the design should leave a primitive open for it.

**Anti-patterns to avoid.** Click-to-activate with no undo (Airflow frustration). Double-click as primary action (hidden, low affordance). Status conflation between human and agent owners. Hover-to-start (accidental triggers).

## Ranked Ideas

### 1. Click = Lane-aware Promote (single internal verb, lane decides effect)

**Description:** A click is the row's primary verb: _promote_. Internally, one function `promote(taskId)` writes the appropriate frontmatter mutation; the lane the row currently sits in decides what "appropriate" means.

- **Inbox / Backlog** → set `status: running`, spawn-or-focus terminal at the project's path, animate the row to the Running lane.
- **Running** → focus that task's existing terminal session (idempotent).
- **Needs-you** → focus the terminal where the agent waits (reuse `isLikelyPromptingForInput` signal).
- **Graveyard** → read-mode (open detail / notes; no spawn).

The `.md` is _not_ opened on click. It becomes a hover-revealed chip and a `⌘O` keyboard shortcut. The disclosure triangle (already on rows) stays as the peek-without-committing affordance.

**Rationale:** Monosemantic with intent — "I'm picking this up." Self-documenting (the lane _is_ the affordance). One internal verb makes `gt promote TASK_ID` and an MCP `task.promote` tool trivially mirror the GUI — three-surface coherence is free. The status flip is the mechanical proof of progress, leveraging the existing spatial-stability animation as the primary feedback signal. Solves the "every click opens another Obsidian tab" problem cleanly.

**Downsides:** Different click effect per lane — users have to learn the model. Mitigated because the model is "obvious next thing for this state," and the visual lane migration teaches it on the first click. No first-class undo for the spawn — a misclicked Linear task spawns a process. Solved partially by lane-aware behavior (Running click is idempotent), partially by adding `⌘Z` to abort a just-started task in v1.

**Confidence:** 80%
**Complexity:** Low (refactor `handleTap()` in `TaskRowView.swift` into a `promote()` call; add a hover button for note-open; teach the existing `coordinator.startOrFocusSession` path the orphan-task branch — see #5).
**Status:** Explored

---

### 2. Click = Inline Expand, Double-click = Activate (Peek vs. Commit)

**Description:** A single click expands the row in-place — frontmatter chips, full description, last activity, action buttons. Double-click activates (spawns terminal). The disclosure triangle becomes redundant and is removed.

**Rationale:** Solves "I just wanted to peek" cleanly — no side effects from a glance. Maps to VS Code's preview-tab pattern. Double-click as the _escalated_ action is acceptable per the SwiftUI gesture-ordering precedent already in the code.

**Downsides:** Diverges from the designer's reframe (the sidebar is a queue of work, not references to browse). This puts browsing first. Double-click is harder to discover. Adds inline-expansion chrome to every row, fighting the v0 spatial-stability calmness.

**Confidence:** 50%
**Complexity:** Medium
**Status:** Unexplored

---

### 3. Click = Soft-Claim with TTL (multi-actor coordination primitive)

**Description:** A click writes both the lane-aware promote effect AND a soft-claim: `claimed-by: sean@hostname`, `claimed-at: <ts>`. Visible across surfaces. Auto-releases after N minutes of idle, or explicitly on `gt release` / second click. An agent attempting to claim a task already claimed by a human surfaces a polite "Sean is on this — interrupt? [y/N]" instead of a silent collision.

**Rationale:** Today's tools have not solved human-agent shared-pool coordination. Building the claim primitive _now_, while there's only one human user, costs almost nothing and compounds enormously when (a) multi-window operation becomes real, (b) auto-pilot agents pull from inbox autonomously, (c) team mode arrives.

**Downsides:** v0 audience is Sean alone — immediate value is near zero. Frontmatter field whose lifecycle is non-trivial (TTL expiration, race on simultaneous claim). Could be added later without breaking #1 — argument for _not_ shipping now.

**Confidence:** 60% (right primitive, wrong moment for v0)
**Complexity:** Medium
**Status:** Unexplored

---

### 4. MCP-Mirror Discipline (architectural rule, not a click model)

**Description:** Every click action MUST have a JSON-RPC equivalent in the MCP server. The sidebar is a thin client over the MCP verb set. `task.promote(id)` is the verb; the click is one of four equal entry points (mouse, keyboard, CLI, MCP).

**Rationale:** The agent-as-middleman pivot means the user might _be_ an agent (driving Ghostties via MCP from another agent loop). If clicks define behaviors that have no RPC equivalent, agent-users hit a feature wall. This rule keeps every UI gesture scriptable and testable.

**Downsides:** Not a click model in itself — composes with whichever model wins. Adds a discipline overhead.

**Confidence:** 75% (as a rule, not a feature)
**Complexity:** Low — discipline / spec, not code
**Status:** Unexplored

---

### 5. First-click on Orphan Task = Triage Modal (targeted fix)

**Description:** Most tasks click straight through to #1's promote behavior. Linear/GitHub-imported tasks that arrive in Inbox without a `project-path` instead open a lightweight in-sidebar triage card on first click: pick a project from `WorkspaceStore.projects`, optionally pick a template, optionally edit title. Confirm writes `project-path` to frontmatter; subsequent clicks behave normally.

**Rationale:** The "agent imports from Linear, lands in Inbox, has no project context" path is the most-frequent painful click today (silent no-op on terminal side, just opens external editor). Every Linear-sourced task hits this exactly once, then never again.

**Downsides:** Adds a new piece of UI (the triage card). Mistake-prone if user assigns wrong project, but recoverable by editing the .md.

**Confidence:** 80%
**Complexity:** Medium — small modal/popover view, project picker, frontmatter writeback
**Status:** Unexplored

---

### 6. Click = Focus Session, Editor as Hover Affordance (a more conservative #1)

**Description:** Same as #1 but stripped to the bone: click only spawns/focuses the terminal session (one verb, no lane-awareness). The .md never opens from a row click — instead, the focused session shows a small "edit notes" affordance in its chrome, plus a row-hover `📝` button.

**Rationale:** Smallest possible diff that gets the designer's primary outcome.

**Downsides:** Same click behavior in all lanes is more uniform but less useful — Graveyard click would still spawn a terminal, which is wrong. Probably a stepping-stone to #1, not a destination.

**Confidence:** 65%
**Complexity:** Very low — ~30 lines in `TaskRowView.handleTap()`
**Status:** Unexplored

---

### 7. Workspace Context Loading (stretch)

**Description:** A click loads a full task context: terminal session at the project root, editor opened to linked files (from frontmatter), git branch checked out, agent template applied, linked PR in browser pane. Click = workspace switcher.

**Rationale:** The highest-leverage end state — once context-load is a click, every future content type (browser pane, simulator, design tool) plugs into the same primitive.

**Downsides:** Heavy. Requires checking out branches (potentially destructive), opening editors (which one? where?), browser panes (no browser yet). v0 doesn't have most of this surface area.

**Confidence:** 35% (right direction, wrong year)
**Complexity:** High
**Status:** Unexplored

## Rejection Summary

| #   | Idea                                         | Reason rejected                                                                                 |
| --- | -------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 1   | The No-Op Row                                | Removes click signal entirely; Airflow data shows no-op clicks cause frustrated repeat-clicking |
| 2   | Hover-to-Start                               | Triggers on accidental cursor passes; cost of accidental terminal spawn is real                 |
| 3   | Read-Only Sidebar (CLI-only)                 | Fights the sidebar's existence; regresses the v0 "feel real" investment                         |
| 4   | Status from Filesystem Signals               | Spatial-stability animation requires discrete transitions, not gradients                        |
| 5   | Click = Archive (provocative)                | Inverts user model so wildly the dismissal cost is high; misclicks are catastrophic             |
| 6   | Tasks Are Addressed, Not Clicked             | Removes the GUI; product is sidebar-first by design                                             |
| 7   | Continuous Lane Drift                        | Ambient sort fights the explicit status semantics agents/CLI/MCP need                           |
| 8   | Click = Hand to Resident Agent               | "Resident agent" doesn't exist yet; premature for v0                                            |
| 9   | Click = Approve the Agent's Pick             | Agent-as-prioritizer not built; pivot was agent-as-middleman, not orchestrator                  |
| 10  | Click = Speak to the Task (composer)         | Adds heavy input modality on top of an unsolved click model                                     |
| 11  | Source-Typed Click                           | Users can't predict polymorphic-by-source behavior; too clever                                  |
| 12  | Long-Press / Press-and-Hold                  | Hidden gestures with no macOS precedent in list rows                                            |
| 13  | Click = Telemetry-First                      | Logging is great infra but doesn't define click behavior                                        |
| 14  | Click = Open Notes (terminal as side-effect) | Inverts designer intent ("terminal is the work, .md is plumbing")                               |
| 15  | Click = Resume Where You Left Off            | Per-row memory adds state without proportional value                                            |
| 16  | Click = Focus Session, Cmd-Click = Edit      | Modifier-click for a primary-importance action                                                  |
| 17  | Sticky Selection + Action Bar                | Selection chrome is heavy; doesn't fit the sidebar's calmness                                   |
| 18  | Two-Stage Commit (press-and-hold)            | Hidden gesture; macOS doesn't establish this for list rows                                      |
| 19  | Hook-Then-Act (radar)                        | Elegant analogy but more affordances than v0 needs                                              |
| 20  | Bump-the-Ticket (KDS)                        | Same as #1 survivor (folded in)                                                                 |
| 21  | Paddle + Gavel (auction)                     | Same coordination need as #3 survivor; folded in                                                |
| 22  | Call the Cue (theatre)                       | Keyboard-modal "GO" call doesn't match macOS norms                                              |
| 23  | Strip Bay Drag (ATC)                         | Drag is high-friction for a primary action                                                      |
| 24  | SBAR Two-Step Handoff                        | Future feature on top of #3, not a click model                                                  |
| 25  | Reporter + Editor Veto                       | Future composability on top of #3                                                               |
| 26  | Add-to-Queue vs. Play-Next (Spotify)         | "Queueing" isn't a sidebar concept yet                                                          |
| 27  | Click = Bind to Quartet (kbd+CLI+MCP)        | Folded into #4 survivor                                                                         |
| 28  | Click-as-Filter-Pivot                        | Valuable at 1000 tasks; v0 target is 2-4 active typical                                         |
| 29  | The Empty-State Cursor                       | Nice empty-state design; not a click-model decision                                             |
| 30  | Focus-Beam Multi-Monitor                     | Multi-window is a future concern                                                                |
| 31  | Soft-Click 30s Undo Lane                     | Shadow-path buffering of agent side-effects is expensive infra                                  |
| 32  | The Single Daily Click                       | Folded into #1 survivor (promote = single primary verb)                                         |
| 33  | No-Click / Keyboard-Only                     | Keyboard parity is a design _principle_, not the click model itself                             |
