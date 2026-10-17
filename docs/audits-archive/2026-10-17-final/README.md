# Khostty Fork Audit — 2026-10-17 (Archive Snapshot)

This directory is a **versioned snapshot** of the 2026-10-17 khostty fork audit,
frozen at the point of the orchestrator's synthesis pass.

## What's here

| File | Lines | Purpose |
|---|---:|---|
| `FINAL-AUDIT.md` | ~270 | Synthesis: executive TL;DR, current state, what's done, what's unfinished, runtime gaps, shippability verdict |
| `FWD-PATH.md` | ~445 | Forward-path roadmap: Phases A/B/C/D + open operator decisions + effort budget |
| `state.md` | ~258 | Canonical current state — author of truth where reports conflict |
| `mux.md` | ~262 | Phase 0/1 detail; **stale on Phase 0 merge — Phase 0 is now on `main`** |
| `stubs.md` | ~217 | 61 findings; **stale on Phase 0 merge** |
| `usability.md` | ~302 | CVP / MVP / intended user |

## Stale-on-merge caveat

- `mux.md` and `stubs.md` list "merge Phase 0 → main" as an open carry-forward;
  **Phase 0 merged via PR #15 at `ebc033eba` on 2026-10-15**. Their Phase 0
  carry-forwards are void at the time of this snapshot.
- The audit synthesis in `FINAL-AUDIT.md` resolved all conflicts via
  `state.md` being authoritative.

## Where the live work lives

The canonical live working copies of these audits live in
`docs/audits/` (untracked, per binding rule #10 — never `git add` them).
This `docs/audits-archive/2026-10-17-final/` snapshot exists for the
repo's tracked history only.

## Provenance

- Author: VP-Eng (jcode orchestrator, tier-0 M3) on 2026-10-17T05:18Z
- Method: read-only synthesis of 4 sibling reports + 2 cross-checks
- Companion: see `FINAL-AUDIT.md` §0 "Inputs (consolidated)" and the
  `20261016-fork-reset/` session doc (also untracked)
- Binding (operator 2026-10-15): FORK-ONLY. No `gh pr/issue/discussion create`
  or `gh api POST/PATCH/DELETE` against `ghostty-org/ghostty` or any other
  upstream repo. Push to `KooshaPari/*`: fine.

## How to use this snapshot

Read `FINAL-AUDIT.md` first (executive TL;DR + verdict), then `FWD-PATH.md`
for the next concrete steps (Phases A/B/C task lists). The 4 sibling reports
are reference material and have been folded into the synthesis.