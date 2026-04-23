# PR description drafts

Written 2026-04-23 overnight. Value-first PR bodies for each branch. Paste into `gh pr create` or the GitHub UI.

---

## `feat/task-first-sidebar-v0` → main

**Title:** Task-first sidebar v0: file-watching and row-click wiring

**Body:**

```markdown
## What this does

Turns the Concept F sidebar skeleton into a working data browser. Editing a `.ghostties/tasks/*.md` updates the sidebar live; clicking a row opens its `.md` in the default editor and switches the terminal to the task's project.

## Why

The v0 sidebar shipped last week rendered fixtures but clicks did nothing. This is the moment the sidebar stops being a pretty render and starts being a working tool.

## Changes

- `TaskFileWatcher.swift` — `DispatchSourceFileSystemObject` on `.ghostties/tasks/` with 150ms debounce, handles dir recreation
- `TaskRowView.onTapGesture` — opens `.md` via `NSWorkspace`, calls `SessionCoordinator.focusLastSession(forProject:)` for terminal switch

## Test plan

- [ ] Toggle Task View (⌘⇧V)
- [ ] Click any row — `.md` opens in editor
- [ ] Edit a task `.md` externally — sidebar updates within ~150ms
- [ ] Delete a task `.md` — row disappears
```

---

## `feat/sidebar-polish-v0` → main

**Title:** Sidebar polish: truncation, glyph color, zone rules, empty state

**Body:**

```markdown
## What this does

Four cosmetic polish commits that compound the crafted feel of the task-first sidebar.

## Changes

- Row metadata tail-truncates and drops `filesStaged` when `project + branch > 20` chars (no more "7 fi…")
- Project glyph desaturated `#7cb342` → `#8aa96a` (muted sage against warm chrome)
- NEEDS YOU header flanked by horizontal rules (matches the design mock)
- Empty state "No tasks in the graveyard." when all four lanes empty

## Non-functional

No behavior changes. Pure styling and empty-state wording.

## Test plan

- [ ] Visual diff vs prior build
- [ ] NEEDS YOU header: rules render on both sides
- [ ] Graveyard: force-empty by moving all fixtures out of graveyard lane, verify empty state
```

---

## `feat/gt-cli-v0` → main

**Title:** `gt` CLI: terminal-native task manipulation

**Body:**

````markdown
## What this does

Ships the second of the three-surface architecture (sidebar + CLI + MCP). `gt` reads/writes the same `.ghostties/tasks/*.md` files the app reads.

## Subcommands

- `gt new <title>` — create a task `.md`
- `gt list` — print tasks with tty-aware color
- `gt focus <id>` — write `.ghostties/.focus` with a focused task id
- `gt done <id>` — move to graveyard (status: done)
- `gt notes append <id> "…"` — append a timestamped bullet to the task's Notes section

## Install

```bash
cd cli && swift build -c release
cp .build/release/gt /usr/local/bin/gt
# or alias to ghostties-gt if conflicting with git-town
```
````

## Schema additions (from stacked parity work)

- `--project-path <path>` flag + frontmatter field
- `--template <name>` flag + frontmatter field

## Test plan

- [ ] `swift test` — 47 tests pass (on `feat/automated-testing-v0`, merged after)
- [ ] Manual smoke: create → list → notes append → focus → done

````

---

## `feat/ghostties-mcp-server-v0` → main

**Title:** Ghostties MCP server: 9+ tools for agent-driven task state

**Body:**

```markdown
## What this does

Third surface of the three-surface architecture. Stdio JSON-RPC 2.0 server exposing the task state to any MCP-capable agent (Claude Code, Cursor, aider). Same `.ghostties/tasks/` files the sidebar + `gt` CLI use.

## Architecture

Extracted shared `GhosttiesCore` library from the CLI work — `gt` and `ghostties-mcp` both consume the same types. Zero duplication across the two binaries.

## Tools exposed

- `list_tasks`, `get_task`, `create_task`, `update_task_status`, `get_active`, `get_needs_you`, `read_task_notes`, `append_task_notes`, `get_inbox`
- `write_session_notes` (via stacked branch) — bulk session summary with timestamped header

## Install + Claude Code config

```json
{
  "mcpServers": {
    "ghostties": {
      "command": "/usr/local/bin/ghostties-mcp",
      "args": ["--tasks-dir", "/path/to/.ghostties/tasks"]
    }
  }
}
````

## Test plan

- [ ] `cli/scripts/smoke-mcp.sh` — all assertions pass
- [ ] `swift test` — `GhosttiesMCPTests/MCPProtocolTests` all green
- [ ] Manual: wire into Claude Code, call `list_tasks` from a live session

````

---

## `feat/automated-testing-v0` → main

**Title:** Automated test suite + GitHub Actions CI

**Body:**

```markdown
## What this does

Unit test coverage for the three-surface architecture + CI workflow to keep it green.

## Coverage

- **47 Swift Package tests** in `cli/Tests/`:
  - `GhosttiesCoreTests` — frontmatter, TaskStore, TasksDirectory, cross-surface coherence
  - `GhosttiesMCPTests` — JSON-RPC protocol + all 9 tools
- **13 macOS XCTests** in `macos/Tests/Ghostties/`:
  - `TaskModelTests` — parser + schema
  - `TaskFileWatcherTests` — debounce, dir recreation, filesystem events

## CI

`.github/workflows/test-ghostties.yml` — runs `swift test` and `xcodebuild test` on push + PR. Named `test-ghostties.yml` to avoid colliding with upstream's `test.yml`.

## Critical test

`CrossSurfaceCoherenceTests` is the schema contract — if `gt` CLI, MCP server, and macOS parser ever drift on frontmatter keys, this fails loudly.

## Test plan

- [ ] CI green on push
- [ ] Local: `cd cli && swift test` — 47 pass
- [ ] Local: `cd macos && xcodebuild test` — 13 pass
````

---

## `feat/ui-automation-v0` → main

**Title:** XCUITest smoke for Task sidebar (IDE-only)

**Body:**

```markdown
## What this does

Single XCUITest that boots the app, toggles Task View (⌘⇧V), asserts NEEDS YOU / ACTIVE / GRAVEYARD zones render. Gated to Xcode IDE only — matches the existing `GhosttyWorkspaceUITests` / `GhosttyTitleUITests` skip-gate pattern.

## Why IDE-only

CLI `xcodebuild test -only-testing:GhosttyUITests/...` hangs before runner-connection. Known consequence of bundle ID collision (`/Applications/Ghostties.app` + debug build + 8 backup bundles all share `com.mitchellh.ghostty`). Fixed by `feat/dev-environments-v0` which lands separately.

## Test plan

- [ ] Run from Xcode Test Navigator
- [ ] Once `feat/dev-environments-v0` lands: wire into CI workflow
```

---

## `feat/task-start-terminal` → main

**Title:** Click to start: spawn terminals + Claude Code templates on task click

**Body:**

````markdown
## What this does

Two waves of click-behavior enhancement that complete Phase 1's stretch goal.

**Wave 1 — session spawn:**

- Adds `project-path` frontmatter field (kebab-case) — optional explicit path per task
- `SessionCoordinator.startOrFocusSession(forProjectNamed:rootPath:)` — wraps existing `createQuickSession` to either focus an existing session or spawn a fresh one at the task's cwd
- `TaskRowView.handleTap` calls the new method

**Wave 2 — templates:**

- Adds `template` frontmatter field — optional launch template override per task
- `@AppStorage("ghostties.defaultTaskTemplate")` — user-level default (empty = no preference)
- Resolution chain: task frontmatter > user default > existing fallback
- "Orchestrator" template already ships as a built-in (`AgentTemplate.defaults`)

## User action

```bash
defaults write com.mitchellh.ghostty ghostties.defaultTaskTemplate "Orchestrator"
```
````

Then click any task row → Claude Code launches with orchestrator prompt at project root. Case-insensitive match.

## Fixtures

12 fixture tasks backfilled with `project-path`. 3 fixtures include `template: orchestrator` to exercise the explicit-override path.

## Test plan

- [ ] Click a task whose project has no live session → terminal spawns with correct template + cwd
- [ ] Click a task whose project has a live session → existing session focuses
- [ ] Click a task with `template: orchestrator` → Claude Code launches regardless of user preference
- [ ] Click a task without a `template:` field + no user preference → default Shell (existing behavior)
- [ ] Click a task with a bogus template name → stderr warning, falls back to default

````

---

## `feat/dev-environments-v0` → main

**Title:** Phase 4 Part 1: Debug bundle ID split

**Body:**

```markdown
## What this does

Splits the Debug build's bundle ID from Release so the dev build can run concurrently with `/Applications/Ghostties.app`. Resolves Fragile Areas #1 (bundle ID collision) and #9 (shared `workspace.json`) for the Debug path.

## Changes

- Debug config `PRODUCT_BUNDLE_IDENTIFIER` → `com.seansmithdesign.ghostties.dev`
- Debug config display name → `Ghostties Dev` (shows in Dock, menu bar, TCC prompts)
- Application Support directory partitioned by bundle ID (Debug and Release no longer share `workspace.json`)

## What this does NOT do

- Release bundle ID stays `com.mitchellh.ghostty` pending Developer ID cert decision
- DMG pipeline (Phase 4 Part 2) still blocked on 9 GitHub secrets

## Test plan

- [ ] `xcodebuild build -configuration Debug ONLY_ACTIVE_ARCH=YES ARCHS=arm64` — clean
- [ ] `open macos/build/Debug/Ghostties.app` — launches, doesn't kick out daily driver
- [ ] Dock shows "Ghostties Dev" label
- [ ] `defaults read com.seansmithdesign.ghostties.dev` shows new domain after first run
- [ ] `/Applications/Ghostties.app` still launches independently
- [ ] `tccutil reset All com.seansmithdesign.ghostties.dev` resets debug permissions (if needed)
````

---

## Session-hybrid branches (if landed separately)

**Title:** Session-hybrid v1: terminal sessions as first-class sidebar rows

**Body:** (paste the summary from `design-session-hybrid.md` plus the shipped commit list)

---

## `gh pr create` one-liner

When you're ready to land a branch, the shortest path is:

```bash
git checkout <branch>
gh pr create --title "..." --body "..." --base main --head <branch>
```

Or use `/ce-commit-push-pr` which drafts the body and opens the PR in one step.
