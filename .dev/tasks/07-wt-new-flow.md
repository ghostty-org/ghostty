# 07 — feat/wt-new-flow  (Milestone M4)

**Base:** rebase onto `feat/wt-switching` once M3 lands. · **Status:** BLOCKED until
06 exists. · **Terminal branch** (last in the chain).
**Read first:** [`plan.md`](../../plan.md) §"Milestones → M4"

## Purpose

M4: worktree creation + polish. Closes out v1.

## Scope

- **"New worktree…" row** at the bottom of the sidebar: prompts for a branch name, runs
  `git worktree add ../<repo>-<branch> -b <branch>`.
  - ⚠️ **Confirm the path convention with the human before wiring**, and make it
    configurable if trivial.
  - On success the new worktree appears and opens.
- **Error surfaces:** git failures shown as an unobtrusive **sidebar message, not
  alerts**. (E.g. bad branch name.) Never crash or block main.
- **Sidebar state** (collapsed/expanded + width) remembered **per window, for the app
  session** (not across restarts — persistence is a v1 non-goal).
- **README section** documenting the feature and its config/keybinds. If the keybind
  fallback (Swift menu items) was taken in `feat/wt-keybinds`, note the config-system gap.

## Out of scope (v1 non-goals — leave TODOs at most)

- Dirty / ahead-behind indicators, FSEvents watchers, thumbnails.
- Worktree deletion/pruning UI.
- Persistence across app restarts. Linux support.

## Verify (M4 criteria)

- Create a worktree from the sidebar → it appears and opens.
- Induce a git error (bad branch name) → graceful, unobtrusive handling, no alert/crash.

## Handoff

Feature complete. Optionally squash the M1→M4 chain into `feat/worktree-sidebar` for a
clean upstream-facing branch. Strip `.dev/tasks/` before any real PR.
