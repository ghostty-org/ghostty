# Ghostty X

A macOS appearance fork based on `amsynist/ghostty-X` at e95bed633. The terminal engine remains Ghostty. The visual reference is the owner's OmniVM-X terminal: compact tabs aligned left, rounded split panes, six-point gutters and a blue focus outline. The UI implementation is written independently using native AppKit tab controls and SwiftUI split views; no OmniWM source or window-management dependency is included.

## Changes

- With `macos-titlebar-style = tabs` on macOS 26+, a custom tab strip replaces the native tab strip's visible contents within its existing titlebar accessory. Native AppKit tab groups still own windows, selection and restoration.
- Tabs support selection, close confirmation, rename, tab colors, drag reordering within a group, context menu movement and moving to a new window. Overflow scrolls horizontally and the selected tab is revealed. Keyboard bindings come from the existing Ghostty configuration.
- Split panes have eight-point corners, six-point gutters, and a focus outline. The existing terminal surfaces, drag/drop zones, split tree, zoom and equalize actions are retained. Divider geometry accounts for the entire gap and drag resizing uses translation to avoid jumps.
- The app bundle is `GhosttyX.app` (`com.amsynist.ghosttyx`) so the official application remains separate. The executable and Swift module keep their upstream names. Existing Ghostty configuration is reused. No custom user config, signing keys or terminal history belongs in this repository.
- macOS 13–15 retains upstream tab appearance. No private terminal engine APIs or additional dependency were introduced. Titlebar attachment uses the existing upstream AppKit hierarchy integration.

## Build

Read `AGENTS.md`, `macos/AGENTS.md` and `HACKING.md` first. This revision pins Zig 0.17.0. Use that exact compiler, Xcode with the Metal Toolchain, and Nushell:

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
macos/build.nu --configuration ReleaseLocal --arch arm64
macos/build.nu --configuration ReleaseLocal --arch arm64 --action test
```

The `--arch arm64` option matches the native-only framework; omit it when building a universal framework.

The release-optimized local app is `macos/build/ReleaseLocal/GhosttyX.app`. `ReleaseLocal` uses upstream local build signing; distributing or installing a trusted custom build requires explicit signing and validation. Building does not replace or quit an installed terminal. The development toolchain and local build logs are excluded using `.git/info/exclude`.

## Review and validation

See `macos/Tests/Splits/SplitViewGeometryTests.swift` and `macos/Tests/RoundedTerminalTabModelTests.swift` for focused coverage. Run the native test suite and lint the changed Swift files. Runtime checks should cover tabs, close warnings, overflow, drag reorder, detach, splits, resize, zoom, fullscreen and restored sessions. A successful compile is not evidence of those manual checks.

AI assistance: OpenAI Codex implemented this custom appearance and its focused tests at the owner's request. This is work in a personal fork, not a submitted upstream contribution.

## Current validation

- Release-optimized Apple Silicon core and `ReleaseLocal` macOS app builds succeeded with Xcode 27.2 and Zig 0.17.0.
- Native suite: 299 passed, one skipped, zero failures (300 tests, including parameterized runs). UI automation is skipped by the upstream runner.
- Strict SwiftLint passed on all six changed/new Swift source and test files; `git diff --check` passed.
- The built CLI reports the expected fork revision and validates the existing user configuration.
- The actual tab component was rendered offscreen with synthetic titles and visually inspected. Pane geometry and native group reorder/detach have automated coverage.
- The local app was signed using the certificate/key from OmniVM-X's ignored `.signing` folder, via a temporary keychain following its rebuild procedure. Deep, strict bundle signature verification passed. The original user keychain search list was restored and temporary key material removed. No signing key or certificate was copied into this repository. This is local signing, not notarization.
- Local signing helper, build logs, result summary and synthetic tab preview are in ignored `.local/`. Rebuilding replaces the signature using upstream build settings; re-sign using the local helper afterward.
- The user quit stock Ghostty, then the signed build was installed at `/Applications/Ghostty.app`. The complete stock bundle was retained in the user’s local terminal-backup directory. The existing Zera launcher path was verified; the active OmniWM rule now assigns the fork’s bundle ID to workspace 2. Full real-window validation (fullscreen, restoration, tab close confirmation, overflow, splits and physical keyboard shortcuts) remains unverified.

## Tab mouse-input correction

The first header used a draggable hosting view and SwiftUI button/drag recognizers in AppKit's titlebar. The corrected strip uses non-draggable native AppKit controls with first-click handling and stable per-window controls. Native inline title editing is bypassed for this custom strip so a rapid double-click cannot focus an invisible editor over the hidden stock tabs. Native double-click rename and context menus belong to the visible tab controls. Published tab snapshots now lay out new controls directly, without reading the previous model value during its `willSet` notification.

Two additional native fixture tests dispatch mouse events through the titlebar window: selecting another tab, and selecting a newly added tab above split content after resizing. The final suite passes 299 tests with one skip. These are disposable fixtures; physical mouse/trackpad behavior in the installed terminal still requires a user check.

The mouse-input correction has been installed at `/Applications/Ghostty.app` after the user quit the previous copy. Its executable hash matches the tested build and deep signature verification passed. The preceding custom build is retained in the local terminal-backup directory. Physical click confirmation is pending.

## Tab click z-order fix

Root cause of tabs not switching on physical clicks: whenever the selected tab changes, AppKit re-inserts its native `NSTabBar` as the last (frontmost) subview of the shared titlebar accessory view, above the rounded strip. The native bar was only made invisible with `alpha = 0`, but `NSTabBar` still hit-tests while transparent (and even while `isHidden`), so after the first switch every click landed on an invisible native tab button at a different x position (or on the `+`). An in-app trace confirmed it: the first click hit `RoundedTabCell`, later ones hit `NSTabButton`/`NSTextField` inside `NSTabBar`.

`TitlebarTabsTahoeTerminalWindow` now keeps the rounded strip frontmost with an in-place `sortSubviews` (constraints survive) on `becomeMain`, tab-bar setup, and right before AppKit hit-tests every mouse-down in `sendEvent`. A traced run of 10 scripted clicks across three tabs (two with splits) plus the `+` button switched correctly every time. `ProductionTabTitlebarTests` now also clicks back to the first tab after a switch. Installed at `/Applications/Ghostty.app`; the prior build is in the terminal-backup directory.

## Theme-matched tab gradients

Tabs take their colors from the active Ghostty config (palette 4 → 5 accent gradient, `foreground` for text; Tokyo Night fallback) and update on config reload. The selected tab is a rounded pill with a blue→magenta wash, gradient hairline border, top sheen and gradient underline; hover adds a neutral wash. Selection and hover fade over 0.18s via animatable `selectAmount`/`hoverAmount`. User tab colors keep their own underline. Previewed offscreen with the real component before install.
