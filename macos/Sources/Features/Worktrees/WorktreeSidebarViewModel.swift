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

    /// Invoked when the user picks a worktree row. The M3 switching layer
    /// (TerminalController) wires this to the workspace switch; selection
    /// state is then updated by the switcher, so the highlight tracks the
    /// active workspace rather than the click.
    var onSelect: ((Worktree) -> Void)?

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
        //
        // TODO(worktree-sidebar): a worktree deleted on disk while its
        // workspace is open disappears from this list, orphaning the (still
        // usable) workspace. Mark such rows as missing instead of dropping
        // them so the user can still reach and close that workspace.
        if let selectedWorktree,
           loaded.contains(where: { $0.path == selectedWorktree.path }) {
            // Keep the current selection.
        } else {
            selectedWorktree = WorktreeSidebar.activeWorktree(in: loaded, cwd: cwd)
        }
    }

    /// Forward a row click to the switching layer (see `onSelect`).
    func select(_ worktree: Worktree) {
        onSelect?(worktree)
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

    /// The worktree `offset` steps away from `current` in sidebar order,
    /// wrapping around either end. `current` is matched by standardized path;
    /// when it is nil or not in the list, the first worktree is returned so
    /// cycling from an unknown state lands somewhere deterministic. Returns
    /// nil for an empty list or when the result would be `current` itself
    /// (a single-entry list): there is nothing to switch to.
    static func cycleTarget(in worktrees: [Worktree], from current: URL?, offset: Int) -> Worktree? {
        guard !worktrees.isEmpty else { return nil }

        let currentPath = current?.standardizedFileURL.path
        guard let index = worktrees.firstIndex(where: {
            $0.path.standardizedFileURL.path == currentPath
        }) else {
            return worktrees.first
        }

        let count = worktrees.count
        let target = ((index + offset) % count + count) % count
        guard target != index else { return nil }
        return worktrees[target]
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
