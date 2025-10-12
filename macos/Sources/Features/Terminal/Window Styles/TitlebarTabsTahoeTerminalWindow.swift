import AppKit
import SwiftUI

/// `macos-titlebar-style = tabs` for macOS 26 (Tahoe) and later.
///
/// This inherits from transparent styling so that the titlebar matches the background color
/// of the window.
class TitlebarTabsTahoeTerminalWindow: TransparentTitlebarTerminalWindow, NSToolbarDelegate {
    
    /// Titlebar tabs can't support the update accessory because of the way we layout
    /// the native tabs back into the menu bar.
    override var supportsUpdateAccessory: Bool { false }

    deinit {
        tabBarObserver = nil
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        // We must hide the title since we're going to be moving tabs into
        // the titlebar which have their own title.
        titleVisibility = .hidden

        // Create a toolbar
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
    }

    override func becomeMain() {
        super.becomeMain()

        // Check if we have a tab bar and set it up if we have to. See the comment
        // on this function to learn why we need to check this here.
        setupTabBar()
    }

    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        // If this is the tab bar then we need to set it up for the titlebar
        guard isTabBar(childViewController) else {
            // After dragging a tab into a new window, `hasTabBar` needs to be
            // updated to properly review window title
            viewModel.hasTabBar = false
            switch childViewController.ghosttyAccessoryType {
            case .update:
                /// see ``TitlebarTabsTahoeTerminalWindow/supportsUpdateAccessory``
                break
            case .resetZoom, .none:
                // since we've already included resetZoom button in the custom titlebar,
                // we skip add this kind of accessory
                break
            }

            setupCustomTitlebar(windowButtonsWidth: clipViewLeadingOffset)
            return
        }

        // When an existing tab is being dragged in to another tab group,
        // system will also try to add tab bar to this window, so we want to reset observer,
        // to put tab bar where we want again
        tabBarObserver = nil
        
        // Some setup needs to happen BEFORE it is added, such as layout. If
        // we don't do this before the call below, we'll trigger an AppKit
        // assertion.
        childViewController.layoutAttribute = .right

        super.addTitlebarAccessoryViewController(childViewController)

        // Setup the tab bar to go into the titlebar.
        DispatchQueue.main.async {
            // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
            // If we don't do this then on launch windows with restored state with tabs will end
            // up with messed up tab bars that don't show all tabs.
            self.setupTabBar()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        guard let childViewController = titlebarAccessoryViewControllers[safe: index],
                isTabBar(childViewController) else {
            super.removeTitlebarAccessoryViewController(at: index)
            return
        }

        super.removeTitlebarAccessoryViewController(at: index)

        removeTabBar()
    }

    // MARK: Tab Bar Setup

    /// NSTitlebarAccessoryClipView top offset relative to NSToolbarView, used in ``TitlebarTabsTahoeTerminalWindow/setupTabBar()``
    ///
    /// and override by ``TitlebarTabsVenturaTerminalWindow/clipViewTopOffset``
    var clipViewTopOffset: CGFloat {
        2
    }

    /// NSTitlebarAccessoryClipView leading offset relative to NSToolbarView, used in ``TitlebarTabsTahoeTerminalWindow/setupTabBar()``
    ///
    /// and override by ``TitlebarTabsVenturaTerminalWindow/clipViewLeadingOffset``
    var clipViewLeadingOffset: CGFloat {
        // The padding for the tab bar. If we're showing window buttons then
        // we need to offset the window buttons.
        let leftPadding: CGFloat = switch(self.derivedConfig.macosWindowButtons) {
        case .hidden: 0
        case .visible: 70
        }
        return leftPadding
    }

    /// Used in ``TitlebarTabsTahoeTerminalWindow/setupTabBar()``
    ///
    /// and override by ``TitlebarTabsVenturaTerminalWindow/tabBarHeight(with:)``
    func tabBarHeight(with newTabButtonRect: CGRect) -> CGFloat {
        newTabButtonRect.width
    }

