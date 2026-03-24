# Embedded Browser CEF Phase 1 — Implementation Plan

**Date:** 2026-03-24
**Feature:** Embedded Chromium browser via CEF
**Branch:** `feat/embedded-browser-cef`

## Overview

Add an embedded Chromium browser to Ghostties using CEF (Chromium Embedded Framework). Phase 1 establishes the foundation: CEF acquisition, ObjC++ bridge, Swift integration, browser panel with URL bar, internal tabs, and DevTools in a separate window.

**Exit criteria:** Can toggle a browser panel, type a URL, see a rendered page, navigate back/forward/reload, manage tabs, and open DevTools in a separate window.

---

## Step 1: Kind.browser on AgentTemplate

**Complexity:** S | **Dependencies:** None | **Parallel:** Yes

**Files to modify:**
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift`

**Changes:**
- Add `.browser` to `Kind` enum (with safe Codable fallback to `.shell`)
- Add built-in browser template (deterministic UUID `00000000-0000-0000-0000-000000000004`)
- Update `defaults` array to include browser
- `buildCommand()` returns empty string for `.browser`
- Icon: `globe`

---

## Step 2: CEF Download Script

**Complexity:** M | **Dependencies:** None | **Parallel:** Yes

**Files to create:**
- `scripts/download-cef.sh`

**Changes:**
- Downloads CEF ARM64 macOS standard distribution from `cef-builds.spotifycdn.com`
- Pin to specific stable version with SHA-256 validation
- Extracts to `vendor/cef/` (gitignored)
- Only re-downloads if version doesn't match
- Add `vendor/cef/` to `.gitignore`

---

## Step 3: CEFBridge Manager (ObjC++)

**Complexity:** M | **Dependencies:** Step 2 (CEF headers) | **Parallel:** Yes (can write against header signatures)

**Files to create:**
- `macos/Sources/Helpers/CEF/CEFBridge.h`
- `macos/Sources/Helpers/CEF/CEFBridge.mm`

**API surface:**
```objc
@interface CEFBridgeManager : NSObject
+ (BOOL)isInitialized;
+ (void)initializeIfNeeded;
+ (void)shutdown;
+ (int)remoteDebuggingPort;
@end
```

**Implementation:**
- Lazy init: `CefInitialize()` on first call
- Settings: `no_sandbox = true`, `framework_dir_path`, `browser_subprocess_path`, `remote_debugging_port = 0`
- Message loop: `NSTimer` at 60fps calling `CefDoMessageLoopWork()` in common run loop modes
- Shutdown via `NSApplicationWillTerminateNotification` — closes all browsers then `CefShutdown()`

---

## Step 4: CEFBrowserView (ObjC++)

**Complexity:** L | **Dependencies:** Step 3 (manager exists) | **Parallel:** Yes (can write against bridge API)

**Files to create:**
- `macos/Sources/Helpers/CEF/CEFBrowserView.h`
- `macos/Sources/Helpers/CEF/CEFBrowserView.mm`

**API surface:**
```objc
@protocol CEFBrowserViewDelegate <NSObject>
@optional
- (void)browserView:(CEFBrowserView *)view didChangeURL:(NSString *)url;
- (void)browserView:(CEFBrowserView *)view didChangeTitle:(NSString *)title;
- (void)browserView:(CEFBrowserView *)view didChangeLoadingState:(BOOL)isLoading
         canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
@end

