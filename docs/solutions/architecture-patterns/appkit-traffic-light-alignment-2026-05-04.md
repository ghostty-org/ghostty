---
title: AppKit Traffic-Light Alignment via NSToolbar
date: 2026-05-04
category: docs/solutions/architecture-patterns/
module: TerminalWindow / WorkspaceViewContainer
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Sidebar toolbar row needs to align vertically with traffic lights
  - After any upstream merge touching TerminalWindow or titlebar code
  - Window uses a custom NSView-based toolbar row instead of native NSToolbar items
tags:
  - appkit
  - titlebar
  - nstoolbar
  - traffic-lights
  - alignment
  - upstream-merge
  - macos
related_components:
  - WorkspaceLayout
  - WorkspaceSidebarView
---

# AppKit Traffic-Light Alignment via NSToolbar

> **Complement to the Arc/Dia pattern.** The [Arc/Dia invisible titlebar doc](../architecture/titlebar-accessory-inflation-arc-style-fix.md) uses "NO NSToolbar" to achieve a fully invisible titlebar at the traffic lights' natural position. This doc is for the additional step: making custom UI elements (sidebar toggle, + button) co-planar with traffic lights. Both patterns are active in Ghostties simultaneously.

## Context

After a 985-commit upstream merge from `ghostty-org/ghostty` (2026-05-02), commit `a85529c61` removed an NSToolbar that had been part of a prior alignment fix. Without the toolbar, AppKit's titlebar zone shrank from ~44pt to ~16pt, dropping traffic lights from ~16pt to ~8pt from the window top. The custom sidebar toggle and SwiftUI + button — anchored to hardcoded constants — no longer matched.

The debugging arc ran across five sessions over two days (session history). Three structural approaches failed before the root cause was understood: AppKit keys traffic-light vertical centering exclusively off the presence of an `NSToolbar`, not off accessories, styleMask, or manual frame setting.

## Guidance

### 1. Attach an empty NSToolbar in `TerminalWindow.awakeFromNib()`

```swift
// MARK: - Ghostties fork fence (alignment toolbar) — see reference-traffic-light-alignment-solved.md
// Attach an empty NSToolbar with toolbarStyle = .unified so AppKit grows
// the titlebar zone and auto-centers traffic lights inside it.
// titleVisibility = .hidden and titlebarAppearsTransparent = true keep
// the toolbar surface invisible — only the geometric side effect is needed.
// isAttachingAlignmentToolbar prevents the toolbar didSet from flipping
// viewModel.hasToolbar, which would shift right-side titlebar accessories.
isAttachingAlignmentToolbar = true
defer { isAttachingAlignmentToolbar = false }
let ghosttiesToolbar = NSToolbar(identifier: "GhosttiesTerminalToolbar")
ghosttiesToolbar.showsBaselineSeparator = false
self.toolbar = ghosttiesToolbar
self.toolbarStyle = .unified
self.titleVisibility = .hidden
self.titlebarAppearsTransparent = true
// MARK: - End Ghostties fork fence (alignment toolbar)
```

The `isAttachingAlignmentToolbar` flag (`private var Bool` on `TerminalWindow`) prevents the `toolbar` `didSet` from setting `viewModel.hasToolbar = true`, which would incorrectly shift the right-side titlebar accessories (reset zoom, update pill) downward.

### 2. Derive the toolbar row Y from the live close-button frame — `WorkspaceLayout.swift`

```swift
static func titlebarRowTopAnchorConstant(in view: NSView) -> CGFloat? {
    guard let win = view.window,
          let close = win.standardWindowButton(.closeButton),
          close.window === win else { return nil }
    let closeInView = close.convert(close.bounds, to: view)
    // AppKit unflipped coords: larger Y = visually higher.
    let rowY_unflipped = closeInView.midY - breathingRoomBelowChrome  // breathingRoom = 0
    // topAnchor + N = N pts below visual top; visual top = bounds.height (unflipped).
    return view.bounds.height - rowY_unflipped
}
```

`breathingRoomBelowChrome = 0` means exact co-planar alignment (confirmed from design mock). The coordinate inversion converts AppKit's unflipped Y to the Auto Layout `topAnchor + constant` form.

### 3. Update the constraint every `layout()` pass — `WorkspaceViewContainer.swift`

```swift
override func layout() {
    super.layout()
    // ...
    var didUpdateConstraintThisPass = false
    if let constant = WorkspaceLayout.titlebarRowTopAnchorConstant(in: self) {
        if abs(sidebarToggleCenterYConstraint.constant - constant) > 0.5 {
            sidebarToggleCenterYConstraint.constant = constant
            didUpdateConstraintThisPass = true
        }
        // Publish to SwiftUI so the + button spacer stays in sync.
        if abs(WorkspaceStore.shared.toolbarRowTopAnchorConstant - constant) > 0.5 {
            WorkspaceStore.shared.toolbarRowTopAnchorConstant = constant
        }
    }
    // DEBUG assertion uses didUpdateConstraintThisPass — see Prevention.
}
```

