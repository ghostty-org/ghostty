# RoundedStone: Adaptive Split Layout

Status doc for an ongoing, multi-session effort — not a one-shot build.
Update the checkboxes/notes here as work progresses so any future session
(agent or human) can pick up context without re-deriving it.

## Goal

Fork of [Ghostty](https://github.com/ghostty-org/ghostty) (macOS/SwiftUI)
adding a Google-Meet-style "adaptive" split layout: the focused pane takes
up the majority of the window, other panes shrink to a condensed strip
(scaled-live content, or just a tab/title pill once too small), and
switching focus animates the layout. Manual split/drag/zoom behavior must
keep working unchanged when adaptive mode is off — this is additive.

Naming: "RoundedStone" — rounded-corner aesthetic + otters carrying a
rounded stone as a keepsake.

## Key technical constraint (do not relitigate without new evidence)

Ghostty panes are live PTYs with a fixed character grid, not video feeds.
Shrinking a pane's on-screen frame naively shrinks its row/column count,
causing TUI apps (vim, htop, etc.) to reflow/clip — not just look smaller.

**Resolution:** decouple visual size from PTY grid size for inactive
panes. Render the `SurfaceView` at a stable canonical frame (so the PTY
size never changes), then apply a SwiftUI `.scaleEffect` + `.clipped()`
on top to shrink it visually. Ghostty's macOS `SurfaceView` is
Metal/CALayer-backed, so this should composite cleanly — **needs
confirming empirically in the Phase 2 spike below**, with snapshot-image
thumbnails as the fallback if live scaling looks bad or is expensive.

## Architecture notes (from reading the existing code)

- Splits are a binary tree: `SplitTree<SurfaceView>` in
  `macos/Sources/Features/Splits/SplitTree.swift`. Each split node has a
  `direction` (`.horizontal`/`.vertical`) and a `ratio` (0–1). Rendered
  recursively by `SplitView.swift` via `GeometryReader`.
- There's already a `zoomed` node concept (one pane goes fullscreen,
  others stop rendering) — a useful reference for how the codebase
  already handles "one pane dominates," but too blunt for what we want
  (others should stay visible, just condensed).
- `BaseTerminalController.swift` has `@Published var surfaceTree`,
  `focusedSurface`, and `focusedSurfaceDidChange(to:)` — this is the hook
  to trigger adaptive relayout when focus changes.
- Binary-tree ratios encode *pairwise* divisions, not a uniform grid.
  **Superseded 2026-07-15** (see session log — user provided a hand-drawn
  UX reference): the original plan here was a flat leaf list flattened
  into "one big active rect + a uniform strip of small tiles," discarding
  each pane's spatial relationship to the others. Built and confirmed
  working, but wrong per the user's actual intent. **Current design:**
  `AdaptiveLayoutContainer` still renders as a separate view (manual
  split system stays untouched — `SplitTree`'s stored ratios are never
  mutated), but the *layout computation* now walks the tree's own
  left/right/up/down structure recursively: at each split along the path
  to the focused leaf, the focus-side gets `activeFraction` (recursively,
  so nested on-path splits keep biasing); splits off that path keep their
  existing manual ratio unchanged. This preserves relative spatial
  position — a pane that was top-right of the tree stays in the top-right
  region as it shrinks, rather than collapsing into a strip.

## Phases

- [x] **Phase 0 — Toolchain baseline.** Installed `zig@0.15.2` via brew.
      Had to run `xcodebuild -runFirstLaunch` (fixed a broken
      IDESimulatorFoundation plugin) and
      `xcodebuild -downloadComponent MetalToolchain` (687MB, needed for
      `zig build` to compile `.metal` shaders) before the build worked.
      Working build sequence:
      `zig build -Demit-macos-app` (produces `macos/GhosttyKit.xcframework`)
      then `xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty
      -configuration Debug build`. Confirmed the resulting binary runs
      (launching via `open Ghostty.app` didn't spawn it in this sandboxed
      shell — running `Contents/MacOS/Ghostty` directly did).
- [x] **Phase 1 — Repo setup.** `origin` renamed to `upstream` (no
      personal fork remote yet). Working on branch `adaptive-layout` off
      `main`, will rebase periodically against `upstream/main`.
- [x] **Phase 2 — Spike: live-scaled surface.** Prototype rendering one
      `SurfaceView` at a fixed canonical frame with `.scaleEffect` +
      `.clipped()` layered on top. Confirmed empirically 2026-07-14: (a)
      stays live — yes, shrunk pane showed the same live shell output as
      the full-size pane, not a frozen frame; (c) no PTY resize — yes,
      text wrapped at identical columns to the full-size left pane,
      confirming the grid stayed at the canonical 800x500 size; (b) text
      legible at thumbnail size — no, at 0.3 scale (240x150) it's a
      recognizable terminal-shaped blur, not readable text. **Decision:**
      live-scaled tiles work technically (no snapshot-image fallback
      needed), but confirms the tiered design from the architecture
      notes is required — the "scaled-live" tier is for recognition, not
      reading; only the active/full tier needs to be legible. Live
      scaling is viable for v1.
- [ ] **Phase 3 — `AdaptiveLayoutContainer`.** New SwiftUI view, separate
      from `SplitTree`'s binary math. Takes flat leaf list + focused
      leaf, computes one large active rect + strip/grid of others. Three
      visual tiers per pane based on computed slot size: full (active),
      scaled-live (medium), title-only pill (below condense threshold).
- [ ] **Phase 4 — Wiring.** `layoutMode: .manual | .adaptive` toggle
      (keybind + config option: `adaptive-layout`,
      `adaptive-active-fraction`, `adaptive-strip-position`,
      `adaptive-condense-threshold`). Driven by `focusedSurfaceDidChange`,
      animated with spring transitions.
