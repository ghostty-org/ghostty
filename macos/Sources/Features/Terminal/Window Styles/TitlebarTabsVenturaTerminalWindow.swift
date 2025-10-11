import Cocoa

class TitlebarTabsVenturaTerminalWindow: TitlebarTabsTahoeTerminalWindow {
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
        // if standardWindowButton(.theButton) == nil, the button isn't there, so coalesce to true
        let closeIsHidden = standardWindowButton(.closeButton)?.isHiddenOrHasHiddenAncestor ?? true
        let miniaturizeIsHidden = standardWindowButton(.miniaturizeButton)?.isHiddenOrHasHiddenAncestor ?? true
        let zoomIsHidden = standardWindowButton(.zoomButton)?.isHiddenOrHasHiddenAncestor ?? true
        return !(closeIsHidden && miniaturizeIsHidden && zoomIsHidden)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

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
        resetCustomTabBarViewsIfNoTabsLeft()

        super.becomeKey()

        updateNewTabButtonOpacity()
    }

    override func resignKey() {
        super.resignKey()

        updateNewTabButtonOpacity()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        // We need to be aggressive with this, and it has to be done as well in `update`,
        // otherwise things can get out of sync and flickering can occur.
        updateTabsForVeryDarkBackgrounds()
    }

    override func update() {
        super.update()
        updateTabsForVeryDarkBackgrounds()
        // This is called when we open, close, switch, and reorder tabs, at which point we determine if the
        // first tab in the tab bar is selected. If it is, we make the `windowButtonsBackdrop` color the same
        // as that of the active tab (i.e. the titlebar's background color), otherwise we make it the same
        // color as the background of unselected tabs.
        if let index = windowController?.window?.tabbedWindows?.firstIndex(of: self) {
            windowButtonsBackdrop?.isHighlighted = index == 0
        }

        titlebarSeparatorStyle = .none
        hideToolbarOverflowButton()
        hideTitleBarSeparators()

        if !effectViewIsHidden {
            // By hiding the visual effect view, we allow the window's (or titlebar's in this case)
            // background color to show through. If we were to set `titlebarAppearsTransparent` to true
            // the selected tab would look fine, but the unselected ones and new tab button backgrounds
            // would be an opaque color. When the titlebar isn't transparent, however, the system applies
            // a compositing effect to the unselected tab backgrounds, which makes them blend with the
            // titlebar's/window's background.
            if let effectView = titlebarContainer?.descendants(
                withClassName: "NSVisualEffectView").first
            {
                effectView.isHidden = true
            }

            effectViewIsHidden = true
        }

        updateNewTabButtonOpacity()
        updateNewTabButtonImage()
    }

    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()

        hideToolbarOverflowButton()
        hideTitleBarSeparators()
    }

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

    private var newTabButtonImageLayer: VibrantLayer?

    func updateTabBar() {
        newTabButtonImageLayer = nil
        effectViewIsHidden = false

        // We can only update titlebar tabs if there is a titlebar. Without the
        // styleMask check the app will crash (issue #1876)
        if styleMask.contains(.titled) {
            guard let tabBarAccessoryViewController = titlebarAccessoryViewControllers.first(where: { $0.identifier == Self.tabBarIdentifier}) else { return }
            tabBarAccessoryViewController.layoutAttribute = .right
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
        let fillColor: NSColor = isLightTheme ? .black.withAlphaComponent(0.85) : .white.withAlphaComponent(0.85)
        let newImage = NSImage(size: newTabButtonImage.size, flipped: false) { rect in
            newTabButtonImage.draw(in: rect)
            fillColor.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }

        let imageLayer = newTabButtonImageLayer ?? VibrantLayer(forAppearance: isLightTheme ? .light : .dark)!

        // we need to update its frame each time this's being called
        imageLayer.frame = NSRect(origin: NSPoint(x: newTabButton.bounds.midX - newTabButtonImage.size.width / 2, y: newTabButton.bounds.midY - newTabButtonImage.size.height / 2), size: newTabButtonImage.size)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contents = newImage
        imageLayer.opacity = 0.5

        newTabButtonImageLayer = imageLayer

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

    private var windowButtonsBackdrop: WindowButtonsBackdropView?

    private var windowDragHandle: WindowDragView?

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

    // To be called immediately after the tab bar is disabled.
    private func resetCustomTabBarViewsIfNoTabsLeft() {
        guard let tabGroup = tabGroup, tabGroup.windows.count < 2 else {
            // when there is no tab group, do nothing
            // to avoid edge cases
            // e.g. on Sequoia
            // 1. Open a new window
            // 2. Create 3 tabs
            // 3. Select the second tab
            //
            // without this check, the leading will be inconsistent with the dark first tab
            return
        }
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true

        // Hide the window drag handle.
        windowDragHandle?.isHidden = true
    }

    private func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
        guard windowButtonsBackdrop?.superview != titlebarView else {
            // this can avoid unnecessary flickering
            return
        }
        windowButtonsBackdrop?.removeFromSuperview()
        windowButtonsBackdrop = nil

        let view = WindowButtonsBackdropView(window: self)
        view.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
        titlebarView.addSubview(view)

        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: clipViewLeadingOffset).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true

        windowButtonsBackdrop = view
    }

    private func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
        guard windowDragHandle?.superview != titlebarView.superview else {
            return
        }
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        let view = windowDragHandle ?? WindowDragView()

        view.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
        titlebarView.superview?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true

        windowDragHandle = view
    }

    override var clipViewTopOffset: CGFloat {
        0
    }

    override var clipViewLeadingOffset: CGFloat {
        hasWindowButtons ? 78 : 0
    }

    override func tabBarHeight(with newTabButtonRect: CGRect) -> CGFloat {
        newTabButtonRect.width + 10 // empty title bar height ~= 10
    }

    override func setupTabBar() {
        super.setupTabBar()
        guard
            let titlebarView = getTitlebarView(),
            let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView")
        else {
            resetCustomTabBarViewsIfNoTabsLeft() // remove backdrop and handle
            return
        }
        // HACK: wait a tick before doing anything, to get correct ``hasTabBar`` result
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // this check here can resolve: https://github.com/ghostty-org/ghostty/issues/1691
            // because, when the second last tab was close,
            // the only remaining tab
            //      (presumable created when the window first opened)
            // will have no tab bar when new tab was created.
            // but the moment that second last tab was close, this check was true, which leads us here
            guard hasTabBar else {
                // this reset the tabs which were created later, but closed last
                resetCustomTabBarViewsIfNoTabsLeft() // reset again
                return
            }
            self.addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
            self.addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)
        }
    }
}

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
private class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if event.type == .leftMouseDown, event.clickCount == 1 {
            window?.performDrag(with: event)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
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
private class WindowButtonsBackdropView: NSView {
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

    @available(*, unavailable)
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
