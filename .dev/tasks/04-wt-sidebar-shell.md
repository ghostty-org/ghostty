# 04 — feat/wt-sidebar-shell  (Milestone M1)

**Base:** `main` · **Status:** ready now, parallel · **Merges to:** `main` (first milestone in)
**Read first:** [`plan.md`](../../plan.md) §"Architecture" (Sidebar) and §"Milestones → M1"

## Purpose

M1: the collapsible sidebar *shell* with placeholder content. No real data yet. This is
the first branch that lands and becomes the base for the M2→M3→M4 chain.

## Scope

- Introduce an `NSSplitViewController` with a `.sidebar`-behavior split item hosting a
  SwiftUI list via `NSHostingView`. Sidebar vibrancy material; standard AppKit look
  (Finder/Xcode style), no custom chrome.
- Show a **hardcoded placeholder list** for now.
- Toggle via a menu item **and** the `toggle_worktree_sidebar` keybind.
- **Default state: collapsed.** With zero interaction, Ghostty behaves identically to
  upstream.
- Implement the `toggle_worktree_sidebar` stub from `feat/wt-keybinds` (or, if that
  branch isn't merged yet, wire a temporary menu item and leave a `// worktree-sidebar:`
  TODO to connect the action). Keep changes to `TerminalController` minimal; prefer a new
  `WorktreeSidebarViewController` file + extension points over editing method bodies.

## Out of scope

- Real worktree data, filtering, repo detection → `feat/wt-model-ui`.
- Workspace switching / SplitTree detach → `feat/wt-switching`.

## Verify (M1 criteria)

- Toggle animates open/closed; sidebar shows placeholder rows.
- Window resize behaves; fullscreen still works; native tabs still work.
- No regression opening a plain window; collapsed = indistinguishable from upstream.

## Handoff

Base for `feat/wt-model-ui`. Keep the SwiftUI list's data source behind a small protocol
so M2 can swap placeholder rows for real `Worktree`s without restructuring the view.
Depends (soft) on `feat/wt-keybinds` for the toggle action; can stub locally if it lags.
