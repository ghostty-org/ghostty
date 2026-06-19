# Sidebar Spaces — Design

**Date:** 2026-06-18
**Status:** Approved (design)
**Scope:** macOS app only (`macos/`). No Zig core changes.

## Summary

Add Arc-browser-style **Spaces** to the left tab sidebar (the fork's
`macos-tab-bar-location = left` mode). A Space is a named, emoji-tagged group of
tabs. Each window's tab-group has an ordered list of spaces and exactly one
**active space**. The sidebar shows only the active space's tabs, with a row of
space icons at the bottom that switches between them (the list "swaps" when you
switch, matching Arc).

State is **session-only** (not persisted across app restarts) and scoped
**per tab-group** (per-window, technically per `NSWindowTabGroup`).

## Background / current architecture

The existing sidebar (`macos/Sources/Features/Terminal/TerminalSidebarView.swift`)
is a SwiftUI view that mirrors the native macOS tab group. Key facts that drive
this design:

- Tabs are separate `NSWindow`s sharing one `NSWindowTabGroup`. Only one window
  in a group is visible at a time (native macOS tabbing).
- Each tab/window has its own `TerminalController` → its own `TerminalView` →
  its own `TerminalSidebarView` instance. You only ever *see* the front window's
  sidebar, but every window renders one.
- The sidebar holds no persistent model; `tabRows` reads `tabGroup.windows`
  live on every refresh (driven by notifications + a 0.5s timer).
- In sidebar mode the native top tab bar is already collapsed
  (`TerminalWindow.syncTabBarLocation()`).

Because every window in a group renders its own sidebar, spaces state **cannot**
live on a single controller or view — all tabs in a group must observe the
*same* spaces and the *same* active space.

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Switch behavior | Arc-style: switching a space swaps the whole visible tab list. |
| Scope | Per-window (per tab-group). No global/cross-window spaces. |
| Persistence | Session-only. No disk serialization. |
| Move tab to space | Context-menu "Move to Space…" (v1). Drag-onto-icon deferred. |
| Space identity | Emoji icon (free-text, ≤2 chars) + name. No SF Symbol picker. |
| Delete a non-empty space | Blocked. Only empty spaces are deletable. Last space never deletable. |
| Activation | Always on whenever `macos-tab-bar-location = left`. No new config key. |
| Keyboard switching | Deferred. |

## Data model

A small **`TerminalSpacesStore`**: an app-level singleton that vends one
`ObservableObject` model per tab-group, keyed by `ObjectIdentifier` of the
`NSWindowTabGroup`. Each sidebar looks up its window's tab-group and binds to the
shared model, so all sidebars in a group stay in sync.

The per-tab-group model (call it `SpacesModel: ObservableObject`) holds:

- `spaces: [Space]` — ordered.
- `activeSpaceID: Space.ID`
- `assignments: [ObjectIdentifier /* window */ : Space.ID]` — tab → space.
- `lastActiveTab: [Space.ID : ObjectIdentifier]` — remembers each space's
  most-recently-active tab for restore-on-switch.

```
struct Space: Identifiable {
    let id: UUID
    var name: String
    var icon: String   // emoji, ≤2 chars
}
```

The model's logic is kept **free of AppKit** (operates on opaque
`ObjectIdentifier` window keys and `Space` values) so it can be unit-tested
directly. The view layer is a thin shell over it.

### Model responsibilities (pure, testable)

- **Default space:** lazily create one default space (`name: "Space 1"`,
  `icon: "💻"`) the first time a tab-group is seen; assign all currently-known
  tabs to it.
- **Assign-on-create:** any window not present in `assignments` is lazily
  assigned to `activeSpaceID` (covers new tabs created via `+`).
- **Active tabs for a space:** filter a provided ordered window list to those
  assigned to a given space.
- **isEmpty(space):** true when no known/assigned tab maps to it.
- **Delete guard:** deletion allowed iff the space is empty AND it is not the
  last space.
- **Move tab → space:** update `assignments[window]`.
- **Switch active space:** set `activeSpaceID`; expose the target's
  `lastActiveTab` (if still present) for the view to bring to front.
- **Reconciliation:** drop assignments / `lastActiveTab` entries for windows
  that no longer exist in the group (called on refresh).

## UI

The sidebar gains a third region. Top-to-bottom:

```
┌─────────────────────────┐
│  💻 Space 1          +   │   header: active space emoji+name, New Tab (+)
├─────────────────────────┤
│  ◦ tab one          ⌘1  │
│  ◦ tab two          ⌘2  │   tab list (active space only) — existing styling
│  ◦ tab three            │
│         (scrolls)       │
├─────────────────────────┤
│  💻  🌐  🛠️   …     +   │   space switcher: emoji per space + add-space (+)
└─────────────────────────┘
```

- **Header:** shows the active space's emoji + name; keeps the New-Tab `+`
  (creates a tab in the active space). Replaces today's header that only holds
  the `+`.
- **Tab list:** unchanged row styling; now filtered to the active space.
- **Switcher row (fixed, bottom):** one button per space showing its emoji;
  active space highlighted (accent tint / filled background); hover tooltip =
  space name. Trailing `+` adds a space.
