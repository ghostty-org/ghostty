import Cocoa

/// Represents a single tab's state for restoration.
struct QuickTerminalTabState<ViewType: NSView & Codable & Identifiable>: Codable {
    let surfaceTree: SplitTree<ViewType>
    let title: String
    let titleOverride: String?
    let tabColor: TerminalTabColor

    init(surfaceTree: SplitTree<ViewType>, title: String, titleOverride: String?, tabColor: TerminalTabColor) {
        self.surfaceTree = surfaceTree
        self.title = title
        self.titleOverride = titleOverride
        self.tabColor = tabColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceTree = try container.decode(SplitTree<ViewType>.self, forKey: .surfaceTree)
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
    static var minimumVersion: Int { 1 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }

    var screenStateEntries: QuickTerminalScreenStateCache.Entries {
        internalState.screenStateEntries
    }

    var tabs: [QuickTerminalTabState<Ghostty.SurfaceView>] {
        internalState.tabs
    }

    var currentTabIndex: Int {
        internalState.currentTabIndex
    }

    /// Legacy property for backwards compatibility - returns the current tab's surface tree
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        guard currentTabIndex < tabs.count else {
            return internalState.surfaceTree
        }
        return tabs[currentTabIndex].surfaceTree
    }

    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: QuickTerminalController) {
        controller.saveScreenState(exitFullscreen: true)

        // Sync the current tab's surface tree from the controller before snapshotting
        if let currentTab = controller.tabManager.currentTab {
            currentTab.surfaceTree = controller.surfaceTree
        }

        self.internalState = .init(from: controller)
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

extension QuickTerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `QuickTerminalRestorableState`
    /// due to `CodableBridge<QuickTerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 1 (1.3.0)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let screenStateEntries: QuickTerminalScreenStateCache.Entries

        // MARK: - Version 2 (1.4.0)
        let tabs: [QuickTerminalTabState<ViewType>]
        let currentTabIndex: Int

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            screenStateEntries: QuickTerminalScreenStateCache.Entries,
            tabs: [QuickTerminalTabState<ViewType>] = [],
            currentTabIndex: Int = 0,
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.screenStateEntries = screenStateEntries
            self.tabs = tabs
            self.currentTabIndex = currentTabIndex
        }

        /// Custom decode so v1 archives (which lack `tabs`/`currentTabIndex`)
        /// continue to decode after the v2 bump.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.focusedSurface = try container.decodeIfPresent(String.self, forKey: .focusedSurface)
            self.surfaceTree = try container.decode(SplitTree<ViewType>.self, forKey: .surfaceTree)
            self.screenStateEntries = try container.decode(
                QuickTerminalScreenStateCache.Entries.self,
                forKey: .screenStateEntries
            )
            self.tabs = try container.decodeIfPresent(
                [QuickTerminalTabState<ViewType>].self,
                forKey: .tabs
            ) ?? []
            self.currentTabIndex = try container.decodeIfPresent(Int.self, forKey: .currentTabIndex) ?? 0
        }

        enum CodingKeys: String, CodingKey {
            case focusedSurface, surfaceTree, screenStateEntries, tabs, currentTabIndex
        }
    }
}

extension QuickTerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: QuickTerminalController) {
        let tabManager = controller.tabManager
        let tabs = tabManager.tabs.map { tab in
            QuickTerminalTabState(
                surfaceTree: tab.surfaceTree,
                title: tab.title,
                titleOverride: tab.titleOverride,
                tabColor: tab.tabColor
            )
        }

        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            screenStateEntries: controller.screenStateCache.stateByDisplay,
            tabs: tabs,
            currentTabIndex: tabManager.currentTabIndex ?? 0,
        )
    }
}
