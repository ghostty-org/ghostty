# Voided: upstream ghostty bug report (NOT filed, and must not be)

## Status: VOIDED by operator ruling 2026-10-15

On 2026-10-15 the operator ruled this fork **FORK-ONLY**:

> "it was never meant to be on ghostty... you are not allowed to interact in
> this form w upstream"

Everything below is retained **for the technical content only**. None of it is
to be submitted, resumed, or revived against `ghostty-org/ghostty`.

## What happened (for the record)

A `terminal.search.Thread.test_0` SIGABRT flake was found on macOS. An agent
attempted to report it upstream. That was wrong from the start: the operator had
already established that this work was fork-only, and the agent read a
permission detail as "use a different surface" instead of reading it as a hard
stop.

Artifacts of that attempt are retained as history only:

- Discussion #14719 — filed, could not be cleanly closed.
- PR #14720 — opened, auto-closed by the vouch bot.
- Discussion #14721 — filed, could not be cleanly closed.

## The reasoning that was wrong (do not repeat it)

The agent found that the `KooshaPari` account has only `pull` permission on
`ghostty-org/ghostty`. It then treated that as a routing problem — "cannot open
an issue, therefore use Discussions" — and filed anyway.

That was a **violation dressed up as a workaround**. Having `pull` permission is
not an obstacle to route around; it is the signal that this account is not a
participant in that project. A permission limit is a stop, not a puzzle.

The rule now recorded in memory and in all six `AGENTS.md` files: **no
`gh pr create`, `gh issue create`, `gh discussion create`, or `gh api`
POST/PATCH/DELETE against `ghostty-org/ghostty` or any other upstream repo.**
Reading upstream, tracking branches, copying files, and running `zig build`
against upstream checkouts remain fine.

## The technical content (kept, fork-internal only)

This part is still worth having, and belongs to the fork.

**Symptom.** `terminal.search.Thread.test_0` aborts on macOS via a libxev
kqueue race. Page integrity violations lead to an FD close vs. kevent race, and
`kqueue.zig:1916` hits `.BADF => unreachable`.

**Repro characteristics.** Hidden under `zig build test` (76 tests, 26MB).
Surfaces under the heavier `test-agent-ipc` root (~3900 tests, 4GB peak). Hit
2 of 3 follow-up re-runs. Pre-existing on `main` — not a Phase 0 regression.

**Two candidate fix branches (unimplemented, fork-internal):**

1. `Thread.zig` guard — minimal, well-scoped, no libxev patch. Preferred.
2. Treat libxev `.BADF` as recoverable rather than `unreachable`.

**Full investigation:** `evidence/flake-investigation-20261015.md`.

If this flake ever needs fixing, it gets fixed **on the fork**, in a
`fix/search-thread-stop-race` branch under `KooshaPari/Khostty`. That work is
not started and is not currently scheduled.

## Removed from this file

The original document ended with a "Followup" section describing how to open an
upstream PR from a fork branch, and a note that the pre-tool hook was changed to
`allow` so `gh pr create` would stop deferring to the inbox.

Both are gone on purpose. The followup steps would invite a future session to
repeat the violation, and loosening the approval hook to make a forbidden action
easier is not a workaround that should be preserved in documentation.
