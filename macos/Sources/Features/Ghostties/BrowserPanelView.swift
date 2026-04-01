import AppKit

/// Container for the browser panel content: navigation bar + tab bar + browser view area + inline devtools.
/// This view sits inside `browserShadowHost` (which provides shadow and rounded corners).
@MainActor
final class BrowserPanelView: NSView {
    let navigationBar = BrowserNavigationBar()
    let tabBar = BrowserTabBar()

    /// Placeholder for the browser content area (CEFBrowserView goes here in Step 9).
    let contentArea: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        return view
    }()

    /// Container for inline DevTools. Hidden by default; shown when the user
    /// toggles DevTools inline. Splits the content area vertically.
    let devToolsArea: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.isHidden = true
        return view
    }()

    /// Whether inline DevTools are currently visible.
    private(set) var isDevToolsVisible = false

    /// Height constraint for the devtools area (animated on show/hide).
    private var devToolsHeightConstraint: NSLayoutConstraint!
    /// The content area's bottom anchor target switches between panel bottom
    /// and devtools top depending on visibility.
    private var contentAreaBottomToPanel: NSLayoutConstraint!
    private var contentAreaBottomToDevTools: NSLayoutConstraint!

    /// Default DevTools height as a fraction of the panel.
    private static let devToolsRatio: CGFloat = 0.35
    private static let devToolsMinHeight: CGFloat = 120

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = WorkspaceLayout.terminalCornerRadius
        layer?.cornerCurve = .continuous

        addSubview(navigationBar)
        addSubview(tabBar)
        addSubview(contentArea)
        addSubview(devToolsArea)

        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        // Tab bar starts hidden (alphaValue 0) and shows automatically when >1 tab.
        tabBar.alphaValue = 0

        // DevTools area constraints — anchored to the bottom, hidden by default.
        devToolsHeightConstraint = devToolsArea.heightAnchor.constraint(equalToConstant: 0)

        // Content area bottom: two mutually exclusive targets.
        contentAreaBottomToPanel = contentArea.bottomAnchor.constraint(equalTo: bottomAnchor)
        contentAreaBottomToDevTools = contentArea.bottomAnchor.constraint(equalTo: devToolsArea.topAnchor)
        contentAreaBottomToPanel.isActive = true
        contentAreaBottomToDevTools.isActive = false

        NSLayoutConstraint.activate([
            // Navigation bar (top, fixed height)
            navigationBar.topAnchor.constraint(equalTo: topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navigationBar.heightAnchor.constraint(
                equalToConstant: WorkspaceLayout.terminalTitleBarHeight),

            // Tab bar (below nav, 24pt height)
            tabBar.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Content area (fills between tab bar and bottom / devtools)
            contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),

            // DevTools area (anchored to bottom)
            devToolsArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            devToolsArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            devToolsArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            devToolsHeightConstraint,
        ])
    }

    // MARK: - Inline DevTools

    /// Show the inline DevTools area with animation.
    func showDevTools() {
        guard !isDevToolsVisible else { return }
        isDevToolsVisible = true
        devToolsArea.isHidden = false

        // Switch content area bottom anchor to devtools top.
        contentAreaBottomToPanel.isActive = false
        contentAreaBottomToDevTools.isActive = true

        let targetHeight = max(bounds.height * Self.devToolsRatio, Self.devToolsMinHeight)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            devToolsHeightConstraint.animator().constant = targetHeight
        }
    }

    /// Hide the inline DevTools area with animation.
    func hideDevTools() {
        guard isDevToolsVisible else { return }
        isDevToolsVisible = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            devToolsHeightConstraint.animator().constant = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.devToolsArea.isHidden = true
            self.contentAreaBottomToDevTools.isActive = false
            self.contentAreaBottomToPanel.isActive = true
        })
    }

    /// Toggle inline DevTools visibility.
    func toggleDevTools() {
        if isDevToolsVisible {
            hideDevTools()
        } else {
            showDevTools()
        }
    }
}
