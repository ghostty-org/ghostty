import AppKit

/// Coordinates close operations for windows that are part of a tab group.
///
/// This coordinator helps distinguish between closing a single tab versus closing
/// an entire window (with all its tabs). When macOS native tabs are used, close
/// operations can be ambiguous - this coordinator tracks close requests across
/// multiple windows in a tab group to determine the user's intent.
class TabGroupCloseCoordinator {
    /// The scope of a close operation.
    enum CloseScope {
        case tab
        case window
    }

    /// Protocol that window controllers must implement to use the coordinator.
    protocol Controller {
        /// The tab group close coordinator instance for this controller.
        var tabGroupCloseCoordinator: TabGroupCloseCoordinator { get }
    }

    /// Callback type for close operations.
    typealias Callback = (CloseScope) -> Void

    // We use weak vars and ObjectIdentifiers below because we don't want to
    // create any strong reference cycles during coordination.

    /// The tab group being coordinated. Weak reference to avoid cycles.
    private weak var tabGroup: NSWindowTabGroup?

    /// Map of window identifiers to their close callbacks.
    private var closeRequests: [ObjectIdentifier: Callback] = [:]

    /// Timer used to debounce close requests and determine intent.
    private var debounceTimer: Timer?

    deinit {
        trigger(.tab)
    }

    /// Call this from the windowShouldClose override in order to track whether
    /// a window close event is from a tab or a window. If this window already
    /// requested a close then only the latest will be called.
    func windowShouldClose(
        _ window: NSWindow,
        callback: @escaping Callback
    ) {
        // If this window isn't part of a tab group we assume its a window
        // close for the window and let our timer keep running for the rest.
        guard let tabGroup = window.tabGroup else {
            callback(.window)
            return
        }

        // Forward to the proper coordinator
        if let firstController = tabGroup.windows.first?.windowController as? Controller,
           firstController.tabGroupCloseCoordinator !== self {
            let coordinator = firstController.tabGroupCloseCoordinator
            coordinator.windowShouldClose(window, callback: callback)
            return
        }

        // If our tab group is nil then we either are seeing this for the first
        // time or our weak ref expired and we should fire our callbacks.
        if self.tabGroup == nil {
            self.tabGroup = tabGroup
            debounceTimer?.fire()
            debounceTimer = nil
        }

        // No matter what, we cancel our debounce and restart this. This opens
        // us up to a DoS if close requests are looped but this would only
        // happen in hostile scenarios that are self-inflicted.
        debounceTimer?.invalidate()
        debounceTimer = nil

        // If this tab group doesn't match then I don't really know what to
        // do. This shouldn't happen. So we just assume it's a tab close
        // and trigger the rest. No right answer here as far as I know.
        if self.tabGroup != tabGroup {
            callback(.tab)
            trigger(.tab)
            return
        }

        // Add the request
        closeRequests[ObjectIdentifier(window)] = callback

        // If close requests matches all our windows then we are done.
        if closeRequests.count == tabGroup.windows.count {
            let allWindows = Set(tabGroup.windows.map { ObjectIdentifier($0) })
            if Set(closeRequests.keys) == allWindows {
                trigger(.window)
                return
            }
        }

        // Setup our new timer
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Duration.milliseconds(100).timeInterval,
            repeats: false
        ) { [weak self] _ in
            self?.trigger(.tab)
        }
    }

    /// Triggers all pending close callbacks with the given scope.
    ///
    /// This method is called when the coordinator has determined the user's intent
    /// (either closing a tab or the entire window). It executes all pending callbacks
    /// and resets the coordinator's state.
    ///
    /// - Parameter scope: The determined scope of the close operation.
    private func trigger(_ scope: CloseScope) {
        // Reset our state
        tabGroup = nil
        debounceTimer?.invalidate()
        debounceTimer = nil

        // Trigger all of our callbacks
        closeRequests.forEach { $0.value(scope) }
        closeRequests = [:]
    }
}
