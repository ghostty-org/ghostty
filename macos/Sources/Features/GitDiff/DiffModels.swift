import Foundation

enum DiffDocumentSource: Hashable {
    case workingTree(scope: GitDiffScope)
    case pullRequest(number: Int)
}

struct DiffDocument: Hashable {
    var source: DiffDocumentSource
    var files: [DiffFile]
}

enum DiffFileStatus: String, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case binary
    case combinedUnsupported
    case unknown
}

struct DiffFile: Identifiable, Hashable {
    let pathOld: String?
    let pathNew: String?
    let status: DiffFileStatus
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]

    // Used for binary diffs and unsupported combined diffs.
    let fallbackText: String?
    let isTooLargeToRender: Bool

    var id: String { primaryPath }

    var primaryPath: String {
        (pathNew?.isEmpty == false ? pathNew : nil)
            ?? (pathOld?.isEmpty == false ? pathOld : nil)
            ?? "Diff"
    }

    var displayTitle: String {
        guard let pathOld, let pathNew, !pathOld.isEmpty, !pathNew.isEmpty, pathOld != pathNew else {
            return primaryPath
        }
        return "\(pathNew) \u{2190} \(pathOld)"
    }

    var isBinary: Bool { status == .binary }
    var isCombinedUnsupported: Bool { status == .combinedUnsupported }
}

struct DiffHunk: Identifiable, Hashable {
    let id: String
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]
}

enum DiffLineKind: Hashable {
    case context
    case add
    case del
    case meta
}

struct DiffLine: Identifiable, Hashable {
    let id: String
    let kind: DiffLineKind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}
