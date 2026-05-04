---
title: "Remove Titlebar Accessory Inflation for Arc-Style Invisible Titlebar"
category: architecture
component:
  - TerminalController
  - WorkspaceSidebarView
symptoms:
  - Visible titlebar band despite titlebarAppearsTransparent = true
  - Traffic lights and sidebar toolbar buttons on different horizontal lines
  - ~30pt gap between window chrome and sidebar content
tags:
  - macos
  - nswindow
  - titlebar
  - workspace-sidebar
  - arc-browser-pattern
  - NSTitlebarAccessoryViewController
date_solved: 2026-02-26
---

# Remove Titlebar Accessory Inflation for Arc-Style Invisible Titlebar

## Problem

After forcing the base Terminal nib (commit `509fc927f`) to hide the native title text, a visible titlebar band persisted in workspace mode. The band was ~30pt tall, pushing the sidebar toolbar buttons below the traffic lights instead of aligning them on the same horizontal line.

**Observable symptoms:**

- Titlebar text and background were gone, but vertical space remained
- Traffic lights sat higher than the sidebar's `+` and sidebar-toggle buttons
- The sidebar background did not extend flush to the window's top chrome edge

## Root Cause

Two `NSTitlebarAccessoryViewControllers` added in `TerminalWindow.awakeFromNib()` inflated the titlebar height from ~28pt to ~50-60pt:

```swift
// TerminalWindow.swift — awakeFromNib()
resetZoomAccessory.layoutAttribute = .right
addTitlebarAccessoryViewController(resetZoomAccessory)   // +height

updateAccessory.layoutAttribute = .right
addTitlebarAccessoryViewController(updateAccessory)       // +height
```

Additionally:

1. **Missing `titlebarSeparatorStyle = .none`** — the default separator drew a hairline between titlebar and content
2. **Missing `.ignoresSafeArea`** — with `.fullSizeContentView`, the NSWindow safe area includes the titlebar height. The sidebar's `NSHostingView` passed this inset to SwiftUI, pushing the `VStack` down even though the frame extended to the top

## Solution

Three changes, all applied as a unit:

### 1. Remove accessories and suppress separator

**File:** `TerminalController.swift` — `configureWorkspaceTitlebar()`

```swift
private func configureWorkspaceTitlebar() {
    guard let window else { return }

    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none

    // Remove titlebar accessories (resetZoom, update notification) that
    // the base TerminalWindow adds in awakeFromNib. These inflate the
    // titlebar height and create a visible band. The workspace sidebar
    // replaces their functionality.
    while !window.titlebarAccessoryViewControllers.isEmpty {
        window.removeTitlebarAccessoryViewController(at: 0)
    }
}
```

Called from `windowDidLoad()` after setting `WorkspaceViewContainer` as the content view and after `awakeFromNib` has added the accessories.

### 2. Ignore safe area in sidebar SwiftUI view

**File:** `WorkspaceSidebarView.swift` — root body modifier chain

```swift
.background(.clear)
.ignoresSafeArea(.container, edges: .top)
```

This tells SwiftUI to extend into the titlebar safe area inset, allowing the sidebar toolbar to start at y=0 of the hosting view frame.

### The Arc/Dia Browser Recipe

The complete pattern for an invisible titlebar with naturally-positioned traffic lights:

```
.titled + .fullSizeContentView
+ titlebarAppearsTransparent = true
+ titleVisibility = .hidden
+ titlebarSeparatorStyle = .none
+ NO NSTitlebarAccessoryViewControllers
+ NO NSToolbar
= invisible titlebar, traffic lights at natural ~(7, 6) position
```

All components are required. Missing any one leaves visual artifacts.

## Investigation Trail

| #   | Approach                                         | Result      | Why                                    |
| --- | ------------------------------------------------ | ----------- | -------------------------------------- |
| 1   | KVO + `isHidden` on NSTextField                  | Failed      | macOS resets `isHidden` internally     |
| 2   | `alphaValue = 0` on NSTextField                  | Failed      | Targeted wrong element                 |
| 3   | `toolbar = nil`                                  | Partial     | Removed text but band remained         |
| 4   | Clear `titlebarContainer.layer?.backgroundColor` | Failed      | `syncAppearance()` repaints it         |
| 5   | Force base Terminal nib (`509fc927f`)            | Partial     | Fixed title text, band remained        |
| 6   | Remove accessories + separator style             | **Success** | Eliminates structural height inflation |

**Key insight:** The titlebar band was a **structural layout problem**, not a visual style problem. The accessories reserved height that remained allocated even after hiding text. Removing the accessories prevents the height reservation entirely.

## Prevention

1. **The Arc/Dia pattern is atomic** — all four properties (visibility, transparency, separator, accessories) must be set together in one place. Missing one leaves artifacts.
2. **Defer titlebar config to post-awakeFromNib** — let the base class add accessories, then remove them in the controller. Safer than preventing addition.
3. **Always add `.ignoresSafeArea(.container, edges: .top)` to SwiftUI views that must reach the window edge** when using `.fullSizeContentView`.
4. **Guard against reapplication** — use `while !isEmpty` loop rather than fixed count. Check that `syncAppearance()` and fullscreen transitions don't re-add accessories.

## Testing Checklist

- [ ] No visible band in pinned, closed, and overlay sidebar states
- [ ] Traffic lights aligned horizontally with sidebar toolbar buttons
- [ ] `window.titlebarAccessoryViewControllers.count == 0` after configuration
- [ ] Fullscreen enter/exit doesn't restore the band
- [ ] Dark/light mode toggle preserves invisible titlebar
- [ ] App quit and relaunch restores state correctly

## Related

- [Force Base Terminal Nib](nib-window-subclass-titlebar-hiding.md) — prerequisite fix that bypasses the complex window subclass
- [Sidebar 3-State Machine](sidebar-3-state-machine-overlay-pattern.md) — the pinned/closed/overlay state machine this titlebar fix supports
- `TerminalWindow.swift` — base class where accessories are added in `awakeFromNib()`
- `HiddenTitlebarTerminalWindow.swift` — reference for `.titled` + `.fullSizeContentView` pattern (but hides traffic lights, which we don't want)
- [NSToolbar Alignment for Co-Planar Toolbar Row](../architecture-patterns/appkit-traffic-light-alignment-2026-05-04.md) — when you also need custom UI elements (sidebar toggle, + button) co-planar with traffic lights, an empty NSToolbar is required on top of this pattern