- [ ] **Phase 5 — Rounded aesthetic.** Rounded corners/elevation on the
      active pane, smooth focus-change animations, click-to-expand on
      condensed tiles.
- [ ] **Phase 6 — Edge cases & tests.** Window resize while adaptive,
      opening/closing panes, ≤2 panes = no-op, unit tests for the layout
      math (pure function — model on existing `SplitTreeTests`).
- [ ] **Phase 7 — Branding polish (optional, low priority).** Rename
      bundle id/icon to RoundedStone once the feature itself is solid.

## Session log

- 2026-07-14: Cloned Ghostty into this directory, researched split/focus
  architecture, wrote this plan. Completed Phase 0 (toolchain + baseline
  build working) and Phase 1 (repo/branch setup). Next: Phase 2 spike on
  `adaptive-layout` branch.
- 2026-07-14 (later): Started Phase 2 spike. Uncommitted diff in
  `macos/Sources/Features/Splits/TerminalSplitTreeView.swift` (marked
  `SPIKE(roundedstone)`) wraps the right child of a split with
  `.frame(800x500) -> .scaleEffect(0.3) -> .frame(240x150) -> .clipped()
  -> .border(.red)` to test live-scaling a `SurfaceView` without
  resizing its PTY grid — **visual result not yet confirmed**. A Debug
  build exists at
  `~/Library/Developer/Xcode/DerivedData/Ghostty-ddbapgraojhfmpblkxepxgqmaytl/Build/Products/Debug/Ghostty.app`
  and was up to date with this diff as of this session.
  Mid-session, the user's system had some config change that killed
  windows (their words: "shut down even this prod ghostty terminal");
  this Claude Code session itself runs inside a Ghostty window, and it
  got restarted, losing prior conversation context (recovered from this
  plan file). Two orphaned debug processes with zero windows were found
  and killed; a fresh debug instance was launched and did show a window.
  **Important finding:** driving the debug Ghostty window via
  `osascript`/System Events (`keystroke`, `set frontmost`, `AXRaise`)
  from *inside a Claude Code session that itself runs in a Ghostty
  window* is unreliable — keystrokes kept landing on the session's own
  window instead of the target debug window (real OS key focus didn't
  follow the AX-level frontmost/raise calls), and one stray `Cmd+D`
  added an unwanted extra split pane to the live session window itself.
  That stray pane needs manual cleanup (see note to self below). The
  user is switching to driving Claude Code from the default macOS
  Terminal.app instead of Ghostty specifically to avoid this
  self-control collision.
  **Status:** Phase 2 spike code is in place and builds, but the actual
  visual question (does the scaled pane stay legible/live?) is still
  unanswered. Debug build window (a separate process from the app
  Claude Code runs in) may still be open/running from this session at
  approx screen position (842, 358), size 800x632, single pane, showing
  the debug-build warning banner — worth checking if it survived before
  rebuilding.
  Also present in repo root, untracked, likely safe to ignore/delete:
  `default.profraw` (coverage artifact, not part of this work).
- 2026-07-14 (later still): Resumed in a fresh session, now driven from
  Terminal.app (not Ghostty) per the note above, so the osascript hazard
  no longer applies. The old debug process (pid 50682) had no visible
  window anymore (confirmed via a full-desktop screenshot — avoid
  repeating that, it captures unrelated screen content; prefer targeted
  region screenshots via `screencapture -R` once window bounds are
  known). Killed it, ran the full build sequence
  (`zig build -Demit-macos-app` then the `xcodebuild` command from
  Phase 0), launched a fresh debug binary, used read-only
  `System Events` position/size queries plus one `Cmd+D` keystroke
  (verified frontmost was the debug app before sending it) to open a
  split and trigger the `SPIKE(roundedstone)` code path, then
  screenshotted just that window region. **Result: Phase 2 spike
  confirmed** (see checkbox above) — live-scaled tiles work. Debug
  process killed afterward. The `SPIKE(roundedstone)` diff in
  `TerminalSplitTreeView.swift` is still uncommitted/unreverted — next
  session should decide whether to revert it now or evolve it directly
  into Phase 3's `AdaptiveLayoutContainer`. Next: Phase 3 — design and
  build `AdaptiveLayoutContainer` (flat leaf list, tiered layout).
