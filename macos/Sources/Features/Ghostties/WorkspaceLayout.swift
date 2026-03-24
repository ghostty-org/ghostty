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

    /// Purple accent for the "needs attention" indicator state. #A855F7
    static let needsAttentionPurple = Color(red: 0.659, green: 0.333, blue: 0.969)
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