@interface CEFBrowserView : NSView
@property (nonatomic, weak) id<CEFBrowserViewDelegate> delegate;
- (instancetype)initWithFrame:(NSRect)frame url:(NSString *)url;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)showDevTools;
- (void)closeDevTools;
- (void)closeBrowser;
- (NSString *)currentURL;
- (NSString *)currentTitle;
- (BOOL)isLoading;
- (BOOL)canGoBack;
- (BOOL)canGoForward;
@end
```

**Implementation:**
- Implements `CefClient`, `CefLifeSpanHandler`, `CefDisplayHandler`, `CefLoadHandler` as inner C++ classes
- Creates browser via `CefBrowserHost::CreateBrowser()` with this NSView as window handle
- DevTools via `CefBrowserHost::ShowDevTools()` in separate window

---

## Step 5: BrowserTabManager + BrowserTabBar (Swift)

**Complexity:** M | **Dependencies:** None (pure Swift) | **Parallel:** Yes

**Files to create:**
- `macos/Sources/Features/Ghostties/BrowserTabManager.swift`
- `macos/Sources/Features/Ghostties/BrowserTabBar.swift`
- `macos/Tests/Workspace/BrowserTabManagerTests.swift`

**BrowserTabManager:**
- `@MainActor` class managing array of tabs
- Each tab: `id: UUID`, `browserView: CEFBrowserView`, `title`, `url`, `isLoading`
- Methods: `createTab(url:)`, `closeTab(id:)`, `switchTab(id:)`, `closeAllTabs()`
- `@Published` properties for SwiftUI observation

**BrowserTabBar (NSView):**
- Horizontal row of tab buttons
- Active tab highlighted, close button on hover
- `[+]` button creates new tab
- Hidden when only 1 tab exists
- Height: 24pt

---

## Step 6: Browser Panel Layout + Globe Toggle

**Complexity:** L | **Dependencies:** None (layout work, CEF views can be stubbed) | **Parallel:** Yes

**Files to create:**
- `macos/Sources/Features/Ghostties/BrowserPanelView.swift`
- `macos/Sources/Features/Ghostties/BrowserNavigationBar.swift`

**Files to modify:**
- `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift`
- `macos/Sources/Features/Ghostties/WorkspaceLayout.swift`

**WorkspaceViewContainer changes:**
- Add `browserShadowHost` NSView (identical layer config to terminal shadow host)
- Add `browserToggleButton` (`globe` / `globe.fill`) at trailing edge of terminal title bar
- Add `isBrowserVisible` state + `toggleBrowser()` method
- Constraint system: terminal trailing → browser leading (8pt gap), browser trailing → window (8pt inset)
- Animation: same `NSAnimationContext` pattern as sidebar (0.2s easeInOut)
- Also update `sidebarToggleButton` to use filled/outline system

**WorkspaceLayout additions:**
- `browserMinWidth: CGFloat = 320`
- `browserWidthRatio: CGFloat = 0.5`

**BrowserNavigationBar:**
- `[<] [>] [↻] [____URL field____] [DevTools]`
- Same styling as terminal title bar controls

**BrowserPanelView:**
- Contains tab bar + navigation bar + CEFBrowserView area
- Floating card treatment (rounded corners, shadow, inset)

**Keyboard shortcut:** `Cmd+B` for browser toggle

---

## Sequential Steps (After Parallel Work)

### Step 7: Helper Process Setup

**Complexity:** M | **Dependencies:** Step 2 (CEF downloaded)

- Create 4 helper `.app` bundles (main, GPU, renderer, plugin)
- Info.plist templates with correct bundle identifiers
- `scripts/setup-cef-helpers.sh` for bundling
- Entitlements: allow unsigned executable memory, disable library validation

### Step 8: Xcode Project Integration

**Complexity:** M | **Dependencies:** Steps 2, 7

- Add CEF framework to project (link + embed)
- Framework search paths + header search paths
- Run Script build phase for copying helpers + resources
- Code signing build phase for helpers
- Add `#import "CEFBridge.h"` and `#import "CEFBrowserView.h"` to bridging header

### Step 9: Session Integration

**Complexity:** M | **Dependencies:** All above

**Files to modify:**
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift`

**Changes:**
- Browser session state: `browserSessionId`, `browserTabManager`
- `createSession` for `.browser` kind: init CEF, create tab manager, show panel
- `focusSession`: show browser or terminal based on session kind
- `closeSession`: close all tabs, hide panel
- Activity tracking: loading → processing, loaded → idle, error → error

### Step 10: Smoke Test + Integration

**Complexity:** M | **Dependencies:** All above

- Verify CEF initializes without crash
- Load a URL, verify page renders
- Navigate back/forward/reload
- Open DevTools in separate window
- Create/switch/close tabs
- Toggle browser panel via globe icon and Cmd+B
- App shutdown with browser open (no hangs)
- Light/dark mode appearance

---

## Dependency Graph

```
Step 1 (Kind.browser)     ──┐
Step 2 (CEF download)     ──┤
Step 3 (CEFBridge.mm)     ──┤── All parallel
Step 4 (CEFBrowserView.mm)──┤
Step 5 (TabManager)       ──┤
Step 6 (Layout + globe)   ──┘
                              │
                              v
Step 7 (Helpers)  ──> Step 8 (Xcode) ──> Step 9 (Sessions) ──> Step 10 (Smoke test)
```

## Risks

| Risk | Mitigation |
|------|-----------|
| CEF headers don't compile with project ObjC settings | Isolate all CEF includes in .mm files only, never in .h exposed to Swift |
| Message loop timer causes terminal jank | Only start timer when CEF initialized; profile and adjust interval |
| Helper process signing fails in development | Start with ad-hoc signing; proper signing comes later |
| `CefShutdown()` hangs on quit | Shutdown handler closes all browsers with timeout before calling CefShutdown |
| NSView hosting conflicts with shadow host clipping | Test early; CEF creates its own view hierarchy inside parent |
| 300MB CEF download slows first build | Script caches download; only re-downloads on version change |

## File Summary

**New files (12):**
- `scripts/download-cef.sh`
- `scripts/setup-cef-helpers.sh`
- `macos/Sources/Helpers/CEF/CEFBridge.h`
- `macos/Sources/Helpers/CEF/CEFBridge.mm`
- `macos/Sources/Helpers/CEF/CEFBrowserView.h`
- `macos/Sources/Helpers/CEF/CEFBrowserView.mm`
- `macos/Sources/Features/Ghostties/BrowserPanelView.swift`
- `macos/Sources/Features/Ghostties/BrowserNavigationBar.swift`
- `macos/Sources/Features/Ghostties/BrowserTabBar.swift`
- `macos/Sources/Features/Ghostties/BrowserTabManager.swift`
- `macos/Tests/Workspace/BrowserTabManagerTests.swift`
- `macos/Helpers/CEF/` (Info.plist templates)

**Modified files (6):**
- `macos/Sources/App/macOS/ghostty-bridging-header.h`
- `macos/Sources/Features/Ghostties/Models/AgentTemplate.swift`
- `macos/Sources/Features/Ghostties/WorkspaceViewContainer.swift`
- `macos/Sources/Features/Ghostties/WorkspaceLayout.swift`
- `macos/Sources/Features/Ghostties/SessionCoordinator.swift`
- `macos/Ghostties.xcodeproj/project.pbxproj`
