import AppKit
import SwiftUI
import GhosttyKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    private var viewModel = ViewModel()

    /// Reset split zoom button in titlebar
    private let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
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
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // All new windows are based on the app config at the time of creation.
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)

        // If window decorations are disabled, remove our title
        if (!config.windowDecorations) { styleMask.remove(.titled) }

        // Set our window positioning to coordinates if config value exists, otherwise
        // fallback to original centering behavior
        setInitialWindowPosition(
            x: config.windowPositionX,
            y: config.windowPositionY,
            windowDecorations: config.windowDecorations)

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
        }

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable.
        let stackView = NSStackView(views: [keyEquivalentLabel, resetZoomTabButton])
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 3
        tab.accessoryView = stackView

        // Get our saved level
        level = UserDefaults.standard.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

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

    /// Returns true if there is a tab bar visible on this window.
    var hasTabBar: Bool {
        contentView?.firstViewFromRoot(withClassName: "NSTabBar") != nil
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
    }

    private func tabBarDidDisappear() {
        if styleMask.contains(.titled) {
            if titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) == nil {
                addTitlebarAccessoryViewController(resetZoomAccessory)
            }
        }
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
        button.contentTintColor = .controlAccentColor
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
        }
    }

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
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

    private func setInitialWindowPosition(x: Int16?, y: Int16?, windowDecorations: Bool) {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x, let y else {
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

        // Orient based on the top left of the primary monitor
        let frame = screen.visibleFrame
        setFrameOrigin(.init(
            x: frame.minX + CGFloat(x),
            y: frame.maxY - (CGFloat(y) + frame.height)))
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: Config

    struct DerivedConfig {
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons

        init() {
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
        }

        init(_ config: Ghostty.Config) {
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
    }

    struct ResetZoomAccessoryView: View {
        @ObservedObject var viewModel: ViewModel
        let action: () -> Void
        
        // The padding from the top that the view appears. This was all just manually
        // measured based on the OS.
        var topPadding: CGFloat {
            if #available(macOS 26.0, *) {
                return viewModel.hasToolbar ? 10 : 5
            } else {
                return viewModel.hasToolbar ? 9 : 4
            }
        }

        var body: some View {
            if viewModel.isSurfaceZoomed {
                VStack {
                    Button(action: action) {
                        Image("ResetZoom")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Reset Split Zoom")
                    .frame(width: 20, height: 20)
                    Spacer()
                }
                // With a toolbar, the window title is taller, so we need more padding
                // to properly align.
                .padding(.top, topPadding)
                // We always need space at the end of the titlebar
                .padding(.trailing, 10)
            }
        }
    }
}
