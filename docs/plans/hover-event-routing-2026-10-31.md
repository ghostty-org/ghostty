# Native hover event routing

Baseline: `76179b206`, also verified in the running `/Applications/OMG Dev.app`
as `0.18.0-dev.76179b20`. The existing group contained 40 tabs.

## Root cause and why earlier regressions missed it

`NativeTableHover` inherits `NSObject`, not `NSResponder`. Its Swift declarations
`@objc func mouseMoved(with:)`, `mouseEntered(with:)`, and `mouseExited(with:)`
exported `mouseMovedWith:`, `mouseEnteredWith:`, and `mouseExitedWith:`.
`NSTrackingArea` calls the AppKit selectors ending in a single colon without
`With`. A runtime probe and the new baseline test confirmed that the actual
tracking owner did not respond to any of the three expected selectors.

The tab cell used an independent `NSView` tracking override with the correct
selector. Its close button followed the pointer while the table background
only caught up during layout or scrolling. Files and Agent History used the
same broken table tracking owner. This accounts for the reported disagreement
between the background and close button.

The previous tests called Swift methods or assigned hover state directly.
Rendered-pixel checks verified drawing, but bypassed Objective-C event routing.
They could not detect this failure. The earlier pixel repair remains useful,
but did not establish working pointer tracking.

## Repair

- Explicitly export `mouseEntered:`, `mouseMoved:`, and `mouseExited:`.
- Give tab row backgrounds and close-button visibility one shared hover state;
  remove the cell's independent tracker and Boolean.
- Observe only the table's own clip view and window. Rebind on window moves and
  clear on hide, detach, or resignation of key status.
- Coalesce scroll/layout reconciliation. Use window-local pointer coordinates
  on the scroll path; keep topmost-window validation for attachment, activation,
  and unhide. Newer pointer events invalidate queued reconciliation.
- Update hover geometry only when bounds change and color only when its theme
  changes. A row transition updates layer visibility and its controls without
  reconstructing paths or resolving the theme.

The debugging skill now treats a repair request as authorization for scoped
Dev observation, builds, installation, and restart required for verification.
It still protects release OMG and existing session data. Its regression guidance
explicitly distinguishes event routing, rendered pixels, and desktop input.

## Evidence

- `/tmp/omg-hover-routing-baseline.log`: the original owner failed all three
  AppKit selector checks.
- `/tmp/omg-hover-selector-repair.log`: 20 tests in four suites passed.
- `/tmp/omg-hover-selector-regression.log`: 49 tests in ten affected suites passed.
  These cover selector dispatch, shared row/control state, stationary-pointer
  scrolling, exit cancellation, row pixels, path reuse, native tab lifecycle,
  Files, Agent History, and Inspector pane retention.
- `/tmp/omg-hover-final-swiftlint.log`: 554 Swift files, no violations.
- Documentation, skill schema, and whitespace checks passed.

The routing fixtures use the real Objective-C selectors through `NSApp.sendAction`
and actual clip-view notifications. They deliberately do not claim to simulate
WindowServer input. An attempted fake-window `sendEvent` fixture could not
reliably deliver even child-control movement and was replaced, rather than
being counted as desktop acceptance.

`VerticalTabMouseTests.repeatedKeyboardCreationAndPointerTracking()` now checks
actual native row and close-button state instead of the obsolete SwiftUI
`hoveredTabID`. It posts system pointer moves across 24 alternating rows and
checks a stationary pointer after scrolling, while preserving the foreground
and event-posting permission prerequisites.

The explicitly opted-in desktop run compiled but stopped at its foreground
prerequisite (`NSApp.isActive == false`). Retrying with the installed Dev
normally quit gave the same result, before any hover assertion or pointer
measurement. This test is **not passed**; it does not indicate a hover assertion
failure either. Evidence: `/tmp/omg-hover-routing-desktop-isolated.log`.
