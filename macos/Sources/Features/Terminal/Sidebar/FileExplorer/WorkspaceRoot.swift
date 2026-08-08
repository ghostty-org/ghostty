import Foundation

/// Which folder the file explorer treats as the workspace.
enum WorkspaceRootMode: String, CaseIterable, Identifiable, Codable {
    /// Project group root, else the repository, else the terminal's folder.
    case auto

    /// Always the enclosing git repository, even for a terminal sitting
    /// deep inside it.
    case repository

    /// Always the terminal's literal working directory.
    case terminalFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .repository: return "Repository Root"
        case .terminalFolder: return "Terminal Folder"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Project group, else repository, else folder"
        case .repository: return "The enclosing git repository"
        case .terminalFolder: return "Exactly where the terminal is"
        }
    }

    static let defaultsKey = "FileExplorerRootMode"

    static var stored: WorkspaceRootMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = WorkspaceRootMode(rawValue: raw)
        else { return .auto }
        return mode
    }
}

/// Picks the explorer's root folder from what the selected terminal knows
/// about itself.
///
/// A project group already declares a root — that's a workspace the user
/// defined by hand, so it wins. Failing that, a terminal inside a git repo
/// is almost always working on that whole repo rather than the one
/// directory it happens to be `cd`'d into, so the repository root is a
/// better default than the raw pwd. Both of those can be overridden,
/// because "show me exactly this folder" is a legitimate thing to want.
enum WorkspaceRootResolver {
    /// - Parameters:
    ///   - groupRoot: the project group's root, tilde-abbreviated as stored
    ///     in `SidebarGroup.Kind.project(root:)`, or nil for manual and
    ///     ungrouped tabs.
    ///   - repoRoot: the enclosing git repository, already computed by
    ///     `SidebarTabManager.gitInfo`.
    ///   - pwd: the terminal's working directory.
    static func resolve(
        mode: WorkspaceRootMode,
        groupRoot: String?,
        repoRoot: String?,
        pwd: String?
    ) -> String? {
        func expand(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            return (path as NSString).expandingTildeInPath
        }

        switch mode {
        case .terminalFolder:
            return expand(pwd)
        case .repository:
            return expand(repoRoot) ?? expand(pwd)
        case .auto:
            return expand(groupRoot) ?? expand(repoRoot) ?? expand(pwd)
        }
    }
}

/// Lets the titlebar's refresh button reach whichever explorer is on
/// screen without the controller having to hold a reference to it.
///
/// The chrome lives in the window titlebar and the explorer lives in the
/// sidebar pane; they share `SidebarLayoutModel`, but that is per-window
/// state created before any explorer exists. A tiny broadcast keeps the
/// button working without inverting that ownership.
@MainActor
final class FileExplorerRefresh: ObservableObject {
    static let shared = FileExplorerRefresh()

    /// Bumped on every request; explorers watch it and reload.
    @Published private(set) var token = 0

    func request() {
        token &+= 1
    }
}
