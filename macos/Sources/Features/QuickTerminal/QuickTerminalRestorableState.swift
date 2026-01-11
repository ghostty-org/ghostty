import Cocoa

/// Represents a single tab's state for restoration.
struct QuickTerminalTabState: Codable {
    let surfaceTree: SplitTree<Ghostty.SurfaceView>
    let title: String
    let titleOverride: String?
    let tabColor: TerminalTabColor

    init(surfaceTree: SplitTree<Ghostty.SurfaceView>, title: String, titleOverride: String?, tabColor: TerminalTabColor) {
        self.surfaceTree = surfaceTree
        self.title = title
        self.titleOverride = titleOverride
        self.tabColor = tabColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceTree = try container.decode(SplitTree<Ghostty.SurfaceView>.self, forKey: .surfaceTree)
        title = try container.decode(String.self, forKey: .title)
        // Provide defaults for new fields to handle old saved state
        titleOverride = try container.decodeIfPresent(String.self, forKey: .titleOverride)
        tabColor = try container.decodeIfPresent(TerminalTabColor.self, forKey: .tabColor) ?? .none
    }

    enum CodingKeys: String, CodingKey {
        case surfaceTree, title, titleOverride, tabColor
    }
}

struct QuickTerminalRestorableState: TerminalRestorable {
    static var version: Int { 2 }

    let focusedSurface: String?
    let screenStateEntries: QuickTerminalScreenStateCache.Entries
    let tabs: [QuickTerminalTabState]
    let currentTabIndex: Int

    /// Legacy property for backwards compatibility - returns the current tab's surface tree
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        guard currentTabIndex < tabs.count else {
            return SplitTree()
        }
        return tabs[currentTabIndex].surfaceTree
    }

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)
        self.focusedSurface = controller.focusedSurface?.id.uuidString
        self.screenStateEntries = controller.screenStateCache.stateByDisplay

        let tabManager = controller.tabManager
        // Sync the current tab's surface tree from the controller
        if let currentTab = tabManager.currentTab {
            currentTab.surfaceTree = controller.surfaceTree
        }

        self.tabs = tabManager.tabs.map { tab in
            QuickTerminalTabState(
                surfaceTree: tab.surfaceTree,
                title: tab.title,
                titleOverride: tab.titleOverride,
                tabColor: tab.tabColor
            )
        }
        self.currentTabIndex = tabManager.currentTabIndex ?? 0
    }

    init(copy other: QuickTerminalRestorableState) {
        self = other
    }

    var baseConfig: Ghostty.SurfaceConfiguration? {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
        return config
    }
}
