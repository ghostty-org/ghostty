import Combine
import Foundation

#if os(macOS)

/// Observable view model backing the worktree sidebar.
///
/// The sidebar shell (M1) rendered from a static `WorktreeSidebarDataSource`.
/// This model replaces that seam with reactive state fed by the git data
/// layer (`GitWorktreeModel`): an async `refresh(cwd:)` loads the worktrees
/// for whatever repository the given cwd belongs to, and the SwiftUI list
/// observes the published state so async loads update the UI.
///
/// Workspace switching is out of scope for M2. This model only *exposes* the
/// active/selected worktree (`selectedWorktree`) as observable, driveable
/// state so the M3 switching layer can both read and set it.
@MainActor
final class WorktreeSidebarViewModel: ObservableObject {
    /// All worktrees for the current repository, main pinned first (the model
    /// already returns them in that order — we preserve it).
    @Published private(set) var worktrees: [Worktree] = []

    /// Case-insensitive substring filter applied over branch + directory names.
    @Published var filterText: String = ""

    /// The active/selected worktree. Initialized on each refresh to the
    /// worktree containing the source cwd (the "active" one, highlighted in the
    /// list). Exposed as settable observable state so the M3 switching layer
    /// can read the current selection and drive navigation to a new one.
    @Published var selectedWorktree: Worktree?

    /// Whether a refresh has completed at least once. Used to distinguish the
    /// initial (pre-load) state from a genuinely empty / non-repo result.
    @Published private(set) var hasLoaded: Bool = false

    private let model: GitWorktreeModel
    private(set) var currentCwd: URL?

    init(model: GitWorktreeModel = GitWorktreeModel()) {
        self.model = model
    }

    /// True once a load has completed and the source cwd is not a git
    /// repository (or there is no cwd at all) — drives the "Not a git
    /// repository" empty state.
    var isEmptyState: Bool {
        hasLoaded && worktrees.isEmpty
    }

    /// The worktrees to display, after applying `filterText`.
    var filteredWorktrees: [Worktree] {
        WorktreeSidebar.filter(worktrees, query: filterText)
    }

    /// Load worktrees for the repository containing `cwd`. A nil cwd (e.g. a
    /// window whose first surface reports no pwd and has no configured
    /// working-directory) resolves to the empty state.
    func refresh(cwd: URL?) async {
        currentCwd = cwd

        let loaded: [Worktree]
        if let cwd {
            loaded = await model.worktrees(forCwd: cwd)
        } else {
            loaded = []
        }

        worktrees = loaded
        hasLoaded = true

        // Preserve an existing selection if it still exists after the refresh;
        // otherwise default to the active worktree (the one containing cwd).
        if let selectedWorktree,
           loaded.contains(where: { $0.path == selectedWorktree.path }) {
            // Keep the current selection.
        } else {
            selectedWorktree = WorktreeSidebar.activeWorktree(in: loaded, cwd: cwd)
        }
    }
}

/// Pure, side-effect-free helpers for the sidebar. Kept free of `@MainActor`
/// and async so the presentation logic (active resolution, filtering, display
/// naming, cwd resolution) is trivially unit-testable.
enum WorktreeSidebar {
    /// Display name for a worktree row: the branch name, falling back to the
    /// directory name for a detached HEAD (which has no branch).
    static func displayName(for worktree: Worktree) -> String {
        if let branch = worktree.branch, !branch.isEmpty {
            return branch
        }
        return worktree.path.lastPathComponent
    }

    /// The worktree containing `cwd`, if any. Uses a longest-path-prefix match
    /// so that a cwd inside a linked worktree resolves to that worktree rather
    /// than to the (ancestor) main repository root.
    static func activeWorktree(in worktrees: [Worktree], cwd: URL?) -> Worktree? {
        guard let cwd else { return nil }
        let target = cwd.standardizedFileURL.path

        return worktrees
            .filter { worktree in
                let base = worktree.path.standardizedFileURL.path
                return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
            }
            .max { $0.path.standardizedFileURL.path.count < $1.path.standardizedFileURL.path.count }
    }

    /// Case-insensitive substring filter over branch + directory names. An
    /// empty/whitespace query returns the input unchanged.
    static func filter(_ worktrees: [Worktree], query: String) -> [Worktree] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return worktrees }

        return worktrees.filter { worktree in
            let haystacks = [displayName(for: worktree), worktree.path.lastPathComponent]
            return haystacks.contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
    }

    /// Resolve the cwd to source worktrees from: prefer the surface's live pwd,
    /// falling back to the configured `working-directory` (bare commands report
    /// no pwd — see the research spike). Returns nil when neither is available.
    static func resolveCwd(pwd: String?, configuredWorkingDirectory: String?) -> URL? {
        if let pwd, !pwd.isEmpty {
            return URL(fileURLWithPath: pwd)
        }
        if let configured = configuredWorkingDirectory, !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return nil
    }
}

#endif
