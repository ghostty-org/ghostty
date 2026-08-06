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

    /// Creates a new terminal tab that immediately starts a Claude session.
    var onNewClaudeTab: () -> Void = {}
}

/// The sidebar | terminal split view, with a user-configurable divider:
/// default system color, hidden, or a custom color.
final class SidebarSplitView: NSSplitView {
    /// What the panes on either side are painting, so a hidden divider can
    /// paint the same thing. Kept in sync by the controller via
    /// `AppearanceCoordinator`; nil means the panes paint nothing (glass).
    var paneColor: NSColor? {
        didSet {
            guard paneColor != oldValue else { return }
            needsDisplay = true
        }
    }

    private enum DividerMode {
        case system
        case hidden
        case custom(NSColor)

        static var current: DividerMode {
            let defaults = UserDefaults.standard
            switch defaults.string(forKey: "SidebarDividerMode") ?? "default" {
            case "hidden":
                return .hidden
            case "custom":
                guard let hex = defaults.string(forKey: "SidebarDividerColorHex"),
                      let color = NSColor(hex: hex)
                else { return .system }
                return .custom(color)
            default:
                return .system
            }
        }
    }

    override var dividerColor: NSColor {
        switch DividerMode.current {
        case .hidden: return .clear
        case .custom(let color): return color
        case .system: return super.dividerColor
        }
    }

    /// Drawing the divider directly rather than relying only on the
    /// `dividerColor` override: AppKit does not reliably re-read that
    /// property for an already-drawn divider, so a mode change in settings
    /// left the old divider on screen until the window was recreated.
    override func drawDivider(in rect: NSRect) {
        switch DividerMode.current {
        case .hidden:
            // Hiding means painting what the panes paint, not skipping the
            // draw: the divider keeps its width either way, so an unpainted
            // one exposes the window behind it — which reads as a visible
            // seam at any opacity below fully opaque. Under glass the panes
            // paint nothing, and so does this.
            guard let paneColor else { return }
            paneColor.setFill()
            rect.fill()
        case .custom(let color):
            color.setFill()
            rect.fill()
        case .system:
            super.drawDivider(in: rect)
        }
    }
}
