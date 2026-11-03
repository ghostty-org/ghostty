# OMG 0.19.0 validation and deferred test repairs

## Release decision

On 2026-11-03 the maintainer authorized releasing 0.19.0 before repairing the
known order-dependent Swift UI test failures if a complete repair would take
substantial time. The estimated repair and verification effort was 45-90 minutes.
This is a scoped exception for the recorded Swift failures, not a claim that the
routine suite passed or a change to the normal release policy.

## Existing test evidence

The release preparation ran 1,383 routine Swift tests in 173 suites in one host.
Recorded failures included:

- `TerminalWorkspaceIntegrationTests.workspacePopoverSurvivesAnchorUpdatesAndExecutesActionOnceAfterClosing`:
  the completion count was not one after a fixed 100 ms delay.
- `WeakLocalEventMonitorTests.modalButtonsReceiveClicksAfterMonitorOwnerExpires`:
  synthetic Cancel and Confirm clicks timed out and the modal returned abort.
- `TerminalWorkspaceSwitchSchedulingTests.latestQueuedTargetStillAppliesWhenTransitionFinishes`:
  a later broad run did not observe the queued workspace committed after its
  fixed 100 ms delay.

Focused retries passed. Earlier successful broad coverage used 15 fresh-host
batches; that result does not establish same-host isolation.

The existing test-only repair balances the synthetic fullscreen entry in
`closingATransitionWindowDoesNotLeaveItsHostQueueWaitingForever` with an exit
notification. It does not fix every synthetic transition in the suite.

Retained Xcode results from 18:33, 18:35, 18:36, and 18:39 on 2026-11-03 show
that running `fullscreenFailureDoesNotDrainCommandsInsideTheNativeCallback`
before the modal suite reproduces the modal failure; running the modal suite
alone passes. Diagnostic event monitors saw mouse-down delivery to the alert.
Both passing and failing runs could report no key window, so that observation
alone does not establish the underlying AppKit mechanism.

## Deferred repair

- Isolate synthetic native transition notifications from the process-wide
  notification center where practical, and balance lifecycle fixtures on every
  exit path.
- Replace fixed sleeps with bounded waits for the completion being asserted.
- Preserve modal mouse-event regression coverage rather than relabeling it to
  exclude a failing test.
- Verify the failing combinations and then the complete same-host routine
  sweep. Report optional interactive desktop coverage separately.

The release notes disclose the unresolved sweep and the unexecuted platform,
Agent recovery, native desktop, and permission-migration checks. Release
artifacts still require persistent signing, architecture, runtime-bundle,
DMG, launch, and Sparkle verification.

## Release preparation checks

- Strict Swift lint: zero violations in 572 files.
- Zig formatting, settings JSON, application plist, XIB, documentation contract,
  and whitespace checks passed.
- Signing policy: 17 tests, including two optional skips. Keychain contract:
  15 tests, including one optional skip. Test selector contract: 42 tests passed.
- The final version metadata, synthetic close-transition cleanup, and modal
  suites passed together: eight tests in three suites. This focused result does
  not supersede the known broad-sweep failures.
- Runtime formatting and strict Clippy passed. Rust tests: 49 passed.
- Runtime Python discovery: 26 tests, 23 passed and three skipped because an
  explicit SSH deployment, disposable Linux containment host, and legacy
  packaged local runtime were not configured.
- Runtime bundle contract: two tests passed. SSH Agent wrappers: six passed.

## Final artifact verification

- ReleaseFast arm64, x86_64, and universal Apps built as OMG 0.19.0, build 46.
- Every App contains a universal local relay and macOS aarch64/x86_64 plus Linux
  aarch64/x86_64 runtime artifacts. All platform manifests and SHA-256 hashes
  were verified after signing.
- Runtime revision: `4c3958f3604e5884d8d7`; snapshot revision:
  `59c5cc7b4d1fe408faf5`. The bundled relay reports
  `omg-session-runtime/2 snapshot/1`.
- The persistent release signature and designated requirement were verified
  against the preserved 0.18.0 App. All three read-only mounted DMGs passed the
  same signature and identity checks.
- arm64 and universal App and mounted-DMG command-line launch probes passed.
  Intel architecture checks passed; Intel execution was not run because
  Rosetta is unavailable. These are not GUI interaction or TCC upgrade tests.
- The actual arm64 App's generated SSH bootstrap matched the current source;
  all six Agent-wrapper checks passed. Twelve shell scenarios passed using
  Bash, Zsh, and Fish with a local fake SSH transport; no external SSH host was
  used.
- Fifteen local session, reconnect, close, inline-viewer, and working-directory
  tests passed using the signed packaged relay in isolated temporary fixtures.
  This does not establish execution of the foreign-platform binaries or real
  Agent conversation recovery.
- Sparkle's EdDSA archive signature was verified. Its public key matches
  0.18.0, and the new feed advances build 45 to 46 while preserving older items.

Release DMG checksums:

```text
b29ef6393b928c5f9f480fc2d7a63e8d33691c8cd93f11a00f80f8d5f2e99b45  OMG-0.19.0-macos-arm64.dmg
42f62efe21266f7ecf48396f93e2aa168f16a68224d4bf33c9c09c93d94cb06d  OMG-0.19.0-macos-x86_64.dmg
aa9c009d3239ac62b9475139d756f3c6dc3d1aede0f9132799af340a8c2de5d4  OMG-0.19.0-macos-universal.dmg
```
