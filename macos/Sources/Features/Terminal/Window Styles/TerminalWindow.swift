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

    /// Posted when the window title changes.
    static let terminalTitleDidChangeNotification = Notification.Name("TerminalWindowTitleDidChange")

    /// Posted when tab/session metadata mirrored by the sidebar changes.
    static let terminalSidebarMetadataDidChangeNotification = Notification.Name("TerminalWindowSidebarMetadataDidChange")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// Update notification UI in titlebar
    private let updateAccessory = NSTitlebarAccessoryViewController()

    /// Visual indicator that mirrors the selected tab color.
    private lazy var tabColorIndicator: NSHostingView<TabColorIndicatorView> = {
        let view = NSHostingView(rootView: TabColorIndicatorView(tabColor: tabColor))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Sets up our tab context menu
    private var tabMenuObserver: NSObjectProtocol?

    /// Handles inline tab title editing for this host window.
    private(set) lazy var tabTitleEditor = TabTitleEditor(
        hostWindow: self,
        delegate: self
    )

    /// Custom vertical session sidebar for `macos-titlebar-style = sidebar`.
    private var sidebarController: TerminalSidebarController?
    private var sidebarTitlebarBackgroundView: SidebarTitlebarBackgroundView?
    private var sidebarTitlebarWidthConstraint: NSLayoutConstraint?
    private var sidebarTitlebarResizeHandle: SidebarTitlebarResizeHandle?
    private var sidebarTitlebarResizeHandleCenterXConstraint: NSLayoutConstraint?
    private var sidebarTitlebarControlsView: SidebarTitlebarControlsView?
    private var sidebarCollapsed = false

    var isSidebarCollapsed: Bool {
        sidebarCollapsed
    }

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
            NotificationCenter.default.post(name: Self.terminalSidebarMetadataDidChangeNotification, object: self)
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

        // If there is a hardcoded title in the configuration, we set that
        // immediately. Future `set_title` apprt actions will override this
        // if necessary but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick (see #5934)
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        // NOTE: setInitialWindowPosition is NOT called here because subclass
        // awakeFromNib may add decorations (e.g. toolbar for tabs style) that
        // change the frame. It is called from TerminalController.windowDidLoad
        // after the window is fully set up.

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
        level = UserDefaults.ghostty.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func sendEvent(_ event: NSEvent) {
        if handleSidebarToggleShortcut(event) {
            return
        }

        if tabTitleEditor.handleMouseDown(event) {
            return
        }

        if tabTitleEditor.handleRightMouseDown(event) {
            return
        }

        super.sendEvent(event)
    }

    override func close() {
        tabTitleEditor.finishEditing(commit: true)
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        resetZoomTabButton.contentTintColor = .controlAccentColor
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
        tabTitleEditor.finishEditing(commit: true)
    }

    override func becomeMain() {
        super.becomeMain()

        // Its possible we miss the accessory titlebar call so we check again
        // whenever the window becomes main. Both of these are idempotent.
        if derivedConfig.macosTitlebarStyle == .sidebar {
            configureSidebarChrome()
            hideNativeTabBarForSidebar()
            terminalController?.terminalViewContainer?.syncSidebarTitlebarWidth()
        } else if tabBarView != nil {
            tabBarDidAppear()
        } else {
            tabBarDidDisappear()
        }
        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }

    @discardableResult
    func beginInlineTabTitleEdit(for targetWindow: NSWindow) -> Bool {
        tabTitleEditor.beginEditing(for: targetWindow)
    }

    func installSidebarIfNeeded() {
        guard derivedConfig.macosTitlebarStyle == .sidebar else {
            sidebarCollapsed = false
            sidebarController = nil
            terminalController?.terminalViewContainer?.removeSidebar()
            removeSidebarTitlebarBackground()
            return
        }

        guard !sidebarCollapsed else {
            configureSidebarChrome()
            terminalController?.terminalViewContainer?.removeSidebar()
            hideNativeTabBarForSidebar()
            return
        }

        guard let container = terminalController?.terminalViewContainer else { return }

        configureSidebarChrome()
        let controller = sidebarController ?? TerminalSidebarController(hostWindow: self)
        sidebarController = controller
        container.installSidebar(controller.view, width: TerminalSidebarController.preferredWidth)
        container.syncSidebarTitlebarWidth()
        controller.sync()
        syncSidebarAppearance()
        hideNativeTabBarForSidebar()
    }

    @discardableResult
    func toggleSidebar(_ _: Any?) -> Bool {
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return false }

        setSidebarCollapsed(!sidebarCollapsed, propagateToTabGroup: true)
        return true
    }

    func setSidebarCollapsed(_ collapsed: Bool, propagateToTabGroup: Bool) {
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return }

        sidebarCollapsed = collapsed
        if collapsed {
            terminalController?.terminalViewContainer?.removeSidebar()
            hideNativeTabBarForSidebar()
        } else {
            installSidebarIfNeeded()
        }

        if propagateToTabGroup {
            syncSidebarCollapsedAcrossTabGroup()
        }
    }

    private func syncSidebarCollapsedAcrossTabGroup() {
        guard let windows = tabGroup?.windows else { return }

        for window in windows where window !== self {
            guard let terminalWindow = window as? TerminalWindow else {
                continue
            }

            terminalWindow.setSidebarCollapsed(sidebarCollapsed, propagateToTabGroup: false)
        }
    }

    private func handleSidebarToggleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return false }
        guard event.isSidebarToggleShortcut else { return false }
        guard !sidebarToggleConflictsWithGhosttyBinding(event) else { return false }

        if !event.isARepeat {
            toggleSidebar(event)
        }

        return true
    }

    private func sidebarToggleConflictsWithGhosttyBinding(_ event: NSEvent) -> Bool {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else {
            return false
        }

        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        return (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            return surface.keyIsBinding(ghosttyEvent) != nil
        }
    }

    private func syncSidebarAppearance() {
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return }

        let theme = sidebarTheme
        sidebarController?.updateTheme(theme)
        sidebarTitlebarBackgroundView?.theme = theme
        sidebarTitlebarControlsView?.theme = theme
    }

    private func configureSidebarChrome() {
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbar = nil

        guard !sidebarCollapsed else {
            removeSidebarTitlebarBackground()
            return
        }

        let currentWidth = terminalController?.terminalViewContainer?.currentSidebarWidth ?? 0
        let width = currentWidth > 0 ? currentWidth : TerminalSidebarController.preferredWidth
        setSidebarTitlebarWidth(width)

        DispatchQueue.main.async { [weak self] in
            if let container = self?.terminalController?.terminalViewContainer {
                container.syncSidebarTitlebarWidth()
            } else {
                self?.setSidebarTitlebarWidth(TerminalSidebarController.preferredWidth)
            }
        }
    }

    func setSidebarTitlebarWidth(_ width: CGFloat) {
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return }

        let width = min(
            max(width, TerminalSidebarController.minWidth),
            TerminalSidebarController.maxWidth)

        guard let titlebarView = titlebarContainer?.firstDescendant(withClassName: "NSTitlebarView") else {
            return
        }

        let backgroundView = sidebarTitlebarBackgroundView ?? SidebarTitlebarBackgroundView()
        backgroundView.hostWindow = self
        backgroundView.theme = sidebarTheme
        if backgroundView.superview !== titlebarView {
            sidebarTitlebarWidthConstraint?.isActive = false
            backgroundView.removeFromSuperview()
            backgroundView.translatesAutoresizingMaskIntoConstraints = false

            if let firstSubview = titlebarView.subviews.first {
                titlebarView.addSubview(backgroundView, positioned: .below, relativeTo: firstSubview)
            } else {
                titlebarView.addSubview(backgroundView)
            }

            let widthConstraint = backgroundView.widthAnchor.constraint(equalToConstant: width)
            NSLayoutConstraint.activate([
                backgroundView.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor),
                backgroundView.topAnchor.constraint(equalTo: titlebarView.topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: titlebarView.bottomAnchor),
                widthConstraint,
            ])
            sidebarTitlebarWidthConstraint = widthConstraint
            sidebarTitlebarBackgroundView = backgroundView
        }

        sidebarTitlebarWidthConstraint?.constant = width
        backgroundView.needsDisplay = true
        installSidebarTitlebarResizeHandle(in: titlebarView, width: width)
        installSidebarTitlebarControls(in: titlebarView)
    }

    func removeSidebarTitlebarBackground() {
        sidebarTitlebarWidthConstraint?.isActive = false
        sidebarTitlebarWidthConstraint = nil
        sidebarTitlebarBackgroundView?.removeFromSuperview()
        sidebarTitlebarBackgroundView = nil
        sidebarTitlebarResizeHandleCenterXConstraint?.isActive = false
        sidebarTitlebarResizeHandleCenterXConstraint = nil
        sidebarTitlebarResizeHandle?.removeFromSuperview()
        sidebarTitlebarResizeHandle = nil
        sidebarTitlebarControlsView?.removeFromSuperview()
        sidebarTitlebarControlsView = nil
    }

    private func installSidebarTitlebarResizeHandle(in titlebarView: NSView, width: CGFloat) {
        let resizeHandle = sidebarTitlebarResizeHandle ?? SidebarTitlebarResizeHandle(hostWindow: self)
        resizeHandle.hostWindow = self

        if resizeHandle.superview !== titlebarView {
            sidebarTitlebarResizeHandleCenterXConstraint?.isActive = false
            resizeHandle.removeFromSuperview()
            resizeHandle.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(resizeHandle)

            let centerXConstraint = resizeHandle.centerXAnchor.constraint(
                equalTo: titlebarView.leadingAnchor,
                constant: width)
            NSLayoutConstraint.activate([
                centerXConstraint,
                resizeHandle.topAnchor.constraint(equalTo: titlebarView.topAnchor),
                resizeHandle.bottomAnchor.constraint(equalTo: titlebarView.bottomAnchor),
                resizeHandle.widthAnchor.constraint(equalToConstant: 10),
            ])
            sidebarTitlebarResizeHandleCenterXConstraint = centerXConstraint
            sidebarTitlebarResizeHandle = resizeHandle
        }

        sidebarTitlebarResizeHandleCenterXConstraint?.constant = width
    }

    private func installSidebarTitlebarControls(in titlebarView: NSView) {
        let controlsView = sidebarTitlebarControlsView ?? SidebarTitlebarControlsView(hostWindow: self)
        controlsView.hostWindow = self
        controlsView.theme = sidebarTheme
        controlsView.updateTooltips()

        if controlsView.superview !== titlebarView {
            controlsView.removeFromSuperview()
            controlsView.translatesAutoresizingMaskIntoConstraints = false
            titlebarView.addSubview(controlsView)

            NSLayoutConstraint.activate([
                controlsView.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor, constant: -8),
                controlsView.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
            ])
            sidebarTitlebarControlsView = controlsView
        }
    }

    func hideNativeTabBarForSidebar() {
        guard derivedConfig.macosTitlebarStyle == .sidebar else { return }

        for childViewController in titlebarAccessoryViewControllers where isTabBar(childViewController) {
            childViewController.view.isHidden = true
            childViewController.view.frame.size.height = 0
        }

        tabBarView?.isHidden = true
    }

    @objc private func renameTabFromContextMenu(_ sender: NSMenuItem) {
        let targetWindow = sender.representedObject as? NSWindow ?? self
        if beginInlineTabTitleEdit(for: targetWindow) {
            return
        }

        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
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
        let isNativeTabBar = isTabBar(childViewController)
        if isNativeTabBar && derivedConfig.macosTitlebarStyle == .sidebar {
            childViewController.layoutAttribute = .right
        }

        super.addTitlebarAccessoryViewController(childViewController)

        // Tab bar is attached as a titlebar accessory view controller (layout bottom). We
        // can detect when it is shown or hidden by overriding add/remove and searching for
        // it. This has been verified to work on macOS 12 to 26
        if isNativeTabBar {
            childViewController.identifier = Self.tabBarIdentifier
            if derivedConfig.macosTitlebarStyle == .sidebar {
                hideNativeTabBarForSidebar()
                sidebarController?.sync()
            } else {
                tabBarDidAppear()
            }
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        if let childViewController = titlebarAccessoryViewControllers[safe: index], isTabBar(childViewController) {
            tabBarDidDisappear()
        }

        super.removeTitlebarAccessoryViewController(at: index)
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
    }

    private func tabBarDidDisappear() {
        if styleMask.contains(.titled) {
            if titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) == nil {
                addTitlebarAccessoryViewController(resetZoomAccessory)
            }
        }
    }

    // MARK: Tab Key Equivalents

    var keyEquivalent: String? {
        didSet {
            defer {
                NotificationCenter.default.post(name: Self.terminalSidebarMetadataDidChangeNotification, object: self)
            }

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

    override var title: String {
        didSet {
            // Whenever we change the window title we must also update our
            // tab title if we're using custom fonts.
            tab.attributedTitle = attributedTitle
            /// We also needs to update this here, just in case
            /// the value is not what we want
            ///
            /// Check ``titlebarFont`` down below
            /// to see why we need to check `hasMoreThanOneTabs` here
            titlebarTextField?.usesSingleLineMode = !hasMoreThanOneTabs
            NotificationCenter.default.post(name: Self.terminalTitleDidChangeNotification, object: self)
        }
    }

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
            /// We check `hasMoreThanOneTabs` here because the system
            /// may copy this setting to the tab’s text field at some point(e.g. entering/exiting fullscreen),
            /// which can cause the title to be vertically misaligned (shifted downward).
            ///
            /// This behaviour is the opposite of what happens in the title bar’s text field, which is quite odd...
            titlebarTextField?.usesSingleLineMode = !hasMoreThanOneTabs
            tab.attributedTitle = attributedTitle
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
        guard let titlebarFont = titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
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

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else { return }
        defer { updateColorSchemeForSurfaceTree() }

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        //
        // Also check if the user has overridden transparency to be fully opaque.
        let forceOpaque = terminalController?.isBackgroundOpaque ?? false
        if !styleMask.contains(.fullScreen) &&
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

            let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
            self.backgroundColor = backgroundColor.withAlphaComponent(1)
        }

        syncSidebarAppearance()
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let surface = preferredAppearanceSurface {
            let backgroundColor = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
            let alpha = surface.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
            return NSColor(backgroundColor).withAlphaComponent(alpha)
        }

        let alpha = derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
        return derivedConfig.backgroundColor.withAlphaComponent(alpha)
    }

    /// The preferred terminal foreground color that corresponds to `preferredBackgroundColor`.
    var preferredForegroundColor: NSColor? {
        if let surface = preferredAppearanceSurface {
            return NSColor(surface.foregroundColor ?? surface.derivedConfig.foregroundColor)
        }

        return derivedConfig.foregroundColor
    }

    var sidebarTheme: TerminalSidebarTheme {
        TerminalSidebarTheme(
            backgroundColor: preferredBackgroundColor ?? derivedConfig.backgroundColor,
            foregroundColor: preferredForegroundColor ?? derivedConfig.foregroundColor)
    }

    private var preferredAppearanceSurface: Ghostty.SurfaceView? {
        guard let terminalController, !terminalController.surfaceTree.isEmpty else {
            return nil
        }

        // If our focused surface borders the top then we prefer its colors.
        if let focusedSurface = terminalController.focusedSurface,
           let treeRoot = terminalController.surfaceTree.root,
           let focusedNode = treeRoot.node(view: focusedSurface),
           treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
            return focusedSurface
        }

        // If it doesn't border the top, we use the top-left leaf.
        return terminalController.surfaceTree.root?.leftmostLeaf()
    }

    func updateColorSchemeForSurfaceTree() {
        terminalController?.updateColorSchemeForSurfaceTree()
    }

    func setInitialWindowPosition(x: Int16?, y: Int16?) -> Bool {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x = x, let y = y else {
            return false
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            return false
        }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        setFrameOrigin(safeOrigin)
        return true
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
        let foregroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.foregroundColor = NSColor.labelColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.macosTitlebarStyle = .default
            self.windowCornerRadius = 16
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.foregroundColor = NSColor(config.foregroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.macosTitlebarStyle = config.macosTitlebarStyle

            // Set corner radius based on macos-titlebar-style
            // Native, transparent, and hidden styles use 16pt radius
            // Tabs style uses 20pt radius
            switch config.macosTitlebarStyle {
            case .tabs:
                self.windowCornerRadius = 20
            default:
                self.windowCornerRadius = 16
            }
        }
    }
}