- Resize handle, divider, and existing row styling are untouched.

## Interactions

- **Switch:** click a space icon → set active → list re-filters → bring the
  space's `lastActiveTab` to front (fallback: first tab in the space).
- **Create space:** `+` in switcher → inline popover with two fields: emoji
  (≤2 chars) and name. On confirm: create, make active, and **auto-create one
  new tab** in it (never shown empty right after creation).
- **Rename/edit:** right-click space icon → "Rename Space…" (re-opens the
  emoji+name editor).
- **Delete:** right-click space icon → "Delete Space"; disabled (with
  explanatory tooltip) when the space is non-empty or is the last space.
- **Move tab between spaces:** right-click a tab → "Move to Space ▸" submenu
  listing all spaces (current one checked/disabled). If the moved tab was the
  active/front tab, the sidebar re-filters and selects another tab in the
  current active space.
- **Empty-space switch:** if you switch *into* an empty space, auto-create one
  fresh tab so the terminal area always shows a live surface, never blank.
- **Default space:** on first sidebar load, all existing tabs go to "Space 1"
  (💻). Behavior is identical to today until a second space is added.

## Switching mechanics (why it's cheap)

All windows already live in the native tab-group; only one is ever visible.
"Swapping the list" is just: (1) change `activeSpaceID`, (2) re-filter the
sidebar rows, (3) `makeKeyAndOrderFront` the target space's last-active tab. No
windows are added to or removed from the tab-group on a switch.

## Non-goals (deferred)

- Persistence across restarts.
- Keyboard shortcuts for spaces.
- Drag-a-tab-onto-a-space-icon (context menu only in v1).
- Per-space accent colors.
- Global / cross-window spaces.
- Making native `⌘1…9` / `⌃Tab` cycling respect the active space — these still
  traverse all windows in the group (the native tab bar is collapsed, so this is
  invisible but the shortcuts walk everything).

## Known limitations (v1)

- **Spaces are per-window; tabs don't carry their space across windows.** Because
  spaces are scoped per tab-group with unique IDs, moving a tab to another window
  (Move Tab to New Window, drag-out, Merge All Windows) places it in the
  destination window's active space rather than recreating its original space.
  This is intentional for the per-window model. (True cross-window preservation
  would require name-based space travel or making spaces app-global.)

- **Store keying across the standalone→tabbed transition.** `TerminalSpacesStore`
  keys the shared model by `NSWindowTabGroup` identity, falling back to the window
  itself when `tabGroup` is `nil`. With native window tabbing enabled (the default,
  and the context this feature targets) a window belongs to a tab-group even when
  it holds a single tab, so this is a non-issue in practice. In the rare case a
  window genuinely has no tab-group and the user creates extra spaces *before*
  opening a second tab, those spaces are keyed to the lone window; once it joins a
  tab-group the sidebar binds to the group's model and the pre-tab spaces are not
  carried over. Acceptable for session-only state; a fix would add migration
  machinery that is not worth the complexity for v1.
- **Native "Close Other Tabs" / "Close Tabs to the Right" are space-blind.** The
  sidebar's own Close Other / Close Below are space-scoped, but the native
  actions (no default keybind; only reachable via a custom keybind or the native
  tab context menu, which is hidden in sidebar mode) still operate on the whole
  tab group. Left as-is to avoid editing upstream close logic; low reachability.
- **Bulk close shows one confirmation per running-process tab.** Closing several
  tabs that need quit-confirmation (Close Other/Below, Delete Space) prompts per
  tab rather than once. Minor; correctness is unaffected.
- **Undo of a closed tab restores it into the current active space** (session
  only). The refresh timer + change-signature gate is retained deliberately
  (event-driven title updates would require upstream changes for no net gain).
- **Interactive UI not automatically verified.** The model layer is unit-tested
  and the app builds and launches cleanly with the feature active, but the
  interactive flows (create / switch / rename / delete / move spaces) require a
  manual run — screen-recording/accessibility automation was unavailable in the
  build environment.

## Testing

- **Unit tests:** `SpacesModel` pure logic — default-space creation,
  assign-on-create, `isEmpty`, delete guard (empty + not-last), move-to-space,
  switch + `lastActiveTab`, reconciliation of dead windows.
- **Manual verification:** build the macOS app (`zig build`); exercise create /
  switch / rename / move / delete; multi-tab windows; closing the last tab of a
  space; switching into an empty space; default-space wrapping of pre-existing
  tabs; confirm all sidebars in a tab-group stay in sync.

## Affected files (anticipated)

- `macos/Sources/Features/Terminal/TerminalSidebarView.swift` — header, switcher,
  filtered list, context menus.
- New: `macos/Sources/Features/Terminal/TerminalSpacesStore.swift` (or similar)
  — store + `SpacesModel` + `Space`.
- Possibly `TerminalView.swift` only if wiring the store needs it (the sidebar
  can look the store up itself via its window's tab-group).
- Xcode project file (`project.pbxproj`) — add the new source file.
