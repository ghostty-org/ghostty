## Context

lcmux is a fork of `ghostty-org/ghostty` (forked to `nborodikhin/lcmux`, tracked via an `upstream` remote for periodic rebase). The GTK/Linux app (`src/apprt/gtk/`) is a first-class libghostty consumer, written in Zig, sharing the same source tree as the core terminal emulator — there is no separate embeddable "full terminal" library on Linux to build against, so this change is implemented as a patch on top of Ghostty's own GTK apprt rather than a standalone app.

Relevant existing structure (confirmed by reading the source directly):
- `src/apprt/gtk/class/window.zig`: `Window` currently owns a single `tab_view: *adw.TabView` private field. Tabs are managed via `newTabPage()`, `selectTab(SelectTab)` (a `previous | next | last | n: usize` union with wraparound for `previous`/`next` and clamp-to-last for `n`), and a `tabViewNPages()` callback on the `notify::n-pages` GObject signal that currently closes the whole window when the tab count reaches 0.
- `src/input/Binding.zig`: defines the `Action` union used by keybind config parsing (e.g. `new_tab`, `previous_tab`, `next_tab`, `last_tab`, `goto_tab: usize`, `move_tab: isize`, `toggle_tab_overview`).
- `src/apprt/action.zig`: defines a separate `apprt.Action` tagged union (the cross-apprt-boundary runtime action set, e.g. `goto_tab: GotoTab` where `GotoTab` is `previous | next | last | _` enum). `src/Surface.zig` (~line 5281) translates a subset of `Binding.Action` values into `apprt.Action` calls.
- `src/apprt/gtk/class/application.zig`: `performAction()` switches on `apprt.Action.Key` and dispatches to functions like `Action.gotoTab(target, value)` / `Action.newTab(target)`, defined in the same file.
- `src/config/Config.zig` (~line 6600-6900): hardcodes Ghostty's built-in default keybindings, including the two we found actual conflicts with (see Decisions).
- `src/build/GhosttyExe.zig`: defines the installed executable name for the GTK application.

## Goals / Non-Goals

**Goals:**
- Add a `Workspace` concept above today's single-tab_view-per-window model, with a sidebar to view/switch/manage workspaces.
- Reuse Ghostty's existing tab/split/config/keybinding machinery unchanged; workspaces are a thin grouping layer, not a parallel implementation.
- Keep the patch surface small and mostly additive so future rebases onto upstream Ghostty stay tractable.

**Non-Goals:**
- No changes to terminal rendering, font handling, splits-within-a-tab, or config/theme parsing.
- No git/PR-aware tab metadata, notifications, embedded browser, socket API, or session restore (later lcmux work, not this change).
- No macOS support — this change only targets `src/apprt/gtk`.

## Decisions

### Workspace = a wrapper around today's per-window tab_view
Introduce `Workspace` (new file `src/apprt/gtk/class/workspace.zig`) as a GObject class owning what `Window` owns today: one `adw.TabView` plus the `newTabPage`/`selectTab`-equivalent logic, moved over largely as-is. `Window` changes from "owns one tab_view" to "owns an ordered list of `Workspace`s plus an active-workspace index."

The existing `Window` template currently owns `tab_view` and binds it directly into `Adw.TabOverview`, `Adw.TabBar`, the computed subtitle binding, and tab lifecycle callbacks. During this change, `Window` remains the owner of the surrounding chrome (`Adw.TabOverview`, `Adw.TabBar`, header bar, toast overlay, sidebar, and action dispatch), but no longer template-owns a permanent `Adw.TabView`. Instead:

1. `Workspace` creates and owns its `Adw.TabView` programmatically.
2. `Window` stores workspaces in an ordered list and exposes `activeWorkspace().getTabView()` as the current tab view.
3. Whenever the active workspace changes, `Window` rebinds `Adw.TabOverview.view` and `Adw.TabBar.view` to the new active workspace's tab view, updates tab-related title/subtitle state, and places that tab view in the content area.
4. The tab-view callbacks that need `Window` state (`close-page`, `page-attached`, `page-detached`, `create-window`, `setup-menu`, `notify::selected-page`) are connected by `Window` to each workspace's tab view when the workspace is added, then disconnected when it is removed.
5. The per-workspace empty lifecycle callback (`notify::n-pages`) lives in `Workspace` and emits `empty`; `Window` handles that signal by removing the workspace or creating a replacement when it was the last one.

This keeps a single source of truth for tab ownership (`Workspace`) while preserving upstream's existing `Window` responsibilities for application actions, close confirmations, surface signal wiring, and window chrome.

*Alternative considered*: keep `tab_view` directly on `Window` and fake "workspaces" as logical groupings of `AdwTabPage`s within a single shared tab_view. Rejected — this would require re-implementing tab-view semantics (page ordering, selection, close handling) per group instead of reusing `AdwTabView` wholesale, and would make hiding/showing "other workspaces' tabs" awkward since `AdwTabView` shows all its pages by default.

### Sidebar via AdwOverlaySplitView
Host the sidebar in an `AdwOverlaySplitView` (sidebar = new `GtkListBox`-based widget bound to `Window`'s workspace list; content = whichever `Workspace`'s tab_view is active). No existing precedent for this widget in `src/apprt/gtk/` today, so this is a new UI structure, not a reuse of e.g. the command palette or inspector layout.

