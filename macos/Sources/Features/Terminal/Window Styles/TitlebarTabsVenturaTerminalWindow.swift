import Cocoa

/// Titlebar tabs for macOS 13 to 15.
class TitlebarTabsVenturaTerminalWindow: TerminalWindow {
    /// This is used to determine if certain elements should be drawn light or dark and should
    /// be updated whenever the window background color or surrounding elements changes.
    fileprivate var isLightTheme: Bool = false

    lazy var titlebarColor: NSColor = backgroundColor {
        didSet {
            guard let titlebarContainer else { return }
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
        }
    }

    // false if all three traffic lights are missing/hidden, otherwise true
    private var hasWindowButtons: Bool {
        get {
            // if standardWindowButton(.theButton) == nil, the button isn't there, so coalesce to true
            let closeIsHidden = standardWindowButton(.closeButton)?.isHiddenOrHasHiddenAncestor ?? true
            let miniaturizeIsHidden = standardWindowButton(.miniaturizeButton)?.isHiddenOrHasHiddenAncestor ?? true
            let zoomIsHidden = standardWindowButton(.zoomButton)?.isHiddenOrHasHiddenAncestor ?? true
            return !(closeIsHidden && miniaturizeIsHidden && zoomIsHidden)
        }
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // Handle titlebar tabs config option. Something about what we do while setting up the
        // titlebar tabs interferes with the window restore process unless window.tabbingMode
        // is set to .preferred, so we set it, and switch back to automatic as soon as we can.
        tabbingMode = .preferred
        DispatchQueue.main.async {
            self.tabbingMode = .automatic
        }

        titlebarTabs = true

        // Set the background color of the window
        backgroundColor = derivedConfig.backgroundColor

        // This makes sure our titlebar renders correctly when there is a transparent background
        titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
    }

    // We only need to set this once, but need to do it after the window has been created in order
    // to determine if the theme is using a very dark background, in which case we don't want to
    // remove the effect view if the default tab bar is being used since the effect created in
    // `updateTabsForVeryDarkBackgrounds` creates a confusing visual design.
    private var effectViewIsHidden = false

    override func becomeKey() {
        // This is required because the removeTitlebarAccessoryViewController hook does not
        // catch the creation of a new window by "tearing off" a tab from a tabbed window.
        if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
            resetCustomTabBarViews()
        }

        super.becomeKey()

