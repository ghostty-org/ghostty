import GhosttyKit
import SwiftUI

/// Custom TabManager for the "quick" terminal
class QuickTerminalTabManager: ObservableObject {
    /// All currently open tabs
    @Published var tabs: [QuickTerminalTab] = []
    /// The current tab in focus
    @Published var currentTab: QuickTerminalTab? {
        didSet {
            if let oldTab = oldValue, let oldSurfaceTree = controller?.surfaceTree {
                oldTab.surfaceTree = oldSurfaceTree
            }

            guard let currentTab else { return }

            self.controller?.surfaceTree = currentTab.surfaceTree

            DispatchQueue.main.async {
                // Find the focused surface, or fallback to the first surface (for new tabs)
                let surfaceToFocus = currentTab.surfaceTree.first(where: { $0.focused })
                    ?? currentTab.surfaceTree.first

                if let surface = surfaceToFocus {
                    self.controller?.focusSurface(surface)
                    self.controller?.syncFocusToSurfaceTree()
                }

                // This is the only way I found to force a re-render, and it's still not perfect.
                // I'm getting some artifacts  when switching tabs, characters not rendering correctly,
                // stuff like that.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let surfaceTree = self.controller?.surfaceTree else { return }

                    for surface in surfaceTree {
                        surface.sizeDidChange(surface.bounds.size)
                    }
                }
            }
        }
    }
    /// The current tab being dragged
    @Published var draggedTab: QuickTerminalTab? {
        didSet {
            if draggedTab == nil {
                dropTargetIndex = nil
                draggedTabWidth = nil
            }
        }
    }
    /// The index where a dragged tab will be dropped (for showing placeholder)
    @Published var dropTargetIndex: Int?
    /// The width of the tab being dragged (captured at drag start)
    var draggedTabWidth: CGFloat?

    /// Reference to the "quick" terminal Controller
    weak var controller: QuickTerminalController?


    var currentTabIndex: Int? {
        tabs.firstIndex { $0.id == currentTab?.id }
    }

    /// Access to the Ghostty config for keybinding lookups
    var config: Ghostty.Config? {
        controller?.ghostty.config
    }

    init(controller: QuickTerminalController, restorationState: QuickTerminalRestorableState? = nil) {
        self.controller = controller

        // Check if restoration is enabled
        let shouldRestore = controller.ghostty.config.windowSaveState != "never"

        if shouldRestore,
           let savedState = restorationState,
           !savedState.tabs.isEmpty {
            // Restore tabs from saved state
            for state in savedState.tabs {
                let tab = QuickTerminalTab(surfaceTree: state.surfaceTree, title: state.title)
                tab.titleOverride = state.titleOverride
                tab.tabColor = state.tabColor
                tabs.append(tab)
            }

            // Select the previously current tab
            if savedState.currentTabIndex < tabs.count {
                selectTab(tabs[savedState.currentTabIndex])
            } else if let first = tabs.first {
                selectTab(first)
            }
        } else {
            // No saved state or restoration disabled - create default tab
            addNewTab()
        }
    }

    /// Restores tabs from saved state. This replaces any existing tabs.
    /// - Parameters:
    ///   - tabStates: The saved tab states to restore
    ///   - currentIndex: The index of the tab that should be selected
    func restoreTabs(from tabStates: [QuickTerminalTabState], currentIndex: Int) {
        // Clear existing tabs without triggering close logic
        tabs.removeAll()
        currentTab = nil

        // Restore each tab from state
        for state in tabStates {
            let tab = QuickTerminalTab(surfaceTree: state.surfaceTree, title: state.title)
            tab.titleOverride = state.titleOverride
            tab.tabColor = state.tabColor
            tabs.append(tab)
        }

        // Select the previously current tab
        if currentIndex < tabs.count {
            selectTab(tabs[currentIndex])
        } else if let first = tabs.first {
            selectTab(first)
        }
    }

    // MARK: Methods

    func addNewTab() {
        guard let ghostty = controller?.ghostty else { return }

        let leaf: Ghostty.SurfaceView = .init(ghostty.app!, baseConfig: nil)
        let surfaceTree: SplitTree<Ghostty.SurfaceView> = .init(view: leaf)
        let tabIndex = tabs.count + 1

        let newTab = QuickTerminalTab(surfaceTree: surfaceTree, title: "Terminal \(tabIndex)")
        tabs.append(newTab)

        selectTab(newTab)
    }

    /// Adds an existing surface tree as a new tab in the quick terminal.
    /// Used when moving a tab from a regular terminal window to the quick terminal.
    func addTabWithSurfaceTree(
        _ surfaceTree: SplitTree<Ghostty.SurfaceView>,
        title: String? = nil,
        titleOverride: String? = nil,
        tabColor: TerminalTabColor = .none
    ) {
        let tabIndex = tabs.count + 1
        let newTab = QuickTerminalTab(
            surfaceTree: surfaceTree,
            title: title ?? "Terminal \(tabIndex)"
        )
        newTab.titleOverride = titleOverride
        newTab.tabColor = tabColor
        tabs.append(newTab)
        selectTab(newTab)
    }

    func selectTab(_ tab: QuickTerminalTab) {
        guard currentTab?.id != tab.id else { return }

        currentTab = tab
    }

    func closeTab(_ tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        tabs.remove(at: index)

        if currentTab?.id == tab.id {
            if tabs.isEmpty {
                addNewTab()
                controller?.animateOut()
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectTab(tabs[newIndex])
            }
        }
    }

    func closeAllTabs(except: QuickTerminalTab) {
        let toClose = self.tabs.filter { $0.id != except.id }

        guard toClose.count != self.tabs.count else { return }

        for tab in toClose {
            self.closeTab(tab)
        }
    }

    func closeTabsToTheRight(of tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        let toClose = tabs.enumerated().filter { $0.offset > index }.map { $0.element }

        for tabToClose in toClose {
            self.closeTab(tabToClose)
        }
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func selectNextTab() {
        guard let currentTabIndex else { return }

        let nextIndex = (currentTabIndex + 1) % tabs.count
        selectTab(tabs[nextIndex])
    }

    func selectPreviousTab() {
        guard let currentTabIndex else { return }

        let previousIndex = (currentTabIndex - 1 + tabs.count) % tabs.count
        selectTab(tabs[previousIndex])
    }

    /// Moves a tab to a new regular terminal window at the specified screen location.
    /// The tab's surface tree is transferred to the new window.
    func moveTabToNewWindow(_ tab: QuickTerminalTab, at screenLocation: NSPoint? = nil) {
        guard let ghostty = controller?.ghostty else { return }
        guard controller?.window != nil else { return }

        // If this is the current tab, sync its surface tree from the controller
        if currentTab?.id == tab.id, let controllerTree = controller?.surfaceTree {
            tab.surfaceTree = controllerTree
        }

        // Capture the target location (use provided location or current mouse position)
        let targetLocation = screenLocation ?? NSEvent.mouseLocation

        // Create a new TerminalController with the existing surface tree
        let newController = TerminalController(
            ghostty,
            withSurfaceTree: tab.surfaceTree
        )

        // Transfer tab title and color to the new controller/window
        newController.titleOverride = tab.titleOverride

        // Show the new window first (this triggers window loading)
        newController.showWindow(nil)

        // Position the window after showing. We need to do this in async to ensure
        // any window cascading or layout passes have completed first.
        if let newWindow = newController.window {
            // Transfer tab color to the new window
            (newWindow as? TerminalWindow)?.tabColor = tab.tabColor

            let windowSize = newWindow.frame.size
            // Position so the top center of the title bar is at the drop point
            let newOrigin = NSPoint(
                x: targetLocation.x - windowSize.width / 2,
                y: targetLocation.y - windowSize.height
            )
            // Use async to ensure positioning happens after any pending layout
            DispatchQueue.main.async {
                newWindow.setFrameOrigin(newOrigin)
                newWindow.makeKeyAndOrderFront(nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        // Remove the tab from the quick terminal without closing its surfaces
        // (they're now owned by the new window)
        removeTabWithoutClosingSurfaces(tab)

        // Clear the dragged tab state
        draggedTab = nil
    }

    /// Removes a tab from the tab list without closing its surfaces.
    /// Used when transferring a tab to a new window.
    func removeTabWithoutClosingSurfaces(_ tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        tabs.remove(at: index)

        if currentTab?.id == tab.id {
            if tabs.isEmpty {
                // Add a new tab since we need at least one
                addNewTab()
                controller?.animateOut()
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectTab(tabs[newIndex])
            }
        }
    }

    /// Finds a Ghostty terminal window (not quick terminal) at the given screen location.
    private func findGhosttyWindowAtLocation(_ location: NSPoint) -> NSWindow? {
        // Get all windows ordered front to back
        let windows = NSApp.orderedWindows

        for window in windows {
            // Skip the quick terminal window
            if window.windowController is QuickTerminalController {
                continue
            }

            // Check if it's a terminal window
            guard window.windowController is TerminalController else {
                continue
            }

            // Check if the location is within this window's frame
            if window.frame.contains(location) {
                return window
            }
        }

        return nil
    }

    /// Checks if the given screen location is in the tab bar area of the window.
    private func isInTabBarArea(_ location: NSPoint, of window: NSWindow) -> Bool {
        let windowFrame = window.frame

        // Calculate the actual title bar + tab bar height by measuring the difference
        // between the window frame and the content layout rect. This works across
        // different macOS versions and window styles.
        let titleBarHeight = windowFrame.height - window.contentLayoutRect.height

        // Use the measured height, but ensure a minimum for edge cases
        let effectiveHeight = max(titleBarHeight, 28)

        let tabBarRect = NSRect(
            x: windowFrame.minX,
            y: windowFrame.maxY - effectiveHeight,
            width: windowFrame.width,
            height: effectiveHeight
        )

        return tabBarRect.contains(location)
    }

    /// Moves a tab to an existing terminal window as a new tab.
    func moveTabToExistingWindow(_ tab: QuickTerminalTab, targetWindow: NSWindow) {
        guard let ghostty = controller?.ghostty else { return }
        guard controller?.window != nil else { return }

        // If this is the current tab, sync its surface tree from the controller
        if currentTab?.id == tab.id, let controllerTree = controller?.surfaceTree {
            tab.surfaceTree = controllerTree
        }

        // Create a new TerminalController with the existing surface tree
        let newController = TerminalController(
            ghostty,
            withSurfaceTree: tab.surfaceTree
        )

        // Transfer tab title and color to the new controller/window
        newController.titleOverride = tab.titleOverride

        // Add the new window as a tab to the target window
        if let newWindow = newController.window {
            // Transfer tab color to the new window
            (newWindow as? TerminalWindow)?.tabColor = tab.tabColor

            targetWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Remove the tab from the quick terminal without closing its surfaces
        removeTabWithoutClosingSurfaces(tab)

        // Clear the dragged tab state
        draggedTab = nil
    }

    // MARK: - Notifications

    @objc func onMoveTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == controller?.focusedSurface else { return }

        guard
            let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab
        else { return }

        guard action.amount != 0 else { return }

        guard let currentTabIndex else { return }

        // Determine the final index we want to insert our tab
        let finalIndex: Int
        if action.amount < 0 {
            finalIndex = max(0, currentTabIndex - min(currentTabIndex, -action.amount))
        } else {
            let remaining: Int = tabs.count - 1 - currentTabIndex
            finalIndex = currentTabIndex + min(remaining, action.amount)
        }

        if finalIndex != currentTabIndex {
            moveTab(from: IndexSet(integer: currentTabIndex), to: finalIndex)
        }
    }

    @objc func onGoToTab(_ notification: Notification) {
        // Only respond to goto_tab when the quick terminal window is focused
        guard controller?.window?.isKeyWindow == true else { return }

        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }

        let tabIndex: Int32 = tabEnum.rawValue

        if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
            selectPreviousTab()
        } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
            selectNextTab()
        } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
            selectTab(tabs[tabs.count - 1])
        } else if tabIndex > 0 {
            // Numeric tab index (1-indexed)
            let arrayIndex = Int(tabIndex) - 1
            guard arrayIndex < tabs.count else { return }
            selectTab(tabs[arrayIndex])
        }
    }
}