*Alternative considered*: a custom `GtkBox` with manual show/hide instead of `AdwOverlaySplitView`. Rejected — `AdwOverlaySplitView` already provides the collapsible sidebar behavior, animation, and `show-sidebar` property we need for `toggle_workspace_sidebar`, for free.

### Workspace destruction replaces window-closes-at-zero-tabs
`Workspace.tabViewNPages`-equivalent (per-workspace `notify::n-pages` handler) signals `Window` when a workspace's tab count hits 0. `Window` then:
1. Removes that workspace from its list and from the sidebar.
2. If other workspaces remain, activates the adjacent one (prefer next, fall back to previous).
3. If none remain, creates a fresh workspace with one new tab (the zero-workspace guarantee) instead of closing the window — this replaces today's `tabViewNPages` behavior of calling `self.as(gtk.Window).close()` at 0 pages.

### New keybinding actions mirror existing tab action naming
Add to `src/input/Binding.zig`'s `Action` union: `new_workspace`, `previous_workspace`, `next_workspace`, `last_workspace`, `goto_workspace: usize`, `toggle_workspace_sidebar` — directly mirroring the existing `*_tab` action family (including `goto_workspace`'s clamp-to-last-on-overflow behavior, matching `goto_tab`). Add corresponding `apprt.Action` variants and `GotoWorkspace` enum in `src/apprt/action.zig`, translation in `src/Surface.zig` alongside the existing tab-action translation, and dispatch functions (`Action.newWorkspace`, `Action.gotoWorkspace`, etc.) in `src/apprt/gtk/class/application.zig`'s `performAction` switch, following the exact pattern of `Action.gotoTab`/`Action.newTab`.

### Default keybind conflicts: override in our fork
Checked `src/config/Config.zig`'s built-in default keybind table directly and found two real conflicts with the combos requested:
- **Ctrl+Shift+N** already defaults to `new_window` (non-macOS block).
- **Ctrl+Shift+PageUp` / `Ctrl+Shift+PageDown`** already default to `move_tab -1` / `move_tab 1`.

Decision: since no response was available to confirm, proceeded with overriding both defaults in our fork — `new_workspace`/`previous_workspace`/`next_workspace` take these combos as their defaults, and `new_window`/`move_tab` lose their out-of-the-box bindings (still reachable via user config remap or the command palette). This is flagged here explicitly so it can be revisited before merging if the user prefers different combos instead.

No conflicts were found for Ctrl+Shift+1-9 (existing `goto_tab`/`last_tab` defaults use Alt+1-9 on Linux), Ctrl+Shift+0 (existing `reset_font_size` default is Ctrl+0 without Shift), or Ctrl+Shift+B (unused).

### Executable name = lcmux
The GTK executable produced by the build is named `lcmux` instead of `ghostty`. This makes the fork's runnable binary distinct from upstream Ghostty and matches the README build/run documentation. The rename is intentionally scoped to the executable target in `src/build/GhosttyExe.zig`; inherited resources, docs, library names, app IDs, and runtime behavior remain unchanged unless a later rebranding change explicitly covers them.

*Alternative considered*: rename resources, docs, bundle IDs, and every Ghostty-facing path in the same change. Rejected — that would substantially widen the patch surface and rebase burden. This change only needs the user-facing command name to be `lcmux`.

## Risks / Trade-offs

- **[Risk]** Moving tab_view ownership from `Window` into a new `Workspace` type touches a structurally central file (`window.zig`) → **Mitigation**: keep the extracted `Workspace` API shape (method names/signatures) as close as possible to `Window`'s current tab methods, minimizing the diff and easing future rebases.
- **[Risk]** Overriding two existing default keybinds changes stock Ghostty behavior out of the box, which could surprise users migrating configs from vanilla Ghostty → **Mitigation**: documented explicitly in this design doc and in the README fork notice (separate task); both actions remain available via manual keybind config.
- **[Risk]** `AdwOverlaySplitView` requires a minimum libadwaita version → **Mitigation**: check the version already required by Ghostty's existing `adw_version.zig` gating (e.g. `toggle_tab_overview`'s libadwaita 1.4+ requirement) and confirm `AdwOverlaySplitView` (available since libadwaita 1.4) doesn't raise the minimum further; if it does, gate sidebar availability the same way `toggle_tab_overview` is gated.
- **[Risk]** Renaming only the executable may leave inherited resource paths/docs mentioning Ghostty → **Mitigation**: scope this change to binary invocation (`zig-out/bin/lcmux`) and defer broader product rebranding to a separate change.
- **[Risk]** Rebasing onto upstream Ghostty will conflict most often in `window.zig` and `Config.zig`'s default keybind block, since both are actively developed upstream → **Mitigation**: accepted maintenance cost (see proposal.md), kept patch surface additive where possible.

## Open Questions

- Should the sidebar's shown/hidden state persist across app restarts? Not specified by the user; out of scope for this change unless raised.
- Exact default libadwaita version gate for `AdwOverlaySplitView` needs confirming against `adw_version.zig` during implementation.
