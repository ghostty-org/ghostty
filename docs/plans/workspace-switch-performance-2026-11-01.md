# Loaded workspace switching with 60 tabs

## Scope and baseline

The user confirmed the fullscreen workspace hang was fixed in `1b9a05a04`,
but returning to an already loaded 60-tab workspace still paused.
This change keeps the retained native group, terminal controllers, surfaces,
PTYs, and workspace ownership introduced by that repair.

A bounded test creates 60 source tabs and two one-tab workspaces, then runs
60 round trips (120 switches). A one-shot, test-only configuration at
`/tmp/omg-workspace-switch-profile.json` selects the bounded workload and is
removed as soon as the test reads it. Normal routine runs remain at 40 tabs
and eight switches. The readiness file identifies the test PID, which the
external sampler verifies against the source-built test application's path.
No profiling settings or stack logging are added to the product.

The baseline sample covered ten seconds at a requested one-millisecond
sampling interval. It identified native tab selection and tab-bar view
attachment as the dominant synchronous path: 1,757 of 3,540 main-thread
samples were below the adapter's `showWindowSafely` calls. The path includes
`NSWindowStackController` tab-bar attachment, view/window propagation,
Auto Layout, and SwiftUI focus traversal. Repeated ownership scans were a
smaller contributor in this sample.

## Changes

- Retain each window's original native tab accessory in its chrome controller.
  Vertical layout detaches it from `NSWindowTab`; horizontal layout restores
  the same view and arranged subviews. Hidden horizontal-only accessories no
  longer join AppKit's native tab-bar hierarchy for every vertical selection.
  Pending and parked tabs also receive layout-mode changes.
- For an already retained vertical group, prepare geometry only for the selected
  destination. Resizing every member
  of a large incoming workspace made fullscreen returns update hidden windows.
  Other tabs keep their frames and IOSurfaces until selected, when the existing
  tab-presentation path prepares their final size. Topology changes and entry
  into or exit from isolated modes retain their original geometry preparation.
- Parked sidebar subscriptions defer store/metadata refreshes. Activation and
  explicit `configure` still render current state synchronously. A new tab
  awaiting attachment does not resolve an unnecessary native group here.

The final implementation preserves the existing complete publication,
next-turn repair, and ownership reconciliation. The initial experiment also
coalesced completion work and indexed owners; those changes were withdrawn
while isolating fullscreen boundary failures. Readiness of the focused pane
alone does not prove every delayed native attachment has finished.

## Measurements

These are test-process wall-clock measurements, not hardware input-to-pixel
latency. Both long-loop runs include external sampling, whose overhead affects
absolute timings, especially the tail. First creation remains a separate cost.

| 60-tab, 120-switch experiment | Baseline | Final implementation |
| --- | ---: | ---: |
| Enter large workspace, mean | 153.119 ms | 89.397 ms |
| Leave large workspace, mean | 143.343 ms | 88.491 ms |
| All warm switches, median | 116.958 ms | 60.104 ms |
| All warm switches, p95 | 456.925 ms | 200.486 ms |
| Warm native attach calls | 0 | 0 |

Both runs preserve all 62 Surface identities and native group members.
The final measurements use the conservative implementation with the original
complete publication and next-turn repair restored (`final.log`).
Logs and samples are under
`/var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-ws60-profile-4wj_dtyk/`.

The real foreground fullscreen mouse regression revealed a separate geometry
cost after that first pass. Its first return to 60 loaded tabs took 1,830.130 ms.
Restricting frame preparation to the selected destination reduced the same
case to 209.179 ms. These are single observations of event delivery through
committed presentation, including the test's readiness polling, not a claim
about a percentile or compositor display time.

The final conservative implementation completed this foreground mouse return
in 233.884 ms (`/tmp/omg-ws60-desktop-final-2026-11-01.log`).

Evidence:

- `/tmp/omg-ws60-desktop-foreground-2026-11-01.log`
- `/tmp/omg-ws60-desktop-selected-frame-2026-11-01.log`

## Validation

The first focused run passed 41 tests across five suites. The geometry
regression separately verifies that returning to a workspace leaves an
inactive tab's frame unchanged, then selecting that tab prepares a correctly
sized IOSurface without replacing its Surface.

The first desktop attempt failed its foreground/key-window prerequisite before
executing the switching assertions. A subsequent foreground run completed the
actual 60-tab mouse path with a child panel attached to the popover, without
an extra key. The run checks the active Space, fullscreen/key window state,
native group membership, and picker reuse.

The two borderless focus/membership cases also failed against unchanged
`1b9a05a04` product sources, both in a routine background run and in a foreground
control. They now declare their real desktop requirement and verify active/key
window and Space before acting. The final foreground run passed both cases;
this does not establish that the baseline's intermittent behavior is universally
fixed. Fixture teardown now marks its coordinator as quitting before closing
windows, so teardown callbacks cannot reactivate parked workspaces.

The retained-group reorder regression exposed another intermediate-state
hazard: removing a selected tab can briefly select a parked neighbor. Reorder
and canonical sorting now use the existing presentation transaction, restoring
selection before publishing. The test arranges interleaved foreign tabs without
activating their workspace, then checks native order, selection, and parked state.

Final routine regression passed 1,308 tests across 164 suites in 16 serial
batches. Results are in
`/tmp/omg-ws60-regression-rj564om1/final-results.json`.
The first Git batch had one `GitExpansionTimeout` in
`refreshAndPagingKeepChangesAndLoadedHistory(refreshFirst: true)`.
Its seven-test suite passed in isolation, then the entire 125-test batch passed.
The first failure is retained separately in `first-git-batch-failure.json`;
no Git implementation was changed for this retry.

The selector contract passed all 41 Python tests. Changed-file SwiftLint
passed for all 11 Swift files, and documentation checks passed.
The pre-install workspace checkpoint, settings, and old Dev bundle are backed
up in `/tmp/omg-ws60-dev-backup-20261101-135718` (75 tabs, 14 workspaces).
Only `/Applications/OMG Dev.app` is a development installation target.
The delivery report records the exact installed commit version and recovery
verification.

The final native desktop run passed the 60-tab mouse round trip, native sidebar
click/focus preservation, and both parameterized fullscreen tests covering
horizontal and vertical creation/switching. The system drag test stopped at
`CGPreflightPostEventAccess()` before posting any events; its drag behavior is
NOT RUN, not passed. The separate final borderless run passed both methods in
`/tmp/omg-ws60-borderless-final-2026-11-01.log`.
