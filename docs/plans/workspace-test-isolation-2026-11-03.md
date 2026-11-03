# Workspace notification isolation and asynchronous test waits

This is a source follow-up to the test failures recorded for OMG 0.19.0.
The published release validation remains a historical record.

## Reproduction

On the clean `v0.19.0` source at `5f9589dbf`, this same-host selection failed:

```sh
macos/build.nu --action test --only-testing \
  'GhosttyTests/TerminalWorkspaceSwitchSchedulingTests/fullscreenFailureDoesNotDrainCommandsInsideTheNativeCallback(),GhosttyTests/WeakLocalEventMonitorTests'
```

Three tests ran in two suites. The two modal button expectations timed out.
The workspace test posted `NSWindow.willEnterFullScreenNotification` through
the global notification center, then cleared only the adapter's own transition
state. That synthetic notification also reached observers outside the adapter.
The precise internal AppKit state responsible for the modal behavior was not
established by the earlier key-window diagnostics.

## Change

`TerminalWorkspaceNativeAdapter` accepts a notification center and removes its
observers from that same center at destruction. Its production default remains
`NotificationCenter.default`.

Scheduling, management, queued-popover, and layout tests now send synthetic
fullscreen transitions through fixture-owned centers. They still exercise the
adapter's registered observer closures and asynchronous completion queue.
Real native fullscreen desktop tests continue to observe system notifications.
The synthetic close test no longer needs a fabricated global fullscreen exit.

Positive asynchronous assertions wait for the relevant callback, model outcome,
or committed workspace with a three-second bound. They no longer assume a
successful result after a fixed 20 or 100 ms delay. Existing negative observation
windows remain where the test checks that a queued operation did not run.

The modal mouse-event assertions are retained. A serialized, parameterized
regression covers synthetic close, fullscreen failure, and failure followed by
a newer exit, then creates an alert and posts real AppKit mouse-down/up events
to both buttons within the same test. This ordering is independent of suite
scheduling and remains part of routine coverage.

The shared `AppKitTestWait.swift` helper is registered as broad test
infrastructure in the selector, with an offline contract assertion.

## Validation

On 2026-11-03:

- Initial focused regression: 71 tests in six suites passed.
- Complete same-host routine sweep: 1,384 tests in 173 suites passed in
  342.518 seconds. This was one invocation, not fresh-host batches.
- The real 60-tab desktop regression
  `TerminalWorkspacePopoverSwitchTests.nativeFullscreenMouseSelectionClosesAndSwitchesWithoutAnotherKey`
  passed in 10.542 seconds. The already-running test host was verified against
  the checkout's Debug executable before activation. Its foreground and native
  fullscreen prerequisites remained enabled.
- Strict Swift lint: zero violations in 573 files.
- All 42 offline test-selector contracts passed, including the shared wait
  helper's broad-scope selection.
- Documentation and whitespace checks passed.

The Swift source did not change after the complete sweep. The subsequent
selector mapping was validated offline and the real desktop test ran against
the final Swift source. Other optional desktop suites and XCUITest were not
run as part of this focused repair.
