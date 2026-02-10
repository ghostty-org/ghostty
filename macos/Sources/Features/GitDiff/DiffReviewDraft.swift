import Foundation

struct DiffReviewDraft: Codable, Equatable {
    var threads: [DiffThread]

    static var empty: DiffReviewDraft { DiffReviewDraft(threads: []) }
}

enum DiffThreadAnchor: Codable, Hashable {
    case line(newLine: Int)
    case hunk(id: String)
}

struct DiffThread: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var anchor: DiffThreadAnchor
    var body: String
    var isResolved: Bool
    var createdAt: Date
    var updatedAt: Date
}

struct DiffReviewContext: Codable, Hashable {
    var repoRoot: String
    var source: GitDiffSource
    var scope: GitDiffScope?
    var pullRequestNumber: Int?
}

