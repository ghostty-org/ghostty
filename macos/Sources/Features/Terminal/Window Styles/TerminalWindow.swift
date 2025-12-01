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

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()
    
    /// Update notification UI in titlebar
    private let updateAccessory = NSTitlebarAccessoryViewController()
    
    /// Visual indicator that mirrors the selected tab color.
    private let tabColorIndicator = TabColorIndicator()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()
    private var tabMenuObserver: NSObjectProtocol? = nil
    private var tabColorSelection: TabColor = .none {
        didSet { tabColorIndicator.tabColor = tabColorSelection }
    }
    
    /// Whether this window supports the update accessory. If this is false, then views within this
    /// window should determine how to show update notifications.
    var supportsUpdateAccessory: Bool {
        // Native window supports it.
        true
    }

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    func display(tabColor: TabColor) {
        tabColorSelection = tabColor
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

        tabMenuObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: "NSMenuWillOpenNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
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
        if (!config.windowDecorations) { styleMask.remove(.titled) }

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
        }

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable.
        tabColorIndicator.translatesAutoresizingMaskIntoConstraints = false
        tabColorIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        tabColorIndicator.heightAnchor.constraint(equalToConstant: 4).isActive = true
        tabColorIndicator.tabColor = tabColorSelection

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
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
    }

    override func becomeMain() {
        super.becomeMain()

        // Its possible we miss the accessory titlebar call so we check again
        // whenever the window becomes main. Both of these are idempotent.
        if hasTabBar {
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

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs (issue #1902)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // Tab bar is attached as a titlebar accessory view controller (layout bottom). We
        // can detect when it is shown or hidden by overriding add/remove and searching for
        // it. This has been verified to work on macOS 12 to 26
        if isTabBar(childViewController) {
            childViewController.identifier = Self.tabBarIdentifier
            tabBarDidAppear()
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

    private static let closeTabsOnRightMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.closeTabsOnTheRightMenuItem")
    private static let tabColorSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorSeparator")
    private static let tabColorHeaderIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorHeader")
    private static let tabColorPaletteIdentifier = NSUserInterfaceItemIdentifier("com.mitchellh.ghostty.tabColorPalette")

    func findTitlebarView() -> NSView? {
        // Find our tab bar. If it doesn't exist we don't do anything.
        //
        // In normal window, `NSTabBar` typically appears as a subview of `NSTitlebarView` within `NSThemeFrame`.
        // In fullscreen, the system creates a dedicated fullscreen window and the view hierarchy changes;
        // in that case, the `titlebarView` is only accessible via a reference on `NSThemeFrame`.
        // ref: https://github.com/mozilla-firefox/firefox/blob/054e2b072785984455b3b59acad9444ba1eeffb4/widget/cocoa/nsCocoaWindow.mm#L7205
        guard let themeFrameView = contentView?.rootView else { return nil }
        let titlebarView = if themeFrameView.responds(to: Selector(("titlebarView"))) {
            themeFrameView.value(forKey: "titlebarView") as? NSView
        } else {
            NSView?.none
        }
        return titlebarView
    }

    func findTabBar() -> NSView? {
        findTitlebarView()?.firstDescendant(withClassName: "NSTabBar")
    }

    /// Returns true if there is a tab bar visible on this window.
    var hasTabBar: Bool {
        findTabBar() != nil
    }

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

    private func configureTabContextMenuIfNeeded(_ menu: NSMenu) {
        guard isTabContextMenu(menu) else { return }
        removeTabColorSection(from: menu)

        if let existing = menu.items.first(where: { $0.identifier == Self.closeTabsOnRightMenuItemIdentifier }) {
            menu.removeItem(existing)
        }
        guard let terminalController else { return }

        let title = NSLocalizedString("Close Tabs on the Right", comment: "Tab context menu option")
        let item = NSMenuItem(title: title, action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        item.identifier = Self.closeTabsOnRightMenuItemIdentifier
        item.target = terminalController
        item.isEnabled = true

        let closeOtherIndex = menu.items.firstIndex(where: { menuItem in
            guard let action = menuItem.action else { return false }
            let name = NSStringFromSelector(action).lowercased()
            return name.contains("close") && name.contains("other") && name.contains("tab")
        })

        let closeThisIndex = menu.items.firstIndex(where: { menuItem in
            guard let action = menuItem.action else { return false }
            let name = NSStringFromSelector(action).lowercased()
            return name.contains("close") && name.contains("tab")
        })

        let insertionIndex: Int
        if let idx = closeOtherIndex {
            insertionIndex = idx + 1
            menu.insertItem(item, at: insertionIndex)
        } else if let idx = closeThisIndex {
            insertionIndex = idx + 1
            menu.insertItem(item, at: insertionIndex)
        } else {
            menu.addItem(item)
            insertionIndex = menu.items.count - 1
        }

        insertTabColorSection(into: menu, startingAt: insertionIndex + 1)
    }

    private func isTabContextMenu(_ menu: NSMenu) -> Bool {
        guard NSApp.keyWindow === self else { return false }
        let selectorNames = menu.items.compactMap { $0.action }.map { NSStringFromSelector($0).lowercased() }
        return selectorNames.contains { $0.contains("close") && $0.contains("tab") }
    }

    private func removeTabColorSection(from menu: NSMenu) {
        let identifiers: Set<NSUserInterfaceItemIdentifier> = [
            Self.tabColorSeparatorIdentifier,
            Self.tabColorHeaderIdentifier,
            Self.tabColorPaletteIdentifier
        ]

        for (index, item) in menu.items.enumerated().reversed() {
            guard let identifier = item.identifier else { continue }
            if identifiers.contains(identifier) {
                menu.removeItem(at: index)
            }
        }
    }

    private func insertTabColorSection(into menu: NSMenu, startingAt index: Int) {
        guard let terminalController else { return }

        var insertionIndex = index

        let separator = NSMenuItem.separator()
        separator.identifier = Self.tabColorSeparatorIdentifier
        menu.insertItem(separator, at: insertionIndex)
        insertionIndex += 1

        let headerTitle = NSLocalizedString("Tab Color", comment: "Tab color context menu section title")
        let headerItem = NSMenuItem()
        headerItem.identifier = Self.tabColorHeaderIdentifier
        headerItem.title = headerTitle
        headerItem.isEnabled = false
        menu.insertItem(headerItem, at: insertionIndex)
        insertionIndex += 1

        let paletteItem = NSMenuItem()
        paletteItem.identifier = Self.tabColorPaletteIdentifier
        let paletteView = TabColorPaletteView(
            selectedColor: tabColorSelection
        ) { [weak terminalController] color in
            terminalController?.setTabColor(color)
        }
        paletteItem.view = paletteView
        menu.insertItem(paletteItem, at: insertionIndex)
    }


    // MARK: Tab Key Equivalents

    var keyEquivalent: String? = nil {
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
        button.image = NSImage(named:"ResetZoom")
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

        // Basic properties
        appearance = surfaceConfig.windowAppearance
        hasShadow = surfaceConfig.macosWindowShadow

        // Window transparency only takes effect if our window is not native fullscreen.
        // In native fullscreen we disable transparency/opacity because the background
        // becomes gray and widgets show through.
        if !styleMask.contains(.fullScreen) &&
            surfaceConfig.backgroundOpacity < 1
        {
            isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            backgroundColor = .white.withAlphaComponent(0.001)

            if let appDelegate = NSApp.delegate as? AppDelegate {
                ghostty_set_window_background_blur(
                    appDelegate.ghostty.app,
                    Unmanaged.passUnretained(self).toOpaque())
            }
        } else {
            isOpaque = true

            let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
            self.backgroundColor = backgroundColor.withAlphaComponent(1)
        }
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

    private func setInitialWindowPosition(x: Int16?, y: Int16?) {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard x != nil, y != nil else {
            if (!LastWindowPosition.shared.restore(self)) {
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
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
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

extension TerminalWindow {
    enum TabColor: Int, CaseIterable {
        case none
        case blue
        case purple
        case pink
        case red
        case orange
        case yellow
        case green
        case teal
        case graphite

        static let paletteRows: [[TabColor]] = [
            [.none, .blue, .purple, .pink, .red],
            [.orange, .yellow, .green, .teal, .graphite],
        ]

        var localizedName: String {
            switch self {
            case .none:
                return NSLocalizedString("None", comment: "Tab color option label")
            case .blue:
                return NSLocalizedString("Blue", comment: "Tab color option label")
            case .purple:
                return NSLocalizedString("Purple", comment: "Tab color option label")
            case .pink:
                return NSLocalizedString("Pink", comment: "Tab color option label")
            case .red:
                return NSLocalizedString("Red", comment: "Tab color option label")
            case .orange:
                return NSLocalizedString("Orange", comment: "Tab color option label")
            case .yellow:
                return NSLocalizedString("Yellow", comment: "Tab color option label")
            case .green:
                return NSLocalizedString("Green", comment: "Tab color option label")
            case .teal:
                return NSLocalizedString("Teal", comment: "Tab color option label")
            case .graphite:
                return NSLocalizedString("Graphite", comment: "Tab color option label")
            }
        }

        var displayColor: NSColor? {
            switch self {
            case .none:
                return nil
            case .blue:
                return .systemBlue
            case .purple:
                return .systemPurple
            case .pink:
                return .systemPink
            case .red:
                return .systemRed
            case .orange:
                return .systemOrange
            case .yellow:
                return .systemYellow
            case .green:
                return .systemGreen
            case .teal:
                if #available(macOS 13.0, *) {
                    return .systemMint
                } else {
                    return .systemTeal
                }
            case .graphite:
                return .systemGray
            }
        }

        func swatchImage(selected: Bool) -> NSImage {
            let size = NSSize(width: 18, height: 18)
            return NSImage(size: size, flipped: false) { rect in
                let circleRect = rect.insetBy(dx: 1, dy: 1)
                let circlePath = NSBezierPath(ovalIn: circleRect)

                if let fillColor = self.displayColor {
                    fillColor.setFill()
                    circlePath.fill()
                } else {
                    NSColor.clear.setFill()
                    circlePath.fill()
                    NSColor.quaternaryLabelColor.setStroke()
                    circlePath.lineWidth = 1
                    circlePath.stroke()
                }

                if self == .none {
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.minY + 2))
                    slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.maxY - 2))
                    slash.lineWidth = 1.5
                    NSColor.secondaryLabelColor.setStroke()
                    slash.stroke()
                }

                if selected {
                    let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                    highlight.lineWidth = 2
                    NSColor.controlAccentColor.setStroke()
                    highlight.stroke()
                }

                return true
            }
        }
    }
}

private final class TabColorIndicator: NSView {
    var tabColor: TerminalWindow.TabColor = .none {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2

        if let color = tabColor.displayColor {
            alphaValue = 1
            layer.backgroundColor = color.cgColor
            layer.borderWidth = 0
            layer.borderColor = nil
        } else {
            alphaValue = 0
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }
}

private final class TabColorPaletteView: NSView {
    private let stackView = NSStackView()
    private var selectedColor: TerminalWindow.TabColor
    private let selectionHandler: (TerminalWindow.TabColor) -> Void
    private var buttons: [NSButton] = []

    init(selectedColor: TerminalWindow.TabColor,
         selectionHandler: @escaping (TerminalWindow.TabColor) -> Void) {
        self.selectedColor = selectedColor
        self.selectionHandler = selectionHandler
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 180, height: 60)))

        stackView.orientation = .vertical
        stackView.spacing = 6
        addSubview(stackView)

        for row in TerminalWindow.TabColor.paletteRows {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 6

            for color in row {
                let button = makeButton(for: color)
                rowStack.addArrangedSubview(button)
                buttons.append(button)
            }

            stackView.addArrangedSubview(rowStack)
        }

        translatesAutoresizingMaskIntoConstraints = true
        setFrameSize(intrinsicContentSize)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 190, height: 70)
    }

    override func layout() {
        super.layout()
        stackView.frame = bounds.insetBy(dx: 10, dy: 6)
    }

    private func makeButton(for color: TerminalWindow.TabColor) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = color.swatchImage(selected: color == selectedColor)
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.focusRingType = .none
        button.target = self
        button.action = #selector(onSelectColor(_:))
        button.tag = color.rawValue
        button.toolTip = color.localizedName

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])

        return button
    }

    @objc private func onSelectColor(_ sender: NSButton) {
        guard let color = TerminalWindow.TabColor(rawValue: sender.tag) else { return }
        selectedColor = color
        updateButtonImages()
        selectionHandler(color)
    }

    private func updateButtonImages() {
        for button in buttons {
            guard let color = TerminalWindow.TabColor(rawValue: button.tag) else { continue }
            button.image = color.swatchImage(selected: color == selectedColor)
        }
    }
}
