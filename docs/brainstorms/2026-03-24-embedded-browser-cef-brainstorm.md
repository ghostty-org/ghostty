# Embedded Browser (CEF) Brainstorm — 2026-03-24

> Add an embedded Chromium browser to Ghostties via CEF (Chromium Embedded Framework). Browser sessions appear as another session type in the sidebar — click to switch between terminal and browser, just like switching between agent sessions today. Full Chrome DevTools available inline.

## What We're Building

A real Chromium browser embedded inside Ghostties. It lives alongside terminal sessions in the workspace sidebar — click a browser session to see a full web view in the terminal area, click a terminal session to switch back. No split panes for MVP, just tab-style switching.

**Three pillars:**
1. **Same-window web preview** — see your localhost app without Cmd+Tab to Chrome. The terminal and browser share the same workspace.
2. **Real Chrome DevTools** — not a WebKit inspector, not a dumbed-down panel. Actual Chrome DevTools running inline, same as production debugging.
3. **Agent-accessible browser** — agents can open URLs, inspect the DOM, read console output, and take screenshots via Chrome DevTools Protocol (CDP). This is the foundation for design review, visual regression, and autonomous web testing.

## Why CEF Over Alternatives

| Option | Why Not |
|--------|---------|
| **WKWebView** (macOS native) | WebKit, not Chromium — different engine than production. No Chrome DevTools. `isInspectable` gives Safari Web Inspector, which is a different tool with different capabilities. Can't access CDP. |
| **SwiftUI WebView** (macOS 26) | Same WebKit limitation. Great API, zero bundle cost, but fundamentally the wrong engine for production web debugging. Already noted in backlog as the lightweight option. |
| **Ultralight** | WebKit fork, not Chromium. No DevTools. Commercial license. Dead-end for agent integration — no CDP. |
| **QtWebEngine** | Chromium-based (good) but brings all of Qt as a dependency (~500MB). Massive framework dependency for one feature. |
| **Electron as library** | Not embeddable — Electron is an application framework, not a component. You'd be embedding an Electron app inside a native app, which is architecturally cursed. |
| **Servo** | Pre-alpha. No DevTools. Not production-ready. |
| **CEF** (chosen) | Real Chromium. Full Chrome DevTools. CDP built in. Battle-tested (Spotify, Steam, Figma Desktop, 1Password). ~200MB bundle cost is the tradeoff — but it's the only option that gives us a real browser with real DevTools and real CDP. |

**The core argument:** Ghostties is building for agents that work with web apps. Agents need CDP to inspect, interact, and screenshot. Only Chromium provides CDP. Therefore, only CEF (or building from raw Chromium source, which is worse) gives us what agents need.

### Relationship to the SwiftUI WebView Backlog Item

The existing backlog item (`backlog-embedded-browser-simulator.md`) chose SwiftUI `WebView` + `WebPage` (macOS 26) for zero bundle cost and native API. That's the right call for a simple localhost preview. This brainstorm is a different bet: we're building a browser that agents can programmatically control via CDP. The two aren't mutually exclusive — SwiftUI WebView could ship first as a lightweight preview, with CEF as the power-user / agent-integration path later. Or CEF could be the only browser, accepting the bundle size tradeoff upfront.

## Key Decisions

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Session model | New `Kind.browser` on AgentTemplate | Browser sessions are sidebar entries like terminal sessions. Same mental model, same switching UX. |
| 2 | View switching | Tab-style, not split view (MVP) | Simpler layout. Click terminal session → terminal fills the area. Click browser session → browser fills the area. Split view is a future enhancement. |
| 3 | DevTools MVP | Separate window via `CefBrowserHost::ShowDevTools()` | One API call. Ships fast. Inline DevTools panel is Phase 3. |
| 4 | DevTools goal | Inline panel via remote debug port + second CEF view | DevTools as a bottom panel in the browser view, like Chrome's docked DevTools. Requires a second CEF browser view loading the DevTools frontend. |
| 5 | URL entry | Manual URL bar at top of browser view | Simple text field + go button. Auto-detect from terminal output is Phase 2. Agent-initiated is Phase 4. |
| 6 | CEF initialization | Lazy — first browser session triggers `CefInitialize` | No startup cost for users who don't use browser sessions. 200-500ms cost paid once on first browser open. |
| 7 | Bridging layer | CEF C API → ObjC++ → Swift bridging header → SwiftUI | Standard pattern for C/C++ frameworks in Swift apps. ~500-800 lines of ObjC++ estimated. |
| 8 | Navigation | Back/forward/refresh buttons + URL bar | Minimal browser chrome. Not building a full browser — just enough to navigate. |

