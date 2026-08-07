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
    private enum DividerMode {
        case system
        case hidden
        case custom(NSColor)

        var isHidden: Bool {
            if case .hidden = self { return true }
            return false
        }

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

    /// A hidden divider takes no space at all, so the panes meet edge to
    /// edge. Painting it to match instead never quite worked: the strip
    /// still sat above a transparent window, and no fill matches glass.
    /// The drag area it would have provided is restored by the delegate's
    /// `additionalEffectiveRectOfDividerAt`.
    override var dividerThickness: CGFloat {
        DividerMode.current.isHidden ? 0 : super.dividerThickness
    }

    /// Drawing the divider directly rather than relying only on the
    /// `dividerColor` override: AppKit does not reliably re-read that
    /// property for an already-drawn divider, so a mode change in settings
    /// left the old divider on screen until the window was recreated.
    override func drawDivider(in rect: NSRect) {
        // The titlebar paints its own strip and composites above this view,
        // so drawing the divider up into it stacks a second coat over that
        // one column — a short dark tick in an otherwise even strip.
        let inset = safeAreaInsets.top
        let rect = rect.intersection(
            NSRect(
                x: bounds.minX,
                y: isFlipped ? bounds.minY + inset : bounds.minY,
                width: bounds.width,
                height: bounds.height - inset
            )
        )
        guard !rect.isEmpty else { return }

        switch DividerMode.current {
        case .hidden:
            // Nothing to draw: the divider has no width in this mode.
            return
        case .custom(let color):
            color.setFill()
            rect.fill()
        case .system:
            super.drawDivider(in: rect)
        }
    }
}
