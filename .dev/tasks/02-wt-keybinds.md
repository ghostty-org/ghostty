# 02 — feat/wt-keybinds

**Base:** `main` · **Status:** ready now, parallel · **Read first:** [`plan.md`](../../plan.md) §"Keybinds"

## Purpose

Plumb the new keybind actions through the Zig core so they're user-configurable,
mirroring `goto_split`. Pure plumbing — the Swift handlers call stub methods that other
branches fill in. No UI dependency.

## Scope

Add three actions:
- `toggle_worktree_sidebar`
- `goto_worktree:next`
- `goto_worktree:previous`  (next/previous wrap around)

Plumb each: `src/input/Binding.zig` → apprt action enum → macOS apprt handler →
stub method on `TerminalController` (empty body + `// worktree-sidebar:` marker; the
sidebar-shell / switching branches implement them).

Defaults (macOS):
- `toggle_worktree_sidebar` → `cmd+shift+e` (ship bound).
- `goto_worktree:next/previous` → **ship UNBOUND.** Do NOT change the global
  `cmd+[` / `cmd+]` defaults (they're `goto_split:next/prev`); the human rebinds those
  in their own config.

## Out of scope

- Any actual sidebar behavior. Handlers are stubs here.
- GTK/Linux apprt — do not touch.

## Fallback

If Zig plumbing proves disproportionately invasive, fall back to Swift-side menu items
with key equivalents for v1 and note the config-system gap in the README. Flag this to
the human before committing to the fallback. (Coordinate with the spike's keybind trace.)

## Verify

- Build succeeds. Trigger each action and confirm it reaches the Swift stub (log line).
- Opening a plain window with no config change behaves identically to upstream.

## Handoff

`feat/wt-sidebar-shell` implements `toggle_worktree_sidebar`; `feat/wt-switching`
implements `goto_worktree`. Keep the stub method signatures stable so those branches
just fill bodies. Merges cleanly alongside the shell branch (different files).
