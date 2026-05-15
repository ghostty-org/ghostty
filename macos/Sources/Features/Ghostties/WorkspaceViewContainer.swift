import AppKit
import Combine
import SwiftUI

/// An NSView that contains the workspace sidebar alongside the existing terminal view.
/// This replaces TerminalViewContainer as the window's contentView.
///
/// The sidebar is a SwiftUI view hierarchy (disclosure list) embedded in an
/// NSHostingView. The terminal side is the standard TerminalViewContainer, untouched.
/// Both are arranged via Auto Layout with an animated sidebar width constraint.
///
/// This container also creates and owns the `SessionCoordinator`, which bridges
/// the sidebar's SwiftUI world to the terminal controller's AppKit world.
///
/// ## Sidebar State Machine
///
/// The sidebar operates in three modes (see `SidebarMode`):
/// - **pinned**: Sidebar pushes terminal right (floating card with shadow/insets).
/// - **closed**: Sidebar hidden, terminal fills window flush, traffic lights hidden.
/// - **overlay**: Sidebar floats on top of full-width terminal (hover-to-reveal).
class WorkspaceViewContainer: NSView {
    private let backgroundEffectView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    private let sidebarHostingView: NSView
    /// Exposed for `BaseTerminalController.terminalViewContainer` to reach through.
    private(set) var terminalContainer: TerminalViewContainer
    private let coordinator: SessionCoordinator
    private let ghostty: Ghostty.App

    /// v0 task-first sidebar store. Loads `.ghostties/tasks/*.md` fixtures once.
    /// Instantiated lazily on first access (always on the main thread via AppKit
    /// view lifecycle) so the store survives view-mode toggling.
    private lazy var taskStore: TaskStore = TaskStore()

    /// Session-hybrid: tracks anonymous terminal sessions that haven't been
    /// promoted to tasks. Lives alongside `taskStore`; both feed the ACTIVE
    /// zone. Lazy so it only materializes for task-first mode.
    private lazy var sessionDraftStore: SessionDraftStore = SessionDraftStore()

    /// UserDefaults key for the v0 sidebar view mode feature toggle. Mirrors the
    /// `@AppStorage` key used in SwiftUI contexts so both layers observe the
    /// same value. Values: `"projectFirst"` (default) or `"taskFirst"`.
    private static let sidebarViewModeDefaultsKey = "ghostties.sidebarViewMode"

    /// Read the current sidebar view mode from UserDefaults. Defaults to
    /// project-first if the key is missing or holds an unknown value.
    private var currentSidebarViewMode: String {
        let raw = UserDefaults.standard.string(forKey: Self.sidebarViewModeDefaultsKey) ?? "projectFirst"
        return raw == "taskFirst" ? "taskFirst" : "projectFirst"
    }

    /// Resolved sidebar width for the current view mode.
    private var currentSidebarWidth: CGFloat {
        currentSidebarViewMode == "taskFirst"
            ? WorkspaceLayout.taskSidebarWidth
            : WorkspaceLayout.sidebarWidth
    }

    /// Shadow host wraps the terminal container so the drop shadow renders
    /// outside `masksToBounds` clipping. The shadow host carries the shadow;
    /// the inner terminal container clips its corners.
    private let terminalShadowHost: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// Shadow host for the browser panel — identical layer config to terminalShadowHost.
    private let browserShadowHost: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The browser panel content (navigation bar + content area placeholder).
    private let browserPanelView = BrowserPanelView()

