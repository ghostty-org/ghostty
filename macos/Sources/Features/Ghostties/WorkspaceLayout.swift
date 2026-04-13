import AppKit
import Foundation
import SwiftUI

/// Three-state sidebar visibility model.
///
/// - `pinned`: Sidebar open, terminal pushed right (floating card).
/// - `closed`: Sidebar hidden, terminal fills window flush.
/// - `overlay`: Sidebar floats on top of full-width terminal (hover-to-reveal).
enum SidebarMode: Int, Codable {
    case pinned
    case closed
    case overlay
}

/// Shared layout constants for the workspace sidebar.
enum WorkspaceLayout {
    /// Width of the sidebar panel.
    static let sidebarWidth: CGFloat = 220

    /// Height reserved at top for window traffic light controls.
    static let titlebarSpacerHeight: CGFloat = 28

    /// Height of the session-name title bar inside the terminal card.
    static let terminalTitleBarHeight: CGFloat = 28

    /// Corner radius on the floating terminal panel (all four corners).
    static let terminalCornerRadius: CGFloat = 12

    /// Inset around the terminal panel when sidebar is visible (floating card effect).
    /// The design uses 8pt on all four sides (top, bottom, left, right).
    static let terminalInset: CGFloat = 8

    /// Width of the invisible hover trigger strip at the left edge (closed mode).
    static let overlayTriggerWidth: CGFloat = 10

    /// Minimum width for the browser panel when visible.
    static let browserMinWidth: CGFloat = 320

    /// Default split ratio for terminal vs browser (terminal gets this fraction).
    static let browserSplitRatio: CGFloat = 0.5

    /// Background for expanded project group container (dark mode).
    static let expandedContainerDark = Color(white: 0.16)

    /// Background for expanded project group container (light mode).
    static let expandedContainerLight = Color.white

    /// Background for active session row (dark mode): 6% white.
    static let activeRowDark = Color.white.opacity(0.06)

    /// Background for active session row (light mode): 4% black.
    static let activeRowLight = Color.black.opacity(0.04)

    /// Workspace canvas color behind the floating terminal card (light mode).
    static let canvasBackgroundLight = NSColor(red: 0xF0 / 255.0, green: 0xE9 / 255.0, blue: 0xE6 / 255.0, alpha: 1)

    /// Terminal card background including title bar region (light mode).
    static let cardBackgroundLight = NSColor(red: 0xFD / 255.0, green: 0xF9 / 255.0, blue: 0xF7 / 255.0, alpha: 1)

    /// Workspace canvas color behind the floating terminal card (dark mode).
    /// Slightly lighter than the card so the terminal appears to float.
    static let canvasBackgroundDark = NSColor(white: 0.14, alpha: 1)

    /// Terminal card background including title bar region (dark mode).
    /// Darker than the canvas to give the terminal visual weight.
    static let cardBackgroundDark = NSColor(white: 0.10, alpha: 1)

    /// Terracotta/warm rust accent for the "waiting" indicator state. #c97350
    static let waitingTerracotta = Color(red: 0.788, green: 0.451, blue: 0.314)

    /// NSColor variant of `waitingTerracotta` for AppKit layers (e.g. button tints).
    static let waitingTerracottaNS = NSColor(red: 0.788, green: 0.451, blue: 0.314, alpha: 1)

    /// Minimum width for the terminal panel when browser is visible.
    static let terminalMinWidth: CGFloat = 300

    /// Purple accent for the "needs attention" indicator state. #A855F7
    static let needsAttentionPurple = Color(red: 0.659, green: 0.333, blue: 0.969)

    // MARK: - Activity / Section Foregrounds

    /// Foreground color for a project's ghost icon when the project has recent
    /// activity (within 24h) but no live active session. Reads as "alive but not
    /// running" — full-strength label, same weight as a body label.
    static let activityNormalForeground = Color.primary

    /// Foreground color for a project's ghost icon when the project is idle
    /// (no live active session and nothing within the past 24h). Reads as "in
    /// the long tail" — quietest tier above pure invisible.
    static let activityMutedForeground = Color(.tertiaryLabelColor)

    /// Foreground for the small section-header labels in the sidebar
    /// ("Pinned", "Active Now", "Recent", "All Projects"). Muted by design so
    /// the project rows themselves stay the dominant visual.
    static let sectionHeaderForeground = Color(.tertiaryLabelColor)

    /// Foreground for the smaller in-row session group headers ("Active",
    /// "Recent", "Idle") inside an expanded project. One tier quieter than the
    /// top-level section headers since they're nested.
    static let sessionGroupHeaderForeground = Color(.tertiaryLabelColor)
}

// MARK: - Workspace Notifications

extension Notification.Name {
    /// Posted by TerminalController when the user presses Cmd+Shift+].
    /// The notification object is the originating NSWindow.
    static let workspaceSelectNextProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectNextProject")

    /// Posted by TerminalController when the user presses Cmd+Shift+[.
    /// The notification object is the originating NSWindow.
    static let workspaceSelectPreviousProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectPreviousProject")

    /// Posted by WorkspaceStore just before a project is removed.
    /// userInfo contains "projectId" (UUID). Coordinators observe this to close
    /// running sessions before the store deletes the project's records.
    static let workspaceProjectWillBeRemoved = Notification.Name("com.seansmithdesign.ghostties.workspace.projectWillBeRemoved")

    /// Posted by TerminalController when the user presses Cmd+Shift+T.
    /// The notification object is the originating NSWindow.
    static let workspaceNewSession = Notification.Name("com.seansmithdesign.ghostties.workspace.newSession")

    /// Posted by MenuBarDropdownView when the user clicks a session row.
    /// userInfo contains "sessionId" (UUID). SessionCoordinators observe this
    /// to focus the tapped session and bring its window to the front.
    static let menuBarFocusSession = Notification.Name("com.seansmithdesign.ghostties.menuBar.focusSession")
}
