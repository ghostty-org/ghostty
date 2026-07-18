# Worktree Sidebar — multi-branch dev plan

Source of truth for the feature: [`plan.md`](../../plan.md). This directory holds
the per-branch guides that break that plan into independently-developable units.

## How this is organized

Each branch owns one guide file in `.dev/tasks/`. Check out a branch, read its
guide, build only what it describes. Filenames are unique per branch so they never
collide when branches merge up the chain.

## Dependency graph

```
main
 ├── research/spike ............ 01  gate — confirm assumptions before ANY code
 │
 ├── feat/wt-keybinds .......... 02  Zig core action plumbing      ┐
 ├── feat/wt-git-model ......... 03  Swift git/worktree model      ├ parallel, off main
 └── feat/wt-sidebar-shell ..... 04  M1: sidebar shell             ┘
        │
        └── feat/wt-model-ui .... 05  M2  (needs 03 + 04)
               │
               └── feat/wt-switching .... 06  M3  (needs 04 + spike findings)
                      │
                      └── feat/wt-new-flow .... 07  M4  (needs 05 + 06)
```

## What can run in parallel

- **Now (off `main`):** `research/spike`, `feat/wt-keybinds`, `feat/wt-git-model`,
  `feat/wt-sidebar-shell`. The spike gates whether the milestone chain proceeds,
  but the three `feat/*` branches can be built concurrently regardless.
- **After M1 (`feat/wt-sidebar-shell`) lands:** cut/rebase `feat/wt-model-ui`.
- Then `feat/wt-switching`, then `feat/wt-new-flow` — a chain, each on the prior.

`feat/wt-git-model` is the cleanest to fully delegate (pure Swift, unit-testable,
no UI). `feat/wt-switching` is the riskiest — keep it close; it depends on the
surface-lifecycle finding from the spike.

## Merge/rebase flow

1. `research/spike` → review findings, revise plan, DO NOT merge code (it's notes).
2. `feat/wt-sidebar-shell` → `main` (or into an integration branch) once M1 verifies.
3. `feat/wt-model-ui` rebases onto the merged shell, then merges `feat/wt-git-model`.
4. `feat/wt-switching` rebases onto model-ui. `feat/wt-new-flow` onto switching.
5. Optionally squash the milestone chain into a single `feat/worktree-sidebar`
   branch for a clean upstream-facing history (matches `plan.md`'s branch name).

## Conventions (from plan.md)

- macOS only. Do not touch GTK/Linux apprt.
- Prefer new Swift files over editing existing ones. Where editing upstream files
  is unavoidable, keep hunks small and mark them `// worktree-sidebar:` so future
  rebases can find them.
- Git always shelled via `Process` with explicit `-C <path>`, off-main, fail-soft.
- These `.dev/tasks/` docs are dev scaffolding — strip them before any upstream PR.
