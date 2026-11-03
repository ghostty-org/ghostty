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
