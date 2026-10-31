# Hover pixels and native tab creation

Baseline: `05c9f92f1`. The installed `OMG Dev` was verified to contain that
commit. The user's report therefore concerns the previous repair, not an old
installation. The observed live group contained 40 tabs.

## Hover: state was changing without repainting the row

Tabs, Files and Agent History share `NativeHoverRowView`. The close button has
its own native control rendering. Earlier tests called the hover owner directly
and checked its Boolean state, but did not establish that the table repainted
both backgrounds during normal window display.

The new baseline regression attached real table rows to a window, changed the
hover owner, then called `window.displayIfNeeded()`. Both the outgoing and
incoming row reported **zero** `drawBackground` calls. This reproduces a concrete
reason for a stale background while the close button remains responsive.

The shared row now owns a small shape layer for hover. Changing hover updates
that layer without implicit animation, independent of NSTableView's cached
background painting. Native selection remains separate and suppresses hover
on the selected row. Theme, attachment and layout update the shape. No hover
timer, table reload or synchronous window-wide display was introduced.

The regression samples rendered layer pixels: idle -> hovered -> idle for the
outgoing row, and idle -> hovered for the incoming row. It also checks selection
suppression and absence of implicit layer animations.

## New-tab correctness and repeated work

- The native `newWindowForTab` action returned before the added window became
  the selected tab. A regression failed on that exact boundary. It now uses the
  existing controller creation path and completes its pending presentation in
  the same call. The already-queued work item is cancelled afterward.
- Attachment completion initializes native title/icon content before selection.
  The native "+" path also refreshes selected chrome before returning. Tests
  verify a nonempty glyph, selected accent, stable membership and no delayed
  replay that changes the selection.
- Tab membership is no longer broadcast through every terminal controller.
  Lists already observe the shared tab presentation. Controller selection
  notifications are limited to the outgoing/incoming terminal shells.
- Workspace reconciliation assigned identical workspace UUIDs to `@Published`
  properties on every controller. A didSet equality guard cannot prevent that
  publisher's pre-change notification. Equality is now checked before assignment;
  unchanged native tabbing identifiers are also left alone.
- Parent window geometry is assigned before installing the new SwiftUI root.
  Native shortcut labels avoid equivalent attributed-string writes and empty
  trailing spaces. Native group appearance callbacks coalesce after AppKit's
  mutation and repair only the displayed window.

## Measurements and remaining limitation

The fixture creates 40 additional tabs with `/bin/sleep 120`, in a fresh test
process, for both layouts. It measures synchronous creation and elapsed time
until native selection. It is not shell startup or a physical input-to-photon
measurement.

| Layout, final group size 41 | Baseline create | Baseline selected | Repair create | Repair selected |
| --- | ---: | ---: | ---: | ---: |
| Vertical | 325 ms | 614 ms | 201 ms | 393 ms |
| Horizontal | 304 ms | 618 ms | 340 ms | 593 ms |

These are observed runs, not a statistical performance guarantee. Horizontal
large-group creation has **not** reached the requested responsiveness. Sampled
creation stacks include AppKit's `_syncInactiveTabWindowSizesToWindow` and
`CA::Transaction::flush`, which perform layout/display work across the native
window group. The retained changes remove proven redundant work and fix the
native action boundary; they do not remove the cost of one native window per tab.

An experiment disabling automatic sizing on the outer hosting view did not
produce stable gains, especially horizontally. It was reverted so the existing
initial-size contract remains unchanged.

Two diagnostic tabs created in the installed app were cleaned up, returning
its native group to 40 tabs. One exhibited the missing-icon/gray-item symptom;
its background close button did not act through AX, while selecting that
diagnostic tab and closing it with the normal shortcut did. This observation
is retained separately from proof about AppKit's private item implementation.

## Browser implementation comparison

Inspected upstream Chromium sources:

- [Tab](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/views/tabs/tab.cc):
  mouse entry/movement/exit updates that tab's hover state and delegates local
  hover presentation. Movement can recover a missed entry.
- [TabStrip](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/views/tabs/tab_strip.cc):
  `AddTabsAt` creates tab views and inserts them into its tab container.
- [BrowserView](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/views/frame/browser_view.cc):
  `OnActiveTabChanged` updates the active contents view's `WebContents`,
  separately from the tab strip's view insertion.

These are Chromium Views implementations, not a drop-in AppKit tab kit.
The useful comparison is ownership of hover pixels and tab presentation.
Safari's application tab implementation was not inspected, and no claim is
made that WebKit's example browser is Safari's UI.

## Evidence and verification

- `/tmp/omg-hover-tab-baseline.log`: failing background-paint regression and
  40-tab baseline timings.
- `/tmp/omg-tab-native-action-baseline.log`: failing immediate native selection
  contract; its timings include sampling overhead and are not used in the table.
- `/tmp/omg-tab-phase-vertical.sample` and
  `/tmp/omg-tab-phase-horizontal.sample`: private bounded source-test samples.
- `/tmp/omg-hover-tab-final-benchmark.log`: passing pixel, publication, native
  action and large-group tests; repaired timing values in the table.
- The 160-suite catalog was exercised in seven fresh-process batches:
  1,278 tests, with one skipped benchmark and one failing quit/session fixture
  in the initial sweep. The fixture passed alone, but depended on the global
  workspace coordinator. It now owns an isolated runtime and restores its
  quit state before teardown; all order/freeze/cancel assertions are retained.
- Subsequent larger window runs retained borderless-fullscreen failures.
  A same-environment control temporarily used the preceding commit's source,
  then restored every edited source file. Both the baseline and repaired source
  failed `nativeTabObservationSurvivesRepeatedBorderlessStyleChanges` with the
  same seven membership assertions; both passed the companion workspace
  round-trip case in that two-case control. This does not establish that the
  remaining fullscreen stress issue is fixed.
- Final focused regression: **37 tests in five suites passed**, including
  the isolated session fixture, native controls, shell geometry, hover pixels,
  native "+" selection/glyph state and 40-tab creation.
- The final post-cleanup check passed **10 tests in three suites**. SwiftLint
  passed all 553 scanned files, and documentation/whitespace checks passed.
- The desktop tool subsequently confirmed that the Mac was locked. Physical
  pointer acceptance of the repaired binary was therefore not completed.
  Later timing runs after locking are not used as a foreground before/after
  comparison.

Additional logs:

- `/tmp/omg-hover-tab-batch-plan.json` and `/tmp/omg-hover-tab-batch-results.json`
- `/tmp/omg-hover-tab-batch-6-rerun.log`
- `/tmp/omg-hover-tab-fullscreen-base-control.log`
- `/tmp/omg-hover-tab-fullscreen-current-control.log`
- `/tmp/omg-hover-tab-delivery-tests.log`
- `/tmp/omg-hover-tab-final-check.log`

The running installed app was not restarted or replaced during this review.
Passing state or pixel tests is not a substitute for physical hover acceptance
of the new binary.