    private var tabBarObserver: NSObjectProtocol? {
        didSet {
            // When we change this we want to clear our old observer
            guard let oldValue else { return }
            NotificationCenter.default.removeObserver(oldValue)
        }
    }

    /// Take the NSTabBar that is on the window and convert it into titlebar tabs.
    ///
    /// Let me explain more background on what is happening here. When a tab bar is created, only the
    /// main window actually has an NSTabBar. When an NSWindow in the tab group gains main, AppKit
    /// creates/moves (unsure which) the NSTabBar for it and shows it. When it loses main, the tab bar
    /// is removed from the view hierarchy.
    ///
    /// We can't reliably detect this via `addTitlebarAccessoryViewController` because AppKit
    /// creates an accessory view controller for every window in the tab group, but only attaches
    /// the actual NSTabBar to the main window's accessory view.
    ///
    /// The best way I've found to detect this is to search for and setup the tab bar anytime the
    /// window gains focus. There are probably edge cases to check but to resolve all this I made
    /// this function which is idempotent to call.
    ///
    /// There are more scenarios to look out for and they're documented within the method.
    func setupTabBar() {
        // We only want to setup the observer once
        guard tabBarObserver == nil else { return }
        guard let tabBar = getTabBar() else { return }

        // View model updates must happen on their own ticks.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.hasTabBar = true
        }

        // Find our clip view
        guard let clipView = tabBar.firstSuperview(withClassName: "NSTitlebarAccessoryClipView") else { return }
        guard let accessoryView = clipView.subviews[safe: 0] else { return }
        guard let titlebarView = getTitlebarView() else { return }
        guard let toolbarView = titlebarView.firstDescendant(withClassName: "NSToolbarView") else { return }
        
        // Make sure tabBar's height won't be stretched
        guard let newTabButton = titlebarView.firstDescendant(withClassName: "NSTabBarNewTabButton") else { return }
        tabBar.frame.size.height = tabBarHeight(with: newTabButton.frame)

        // The container is the view that we'll constrain our tab bar within.
        let container = toolbarView

        // Constrain the accessory clip view (the parent of the accessory view
        // usually that clips the children) to the container view.
        clipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false

        // Setup all our constraints
        NSLayoutConstraint.activate([
            clipView.leftAnchor.constraint(equalTo: container.leftAnchor, constant: clipViewLeadingOffset),
            clipView.rightAnchor.constraint(equalTo: container.rightAnchor),
            clipView.topAnchor.constraint(equalTo: container.topAnchor, constant: clipViewTopOffset),
            clipView.heightAnchor.constraint(equalTo: container.heightAnchor),
            accessoryView.leftAnchor.constraint(equalTo: clipView.leftAnchor),
            accessoryView.rightAnchor.constraint(equalTo: clipView.rightAnchor),
            accessoryView.topAnchor.constraint(equalTo: clipView.topAnchor),
            accessoryView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])

        clipView.needsLayout = true
        accessoryView.needsLayout = true

        // Setup an observer for the NSTabBar frame. When system appearance changes or
        // other events occur, the tab bar can resize and clear our constraints. When this
        // happens, we need to remove our custom constraints and re-apply them once the
        // tab bar has proper dimensions again to avoid constraint conflicts.
        tabBar.postsFrameChangedNotifications = true
        tabBarObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: tabBar,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }

            // Remove the observer so we can call setup again.
            self.tabBarObserver = nil

            // Wait a tick to let the new tab bars appear and then set them up.
            DispatchQueue.main.async {
                self.setupTabBar()
            }
        }
    }

    func removeTabBar() {
        // View model needs to be updated on another tick because it
        // triggers view updates.
        DispatchQueue.main.async {
            self.viewModel.hasTabBar = false
        }

        // Clear our observations
        self.tabBarObserver = nil
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        return NSToolbarItem(itemIdentifier: itemIdentifier)
    }
}
