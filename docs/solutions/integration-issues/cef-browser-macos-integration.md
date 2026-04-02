---
title: CEF Browser Integration — macOS AppKit Embedding
date: 2026-03-31
category: integration-issues
component: CEF Browser / Embedded Chromium
severity: high
symptoms:
  - App crashes on Cmd+B (SIGABRT) due to message pump threading
  - Beach ball from main thread flooding
  - Browser viewport doesn't fill panel or resize with window
  - Localhost dev server connections refused (ERR_CONNECTION_REFUSED)
  - Popup windows crash app (frame timeout errors)
  - Tab bar Combine/@MainActor race condition
tags:
  - cef
  - message-pump
  - external-message-pump
  - main-thread-safety
  - viewport-layout
  - network-entitlements
  - popup-handling
  - macos
  - appkit
related_commits:
  - d6e24080f
  - 2c187c224
  - 3a0b3c69a
  - bdb323d37
  - acd3aeaf1
  - 10e466f51
  - 67a597600
  - 5d2fe5f4b
  - ea37e5eac
---

# CEF Browser Integration in a macOS AppKit App

## Problem

Embedding CEF (Chromium Embedded Framework) 146 into Ghostties — an existing macOS AppKit app — caused cascading failures: crashes on browser creation, UI freezes, viewport sizing issues, blocked localhost, and popup handling crashes.

## Root Causes & Solutions

### 1. Crash on Browser Creation (Primary)

**Cause:** CEF's macOS implementation requires `external_message_pump = true` with a `CefApp` subclass providing `CefBrowserProcessHandler::OnScheduleMessagePumpWork()`. Without this, CEF's internal threads can't dispatch work to the main thread, causing Chromium to abort.

**Fix:** Custom CefApp with dispatch-based message pump:

```objc
class GhosttiesBrowserProcessHandler : public CefBrowserProcessHandler {
public:
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        if (delay_ms <= 0) {
            if (!work_pending_.exchange(true)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    work_pending_ = false;
                    CefDoMessageLoopWork();
                });
            }
        } else {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ CefDoMessageLoopWork(); });
        }
    }
private:
    std::atomic<bool> work_pending_{false};
};
```

The `std::atomic<bool>` coalescing is critical — without it, zero-delay callbacks flood the main queue and starve AppKit (beach ball).

### 2. Viewport Not Filling / Not Resizing

**Cause:** CEF inserts its own child NSView for rendering but doesn't subscribe to parent resize events. `WasResized()` must be called explicitly.

**Fix:** Sync child bounds on every layout pass:

```objc
- (void)_syncCefChildBounds {
    for (NSView *child in self.subviews) {
        if (!NSEqualRects(child.frame, self.bounds)) {
            child.frame = self.bounds;
        }
    }
    if (_browser) _browser->GetHost()->WasResized();
}
```

Called from `layout`, `setFrameSize:`, `viewDidEndLiveResize`, and `_browserDidCreate:`.

### 3. Localhost Blocked

**Cause:** Missing `com.apple.security.network.client` and `network.server` entitlements on the main app (not just helpers).

**Fix:** Added to all three entitlements files (Debug, ReleaseLocal, Release).

### 4. Popup Crashes

**Cause:** `OnBeforePopup` was cancelling ALL popups. Programmatic popups (OAuth, iframes) need to proceed normally — only user-gesture clicks should be redirected.

**Fix:** Filter on `user_gesture`:

```cpp
if (user_gesture && !target_url.empty()) {
    browser->GetMainFrame()->LoadURL(target_url);
    return true;  // Cancel popup, load inline
}
return false;  // Allow programmatic popups
```

### 5. Missing CefSettings

**Cause:** `root_cache_path`, `cache_path`, and `locale` not set. Helpers crash without these during IPC setup.

**Fix:** Set all three before CefInitialize:

```objc
CefString(&settings.root_cache_path) = [cacheDir UTF8String];
CefString(&settings.cache_path) = [cacheDir UTF8String];
CefString(&settings.locale) = "en-US";
```

## CEF macOS Integration Rules

Non-obvious requirements discovered:

