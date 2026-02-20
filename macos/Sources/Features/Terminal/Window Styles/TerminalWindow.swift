import AppKit
import SwiftUI
import GhosttyKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// Posted when a terminal window awakes from nib.
    static let terminalDidAwake = Notification.Name("TerminalWindowDidAwake")

    /// Posted when a terminal window will close
    static let terminalWillCloseNotification = Notification.Name("TerminalWindowWillClose")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    private var viewModel = ViewModel()
    private var enforcedTitlebarFont: NSFont = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// Update notification UI in titlebar
    private let updateAccessory = NSTitlebarAccessoryViewController()
    private let diffSidebarAccessory = NSTitlebarAccessoryViewController()
    private weak var diffSidebarButton: NSButton?

    /// Visual indicator that mirrors the selected tab color.
    private lazy var tabColorIndicator: NSHostingView<TabColorIndicatorView> = {
        let view = NSHostingView(rootView: TabColorIndicatorView(tabColor: tabColor))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Sets up our tab context menu
    private var tabMenuObserver: NSObjectProtocol? = nil
    private var titlebarFontTabGroupObservation: NSKeyValueObservation? = nil
    private var titlebarFontTabBarObservation: NSKeyValueObservation? = nil
    private var lastTitlebarFontState: TitlebarFontState? = nil
    private var lastAppliedAppearance: AppearanceState? = nil

    /// Whether this window supports the update accessory. If this is false, then views within this
    /// window should determine how to show update notifications.
    var supportsUpdateAccessory: Bool {
        // Native window supports it.
        true
    }

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    /// The color assigned to this window's tab. Setting this updates the tab color indicator
    /// and marks the window's restorable state as dirty.
    var tabColor: TerminalTabColor = .none {
        didSet {
            guard tabColor != oldValue else { return }
            tabColorIndicator.rootView = TabColorIndicatorView(tabColor: tabColor)
            invalidateRestorableState()
        }
    }

    // MARK: NSWindow Overrides

    override var toolbar: NSToolbar? {
        didSet {
            DispatchQueue.main.async {
                // When we have a toolbar, our SwiftUI view needs to know for layout
                self.viewModel.hasToolbar = self.toolbar != nil
            }
        }
    }

    override func awakeFromNib() {
        // Notify that this terminal window has loaded
        NotificationCenter.default.post(name: Self.terminalDidAwake, object: self)

        // This is fragile, but there doesn't seem to be an official API for customizing
        // native tab bar menus.
        tabMenuObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: "NSMenuWillOpenNotification"),
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self, let menu = n.object as? NSMenu else { return }
            self.configureTabContextMenuIfNeeded(menu)
        }

        // This is required so that window restoration properly creates our tabs
        // again. I'm not sure why this is required. If you don't do this, then
        // tabs restore as separate windows.
        tabbingMode = .preferred
        DispatchQueue.main.async {
            self.tabbingMode = .automatic
        }

        // All new windows are based on the app config at the time of creation.
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)
        enforcedTitlebarFont = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        setupTitlebarFontKVO()

        // If there is a hardcoded title in the configuration, we set that
        // immediately. Future `set_title` apprt actions will override this
        // if necessary but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick (see #5934)
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        // Set our window positioning to coordinates if config value exists, otherwise
        // fallback to original centering behavior
        setInitialWindowPosition(
            x: config.windowPositionX,
            y: config.windowPositionY)

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // Create our reset zoom titlebar accessory. We have to have a title
        // to do this or AppKit triggers an assertion.
        if styleMask.contains(.titled) {
            resetZoomAccessory.layoutAttribute = .right
            resetZoomAccessory.view = NSHostingView(rootView: ResetZoomAccessoryView(
                viewModel: viewModel,
                action: { [weak self] in
                    guard let self else { return }
                    self.terminalController?.splitZoom(self)
                }))
            addTitlebarAccessoryViewController(resetZoomAccessory)
            resetZoomAccessory.view.translatesAutoresizingMaskIntoConstraints = false

            // Create update notification accessory
            if supportsUpdateAccessory {
                updateAccessory.layoutAttribute = .right
                updateAccessory.view = NonDraggableHostingView(rootView: UpdateAccessoryView(
                    viewModel: viewModel,
                    model: appDelegate.updateViewModel
                ))
                addTitlebarAccessoryViewController(updateAccessory)
                updateAccessory.view.translatesAutoresizingMaskIntoConstraints = false
            }

            diffSidebarAccessory.layoutAttribute = .right
            let container = NonDraggableAccessoryContainer()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: 40).isActive = true
            container.heightAnchor.constraint(equalToConstant: 40).isActive = true

            let button = NonDraggableToolbarButton(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 26.0, *) {
                button.bezelStyle = .glass
            } else {
                button.bezelStyle = .toolbar
            }
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            button.image = NSImage(systemSymbolName: "plusminus", accessibilityDescription: "Toggle Diff Sidebar")?
                .withSymbolConfiguration(symbolConfig)
            button.imagePosition = .imageOnly
            button.controlSize = .large
            button.target = terminalController
            button.action = #selector(TerminalController.toggleGitDiffSidebar(_:))
            button.setButtonType(.momentaryPushIn)

            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -6),
                button.widthAnchor.constraint(equalToConstant: 36),
                button.heightAnchor.constraint(equalToConstant: 36),
            ])

            diffSidebarAccessory.view = container
            diffSidebarButton = button
            addTitlebarAccessoryViewController(diffSidebarAccessory)
            diffSidebarAccessory.view.translatesAutoresizingMaskIntoConstraints = false
        }

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable.
        tabColorIndicator.rootView = TabColorIndicatorView(tabColor: tabColor)

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 4
        stackView.alignment = .centerY
        stackView.addArrangedSubview(tabColorIndicator)
        stackView.addArrangedSubview(keyEquivalentLabel)
        stackView.addArrangedSubview(resetZoomTabButton)
        tab.accessoryView = stackView

        // Get our saved level
        level = UserDefaults.standard.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func close() {
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        resetZoomTabButton.contentTintColor = .controlAccentColor
        enforceTitlebarFont()
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
        updateWorktrunkToolbarTitle()
    }

    override func becomeMain() {
        super.becomeMain()

        // Its possible we miss the accessory titlebar call so we check again
        // whenever the window becomes main. Both of these are idempotent.
        if WorktrunkPreferences.sidebarTabsEnabled {
            collapseNativeTabBarRegionIfPresent()
        } else if tabBarView != nil {
            tabBarDidAppear()
        } else {
            tabBarDidDisappear()
        }
        viewModel.isMainWindow = true
        if diffSidebarButton?.target == nil {
            diffSidebarButton?.target = terminalController
        }
        enforceTitlebarFont()
        setupTitlebarFontKVO()
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }

    override func update() {
        super.update()
        enforceTitlebarFont()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs (issue #1902)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let isTabBarCandidate = isTabBar(childViewController)
        if isTabBarCandidate, WorktrunkPreferences.sidebarTabsEnabled {
            // Prevent a one-frame flash of the native tab strip by collapsing its reserved region
            // before AppKit lays it out.
            childViewController.identifier = Self.tabBarIdentifier
            childViewController.view.isHidden = true
            childViewController.view.alphaValue = 0
            let c = childViewController.view.heightAnchor.constraint(equalToConstant: 0)
            c.priority = .required
            c.isActive = true
        }

        super.addTitlebarAccessoryViewController(childViewController)

        // Tab bar is attached as a titlebar accessory view controller (layout bottom). We
        // can detect when it is shown or hidden by overriding add/remove and searching for
        // it. This has been verified to work on macOS 12 to 26
        if isTabBarCandidate || isTabBar(childViewController) {
            childViewController.identifier = Self.tabBarIdentifier
            if WorktrunkPreferences.sidebarTabsEnabled {
                // In "Sidebar tabs" mode we keep native tab groups but hide the native
                // tab bar UI so switching happens via the sidebar.
                collapseTitlebarAccessoryClipViewIfPresent(containing: childViewController.view)
            } else {
                tabBarDidAppear()
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.enforceTitlebarFont()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        if let childViewController = titlebarAccessoryViewControllers[safe: index], isTabBar(childViewController) {
            if !WorktrunkPreferences.sidebarTabsEnabled {
                tabBarDidDisappear()
            }
        }

        super.removeTitlebarAccessoryViewController(at: index)
        DispatchQueue.main.async { [weak self] in
            self?.enforceTitlebarFont()
        }
    }

    // MARK: Tab Bar

    /// This identifier is attached to the tab bar view controller when we detect it being
    /// added.
    static let tabBarIdentifier: NSUserInterfaceItemIdentifier = .init("_ghosttyTabBar")

    var hasMoreThanOneTabs: Bool {
        /// accessing ``tabGroup?.windows`` here
        /// will cause other edge cases, be careful
        (tabbedWindows?.count ?? 0) > 1
    }

    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool {
        if childViewController.identifier == nil {
            // The good case
            if childViewController.view.contains(className: "NSTabBar") {
                return true
            }

            // When a new window is attached to an existing tab group, AppKit adds
            // an empty NSView as an accessory view and adds the tab bar later. If
            // we're at the bottom and are a single NSView we assume its a tab bar.
            if childViewController.layoutAttribute == .bottom &&
                childViewController.view.className == "NSView" &&
                childViewController.view.subviews.isEmpty {
                return true
            }

            return false
        }

        // View controllers should be tagged with this as soon as possible to
        // increase our accuracy. We do this manually.
        return childViewController.identifier == Self.tabBarIdentifier
    }

    private func tabBarDidAppear() {
        // Remove our reset zoom accessory. For some reason having a SwiftUI
        // titlebar accessory causes our content view scaling to be wrong.
        // Removing it fixes it, we just need to remember to add it again later.
        if let idx = titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) {
            removeTitlebarAccessoryViewController(at: idx)
        }

        // We don't need to do this with the update accessory. I don't know why but
        // everything works fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            self?.enforceTitlebarFont()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.enforceTitlebarFont()
        }
    }

    private func tabBarDidDisappear() {
        if styleMask.contains(.titled) {
            if titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) == nil {
                addTitlebarAccessoryViewController(resetZoomAccessory)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            self?.enforceTitlebarFont()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.enforceTitlebarFont()
        }
    }

    private func removeNativeTabBarIfPresent() {
        // Tab bars can appear via multiple accessory view controller arrangements depending on
        // macOS + window state. Remove any tab bar accessory view controllers we detect.
        while let idx = titlebarAccessoryViewControllers.firstIndex(where: { isTabBar($0) }) {
            removeTitlebarAccessoryViewController(at: idx)
        }
    }

    private func collapseNativeTabBarRegionIfPresent() {
        guard WorktrunkPreferences.sidebarTabsEnabled else { return }
        for tabBarVC in titlebarAccessoryViewControllers where isTabBar(tabBarVC) {
            collapseTitlebarAccessoryClipViewIfPresent(containing: tabBarVC.view)
        }
    }

    private func collapseTitlebarAccessoryClipViewIfPresent(containing view: NSView) {
        var v: NSView? = view
        while let cur = v, cur.className != "NSTitlebarAccessoryClipView" {
            v = cur.superview
        }
        guard let clip = v else { return }

        clip.isHidden = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        if clip.constraints.first(where: { c in
            c.firstAttribute == .height &&
            c.relation == .equal &&
            c.constant == 0 &&
            c.priority == .required
        }) == nil {
            let c = clip.heightAnchor.constraint(equalToConstant: 0)
            c.priority = .required
            c.isActive = true
        }
    }

    // MARK: Tab Key Equivalents

    var keyEquivalent: String? {
        didSet {
            // When our key equivalent is set, we must update the tab label.
            guard let keyEquivalent else {
                keyEquivalentLabel.attributedStringValue = NSAttributedString()
                return
            }

            keyEquivalentLabel.attributedStringValue = NSAttributedString(
                string: "\(keyEquivalent) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
        }
    }

    /// The label that has the key equivalent for tab views.
    private lazy var keyEquivalentLabel: NSTextField = {
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
        label.postsFrameChangedNotifications = true
        return label
    }()

    // MARK: Surface Zoom

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            // Show/hide our reset zoom button depending on if we're zoomed.
            // We want to show it if we are zoomed.
            resetZoomTabButton.isHidden = !surfaceIsZoomed

            DispatchQueue.main.async {
                self.viewModel.isSurfaceZoomed = self.surfaceIsZoomed
            }
        }
    }

    private lazy var resetZoomTabButton: NSButton = generateResetZoomButton()

    private func generateResetZoomButton() -> NSButton {
        let button = NSButton()
        button.isHidden = true
        button.target = terminalController
        button.action = #selector(TerminalController.splitZoom(_:))
        button.isBordered = false
        button.allowsExpansionToolTips = true
        button.toolTip = "Reset Zoom"
        button.contentTintColor = isMainWindow ? .controlAccentColor : .secondaryLabelColor
        button.state = .on
        button.image = NSImage(named: "ResetZoom")
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    // MARK: Title Text

    private struct TitlebarFontState: Equatable {
        let title: String
        let fontName: String
        let fontSize: CGFloat
        let isKeyWindow: Bool
        let macosTitlebarStyle: String
        let tabCount: Int
        let toolbarIdentifier: ObjectIdentifier?
    }

    override var title: String {
        didSet {
            // Only manage tab titles for custom tab styles.
            if derivedConfig.macosTitlebarStyle == "tabs" {
                tab.title = title
                tab.attributedTitle = attributedTitle
            }
            /// We also needs to update this here, just in case
            /// the value is not what we want
            ///
            /// Check ``titlebarFont`` down below
            /// to see why we need to check `hasMoreThanOneTabs` here
            enforceTitlebarFont()
        }
    }

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
            enforcedTitlebarFont = font

            enforceTitlebarFont()
        }
    }

    // Find the NSTextField responsible for displaying the titlebar's title.
    private var titlebarTextField: NSTextField? {
        titlebarContainer?
            .firstDescendant(withClassName: "NSTitlebarView")?
            .firstDescendant(withClassName: "NSTextField") as? NSTextField
    }

    // Return a styled representation of our title property.
    var attributedTitle: NSAttributedString? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: enforcedTitlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    func enforceTitlebarFont() {
        let tabCount = tabGroup?.windows.count ?? 0
        let font = enforcedTitlebarFont
        let state = TitlebarFontState(
            title: title,
            fontName: font.fontName,
            fontSize: font.pointSize,
            isKeyWindow: isKeyWindow,
            macosTitlebarStyle: derivedConfig.macosTitlebarStyle,
            tabCount: tabCount,
            toolbarIdentifier: toolbar.map(ObjectIdentifier.init)
        )
        if state == lastTitlebarFontState {
            return
        }
        lastTitlebarFontState = state

        if derivedConfig.macosTitlebarStyle != "tabs",
           tabCount > 1 {
            updateWorktrunkToolbarTitle()
            return
        }
        if let titlebarTextField {
            titlebarTextField.font = enforcedTitlebarFont
            titlebarTextField.usesSingleLineMode = true
            titlebarTextField.attributedStringValue = attributedTitle ?? NSAttributedString(string: title)
            if derivedConfig.macosTitlebarStyle == "tabs" {
                tab.title = title
                tab.attributedTitle = attributedTitle
            }
        }
        updateWorktrunkToolbarTitle()
    }

    private func updateWorktrunkToolbarTitle() {
        guard let toolbar = toolbar as? WorktrunkToolbar else { return }
        toolbar.titleText = title
        toolbar.titleTextFont = enforcedTitlebarFont
        toolbar.titleTextColor = isKeyWindow ? .labelColor : .secondaryLabelColor
    }

    private func setupTitlebarFontKVO() {
        titlebarFontTabGroupObservation?.invalidate()
        titlebarFontTabGroupObservation = nil
        titlebarFontTabBarObservation?.invalidate()
        titlebarFontTabBarObservation = nil

        guard let tabGroup else { return }
        titlebarFontTabGroupObservation = tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.enforceTitlebarFont()
            }
        }
        titlebarFontTabBarObservation = tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.enforceTitlebarFont()
            }
        }
    }

    var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: Positioning And Styling

    private struct ColorRGBA: Equatable {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
    }

    private struct AppearanceState: Equatable {
        let isFullScreen: Bool
        let forceOpaque: Bool
        let backgroundOpacity: Double
        let backgroundBlur: Ghostty.Config.BackgroundBlur
        let macosWindowShadow: Bool
        let windowTheme: String
        let windowAppearanceName: String?
        let preferredBackground: ColorRGBA?
    }

    private func rgba(from color: NSColor?) -> ColorRGBA? {
        guard let color else { return nil }
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        return ColorRGBA(
            r: rgb.redComponent,
            g: rgb.greenComponent,
            b: rgb.blueComponent,
            a: rgb.alphaComponent
        )
    }

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else {
            lastAppliedAppearance = nil
            return
        }
        defer { updateColorSchemeForSurfaceTree() }

        let isFullScreen = styleMask.contains(.fullScreen)
        let forceOpaque = terminalController?.isBackgroundOpaque ?? false
        let windowTheme = surfaceConfig.windowTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredBackground = preferredBackgroundColor
        let appearanceState = AppearanceState(
            isFullScreen: isFullScreen,
            forceOpaque: forceOpaque,
            backgroundOpacity: surfaceConfig.backgroundOpacity,
            backgroundBlur: surfaceConfig.backgroundBlur,
            macosWindowShadow: surfaceConfig.macosWindowShadow,
            windowTheme: windowTheme,
            windowAppearanceName: surfaceConfig.windowAppearance?.name.rawValue,
            preferredBackground: rgba(from: preferredBackground)
        )
        if appearanceState == lastAppliedAppearance {
            return
        }

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        //
        // Also check if the user has overridden transparency to be fully opaque.
        if !isFullScreen &&
            !forceOpaque &&
            (surfaceConfig.backgroundOpacity < 1 || surfaceConfig.backgroundBlur.isGlassStyle) {
            isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            backgroundColor = .white.withAlphaComponent(0.001)

            // We don't need to set blur when using glass
            if !surfaceConfig.backgroundBlur.isGlassStyle, let appDelegate = NSApp.delegate as? AppDelegate {
                ghostty_set_window_background_blur(
                    appDelegate.ghostty.app,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        } else {
            isOpaque = true

            let usesTerminalBackgroundForWindow = windowTheme == "auto" || windowTheme == "ghostty"
            if usesTerminalBackgroundForWindow {
                let backgroundColor = preferredBackground ?? NSColor(surfaceConfig.backgroundColor)
                self.backgroundColor = backgroundColor.withAlphaComponent(1)
            } else {
                self.backgroundColor = NSColor.windowBackgroundColor
            }
        }

        lastAppliedAppearance = appearanceState
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let terminalController, !terminalController.surfaceTree.isEmpty {
            let surface: Ghostty.SurfaceView?

            // If our focused surface borders the top then we prefer its background color
            if let focusedSurface = terminalController.focusedSurface,
               let treeRoot = terminalController.surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
                surface = focusedSurface
            } else {
                // If it doesn't border the top, we use the top-left leaf
                surface = terminalController.surfaceTree.root?.leftmostLeaf()
            }

            if let surface {
                let backgroundColor = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
                let alpha = surface.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
                return NSColor(backgroundColor).withAlphaComponent(alpha)
            }
        }

        let alpha = derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
        return derivedConfig.backgroundColor.withAlphaComponent(alpha)
    }

    func updateColorSchemeForSurfaceTree() {
        terminalController?.updateColorSchemeForSurfaceTree()
    }

    private func setInitialWindowPosition(x: Int16?, y: Int16?) {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard x != nil, y != nil else {
            if !LastWindowPosition.shared.restore(self) {
                center()
            }

            return
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            center()
            return
        }

        // We have an X/Y, use our controller function to set it up.
        guard let terminalController else {
            center()
            return
        }

        let frame = terminalController.adjustForWindowPosition(frame: frame, on: screen)
        setFrameOrigin(frame.origin)
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    deinit {
        if let observer = tabMenuObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Config

    struct DerivedConfig {
        let title: String?
        let backgroundBlur: Ghostty.Config.BackgroundBlur
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: String
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.macosTitlebarStyle = "transparent"
            self.windowCornerRadius = 16
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.macosTitlebarStyle = config.macosTitlebarStyle

            // Set corner radius based on macos-titlebar-style
            // Native, transparent, and hidden styles use 16pt radius
            // Tabs style uses 20pt radius
            switch config.macosTitlebarStyle {
            case "tabs":
                self.windowCornerRadius = 20
            default:
                self.windowCornerRadius = 16
            }
        }
    }
}

