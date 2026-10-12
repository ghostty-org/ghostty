import AppKit
import Combine

/// App-wide state of the tab sidebar. Every terminal window observes this so that
/// all sidebars always have the same width and visibility. This matters because each
/// tab is its own window and AppKit swaps windows when switching tabs.
@MainActor
final class TabSidebarSettings: ObservableObject {
    static let shared = TabSidebarSettings(defaults: .ghostty)

    static let widthKey = "TabSidebarWidth"
    static let visibleKey = "TabSidebarVisible"

    private let defaults: UserDefaults

    /// The user-chosen width of the sidebar. This is always clamped to the valid range.
    @Published private(set) var width: CGFloat

    /// Whether the sidebar is visible.
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Self.visibleKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let storedWidth = (defaults.object(forKey: Self.widthKey) as? Double).map { CGFloat($0) }
        self.width = TabSidebarLogic.clampStoredWidth(storedWidth ?? TabSidebarLogic.defaultWidth)
        self.isVisible = defaults.object(forKey: Self.visibleKey) as? Bool ?? true
    }

    /// Sets the width. During a live resize `persist` should be false so we only
    /// write to the defaults once the drag completes.
    func setWidth(_ width: CGFloat, persist: Bool) {
        let clamped = TabSidebarLogic.clampStoredWidth(width)
        if clamped != self.width { self.width = clamped }
        if persist { defaults.set(Double(clamped), forKey: Self.widthKey) }
    }

    func toggleVisible() {
        isVisible.toggle()
    }
}

extension Notification.Name {
    /// Posted with a `TerminalController` object when something displayed for that tab in
    /// the sidebar changed (title, working directory, color, zoom).
    static let terminalTabSidebarItemDidChange = Notification.Name("com.mitchellh.ghostty.tabSidebarItemDidChange")

    /// Posted when the tab structure (order, membership) may have changed and sidebars
    /// should rebuild their list of tabs.
    static let terminalTabSidebarNeedsReload = Notification.Name("com.mitchellh.ghostty.tabSidebarNeedsReload")
}