    /// Sidebar material backing for overlay mode. In pinned mode the shared
    /// `backgroundEffectView` already covers the sidebar area, so this is hidden.
    /// In overlay mode it provides the .sidebar material behind the hosting view
    /// with a right-edge shadow to separate from terminal content.
    private let sidebarOverlayBackground: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alphaValue = 0
        view.isHidden = true
        return view
    }()

    /// Session name centered at the top of the terminal card (titlebar region).
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// Sidebar toggle button in the terminal card's titlebar region (top-left).
    /// Placed here (not in the sidebar) so it's accessible when the sidebar is closed.
    private lazy var sidebarToggleButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "Toggle Sidebar"
        )
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .medium
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggleSidebar)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("sidebarToggleButton")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }()

    /// Browser toggle button in the terminal card's titlebar region (top-right).
    /// Globe icon — tinted with accent color when browser is visible.
    private lazy var browserToggleButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: "Toggle Browser"
        )
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .medium
        )
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggleBrowser)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("browserToggleButton")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }()

    /// Weak reference to the window whose fullscreen observers are currently registered.
    private weak var fullScreenObservedWindow: NSWindow?

    private var cancellables = Set<AnyCancellable>()

    /// Cancellables scoped to the currently-observed focused surface. Cleared and
    /// repopulated every time the active session changes so we only listen to the
    /// one surface driving the chrome color.
    private var observedSurfaceCancellables = Set<AnyCancellable>()

    /// Weak reference to the surface whose theme is currently driving the card
    /// background. Held weakly so a torn-down surface doesn't pin memory; we
    /// also cancel our subscription whenever the active session changes.
    private weak var observedSurface: Ghostty.SurfaceView?

    /// Current sidebar state — always kept in sync with `WorkspaceStore.shared.sidebarMode`.
    private var sidebarMode: SidebarMode = .pinned

    /// Stored constraint for the sidebar toggle button's vertical position.
    /// Updated in layout() from the live close-button frame so the toolbar row
    /// survives macOS version bumps and upstream titlebar refactors.
    private var sidebarToggleCenterYConstraint: NSLayoutConstraint!

    /// Stored constraints for animating sidebar show/hide and terminal insets.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var shadowHostTopConstraint: NSLayoutConstraint!
    private var shadowHostTrailingConstraint: NSLayoutConstraint!
    private var shadowHostBottomConstraint: NSLayoutConstraint!

    /// Top offset of the terminal inside the shadow host, reserving space
    /// for the title bar in pinned mode.
    private var terminalTopConstraint: NSLayoutConstraint!

    /// Dual leading constraints — mutually exclusive.
    /// `.pinned`: terminal leading follows sidebar trailing (pushed right).
    /// `.closed`/`.overlay`: terminal leading follows superview leading (full-width).
    private var shadowHostLeadingToSidebar: NSLayoutConstraint!
    private var shadowHostLeadingToSuperview: NSLayoutConstraint!

    /// Whether the browser panel is currently visible (expanded).
    private var isBrowserVisible = false

    /// Fraction of the resizable width (terminal + browser) that the browser gets.
    /// Range 0.0–1.0; default comes from `WorkspaceLayout.browserSplitRatio`.
    /// Updated when the user drags the divider; used by `layout()` to keep
    /// the split proportional during window resizes.
    private var browserSplitRatio: CGFloat = WorkspaceLayout.browserSplitRatio

    /// Drag handle between terminal and browser cards for resizing.
    private lazy var browserDragHandle: BrowserDragHandleView = {
        let handle = BrowserDragHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.isHidden = true  // shown only when browser panel is visible
        handle.onDrag = { [weak self] delta in
            self?.handleBrowserDrag(delta: delta)
        }
        return handle
    }()

    /// Browser shadow host constraints for the 3-column layout.
    private var browserWidthConstraint: NSLayoutConstraint!
    private var browserShadowHostTopConstraint: NSLayoutConstraint!
    private var browserShadowHostBottomConstraint: NSLayoutConstraint!
    private var browserShadowHostTrailingConstraint: NSLayoutConstraint!
    /// Terminal trailing to browser leading (8pt gap when browser is visible).
    private var shadowHostTrailingToBrowser: NSLayoutConstraint!

    /// Tracking area for hover detection. Only one is active at a time.
    private var activeTrackingArea: NSTrackingArea?

    private var isLightAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    /// Canvas palette color for the current OS appearance. The canvas layer
    /// covers the terminal card background (internal header strip + card rim
    /// around the GPU-rendered terminal area). Owned by the Ghostties design
    /// system — intentionally independent of terminal theme.
    private var canvasPaletteNSColor: NSColor {
        isLightAppearance
            ? WorkspaceLayout.canvasBackgroundLight
            : WorkspaceLayout.canvasBackgroundDark
    }

    /// Chrome palette color for the current OS appearance. The chrome layer
    /// covers the left sidebar column and the gutter padding around the
    /// terminal card. Owned by the Ghostties design system — intentionally
    /// independent of terminal theme.
    private var chromePaletteNSColor: NSColor {
        isLightAppearance
            ? WorkspaceLayout.chromeBackgroundLight
            : WorkspaceLayout.chromeBackgroundDark
    }

    /// Terminal card background — the canvas layer. Always the Ghostties
    /// canvas palette; terminal theme is intentionally NOT bound here. The
    /// terminal content area inside the card is still painted by GhosttyKit
    /// (its theme system owns that rectangle).
    private var cardBackgroundCGColor: CGColor {
        canvasPaletteNSColor.cgColor
    }

    /// Browser card background — unified with the terminal card's canvas
    /// palette so the two card types read as the same design-system layer.
    private var browserCardBackgroundCGColor: CGColor {
        canvasPaletteNSColor.cgColor
    }

    /// Outer workspace canvas behind the sidebar and the gutter around the
    /// terminal card — the chrome layer. Always the Ghostties chrome palette;
    /// terminal theme is intentionally NOT bound here.
    private var canvasBackgroundCGColor: CGColor {
        chromePaletteNSColor.cgColor
    }

    init<ViewModel: TerminalViewModel>(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.ghostty = ghostty
        self.terminalContainer = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: viewModel, delegate: delegate)
        }

        self.coordinator = SessionCoordinator(ghostty: ghostty)

        #if DEBUG
        if let stress = ProcessInfo.processInfo.environment["GHOSTTIES_STRESS_SESSIONS"],
           let n = Int(stress), n > 0 {
            coordinator.injectStressLoad(count: n)
        }
        #endif

        // Start with a placeholder root; `applySidebarView()` will install the
        // correct view (project-first vs task-first) during setup. We use
        // AnyView so the hosting view's generic type is fixed across the
        // feature-toggle swap.
        let hostingView = TransparentHostingView(rootView: AnyView(EmptyView()))
        // Auto Layout controls the sidebar width; disable intrinsic size reporting
        // to avoid unnecessary layout computation from the hosting view.
        hostingView.sizingOptions = []
        self.sidebarHostingView = hostingView

        super.init(frame: .zero)

        // Session-hybrid: give the coordinator a weak handle to the draft store
        // so spawn/close events can register + GC draft rows in the sidebar.
        // Touching the lazy here materializes the store before the first spawn
        // — the coordinator's weak reference takes it from there.
        self.coordinator.sessionDraftStore = self.sessionDraftStore

        setup()
        applySidebarView()

        // Observe view-mode toggle so the container swaps sidebars without
        // requiring a window rebuild.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sidebarViewModeChanged),
            name: .workspaceSidebarViewModeChanged,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Clean up previous window's observers (handles view moving between windows).
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: fullScreenObservedWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: fullScreenObservedWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: fullScreenObservedWindow)

        guard let window = window else { return }
        // Give the coordinator a reference to this view so it can discover
        // the window controller through the responder chain.
        coordinator.containerView = self

        // The workspace sidebar replaces the native tab bar — sessions are the new "tabs".
        // Disallow native tabbing to prevent a visual conflict (tab bar + sidebar).
        window.tabbingMode = .disallowed

        // Extend content under titlebar — traffic lights appear inside the sidebar panel.
        window.styleMask.insert(.fullSizeContentView)

        // Apply initial traffic light visibility.
        setTrafficLightsHidden(sidebarMode == .closed)

        // Auto-dismiss overlay when window loses focus + release the sidebar's
        // freeze snapshot so the next focus shows fresh section bucketing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        // Freeze the sidebar's section layout while the window is active so the
        // user's currently-focused project doesn't shift under bursty agent output.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        // Re-measure toolbar row when fullscreen transitions change the titlebar geometry.
        // willEnter fires before AppKit takes a snapshot for the animation, preventing
        // a single-frame glitch during the enter-fullscreen transition.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterOrExitFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterOrExitFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterOrExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        fullScreenObservedWindow = window

        // If the window is already key when we move into it, freeze immediately.
        if window.isKeyWindow {
            WorkspaceStore.shared.freezeSnapshot()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard sidebarMode == .pinned || sidebarMode == .closed else { return }
        // Canvas still follows OS light/dark — it's Ghostties chrome, not
        // terminal content.
        layer?.backgroundColor = canvasBackgroundCGColor
        // Terminal card follows the focused surface's theme when available;
        // the resolver handles the light/dark fallback itself.
        terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
        // Browser card has no theme concept — always the light/dark fallback.
        browserShadowHost.layer?.backgroundColor = browserCardBackgroundCGColor
    }

    /// Zero out safe area insets so Auto Layout constraints measure from
    /// the actual window edge, not the titlebar-offset safe area.
    /// Without this, `topAnchor` is shifted down by ~28pt (titlebar height)
    /// and our `terminalTopInset` constant has no visible effect.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var intrinsicContentSize: NSSize {
        let termSize = terminalContainer.intrinsicContentSize
        guard termSize.width != NSView.noIntrinsicMetric else { return termSize }
        switch sidebarMode {
        case .pinned:
            let inset = WorkspaceLayout.terminalInset
            return NSSize(
                width: termSize.width + currentSidebarWidth + inset * 2,
                height: termSize.height + inset * 2
            )
        case .closed:
            let inset = WorkspaceLayout.terminalInset
            return NSSize(
                width: termSize.width + inset * 2,
                height: termSize.height + inset * 2
            )
        case .overlay:
            return termSize
        }
    }

    /// Total horizontal space available to the terminal + browser combined.
    /// Subtracts sidebar (when pinned) and the three inset gaps (leading, gap, trailing).
    private var resizableWidth: CGFloat {
        let sidebarWidth = sidebarMode == .pinned ? currentSidebarWidth : 0
        let inset = WorkspaceLayout.terminalInset
        // Three inset slots: leading of terminal, gap between panels, trailing of browser.
        return bounds.width - sidebarWidth - inset * 3
    }

    override func layout() {
        super.layout()

        // Keep the terminal/browser split proportional when the window resizes.
        if isBrowserVisible {
            let available = resizableWidth
            let maxBrowser = available - WorkspaceLayout.terminalMinWidth
            let desired = available * browserSplitRatio
            let clamped = min(max(desired, WorkspaceLayout.browserMinWidth), max(maxBrowser, WorkspaceLayout.browserMinWidth))
            browserWidthConstraint.constant = clamped
        }

        // Explicit shadow paths eliminate per-frame offscreen rendering.
        // Without these, Core Animation rasterizes the entire layer to compute
        // the shadow shape every frame — expensive for a terminal that redraws at 60fps.
        terminalShadowHost.layer?.shadowPath = CGPath(
            roundedRect: terminalShadowHost.bounds,
            cornerWidth: WorkspaceLayout.terminalCornerRadius,
            cornerHeight: WorkspaceLayout.terminalCornerRadius,
            transform: nil
        )
        browserShadowHost.layer?.shadowPath = CGPath(
            roundedRect: browserShadowHost.bounds,
            cornerWidth: WorkspaceLayout.terminalCornerRadius,
            cornerHeight: WorkspaceLayout.terminalCornerRadius,
            transform: nil
        )
        sidebarOverlayBackground.layer?.shadowPath = CGPath(
            rect: sidebarOverlayBackground.bounds,
            transform: nil
        )

        // Re-derive toolbar row position from live close-button frame.
        // This survives macOS version bumps and upstream titlebar refactors.
        if let constant = WorkspaceLayout.titlebarRowTopAnchorConstant(in: self) {
            if abs(sidebarToggleCenterYConstraint.constant - constant) > 0.5 {
                sidebarToggleCenterYConstraint.constant = constant
            }
            // Publish to SwiftUI sidebar so the + button stays in sync.
            if abs(WorkspaceStore.shared.toolbarRowTopAnchorConstant - constant) > 0.5 {
                WorkspaceStore.shared.toolbarRowTopAnchorConstant = constant
            }
        }

    }

    // MARK: - Sidebar View Mode (v0 feature toggle)

    /// Build the correct sidebar SwiftUI view for the current view mode and
    /// install it on the hosting view. Called once during setup and again each
    /// time the view-mode toggle fires a `workspaceSidebarViewModeChanged`
    /// notification. Both branches share the same titlebar spacer so the
    /// traffic-light region stays consistent across modes.
    private func applySidebarView() {
        guard let hostingView = sidebarHostingView as? NSHostingView<AnyView> else { return }

        let mode = currentSidebarViewMode
        if mode == "taskFirst" {
            let view = VStack(spacing: 0) {
                // Reserve space for the window's traffic lights so the NEEDS YOU
                // header doesn't render behind them.
                Color.clear.frame(height: WorkspaceLayout.titlebarSpacerHeight)
                TaskSidebarView(
                    taskStore: taskStore,
                    sessionDraftStore: sessionDraftStore
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Pin the outer VStack to a concrete width so the nested LazyStacks
            // inside the three zones receive a definite cross-axis proposal.
            // Without this the hosting view proposed .infinity, which sent
            // LazyVStack.sizeThatFits into an infinite measurement recursion
            // (see fix/sidebar-layout-hang-v0).
            .frame(width: WorkspaceLayout.taskSidebarWidth)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            // Row clicks in TaskRowView reach back into the terminal via the
            // coordinator and look up a matching project via WorkspaceStore.
            // The store is observed so the row sees a current projects list.
            .environmentObject(taskStore)
            .environmentObject(coordinator)
            .environmentObject(WorkspaceStore.shared)
            .environmentObject(sessionDraftStore)
            hostingView.rootView = AnyView(view)
        } else {
            let view = WorkspaceSidebarView()
                .environmentObject(WorkspaceStore.shared)
                .environmentObject(coordinator)
                .ignoresSafeArea(.container, edges: .top)
            hostingView.rootView = AnyView(view)
        }
    }

    @objc private func sidebarViewModeChanged() {
        applySidebarView()

        // Update width constraint + intrinsic size to reflect the new mode's
        // sidebar width. Only animate when the sidebar is actually pinned; in
        // closed mode the width is 0, in overlay mode the constraint follows
        // the overlay width which is also driven by currentSidebarWidth.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            switch sidebarMode {
            case .pinned, .overlay:
                sidebarWidthConstraint.animator().constant = currentSidebarWidth
            case .closed:
                break
            }
        }
        updateTrackingAreas()
        invalidateIntrinsicContentSize()
    }

    // MARK: - Traffic Lights

    private func setTrafficLightsHidden(_ hidden: Bool) {
        guard let window = window else { return }
        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = hidden
        }
    }

    // MARK: - Sidebar State Machine

    /// Toggle sidebar via keyboard shortcut (Cmd+Shift+E).
    @objc func toggleSidebar() {
        switch sidebarMode {
        case .pinned:  transitionTo(.closed)
        case .closed:  transitionTo(.pinned)
        case .overlay: transitionTo(.pinned)  // promote overlay to pinned
        }
    }

    // MARK: - Browser Toggle

    /// Toggle browser panel visibility via keyboard shortcut (Cmd+B) or globe button.
    /// Shows the browser as a side panel next to the terminal (Dia Browser style).
    /// If no browser session exists yet, creates one via the coordinator.
    @objc func toggleBrowser() {
        if isBrowserVisible {
            // Collapse the side panel.
            animateBrowserPanel(visible: false)
        } else {
            // Ensure we have a browser session with a CEFBrowserView.
            // Check for an existing live browser session first.
            let existingManager: BrowserTabManager? = coordinator.browserManagers.values.first { manager in
                coordinator.browserManagers.contains { (id, m) in
                    m === manager && coordinator.statuses[id]?.isAlive == true
                }
            }

            if let manager = existingManager {
                embedBrowserInPanel(manager)
                animateBrowserPanel(visible: true)
            } else if let project = WorkspaceStore.shared.projects.first {
                // Create a new browser session — this will call showBrowserContent,
                // which embeds into the side panel and animates it open.
                Task { @MainActor in
                    await coordinator.createQuickSession(for: project, template: .browser)
                }
            }
        }
    }

    /// Animate the browser side panel open or closed.
    private func animateBrowserPanel(visible: Bool) {
        isBrowserVisible = visible

        // Swap trailing constraints: terminal trails to browser or to window edge.
        if visible {
            shadowHostTrailingConstraint.isActive = false
            shadowHostTrailingToBrowser.isActive = true
        } else {
            shadowHostTrailingToBrowser.isActive = false
            shadowHostTrailingConstraint.isActive = true
        }

        // Show/hide the drag handle with the browser panel.
        browserDragHandle.isHidden = !visible

        // Update globe button tint: accent color when open, secondary when closed.
        browserToggleButton.contentTintColor = visible
            ? WorkspaceLayout.waitingTerracottaNS
            : .secondaryLabelColor

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            if visible {
                // Expand browser using the stored split ratio.
                let available = resizableWidth
                let maxBrowser = available - WorkspaceLayout.terminalMinWidth
                let desired = available * browserSplitRatio
                let browserWidth = min(max(desired, WorkspaceLayout.browserMinWidth), max(maxBrowser, WorkspaceLayout.browserMinWidth))
                browserWidthConstraint.animator().constant = browserWidth
                browserShadowHost.animator().alphaValue = 1
            } else {
                // Collapse browser.
                browserWidthConstraint.animator().constant = 0
                browserShadowHost.animator().alphaValue = 0
            }
        }

        // Shadow + corner radius (non-animatable).
        browserShadowHost.layer?.shadowOpacity = visible ? WorkspaceLayout.canvasShadowOpacity : 0

        invalidateIntrinsicContentSize()
    }

    /// Handle a horizontal drag delta from the browser drag handle.
    /// Negative delta = dragging left (browser grows), positive = dragging right (browser shrinks).
    private func handleBrowserDrag(delta: CGFloat) {
        // Available space for terminal + browser combined.
        let totalResizable = resizableWidth

        // Current browser width and proposed new width.
        let currentBrowserWidth = browserWidthConstraint.constant
        // Dragging left (negative delta) grows the browser.
        let proposedBrowserWidth = currentBrowserWidth - delta

        // Minimum terminal width — ensure terminal never gets too narrow.
        // Clamp: browser must be >= browserMinWidth and terminal must be >= terminalMinWidth.
        let maxBrowserWidth = totalResizable - WorkspaceLayout.terminalMinWidth
        let clampedWidth = min(max(proposedBrowserWidth, WorkspaceLayout.browserMinWidth), max(maxBrowserWidth, WorkspaceLayout.browserMinWidth))

        browserWidthConstraint.constant = clampedWidth

        // Persist the ratio so the split scales proportionally on window resize.
        if totalResizable > 0 {
            browserSplitRatio = clampedWidth / totalResizable
        }
    }

    /// Embed a browser manager's active tab view into `browserPanelView.contentArea`.
    private func embedBrowserInPanel(_ manager: BrowserTabManager) {
        // Remove any existing content from the panel's content area.
        for subview in browserPanelView.contentArea.subviews {
            subview.removeFromSuperview()
        }

        // Wire the navigation bar actions.
        let navBar = browserPanelView.navigationBar
        navBar.backButton.target = self
        navBar.backButton.action = #selector(browserGoBack)
        navBar.forwardButton.target = self
        navBar.forwardButton.action = #selector(browserGoForward)
        navBar.reloadButton.target = self
        navBar.reloadButton.action = #selector(browserReload)
        navBar.devToolsButton.target = self
        navBar.devToolsButton.action = #selector(browserToggleDevTools)
        navBar.urlField.delegate = self

        // Wire the tab bar to this manager.
        browserPanelView.tabBar.tabManager = manager

        // Wire the bridge to this navigation bar.
        let bridge = coordinator.bridge(for: manager)
        bridge?.navigationBar = navBar

        // Embed the active tab's browser view.
        if let activeTabId = manager.activeTabId,
           let browserView = manager.browserViews[activeTabId] {
            browserView.translatesAutoresizingMaskIntoConstraints = false
            browserPanelView.contentArea.addSubview(browserView)
            NSLayoutConstraint.activate([
                browserView.topAnchor.constraint(equalTo: browserPanelView.contentArea.topAnchor),
                browserView.leadingAnchor.constraint(equalTo: browserPanelView.contentArea.leadingAnchor),
                browserView.trailingAnchor.constraint(equalTo: browserPanelView.contentArea.trailingAnchor),
                browserView.bottomAnchor.constraint(equalTo: browserPanelView.contentArea.bottomAnchor),
            ])
            // Force layout so CEFBrowserView gets its real size, then tell CEF to resize.
            browserPanelView.contentArea.layoutSubtreeIfNeeded()
            if let cefView = browserView as? CEFBrowserView {
                cefView.setFrameSize(browserPanelView.contentArea.bounds.size)
            }
        }

        _activeBrowserManager = manager
    }

    // MARK: - Browser Session Content

    /// Show a browser session's content in the side panel (terminal stays visible).
    /// Called by SessionCoordinator when switching to or creating a browser session.
    func showBrowserContent(_ manager: BrowserTabManager, bridge: BrowserSessionBridge?) {
        embedBrowserInPanel(manager)

        // Wire the bridge if provided (overrides the one found in embedBrowserInPanel).
        if let bridge = bridge {
            bridge.navigationBar = browserPanelView.navigationBar
        }

        // Open the side panel if it isn't already visible.
        if !isBrowserVisible {
            animateBrowserPanel(visible: true)
        }
    }

    /// Restore terminal-only display (collapse browser side panel).
    /// Called by SessionCoordinator when switching from a browser session to a terminal session.
    func showTerminalContent() {
        // Terminal is always visible in side-by-side mode, so nothing to un-hide.
        // Collapse the browser panel if it's open.
        if isBrowserVisible {
            animateBrowserPanel(visible: false)
        }
        _activeBrowserManager = nil
    }

    /// Weak reference to the active browser manager for navigation actions.
    private weak var _activeBrowserManager: BrowserTabManager?

    /// The CEFBrowserView for the active tab, if any.
    private var activeCEFView: CEFBrowserView? {
        guard let tabId = _activeBrowserManager?.activeTabId else { return nil }
        return _activeBrowserManager?.browserViews[tabId] as? CEFBrowserView
    }

    @objc private func browserGoBack() {
        guard let view = activeCEFView else { return }
        view.goBack()
    }

    @objc private func browserGoForward() {
        guard let view = activeCEFView else { return }
        view.goForward()
    }

    @objc private func browserReload() {
        guard let view = activeCEFView else { return }
        if view.isLoading {
            view.stopLoading()
        } else {
            view.reload()
        }
    }

    @objc private func browserToggleDevTools() {
        guard let view = activeCEFView else { return }

        if browserPanelView.isDevToolsVisible {
            // Close inline DevTools and collapse the panel area.
            view.closeDevTools()
            browserPanelView.hideDevTools()
        } else {
            // Expand the inline DevTools area, then tell CEF to render into it.
            browserPanelView.showDevTools()
            view.showInlineDevTools(browserPanelView.devToolsArea)
        }
    }

    /// Minimum interval between transitions to prevent rapid oscillation
    /// (e.g. mouse hovering at the overlay/closed boundary).
    private var lastTransitionTime: CFTimeInterval = 0

    /// Centralized state transition. All sidebar mode changes go through here.
    private func transitionTo(_ newMode: SidebarMode) {
        guard newMode != sidebarMode else { return }
        let now = CACurrentMediaTime()
        guard now - lastTransitionTime > 0.25 else { return }
        lastTransitionTime = now
        sidebarMode = newMode

        let inset = WorkspaceLayout.terminalInset

        // 1. Swap leading constraints before animation.
        switch newMode {
        case .pinned:
            shadowHostLeadingToSuperview.isActive = false
            shadowHostLeadingToSidebar.isActive = true
        case .closed, .overlay:
            shadowHostLeadingToSidebar.isActive = false
            shadowHostLeadingToSuperview.isActive = true
        }

        // 2. Z-ordering for overlay mode.
        let overlayZ: CGFloat = newMode == .overlay ? 100 : 0
        sidebarHostingView.layer?.zPosition = overlayZ
        sidebarOverlayBackground.layer?.zPosition = newMode == .overlay ? 99 : 0

        // 3. Toggle isHidden so inactive NSVisualEffectViews leave the compositing tree.
        //    The background material is only visible in overlay mode (floating hover state).
        //    In pinned mode the sidebar is transparent — the window background shows through.
        switch newMode {
        case .pinned:
            backgroundEffectView.isHidden = true
            sidebarOverlayBackground.isHidden = true
        case .closed:
            backgroundEffectView.isHidden = true
            sidebarOverlayBackground.isHidden = true
        case .overlay:
            backgroundEffectView.isHidden = false
            sidebarOverlayBackground.isHidden = false
        }

        // 4. Animate constraints, widths, alphas.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            switch newMode {
            case .pinned:
                sidebarWidthConstraint.animator().constant = currentSidebarWidth
                sidebarHostingView.animator().alphaValue = 1
                shadowHostTopConstraint.animator().constant = inset
                shadowHostLeadingToSidebar.animator().constant = inset
                if !isBrowserVisible {
                    shadowHostTrailingConstraint.animator().constant = -inset
                }
                shadowHostBottomConstraint.animator().constant = -inset
                terminalTopConstraint.animator().constant = WorkspaceLayout.terminalTitleBarHeight
                titleLabel.animator().alphaValue = 1
                sidebarToggleButton.animator().alphaValue = 1
                browserToggleButton.animator().alphaValue = 1
                sidebarOverlayBackground.animator().alphaValue = 0
                // Browser insets match terminal.
                browserShadowHostTopConstraint.animator().constant = inset
                browserShadowHostBottomConstraint.animator().constant = -inset
                browserShadowHostTrailingConstraint.animator().constant = -inset

            case .closed:
                sidebarWidthConstraint.animator().constant = 0
                sidebarHostingView.animator().alphaValue = 0
                shadowHostTopConstraint.animator().constant = inset
                shadowHostLeadingToSuperview.animator().constant = inset
                if !isBrowserVisible {
                    shadowHostTrailingConstraint.animator().constant = -inset
                }
                shadowHostBottomConstraint.animator().constant = -inset
                terminalTopConstraint.animator().constant = WorkspaceLayout.terminalTitleBarHeight
                titleLabel.animator().alphaValue = 1
                sidebarToggleButton.animator().alphaValue = 1
                browserToggleButton.animator().alphaValue = 1
                sidebarOverlayBackground.animator().alphaValue = 0
                // Browser insets match terminal.
                browserShadowHostTopConstraint.animator().constant = inset
                browserShadowHostBottomConstraint.animator().constant = -inset
                browserShadowHostTrailingConstraint.animator().constant = -inset

            case .overlay:
                // If browser was visible, swap trailing constraint back to window edge.
                if isBrowserVisible {
                    shadowHostTrailingToBrowser.isActive = false
                    shadowHostTrailingConstraint.isActive = true
                    isBrowserVisible = false
                    browserToggleButton.contentTintColor = .secondaryLabelColor
                    browserDragHandle.isHidden = true
                }
                sidebarWidthConstraint.animator().constant = currentSidebarWidth
                sidebarHostingView.animator().alphaValue = 1
                // Terminal stays full-width (leading to superview, no insets).
                shadowHostTopConstraint.animator().constant = 0
                shadowHostLeadingToSuperview.animator().constant = 0
                shadowHostTrailingConstraint.animator().constant = 0
                shadowHostBottomConstraint.animator().constant = 0
                terminalTopConstraint.animator().constant = 0
                titleLabel.animator().alphaValue = 0
                sidebarToggleButton.animator().alphaValue = 0
                browserToggleButton.animator().alphaValue = 0
                sidebarOverlayBackground.animator().alphaValue = 1
                // Collapse browser in overlay mode.
                browserWidthConstraint.animator().constant = 0
                browserShadowHost.animator().alphaValue = 0
                browserShadowHostTopConstraint.animator().constant = 0
                browserShadowHostBottomConstraint.animator().constant = 0
                browserShadowHostTrailingConstraint.animator().constant = 0
            }
        }

        // 5. Non-animatable properties.
        switch newMode {
        case .pinned:
            terminalContainer.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            terminalShadowHost.layer?.shadowOpacity = WorkspaceLayout.canvasShadowOpacity
            terminalShadowHost.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
            browserShadowHost.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            browserShadowHost.layer?.backgroundColor = browserCardBackgroundCGColor
            browserShadowHost.layer?.shadowOpacity = isBrowserVisible ? WorkspaceLayout.canvasShadowOpacity : 0
            layer?.backgroundColor = canvasBackgroundCGColor
            sidebarOverlayBackground.layer?.shadowOpacity = 0
        case .closed:
            terminalContainer.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            terminalShadowHost.layer?.shadowOpacity = WorkspaceLayout.canvasShadowOpacity
            terminalShadowHost.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
            browserShadowHost.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            browserShadowHost.layer?.backgroundColor = browserCardBackgroundCGColor
            browserShadowHost.layer?.shadowOpacity = isBrowserVisible ? WorkspaceLayout.canvasShadowOpacity : 0
            layer?.backgroundColor = canvasBackgroundCGColor
            sidebarOverlayBackground.layer?.shadowOpacity = 0
        case .overlay:
            terminalContainer.layer?.cornerRadius = 0
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            terminalShadowHost.layer?.shadowOpacity = 0
            terminalShadowHost.layer?.cornerRadius = 0
            terminalShadowHost.layer?.backgroundColor = nil
            browserShadowHost.layer?.cornerRadius = 0
            browserShadowHost.layer?.backgroundColor = nil
            browserShadowHost.layer?.shadowOpacity = 0
            layer?.backgroundColor = nil
            sidebarOverlayBackground.layer?.shadowOpacity = 0.2
        }

        // 6. Traffic lights.
        setTrafficLightsHidden(newMode == .closed)

        // 7. Refresh tracking areas.
        updateTrackingAreas()

        // 8. Persist (overlay is transient — store persists it as .closed).
        WorkspaceStore.shared.updateSidebarMode(newMode)

        invalidateIntrinsicContentSize()
    }

    // MARK: - Hover Tracking

    override func updateTrackingAreas() {
        // Remove existing tracking area.
        if let area = activeTrackingArea {
            removeTrackingArea(area)
            activeTrackingArea = nil
        }

        super.updateTrackingAreas()

        switch sidebarMode {
        case .closed:
            // Install trigger zone: thin strip at left edge.
            let triggerRect = CGRect(
                x: 0, y: 0,
                width: WorkspaceLayout.overlayTriggerWidth,
                height: bounds.height
            )
            let area = NSTrackingArea(
                rect: triggerRect,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            activeTrackingArea = area

        case .overlay:
            // Install sidebar zone: covers sidebar width.
            let sidebarRect = CGRect(
                x: 0, y: 0,
                width: currentSidebarWidth,
                height: bounds.height
            )
            let area = NSTrackingArea(
                rect: sidebarRect,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            activeTrackingArea = area

        case .pinned:
            // No tracking areas needed.
            break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if sidebarMode == .closed {
            transitionTo(.overlay)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if sidebarMode == .overlay {
            transitionTo(.closed)
        }
    }

    // MARK: - Window Focus

    @objc private func windowDidResignKey() {
        if sidebarMode == .overlay {
            transitionTo(.closed)
        }
        // Sidebar smart-sections freeze-on-focus (plan unit 4):
        // window blur is treated as the primary release trigger. The next time
        // the window becomes key we'll re-freeze with the (potentially changed)
        // layout, and SwiftUI animates the diff via `sectionSignature`.
        //
        // Implementation note: we're using window-level key-state via
        // `NSWindowDelegate`-style notifications rather than SwiftUI's
        // `.focused()` because the sidebar is hosted in an `NSHostingView`
        // (not an `NSHostingController`), and its rows aren't text-input
        // focusable — `.focused()` doesn't fire reliably for tap-target rows
        // in a hosting view. The window-key signal is coarser but bulletproof:
        // any time the user is interacting with this window, the sidebar's
        // bucketing is frozen.
        WorkspaceStore.shared.releaseSnapshot()
    }

    @objc private func windowDidBecomeKey() {
        // Sidebar smart-sections freeze-on-focus (plan unit 4):
        // freeze the section layout while this window is the user's focus.
        // No-op if already frozen — `freezeSnapshot()` guards against clobber.
        WorkspaceStore.shared.freezeSnapshot()
    }

    @objc private func windowDidEnterOrExitFullScreen() {
        // Fullscreen transitions reposition the traffic lights. Trigger a layout
        // pass so titlebarRowTopAnchorConstant re-reads the new close-button frame.
        needsLayout = true
    }

    // MARK: - Layout

    private func setup() {
        // Canvas layer — the warm background visible behind the floating card.
        wantsLayer = true

        // Z-order: background material → overlay background → sidebar → terminal → drag handle → browser.
        addSubview(backgroundEffectView)
        addSubview(sidebarOverlayBackground)
        addSubview(sidebarHostingView)
        addSubview(terminalShadowHost)
        addSubview(browserDragHandle)
        addSubview(browserShadowHost)

        sidebarHostingView.translatesAutoresizingMaskIntoConstraints = false

        // Enable layers for z-ordering in overlay mode.
        sidebarHostingView.wantsLayer = true
        sidebarOverlayBackground.wantsLayer = true
        sidebarOverlayBackground.layer?.shadowColor = NSColor.black.cgColor
        sidebarOverlayBackground.layer?.shadowRadius = 6
        sidebarOverlayBackground.layer?.shadowOffset = CGSize(width: 2, height: 0)

        // Terminal lives inside the shadow host. The host carries the shadow;
        // the terminal clips its own corners via masksToBounds.
        terminalShadowHost.addSubview(terminalContainer)
        terminalShadowHost.addSubview(titleLabel)
        terminalShadowHost.addSubview(sidebarToggleButton)
        terminalShadowHost.addSubview(browserToggleButton)
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        // Browser panel lives inside browser shadow host.
        browserPanelView.translatesAutoresizingMaskIntoConstraints = false
        browserShadowHost.addSubview(browserPanelView)

        // Read persisted sidebar mode.
        let initialMode = WorkspaceStore.shared.sidebarMode
        self.sidebarMode = initialMode
        let isPinned = initialMode == .pinned
        // Both pinned and closed modes show the floating card with insets.
        let hasCardInset = initialMode != .overlay
        let initialWidth: CGFloat = isPinned ? currentSidebarWidth : 0

        sidebarWidthConstraint = sidebarHostingView.widthAnchor.constraint(equalToConstant: initialWidth)

        let inset: CGFloat = hasCardInset ? WorkspaceLayout.terminalInset : 0
        // Inset constraints target the shadow host, not the terminal directly.
        shadowHostTopConstraint = terminalShadowHost.topAnchor.constraint(
            equalTo: topAnchor, constant: inset)
        // Terminal trailing to window edge (active when browser is hidden).
        shadowHostTrailingConstraint = terminalShadowHost.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: hasCardInset ? -inset : 0)
        shadowHostBottomConstraint = terminalShadowHost.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: hasCardInset ? -inset : 0)

        // Terminal trailing to browser leading (active when browser is visible).
        shadowHostTrailingToBrowser = terminalShadowHost.trailingAnchor.constraint(
            equalTo: browserShadowHost.leadingAnchor, constant: -inset)
        shadowHostTrailingToBrowser.isActive = false

        // Browser shadow host constraints — starts hidden (width 0, alpha 0).
        browserWidthConstraint = browserShadowHost.widthAnchor.constraint(equalToConstant: 0)
        browserShadowHostTopConstraint = browserShadowHost.topAnchor.constraint(
            equalTo: topAnchor, constant: inset)
        browserShadowHostBottomConstraint = browserShadowHost.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: hasCardInset ? -inset : 0)
        browserShadowHostTrailingConstraint = browserShadowHost.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: hasCardInset ? -inset : 0)

        // Dual leading constraints (mutually exclusive).
        shadowHostLeadingToSidebar = terminalShadowHost.leadingAnchor.constraint(
            equalTo: sidebarHostingView.trailingAnchor, constant: inset)
        shadowHostLeadingToSuperview = terminalShadowHost.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: hasCardInset ? inset : 0)
        shadowHostLeadingToSidebar.isActive = isPinned
        shadowHostLeadingToSuperview.isActive = !isPinned

        // Terminal top offset inside the shadow host — reserves title bar space
        // when pinned or closed (card modes show title + toggle button).
        let titlebarInset: CGFloat = hasCardInset ? WorkspaceLayout.terminalTitleBarHeight : 0
        terminalTopConstraint = terminalContainer.topAnchor.constraint(
            equalTo: terminalShadowHost.topAnchor, constant: titlebarInset)

        // 22 is the initial guess before the window appears (breathingRoomBelowChrome is now 0);
        // updated each layout() pass from the live close-button frame.
        sidebarToggleCenterYConstraint = sidebarToggleButton.centerYAnchor
            .constraint(equalTo: topAnchor, constant: 22)

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Overlay background tracks sidebar width via trailing edge.
            sidebarOverlayBackground.topAnchor.constraint(equalTo: topAnchor),
            sidebarOverlayBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarOverlayBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarOverlayBackground.trailingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),

            sidebarHostingView.topAnchor.constraint(equalTo: topAnchor),
            sidebarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarWidthConstraint,

            shadowHostTopConstraint,
            shadowHostBottomConstraint,
            shadowHostTrailingConstraint,

            // Terminal fills the shadow host (top offset reserves title bar space).
            terminalTopConstraint,
            terminalContainer.leadingAnchor.constraint(equalTo: terminalShadowHost.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: terminalShadowHost.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: terminalShadowHost.bottomAnchor),

            // Sidebar toggle button — anchored to window top, not the terminal card.
            // The terminal card (terminalShadowHost) sits ~387pt below the window top in the
            // full layout, so terminalShadowHost.topAnchor is the wrong reference. Anchor
            // directly to self.topAnchor + constant so the toggle sits on the same horizontal
            // row as the traffic lights. The constant is updated from the live close-button
            // frame in layout() — 22 is just the initial guess before the window appears.
            sidebarToggleButton.leadingAnchor.constraint(
                equalTo: terminalShadowHost.leadingAnchor, constant: 8),
            sidebarToggleCenterYConstraint,

            // Browser toggle button at top-right of the terminal card titlebar.
            browserToggleButton.trailingAnchor.constraint(
                equalTo: terminalShadowHost.trailingAnchor, constant: -8),
            browserToggleButton.centerYAnchor.constraint(
                equalTo: sidebarToggleButton.centerYAnchor),

            // Title label centered in the titlebar region, vertically aligned
            // with the sidebar toggle button.
            titleLabel.centerXAnchor.constraint(equalTo: terminalShadowHost.centerXAnchor),
            titleLabel.centerYAnchor.constraint(
                equalTo: sidebarToggleButton.centerYAnchor),

            // Browser shadow host — positioned to the right of the terminal.
            browserShadowHostTopConstraint,
            browserShadowHostBottomConstraint,
            browserShadowHostTrailingConstraint,
            browserWidthConstraint,

            // Browser panel fills its shadow host.
            browserPanelView.topAnchor.constraint(equalTo: browserShadowHost.topAnchor),
            browserPanelView.leadingAnchor.constraint(equalTo: browserShadowHost.leadingAnchor),
            browserPanelView.trailingAnchor.constraint(equalTo: browserShadowHost.trailingAnchor),
            browserPanelView.bottomAnchor.constraint(equalTo: browserShadowHost.bottomAnchor),

            // Drag handle sits in the 8pt gap between terminal and browser.
            browserDragHandle.topAnchor.constraint(equalTo: terminalShadowHost.topAnchor),
            browserDragHandle.bottomAnchor.constraint(equalTo: terminalShadowHost.bottomAnchor),
            browserDragHandle.leadingAnchor.constraint(equalTo: terminalShadowHost.trailingAnchor),
            browserDragHandle.trailingAnchor.constraint(equalTo: browserShadowHost.leadingAnchor),
        ])

        // Terminal floating card: top corners rounded when in card mode (pinned/closed).
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.cornerRadius = hasCardInset ? WorkspaceLayout.terminalCornerRadius : 0
        terminalContainer.layer?.cornerCurve = .continuous
        terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        terminalContainer.layer?.masksToBounds = true

        // Configure shadow on the host layer. Must happen after addSubview so the
        // layer exists (wantsLayer in a property closure may not create it in time).
        terminalShadowHost.wantsLayer = true
        terminalShadowHost.layer?.shadowColor = WorkspaceLayout.canvasShadowColor
        terminalShadowHost.layer?.shadowOpacity = hasCardInset ? WorkspaceLayout.canvasShadowOpacity : 0
        terminalShadowHost.layer?.shadowRadius = WorkspaceLayout.canvasShadowRadius
        terminalShadowHost.layer?.shadowOffset = WorkspaceLayout.canvasShadowOffset

        // Card background behind the title bar region. No masksToBounds — shadow
        // must render outside the layer bounds.
        terminalShadowHost.layer?.cornerRadius = hasCardInset ? WorkspaceLayout.terminalCornerRadius : 0
        terminalShadowHost.layer?.cornerCurve = .continuous
        terminalShadowHost.layer?.backgroundColor = hasCardInset ? cardBackgroundCGColor : nil

        // Browser shadow host — identical layer config to terminal shadow host.
        browserShadowHost.wantsLayer = true
        browserShadowHost.layer?.shadowColor = WorkspaceLayout.canvasShadowColor
        browserShadowHost.layer?.shadowOpacity = 0  // hidden initially
        browserShadowHost.layer?.shadowRadius = WorkspaceLayout.canvasShadowRadius
        browserShadowHost.layer?.shadowOffset = WorkspaceLayout.canvasShadowOffset
        browserShadowHost.layer?.cornerRadius = hasCardInset ? WorkspaceLayout.terminalCornerRadius : 0
        browserShadowHost.layer?.cornerCurve = .continuous
        browserShadowHost.layer?.backgroundColor = hasCardInset ? browserCardBackgroundCGColor : nil
        browserShadowHost.layer?.masksToBounds = false
        browserShadowHost.alphaValue = 0  // hidden initially

        // Canvas background — visible behind the floating card in pinned and closed modes.
        layer?.backgroundColor = hasCardInset ? canvasBackgroundCGColor : nil

        // Background material is only visible in overlay (floating hover) mode.
        // In pinned mode the sidebar is transparent; in closed mode it's hidden entirely.
        backgroundEffectView.isHidden = true
        if initialMode == .closed {
            sidebarHostingView.alphaValue = 0
        } else if initialMode == .overlay {
            titleLabel.alphaValue = 0
            sidebarToggleButton.alphaValue = 0
            browserToggleButton.alphaValue = 0
        }

        // Bind title label to the active session name.
        coordinator.$activeSessionId
            .combineLatest(WorkspaceStore.shared.$sessions)
            .map { activeId, sessions -> String in
                guard let id = activeId,
                      let session = sessions.first(where: { $0.id == id })
                else { return "" }
                return session.name
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.titleLabel.stringValue = name
            }
            .store(in: &cancellables)

        // Bind the terminal card background to the focused surface's theme so
        // the chrome matches the terminal instead of the hardcoded palette.
        // Mirrors TerminalWindow.syncAppearance() — same "focused surface drives
        // window color" rule, applied to our card instead of the window itself.
        coordinator.$activeSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebindFocusedSurfaceTheme()
            }
            .store(in: &cancellables)
        // Initial bind so we pick up whatever surface exists at launch before
        // the publisher fires.
        rebindFocusedSurfaceTheme()
    }

    // MARK: - Focused Surface Theme Binding

    /// Resubscribe to the focused surface's `$derivedConfig` whenever the
    /// active session changes. Cancels any prior subscription, looks up the
    /// new focused surface via the terminal controller, and both applies the
    /// current theme color immediately and listens for future theme updates
    /// (e.g. user edits config, OS appearance swap flips the auto-theme).
    private func rebindFocusedSurfaceTheme() {
        observedSurfaceCancellables.removeAll()

        let surface = focusedSurfaceForActiveSession()
        observedSurface = surface

        // Apply immediately so the card doesn't wait for the next publisher
        // emission. Skip the repaint in overlay mode where the card is hidden
        // and its background was explicitly cleared.
        applyChromeColor()

        guard let surface else { return }

        surface.$derivedConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak surface] _ in
                // Guard: only repaint if this surface is still the one we're
                // observing. A stale emission from a replaced surface would
                // otherwise overwrite the new theme.
                guard let self, let surface, self.observedSurface === surface
                else { return }
                self.applyChromeColor()
            }
            .store(in: &observedSurfaceCancellables)
    }

    /// Look up the focused surface for the currently active session, falling
    /// back to the session tree's first surface when the controller doesn't
    /// yet have a focused surface (e.g. right after session creation).
    /// Returns nil for browser sessions or when no session is active.
    private func focusedSurfaceForActiveSession() -> Ghostty.SurfaceView? {
        guard let activeId = coordinator.activeSessionId else { return nil }
        // Browser sessions have no surface (and no theme).
        if coordinator.browserManagers[activeId] != nil { return nil }
        // Prefer the controller's live focused surface — that's what
        // TerminalWindow.syncAppearance uses too, so our chrome stays aligned
        // with the window background even when the user moves focus across
        // splits within the same session.
        if let controller = window?.windowController as? BaseTerminalController,
           let focused = controller.focusedSurface {
            return focused
        }
        // Fall back to the first surface in the stored tree.
        return coordinator.sessionTrees[activeId]?.first
    }

    /// Repaint the chrome and canvas layers with the current Ghostties design-
    /// system palette (static, not theme-bound). The card + browser use the
    /// canvas tone; the outer layer uses the chrome tone. The focused-surface
    /// Combine subscription still drives this on session swaps and config
    /// changes — after the theme-unbind refactor it's effectively a no-op
    /// repaint with static tokens, but left in place to preserve the
    /// session-swap invalidation path with minimal churn.
    ///
    /// No-op in overlay mode, which intentionally clears all layers to let
    /// the vibrancy material show through.
    private func applyChromeColor() {
        guard sidebarMode == .pinned || sidebarMode == .closed else { return }
        terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
        browserShadowHost.layer?.backgroundColor = browserCardBackgroundCGColor
        layer?.backgroundColor = canvasBackgroundCGColor
    }
}