// MARK: SwiftUI View

extension TerminalWindow {
    class ViewModel: ObservableObject {
        @Published var isSurfaceZoomed: Bool = false
        @Published var hasToolbar: Bool = false
        @Published var isMainWindow: Bool = true

        /// Calculates the top padding based on toolbar visibility and macOS version
        fileprivate var accessoryTopPadding: CGFloat {
            if #available(macOS 26.0, *) {
                return hasToolbar ? 10 : 5
            } else {
                return hasToolbar ? 9 : 4
            }
        }
    }

    struct ResetZoomAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        let action: () -> Void

        var body: some View {
            if viewModel.isSurfaceZoomed {
                VStack {
                    Button(action: action) {
                        Image("ResetZoom")
                            .foregroundColor(viewModel.isMainWindow ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Split Zoom")
                    .frame(width: 20, height: 20)
                    Spacer()
                }
                // With a toolbar, the window title is taller, so we need more padding
                // to properly align.
                .padding(.top, viewModel.accessoryTopPadding)
                // We always need space at the end of the titlebar
                .padding(.trailing, 10)
            }
        }
    }

    /// A pill-shaped button that displays update status and provides access to update actions.
    struct UpdateAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        @ObservedObject var model: UpdateViewModel

        var body: some View {
            // We use the same top/trailing padding so that it hugs the same.
            UpdatePill(model: model)
                .padding(.top, viewModel.accessoryTopPadding)
                .padding(.trailing, viewModel.accessoryTopPadding)
        }
    }

}

