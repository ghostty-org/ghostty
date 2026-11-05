# Surface presentation ownership

Issue #48 reports a blank original pane after splitting in OMG 0.19.1. The
previous fix (`1df076560`) prevented a retired scroll wrapper from resizing a
Surface after another wrapper took it. It did not prevent another wrapper
created by a retained, obsolete hosting tree from taking the Surface back.

## Ownership

The controller now issues a `SurfacePresentationLease` for the current split
presentation. Structural changes, zoom and the built-in terminal inspector
renew it; ratio-only changes do not. The tree passes its immutable lease as an
explicit value through the split leaves, including the editor content deck.
It is not read from a mutable controller or inherited outer environment by an
old leaf during a later rebuild.

Each retained Surface owns `SurfacePresentation`, which records its authorized
lease and weak current wrapper. A wrapper must present the authorized lease to
mount. A replacement permanently retires its predecessor; late updates or
dismantling cannot take or detach the replacement's Surface. Moving a Surface
between controllers revokes only a matching source lease, so delayed source
cleanup cannot revoke the destination's authority. An undo/return gets a fresh
lease even when the tree has the same shape as an earlier tree.

This separates model authority from physical `superview` ownership. The latter
still guards geometry and scrolling, but no longer grants mounting authority.
No timer, forced periodic redraw, PTY restart or replacement terminal is used
to recover presentation.

## Resize lifetime

The live-resize state machine and its existing 50 ms stable commit now belong
to the Surface, not the temporary scroll wrapper. A lease change, wrapper
handoff, native detach or dismantle finishes the transaction while it can still
publish to the retained core. A new wrapper therefore cannot discard a pending
PTY commit and then rely on a same-size ordinary resize that the core deduplicates.
Both live reflow and resize-on-release use this lifetime.

## Regression coverage

`SurfacePresentationOwnershipTests` covers:

- A retired `NSHostingView` reconstructing its representable five times after
  the controller has installed a new tree, without stealing the Surface.
- Late update/layout/dismantle of a superseded wrapper.
- Cross-controller transfers in destination-first order, including a return.
- Lease stability across ratio changes and renewal for zoom, replacement and
  built-in terminal inspector changes.
- Real PTY `TIOCGWINSZ` after same-size wrapper handoff, for both resize modes
  and both unchanged/renewed presentation leases. The initial ordinary resize
  is drained first so coalescing cannot accidentally mask a missing commit.
- Retained terminal text and a non-uniform, correctly sized IOSurface after
  1,000 lines of output and repeated remounts.
- Existing split, Quick Input, workspace and native shell behavior.

The deterministic obsolete-host test exercises an identified failure mechanism,
not a replay of the original user's complete event sequence. The original
report had no view hierarchy/renderer trace. Passing these tests does not
establish a long-duration foreground soak result.

The negative control temporarily removed lease validation and replaced resize
state on handoff. The obsolete-host and cross-controller tests then lost the
Surface, and the real PTY test retained the old column count during live resize.
Those mutations were removed before final validation.

A single-host routine sweep reported 1,427 passing tests in 178 suites, but its
late tests logged `OpenptyFailed`. Final validation therefore uses the same
routine suite inventory in serial batches with fresh app hosts, checks actual
test counts, and rejects any batch containing that PTY error. Optional
interactive-desktop tests remain excluded.

Final result: all 1,427 tests in 178 routine suites passed in 16 serial
fresh-host batches, with no `OpenptyFailed` in any batch. Strict SwiftLint
passed across 592 files; the documentation contract, plist/schema checks and
`git diff --check` also passed.
