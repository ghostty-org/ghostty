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

    /// Shadow host wraps the terminal container so the drop shadow renders
    /// outside `masksToBounds` clipping. The shadow host carries the shadow;
    /// the inner terminal container clips its corners.
    private let terminalShadowHost: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

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

    private var cancellables = Set<AnyCancellable>()

    /// Current sidebar state — always kept in sync with `WorkspaceStore.shared.sidebarMode`.
    private var sidebarMode: SidebarMode = .pinned

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

    /// Tracking area for hover detection. Only one is active at a time.
    private var activeTrackingArea: NSTrackingArea?

    private var isLightAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    /// Card background color for pinned mode title bar region.
    /// Light mode: explicit warm white. Dark mode: dark neutral.
    private var cardBackgroundCGColor: CGColor {
        isLightAppearance
            ? WorkspaceLayout.cardBackgroundLight.cgColor
            : WorkspaceLayout.cardBackgroundDark.cgColor
    }

    /// Canvas color behind the floating terminal card.
    /// Light mode: warm beige. Dark mode: slightly lighter neutral.
    private var canvasBackgroundCGColor: CGColor {
        isLightAppearance
            ? WorkspaceLayout.canvasBackgroundLight.cgColor
            : WorkspaceLayout.canvasBackgroundDark.cgColor
    }


    init<ViewModel: TerminalViewModel>(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.ghostty = ghostty
        self.terminalContainer = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: viewModel, delegate: delegate)
        }

        self.coordinator = SessionCoordinator(ghostty: ghostty)

        let sidebarView = WorkspaceSidebarView()
            .environmentObject(WorkspaceStore.shared)
            .environmentObject(coordinator)
        let hostingView = TransparentHostingView(rootView: sidebarView)
        // Auto Layout controls the sidebar width; disable intrinsic size reporting
        // to avoid unnecessary layout computation from the hosting view.
        hostingView.sizingOptions = []
        self.sidebarHostingView = hostingView

        super.init(frame: .zero)
        setup()
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

        // Auto-dismiss overlay when window loses focus.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard sidebarMode == .pinned else { return }
        layer?.backgroundColor = canvasBackgroundCGColor
        terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
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
                width: termSize.width + WorkspaceLayout.sidebarWidth + inset * 2,
                height: termSize.height + inset * 2
            )
        case .closed, .overlay:
            return termSize
        }
    }

    override func layout() {
        super.layout()
        // Explicit shadow paths eliminate per-frame offscreen rendering.
        // Without these, Core Animation rasterizes the entire layer to compute
        // the shadow shape every frame — expensive for a terminal that redraws at 60fps.
        terminalShadowHost.layer?.shadowPath = CGPath(
            roundedRect: terminalShadowHost.bounds,
            cornerWidth: WorkspaceLayout.terminalCornerRadius,
            cornerHeight: WorkspaceLayout.terminalCornerRadius,
            transform: nil
        )
        sidebarOverlayBackground.layer?.shadowPath = CGPath(
            rect: sidebarOverlayBackground.bounds,
            transform: nil
        )
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
                sidebarWidthConstraint.animator().constant = WorkspaceLayout.sidebarWidth
                shadowHostTopConstraint.animator().constant = inset
                shadowHostLeadingToSidebar.animator().constant = inset
                shadowHostTrailingConstraint.animator().constant = -inset
                shadowHostBottomConstraint.animator().constant = -inset
                terminalTopConstraint.animator().constant = WorkspaceLayout.terminalTitleBarHeight
                titleLabel.animator().alphaValue = 1
                sidebarOverlayBackground.animator().alphaValue = 0

            case .closed:
                sidebarWidthConstraint.animator().constant = 0
                shadowHostTopConstraint.animator().constant = 0
                shadowHostLeadingToSuperview.animator().constant = 0
                shadowHostTrailingConstraint.animator().constant = 0
                shadowHostBottomConstraint.animator().constant = 0
                terminalTopConstraint.animator().constant = 0
                titleLabel.animator().alphaValue = 0
                sidebarOverlayBackground.animator().alphaValue = 0

            case .overlay:
                sidebarWidthConstraint.animator().constant = WorkspaceLayout.sidebarWidth
                // Terminal stays full-width (leading to superview, no insets).
                shadowHostTopConstraint.animator().constant = 0
                shadowHostLeadingToSuperview.animator().constant = 0
                shadowHostTrailingConstraint.animator().constant = 0
                shadowHostBottomConstraint.animator().constant = 0
                terminalTopConstraint.animator().constant = 0
                titleLabel.animator().alphaValue = 0
                sidebarOverlayBackground.animator().alphaValue = 1
            }
        }

        // 5. Non-animatable properties.
        switch newMode {
        case .pinned:
            terminalContainer.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            terminalShadowHost.layer?.shadowOpacity = 0.15
            terminalShadowHost.layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
            terminalShadowHost.layer?.backgroundColor = cardBackgroundCGColor
            layer?.backgroundColor = canvasBackgroundCGColor
            sidebarOverlayBackground.layer?.shadowOpacity = 0
        case .closed:
            terminalContainer.layer?.cornerRadius = 0
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            terminalShadowHost.layer?.shadowOpacity = 0
            terminalShadowHost.layer?.cornerRadius = 0
            terminalShadowHost.layer?.backgroundColor = nil
            layer?.backgroundColor = nil
            sidebarOverlayBackground.layer?.shadowOpacity = 0
        case .overlay:
            terminalContainer.layer?.cornerRadius = 0
            terminalContainer.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            terminalShadowHost.layer?.shadowOpacity = 0
            terminalShadowHost.layer?.cornerRadius = 0
            terminalShadowHost.layer?.backgroundColor = nil
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
                width: WorkspaceLayout.sidebarWidth,
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
    }

    // MARK: - Layout

    private func setup() {
        // Canvas layer — the warm background visible behind the floating card.
        wantsLayer = true

        // Z-order: background material → overlay background → sidebar → shadow host.
        addSubview(backgroundEffectView)
        addSubview(sidebarOverlayBackground)
        addSubview(sidebarHostingView)
        addSubview(terminalShadowHost)

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
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false

        // Read persisted sidebar mode.
        let initialMode = WorkspaceStore.shared.sidebarMode
        self.sidebarMode = initialMode
        let isPinned = initialMode == .pinned
        let initialWidth: CGFloat = isPinned ? WorkspaceLayout.sidebarWidth : 0

        sidebarWidthConstraint = sidebarHostingView.widthAnchor.constraint(equalToConstant: initialWidth)

        let inset: CGFloat = isPinned ? WorkspaceLayout.terminalInset : 0
        // Inset constraints target the shadow host, not the terminal directly.
        shadowHostTopConstraint = terminalShadowHost.topAnchor.constraint(
            equalTo: topAnchor, constant: inset)
        shadowHostTrailingConstraint = terminalShadowHost.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: isPinned ? -inset : 0)
        shadowHostBottomConstraint = terminalShadowHost.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: isPinned ? -inset : 0)

        // Dual leading constraints (mutually exclusive).
        shadowHostLeadingToSidebar = terminalShadowHost.leadingAnchor.constraint(
            equalTo: sidebarHostingView.trailingAnchor, constant: inset)
        shadowHostLeadingToSuperview = terminalShadowHost.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 0)
        shadowHostLeadingToSidebar.isActive = isPinned
        shadowHostLeadingToSuperview.isActive = !isPinned

        // Terminal top offset inside the shadow host — reserves title bar space when pinned.
        let titlebarInset: CGFloat = isPinned ? WorkspaceLayout.terminalTitleBarHeight : 0
        terminalTopConstraint = terminalContainer.topAnchor.constraint(
            equalTo: terminalShadowHost.topAnchor, constant: titlebarInset)

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

            // Title label centered in the titlebar region of the card.
            titleLabel.centerXAnchor.constraint(equalTo: terminalShadowHost.centerXAnchor),
            titleLabel.topAnchor.constraint(
                equalTo: terminalShadowHost.topAnchor,
                constant: 6),
        ])

        // Terminal floating card: all four corners rounded when pinned.
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.cornerRadius = isPinned ? WorkspaceLayout.terminalCornerRadius : 0
        terminalContainer.layer?.cornerCurve = .continuous
        terminalContainer.layer?.maskedCorners = isPinned
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // bottom only (MinY = bottom in CA coords)
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        terminalContainer.layer?.masksToBounds = true

        // Configure shadow on the host layer. Must happen after addSubview so the
        // layer exists (wantsLayer in a property closure may not create it in time).
        terminalShadowHost.wantsLayer = true
        terminalShadowHost.layer?.shadowColor = NSColor.black.cgColor
        terminalShadowHost.layer?.shadowOpacity = isPinned ? 0.15 : 0
        terminalShadowHost.layer?.shadowRadius = 8
        terminalShadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)

        // Card background behind the title bar region. No masksToBounds — shadow
        // must render outside the layer bounds.
        terminalShadowHost.layer?.cornerRadius = isPinned ? WorkspaceLayout.terminalCornerRadius : 0
        terminalShadowHost.layer?.cornerCurve = .continuous
        terminalShadowHost.layer?.backgroundColor = isPinned ? cardBackgroundCGColor : nil

        // Canvas background — visible behind the floating card in pinned mode.
        layer?.backgroundColor = isPinned ? canvasBackgroundCGColor : nil

        // Background material is only visible in overlay (floating hover) mode.
        // In pinned mode the sidebar is transparent; in closed mode it's hidden entirely.
        backgroundEffectView.isHidden = true
        if !isPinned {
            titleLabel.alphaValue = 0
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
