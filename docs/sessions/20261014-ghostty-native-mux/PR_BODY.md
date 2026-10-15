# Phase 0: wire agent IPC into the Zig build graph

> **Fork-internal record.** This was originally drafted as a PR body for
> upstream `ghostty-org/ghostty` on 2026-10-15. That submission was voided by
> the operator's fork-only ruling — see `UPSTREAM_BUG_REPORT.md` in this folder
> for the full account. The technical content below was always correct and is
> kept as the record of what Phase 0 did. **Nothing here is to be sent upstream.**

## Summary

Wires `src/apprt/ipc/app_host.zig` (the `Host` vtable bridge onto the real app runtime) into the Zig build graph for the first time, behind a new `test-agent-ipc` step.

The IPC layer has been unit-tested against `fake_host.zig` since G4. The bridge had never been compiled. Phase 0 closes that gap and nothing more.

## Changes

- **`src/main_agent_ipc.zig`** (new, 89 lines): test root mirroring `src/main_windows_apprt.zig`. Sits in `src/` (not `src/apprt/ipc/`) because the IPC modules reach `../../App.zig`, `../../Surface.zig`, etc. — imports Zig rejects from a module root three levels deep.
- **`build.zig`** (+43 lines): new `test-agent_ipc` step mirroring the `test-windows-apprt` block verbatim.
- **`src/apprt/ipc/app_host.zig`** (-7 lines): removed dead `_ = param;` discards in 7 functions (`titleOf`, `cwdOf`, `pidOf`, `colsOf`, `rowsOf`, `pixelSizeRows`, `scrollbackRows`). Zig 0.16 rejects them when the same param is read in the live `if (comptime windowed)` branch.

## Verification

- `zig build test-agent-ipc` → 85/85 steps, 3900/3925 pass, 25 skipped.
- Wall-clock: ~46m cold-cache, ~30m cache-warm.
- Only GTK is `windowed` on this host, so vtable bodies still need `-Dapp-runtime=gtk` for full type-check. Signatures and imports resolve cleanly. An availability-contract test prints the diagnostic `app_host is compiled but NOT windowed (artifact=exe): the 'none' runtime has no windows` on stderr.

## Flake note (pre-existing on `main`)

**Symptom.** `terminal.search.Thread.test_0` aborts on macOS via a libxev
kqueue race. Hidden under the lighter `zig build test` root (76 tests, 26MB);
surfaces under the heavier `test-agent-ipc` root (~3900 tests, 4GB peak). Hit
2 of 3 follow-up re-runs. **Pre-existing on `main` — not a Phase 0
regression.** Investigation report: `docs/sessions/20261014-ghostty-native-mux/evidence/flake-investigation-20261015.md`. Two candidate fixes are recorded there (a `Thread.zig` guard, or treating libxev `.BADF` as recoverable); neither is implemented. If it is ever fixed, it is fixed **on the fork**. The Phase 0 commit itself produced a clean `85/85 / 3900 pass / 25 skip` result.

## Out-of-scope (Phase 1 needs GTK-runtimed CI)

Phase 1 of the mux design (the mux shell binary reusing `protocol.zig`/`auth.zig`) needs the GTK runtime builds to fully analyze the vtable bodies.

## See also

- Design brief: `docs/sessions/20261014-ghostty-native-mux/00_SESSION_OVERVIEW.md`
- Results: `docs/sessions/20261014-ghostty-native-mux/01_PHASE0_RESULTS.md`
- Original build log: `docs/sessions/20261014-ghostty-native-mux/evidence/agent-ipc-build-20261014.log`
- Wall-clock re-runs: `evidence/agent-ipc-cache-warm-20261014.log` and `evidence/agent-ipc-incremental-20261014.log`
- Flake investigation: `docs/sessions/20261014-ghostty-native-mux/evidence/flake-investigation-20261015.md`