## Session Model

Browser sessions integrate into the existing workspace sidebar as a new template kind:

```swift
enum Kind: String, Codable {
    case shell       // User's login shell
    case claudeCode  // Claude Code CLI
    case custom      // Any CLI command
    case browser     // Embedded Chromium browser (new)
}
```

A browser session gets:
- A sidebar entry like any other session (with ghost character, name, status dot)
- Its own `AgentTemplate` with `kind: .browser`
- A URL as the "command" equivalent (what to load on creation)
- Status indicators: `loading` (page loading), `idle` (page loaded), `error` (page error / crash)

### What the User Sees

```
SIDEBAR                          MAIN AREA
┌─────────────────┐   ┌─────────────────────────────────┐
│  My Project      │   │  ← → ↻  localhost:3000         │
│   ● Terminal 1   │   │─────────────────────────────────│
│   ● Claude Code  │   │                                 │
│   ◉ Browser      │ ← │   [Rendered web page here]      │
│                  │   │                                 │
│                  │   │                                 │
│                  │   │                                 │
│                  │   │─────────────────────────────────│
│                  │   │  [DevTools panel, Phase 3]      │
└─────────────────┘   └─────────────────────────────────┘
```

Clicking "Terminal 1" swaps the main area to the terminal. Clicking "Browser" swaps to the browser. Same `coordinator.focusSession(id:)` flow — the SessionCoordinator manages browser views in `sessionTrees` alongside terminal split trees.

### Three-Column Layout (Future: Terminal + Browser Side-by-Side)

The ultimate layout is three columns with the browser panel having its own internal tabs:

```
SIDEBAR          TERMINAL              BROWSER PANEL
┌──────────┐   ┌──────────────────┐   ┌──────────────────────────┐
│ My Project│   │ $ next dev       │   │ [localhost:3000] [docs] [+]│
│  ● Term   │   │ ready on :3000   │   │────────────────────────────│
│  ● Claude │   │                  │   │                            │
│  ◉ Browser│   │                  │   │  [Live web page]           │
│           │   │                  │   │                            │
│           │   │                  │   │────────────────────────────│
│           │   │                  │   │  [DevTools docked below]   │
└──────────┘   └──────────────────┘   └──────────────────────────┘
```

**Internal tab bar:** The browser panel manages its own tabs — each tab is a separate CEF browser instance with its own URL, JS context, and process. The tab bar sits at the top of the browser panel, not in the Ghostties sidebar. This keeps the sidebar clean (one "Browser" entry) while supporting multiple pages.

