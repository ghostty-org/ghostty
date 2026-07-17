# 05 — feat/wt-model-ui  (Milestone M2)

**Base:** rebase onto `feat/wt-sidebar-shell` once M1 lands, then merge in
`feat/wt-git-model`. · **Status:** BLOCKED until 03 + 04 exist.
**Read first:** [`plan.md`](../../plan.md) §"Milestones → M2"

> Created off `main` now only to hold this guide. Before doing work:
> `git rebase feat/wt-sidebar-shell` then `git merge feat/wt-git-model`.

## Purpose

M2: wire the real worktree model (branch 03) into the sidebar shell (branch 04). Still no
workspace switching — just showing correct data.

## Scope

- Repo detection on first surface cwd availability and on window focus; window's sidebar
  shows that repo's worktrees. Refresh on: window key, sidebar toggle open.
- Replace placeholder rows with real `Worktree`s from `feat/wt-git-model`'s API.
- Rows: branch icon + branch name (fall back to directory name for detached HEAD), **main
  worktree pinned to top**. Long branch names: truncate middle with tooltip.
- **Active worktree highlighted** — initially the worktree containing the first surface's
  cwd, if any.
- Filter text field at top: case-insensitive substring/fuzzy match over branch + dir names.
- Non-repo window → empty state ("Not a git repository"); everything else = stock Ghostty.

## Out of scope

- Clicking a row switching workspaces → `feat/wt-switching`.
- "New worktree…" row → `feat/wt-new-flow`.

## Verify (M2 criteria)

- Test repo with 3+ worktrees incl. detached-HEAD → all shown, active highlighted, main top.
- Non-repo directory → empty state.
- Window opened directly **inside a linked worktree** → resolves to the main repo's list.
- Filter narrows the list correctly.

## Handoff

Base for `feat/wt-switching`. Expose the selected/active worktree as observable state the
switching branch can hook into.
