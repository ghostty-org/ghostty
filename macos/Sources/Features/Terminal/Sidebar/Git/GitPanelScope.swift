import Foundation

/// What the Git panel is looking at.
///
/// A terminal that isn't in a repository used to mean one thing — "nothing
/// to show". It actually means two, and the difference is the whole point
/// of this type: a folder that *contains* repositories (a workspace like
/// `~/Projects/Aurora`, with several checkouts side by side) is somewhere
/// the panel has plenty to say, while a folder with nothing underneath it
/// really is empty.
///
/// Collapsing those two into one nil is what made the panel answer "this
/// terminal isn't in a git repository" while sitting on top of five of
/// them.
enum GitPanelScope: Equatable {
    /// The terminal is inside a repository. One repo, shown flat — this is
    /// the original panel and nothing about it changes.
    case repository(String)

    /// The terminal's folder isn't a repository but holds some. Each one
    /// gets its own collapsible section.
    case workspace(root: String, repos: [String])

    /// Nothing here, and nothing underneath.
    case none

    /// - Parameters:
    ///   - repoRoot: the enclosing repository, already computed without a
    ///     subprocess by `SidebarTabManager.gitInfo`.
    ///   - pwd: the terminal's working directory.
    ///   - discovered: repositories found under `pwd`, or nil while that
    ///     scan hasn't answered yet. Nil and `[]` are deliberately
    ///     different: the first is "still looking", the second is
    ///     "looked, found nothing". Passing `[]` for both would flash the
    ///     empty state on every tab switch.
    static func resolve(
        repoRoot: String?,
        pwd: String?,
        discovered: [String]?
    ) -> GitPanelScope {
        if let repoRoot, !repoRoot.isEmpty {
            return .repository(repoRoot)
        }

        guard let pwd, !pwd.isEmpty, let discovered, !discovered.isEmpty else {
            return .none
        }
        return .workspace(root: pwd, repos: discovered)
    }

    /// Every repository this scope covers, for the callers that need to ask
    /// git about all of them at once.
    var repos: [String] {
        switch self {
        case .repository(let root): return [root]
        case .workspace(_, let repos): return repos
        case .none: return []
        }
    }
}

/// Which repositories in a workspace start open.
///
/// The rule is "whatever needs attention", but it has to yield the moment
/// the user disagrees — otherwise a repo they deliberately collapsed would
/// spring open again the next time a file changed in it, and one they
/// opened would snap shut on the next clean status.
enum GitRepoExpansion {
    /// - Parameters:
    ///   - manual: what the user set for this repo by clicking, or nil if
    ///     they haven't touched it.
    ///   - status: the repo's status, or nil while it is still loading.
    static func isExpanded(manual: Bool?, status: GitStatus?) -> Bool {
        if let manual { return manual }
        guard let status else { return false }
        return !status.isClean
    }

    /// Whether a rule is drawn above the section at `index`.
    ///
    /// Only around a section that is open: expanded content runs straight
    /// into the next header with nothing to say it ended. Two collapsed
    /// sections in a row need no line — stacked headers already read as a
    /// list, which is exactly how they looked before any of this existed.
    ///
    /// Taking both neighbours into account is what keeps an expanded
    /// section from getting a line on one side only.
    static func needsDivider(above index: Int, expanded: [Bool]) -> Bool {
        guard index > 0, index < expanded.count else { return false }
        return expanded[index - 1] || expanded[index]
    }
}
