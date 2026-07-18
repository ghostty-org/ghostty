# Adaptive Split Layout

RoundedStone is a macOS fork of [Ghostty](https://github.com/ghostty-org/ghostty)
that adds an adaptive split layout: the focused pane takes up most of
the window, other panes condense to smaller tiles, and the layout
re-flows as focus moves between panes.

## Enabling it

```
adaptive-layout = true
```

This is a RoundedStone-specific config option (`src/config/Config.zig`),
only read by the macOS app. It defaults to `true`. Setting it to `false`
restores Ghostty's normal manual split behavior — dragging dividers,
zoom, and all other split behavior are unaffected either way, since
adaptive mode is a separate rendering layer on top of the same
`SplitTree` rather than a modification to it.

## How it lays out panes

The focused pane's split path through the tree is grouped into "runs" of
consecutive same-direction splits (what a user thinks of as one row or
column, even if it's built from several nested splits). Within a run,
the focused pane's slot gets a flat `activeFraction` (default 2/3) of
that run's axis length, regardless of how deep in the run it sits. Every
branch that split off anywhere along that run evenly shares the
remaining third. A change of split direction starts a new, independent
run. Branches entirely off the path to the focused pane keep whatever
manual ratio they were already at.

This preserves each pane's relative spatial position — a pane that's
top-right of the tree stays top-right as it shrinks, rather than
collapsing into a single strip along one edge.

Implementation: `AdaptiveLayoutEngine.swift` is a pure function
(`(tree, focusedID, bounds, params) -> [Slot]`) with no SwiftUI/AppKit
dependencies, covered by `AdaptiveLayoutEngineTests.swift`.
`AdaptiveLayoutContainer.swift` is the thin SwiftUI view that renders
the engine's output.

## Pane tiers

Each pane renders in one of three tiers based on its computed slot size:

- **Active** — the focused pane, rendered at full resolution.
- **Scaled** — condensed panes above `condenseThreshold` (default 80pt).
  Rendered live at their real tile size, so the PTY grid reflows to fit
  (fewer columns/rows, real text wrapping) rather than shrinking a
  fixed-size render. This means every focus change resizes the PTY of
  both the outgoing and incoming pane.
- **Pill** — panes below the condense threshold render as a title-only
  rounded pill with no live surface hosted at all.

All tiers get rounded corners (`cornerRadius: 10`) and a small gap
between tiles, filled with the user's configured split-divider color.
Scaled tiles show a small floating title badge (top-leading) since
Ghostty normally only shows a pane's title in the window titlebar while
it's focused.

## Interaction

- Click any condensed tile to focus it; the layout animates (spring
  transition) to the new arrangement.
- Manual keyboard split navigation (`ctrl+cmd+arrow` / `goto_split`)
  works the same as in manual split mode.

## Known rough edges

- Clicking a tile *during* the ~0.35s focus-change animation can miss,
  since hit-testing snaps to the tile's final position while the visual
  transition is still interpolating.
- A full-screen TUI app (vim, htop, etc.) sitting in a condensed pane
  will reflow/redraw on every relayout, since the "scaled" tier's PTY
  grid tracks its real tile size rather than staying fixed.
- Window resize and pane open/close while in adaptive mode haven't had
  dedicated edge-case testing yet.

## Branding

The macOS app target builds as `RoundedStone.app`
(`com.roundedstone.terminal`) instead of `Ghostty.app`, so it can run
side by side with an unmodified Ghostty install. The config directory
is unchanged (`~/Library/Application Support/com.mitchellh.ghostty/`) —
it's controlled by a separate hardcoded constant
(`src/build_config.zig`), not the app's bundle identifier, so the
rename doesn't orphan existing config. The Xcode target name, the
in-bundle executable name, and the app icon are still the upstream
Ghostty defaults; only the product name, bundle ID, and display name
were changed.