// MARK: - Browser URL Field Delegate

extension WorkspaceViewContainer: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        true
    }

    /// Handle Enter key in the browser URL field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            guard let field = control as? NSTextField else { return false }
            var urlString = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return true }

            // Add https:// if no scheme present.
            if !urlString.contains("://") {
                urlString = "https://\(urlString)"
            }

            // Only allow http, https, and about schemes.
            let lower = urlString.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("about:") else {
                NSLog("[WorkspaceViewContainer] Blocked URL with disallowed scheme: %@", urlString)
                return true
            }

            activeCEFView?.loadURL(urlString)
            // Resign first responder so keyboard goes back to the browser.
            field.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - Transparent Hosting View

/// NSHostingView subclass that doesn't draw the default window background.
/// Used for the sidebar so it's transparent in pinned mode — the window
/// background shows through. The overlay NSVisualEffectView provides
/// material only in hover mode.
private class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

// MARK: - Browser Drag Handle

/// Invisible drag handle that sits in the gap between the terminal and browser cards.
/// Changes the cursor to a left-right resize arrow on hover and reports horizontal
/// drag deltas via the `onDrag` closure.
private class BrowserDragHandleView: NSView {
    /// Called during mouseDragged with the horizontal delta (positive = rightward).
    var onDrag: ((CGFloat) -> Void)?

    /// Track the last mouse X position during a drag.
    private var lastDragX: CGFloat = 0

    /// Tracking area for cursor changes on hover.
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Transparent — the handle is invisible but responds to mouse events.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = event.locationInWindow.x
        let delta = currentX - lastDragX
        lastDragX = currentX
        onDrag?(delta)
    }
}
