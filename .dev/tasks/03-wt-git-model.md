# 03 — feat/wt-git-model

**Base:** `main` · **Status:** ready now, parallel — cleanest to fully delegate
**Read first:** [`plan.md`](../../plan.md) §"Architecture" (repo pinning, enumeration, git invocations)

## Purpose

The pure-Swift data layer: repo detection + worktree enumeration. Zero UI. Fully
unit-testable in isolation. This is the most independent chunk — no dependency on any
other branch.

## Scope

New Swift files (no edits to existing types):

- `Worktree` model: `{ path: URL, branch: String?, isMain: Bool, isDetached: Bool }`.
- **Repo pinning:** given a surface cwd, run `git -C <cwd> rev-parse --git-common-dir`
  to resolve the *main* repo root even when standing inside a linked worktree. Not a
  git repo → return nil (caller shows empty state).
- **Enumeration:** `git -C <root> worktree list --porcelain`, parsed into `[Worktree]`,
  main worktree first, branch name falling back to directory name for detached HEAD.
- All git shelled via `Process`, **always explicit `-C <path>`**, run **off the main
  thread**, with timeouts. Non-zero exit / timeout fails soft: return empty/nil + log,
  never throw to a crash, never block main.

## Out of scope

- No SwiftUI, no NSViewController, no `TerminalController` wiring — that's `feat/wt-model-ui`.
- No worktree *creation* (`git worktree add`) — that's `feat/wt-new-flow`.
- No FSEvents/watchers.

## Verify (unit tests against fixtures)

Build fixture repos in the test and assert:
- Repo with 3+ worktrees incl. a **detached-HEAD** one → parsed correctly, main first.
- A **non-repo** directory → nil / empty, no crash.
- A cwd **inside a linked worktree** → `--git-common-dir` still resolves to the main repo.
- Bad/timeout git invocation → fails soft.

Note test observations for bare repos / submodules / nested worktrees (plan edge cases).

## Handoff

Consumed by `feat/wt-model-ui` (M2). Expose a clean async API
(`func worktrees(forCwd:) async -> [Worktree]` + `func repoRoot(forCwd:) async -> URL?`)
so the UI branch merges this and just calls it.