**Constraints:**
- Maximum 3 columns (sidebar + terminal + browser). No deeper nesting.
- Each browser tab adds ~50-100MB memory (Chromium's per-process model). Practical limit: 5-8 tabs before memory pressure.
- Agents can open new tabs programmatically via CDP (`Target.createTarget`).
- Tab lifecycle: open, switch, reorder (drag), close. Standard browser tab UX.

**MVP is tab-style switching** (sidebar only, no side-by-side). The three-column layout is a Phase 2+ enhancement once the browser panel is stable.

### Visual Treatment — Floating Card (Matches Terminal)

The browser panel uses the **same floating card treatment as the terminal**, not the sidebar's flat style:

- **Rounded corners** — `terminalCornerRadius` (12pt), `cornerCurve: .continuous`
- **Canvas background** — the warm beige/pink canvas shows behind and between the cards
- **Inset padding** — `terminalInset` (8pt) gap between the browser card and window edges, and between the terminal and browser cards
- **Shadow** — same `shadowOpacity: 0.15`, `shadowRadius: 8`, `shadowOffset: (0, -2)` as the terminal's `terminalShadowHost`
- **Title bar region** — top area of the card holds the tab bar + URL bar, same height as `terminalTitleBarHeight`
- **Background color** — card background matches the terminal card (`cardBackgroundCGColor`), adapts to light/dark mode

Both cards float on the canvas as equal peers:

```
┌─ canvas (warm background) ──────────────────────────────────────────┐
│                                                                      │
│  ┌─ sidebar ─┐  ┌─ terminal card ─────┐  ┌─ browser card ────────┐  │
│  │ (flat,    │  │  ╭─────────────────╮ │  │  ╭────────────────╮   │  │
│  │  no card, │  │  │ title / toggle  │ │  │  │ tabs + URL bar │   │  │
│  │  flush)   │  │  ├─────────────────┤ │  │  ├────────────────┤   │  │
│  │           │  │  │                 │ │  │  │                │   │  │
│  │           │  │  │  terminal       │ │  │  │  web page      │   │  │
│  │           │  │  │                 │ │  │  │                │   │  │
│  │           │  │  │                 │ │  │  ├────────────────┤   │  │
│  │           │  │  │                 │ │  │  │  DevTools      │   │  │
│  │           │  │  ╰─────────────────╯ │  │  ╰────────────────╯   │  │
│  └───────────┘  └──────────────────────┘  └───────────────────────┘  │
│      ↑                    ↑                          ↑               │
│   no shadow          shadow + rounded           shadow + rounded     │
│   no padding         8pt inset all sides        8pt inset all sides  │
└──────────────────────────────────────────────────────────────────────┘
```

The implementation reuses `WorkspaceViewContainer`'s existing `terminalShadowHost` pattern — a new `browserShadowHost` NSView with identical layer configuration (shadow, corner radius, background color). The CEF browser view sits inside it with `masksToBounds = true` for corner clipping.

## Bridging Architecture

CEF exposes a C API. Swift can't call C++ directly. The bridge goes:

```
CEF Framework (C/C++)
       │
       v
CEFBridge.mm (Objective-C++)     ← ~500-800 lines
  - Wraps CefClient, CefBrowserHost, CefLifeSpanHandler, etc.
  - Exposes Obj-C classes: CEFBrowserView, CEFBridgeManager
       │
       v
Ghostties-Bridging-Header.h      ← Exposes ObjC classes to Swift
       │
       v
BrowserSessionView.swift (SwiftUI)
  - NSViewRepresentable wrapping CEFBrowserView
  - Navigation controls (URL bar, back/forward/refresh)
  - DevTools toggle
```

### Bridge API Surface (Estimated)

```objc
// CEFBridge.h — what Swift sees

@interface CEFBridgeManager : NSObject
+ (void)initializeWithMainArgs:(int)argc argv:(const char **)argv;
+ (void)shutdown;
+ (BOOL)isInitialized;
@end

@interface CEFBrowserView : NSView
- (instancetype)initWithURL:(NSString *)url;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (NSString *)currentURL;
- (NSString *)title;
- (BOOL)isLoading;
- (void)showDevTools;
- (void)closeDevTools;
- (int)remoteDebuggingPort;

// CDP access (Phase 4)
- (void)evaluateJavaScript:(NSString *)script
                completion:(void (^)(id result, NSError *error))completion;
- (void)sendCDPMessage:(NSString *)method
                params:(NSDictionary *)params
            completion:(void (^)(NSDictionary *result))completion;
@end

// Delegate for browser events
@protocol CEFBrowserViewDelegate <NSObject>
- (void)browserView:(CEFBrowserView *)view didChangeURL:(NSString *)url;
- (void)browserView:(CEFBrowserView *)view didChangeTitle:(NSString *)title;
- (void)browserView:(CEFBrowserView *)view didChangeLoadingState:(BOOL)isLoading;
- (void)browserView:(CEFBrowserView *)view didFailWithError:(NSError *)error;
@end
```

## CEF Lifecycle

### Initialization

CEF must be initialized exactly once per process. Lazy init on first browser session:

```
User creates first browser session
       │
       v
SessionCoordinator.createSession(template: .browser)
       │
       v
CEFBridgeManager.initialize() — called once, ~200-500ms
  - CefInitialize() with settings:
    - remote_debugging_port = 0 (auto-assign)
    - no_sandbox = true (macOS doesn't use CEF's Linux sandbox)
    - framework_dir_path = Ghostties.app/Contents/Frameworks/
                           Chromium Embedded Framework.framework
  - Starts CEF message loop integration
       │
       v
CEFBrowserView(url: "localhost:3000") — creates browser instance
       │
       v
Browser view inserted into session tree, displayed in main area
```

### Message Loop Integration

CEF needs to pump its message loop. On macOS, two options:
- **`CefDoMessageLoopWork()`** called from a timer on the main run loop (~16ms interval). Safe, predictable, but slightly laggy.
- **`multi_threaded_message_loop = true`** runs CEF's loop on a separate thread. Better performance but more complex threading.

For MVP: `CefDoMessageLoopWork()` on a display link timer. Good enough for a localhost preview. Optimize later if scrolling or video playback feels sluggish.

### Shutdown

```
App termination (NSApplicationWillTerminate)
       │
       v
Close all CEF browser views
       │
       v
CEFBridgeManager.shutdown()
       │
       v
CefShutdown() — releases Chromium resources
```

## Helper Processes

Chromium's multi-process architecture requires helper app bundles. These are required — not optional.

```
Ghostties.app/
  Contents/
    MacOS/
      Ghostties                          ← main app
    Frameworks/
      Chromium Embedded Framework.framework/  ← ~200MB
    Helpers/
      Ghostties Helper.app/              ← main helper
      Ghostties Helper (GPU).app/        ← GPU process
      Ghostties Helper (Renderer).app/   ← renderer process
      Ghostties Helper (Plugin).app/     ← plugin/PPAPI (optional)
```

### What Users See

Users will see these in Activity Monitor:
- `Ghostties Helper (GPU)` — one process, handles compositing
- `Ghostties Helper (Renderer)` — one per browser tab
- `Ghostties Helper` — utility process

This is normal Chromium behavior. Chrome, Slack, Figma all show the same pattern.

### Code Signing

All helper apps must be signed with the same team ID as the main app. The `Info.plist` for each helper sets `CFBundleIdentifier` to `com.ghostties.app.helper`, `.helper.gpu`, `.helper.renderer`. The build system needs to:
1. Copy helper bundles from CEF distribution
2. Rename them (CEF ships as "cefclient Helper" — need to rename to "Ghostties Helper")
3. Sign each with the same identity

## Resource Impact

| Metric | Current | With CEF | Delta |
|--------|---------|----------|-------|
| App bundle (uncompressed) | ~50MB | ~250MB | +200MB |
| DMG (compressed) | ~30MB | ~130MB | +100MB |
| Memory (no browser open) | baseline | baseline + ~5MB | CEF loaded but no browser process |
| Memory (one browser tab) | — | +50-100MB | Chromium renderer process |
| Memory (per additional tab) | — | +30-80MB | Shared GPU process, separate renderers |
| Launch time (no browser) | baseline | baseline | CEF is lazy-initialized |
| First browser open | — | +200-500ms | `CefInitialize()` one-time cost |
| Subsequent browser opens | — | +50-100ms | New renderer process startup |

The bundle size jump from ~30MB to ~130MB (DMG) is the main tradeoff. Ghostties already distributes directly (not App Store), so there's no size limit concern — but users notice download size.

## URL Management

Three modes, shipped across phases:

### Phase 1: Manual URL Bar
Text field at top of browser view. User types `localhost:3000`, hits Enter. Back/forward/refresh buttons.

### Phase 2: Auto-Detect from Terminal Output
Parse terminal output for common dev server patterns:

```
Patterns to match:
  "ready on http://localhost:3000"      → Next.js
  "Local:   http://localhost:5173/"     → Vite
  "Server running at http://127.0.0.1" → generic
  "listening on port 3000"              → Express
  "started server on 0.0.0.0:3000"     → Next.js (alt)
```

When detected, show a notification in the sidebar or a toast: "Dev server detected — open in browser?" Clicking creates a browser session with that URL.

### Phase 3: Agent-Initiated
Agents open URLs programmatically via a tool or sidebar action. The agent says "open localhost:3000 in the browser" and a browser session appears.

## DevTools Approach

### MVP (Phase 1-2): Separate Window

```swift
// One line in the bridge
browserView.showDevTools()

// CEF opens DevTools in a new native window
// Standard Chrome DevTools, fully functional
// No layout work needed — CEF handles the window
```

Pros: Zero layout effort. Full DevTools. Ships immediately.
Cons: Separate window breaks the "everything in Ghostties" story.

### Goal (Phase 3): Inline Panel

```
┌─────────────────────────────────────────┐
│  ← → ↻  localhost:3000                 │
│─────────────────────────────────────────│
│                                         │
│   [Web page content]                    │
│                                         │
│─────────────────────────────────────────│
│  Elements  Console  Network  Sources    │  ← DevTools panel
│─────────────────────────────────────────│
│  <div class="app">                      │
│    <header>...</header>                 │
│    <main id="root">                     │
│─────────────────────────────────────────│
```

Implementation: Start CEF with `remote_debugging_port` enabled. Create a second `CEFBrowserView` that loads `http://localhost:{port}/devtools/inspector.html?ws=...` — this is the DevTools frontend connecting to the page's debug target via WebSocket. The two CEF views stack vertically with a draggable divider.

This is how VS Code's Simple Browser + embedded DevTools works (same technique, different framework).

## Agent Integration (Phase 4 — Future)

This is the strategic payoff. With CEF's remote debugging port, agents get full CDP access:

### What Agents Can Do via CDP

- **Open URLs** — navigate the browser to any page
- **Read the DOM** — `DOM.getDocument`, `DOM.querySelector`
- **Read console output** — `Runtime.consoleAPICalled` events
- **Execute JavaScript** — `Runtime.evaluate`
- **Take screenshots** — `Page.captureScreenshot` (PNG/JPEG)
- **Network inspection** — `Network.requestWillBeSent`, `Network.responseReceived`
- **Performance profiling** — `Performance.getMetrics`
- **Accessibility tree** — `Accessibility.getFullAXTree`

### Example Workflows

**Design review loop:**
```
Agent makes CSS change → browser reloads → agent screenshots →
agent compares to design spec → suggests fixes → repeat
```

**Visual regression:**
```
Agent screenshots page before change → makes change →
screenshots after → diffs the two → reports visual changes
```

**Autonomous testing:**
```
Agent navigates to /login → fills form via CDP → clicks submit →
checks for error states → reports results in terminal
```

**Integration with external tools:**
- [Stagehand](https://github.com/browserbase/stagehand) — AI web automation via CDP
- Dial Kit / agitation.dev — design-to-code comparison tools
- Playwright — can connect to an existing CDP endpoint

### CDP Bridge to Agent Sessions

The browser's CDP port becomes available to terminal sessions in the same project. An agent running in a Claude Code session can connect to `localhost:{cdp_port}` and control the browser. The SessionCoordinator exposes the port via an environment variable:

```swift
// When creating a terminal session in a project with a browser session:
environment["GHOSTTIES_CDP_PORT"] = "\(browserSession.remoteDebuggingPort)"
```

Agents discover the browser via this env var and connect directly.

## Risks

### CEF Version Pinning
CEF tracks Chromium releases. Security vulnerabilities in Chromium mean we need to update CEF regularly. The update cadence is roughly monthly for stable channel. Ghostties would need a process for:
- Monitoring CEF releases
- Rebuilding/re-signing the framework
- Shipping updates to users

Mitigation: Pin to CEF stable channel. Subscribe to CEF's release announcements. Bundle updates alongside Ghostties updates.

### Metal Coexistence
Ghostty's terminal rendering uses Metal via the GPU. CEF's GPU process also uses Metal for compositing. Two Metal clients in the same app is supported by macOS but can cause resource contention on lower-end machines (Intel Macs, base M1).

Mitigation: CEF's GPU process is a separate process — it has its own Metal device and command queues. Resource contention is handled by macOS's GPU scheduler. Monitor for issues on Intel Macs.

### Code Signing Complexity
Four helper apps + the CEF framework all need signing. The current Ghostties build (Zig + Xcode) would need build script additions to:
1. Download the CEF binary distribution (~300MB)
2. Copy frameworks and helpers into the app bundle
3. Rename helpers from "cefclient" to "Ghostties"
4. Sign everything with the correct entitlements

Mitigation: Script this in a build phase. CEF's binary distribution includes a `cmake` example that handles this — adapt it.

### Not App Store Compatible
CEF uses private APIs and requires helper processes in ways that App Store review rejects. This is fine — Ghostties already distributes directly via DMG and has its own auto-update system (Sparkle).

### Bundle Size Perception
Going from ~30MB to ~130MB (DMG) is a 4x increase. Users notice.

Mitigation: The download is still fast on modern connections (~10s on 100Mbps). Could explore lazy CEF download on first browser use (download ~100MB framework on demand), but that adds complexity and a poor first-run experience.

## Implementation Phases

### Phase 1: Foundation (~2-3 weeks)
- Add CEF binary distribution to the project (vendored or downloaded at build time)
- Write `CEFBridge.mm` — initialize, create browser view, load URL, basic navigation
- Write `BrowserSessionView.swift` — NSViewRepresentable wrapping CEFBrowserView, URL bar, nav buttons
- Helper process setup — rename, sign, bundle
- `showDevTools()` in a separate window
- Manual URL entry only

**Exit criteria:** Can create a browser view, type a URL, see a rendered page, open DevTools in a separate window.

### Phase 2: Workspace Integration (~1-2 weeks)
- Add `Kind.browser` to AgentTemplate
- Browser sessions in the sidebar with status indicators (loading/idle/error)
- Session switching between terminal and browser via SessionCoordinator
- URL auto-detection from terminal output (pattern matching)
- "Open in browser" action when dev server URL detected

**Exit criteria:** Browser is a first-class sidebar session. Users can switch between terminal and browser with one click.

### Phase 3: Inline DevTools (~1-2 weeks)
- Remote debugging port configuration
- Second CEF view loading DevTools frontend
- Vertical split layout with draggable divider
- DevTools toggle button in browser chrome
- Panel persistence across session switches

**Exit criteria:** DevTools panel docked below the browser view, fully functional, togglable.

### Phase 4: Agent Integration (~2-3 weeks)
- CDP port exposed to terminal sessions via env var
- Agent tools for browser control (open URL, screenshot, read DOM)
- Console output forwarding to agent context
- Screenshot diffing for visual regression
- External tool integration (Stagehand, Playwright CDP connection)

**Exit criteria:** An agent in a terminal session can programmatically navigate the browser, take screenshots, and read page content.

## Browser Panel Toggle + Icon System

The browser panel is toggled via a **globe icon** in the terminal card's title bar (top-right), mirroring the sidebar toggle (top-left). Both icons follow a filled/outline system:

```
┌─ terminal card title bar ──────────────────────────────────────┐
│  ☐ sidebar toggle      Session Title           🌐 browser toggle │
│  (outline = closed)                            (outline = closed) │
│  (filled = open)                               (filled = open)    │
└────────────────────────────────────────────────────────────────┘
```

| State | Sidebar Icon | Browser Icon |
|-------|-------------|-------------|
| Panel closed | `sidebar.left` (outline) | `globe` (outline) |
| Panel open | `sidebar.left.fill` (filled) | `globe.fill` (filled) |

This forms a consistent **panel toggle system** — outline means closed, filled means open. The same pattern can extend to future panels.

**Keyboard shortcut:** `Cmd+B` for browser toggle (mirrors `Cmd+S` for sidebar toggle).

**Behavior:**
- Globe icon added to `terminalShadowHost` (same as sidebar toggle but trailing edge)
- Click toggles the browser panel open/closed with animation
- When browser panel opens: terminal card shrinks, browser card animates in from the right
- When browser panel closes: browser card animates out, terminal card expands

**Existing sidebar toggle should also adopt the filled/outline system:**
- Update `sidebarToggleButton` to use `sidebar.left.fill` when sidebar is in `.pinned` or `.overlay` mode
- Use `sidebar.left` (outline) when sidebar is in `.closed` mode

## Open Questions

1. **CEF distribution strategy** — vendor the CEF binary in the repo (~300MB in Git LFS) or download at build time? LFS is simpler for CI. Download keeps the repo small but adds a build dependency.

2. **Multiple browser sessions** — should a project support more than one browser session? Multiple tabs (localhost:3000 and localhost:3001) are plausible. Each one is a separate renderer process with additional memory cost.

3. **Browser session persistence** — should the URL survive app restart? Terminal sessions persist and relaunch their command. Browser sessions could persist their last URL and reload it.

4. **SwiftUI WebView coexistence** — should we ship SwiftUI WebView (macOS 26, zero cost) as a lightweight preview and CEF as the "power" browser? Or go all-in on CEF to avoid maintaining two browser implementations?

5. **CEF build configuration** — CEF ships as a ~1.5GB binary distribution with debug symbols. The release build framework is ~200MB. Do we build CEF from source (control over features, strip unused components) or use the official binary distribution (simpler, well-tested)?

6. **Zig build integration** — the current build system is Zig-based. CEF framework and helpers need to be copied into the app bundle during the build. This is straightforward with Zig's build system (`addInstallDirectory`) but needs testing.

7. **Minimum macOS version** — CEF drops support for older macOS versions faster than Ghostty does. Need to verify CEF's current minimum matches or exceeds Ghostties' deployment target.

8. **Tab bar vs. single session** — if we support multiple browser sessions, do they get their own tab bar within the browser view, or is each one a separate sidebar entry? Sidebar entries are simpler and consistent with the terminal model.

---

*Next: Decide on Phase 1 scope and run `/plan` when ready to implement.*
