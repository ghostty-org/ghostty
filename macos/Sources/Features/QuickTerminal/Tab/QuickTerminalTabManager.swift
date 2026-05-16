import GhosttyKit
import SwiftUI

/// Custom TabManager for the "quick" terminal
class QuickTerminalTabManager: ObservableObject {

    /// All currently open tabs
    @Published private(set) var tabs: [QuickTerminalTab] = []

    /// The current tab in focus
    @Published private(set) var currentTab: QuickTerminalTab? {
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
    private(set) weak var controller: QuickTerminalController?

    var currentTabIndex: Int? {
        tabs.firstIndex { $0.id == currentTab?.id }
    }

    /// Access to the Ghostty config for keybinding lookups
    var config: Ghostty.Config? {
        controller?.ghostty.config
    }

    /// Forwards to the controller's undo manager (the app-level expiring manager).
    /// Returns nil before the controller has a window so callers can short-circuit.
    private var undoManager: ExpiringUndoManager? {
        controller?.undoManager
    }

    private var undoExpiration: Duration {
        controller?.undoExpiration ?? .seconds(60)
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
            // No saved state or restoration disabled - create default tab.
            // Skip undo registration; the initial tab is part of setup, not a user action.
            performAddNewTab(registerUndo: false)
        }
    }

    /// Restores tabs from saved state. This replaces any existing tabs.
    /// - Parameters:
    ///   - tabStates: The saved tab states to restore
    ///   - currentIndex: The index of the tab that should be selected
    func restoreTabs(from tabStates: [QuickTerminalTabState<Ghostty.SurfaceView>], currentIndex: Int) {
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
        performAddNewTab(registerUndo: true)
    }

    @discardableResult
    private func performAddNewTab(registerUndo: Bool) -> QuickTerminalTab? {
        guard let ghostty = controller?.ghostty else { return nil }

        let leaf: Ghostty.SurfaceView = .init(ghostty.app!, baseConfig: nil)
        let surfaceTree: SplitTree<Ghostty.SurfaceView> = .init(view: leaf)
        let tabIndex = tabs.count + 1
        let newTab = QuickTerminalTab(surfaceTree: surfaceTree, title: "Terminal \(tabIndex)")

        let insertIndex = (currentTabIndex.map { $0 + 1 }) ?? tabs.count
        insertTab(newTab, at: insertIndex, undoActionName: registerUndo ? "New Tab" : nil)
        return newTab
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
        let insertIndex = (currentTabIndex.map { $0 + 1 }) ?? tabs.count
        insertTab(newTab, at: insertIndex, undoActionName: "Move Tab")
    }

    func selectTab(_ tab: QuickTerminalTab) {
        guard currentTab?.id != tab.id else { return }

        currentTab = tab
    }

    func closeTab(_ tab: QuickTerminalTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }

        // Group with the "create empty tab + animate out" fallback so a single
        // undo restores both the closed tab and removes the auto-created one.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        removeTab(tab, undoActionName: "Close Tab")

