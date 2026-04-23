---
title: ShellView crash affecting 12 users
source: sentry
source-id: SNT-9
branch: null
project: ghostties
created: 2026-04-22T09:12:00Z
status: inbox
severity: error
events: 34
users: 12
---

## Goal

Recurring crash in `ShellView.updateLayer()` — nil unwrap on `currentSurface` during rapid tab-close. Sentry grouped 34 events from 12 distinct users in the last 24h. Needs reproduction in a detached window with rapid ⌘W presses.

## Notes

```
Fatal error: Unexpectedly found nil while unwrapping an Optional value
  at ShellView.updateLayer() (ShellView.swift:184)
  at NSView._updateLayerGeometryFromView()
  at -[NSWindow _reallyDoOrderWindow:...]
  at Ghostties.AppDelegate.applicationDidFinishLaunching(...)
```

## Activity

- 2026-04-22T09:12:00Z — First event seen in Sentry
- 2026-04-22T09:47:00Z — Crossed 10-user threshold, escalated to inbox
- 2026-04-22T19:30:00Z — Latest occurrence (build 0.1.0-beta.1)
