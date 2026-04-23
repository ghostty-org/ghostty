# v0 Task-First Sidebar — Build Status

> Branch: `feat/task-first-sidebar-v0`
> Started: 2026-04-22T22:30:00Z
> Target: Concept F sidebar visible behind a feature toggle, rendering 12 fixture tasks, no external integrations.

## Waves

### Wave 1 — Foundation (in progress)

- [ ] Codebase integration map (research agent)
- [x] Fixture data in `.ghostties/tasks/` (12 tasks)
- [x] This status tracker

### Wave 2 — Implementation (pending)

- [x] TaskModel + TaskStore (reads fixtures)
- [x] Concept F SwiftUI views (Row, Zones, Sidebar)
- [ ] WorkspaceLayout integration behind feature toggle

### Wave 3 — Polish (pending)

- [ ] Spatial stability verification
- [ ] Terracotta discipline check
- [ ] Build + launch smoke test

## Morning test path

1. Pull branch: `git pull origin feat/task-first-sidebar-v0`
2. Open Xcode: `open macos/Ghostties.xcodeproj`
3. Build + run (⌘R)
4. Open Ghostties Settings → flip the Task View toggle
5. Confirm Concept F renders with fixture data

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
