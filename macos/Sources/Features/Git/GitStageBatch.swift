import Foundation

struct GitStageEntry: Equatable, Sendable {
    let file: GitDiffFile
    let section: GitChangeSection
}

/// Selection membership and index state are deliberately separate.
struct GitStageBatch: Equatable, Sendable {
    let entries: [GitStageEntry]
    var isEmpty: Bool { entries.isEmpty }
    var allStaged: Bool { !entries.isEmpty && entries.allSatisfy { $0.section == .staged } }
    var isMixed: Bool { entries.contains { $0.section == .staged } && entries.contains { $0.section == .unstaged } }
    var shouldStage: Bool { !allStaged }
    var files: [GitDiffFile] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.file.path).inserted ? $0.file : nil }
    }
    var paths: Set<String> { Set(entries.flatMap { [$0.file.path] + ($0.file.oldPath.map { [$0] } ?? []) }) }

    /// A staged selection already discards both versions of the same path.
    var discardEntries: [GitStageEntry] {
        let stagedPaths = Set(entries.filter { $0.section == .staged }.map { $0.file.path })
        var seen = Set<String>()
        return entries.filter {
            ($0.section == .staged || !stagedPaths.contains($0.file.path)) && seen.insert($0.file.path).inserted
        }
    }

    static func entries(staged: [GitDiffFile], unstaged: [GitDiffFile]) -> [GitStageEntry] {
        staged.map { .init(file: $0, section: .staged) } + unstaged.map { .init(file: $0, section: .unstaged) }
    }

    static func folders(_ entries: [GitStageEntry]) -> [String: GitStageBatch] {
        var result: [String: [GitStageEntry]] = [:]
        for entry in entries {
            let parts = entry.file.path.split(separator: "/")
            var path = ""
            for part in parts.dropLast() {
                path = path.isEmpty ? String(part) : path + "/" + part
                result[path, default: []].append(entry)
            }
        }
        return result.mapValues { .init(entries: $0) }
    }
}
