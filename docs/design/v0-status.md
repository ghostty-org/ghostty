# v0 Task-First Sidebar — Build Status

> Branch: `feat/task-first-sidebar-v0`
> Started: 2026-04-22T22:30:00Z
> Target: Concept F sidebar visible behind a feature toggle, rendering 12 fixture tasks, no external integrations.

## Waves

### Wave 1 — Foundation (complete)

- [x] Codebase integration map (research agent)
- [x] Fixture data in `.ghostties/tasks/` (12 tasks)
- [x] This status tracker

### Wave 2 — Implementation (complete)

- [x] TaskModel + TaskStore (reads fixtures)
- [x] Concept F SwiftUI views (Row, Zones, Sidebar)
- [x] WorkspaceLayout integration behind feature toggle
- [x] Menu item + keyboard shortcut (View → Task View, ⌘⇧V)
- [x] Release build + launch smoke test

### Wave 3 — Polish (pending — morning session)

- [ ] Spatial stability verification (visual)
- [ ] Terracotta discipline check (visual)
- [ ] Empty-state and populated-state screenshots

## Morning test path

Exact steps to flip the new sidebar on:

1. Launch the built app:
   ```
   open /Users/seansmith/Code/ghostties/macos/build/Build/Products/Release/Ghostties.app
   ```
   (Or double-click Ghostties.app in that folder.)
2. A terminal window opens with the existing project-first sidebar (220pt wide).
3. In the menu bar: **View → Task View** — or press **⌘⇧V**.
4. The sidebar swaps to the Concept F task-first view (280pt wide), animated over ~0.2s.
   - Expect three stacked zones: NEEDS YOU (hero rows, terracotta emphasis),
     ACTIVE (compact rows + empty slot placeholders), ARCHIVE (Inbox · Backlog ·
     Review · Done lane headers only), plus a muted footer ("3 sources · linear · gh · sentry").
   - The 12 fixture tasks load from `.ghostties/tasks/*.md`.
5. Press **⌘⇧V** again (or click the menu item) to toggle back. The checkmark in
   the menu reflects the current mode.

The chosen mode is persisted in UserDefaults (`ghostties.sidebarViewMode`), so
the next launch opens in whichever mode was last selected.

## Where the toggle lives

- **Menu:** View → Task View (inserted below the existing workspace items).
- **Keyboard:** ⌘⇧V (Cmd+Shift+V). No existing command claims this combo.
- **Defaults key:** `ghostties.sidebarViewMode` — string, `"projectFirst"` (default) or `"taskFirst"`.
- **Notification:** `workspaceSidebarViewModeChanged` — observed by every
  `WorkspaceViewContainer`, so multiple windows re-skin in sync.

## Known issues

- **SourceKit red squiggles.** After pulling the branch, Xcode's editor may show
  red underlines under `TaskStore`, `TaskSidebarView`, etc. until it finishes
  re-indexing. The command-line build is clean (`** BUILD SUCCEEDED **`). Give
  Xcode ~30s after opening, or do a Product → Clean Build Folder once if the
  indexer seems stuck.
- **Fixture data only.** Clicking task rows in the new sidebar does not yet
  context-switch the terminal (no `SessionCoordinator` wiring in v0). The store
  is read-only and loads once on init.
- **No per-window toggling.** The flag is app-global. All open windows swap
  modes together.
- **Existing sidebar behavior preserved.** Closed/overlay/pinned modes all work
  in both views; the width constant is picked via `currentSidebarWidth`.

## Known v0 limitations

- Fixture data only; editing tasks does not persist
- No MCP, no Linear/GitHub/Sentry integration
- No `gt` CLI
- No peek overlay, no browser escalation
- Project-first view remains the default; toggle opts in

## Log

- 2026-04-22T22:30:00Z — Wave 1 started
- 2026-04-23T06:03:00Z — Fixtures created (12 files in `.ghostties/tasks/`)
- 2026-04-23T06:05:00Z — Status tracker created
- 2026-04-22T23:15:00Z — Wave 2: TaskModel + TaskStore landed; build green
- 2026-04-22T23:20:00Z — Wave 2: Concept F SwiftUI views landed (TaskRowView, SlotPlaceholderView, NeedsYouZoneView, ActiveZoneView, ArchiveZoneView, TaskSidebarView); Release build green (commit fc832e012)
- 2026-04-22T23:24:00Z — Wave 2 complete: toggle wired into WorkspaceViewContainer + AppDelegate (View → Task View, ⌘⇧V). Release build green; launch smoke test passed.
