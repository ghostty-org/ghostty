# Runtime presentation and launch recovery

## Scope

Investigate the regressions reported after the session runtime merge: black
terminal backgrounds, workspace switching flashes, and a running App with no
visible terminal after forced termination or tab selection. Baseline:
`c1aff279dfb09594589f4ebb4c0c8b360eaaf797`.

## Confirmed defects and repairs

- Runtime snapshot replacement discarded the viewer's configured color defaults.
  Preserve the viewer defaults while keeping program color overrides and resets
  authoritative in the incoming snapshot. Exercise the actual RenderState, not
  only the snapshot fields. Register the helper tests at module scope so the
  filtered test executable actually discovers them.
- Workspace restoration parked retained native tabs a second time with
  `orderOut`, removing them from the group the native adapter had restored.
  Keep retained membership under the adapter's ownership.
- Hidden-window recovery selected the first workspace in catalog order rather
  than the current workspace and selected tab. Dock reopen also treated existing
  controllers as proof that a window was visible. Present the current workspace
  on reopen/activation, excluding closed controllers and deferring during
  restoration, termination and native fullscreen transitions.
- A workspace presentation replayed global last-window geometry after preparing
  the destination frame. Preserve the prepared frame through `showWindow`.
- Launch without a pending AppKit selection snapshot bypassed the injected
  restoration owner. Use that owner in both launch branches.
- Non-native fullscreen restored a captured sidebar responder after that view
  had moved out of the window during style/workspace changes. Both deferred
  entry and synchronous exit now validate the view's current window before
  restoring focus. Two focused regressions failed before this repair and passed
  after it.
- Desktop regression coverage now locates the workspace create/save controls by
  accessibility identifier before sending real AppKit mouse events. Former
  coordinate guesses missed the resized native editor. Workspace assertions
  check selected-window, parked-state, responder and sidebar ownership while
  requiring retained native membership, rather than assuming parking removes
  windows from their native group.

## Evidence and acceptance boundaries

- The color regression failed before the fix and passed after it, including
  program overrides/reset behavior: 76 Zig tests passed.
- Three launch/restoration regressions failed before the Swift fixes; the
  focused launch, integration and selection run passed 29 tests. A fourth frame
  regression also failed before its fix; launch/presentation/local-runtime
  integration then passed 13 tests.
- Private profiles used separate bundle IDs, configuration, preferences and
  application-support directories. Force-killing only the private GUI and
  restarting preserved pane UUIDs and all three child process PIDs. The final
  fixture used two separate files with `vi -n`, plus a continuously printing
  shell in a split. Both panes rendered with the configured blue background
  after recovery. Test sessions were explicitly closed afterward.
- The simple two-tab process fixture passed on both the baseline and fixed
  build. It did not reproduce every reported no-window scenario. The retained
  multi-workspace membership, hidden-current-workspace and frame defects have
  separate before/after regression evidence.
- No recent OMG system crash report was found during initial triage. The user's
  relevant vim and loop processes were still alive. Missing historical runtime
  records and old remote runtime versions are distinct from window visibility;
  this repair does not turn them into new shells or claim to recover lost PTYs.
- The Mac rebooted during the task, clearing the original temporary evidence
  directory. The pre-reboot results above were observed before that reboot.
  Subsequent evidence and a fresh backup of all 27 saved tabs are under a
  private directory in `~/.codex/tmp/`; no raw session data is checked in.

## Validation

- The full routine run executed 1,369 tests in 170 suites. It reported four
  issues in two existing suites (EditorWorkspaceLifetimeTests and
  WeakLocalEventMonitorTests). Both passed in a fresh host together with
  TerminalWorkspaceLaunchTests and SessionRuntimeLocalIntegrationTests:
  eight tests in four suites. The full-run host accumulated substantial AppKit
  and PTY resources; its result is recorded separately from the isolated pass.
- After the focus repair, 22 tests in NonNativeFullscreenFocusTests,
  TerminalWorkspaceLaunchTests and TerminalWorkspaceManagementTests passed.
- Before reboot, the actual native-fullscreen popup click regression passed.
  Broader desktop checks exposed stale retained-group assertions and incorrect
  create/save click coordinates, corrected here. After reboot, separate-host
  desktop retries failed at the foreground prerequisite despite activating the
  verified, ready test PID; they did not reach fullscreen assertions. These
  retries are not desktop acceptance passes.
- On reboot a non-test copy from `macos/build/Debug/OMG.app` was running with the
  same Debug bundle identity as the installed Dev app. It was normally quit
  before isolated desktop checks. Test readiness now has an explicit PID marker.
- Release OMG and its data are outside this task.
