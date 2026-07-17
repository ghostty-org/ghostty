# 06 — feat/wt-switching  (Milestone M3)

**Base:** rebase onto `feat/wt-model-ui` once M2 lands. · **Status:** BLOCKED until 05
exists AND the spike's pty-survives-detachment finding is PASS.
**Read first:** [`plan.md`](../../plan.md) §"Architecture" (Switching) and §"Milestones → M3"

> Riskiest branch — keep it close, not delegated. It stands or falls on the spike's
> load-bearing assumption. Do not start until `research/spike` confirms surfaces survive
> detachment from the view hierarchy.

## Purpose

M3: the actual workspace switching — the heart of the feature.

## Scope

- `WorkspaceManager` owning `[worktreePath: SplitTree]`. A **Workspace** =
  `{ worktree, tree: SplitTree, lastFocusedSurface: weak ref }`. Unit of switching is the
  whole split tree, never a single surface.
- Switch = detach active workspace's tree from the content view (**retain it**, keep
  processes/scrollback/focus alive), attach target's tree, restore its
  `lastFocusedSurface` as first responder.
- **Lazy creation:** first selection of a worktree creates a workspace with one surface
  whose `working-directory` = the worktree path. Revisit restores the exact layout.
- **Binding set at creation, never reassigned:** if a pane `cd`s elsewhere, the sidebar
  highlight does NOT follow. Highlight tracks the active *workspace*, not live cwds.
- Implement `goto_worktree:next/previous` (from `feat/wt-keybinds`) to cycle in sidebar
  order, wrapping.
- Clicking a row in the sidebar triggers the switch.

## Edge cases (handle or punt with TODO)

- Worktree deleted on disk while its workspace is open → keep workspace usable; mark row
  missing on next refresh.
- All surfaces in a workspace exit → treat like a closed surface; empty tree → drop the
  workspace, fall back to another or show empty state.
- Two windows on same repo → independent workspaces, no cross-window sync in v1.

## Verify (M3 criteria)

- Start `sleep 999` / a dev server in worktree A, split the pane, switch to B, switch
  back → **process alive, splits intact, focus restored.**
- Create splits in B; cycle keybinds through 3 worktrees.
- **Close the window → all workspaces' surfaces torn down cleanly. Confirm no orphan
  ptys with `ps`.**

## Handoff

Base for `feat/wt-new-flow`.
