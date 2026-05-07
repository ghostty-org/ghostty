# Ghostties Sidebar — Six-Zone Layout Mock

ASCII reference for the six-zone parity layout. Zone order locked by the brief:
Inbox · Backlog · Active · Needs You · Review · Graveyard.

---

## Sidebar with content in all zones

```
┌─ GHOSTTIES SIDEBAR (280pt) ───────────────────────┐
│                                   [ + Start ]      │
├────────────────────────────────────────────────────┤  <- 1pt zone divider
│  INBOX · 3                                         │  <- zone header (10.5pt semibold, tracked)
│  ┌────────────────────────────────────────────┐    │
│  │  SEA-201 Fix token budget overflow          │    │  <- TaskRowView compact
│  │  ghostties · [inbox]                        │    │
│  ├────────────────────────────────────────────┤    │
│  │  SEA-198 Triage Sentry alerts               │    │
│  │  ghostties · [inbox]                        │    │
│  └────────────────────────────────────────────┘    │
├────────────────────────────────────────────────────┤
│  BACKLOG · 4                                       │  <- [tray.full] icon, tertiary label color
│  ┌────────────────────────────────────────────┐    │
│  │  SEA-188 Row-click to edit                  │    │
│  │  ghostties · [circle.dotted]                │    │
│  ├────────────────────────────────────────────┤    │
│  │  SEA-185 Embedded browser panel             │    │
│  │  ghostties · [circle.dotted]                │    │
│  └────────────────────────────────────────────┘    │
├────────────────────────────────────────────────────┤
│  ACTIVE · 2                     ◉ machine ok       │  <- [bolt] zone
│  ┌────────────────────────────────────────────┐    │
│  │  SEA-142 Six-zone parity         ● running │    │
│  │  ghostties · 3m ago                        │    │
│  ├────────────────────────────────────────────┤    │
│  │  ○ open slot                               │    │  <- SlotPlaceholderView
│  └────────────────────────────────────────────┘    │
├────────────────────────────────────────────────────┤
│  ──────── NEEDS YOU ────────                 1     │  <- terracotta accent rules
│  ┌────────────────────────────────────────────┐    │
│  │  SEA-199 Approve deploy to prod    ● wait  │    │
│  │  ghostties · waiting 12m                   │    │
│  └────────────────────────────────────────────┘    │
├────────────────────────────────────────────────────┤
│  REVIEW · 2                                        │  <- [checkmark.circle] icon
│  ┌────────────────────────────────────────────┐    │
│  │  SEA-177 Traffic light alignment            │    │
│  │  ghostties · [arrow.triangle.branch]        │    │
│  ├────────────────────────────────────────────┤    │
│  │  SEA-165 DMG codesigning recipe             │    │
│  │  ghostties · [arrow.triangle.branch]        │    │
│  └────────────────────────────────────────────┘    │
├────────────────────────────────────────────────────┤
│  GRAVEYARD · 8                                     │  <- [tray] or [archivebox] icon
│  ▸ Done  5                                         │  <- collapsible sub-lane header
│  (collapsed — header visible, rows hidden)         │
└────────────────────────────────────────────────────┘
│  ◉ 3 sources · linear · gh · sentry       ⚙        │  <- footer (always visible)
└────────────────────────────────────────────────────┘
```

---

## Empty zone behavior

Empty zones show a thin header row but collapse the body. This preserves
spatial stability — the sidebar does not thrash as tasks move between zones.

```
┌─ GHOSTTIES SIDEBAR ───────────────────────────────┐
│  INBOX · 0                                         │  <- empty: full click-target
│  Nothing in the inbox.                             │     (InboxZoneView hides self
│  Click anywhere here to start a new task.          │      when empty — special case)
├────────────────────────────────────────────────────┤
│  BACKLOG · 0                                       │  <- header only; no body rows
├────────────────────────────────────────────────────┤  <- zone divider emitted only
│  ACTIVE · 0                                        │     when prior zone had content
│  (hidden entirely when empty — no divider)         │
├────────────────────────────────────────────────────┤
│  ──────── NEEDS YOU ────────                 0     │
│  ✓ Nothing needs you right now.                    │  <- reserved 30pt empty state
├────────────────────────────────────────────────────┤
│  REVIEW · 0                                        │  <- header only; no body rows
├────────────────────────────────────────────────────┤
│  GRAVEYARD · 0                                     │
│  No tasks in the graveyard.                        │
└────────────────────────────────────────────────────┘
```

---

## Design conventions (from WorkspaceLayout.swift + existing zones)

| Element              | Value                                             |
| -------------------- | ------------------------------------------------- |
| Zone header font     | `.system(size: 10.5, weight: .semibold)`          |
| Zone header tracking | `0.8`                                             |
| Zone header color    | `Color(nsColor: .tertiaryLabelColor)`             |
| Count pill font      | `.system(size: 10.5, design: .monospaced)`        |
| Zone divider         | `Color.primary.opacity(0.12)`, 1pt height         |
| Row divider          | `Color.primary.opacity(0.06)`, 0.5pt / Divider()  |
| Vertical padding     | `.padding(.vertical, 4)` on zone VStack           |
| Horizontal inset     | `TaskRowMetrics.horizontalPadding`                |
| Needs You accent     | `WorkspaceLayout.waitingTerracotta` (only zone)   |
| Backlog icon         | `tray.full` (SF Symbols)                          |
| Review icon          | `checkmark.circle` (SF Symbols)                   |
| Graveyard icon       | none in header (matches existing ArchiveZoneView) |
