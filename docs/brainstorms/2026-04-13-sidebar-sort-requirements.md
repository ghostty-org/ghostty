---
name: Workspace sidebar sort & smart sections
date: 2026-04-13
status: ready for planning
---

# Workspace Sidebar — Smart Sections

## Problem

User juggles 4–8 active agents across 14+ projects. The current alphabetical sidebar buries live work — a collapsed row gives no signal that agents are running inside. Finding "where the action is" requires scanning and expanding projects.

## Goal

Surface activity at the top of the sidebar automatically, without the list jumping around under the user while they work. Keep the calm alphabetical base for the long tail of projects.

## Non-Goals

- Manual drag-drop ordering (skipped — handled by pin as escape hatch).
- Per-project sort modes. Sessions follow the same sectioning rule as projects.
- A user-facing sort-mode switcher. The system decides; pin overrides.
- Reworking the existing per-session drag-drop `sortOrder` within a project (leave as-is).

## Core Idea — Three Sections

Projects auto-group into three sections. Sections are the only sort control; there is no toggle.

| Section           | Membership rule                                         | Internal order                              |
| ----------------- | ------------------------------------------------------- | ------------------------------------------- |
| 📌 **Pinned**     | `project.isPinned == true` (existing field, repurposed) | Stable user-chosen; falls back alphabetical |
| ⚡ **Active Now** | ≥1 session in `processing` or `waiting` state           | Alphabetical                                |
| 🕑 **Recent**     | No active sessions but touched in past 24h              | Chronological by last activity              |
| 📚 **All**        | All other projects                                      | Alphabetical                                |

A project lives in exactly one section — the highest-priority one it qualifies for. The project is the atomic unit; it never fragments across sections.

## Anti-Jumping Rules

Four rules prevent the list from thrashing while agents chatter:

1. **Membership-only sort.** Sections decide where a project lives; within a section, order is stable (alphabetical except Recent, which is time-ordered but only re-evaluates on blur — see #3).
2. **Asymmetric transitions.** A project enters **Active Now** instantly when any session begins processing (user wants the signal). It leaves only after a **2-minute grace period** of total silence across all its sessions. Prevents flapping on bursty output or mid-thought pauses.
3. **Freeze while focused.** The sidebar does not reorder while it has keyboard focus or while a session inside it is active. Reordering triggers on: window blur, new session created, project added/removed, explicit user refresh.
4. **Pin as stability escape hatch.** Pinned projects never move and always sit at the top. Users pin the 2–3 projects they always want at hand; everything else flows.

## Ghost Icon = Activity Indicator

No separate activity dots. The existing ghost icon on each project row becomes the status signal:

- **Terracotta ghost** (`#C97350`) — at least one session inside is processing or waiting.
- **Normal ghost** — project has recent activity but nothing currently running.
- **Muted ghost** — idle project (no activity past 24h).

This collapses two signals (activity + brand character) into one visual.

## Expanded Project Behavior

When a project is expanded, its sessions are internally grouped using the same three-bucket mental model:

```
👻 Brukas            ▾  🟠
   ─ Active ──────────
     Research         🟠
   ─ Recent ──────────
     Build     12m    ▨
   ─ Idle ────────────
     Orchestrator     ·
     GTM              ·
   + New Session
```

- Session state mirrors project state rules (Active = processing/waiting, Recent = output in past 24h, Idle = stale or never-run).
- Internal order within each group: alphabetical (stable).
- Same anti-jump rules apply.
- Group headers only render when the project has sessions in multiple states; a single-bucket project shows a flat list.

## Pin Semantics — Cleanup Needed

The existing `Project.isPinned` field defaults to `true` on every new project (see `macos/Sources/Features/Ghostties/Models/Project.swift:22`). That makes it effectively meaningless as a ranking signal.

**New semantics:** `isPinned` means "always on top, above sections." Default becomes `false`. Existing projects migrate to `false` on first load after upgrade (one-time migration), except any the user later explicitly pins. The existing Pin/Unpin menu item in `ProjectDisclosureRow.swift:161` stays.

## Timestamps — New Data

Required additions:

- `Project.lastActiveAt: Date?` — updated whenever any session within the project produces output, is focused, or is created.
- `AgentSession.lastActiveAt: Date?` — updated on output, focus, or state change away from idle.

Both fields are `Codable` with `decodeIfPresent` for backward compatibility (same pattern used for `ghostCharacter` and `defaultTemplateId` in existing models).

## Edge Cases

- **Only-stale-sessions project that was just opened** → Recent (opening counts as touch, updates `lastActiveAt`).
- **Active session becomes idle** → Project stays in Active Now for 2-min grace, then demotes on next blur-reorder.
- **Brand-new project, zero sessions** → All (no activity yet). Shows in alphabetical long tail.
- **Pinned project with no activity** → Stays Pinned section regardless of state.
- **All 14 projects somehow become active** → All three display in Active Now alphabetical; Recent and All sections render empty (hide empty sections).
- **Section with zero entries** → Hide the section header entirely; don't render empty buckets.

## Success Criteria

- Opening the app with 4+ agents running shows all active projects in the top section without expanding anything.
- Ghost icon colors make it obvious at a glance which collapsed projects have live agents.
- During a 10-minute working session with agents producing bursty output, projects do not change position while the sidebar has focus.
- Pinned projects stay put through all state changes.
- Existing workspace.json files load without error; projects without `lastActiveAt` degrade gracefully (treated as stale, placed in All).

## Open Questions (for planning phase)

- **Blur detection mechanism** — does NSWindow `didResignKey` suffice, or does the sidebar need its own first-responder tracking? Likely the latter since sidebar focus ≠ window focus.
- **Reorder animation** — use existing `NSAnimationContext 0.2s easeInOut` pattern from `WorkspaceViewContainer.transitionTo(_:)`, or keep reorders instantaneous to avoid motion distraction? Respect `accessibilityDisplayShouldReduceMotion` either way.
- **Grace period configurability** — hardcode 2 minutes, or expose as a setting? Recommend hardcode for v1.
- **Migration UX** — should the first-run-after-upgrade unpin all projects silently, or show a brief one-time toast explaining the new pin semantics?

## Reference — Existing Code Touchpoints

- `macos/Sources/Features/Ghostties/Models/Project.swift` — add `lastActiveAt`, change `isPinned` default.
- `macos/Sources/Features/Ghostties/Models/AgentSession.swift` — add `lastActiveAt`.
- `macos/Sources/Features/Ghostties/WorkspaceStore.swift:72` — current pinned/unpinned split; replace with four-section computed property.
- `macos/Sources/Features/Ghostties/WorkspaceSidebarView.swift` — section rendering, headers, empty-section hiding.
- `macos/Sources/Features/Ghostties/ProjectDisclosureRow.swift` — ghost color binding to activity state; internal session grouping when expanded.
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift` — indicator state already tracked; hook activity updates into `lastActiveAt` writes on both session and project.
- `macos/Sources/Features/Ghostties/WorkspacePersistence.swift` — migrate old JSON (set `isPinned = false` where missing new flag, tolerate missing timestamps).

## Handoff

Ready for `/ce:plan` to break this into implementation phases. Suggested phasing:

1. Data model additions (`lastActiveAt`, pin migration) + persistence round-trip tests.
2. Section computation in `WorkspaceStore` + unit tests for membership and grace-period logic.
3. Sidebar rendering — section headers, ghost color binding, expanded-project session grouping.
4. Freeze-on-focus reorder gating + blur detection.
5. Polish — animation timing, empty-section hiding, migration UX decision.