Anchor `sidebarToggleCenterYConstraint` to `self.topAnchor`, not `terminalShadowHost.topAnchor`. The terminal card sits ~387pt below the window top — using the card's anchor produces the wrong position.

## Why This Works

AppKit controls traffic-light vertical centering based on the presence of `NSToolbar`, not on titlebar content or accessories. Without a toolbar, AppKit uses a default titlebar height (~16pt), centering traffic lights at ~8pt from the top. With `NSToolbar` and `toolbarStyle = .unified`, AppKit grows the zone to ~44pt and centers traffic lights at ~16pt. This is the mechanism used by Linear, Notion, and Safari. It is not documented in Apple headers — discoverable only by instrumenting `closeButton.frame` before and after adding the toolbar.

The live-measurement approach in `layout()` makes the sidebar elements track whatever position AppKit chooses, automatically surviving macOS version bumps (Zed logged a traffic-light spacing change for macOS 26 in PR #38756) and future upstream merges.

## What Doesn't Work

| Approach                                                                | Why It Fails                                                                                |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Hardcoded Y offsets (`terminalInset + terminalTitleBarHeight/2 = 22pt`) | Breaks across macOS version bumps and upstream titlebar refactors                           |
| Live `closeButton.frame` measurement _without_ NSToolbar                | Measures correctly but from a wrong baseline (~8pt instead of ~16pt)                        |
| `NSTitlebarAccessoryViewController` with `.leading` attribute           | Does not cause AppKit to re-center traffic lights on macOS 26; five sessions confirmed this |
| `asyncAfter(0.1)` assertion deferral                                    | Fragile timing; correct fix is `didUpdateConstraintThisPass` flag                           |
| Reading `closeButton.frame` in `viewDidMoveToWindow`                    | Too early; AppKit hasn't run titlebar layout yet; returns zero or stale frame               |
| Transparent leading accessory to force 32pt zone                        | Same failure mode — AppKit ignores accessories for traffic-light centering                  |

## When to Apply

- After any upstream merge touching `TerminalWindow.swift` or files in `Window Styles/`
- When traffic lights appear too high or too low after a macOS update
- When sidebar toggle or SwiftUI + button is misaligned even if traffic lights look correct (indicates `layout()` measurement path broke)
- When a Debug build fires `[alignment] Traffic light Y regressed` on first window focus

## Upstream Merge Checklist

After any merge from `upstream/ghostty-org/ghostty`:

1. Verify both fork fence blocks still exist:
   ```bash
   grep -n "Ghostties fork fence" "macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift"
   ```
2. Build Debug scheme, open a terminal window, bring to key. Assertion fire = NSToolbar block removed.
3. Visually confirm traffic lights, sidebar toggle, and + button are co-planar (~16pt from top).
4. If `expectedCloseButtonTopInset` needs updating (future macOS changes zone height): measure from debug print, update constant + comment with new macOS version.

## Prevention

**Guard 1 — TerminalWindow** (`#if DEBUG`, one-shot on first `didBecomeKey`):

Asserts `closeButton.topInset ≈ 26pt ± 3` on the first key event. Skips CI test host (`XCTestConfigurationFilePath == nil`) and subclasses (`type(of: self) == TerminalWindow.self`).

Coordinate math: `topInset = superview.bounds.height - closeButton.frame.midY`. Use `closeButton.superview` (the titlebar layer), not `contentView` — traffic lights live above contentView in the titlebar hierarchy. Converting to contentView gives the wrong Y.

**Guard 2 — WorkspaceViewContainer** (`#if DEBUG`, every `layout()` pass):

Asserts `sidebarToggleButton.frame.midY ≈ close.midY ± 2.0`. The `didUpdateConstraintThisPass` flag skips the assertion in the same layout cycle where the constraint was just updated — the button frame still reflects the prior cycle and the assertion would fire a false positive.

**`MARK: - Ghostties fork fence` markers**: Both blocks are paired. Searchable: `grep -n "Ghostties fork fence" TerminalWindow.swift`. If you remove one, re-evaluate the other.

## Related

- [Arc/Dia Invisible Titlebar Pattern](../architecture/titlebar-accessory-inflation-arc-style-fix.md) — prerequisite; establishes the invisible titlebar. The "NO NSToolbar" rule in that doc achieves the invisible titlebar itself; the NSToolbar alignment step is additive on top.
- [Force Base Terminal Nib](../architecture/nib-window-subclass-titlebar-hiding.md) — earlier prerequisite
- `reference-traffic-light-alignment-solved.md` in project memory — full commit history, coordinate math, and quick-diagnosis table