        updateNewTabButtonOpacity()
        resetZoomToolbarButton.contentTintColor = .controlAccentColor
        tab.attributedTitle = attributedTitle
    }

    override func resignKey() {
        super.resignKey()

        updateNewTabButtonOpacity()
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

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)

        // Update our window light/darkness based on our updated background color
        isLightTheme = OSColor(surfaceConfig.backgroundColor).isLightColor

        // Update our titlebar color
        if let preferredBackgroundColor {
            titlebarColor = preferredBackgroundColor
        } else {
            titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
        }

        if (isOpaque) {
            // If there is transparency, calling this will make the titlebar opaque
            // so we only call this if we are opaque.
            updateTabBar()
        }
    }

    // MARK: Tab Bar Styling

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
            guard let tabBarAccessoryViewController = titlebarAccessoryViewControllers.first(where: { $0.identifier == Self.tabBarIdentifier}) else { return }
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

    private lazy var resetZoomToolbarButton: NSButton = generateResetZoomButton()

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
    override var titlebarFont: NSFont? {
        didSet {
            guard let toolbar = toolbar as? TerminalToolbar else { return }
            toolbar.titleFont = titlebarFont ?? .titleBarFont(ofSize: NSFont.systemFontSize)
        }
    }

    // MARK: - Titlebar Tabs

    private var windowButtonsBackdrop: WindowButtonsBackdropView? = nil

    private var windowDragHandle: WindowDragView? = nil

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

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            titleVisibility = .hidden
            if let toolbar = toolbar as? TerminalToolbar {
                toolbar.titleText = title
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
        let isTabBar = self.titlebarTabs && isTabBar(childViewController)

        if (isTabBar) {
            // Ensure it has the right layoutAttribute to force it next to our titlebar
            childViewController.layoutAttribute = .right

            // If we don't set titleVisibility to hidden here, the toolbar will display a
            // "collapsed items" indicator which interferes with the tab bar.
            titleVisibility = .hidden

            // Mark the controller for future reference so we can easily find it. Otherwise
            // the tab bar has no ID by default.
            childViewController.identifier = Self.tabBarIdentifier
        }

        super.addTitlebarAccessoryViewController(childViewController)

        if (isTabBar) {
            pushTabsToTitlebar(childViewController)
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        let isTabBar = titlebarAccessoryViewControllers[index].identifier == Self.tabBarIdentifier
        super.removeTitlebarAccessoryViewController(at: index)
        if (isTabBar) {
            resetCustomTabBarViews()
        }
    }

    // To be called immediately after the tab bar is disabled.
    private func resetCustomTabBarViews() {
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true

        // Hide the window drag handle.
        windowDragHandle?.isHidden = true

        // Reenable the main toolbar title
        if let toolbar = toolbar as? TerminalToolbar {
            toolbar.titleIsHidden = false
        }
    }

    private func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
        // We need a toolbar as a target for our titlebar tabs.
        if (toolbar == nil) {
            generateToolbar()
        }

        // The main title conflicts with titlebar tabs, so hide it
        if let toolbar = toolbar as? TerminalToolbar {
            toolbar.titleIsHidden = true
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
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: hasWindowButtons ? 78 : 0).isActive = true
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
	private weak var terminalWindow: TitlebarTabsVenturaTerminalWindow?
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

    init(window: TitlebarTabsVenturaTerminalWindow) {
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

// MARK: Toolbar

// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.
fileprivate class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    private let titleTextField = CenteredDynamicLabel(labelWithString: "👻 Ghostty")

    var titleText: String {
        get {
            titleTextField.stringValue
        }

        set {
            titleTextField.stringValue = newValue
        }
    }

    var titleFont: NSFont? {
        get {
            titleTextField.font
        }

        set {
            titleTextField.font = newValue
        }
    }

    var titleIsHidden: Bool {
        get {
            titleTextField.isHidden
        }

        set {
            titleTextField.isHidden = newValue
        }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)

        delegate = self
        centeredItemIdentifiers.insert(.titleText)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem

        switch itemIdentifier {
        case .titleText:
            item = NSToolbarItem(itemIdentifier: .titleText)
            item.view = self.titleTextField
            item.visibilityPriority = .user

            // This ensures the title text field doesn't disappear when shrinking the view
            self.titleTextField.translatesAutoresizingMaskIntoConstraints = false
            self.titleTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.titleTextField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            // Add constraints to the toolbar item's view
            NSLayoutConstraint.activate([
                // Set the height constraint to match the toolbar's height
                self.titleTextField.heightAnchor.constraint(equalToConstant: 22), // Adjust as needed
            ])

            item.isEnabled = true
        case .resetZoom:
            item = NSToolbarItem(itemIdentifier: .resetZoom)
        default:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.titleText, .flexibleSpace, .space, .resetZoom]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, two of the
        // built-in spacers plus the un-zoom button item seems to exactly match the space
        // on the left that's reserved for the window buttons.
        return [.flexibleSpace, .titleText, .flexibleSpace]
    }
}

/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
fileprivate class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Configure the text field
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true

        // Use Auto Layout
        translatesAutoresizingMaskIntoConstraints = false

        // Set content hugging and compression resistance priorities
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    // Vertically center the text
    override func draw(_ dirtyRect: NSRect) {
        guard let attributedString = self.attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            super.draw(dirtyRect)
            return
        }

        let textSize = attributedString.size()

        let yOffset = (self.bounds.height - textSize.height) / 2 - 1 // -1 to center it better

        let centeredRect = NSRect(x: self.bounds.origin.x, y: self.bounds.origin.y + yOffset,
                                  width: self.bounds.width, height: textSize.height)

        attributedString.draw(in: centeredRect)
    }
}

extension NSToolbarItem.Identifier {
    static let resetZoom = NSToolbarItem.Identifier("ResetZoom")
    static let titleText = NSToolbarItem.Identifier("TitleText")
}
