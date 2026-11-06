import Foundation

/// The source of a diff shown by the Git inspector.
enum GitDiffTarget: Hashable, Sendable, Equatable, CustomStringConvertible {
    case commit(GitCommitID)
    case comparison(base: GitCommitID, head: GitCommitID)
    case staged
    case unstaged

    var description: String {
        switch self {
        case .commit(let commit):
            GitL10n.format("commit {0}", String(describing: commit.shortSHA))
        case .comparison(let base, let head):
            "\(base.shortSHA) → \(head.shortSHA)"
        case .staged:
            GitL10n.text("staged changes")
        case .unstaged:
            GitL10n.text("working tree changes")
        }
    }
}

enum GitDiffChangeKind: String, Hashable, Sendable, Equatable {
    case added = "A"
    case copied = "C"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case typeChanged = "T"
    case unmerged = "U"
    case unknown = "?"

    init(status: String) {
        switch status.first.map(String.init) {
        case "A": self = .added
        case "C": self = .copied
        case "D": self = .deleted
        case "M": self = .modified
        case "R": self = .renamed
        case "T": self = .typeChanged
        case "U": self = .unmerged
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .added: GitL10n.text("Added")
        case .copied: GitL10n.text("Copied")
        case .deleted: GitL10n.text("Deleted")
        case .modified: GitL10n.text("Modified")
        case .renamed: GitL10n.text("Renamed")
        case .typeChanged: GitL10n.text("Type changed")
        case .unmerged: "Unmerged"
        case .unknown: GitL10n.text("Changed")
        }
    }
}

struct GitDiffFile: Hashable, Sendable, Equatable, Identifiable {
    let id: String
    let path: String
    let oldPath: String?
    let status: String
    let kind: GitDiffChangeKind
    let isUntracked: Bool

    init(path: String, oldPath: String? = nil, status: String, isUntracked: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.kind = GitDiffChangeKind(status: status)
        self.isUntracked = isUntracked
        self.id = "\(status):\(oldPath ?? ""):\(path)"
    }

    var displayPath: String {
        guard let oldPath, oldPath != path else { return path }
        return "\(oldPath) → \(path)"
    }
}

struct GitDiffCommitBase: Hashable, Sendable {
    let commit: GitCommitID
    let id: String
    let isRoot: Bool
}

struct GitDiffStatistics: Hashable, Sendable {
    let additions: Int
    let deletions: Int
    let binaryFiles: Int
}

struct GitDiffFileList: Hashable, Sendable, Equatable {
    let repository: GitRepositoryIdentity
    let target: GitDiffTarget
    let files: [GitDiffFile]
    let baseDescription: String
    var commitBase: GitDiffCommitBase?
    var statistics: GitDiffStatistics?
}

struct GitCommitMetadata: Hashable, Sendable, Equatable {
    let commitID: GitCommitID
    let authorName: String
    let authorEmail: String?
    let authoredAt: String
    let parents: [GitCommitID]
    let message: String

    var subject: String {
        message.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? GitL10n.text("(no commit message)")
    }

    let body: String

    init(commitID: GitCommitID, authorName: String, authorEmail: String?, authoredAt: String,
         parents: [GitCommitID], message: String) {
        self.commitID = commitID
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.parents = parents
        self.message = message
        let lines = TransientAttachmentNoise.removingNoiseLines(
            from: message.replacingOccurrences(of: "\r\n", with: "\n")
        ).components(separatedBy: "\n")
        if let separator = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            body = lines.dropFirst(separator + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
        } else { body = "" }
    }

    var authorDescription: String {
        guard let authorEmail, !authorEmail.isEmpty else { return authorName }
        return "\(authorName) <\(authorEmail)>"
    }
}

struct GitDiffDocument: Hashable, Sendable, Equatable {
    let file: GitDiffFile
    let text: String
    let isBinary: Bool
    let isTruncated: Bool
    let byteLimit: Int
    let baseDescription: String

    var summary: String? {
        guard isBinary else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? GitL10n.text("Binary file")
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GitDiffServiceError: Error, Sendable, Equatable, LocalizedError {
    case invalidCommit(GitCommitID)
    case invalidPath(String)
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommit(let commit): GitL10n.format("Commit {0} does not exist.", String(describing: commit))
        case .invalidPath(let path): GitL10n.format("The file path is invalid: {0}", String(describing: path))
        case .gitFailed(let message): message
        }
    }
}