1. **`external_message_pump = true` is non-negotiable** for AppKit apps
2. **CefApp subclass required** — must implement `OnScheduleMessagePumpWork`
3. **Zero-delay coalescing required** — atomic flag prevents main queue flooding
4. **4Hz backup timer** — catches missed callbacks during window drags/menus
5. **No zero-size views** — CEF compositor aborts silently on zero dimensions
6. **CreateBrowser must be immediate** — Chromium's ProfileManager shuts down if no browser within ~5s of CefInitialize
7. **Framework must be versioned bundle** — flat CEF framework needs `Versions/A/` + symlinks
8. **All 5 helper variants required** — main, Alerts, GPU, Plugin, Renderer
9. **Helper uses CefExecuteProcess, not CefInitialize** — with real argc/argv
10. **WasResized() on every layout change** — CEF doesn't auto-follow parent

## Security Hardening (from code review)

### 6. URL Scheme Filtering

**Added:** `GhosttiesIsAllowedScheme()` helper in CEFBrowserView.mm. Only `http://`, `https://`, and `about:` are allowed. Blocks `file://`, `javascript://`, `data://` at three enforcement points: `loadURL:`, `OnBeforePopup`, and the Swift URL bar handler.

### 7. Cache Directory Security

**Moved** CEF cache from `/tmp/ghostties-cef` (world-readable) to `~/Library/Application Support/com.seansmithdesign.ghostties/CEF/` (user-only). Log file moved alongside.

### 8. Popup Hardening

All non-user-gesture popups are now blocked (`return true`). Only explicit user clicks redirect to the main frame. Prevents popup storms and uncontrolled windows from malicious pages.

### 9. Entitlement Minimization

Removed `network.server` from all entitlements (remote debugging disabled). Only `network.client` retained.

## Performance Fixes (from code review)

- **Backup timer bumped from 4Hz to 30Hz** — eliminates 250ms latency spikes on interactive content
- **`WasResized()` guarded behind actual bounds change** — halves compositor work during resize
- **Explicit `closeBrowser()` in closeAllTabs/closeTab** — deterministic Chromium process cleanup

## Prevention Checklist

Before embedding CEF in a macOS app:

- [ ] `external_message_pump = true` in CefSettings
- [ ] CefApp subclass with OnScheduleMessagePumpWork (atomic coalescing)
- [ ] Backup timer (30Hz) via NSRunLoop
- [ ] CefScopedLibraryLoader before CefInitialize
- [ ] Non-zero initial frame (min 1x1, default 800x600)
- [ ] CreateBrowser called immediately after CefInitialize
- [ ] `root_cache_path` and `cache_path` in `~/Library/Application Support/` (NOT /tmp)
- [ ] `locale` set explicitly (e.g., "en-US")
- [ ] All 5 helper .app bundles in Contents/Frameworks/
- [ ] Helpers ad-hoc codesigned with entitlements
- [ ] `network.client` on main app (NOT `network.server` unless needed)
- [ ] `xattr -dr com.apple.quarantine` on downloaded framework
- [ ] NSApplicationWillTerminateNotification observer for CefShutdown
- [ ] Weak references (`__weak`) in C++ handler classes
- [ ] All handler callbacks dispatch to main queue
- [ ] URL scheme allowlist (block `file://`, `javascript://`, `data://`)
- [ ] Block non-user-gesture popups
- [ ] Explicit `closeBrowser()` on tab close (don't rely on ARC dealloc)

## Common Pitfalls

| Looks correct but breaks | Symptom | Fix |
|--------------------------|---------|-----|
| No `external_message_pump` | Beach ball during page load | Set `true` + CefApp |
| `dispatch_async` without coalescing | Beach ball (queue flood) | Atomic `work_pending_` flag |
| `CreateBrowser` deferred to later | App exits after 5s, no error | Call in init or viewDidMoveToWindow |
| Missing helper .app variants | Specific features silently fail | Create all 5 from embed script |
| `WasResized()` without bounds check | Doubled compositor work | Guard behind `boundsChanged` flag |
| `OnBeforePopup` returns false for all | Uncontrolled popup windows | Block non-user-gesture, redirect user-gesture |
| No URL scheme filtering | `file://` reads local files | Allowlist `http/https/about` only |
| Cache in /tmp | World-readable cookies/history | Use `~/Library/Application Support/` |
| Tab close without `closeBrowser()` | Leaked Chromium processes | Call explicitly before removing reference |

## Testing Strategy

```bash
# Automated crash test
open "$APP_BUNDLE" && sleep 4
osascript -e 'tell application "Ghostties" to activate; delay 1; tell application "System Events" to keystroke "b" using command down'
sleep 8
pgrep -x ghostty && echo "PASS" || echo "FAIL"
```

Check helper processes: `pgrep -f "Ghostties Helper" | wc -l` (expect 3-5 during active browsing).
