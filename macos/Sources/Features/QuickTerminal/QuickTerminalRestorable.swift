import Cocoa

/// Represents a single tab's state for restoration.
struct QuickTerminalTabState: Codable {
    let surfaceTree: SplitTree<Ghostty.SurfaceView>
    let title: String
}

/// The state stored for quick terminal window restoration.
class QuickTerminalRestorableState: Codable {
    static let selfKey = "state"
    static let versionKey = "version"
    static let version: Int = 1
    static let userDefaultsKey = "QuickTerminalState"

    let tabs: [QuickTerminalTabState]
    let currentTabIndex: Int
    let focusedSurface: String?

    init(from controller: QuickTerminalController, tabManager: QuickTerminalTabManager) {
        // Sync the current tab's surface tree from the controller
        if let currentTab = tabManager.currentTab {
            currentTab.surfaceTree = controller.surfaceTree
        }

        self.tabs = tabManager.tabs.map { tab in
            QuickTerminalTabState(
                surfaceTree: tab.surfaceTree,
                title: tab.title
            )
        }
        self.currentTabIndex = tabManager.currentTabIndex ?? 0
        self.focusedSurface = controller.focusedSurface?.id.uuidString
    }

    init?(coder aDecoder: NSCoder) {
        // Check version compatibility
        guard aDecoder.decodeInteger(forKey: Self.versionKey) == Self.version else {
            return nil
        }

        guard let v = aDecoder.decodeObject(of: CodableBridge<Self>.self, forKey: Self.selfKey) else {
            return nil
        }

        self.tabs = v.value.tabs
        self.currentTabIndex = v.value.currentTabIndex
        self.focusedSurface = v.value.focusedSurface
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(CodableBridge(self), forKey: Self.selfKey)
    }

    // MARK: - UserDefaults Persistence

    /// Saves the quick terminal state to UserDefaults.
    /// This is used when the quick terminal is hidden (not visible to macOS window restoration).
    func saveToUserDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    /// Loads saved quick terminal state from UserDefaults.
    /// Returns nil if no saved state exists or if decoding fails.
    static func loadFromUserDefaults() -> QuickTerminalRestorableState? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(QuickTerminalRestorableState.self, from: data)
    }

    /// Clears saved state from UserDefaults.
    /// Called after successful restoration to avoid restoring stale state.
    static func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

enum QuickTerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
    case noTabs
}

/// The NSWindowRestoration implementation for restoring the quick terminal.
class QuickTerminalWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, QuickTerminalRestoreError.identifierUnknown)
            return
        }

        // Get the app delegate
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, QuickTerminalRestoreError.delegateInvalid)
            return
        }

        // Check if restoration is disabled
        if appDelegate.ghostty.config.windowSaveState == "never" {
            completionHandler(nil, nil)
            return
        }

        // Decode the state
        guard let state = QuickTerminalRestorableState(coder: state) else {
            completionHandler(nil, QuickTerminalRestoreError.stateDecodeFailed)
            return
        }

        // Ensure we have tabs to restore
        guard !state.tabs.isEmpty else {
            completionHandler(nil, QuickTerminalRestoreError.noTabs)
            return
        }

        // Restore the quick terminal with the saved state
        appDelegate.restoreQuickTerminal(with: state)

        // Return the window
        guard let window = appDelegate.quickController.window else {
            completionHandler(nil, QuickTerminalRestoreError.windowDidNotLoad)
            return
        }

        // Restore focus to the correct surface
        if let focusedStr = state.focusedSurface {
            let controller = appDelegate.quickController
            for view in controller.surfaceTree {
                if view.id.uuidString == focusedStr {
                    controller.focusedSurface = view
                    restoreFocus(to: view, inWindow: window)
                    break
                }
            }
        }

        completionHandler(window, nil)
    }

    /// Restores focus to the surface view, waiting for SwiftUI to attach it to the window.
    private static func restoreFocus(to: Ghostty.SurfaceView, inWindow: NSWindow, attempts: Int = 0) {
        let after: DispatchTime
        if attempts == 0 {
            after = .now()
        } else if attempts > 40 {
            // 2 seconds, give up
            return
        } else {
            after = .now() + .milliseconds(50)
        }

        DispatchQueue.main.asyncAfter(deadline: after) {
            guard let viewWindow = to.window else {
                restoreFocus(to: to, inWindow: inWindow, attempts: attempts + 1)
                return
            }

            guard viewWindow == inWindow else { return }

            inWindow.makeFirstResponder(to)
        }
    }
}