private final class NonDraggableToolbarButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class NonDraggableAccessoryContainer: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A small circle indicator displayed in the tab accessory view that shows
/// the user-assigned tab color. When no color is set, the view is hidden.
private struct TabColorIndicatorView: View {
    /// The tab color to display.
    let tabColor: TerminalTabColor

    var body: some View {
        if let color = tabColor.displayColor {
            Circle()
                .fill(Color(color))
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .fill(Color.clear)
                .frame(width: 6, height: 6)
                .hidden()
        }
    }
}

// MARK: - Tab Context Menu

extension TerminalWindow {
    private static let closeTabsOnRightMenuItemIdentifier = NSUserInterfaceItemIdentifier("dev.sidequery.Ghostree.closeTabsOnTheRightMenuItem")
    private static let changeTitleMenuItemIdentifier = NSUserInterfaceItemIdentifier("dev.sidequery.Ghostree.changeTitleMenuItem")
    private static let tabColorSeparatorIdentifier = NSUserInterfaceItemIdentifier("dev.sidequery.Ghostree.tabColorSeparator")

    private static let tabColorPaletteIdentifier = NSUserInterfaceItemIdentifier("dev.sidequery.Ghostree.tabColorPalette")

    func configureTabContextMenuIfNeeded(_ menu: NSMenu) {
        guard isTabContextMenu(menu) else { return }

        // Get the target from an existing menu item. The native tab context menu items
        // target the specific window/controller that was right-clicked, not the focused one.
        // We need to use that same target so validation and action use the correct tab.
        let targetController = menu.items
            .first { $0.action == NSSelectorFromString("performClose:") }
            .flatMap { $0.target as? NSWindow }
            .flatMap { $0.windowController as? TerminalController }

        // Close tabs to the right
        let item = NSMenuItem(title: "Close Tabs to the Right", action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        item.identifier = Self.closeTabsOnRightMenuItemIdentifier
        item.target = targetController
        item.setImageIfDesired(systemSymbolName: "xmark")
        if menu.insertItem(item, after: NSSelectorFromString("performCloseOtherTabs:")) == nil,
           menu.insertItem(item, after: NSSelectorFromString("performClose:")) == nil {
            menu.addItem(item)
        }

        // Other close items should have the xmark to match Safari on macOS 26
        for menuItem in menu.items {
            if menuItem.action == NSSelectorFromString("performClose:") ||
                menuItem.action == NSSelectorFromString("performCloseOtherTabs:") {
                menuItem.setImageIfDesired(systemSymbolName: "xmark")
            }
        }

        appendTabModifierSection(to: menu, target: targetController)
    }

    private func isTabContextMenu(_ menu: NSMenu) -> Bool {
        guard NSApp.keyWindow === self else { return false }

        // These selectors must all exist for it to be a tab context menu.
        let requiredSelectors: Set<String> = [
            "performClose:",
            "performCloseOtherTabs:",
            "moveTabToNewWindow:",
            "toggleTabOverview:"
        ]

        let selectorNames = Set(menu.items.compactMap { $0.action }.map { NSStringFromSelector($0) })
        return requiredSelectors.isSubset(of: selectorNames)
    }

    private func appendTabModifierSection(to menu: NSMenu, target: TerminalController?) {
        menu.removeItems(withIdentifiers: [
            Self.tabColorSeparatorIdentifier,
            Self.changeTitleMenuItemIdentifier,
            Self.tabColorPaletteIdentifier
        ])

        let separator = NSMenuItem.separator()
        separator.identifier = Self.tabColorSeparatorIdentifier
        menu.addItem(separator)

        // Change Title...
        let changeTitleItem = NSMenuItem(title: "Change Title...", action: #selector(BaseTerminalController.changeTabTitle(_:)), keyEquivalent: "")
        changeTitleItem.identifier = Self.changeTitleMenuItemIdentifier
        changeTitleItem.target = target
        changeTitleItem.setImageIfDesired(systemSymbolName: "pencil.line")
        menu.addItem(changeTitleItem)

        let paletteItem = NSMenuItem()
        paletteItem.identifier = Self.tabColorPaletteIdentifier
        paletteItem.view = makeTabColorPaletteView(
            selectedColor: (target?.window as? TerminalWindow)?.tabColor ?? .none
        ) { [weak target] color in
            (target?.window as? TerminalWindow)?.tabColor = color
        }
        menu.addItem(paletteItem)
    }
}

private func makeTabColorPaletteView(
    selectedColor: TerminalTabColor,
    selectionHandler: @escaping (TerminalTabColor) -> Void
) -> NSView {
    let hostingView = NSHostingView(rootView: TabColorMenuView(
        selectedColor: selectedColor,
        onSelect: selectionHandler
    ))
    hostingView.frame.size = hostingView.intrinsicContentSize
    return hostingView
}