private extension NSEvent {
    var isSidebarToggleShortcut: Bool {
        let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard modifierFlags.intersection(shortcutModifiers) == .command else {
            return false
        }

        return charactersIgnoringModifiers?.lowercased() == "b"
    }
}

private final class SidebarTitlebarBackgroundView: NSView {
    weak var hostWindow: TerminalWindow?
    var theme: TerminalSidebarTheme = .fallback {
        didSet { applyTheme() }
    }

    private lazy var newSessionButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = theme.buttonTint
        button.target = self
        button.action = #selector(newSession)
        button.toolTip = sidebarTitlebarTooltip(
            title: "New Tab",
            action: "new_tab")
        button.identifier = NSUserInterfaceItemIdentifier("TerminalSidebarNewSessionButton")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(newSessionButton)
        NSLayoutConstraint.activate([
            newSessionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            newSessionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newSessionButton.widthAnchor.constraint(equalToConstant: 24),
            newSessionButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === newSessionButton ? hitView : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        bounds.fill()

        theme.separator.setFill()
        NSRect(
            x: bounds.maxX - 0.5,
            y: bounds.minY,
            width: 0.5,
            height: bounds.height
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        updateTooltips()
    }

    func updateTooltips() {
        newSessionButton.toolTip = sidebarTitlebarTooltip(
            title: "New Tab",
            action: "new_tab")
    }

    private func applyTheme() {
        newSessionButton.contentTintColor = theme.buttonTint
        needsDisplay = true
    }

    @objc private func newSession() {
        let newController = TerminalSidebarController.newSession(from: hostWindow)
        DispatchQueue.main.async { [weak newController] in
            guard let controller = newController,
                  let focusedSurface = controller.focusedSurface
            else { return }

            controller.focusSurface(focusedSurface)
        }
    }
}

private final class SidebarTitlebarControlsView: NSView {
    weak var hostWindow: TerminalWindow?
    var theme: TerminalSidebarTheme = .fallback {
        didSet { applyTheme() }
    }

    private lazy var splitDownButton = makeButton(
        symbolName: "rectangle.split.1x2",
        title: "Split Down",
        identifier: "TerminalSidebarSplitDownButton",
        action: #selector(splitDown))

    private lazy var splitRightButton = makeButton(
        symbolName: "rectangle.split.2x1",
        title: "Split Right",
        identifier: "TerminalSidebarSplitRightButton",
        action: #selector(splitRight))

    init(hostWindow: TerminalWindow) {
        self.hostWindow = hostWindow
        super.init(frame: .zero)

        let stackView = NSStackView(views: [
            splitDownButton,
            splitRightButton,
        ])
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        applyTheme()
        updateTooltips()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView is NSButton ? hitView : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        updateTooltips()
    }

    func updateTooltips() {
        splitDownButton.toolTip = sidebarTitlebarTooltip(
            title: "Split Down",
            action: "new_split:down")
        splitRightButton.toolTip = sidebarTitlebarTooltip(
            title: "Split Right",
            action: "new_split:right")
    }

    private func makeButton(
        symbolName: String,
        title: String,
        identifier: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = theme.buttonTint
        button.target = self
        button.action = action
        button.toolTip = title
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    private func applyTheme() {
        splitDownButton.contentTintColor = theme.buttonTint
        splitRightButton.contentTintColor = theme.buttonTint
    }

    @objc private func splitDown() {
        hostWindow?.terminalController?.splitDown(self)
    }

    @objc private func splitRight() {
        hostWindow?.terminalController?.splitRight(self)
    }
}

private func sidebarTitlebarTooltip(title: String, action: String) -> String {
    guard
        let appDelegate = NSApp.delegate as? AppDelegate,
        let shortcut = appDelegate.ghostty.config.keyboardShortcut(for: action)
    else {
        return title
    }

    return "\(title) (\(shortcut.description))"
}

private final class SidebarTitlebarResizeHandle: NSView {
    weak var hostWindow: TerminalWindow?
    private var lastMouseX: CGFloat?

    init(hostWindow: TerminalWindow) {
        self.hostWindow = hostWindow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = event.locationInWindow.x
        let previousX = lastMouseX ?? currentX
        lastMouseX = currentX
        hostWindow?.terminalController?.terminalViewContainer?.resizeSidebarFromTitlebar(
            by: currentX - previousX)
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseX = nil
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
    private static let closeTabsOnRightMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.closeTabsOnTheRightMenuItem")
    private static let changeTitleMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.changeTitleMenuItem")
    private static let tabColorSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorSeparator")

    private static let tabColorPaletteIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorPalette")

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

        // Rename Tab
        let changeTitleItem = NSMenuItem(title: "Rename Tab", action: #selector(TerminalWindow.renameTabFromContextMenu(_:)), keyEquivalent: "")
        changeTitleItem.identifier = Self.changeTitleMenuItemIdentifier
        changeTitleItem.target = self
        changeTitleItem.representedObject = target?.window
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

// MARK: - Inline Tab Title Editing

extension TerminalWindow: TabTitleEditorDelegate {
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        canRenameTabFor targetWindow: NSWindow
    ) -> Bool {
        targetWindow.windowController is BaseTerminalController
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        titleFor targetWindow: NSWindow
    ) -> String {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else {
            return targetWindow.title
        }

        return targetController.titleOverride ?? targetWindow.title
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didCommitTitle editedTitle: String,
        for targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.titleOverride = editedTitle.isEmpty ? nil : editedTitle
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        performFallbackRenameFor targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didFinishEditing targetWindow: NSWindow) {
        // After inline editing, the first responder is the window itself.
        // Restore focus to the terminal surface so keyboard input works.
        guard let controller = windowController as? BaseTerminalController,
              let focusedSurface = controller.focusedSurface
        else { return }
        makeFirstResponder(focusedSurface)
    }
}
