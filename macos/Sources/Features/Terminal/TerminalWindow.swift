import Cocoa

class TerminalWindow: NSWindow {
    @objc dynamic var keyEquivalent: String = ""

    /// This is used to determine if certain elements should be drawn light or dark and should
    /// be updated whenever the window background color or surrounding elements changes.
    var isLightTheme: Bool = false

    lazy var titlebarColor: NSColor = backgroundColor {
        didSet {
            guard let titlebarContainer else { return }
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
        }
    }

    private lazy var keyEquivalentLabel: NSTextField = {
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
        label.postsFrameChangedNotifications = true

        return label
    }()

    private lazy var bindings = [
        observe(\.surfaceIsZoomed, options: [.initial, .new]) { [weak self] window, _ in
            guard let tabGroup = self?.tabGroup else { return }

            self?.resetZoomTabButton.isHidden = !window.surfaceIsZoomed
            self?.updateResetZoomTitlebarButtonVisibility()
        },

        observe(\.keyEquivalent, options: [.initial, .new]) { [weak self] window, _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: window.isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let attributedString = NSAttributedString(string: " \(window.keyEquivalent) ", attributes: attributes)

            self?.keyEquivalentLabel.attributedStringValue = attributedString
        },
    ]

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    // MARK: - Lifecycle

    override func awakeFromNib() {
        super.awakeFromNib()

		_ = bindings

        // Create the tab accessory view that houses the key-equivalent label and optional un-zoom button
        let stackView = NSStackView(views: [keyEquivalentLabel, resetZoomTabButton])
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 3
        tab.accessoryView = stackView

		if titlebarTabs {
			generateToolbar()
		}
    }

    deinit {
        bindings.forEach() { $0.invalidate() }
    }

    // MARK: Titlebar Helpers
    // These helpers are generic to what we're trying to achieve (i.e. titlebar
    // style tabs, titlebar styling, etc.). They're just here to make it easier.