- 2026-07-14 (Phase 3 start): Before building the real container, ran an
  advisor-recommended precondition check that Phase 2 never covered:
  does a live `SurfaceView` survive being reparented into a flat,
  non-split-tree container (not just visually scaled in its existing
  tree position)? Replaced the old scaleEffect spike in
  `TerminalSplitTreeView.swift` with a new one gated behind
  `ROUNDEDSTONE_ADAPTIVE_SPIKE=1`: an `AdaptiveContainerSpike` (flat
  `HStack`, each leaf hosted via `Ghostty.InspectableSurface` directly,
  keyed `.id(surfaceView.id)`, bypassing `TerminalSplitLeaf`/`SplitView`
  entirely) swapped in for `TerminalSplitTreeView.body` when the env var
  is set and the tree has ≥2 leaves. **Confirmed empirically:
  reparenting is safe** — built + launched a debug instance with the
  env var set, split it into 3 panes, and visually confirmed (via
  targeted `screencapture -R` after moving the debug window to
  unoccupied screen space) that all panes render live and independently
  in the flat container, each with distinct login timestamps proving
  they're not a duplicated/frozen render. Did not get clean proof of
  *keyboard interactivity* in the flat container specifically — see
  incident note below — but the render-correctness evidence answers the
  question the spike was for. **Decision: flat-container design for
  `AdaptiveLayoutContainer` is unblocked**, matches the architecture
  notes' `AdaptiveLayoutContainer` plan (flat leaf list + focused id →
  active rect + strip).

  **Incident:** While attempting to also confirm keyboard interactivity
  (typing into a reparented pane), a `System Events keystroke` call
  landed on the Claude Code session's own Terminal.app window instead
  of the target debug Ghostty window — despite a `CGEvent` click and a
  frontmost check immediately prior confirming Ghostty was frontmost.
  The typed text (`echo REPARENT_OK_LEFT` + Return) was submitted as if
  the user had sent it as a chat message. No corruption of the Ghostty
  debug panes resulted (they still showed unmodified shell prompts).
  This is the same class of hazard as the earlier Ghostty-in-Ghostty
  incident but recurred on a different controlling terminal app —
  memory updated (`ghostty_gui_automation_hazard` in the auto-memory
  system) with revised guidance: don't send synthetic keyboard input to
  a second app's window at all during a session; mouse clicks and
  read-only window inspection seem fine, keyboard does not. Debug
  process was killed after the incident; no further automated
  interaction was attempted this session.

  Next: build the real `AdaptiveLayoutEngine` (pure function per the
  advisor's suggested split — `(leaves, activeID, bounds, params) ->
  [(surface, rect, tier)]`, testable without SwiftUI) and a thin
  `AdaptiveLayoutContainer` SwiftUI view that renders its output,
  reusing `TerminalSplitLeaf` (not a bare `InspectableSurface`) per tile
  so surface-hosting matches the tree view's path exactly, keyed
  `.id(surface.id)` for identity-preserving animation. Still open:
  how `focusedSurface` reactivity threads into the container (advisor
  flagged — must reuse the existing `@FocusedValue`/
  `.ghosttyLastFocusedSurface` mechanism, not a plain `let`), and the
  canonical-frame-size / GPU-cost tradeoff for how many panes render
  live vs. condense to a title pill.
- 2026-07-14 (Phase 3 core built): Built the real thing, not just spikes.
  - `AdaptiveLayoutEngine.swift`: pure `AdaptiveLayout` enum, generic
    over any `Hashable` ID (no SwiftUI/AppKit/Ghostty types), computing
    `[Slot<ID>]` (id, rect, tier) from `(leafIDs, activeID, bounds,
    params)`. No-ops (returns `[]`) for <3 leaves per the "≤2 panes =
    no-op" edge case, and for zero-sized bounds. Falls back to the
    first leaf as active if `activeID` is nil or stale (e.g. points at
    a closed pane).
  - `AdaptiveLayoutContainer.swift`: thin SwiftUI view — a
    `GeometryReader` feeds bounds into the engine, then a `ZStack`
    positions each tile via `.position`/`.frame`, keyed `.id(surface.id)`.
    `AdaptiveLayoutTile` switches on tier: `.active` and `.scaled` both
    host the real `TerminalSplitLeaf` (promoted from `private` to
    internal in `TerminalSplitTreeView.swift` so this file can reuse
    it — same surface-hosting path as the manual split tree, per the
    advisor's de-risking suggestion), `.scaled` additionally applies
    the canonical-800x500-then-scaleEffect treatment confirmed safe in
    Phase 2; `.pill` renders a `Text(surfaceView.title)` in a rounded
    rect and does not host a live surface at all. `TerminalSplitOperation`
    actions are no-op'd (`{ _ in }`) — resize/drop aren't meaningful
    without a tree, per the advisor.
  - `AdaptiveLayoutEngineTests.swift`: 12 unit tests on the pure engine
    (no-op cases, active-id selection/fallback, geometry math for both
    strip positions, tier thresholds) — all passing via `xcodebuild
    test ... -only-testing:GhosttyTests/AdaptiveLayoutEngineTests`.
  - Wired into `TerminalSplitTreeView.body` behind the same
    `ROUNDEDSTONE_ADAPTIVE_SPIKE=1` env-var gate (now passing
    `focusedSurfaceID: nil`, so it always falls back to the first leaf
    — real focus wiring is still a Phase 4 TODO, marked inline).
  - **Render confirmed end-to-end.** Built, launched with the env var
    set, asked the user to manually create 2 splits (avoided further
    synthetic keystrokes after the incident below), screenshotted the
    window. Result matched the design exactly — active pane fills the
    top ~75% (`activeFraction` default), 3 live-scaled tiles fill the
    bottom strip with correct even spacing, all rendering distinguishable
    live shell content. This is the real container working, not the
    earlier spike.
  - **Process note:** after the earlier keystroke-into-own-session
    incident, switched to asking the user to manually drive the debug
    window (click in, press Cmd+D) rather than scripting keystrokes —
    per the revised `ghostty_gui_automation_hazard` memory guidance.
    Worked cleanly with no further incidents. Recommend continuing this
    pattern for future visual checks on this project.
- 2026-07-14 (interactivity confirmed): Closed the remaining gap from
  the advisor's review — every check up to this point only proved
  surfaces *render* live in the flat container, not that a reparented
  surface still *accepts keyboard input* (the interactivity check the
  earlier keystroke incident interrupted was never redone). Rebuilt,
  relaunched with the env var set, asked the user to manually create
  splits and type `echo hello` into the active pane. Screenshot showed
  `echo hello` / `hello` / a fresh prompt in the active pane —
  **keyboard input to a reparented surface works correctly.** Phase 3's
  core (rendering + interactivity) is now fully verified.

  **Still open before Phase 3 is fully done:** real `focusedSurface`
  reactivity (currently hardcoded nil/first-leaf), animation on
  focus-change (untested — the `.animation(value: slots)` modifier is
  in place but not visually verified since focus never actually
  changes yet), and the Phase 6 edge cases (window resize while
  adaptive, opening/closing panes triggering relayout). Then Phase 4
  (config wiring, real mode toggle) and Phase 5 (rounded aesthetic
  polish) are still ahead.

  **Design gap noticed on review, not yet fixed:** the `.active` tier
  hosts `TerminalSplitLeaf` directly at the active rect's natural size
  (no canonical frame), while `.scaled` hosts it at a fixed canonical
  800x500. That means a pane's PTY grid is 800x500 while scaled but
  reflows to the active rect's actual size the moment it becomes
  active (and back again when it stops being active) — every focus
  change resizes the PTY of both the outgoing and incoming pane. The
  "inactive panes never resize their PTY" premise from Phase 2 only
  holds *while a pane stays in one tier*, not across the active⇄scaled
  transition. This is probably fine — the active pane arguably *should*
  render at its true resolution rather than a scaled-up canonical
  size — but it means the animated focus-change transition (Phase 4)
  needs the PTY reflow to happen before/after the spring animation,
  not during, or it'll flicker/reflow mid-animation. Needs a decision
  when Phase 4 gets built, not before.
- 2026-07-15 (real focus wiring + major redesign): Two things happened
  this session.

  **First, wired real focus tracking** (closing the last Phase 3 TODO):
  `TerminalSplitTreeView` and `AdaptiveLayoutContainer` gained a real
  `focusedSurfaceID` parameter, threaded from `TerminalView`'s existing
  `@FocusedValue(\.ghosttySurfaceView)` / `lastFocusedSurface` fallback
  (single source of truth, not tracked independently). While verifying
  this by clicking a condensed tile, the user found a real bug: the
  previously-active pane would vanish entirely after a focus-change
  click, ending with only one visible pane. Debug logging (temporary,
  since removed) proved the underlying `SplitTree` never lost leaves
  (`tree.count` stayed correct) — it was a SwiftUI rendering bug, not
  data loss, and confined to the disposable debug test build regardless.
  Root cause: `AdaptiveLayoutTile.body`'s `switch tier` put the `.active`
  and `.scaled` cases in structurally distinct branches, so SwiftUI tore
  down and recreated the `TerminalSplitLeaf`/surface host on every focus
  change instead of just changing modifiers. **Fixed** by unifying
  `.active` and `.scaled` into one branch (same `TerminalSplitLeaf` host,
  scale/frame computed conditionally) — only `.pill` (which hosts no
  surface at all) remains a separate branch. Also gave empty-title pills
  a "Terminal" fallback so fresh shells don't render as blank-looking
  rects.

  **Second, and bigger: the user shared a hand-drawn UX reference**
  (`IMG_5951`, described here since the image itself isn't in this repo)
  showing their actual intended interaction model, which turned out to
  differ from what was built: non-focused panes should keep their
  *relative spatial position* (top-right stays top-right, bottom stays
  bottom) as they shrink around the growing focused pane, rather than
  all flattening into a single 1-D strip along one edge. Confirmed with
  the user before proceeding (see "Architecture notes" above for the
  updated design). This required rewriting `AdaptiveLayoutEngine` from
  scratch: instead of a flat `[ID]` leaf list, it now takes a generic
  `TreeNode<ID>` (a pure structural mirror of `SplitTree.Node` — same
  left/right/ratio/direction shape and the same left/right-for-vertical
  convention as `SplitTree.Node.calculateViewBounds`, so converting the
  real tree into the engine's input is a direct 1:1 copy with no
  direction-dependent relabeling to get wrong) and walks it recursively,
  biasing the ratio of each split along the path to the focused leaf
  toward `activeFraction`, leaving off-path splits at their stored
  ratio. `AdaptiveLayoutContainer`'s rendering (`ZStack` + `.position()`
  per slot, tile tiering) didn't need to change — only how slots get
  computed. The `≤2 panes = no-op` edge case from the original plan is
  gone: the new model is meaningful even at exactly 2 panes (focus gets
  `activeFraction`, the other gets the rest), so the no-op guard is now
  just "tree must have at least one split."

  Caught one real bug while implementing: the vertical-split convention
  inherited from `SplitTree` is asymmetric (`ratio` means "fraction to
  the left" for horizontal splits, but "fraction to the right" for
  vertical splits — see `SplitTree.Node.calculateViewBounds`). A naive
  port of the horizontal bias formula to vertical splits silently
  inverted focus sizing (the focused pane would get *smaller*, not
  bigger). Caught by a unit test
  (`onPathSplitDeeperInTheTreeAlsoBiasesTowardFocus`) that exercises a
  split two levels deep — worth keeping tests like this since the bug
  wouldn't show up at the top level alone. All 12 old flat-strip tests
  were rewritten against the new tree model (the old ones validated a
  design that no longer exists); the new 13 use an epsilon-tolerant
  `CGRect` comparison rather than strict `==`, since exact floating-point
  equality across compounded rect-splitting arithmetic isn't reliable.

  **Visually confirmed working** by the user directly (not just via
  screenshot) — clicking a tile now promotes it to active with no panes
  disappearing. User separately noted `goto_split` keyboard navigation
  (`ctrl+cmd+arrow`) only works left/right, not up/down — confirmed this
  is pre-existing core Ghostty behavior (`ghostty_action_goto_split_e`,
  dispatched from libghostty core, unrelated to any file touched by this
  feature) rather than something introduced here. Not investigated
  further this session; worth a separate look if the user wants it fixed.

  Next: tune `activeFraction`/`condenseThreshold` defaults (user
  mentioned "some glitches" without specifics — ask for details before
  guessing what to tune), then the remaining Phase 3/4/5/6 items listed
  above (animation verification, PTY-reflow-on-transition decision,
  config wiring, rounded/spacing polish — a light version of which
  already landed as `.padding(3)` + `cornerRadius: 10` on pill tiles per
  the "all rounded" note in the user's sketch, but active/scaled tiles
  aren't clipped to a rounded shape yet).
- 2026-07-15 (click-to-focus fix + real vertical-split bug found & fixed):
  Two more real bugs this session, both user-caught through actual use.

  **Bug 1 — click on a condensed tile needed more than one try.** Root
  cause: Ghostty's own click-to-focus mechanism
  (`localEventLeftMouseDown` in `SurfaceView_AppKit.swift`) requires the
  click to hit-test exactly onto the `SurfaceView` NSView. `.scaleEffect`
  (used to visually shrink live content in condensed tiles) is a
  rendering-only transform — AppKit's `hitTest` doesn't account for it,
  so clicks landed on the surface's unscaled/canonical frame instead of
  its visible (smaller) area. **Fixed** by adding an explicit
  `.simultaneousGesture(TapGesture()...)` on each tile's *outer* frame in
  `AdaptiveLayoutContainer` (correctly positioned/sized by SwiftUI,
  unlike the scaled content inside it), calling
  `window.makeFirstResponder(surfaceView)` directly — bypassing the
  broken hit-test path entirely. User confirmed this works, with one
  known remaining edge case: clicking *during* the ~0.35s spring
  animation can miss if the click lands outside the tile's *final*
  (post-animation) bounds, since SwiftUI's hit-testing snaps to the
  target layout immediately while the visual rendering is still
  interpolating. Not fixed — noted as a minor rough edge for later
  polish (would need to disable hit-testing mid-transition or shorten
  the animation).

  **Bug 2 — vertical splits rendered upside-down in adaptive mode, and
  `goto_split:up/down` navigation felt inverted.** This took real
  investigation to isolate correctly — worth recording the full trail
  since it's easy to mis-diagnose:
  - Traced the entire up/down keybinding path end to end (Zig keybind
    defaults in `Config.zig`, `SplitFocusDirection` mapping in
    `GhosttyPackage.swift`, menu wiring in `AppDelegate.swift`,
    `gotoSplit` dispatch in `Ghostty.App.swift`) — all symmetric and
    correct between left/right and up/down. No bug found there.
  - Added temporary debug logging to `gotoSplit` and confirmed via the
    user's own live testing that navigation *does* work correctly when
    actually reaching that function — the "upside down" feeling was
    specific to *adaptive mode* rendering, not core Ghostty navigation.
  - Found the actual bug in `SplitTree.swift`: two different functions
    compute the same thing (bounds for a vertical split) with
    **contradictory conventions**. `spatialSlots` (what real keyboard
    navigation uses) and `SplitView.swift` (what actually renders on
    screen, explicitly documented: "for vertical splits, left is top,
    right is bottom") agree with each other. But `calculateViewBounds`
    — a separate, *unused* function with zero production callers,
    documented inline as assuming "Y increases upward" — has left/right
    inverted relative to the other two. It's not wrong in isolation (its
    own test suite in `SplitTreeTests.swift` was written to match its
    own Y-up convention consistently), just internally inconsistent with
    the rest of the codebase and never actually called by anything real.
  - **The actual bug: `AdaptiveLayoutEngine.swift`'s `splitRect`
    accidentally copied `calculateViewBounds`'s (unused, inverted)
    convention** instead of `spatialSlots`'s (correct, actually-used)
    one — introduced when the engine was first written, on the mistaken
    assumption that both SplitTree functions agreed. This meant the
    adaptive layout visually rendered vertical off-path panes swapped
    top/bottom relative to their real position — which is exactly what
    reads as "navigation is upside down" when a user compares what they
    see against where focus actually lands.
  - **Fixed**: rewrote `splitRect`'s vertical case to match
    `spatialSlots`/`SplitView.swift` (left=top, right=bottom). This also
    simplified `recurse`'s bias logic — it no longer needs a
    direction-dependent branch, since `ratio` now uniformly means
    "fraction to the left" for both horizontal and vertical splits (it
    only meant something different for vertical because of the bug being
    fixed). Reverted an earlier, unnecessary edit to
    `calculateViewBounds` itself (tempting to "fix" it too, but it has no
    real callers and changing it would have broken its own existing test
    suite for zero behavioral benefit — left it alone, matching its own
    self-consistent Y-up convention). Updated 2 unit test expectations
    that had encoded the wrong convention as "correct." All
    `AdaptiveLayoutEngineTests` (13) and `SplitTreeTests` (all
    pre-existing tests) pass.
  - **User confirmed fully working** after rebuild: vertical stacking
    renders correctly, and `Cmd+Option+Up/Down` navigation now matches
    what's on screen.

  Lesson for future sessions: when two functions in this codebase
  compute seemingly-the-same spatial thing, check which one actually has
  callers before trusting either as a reference — don't assume
  consistency between them.
- 2026-07-15/16 (algorithm redesign: flat 2/3-per-axis, not recursive
  bias — plus rounded-corner polish): The user drew two more hand-drawn
  references (`IMG_5960`, `IMG_5951` from earlier) showing the *exact*
  intended layout rule, and it turned out to be meaningfully different
  from what Phase 3 had built.

  **The rule, confirmed via two independent worked examples that both
  matched to the exact fraction:** the focused pane always gets a flat
  `activeFraction` (2/3) of *each axis it shares siblings on* — not a
  fraction that compounds with tree depth. Concretely: group the path
  from root to the focused leaf into "runs" of consecutive same-direction
  splits (a run is what a user thinks of as one row or one column, even
  if built as several nested splits). Within a run, focus's slot gets
  2/3 of that run's axis-length; *every* branch that split off anywhere
  along that run evenly shares the remaining 1/3, regardless of nesting
  depth. A direction change starts a new, independent run (so splitting
  focus vertically after it's already 2/3 of a horizontal row gives it
  2/3 height *of that row*, untouched by the row's own 2/3/1/3 split).
  Branches entirely off the path to focus keep their own manual ratios.

  This is NOT what the original recursive-per-split-node bias computed —
  that would compound the fraction at each level (e.g. a pane 2 levels
  deep would get roughly 4/9, not 2/3). The old design happened to give
  correct answers for the specific single-level cases tested earlier in
  the session, which is why the discrepancy wasn't caught until the user
  tested a deeper case (move focus 2 levels into a same-direction chain).

  **Rewrote `AdaptiveLayoutEngine.swift` from scratch** around this
  model: `pathSteps(to:in:)` walks the path capturing (direction,
  which side continues toward focus, the subtree that branched off) per
  step; `groupIntoRuns` batches consecutive same-direction steps;
  `layout()` then processes runs in order, partitioning each run's rect
  into off-path slots (evenly sharing 1/3) plus a continuation slot
  (2/3), carrying the continuation rect forward into the next run.
  Off-path subtrees render via `renderNatural`, recursing with their own
  stored ratios exactly as before (unchanged from the prior design).
  `AdaptiveLayoutContainer`'s rendering side needed no changes — only
  slot computation changed. Rewrote all unit tests against the new
  model, including two that directly encode the user's worked examples
  (`focusTwoLevelsDeepInARunStillGetsFlatTwoThirds`,
  `perpendicularSplitOffFocusStartsANewIndependentRun`) — both catch
  exactly the bug the old design had. All 13 tests pass. Visually
  confirmed correct via screenshot (one dominant focus region, small
  tiles in the corners, matching the expected shape for a tree with
  panes on multiple sides of focus).

  **Rounded corners + gaps** (the last item from the original hand-drawn
  reference, "all rounded"): added `.clipShape(RoundedRectangle(cornerRadius: 10))`
  uniformly to every tile in `AdaptiveLayoutContainer` (previously only
  pill tiles were rounded). This alone wasn't visually verifiable at
  first — the gap between tiles (from the existing `.padding(3)`) had no
  background fill of its own, so it showed through to whatever was
  behind the container, which was often indistinguishable in color from
  the panes themselves, making both the gap *and* the rounding
  invisible regardless of whether the code worked. Fixed by adding
  `.background(ghostty.config.splitDividerColor)` behind the tile
  ZStack — reuses the same user-configurable divider color the manual
  split view already uses, rather than a hardcoded color. Confirmed via
  a zoomed screenshot crop: both gap and rounded corners clearly visible
  at a tile boundary. (Verification note: briefly set `background`/
  `foreground` to white/black in the user's real Ghostty config to get
  enough screenshot contrast to debug the initial "nope, nothing"
  report, then reverted it immediately after — this touches the user's
  shared config file, not just the debug build, so don't leave it
  modified.)

  **Status: user confirmed the full adaptive layout — algorithm,
  click-to-focus, vertical-split fix, and rounded/gapped tiles — all
  working correctly.** Remaining open items unchanged from before:
  animation-during-transition click edge case (noted, not fixed), PTY-
  reflow-on-transition decision, Phase 4 config wiring (currently gated
  by `ROUNDEDSTONE_ADAPTIVE_SPIKE=1` env var, not real config), Phase 6
  edge cases (resize, opening/closing panes while adaptive).
- 2026-07-16 (session paused mid-investigation — NEW BUG, unresolved):
  Shortly after the above was confirmed working, the user reported (with
  a screenshot) large unfilled blank gaps in the layout — e.g. the left
  column showing 2 tiles at top, then a big empty gap, then 1 more tile
  at the bottom, instead of the tiles tiling the column completely.
  **This is not yet fixed — pick up here.**

  **What's been ruled out:** added temporary debug logging (still in
  `AdaptiveLayoutContainer.swift`, search `DEBUG(roundedstone)`, remove
  once this is resolved) that prints the exact tree structure, bounds,
  and computed slots to stderr on every render. Captured a real log
  entry matching a screenshot showing the gap bug, and hand-traced the
  algorithm by hand against the *exact* logged tree (6 leaves, focus 3
  levels deep through a horizontal→vertical→horizontal direction
  sequence) and the *exact* logged bounds (1564x1256). **The computed
  slots, by hand-verification, tile the window with zero gaps and zero
  overlaps** — every rect in the logged `slots=` line was independently
  recomputed from the tree and matched exactly, and the union of all
  slot rects covers the full 1564x1256 window with no leftover area.
  This means the *algorithm's output* is very likely not the bug —
  which points to a rendering-layer or animation-layer discrepancy
  between the computed (correct) slots and what's actually painted on
  screen, or something environmental (see below).

  **Leading hypothesis, NOT yet confirmed:** the screenshot may have
  caught the `.spring(response: 0.35, ...)` transition animation
  mid-flight (e.g. right after one of the many relaunches/config
  reloads this session, or right after window state restoration
  settled into a new tree shape), showing tiles at an interpolated
  position rather than their final one. This was never actually
  verified — the user interrupted the tool call that would have taken a
  fresh, settled screenshot to check. **Next session: start by taking
  one settled screenshot (wait a couple seconds after launch/focus
  changes, no relaunch immediately before) and compare against the
  debug log's `slots=` line for that exact render. If the gap is still
  there in a settled state, the hypothesis above is wrong and the bug
  is real** — in that case, worth checking next: (a) whether
  `leaves.first(where: { $0.id == slot.id })` in
  `AdaptiveLayoutContainer.body` is silently failing to find a match
  for some slot (which would silently skip rendering that tile,
  producing exactly this kind of hole) — add a log line for the `else`
  branch of that `if let` to check; (b) whether repeated relaunches +
  macOS window-state restoration this session left stale/duplicate
  `SurfaceView` entries with mismatched ids in the tree, independent of
  the adaptive-layout code.

  Debug build was killed and config file confirmed reverted to original
  before pausing — no leftover state from this investigation outside
  the repo.
- 2026-07-16 (gap bug fixed): Picked back up per the note above. A
  settled screenshot (no relaunch/animation immediately before)
  reproduced the bug clearly, which already ruled out the
  animation-mid-flight hypothesis. Pixel-level comparison against the
  debug log's `slots=` output for that exact render was inconclusive by
  hand at first — advisor review caught the real bug from the same
  evidence already gathered.

  **Root cause: `AdaptiveLayoutTile`'s `.scaled` tier scales the
  canonical 800x500 frame *uniformly*** (`scale = min(width/800,
  height/500)`) **so it only fills both axes of its slot when the
  slot's aspect ratio happens to equal 1.6:1 (800/500). The run-based
  layout produces slots of many different aspect ratios, so most
  scaled tiles filled only one axis and left the other letterboxed —
  showing the container's `splitDividerColor` background through the
  unfilled strip, which read as a "gap."** Confirmed against real
  numbers: for a logged slot of 1042.67x418.67, `scale = min(1.303,
  0.837) = 0.837`, filling only 800*0.837 ≈ 670pt of the available
  1042.67pt width — the remaining ~372pt showed as gap, matching the
  screenshot exactly.

  Both leading dead-end theories from the prior session were ruled out
  correctly at the time: the algorithm's computed slots were never the
  problem (they do tile the window exactly), and the `leaves.first(where:)`
  lookup was never silently failing (a subagent proved `leaves()` and
  the engine's tree conversion walk the same immutable tree in the same
  `body` call, so a mismatch is structurally impossible). The debug
  logging for both (the `ROUNDEDSTONE_DEBUG` tree/bounds/slots dump and
  the `MISSING` leaf-lookup check) has been removed from
  `AdaptiveLayoutContainer.swift`.

  **Fix (user picked "letterbox with matching background" over
  non-uniform stretch or per-slot aspect-matched canonical size, to
  avoid distortion and avoid reopening the parked PTY-reflow-on-transition
  decision):** kept the uniform scale as-is, added
  `.background(surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)`
  behind the scaled `TerminalSplitLeaf` so the letterboxed strip now
  reads as empty terminal space (matching the pane's own background)
  instead of showing the divider-color gap. This only affects the
  `.scaled` tier's fill color — no geometry/PTY-grid changes, so the
  Phase 2 "stable PTY grid" premise is untouched. **User confirmed
  working.**

  Status: adaptive layout — algorithm, click-to-focus, vertical-split
  fix, rounded/gapped tiles, and now full-slot-fill for scaled tiles —
  all confirmed working. Remaining open items unchanged: animation-
  during-transition click edge case (noted, not fixed), Phase 4 config
  wiring (still gated by `ROUNDEDSTONE_ADAPTIVE_SPIKE=1` env var, not
  real config), Phase 6 edge cases (resize, opening/closing panes while
  adaptive).
- 2026-07-16 (later: unfocused-pane headers, readable text, Phase 4
  config wiring, and Phase 7 rename — all shipped and confirmed
  working):

  **Unfocused-pane title headers.** Ghostty only shows a pane's title
  in the window titlebar while it's focused, so condensed panes had no
  label at all. Scoped deliberately to adaptive layout only (manual
  split mode untouched) and to the `.scaled` tier only (`.pill` already
  shows the title as its sole content; `.active` owns the real
  titlebar). Small floating rounded badge, top-leading inset, `.caption2`
  font, truncates with `.lineLimit(1)`, width-capped so it can't
  overflow the tile. Background is `Color(nsColor: .windowBackgroundColor)`
  at 0.75 opacity (25% transparent, per a later cosmetic follow-up —
  originally shipped with `.ultraThinMaterial`, swapped out on request).
  Implementation in `AdaptiveLayoutTile`'s `.overlay(alignment: .topLeading)`
  in `AdaptiveLayoutContainer.swift`.

  **Condensed tiles now show real, readable, line-wrapped text instead
  of shrunk/scaled text.** User feedback, in two rounds:
  1. First round: dropped the `.scaleEffect` on `.scaled` tier tiles
     entirely — instead of shrinking the whole canonical 800x500 frame
     down to fit the tile, render it at native size and let `.clipped()`
     crop to the tile's visible area (a "viewport" into the top-left of
     the pane). Text became normal-size and readable, but content was
     just *cropped*, not reflowed — long lines still ran off the edge
     of the small tile instead of wrapping.
  2. Second round ("text should auto change line, that is the point"):
     removed the canonical-800x500-frame concept entirely for condensed
     tiles. They now render directly at their actual tile size
     (`geometry.size`, same as `.active`), so the PTY grid gets real
     fewer columns/rows and text wraps naturally at the tile's real
     width. **This deliberately abandons the "stable PTY grid regardless
     of tile size" premise from Phase 2/3 for the `.scaled` tier** —
     every focus change now resizes the PTY of both the outgoing and
     incoming pane. Fine for plain shell content (confirmed by the
     user); a full-screen TUI app (vim, htop) sitting in a condensed
     tile will reflow/redraw on every relayout — not yet tested, worth
     watching for if it comes up. `AdaptiveLayoutTile.canonicalSize` was
     removed as dead code as part of this.

  **Phase 4 done: real config option, no more env var.** Added
  `adaptive-layout: bool` to `src/config/Config.zig` (default `true`,
  since this is a personal fork built specifically for this feature —
  user explicitly chose on-by-default over opt-in). Zig-side parsing
  and the C API getter are both fully generic/reflection-based
  (`src/config/key.zig`, `src/config/c_get.zig`) so no additional Zig
  code was needed beyond the field declaration itself. Added
  `Ghostty.Config.adaptiveLayout: Bool` in `Ghostty.Config.swift`
  (mirrors the existing `focusFollowsMouse` pattern exactly). Wired
  into `TerminalSplitTreeView` by adding `@EnvironmentObject var
  ghostty: Ghostty.App` and reading `ghostty.config.adaptiveLayout`
  directly in `body` (same live-read pattern `AdaptiveLayoutContainer`
  already uses for `splitDividerColor` — no `DerivedConfig` snapshot
  needed for a single bool read in a View). The
  `ROUNDEDSTONE_ADAPTIVE_SPIKE` env var and `adaptiveModeEnabled` are
  gone. **Confirmed working**: launched with no env var set at all,
  adaptive mode was on by default as expected.

  **Phase 7 done (partial — rename, not icon): app renamed to
  RoundedStone.** Motivation: user wants to run this build day-to-day
  on a second (work) Mac that also has an unmodified, separately-
  installed production Ghostty — needed a distinct app identity, not
  just a personal preference. Confirmed first via research that the
  config directory (`~/Library/Application Support/com.mitchellh.ghostty/`)
  is controlled by a *separate*, hardcoded Zig constant
  (`src/build_config.zig:58`, `bundle_id`) — **not** derived from the
  Xcode/Info.plist bundle identifier — so renaming the app's bundle ID
  does NOT orphan the user's existing config. Deliberately left
  `build_config.zig`'s `bundle_id` untouched (the file's own comment
  warns changing it isn't as simple as it looks and has wider
  implications) — config path is unaffected either way.

  Changed only the three **macOS app target** build configs in
  `macos/Ghostty.xcodeproj/project.pbxproj` (`Debug`, `Release`,
  `ReleaseLocal` — confirmed via `SWIFT_OBJC_BRIDGING_HEADER`, a string
  that appears in exactly these three blocks, as the scoping anchor
  before editing anything): `PRODUCT_NAME` (`$(TARGET_NAME)` →
  `RoundedStone`, so the built product is literally `RoundedStone.app`
  now, not just a relabeled `Ghostty.app`), `PRODUCT_BUNDLE_IDENTIFIER`
  (`com.mitchellh.ghostty[.debug]` → `com.roundedstone.terminal[.debug]`),
  `INFOPLIST_KEY_CFBundleDisplayName` (→ `RoundedStone` /
  `RoundedStone[DEBUG]`), and all the `INFOPLIST_KEY_NS*UsageDescription`
  permission-prompt strings (`"...within Ghostty..."` →
  `"...within RoundedStone..."`) so system permission dialogs stay
  consistent with the new name. Used line-range-scoped `sed` (not a
  global find/replace) to touch only those three blocks — verified
  after via `git diff` hunk ranges that nothing outside them changed
  (the iOS target, `GhosttyTests`/`GhosttyUITests`, and `DockTilePlugin`
  configs, which share several of the same setting *values* but are
  different blocks, were confirmed untouched). Deliberately **not**
  changed: the actual Xcode target name (still "Ghostty" — only its
  build-setting *outputs* were renamed, lower risk than a real target
  rename), `EXECUTABLE_NAME` (stays `ghostty` — internal binary
  filename inside the bundle, invisible to the user, and other things
  like the Debug dylib hot-reload path may assume it), the app icon
  (user asked for the name specifically; icon is still the default
  ghost — asked, user didn't request a new one this session, worth
  revisiting if wanted later), and `DockTilePlugin`'s bundle ID /
  hardcoded `UserDefaults(suiteName:)` string (self-consistent between
  plugin and main app regardless of the main app's bundle ID — no
  cross-impact from leaving it alone).

  **Found and fixed a second hardcoded reference**: `zig build
  -Demit-macos-app` itself failed after the rename —
  `src/build/GhosttyXcodebuild.zig:52` had `Ghostty.app` hardcoded as
  the expected build product path for its own copy-into-`zig-out` step,
  independent of the Xcode project settings. Updated to
  `RoundedStone.app`. (The `-target "Ghostty"` argument passed to
  `xcodebuild` elsewhere in that file is correctly untouched — that's
  the Xcode *target* name, which was deliberately not renamed.)

  **Release build**: per user request ("too slow in my work env" —
  Debug build's performance-degraded warning was the issue), built with
  `zig build -Demit-macos-app -Doptimize=ReleaseFast` +
  `xcodebuild -configuration ReleaseLocal`. `ReleaseLocal` is the
  project's own designated config for "optimized build for your own
  machine" (confirmed via `xcodebuild -list`: it's the default
  configuration when none is specified, and needs no Developer
  ID/notarization). Output: `zig-out/RoundedStone.app` — confirmed via
  `PlistBuddy`: `CFBundleIdentifier = com.roundedstone.terminal`,
  `CFBundleDisplayName = RoundedStone`, universal binary (arm64 +
  x86_64, so it should also run on an Intel Mac without a from-source
  rebuild, though only tested on this Apple Silicon machine so far).
  Launched and confirmed working — no debug banner, adaptive layout on
  by default, matches the Debug build's behavior otherwise. This is the
  build to copy to the second (work) Mac.

  **Status at end of session: everything requested today is done and
  user-confirmed** — unfocused-pane headers (with 25%-transparent
  background), real (non-scaled, line-wrapping) text in condensed
  tiles, adaptive layout on by real config default (no env var),
  renamed app (`RoundedStone.app`, `com.roundedstone.terminal`), and a
  working `ReleaseLocal` release build at `zig-out/RoundedStone.app`.

  **For next session:**
  - Getting it running on the second Mac: since it's ad-hoc signed
    ("Sign to Run Locally"), the `zig-out/RoundedStone.app` built here
    likely won't launch as-is on another machine without re-signing —
    building from source there (same repo/branch, same toolchain) is
    the more reliable path discussed with the user; copying the binary
    directly was mentioned as an option but not actually tested
    cross-machine this session.
  - App icon still the default ghost — ask if they want a custom
    RoundedStone icon (would need actual artwork, not something to
    guess at).
  - Untested: how the condensed-tile real-PTY-reflow change (see above)
    behaves with a full-screen TUI app (vim, htop, etc.) in a condensed
    pane, given the Phase 2 "stable grid" premise no longer holds for
    that tier. Watch for this if it comes up.
  - Still open from before, unchanged: animation-during-transition
    click edge case, Phase 6 resize/open/close edge cases.
  - `GhosttyTests`/`GhosttyUITests`/iOS target bundle IDs were
    deliberately left as `com.mitchellh.*` during the rename (out of
    scope, not user-facing) — fine to leave unless it becomes relevant.
