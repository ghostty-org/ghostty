import Cocoa

/// Represents a single tab's state for restoration.
struct QuickTerminalTabState: Codable {
    let surfaceTree: SplitTree<Ghostty.SurfaceView>
    let title: String
}

/// The state stored for quick terminal restoration via UserDefaults.
class QuickTerminalRestorableState: Codable {
    private static let userDefaultsKey = "QuickTerminalState"

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

    // MARK: - UserDefaults Persistence

    /// Saves the quick terminal state to UserDefaults.
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