        // If we just closed the last tab, replace it with a fresh empty tab and
        // hide the window. The replacement is part of the same undo group, so
        // undoing "Close Tab" both removes the new tab and restores the old one.
        if tabs.isEmpty {
            performAddNewTab(registerUndo: true)
            controller?.animateOut()
        }
    }

    func closeAllTabs(except: QuickTerminalTab) {
        let toClose = self.tabs.filter { $0.id != except.id }
        guard !toClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Close Other Tabs")
        defer { undoManager?.endUndoGrouping() }

        for tab in toClose {
            self.closeTab(tab)
        }
    }

    func closeTabsToTheRight(of tab: QuickTerminalTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let toClose = tabs.enumerated().filter { $0.offset > index }.map { $0.element }
        guard !toClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Close Tabs to the Right")
        defer { undoManager?.endUndoGrouping() }

        for tabToClose in toClose {
            self.closeTab(tabToClose)
        }
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        // Capture pre-move order so we can register an undo.
        let preMoveOrder = tabs
        tabs.move(fromOffsets: source, toOffset: destination)
        guard tabs.map(\.id) != preMoveOrder.map(\.id) else { return }
        registerReorderUndo(to: preMoveOrder, actionName: "Move Tab")
    }

    // MARK: Undoable Helpers

    /// Inserts a tab at the given index and (optionally) registers an undo that
    /// closes it again. The undo closure re-registers a redo via `removeTab`.
    private func insertTab(_ tab: QuickTerminalTab, at index: Int, undoActionName: String?) {
        let clamped = max(0, min(index, tabs.count))
        tabs.insert(tab, at: clamped)
        selectTab(tab)

        guard let undoActionName, let undoManager else { return }
        undoManager.setActionName(undoActionName)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            target.removeTab(tab, undoActionName: undoActionName)
        }
    }

    /// Removes a tab without closing its surfaces (the tab object itself
    /// retains them, so undo can restore it). Registers an undo that re-inserts.
    private func removeTab(_ tab: QuickTerminalTab, undoActionName: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let previousSelection = currentTab

        tabs.remove(at: index)

        if currentTab?.id == tab.id {
            if tabs.isEmpty {
                currentTab = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectTab(tabs[newIndex])
            }
        }

        guard let undoActionName, let undoManager else { return }
        undoManager.setActionName(undoActionName)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            target.insertTab(tab, at: index, undoActionName: undoActionName)
            if let previousSelection, target.tabs.contains(where: { $0.id == previousSelection.id }) {
                target.selectTab(previousSelection)
            }
        }
    }

    /// Restores a previous tab ordering and registers a redo that re-applies
    /// the current ordering.
    private func registerReorderUndo(to previousOrder: [QuickTerminalTab], actionName: String) {
        guard let undoManager else { return }
        let newOrder = tabs
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            target.tabs = previousOrder
            target.registerReorderUndo(to: newOrder, actionName: actionName)
        }
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

        // Group with the auto-empty-tab fallback in `removeTabWithoutClosingSurfaces`
        // so undo reverses both the move AND the auto-created replacement tab.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        // Capture state before the move so undo can restore it.
        let originalIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.count
        let previousSelection = currentTab

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

        registerMoveOutUndo(
            tab: tab,
            destinationController: newController,
            originalIndex: originalIndex,
            previousSelection: previousSelection,
            actionName: "Move Tab to New Window"
        ) { target in
            target.moveTabToNewWindow(tab, at: targetLocation)
        }
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

        // Group with the auto-empty-tab fallback in `removeTabWithoutClosingSurfaces`
        // so undo reverses both the move AND the auto-created replacement tab.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        // Capture state before the move so undo can restore it.
        let originalIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.count
        let previousSelection = currentTab

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

        registerMoveOutUndo(
            tab: tab,
            destinationController: newController,
            originalIndex: originalIndex,
            previousSelection: previousSelection,
            actionName: "Move Tab to Window"
        ) { [weak targetWindow] target in
            // If the original target window is gone by redo time, fall back to
            // detaching as a standalone window so the tab still comes back.
            if let targetWindow {
                target.moveTabToExistingWindow(tab, targetWindow: targetWindow)
            } else {
                target.moveTabToNewWindow(tab)
            }
        }
    }

    /// Registers an undo for "move out" operations (to a new window or to an
    /// existing window as a tab). The undo empties the destination controller's
    /// surface tree (so closing it doesn't kill PTYs), closes its window, and
    /// re-inserts the tab back into the quick terminal at its original index.
    ///
    /// `redo` re-runs the original move so Cmd+Shift+Z restores the tab to a
    /// fresh destination window. We capture the destination controller strongly
    /// until the undo expires/fires so the window can be cleanly dismissed; the
    /// retention is bounded by `undoExpiration`.
    private func registerMoveOutUndo(
        tab: QuickTerminalTab,
        destinationController: TerminalController,
        originalIndex: Int,
        previousSelection: QuickTerminalTab?,
        actionName: String,
        redo: @escaping (QuickTerminalTabManager) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            // The tab still holds the surfaces. Detach them from the destination
            // controller's tree so closing its window won't tear down PTYs.
            destinationController.surfaceTree = .init()
            destinationController.window?.close()

            // Re-insert into the quick terminal and restore selection. We pass
            // nil for the undo action name so this insert doesn't register its
            // own undo — we register the proper redo (re-run the move) below.
            target.insertTab(tab, at: originalIndex, undoActionName: nil)
            if let previousSelection, target.tabs.contains(where: { $0.id == previousSelection.id }) {
                target.selectTab(previousSelection)
            }

            // Register the redo: re-run the original move so Cmd+Shift+Z
            // recreates the destination window with this tab's surfaces.
            undoManager.setActionName(actionName)
            undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                redo(target)
            }
        }
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
