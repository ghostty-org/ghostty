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
            if draggedTab != nil {
                startDragMonitor()
            } else {
                stopDragMonitor()
            }
        }
    }

    /// Reference to the "quick" terminal Controller
    weak var controller: QuickTerminalController?

    /// Event monitor for detecting when a drag ends outside the window
    private var dragEventMonitor: Any?

    var currentTabIndex: Int? {
        tabs.firstIndex { $0.id == currentTab?.id }
    }

    /// Access to the Ghostty config for keybinding lookups
    var config: Ghostty.Config? {
        controller?.ghostty.config
    }

    init(controller: QuickTerminalController) {
        self.controller = controller
        addNewTab()
    }

    deinit {
        stopDragMonitor()
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

        // Show the new window first (this triggers window loading)
        newController.showWindow(nil)

        // Position the window after showing. We need to do this in async to ensure
        // any window cascading or layout passes have completed first.
        if let newWindow = newController.window {
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

    // MARK: - Drag Monitoring

    /// Local event monitor for drag end detection
    private var localDragEventMonitor: Any?

    /// Captured mouse location when drag ends (before async processing)
    private var dragEndLocation: NSPoint?

    private func startDragMonitor() {
        // Don't create multiple monitors
        guard dragEventMonitor == nil else { return }

        // Monitor for left mouse up events globally to detect when drag ends
        // outside our application
        dragEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.handleDragEnd()
        }

        // Also monitor local events in case the drag ends within our app
        // but outside the quick terminal window
        localDragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleDragEnd()
            return event
        }
    }

    private func stopDragMonitor() {
        if let monitor = dragEventMonitor {
            NSEvent.removeMonitor(monitor)
            dragEventMonitor = nil
        }
        if let monitor = localDragEventMonitor {
            NSEvent.removeMonitor(monitor)
            localDragEventMonitor = nil
        }
        dragEndLocation = nil
    }

    private func handleDragEnd() {
        // Capture mouse location immediately before any async processing
        dragEndLocation = NSEvent.mouseLocation

        // Small delay to allow drop delegate to process first
        // This prevents race conditions between performDrop clearing draggedTab
        // and the event monitor checking it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.processDragEnd()
        }
    }

    private func processDragEnd() {
        // Must have a tab being dragged (if nil, drop delegate already handled it)
        guard let tab = draggedTab else {
            dragEndLocation = nil
            return
        }
        guard let window = controller?.window else {
            draggedTab = nil
            dragEndLocation = nil
            return
        }

        // Use captured location from when drag ended
        let mouseLocation = dragEndLocation ?? NSEvent.mouseLocation
        let windowFrame = window.frame

        if !windowFrame.contains(mouseLocation) {
            // Mouse is outside the quick terminal window
            // Check if we're over another Ghostty terminal window's tab bar area
            if let targetWindow = findGhosttyWindowAtLocation(mouseLocation),
               isInTabBarArea(mouseLocation, of: targetWindow) {
                // Add as a tab to the existing window
                moveTabToExistingWindow(tab, targetWindow: targetWindow)
            } else {
                // Create a new standalone window
                moveTabToNewWindow(tab, at: mouseLocation)
            }
        } else {
            // Mouse is inside the window but not on a tab - just clear the dragged tab
            draggedTab = nil
        }

        dragEndLocation = nil
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

        // Add the new window as a tab to the target window
        if let newWindow = newController.window {
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