    private var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            guard let view = contentView?.superview ?? contentView else { return nil }
            return titlebarContainerView(in: view)
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            guard let view = window.contentView else { continue }
            return titlebarContainerView(in: view)
        }

        return nil
    }

    private func titlebarContainerView(in view: NSView) -> NSView? {
        if view.className == "NSTitlebarContainerView" {
            return view
        }

        for subview in view.subviews {
            if let found = titlebarContainerView(in: subview) {
                return found
            }
        }

        return nil
    }

    // MARK: - NSWindow

    override var title: String {
        didSet {
            tab.attributedTitle = attributedTitle
        }
    }

    // We override this so that with the hidden titlebar style the titlebar
    // area is not draggable.
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect

        // If we are using a hidden titlebar style, the content layout is the
        // full frame making it so that it is not draggable.
        if let controller = windowController as? TerminalController,
              controller.derivedConfig.macosTitlebarStyle == "hidden" {
            rect.origin.y = 0
            rect.size.height = self.frame.height
        }
        return rect
    }

    // The window theme configuration from Ghostty. This is used to control some
    // behaviors that don't look quite right in certain situations.
    var windowTheme: TerminalWindowTheme?

    // We only need to set this once, but need to do it after the window has been created in order
    // to determine if the theme is using a very dark background, in which case we don't want to
    // remove the effect view if the default tab bar is being used since the effect created in
    // `updateTabsForVeryDarkBackgrounds` creates a confusing visual design.
    private var effectViewIsHidden = false

    override func becomeKey() {
        // This is required because the removeTitlebarAccessoryViewController hook does not
        // catch the creation of a new window by "tearing off" a tab from a tabbed window.
        if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
            hideCustomTabBarViews()
        }

        super.becomeKey()

        updateNewTabButtonOpacity()
        resetZoomTabButton.contentTintColor = .controlAccentColor
        resetZoomToolbarButton.contentTintColor = .controlAccentColor
        tab.attributedTitle = attributedTitle
    }

    override func resignKey() {
        super.resignKey()

        updateNewTabButtonOpacity()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
        resetZoomToolbarButton.contentTintColor = .tertiaryLabelColor
        tab.attributedTitle = attributedTitle
    }

	override func layoutIfNeeded() {
		super.layoutIfNeeded()

		guard titlebarTabs else { return }

		// We need to be aggressive with this, and it has to be done as well in `update`,
		// otherwise things can get out of sync and flickering can occur.
		updateTabsForVeryDarkBackgrounds()
	}

    override func update() {
        super.update()

        if titlebarTabs {
            updateTabsForVeryDarkBackgrounds()
            // This is called when we open, close, switch, and reorder tabs, at which point we determine if the
            // first tab in the tab bar is selected. If it is, we make the `windowButtonsBackdrop` color the same
            // as that of the active tab (i.e. the titlebar's background color), otherwise we make it the same
            // color as the background of unselected tabs.
            if let index = windowController?.window?.tabbedWindows?.firstIndex(of: self) {
                windowButtonsBackdrop?.isHighlighted = index == 0
            }
        }

        updateResetZoomTitlebarButtonVisibility()

        // The remainder of this function only applies to styled tabs.
        guard hasStyledTabs else { return }

		titlebarSeparatorStyle = tabbedWindows != nil && !titlebarTabs ? .line : .none
        if titlebarTabs {
            hideToolbarOverflowButton()
            hideTitleBarSeparators()
        }

		if !effectViewIsHidden {
			// By hiding the visual effect view, we allow the window's (or titlebar's in this case)
			// background color to show through. If we were to set `titlebarAppearsTransparent` to true
			// the selected tab would look fine, but the unselected ones and new tab button backgrounds
			// would be an opaque color. When the titlebar isn't transparent, however, the system applies
			// a compositing effect to the unselected tab backgrounds, which makes them blend with the
			// titlebar's/window's background.
			if let effectView = titlebarContainer?.descendants(
                withClassName: "NSVisualEffectView").first {
				effectView.isHidden = titlebarTabs || !titlebarTabs && !hasVeryDarkBackground
			}

			effectViewIsHidden = true
		}

        updateNewTabButtonOpacity()
        updateNewTabButtonImage()
    }

    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()

        if titlebarTabs {
            hideToolbarOverflowButton()
            hideTitleBarSeparators()
        }
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        if let controller = self.windowController as? TerminalController {
            // It takes an event loop cycle to merge all the windows so we set a
            // short timer to relabel the tabs (issue #1902)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }
        }
    }

    // MARK: - Tab Bar Styling

    // This is true if we should apply styles to the titlebar or tab bar.
    var hasStyledTabs: Bool {
        // If we have titlebar tabs then we always style.
        guard !titlebarTabs else { return true }

        // We style the tabs if they're transparent
        return transparentTabs
    }

    // Set to true if the background color should bleed through the titlebar/tab bar.
    // This only applies to non-titlebar tabs.
    var transparentTabs: Bool = false

    var hasVeryDarkBackground: Bool {
        backgroundColor.luminance < 0.05
    }

    private var newTabButtonImageLayer: VibrantLayer? = nil

    func updateTabBar() {
        newTabButtonImageLayer = nil
        effectViewIsHidden = false

        // We can only update titlebar tabs if there is a titlebar. Without the
        // styleMask check the app will crash (issue #1876)
        if titlebarTabs && styleMask.contains(.titled) {
            guard let tabBarAccessoryViewController = titlebarAccessoryViewControllers.first(where: { $0.identifier == Self.TabBarController}) else { return }

            tabBarAccessoryViewController.layoutAttribute = .right
            pushTabsToTitlebar(tabBarAccessoryViewController)
        }
    }

    // Since we are coloring the new tab button's image, it doesn't respond to the
    // window's key status changes in terms of becoming less prominent visually,
    // so we need to do it manually.
    private func updateNewTabButtonOpacity() {
        guard let newTabButton: NSButton = titlebarContainer?.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
        guard let newTabButtonImageView: NSImageView = newTabButton.subviews.first(where: {
            $0 as? NSImageView != nil
        }) as? NSImageView else { return }

        newTabButtonImageView.alphaValue = isKeyWindow ? 1 : 0.5
    }

	// Color the new tab button's image to match the color of the tab title/keyboard shortcut labels,
	// just as it does in the stock tab bar.
	private func updateNewTabButtonImage() {
		guard let newTabButton: NSButton = titlebarContainer?.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
		guard let newTabButtonImageView: NSImageView = newTabButton.subviews.first(where: {
			$0 as? NSImageView != nil
		}) as? NSImageView else { return }
        guard let newTabButtonImage = newTabButtonImageView.image else { return }


        if newTabButtonImageLayer == nil {
			let fillColor: NSColor = isLightTheme ? .black.withAlphaComponent(0.85) : .white.withAlphaComponent(0.85)
			let newImage = NSImage(size: newTabButtonImage.size, flipped: false) { rect in
				newTabButtonImage.draw(in: rect)
				fillColor.setFill()
				rect.fill(using: .sourceAtop)
				return true
			}
			let imageLayer = VibrantLayer(forAppearance: isLightTheme ? .light : .dark)!
			imageLayer.frame = NSRect(origin: NSPoint(x: newTabButton.bounds.midX - newTabButtonImage.size.width/2, y: newTabButton.bounds.midY - newTabButtonImage.size.height/2), size: newTabButtonImage.size)
			imageLayer.contentsGravity = .resizeAspect
			imageLayer.contents = newImage
			imageLayer.opacity = 0.5

			newTabButtonImageLayer = imageLayer
		}

        newTabButtonImageView.isHidden = true
        newTabButton.layer?.sublayers?.first(where: { $0.className == "VibrantLayer" })?.removeFromSuperlayer()
        newTabButton.layer?.addSublayer(newTabButtonImageLayer!)
	}

	private func updateTabsForVeryDarkBackgrounds() {
		guard hasVeryDarkBackground else { return }
        guard let titlebarContainer else { return }

		if let tabGroup = tabGroup, tabGroup.isTabBarVisible {
			guard let activeTabBackgroundView = titlebarContainer.firstDescendant(withClassName: "NSTabButton")?.superview?.subviews.last?.firstDescendant(withID: "_backgroundView")
			else { return }

			activeTabBackgroundView.layer?.backgroundColor = titlebarColor.cgColor
			titlebarContainer.layer?.backgroundColor = titlebarColor.highlight(withLevel: 0.14)?.cgColor
		} else {
			titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
		}
	}

    // MARK: - Split Zoom Button

    @objc dynamic var surfaceIsZoomed: Bool = false

    private lazy var resetZoomToolbarButton: NSButton = generateResetZoomButton()

    private lazy var resetZoomTabButton: NSButton = {
        let button = generateResetZoomButton()
        button.action = #selector(selectTabAndZoom(_:))
        return button
    }()

    private lazy var resetZoomTitlebarAccessoryViewController: NSTitlebarAccessoryViewController? = {
        guard let titlebarContainer else { return nil }
        let size = NSSize(width: titlebarContainer.bounds.height, height: titlebarContainer.bounds.height)
        let view = NSView(frame: NSRect(origin: .zero, size: size))

        let button = generateResetZoomButton()
        button.frame.origin.x = size.width/2 - button.bounds.width/2
        button.frame.origin.y = size.height/2 - button.bounds.height/2
        view.addSubview(button)

        let titlebarAccessoryViewController = NSTitlebarAccessoryViewController()
        titlebarAccessoryViewController.view = view
        titlebarAccessoryViewController.layoutAttribute = .right

        return titlebarAccessoryViewController
    }()

    private func updateResetZoomTitlebarButtonVisibility() {
        guard let tabGroup, let resetZoomTitlebarAccessoryViewController else { return }

		let isHidden = tabGroup.isTabBarVisible ? true : !surfaceIsZoomed

		if titlebarTabs {
			resetZoomToolbarButton.isHidden = isHidden

			for (index, vc) in titlebarAccessoryViewControllers.enumerated() {
				guard vc == resetZoomTitlebarAccessoryViewController else { return }
				removeTitlebarAccessoryViewController(at: index)
			}
		} else {
			if !titlebarAccessoryViewControllers.contains(resetZoomTitlebarAccessoryViewController) {
				addTitlebarAccessoryViewController(resetZoomTitlebarAccessoryViewController)
			}
			resetZoomTitlebarAccessoryViewController.view.isHidden = isHidden
		}
    }

	private func generateResetZoomButton() -> NSButton {
		let button = NSButton()
		button.target = nil
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

	@objc private func selectTabAndZoom(_ sender: NSButton) {
		guard let tabGroup else { return }

		guard let associatedWindow = tabGroup.windows.first(where: {
			guard let accessoryView = $0.tab.accessoryView else { return false }
			return accessoryView.subviews.contains(sender)
		}),
			  let windowController = associatedWindow.windowController as? TerminalController
		else { return }

		tabGroup.selectedWindow = associatedWindow
		windowController.splitZoom(self)
	}

    // MARK: - Titlebar Font

    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
            tab.attributedTitle = attributedTitle

            if let toolbar = toolbar as? TerminalToolbar {
                toolbar.titleFont = font
            }
        }
    }

    // Find the NSTextField responsible for displaying the titlebar's title.
    private var titlebarTextField: NSTextField? {
        guard let titlebarView = titlebarContainer?.subviews
            .first(where: { $0.className == "NSTitlebarView" }) else { return nil }
        return titlebarView.subviews.first(where: { $0 is NSTextField }) as? NSTextField
    }

    // Return a styled representation of our title property.
    private var attributedTitle: NSAttributedString? {
        guard let titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    // MARK: - Titlebar Tabs

    private var windowButtonsBackdrop: WindowButtonsBackdropView? = nil

    private var windowDragHandle: WindowDragView? = nil

    // The tab bar controller ID from macOS
    static private let TabBarController = NSUserInterfaceItemIdentifier("_tabBarController")

    // Used by the window controller to enable/disable titlebar tabs.
    var titlebarTabs = false {
        didSet {
            self.titleVisibility = titlebarTabs ? .hidden : .visible
			if titlebarTabs {
				generateToolbar()
            } else {
                toolbar = nil
            }
        }
    }

    // We have to regenerate a toolbar when the titlebar tabs setting changes since our
    // custom toolbar conditionally generates the items based on this setting. I tried to
    // invalidate the toolbar items and force a refresh, but as far as I can tell that
    // isn't possible.
    func generateToolbar() {
        let terminalToolbar = TerminalToolbar(identifier: "Toolbar")

        toolbar = terminalToolbar
        toolbarStyle = .unifiedCompact
        if let resetZoomItem = terminalToolbar.items.first(where: { $0.itemIdentifier == .resetZoom }) {
            resetZoomItem.view = resetZoomToolbarButton
            resetZoomItem.view!.removeConstraints(resetZoomItem.view!.constraints)
            resetZoomItem.view!.widthAnchor.constraint(equalToConstant: 22).isActive = true
            resetZoomItem.view!.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        updateResetZoomTitlebarButtonVisibility()
    }

    // For titlebar tabs, we want to hide the separator view so that we get rid
    // of an aesthetically unpleasing shadow.
    private func hideTitleBarSeparators() {
        guard let titlebarContainer else { return }
        for v in titlebarContainer.descendants(withClassName: "NSTitlebarSeparatorView") {
            v.isHidden = true
        }
    }


    // HACK: hide the "collapsed items" marker from the toolbar if it's present.
    // idk why it appears in macOS 15.0+ but it does... so... make it go away. (sigh)
    private func hideToolbarOverflowButton() {
        guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
        guard let titlebarView = windowButtonsBackdrop.superview else { return }
        guard titlebarView.className == "NSTitlebarView" else { return }
        guard let toolbarView = titlebarView.subviews.first(where: {
            $0.className == "NSToolbarView"
        }) else { return }

        toolbarView.subviews.first(where: { $0.className == "NSToolbarClippedItemsIndicatorViewer" })?.isHidden = true
    }

    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let isTabBar = self.titlebarTabs && (
            childViewController.layoutAttribute == .bottom ||
            childViewController.identifier == Self.TabBarController
        )

        if (isTabBar) {
            // Ensure it has the right layoutAttribute to force it next to our titlebar
            childViewController.layoutAttribute = .right

            // If we don't set titleVisibility to hidden here, the toolbar will display a
            // "collapsed items" indicator which interferes with the tab bar.
            titleVisibility = .hidden

            // Mark the controller for future reference so we can easily find it. Otherwise
            // the tab bar has no ID by default.
            childViewController.identifier = Self.TabBarController
        }

        super.addTitlebarAccessoryViewController(childViewController)

        if (isTabBar) {
            pushTabsToTitlebar(childViewController)
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        let isTabBar = titlebarAccessoryViewControllers[index].identifier == Self.TabBarController
        super.removeTitlebarAccessoryViewController(at: index)
        if (isTabBar) {
            hideCustomTabBarViews()
        }
    }

    // To be called immediately after the tab bar is disabled.
    private func hideCustomTabBarViews() {
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true

        // Hide the window drag handle.
        windowDragHandle?.isHidden = true
    }

    private func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
        // We need a toolbar as a target for our titlebar tabs.
        if (toolbar == nil) {
            generateToolbar()
        }

        // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
        // If we don't do this then on launch windows with restored state with tabs will end
        // up with messed up tab bars that don't show all tabs.
        DispatchQueue.main.async { [weak self] in
            let accessoryView = tabBarController.view
            guard let accessoryClipView = accessoryView.superview else { return }
            guard let titlebarView = accessoryClipView.superview else { return }
            guard titlebarView.className == "NSTitlebarView" else { return }
            guard let toolbarView = titlebarView.subviews.first(where: {
                $0.className == "NSToolbarView"
            }) else { return }

            self?.addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
            guard let windowButtonsBackdrop = self?.windowButtonsBackdrop else { return }

            self?.addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)

            accessoryClipView.translatesAutoresizingMaskIntoConstraints = false
            accessoryClipView.leftAnchor.constraint(equalTo: windowButtonsBackdrop.rightAnchor).isActive = true
            accessoryClipView.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
            accessoryClipView.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            accessoryClipView.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
            accessoryClipView.needsLayout = true

            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.leftAnchor.constraint(equalTo: accessoryClipView.leftAnchor).isActive = true
            accessoryView.rightAnchor.constraint(equalTo: accessoryClipView.rightAnchor).isActive = true
            accessoryView.topAnchor.constraint(equalTo: accessoryClipView.topAnchor).isActive = true
            accessoryView.heightAnchor.constraint(equalTo: accessoryClipView.heightAnchor).isActive = true
            accessoryView.needsLayout = true

            self?.hideToolbarOverflowButton()
            self?.hideTitleBarSeparators()
        }
    }

    private func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
        windowButtonsBackdrop?.removeFromSuperview()
        windowButtonsBackdrop = nil

        let view = WindowButtonsBackdropView(window: self)
        view.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
        titlebarView.addSubview(view)

        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 78).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true

        windowButtonsBackdrop = view
    }

    private func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        if let view = windowDragHandle {
            view.removeFromSuperview()
            view.isHidden = false
            titlebarView.superview?.addSubview(view)
            view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
            view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
            view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
            return
        }

        let view = WindowDragView()
        view.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
        titlebarView.superview?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true

        windowDragHandle = view
    }

    // This forces this view and all subviews to update layout and redraw. This is
    // a hack (see the caller).
    private func markHierarchyForLayout(_ view: NSView) {
        view.needsUpdateConstraints = true
        view.needsLayout = true
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        for subview in view.subviews {
            markHierarchyForLayout(subview)
        }
    }
}

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
fileprivate class WindowDragView: NSView {
    override public func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if (event.type == .leftMouseDown && event.clickCount == 1) {
            window?.performDrag(with: event)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.disableCursorRects()
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        window?.enableCursorRects()
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// A view that matches the color of selected and unselected tabs in the adjacent tab bar.
fileprivate class WindowButtonsBackdropView: NSView {
    // This must be weak because the window has this view. Otherwise
    // a retain cycle occurs.
	private weak var terminalWindow: TerminalWindow?
	private let isLightTheme: Bool
    private let overlayLayer = VibrantLayer()

    var isHighlighted: Bool = true {
        didSet {
            guard let terminalWindow else { return }

            if isLightTheme {
                overlayLayer.isHidden = isHighlighted
                layer?.backgroundColor = .clear
            } else {
				let systemOverlayColor = NSColor(cgColor: CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.45))!
				let titlebarBackgroundColor = terminalWindow.titlebarColor.blended(withFraction: 1, of: systemOverlayColor)

				let highlightedColor = terminalWindow.hasVeryDarkBackground ? terminalWindow.backgroundColor : .clear
				let backgroundColor = terminalWindow.hasVeryDarkBackground ? titlebarBackgroundColor : systemOverlayColor

                overlayLayer.isHidden = true
				layer?.backgroundColor = isHighlighted ? highlightedColor?.cgColor : backgroundColor?.cgColor
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(window: TerminalWindow) {
		self.terminalWindow = window
        self.isLightTheme = window.isLightTheme

        super.init(frame: .zero)

        wantsLayer = true

        overlayLayer.frame = layer!.bounds
        overlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlayLayer.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.95, alpha: 1)

        layer?.addSublayer(overlayLayer)
    }
}

enum TerminalWindowTheme: String {
    case auto
    case system
    case light
    case dark
}
