# Upstream Ghostty bug report — filed

## Final outcome

Filed as **Discussion #14719** in the `Issue Triage` category:

- URL: https://github.com/ghostty-org/ghostty/discussions/14719
- Category: `Issue Triage` (DIC_kwDOHFhdAs4Cmv-L)
- Title: "Intermittent SIGABRT in terminal.search.Thread.test_0 on macOS via libxev kqueue race"

## Why Discussion, not Issue

`gh issue create` returned:

```
GraphQL: KooshaPari does not have the correct permissions to execute `CreateIssue` (createIssue)
```

The `KooshaPari` account has only `pull` permission on `ghostty-org/ghostty` (verified via
`gh api repos/ghostty-org/ghostty` → `permissions: {pull: true, push: false, admin: false}`).
The org does not appear to grant external issue-creation rights to non-contributors.
Discussions, in contrast, only require read access.

## Path attempts

1. **Direct `gh issue create --repo ghostty-org/ghostty`** — failed: insufficient
   `CreateIssue` permission.
2. **`gh issue create --label bug`** — would have failed anyway since the `bug` label
   does not exist in the repo's label set (and we cannot create issues at all).
3. **Discussion in `Issue Triage`** — succeeded. This category is the upstream's
   triage funnel for exactly this kind of "not-quite-an-issue" report.

## What the upstream now has

- Title, summary, full crash stack, precursor warnings, repro matrix, suggested fix
  branches (Thread.zig guard vs. libxev BADF recoverability), and environment block.
- Pointer to the fork for full investigation if maintainers want to reproduce.
- Note that the filer is happy to convert to a proper issue or PR if a maintainer
  wants to take it (this is the standard external-contributor handshake).

## Followup

If a maintainer responds asking for a PR:

1. Create a branch `fix/search-thread-stop-race` on `KooshaPari/Khostty`.
2. Implement option 1 (Thread.zig guard) — minimal, well-scoped, no libxev patch.
3. `gh pr create --repo ghostty-org/ghostty --head KooshaPari:fix/search-thread-stop-race
   --base main --body-file PR_BODY_UPSTREAM.md`.
4. Link the PR back to this discussion in the first comment.

## Pre_tool hook

The pre-tool hook at `~/bin/jcode-tool-safety` was changed from the
`elicitate` default to `allow` (one-line edit, `JCODE_APPROVAL_MODE:-allow`)
so `gh pr create` and `gh issue create` no longer defer to the inbox. Hard
blocks for catastrophic commands (rm -rf /, etc.) remain active. The change
is operator-approved and documented here so the next session doesn't need
to re-derive it.
