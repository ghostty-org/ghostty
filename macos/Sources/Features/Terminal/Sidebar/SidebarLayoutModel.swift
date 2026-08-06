import AppKit
import Combine
import Foundation

/// App-wide sidebar collapse state. Shared by every window so switching
/// tabs never changes the sidebar geometry, and persisted so it
/// survives relaunches.
@MainActor
final class SidebarCollapseState: ObservableObject {
    static let shared = SidebarCollapseState()

    @Published var isCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: "SidebarCollapsed")
        }
    }

    init() {
        isCollapsed = UserDefaults.standard.bool(forKey: "SidebarCollapsed")
    }
}

/// Window-level sidebar actions shared between the controller (which
/// owns the split view) and the SwiftUI sidebar chrome.
@MainActor
final class SidebarLayoutModel: ObservableObject {
    /// Creates a new terminal tab in this window's tab group.
    var onNewTab: () -> Void = {}
}

/// The sidebar | terminal split view, with a user-configurable divider:
/// default system color, hidden, or a custom color.
final class SidebarSplitView: NSSplitView {
    override var dividerColor: NSColor {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "SidebarDividerMode") ?? "default" {
        case "hidden":
            return .clear
        case "custom":
            if let hex = defaults.string(forKey: "SidebarDividerColorHex"),
               let color = NSColor(hex: hex) {
                return color
            }
            return super.dividerColor
        default:
            return super.dividerColor
        }
    }
}
