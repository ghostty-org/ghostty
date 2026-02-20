import Foundation

/// Shared layout constants for the workspace sidebar.
enum WorkspaceLayout {
    /// Width of the collapsed icon rail (icons only).
    static let collapsedRailWidth: CGFloat = 52

    /// Width of the expanded icon rail (icons + labels).
    static let expandedRailWidth: CGFloat = 220

    /// Total width of the sidebar container (matches expanded rail).
    static let sidebarWidth: CGFloat = 220
}

// MARK: - Workspace Notifications

extension Notification.Name {
    /// Posted by TerminalController when the user presses Cmd+Shift+].
    /// The notification object is the originating NSWindow.
    static let workspaceSelectNextProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectNextProject")

    /// Posted by TerminalController when the user presses Cmd+Shift+[.
    /// The notification object is the originating NSWindow.
    static let workspaceSelectPreviousProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectPreviousProject")
}
