import Foundation

/// One path's state, as git reports it.
///
/// The two letters are git's own `XY`: `X` is what the index has staged,
/// `Y` is what the working tree has on top of it. They're independent, so a
/// file that was staged and then edited again reads `MM` and belongs in
/// *both* the staged and the unstaged list — which is exactly how it looks
/// in VS Code, and why this keeps the raw pair instead of collapsing it
/// into one state.
struct GitFileChange: Identifiable, Equatable, Hashable {
    /// Repository-relative, as git prints it.
    let path: String

    /// Where a renamed or copied file came from.
    let originalPath: String?

    /// Index status. `.` means "nothing staged".
    let index: Character

    /// Working-tree status. `.` means "no unstaged change".
    let worktree: Character

    /// Untracked files have no `XY` at all; git reports them on their own
    /// line type.
    let isUntracked: Bool

    /// Both sides carry a conflict marker.
    let isUnmerged: Bool

    var id: String { path }

    var name: String { (path as NSString).lastPathComponent }

    /// The containing directory, for the dimmed second half of a row.
    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    var isStaged: Bool { !isUntracked && index != "." }
    var hasUnstagedChanges: Bool { isUntracked || worktree != "." }

    /// The single letter shown on the row, matching git's own vocabulary.
    func badge(staged: Bool) -> String {
        if isUnmerged { return "U" }
        if isUntracked { return "U" }
        return String(staged ? index : worktree)
    }

    /// Deleting a file that only ever existed in the working tree is a
    /// filesystem operation, not something git can restore.
    var isUntrackedOnly: Bool { isUntracked }
}

/// A repository's working state: which branch, how it relates to its
/// upstream, and what's changed.
struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0

    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var unmerged: [GitFileChange] = []

    /// A branch with no upstream is one that has never been pushed — the
    /// difference between a "Push" button and a "Publish Branch" one.
    var hasUpstream: Bool { upstream != nil }

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && unmerged.isEmpty }

    var changeCount: Int { staged.count + unstaged.count + unmerged.count }

    /// Detached HEAD reports a literal `(detached)` as the branch name.
    var isDetached: Bool { branch == "(detached)" }
}

extension GitStatus {
    /// Parses `git status --porcelain=v2 --branch`.
    ///
    /// Porcelain v2 is the only status format that is both stable across
    /// git versions (v1 is explicitly not) and complete enough to build the
    /// whole panel from one call: branch, upstream, ahead/behind and every
    /// file's index-and-worktree pair.
    ///
    /// Field counts differ per line type, so each is split with an explicit
    /// `maxSplits` that leaves the path as the untouched remainder — paths
    /// contain spaces and must never be split on them.
    ///
    /// Assumes `-c core.quotePath=false`, without which git C-escapes any
    /// non-ASCII path (`"arquivo-a\303\247\303\243o.ts"`) and every accented
    /// filename would render as gibberish and fail to stage.
    nonisolated static func parse(porcelainV2 output: String) -> GitStatus {
        var status = GitStatus()

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let kind = line.first else { continue }

            switch kind {
            case "#":
                parseHeader(line, into: &status)
            case "1":
                if let change = parseOrdinary(line) { append(change, to: &status) }
            case "2":
                if let change = parseRenamed(line) { append(change, to: &status) }
            case "u":
                if let change = parseUnmerged(line) { status.unmerged.append(change) }
            case "?":
                if let change = parseUntracked(line) { status.unstaged.append(change) }
            default:
                continue
            }
        }

        return status
    }

    /// A file can be in both lists at once — that's the point of keeping
    /// `XY` intact rather than reducing it to a single state.
    private static func append(_ change: GitFileChange, to status: inout GitStatus) {
        if change.isStaged { status.staged.append(change) }
        if change.hasUnstagedChanges { status.unstaged.append(change) }
    }

    private static func parseHeader(_ line: Substring, into status: inout GitStatus) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }

        switch parts[1] {
        case "branch.head":
            status.branch = String(parts[2])
        case "branch.upstream":
            status.upstream = String(parts[2])
        case "branch.ab":
            // "+2 -1" — ahead of upstream by 2, behind by 1.
            for token in parts[2].split(separator: " ") {
                guard let sign = token.first, let value = Int(token.dropFirst()) else { continue }
                if sign == "+" { status.ahead = value }
                if sign == "-" { status.behind = value }
            }
        default:
            break
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ line: Substring) -> GitFileChange? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9, let xy = statusPair(parts[1]) else { return nil }

        return GitFileChange(
            path: String(parts[8]),
            originalPath: nil,
            index: xy.index,
            worktree: xy.worktree,
            isUntracked: false,
            isUnmerged: false
        )
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>\t<origPath>`
    ///
    /// The two paths share the last field, separated by a tab — the one
    /// character a path can't contain.
    private static func parseRenamed(_ line: Substring) -> GitFileChange? {
        let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10, let xy = statusPair(parts[1]) else { return nil }

        let paths = parts[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = paths.first else { return nil }

        return GitFileChange(
            path: String(path),
            originalPath: paths.count > 1 ? String(paths[1]) : nil,
            index: xy.index,
            worktree: xy.worktree,
            isUntracked: false,
            isUnmerged: false
        )
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func parseUnmerged(_ line: Substring) -> GitFileChange? {
        let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11, let xy = statusPair(parts[1]) else { return nil }

        return GitFileChange(
            path: String(parts[10]),
            originalPath: nil,
            index: xy.index,
            worktree: xy.worktree,
            isUntracked: false,
            isUnmerged: true
        )
    }

    /// `? <path>`
    private static func parseUntracked(_ line: Substring) -> GitFileChange? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        return GitFileChange(
            path: String(parts[1]),
            originalPath: nil,
            index: ".",
            worktree: "?",
            isUntracked: true,
            isUnmerged: false
        )
    }

    private static func statusPair(_ field: Substring) -> (index: Character, worktree: Character)? {
        guard field.count == 2 else { return nil }
        return (field[field.startIndex], field[field.index(after: field.startIndex)])
    }
}
