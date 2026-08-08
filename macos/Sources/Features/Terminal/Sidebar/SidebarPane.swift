import Foundation

/// One panel the sidebar can show.
///
/// The sidebar started out only able to list terminals. This enum is the
/// seam that lets it hold more: adding a panel is a case here plus a branch
/// in `SidebarView.paneContent` and, if it needs its own titlebar buttons,
/// one in `SidebarTitlebarChrome`. Nothing in the AppKit hierarchy
/// (`TerminalController.makeSidebarSplitView`) has to change.
///
/// Git and worktree panels are the planned next two.
enum SidebarPane: String, CaseIterable, Identifiable, Codable {
    case terminals
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminals: return "Terminals"
        case .files: return "Files"
        }
    }

    /// SF Symbol for the tab bar.
    var icon: String {
        switch self {
        case .terminals: return "terminal"
        case .files: return "folder"
        }
    }
}
