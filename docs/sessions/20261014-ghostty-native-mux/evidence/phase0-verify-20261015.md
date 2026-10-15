# Phase 0 — fresh build verification (2026-10-15)

## Why this file

The auto-feedback loop flagged that the Phase 0 work and the
terminal.search.Thread flake analysis never had their feedback loops
closed with fresh evidence. This run closes both with a real
`zig build test-agent-ipc` from the same branch (`test/agent-ipc-phase0`,
commit `d503ef762`).

## Result

| Metric         | Recorded baseline | This run       | Delta                                                                                                                                                               |
| -------------- | ----------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wall clock     | 30m 24s           | 27m 29s        | -2m 55s (faster)                                                                                                                                                    |
| Build steps    | 83/85             | 83/85          | same                                                                                                                                                                |
| Tests passed   | 3899/3925         | 3899/3925      | same                                                                                                                                                                |
| Tests skipped  | 25                | 25             | same                                                                                                                                                                |
| Tests crashed  | 1                 | 1              | same                                                                                                                                                                |
| Peak RSS       | 4 GB              | 648 MB         | measured differently (RSS via `time -l` not `ps`); the test process peaked lower in this run, but the crashed subagent consumed additional memory before its trace. |
| Build artifact | (khostty-test)    | (khostty-test) | same                                                                                                                                                                |

**Verdict: same as baseline.** Slightly faster, identical pass/fail profile.

## What crashed

`terminal.search.Thread.test_0` — same flake documented in
`evidence/flake-investigation-20261015.md`. Identical stack trace:

```
thread 6500462 panic: reached unreachable code
zig-pkg/libxev-.../src/backend/kqueue.zig:1916:22  kevent_syscall
  .BADF => unreachable, // Always a race condition.
zig-pkg/libxev-.../src/backend/kqueue.zig:493:48  tick
zig-pkg/libxev-.../src/backend/kqueue.zig:305:35  run
src/terminal/search/Thread.zig:197:30  threadMain_
src/terminal/search/Thread.zig:136:21  threadMain
```

Precursor warnings (identical to prior runs):

```
[page] (warn): page integrity violation y=0 grapheme data but row not marked
[page] (warn): page integrity violation style ref count mismatch id=1 expected=10 actual=9
[page] (warn): page integrity violation zero row count
[page] (warn): page integrity violation zero col count
[terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory  (x3)
```

App_host diagnostic (the `app_host is compiled but NOT windowed (artifact=exe)`
line) is the same informational message from the Phase 0 step's
availability-contract test that we documented in the PR body. Not a bug.

## What this proves

- **Phase 0 work is correct.** The `test-agent-ipc` step completes 83/85
  build steps. The 1 failed step is the test step itself, and the 1
  crashed test is a pre-existing latent flake, not a Phase 0 regression.
  3899/3925 tests pass with 25 environment-skipped, which matches the
  prior baseline exactly.
- **The terminal.search.Thread flake is real and reproduces on this
  branch.** Same stack trace, same precursor warnings. The upstream
  Discussion #14719 documents it. No fix has been applied on this branch
  (we only documented the race; the fix would be either the Thread.zig
  guard or a libxev BADF recoverability change).

## What this does NOT prove

- That the flake is fixed. The flake was never fixed on this branch —
  only characterized. A fix is out of scope for Phase 0.
- That the PR will merge on the upstream. The upstream PR #14720 was
  auto-closed by the vouch bot during this turn (see below).

## New finding (unrelated to the build): upstream PR auto-closed

While waiting for the build, the upstream PR
https://github.com/ghostty-org/ghostty/pull/14720 was auto-closed by
`ghostty-vouch[bot]` at 2026-10-15T07:23:09Z with:

> Hi @KooshaPari, thanks for your interest in contributing!
> This project requires that pull request authors are vouched, and you
> are not in the list of vouched users.
> This PR will be closed automatic[ally]

The repo has a `vouch-manage-by-discussion.yml` workflow. The standard
external-contributor path is to open a vouch request in
Discussions -> "Vouch Request" category. Operator action required
if we want the Phase 0 work merged upstream:

1. Open a vouch request discussion in `ghostty-org/ghostty` Discussions
   -> "Vouch Request" category.
2. Wait for the vouch-bot to add the user.
3. Reopen or re-create the PR.

Without vouch, the Phase 0 work is shipped on the fork
(`KooshaPari/Khostty`) at branch `test/agent-ipc-phase0` but will not
land on `ghostty-org/ghostty:main` via the standard PR path.

## Build log

Full log: `/tmp/khostty-test-verify.log` (1224 lines)
