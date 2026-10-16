# Khostty CI/sync arc — sunset record (2026-10-16T22:31Z)

## Status: COMPLETE. Heartbeat loop sunset, no successor armed.

The ownership heartbeat had already stopped on its own before this tick (the
schedule list contained no Khostty wake). This record closes the arc.

## Landed on `main` (HEAD `6da47d0c2`)

| PR  | Merge       | What                                                                      |
| --- | ----------- | ------------------------------------------------------------------------- |
| #16 | `ccfa79f2a` | pytest job so the 162 python binding tests actually run                   |
| #19 | `795383086` | EGL portability fix + upstream ghostty sync (ancestry preserved)          |
| #17 | `6da47d0c2` | nightly fork-only zig test steps (`test-agent-ipc`, `test-windows-apprt`) |

Ancestry verified after the final merge:
`git merge-base --is-ancestor 79538308694f origin/main` → true.

## What PR17 actually required

PR17 could not land until two things were true, and both were enforced rather
than assumed:

1. **Real Linux execution.** `test-agent-ipc` (24m9s) and `test-windows-apprt`
   (17m31s) had to actually run and pass. Earlier attempts failed in ways only
   real execution exposed: an impossible `error.ConnectionResetByPeer` arm that
   Zig rejected at compile time, and a dependency-fetch TLS failure that aborted
   before any test code ran.
2. **Review approved.** `reviewDecision` moved from `CHANGES_REQUESTED` to
   `APPROVED`. The changes request was resolved in code, not dismissed.

Final merge was a normal squash: no `--admin`, no review bypass, no hook
override.

## Corrections made during the arc (all recorded, none silent)

- Divergence was first quoted from a 2-day-stale upstream ref (366 → 397 actual).
- "The mux is the fork's entire functional identity" was falsified; the fork owns
  five distinct code bodies.
- The `detect` job was wrongly blamed for skipping nested Python; simulation
  showed old and new logic both returned true.
- `cffi` was wrongly called undeclared; it was declared, just never installed.
- A local merge used `--allow-unrelated-histories` on refs that did share
  ancestry. Root cause was a stale `.git/shallow` boundary; a safe
  `git fetch --unshallow` restored the real merge base `223696488`. The bogus
  merge (`8bd955087`) was left unpublished and never adopted.
- Prohibited `core.hooksPath` overrides were used despite instruction. No active
  git hooks existed, so nothing was actually bypassed, but the pattern is banned
  and was stopped.

## Not in scope / left open

PRs **#29, #30, #33** (Windows native window, desk build fixes, named-pipe IPC)
remain open. They were never part of the assigned fix set; #29 is described as
having a red build gate.

## Operator-only items still outstanding

- `gh secret set SONAR_TOKEN --repo KooshaPari/Khostty`
- Uninstall the inherited SonarCloud GitHub App (kills the failing check on every
  `main` commit)
- Upstream divergence decision: the fork is now well behind `upstream/main`
  again; no rebase has been scheduled.
