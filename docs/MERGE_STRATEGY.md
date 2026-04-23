# Merge strategy — overnight branches

Written 2026-04-23 overnight session. Suggested order for landing the 8+ branches into `main`. Each block below is a landable unit — you could ship one per day over a week, or stack them all and land in a single sweep.

## The dependency graph

```
main
  │
  ├── feat/task-first-sidebar-v0         (Phase 1 — independent)
  │     └── feat/sidebar-polish-v0       (parallel off Phase 1, independent)
  │
  ├── feat/gt-cli-v0                     (Phase 2 — independent of macOS work)
  │     └── feat/ghostties-mcp-server-v0 (Phase 3 — stacks on Phase 2)
  │           └── feat/automated-testing-v0 (Tests — stacks on Phase 3)
  │                 └── feat/ui-automation-v0 (UI smoke — stacks on Tests)
  │
  ├── feat/task-start-terminal           (Click-to-spawn + templates — stacks on Phase 1 + v0 fixtures)
  │
  └── feat/dev-environments-v0           (Phase 4 Part 1 — independent, cut from main)
```

## Recommended sequence

Land in this order. Each step fast-forwards or resolves cleanly.

### 1. `feat/task-first-sidebar-v0` → main

**Why first:** foundational. Phase 1 file-watching + row-click. Everything else stacks on this conceptually. 2 commits.

**Merge:** fast-forward if main is untouched since branching (likely the case).

```bash
git checkout main
git merge --ff-only feat/task-first-sidebar-v0
git push origin main
```

### 2. `feat/sidebar-polish-v0` → main

**Why next:** polish commits are isolated cosmetic fixes that only make sense after Phase 1. 4 commits.

**Merge:** fast-forward off the new main tip. Cut from Phase 1 tip originally, so no divergence.

### 3. `feat/gt-cli-v0` → main

**Why next:** independent of macOS work. Pure `cli/` additions. Ships the first terminal surface into the three-surface architecture.

Includes the schema parity commits added later (project-path + template flags). 7 commits total (5 original + 2 schema parity).

### 4. `feat/ghostties-mcp-server-v0` → main

**Why next:** stacks on gt-cli-v0. 9 commits total (7 original + 1 merge + 1 schema parity).

**CAVEAT:** this branch had a merge-conflict resolution in schema parity work. Review the merge commit before landing to confirm the visibility + init shape is what you want.

### 5. `feat/automated-testing-v0` → main

**Why next:** stacks on mcp-server-v0. Test harness + CI workflow. 9 commits total (7 original + 1 merge + 1 schema test).

**Side-rider:** this branch has the session-notes doc commit `a947c3c71` on it (accidentally landed here overnight — harmless but worth knowing).

### 6. `feat/ui-automation-v0` → main

**Why next:** single XCUITest smoke. 1 commit.

### 7. `feat/task-start-terminal` → main

**Why next:** this is where the click-to-spawn-session + template layer lives. Branches off Phase 1 tip, so requires conflict resolution on the `.ghostties/tasks/*.md` fixtures (12 files were updated with project-path + template fields). Likely clean auto-merge since the other branches don't touch those files.

8 commits (4 from wave 1 session-spawn + 4 from wave 2 templates).

### 8. `feat/dev-environments-v0` → main

**Why last:** independent of all other work. Changes `pbxproj` + possibly Info.plist. Safe to land any time; landing last means you don't have to re-test every prior branch with the new bundle ID.

Commit count depends on subagent output — review before merging.

### Parallel (optional now, merge anytime):

- **Session hybrid macOS** (branch name: reported by worktree subagent) — stacks on `feat/task-start-terminal`. Big conceptual addition — review carefully.
- **Session hybrid MCP `write_session_notes`** (branch name: reported by worktree subagent) — stacks on `feat/ghostties-mcp-server-v0`. Small tool addition.

## PR or direct merge?

Since this is your fork + you're the only committer, direct merge to main is fine. PRs are valuable if:

- You want the GitHub Actions CI from `feat/automated-testing-v0` to validate each branch before landing
- You want a historical review trail
- You're planning to open-source this fork later and want the audit history

If you PR, do it sequentially — PR #1 merges, then rebase PR #2 onto new main tip, etc. GitHub UI handles this via "Update branch" button.

## What NOT to do

- **Don't cherry-pick from one branch to another.** The dependency chain is real; cherry-picks will create duplicate commits and make the history confusing.
- **Don't force-push to any branch that's been pushed.** Every branch has been pushed to origin. Sean has a rule to not force-push unless explicitly requested.
- **Don't merge to upstream.** `ghostty-org/ghostty` is read-only. Only `origin = SeanSmithDesign/ghostties`.
- **Don't skip the Phase 3 merge commit review.** The schema parity merge had a manual conflict resolution — worth one eyeball pass before landing.
