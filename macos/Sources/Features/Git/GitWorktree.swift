import Foundation

struct GitWorktreeInfo: Equatable, Sendable, Identifiable {
    let path: String
    let head: GitCommitID?
    let branchRef: String?
    let isMain: Bool
    let isCurrent: Bool
    var isBare = false
    var lockedReason: String?
    var prunableReason: String?
    var isDirty: Bool?
    var statusError: String?
    var id: String { path }
    var branchName: String { branchRef.map { String($0.dropFirst("refs/heads/".count)) } ?? "Detached HEAD" }
    var canOpen: Bool { !isBare && prunableReason == nil }
    var canRemove: Bool { !isMain && !isCurrent && !isBare && lockedReason == nil && prunableReason == nil && isDirty != true && statusError == nil }

    static func parse(_ data: Data, currentPath: String) throws -> [GitWorktreeInfo] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Worktree paths could not be decoded as UTF-8."))
        }
        var result: [GitWorktreeInfo] = []
        var fields: [String: String] = [:]
        func append() {
            guard let path = fields["worktree"] else { return }
            // Git uses the null object ID for a worktree before its first commit.
            let head = fields["HEAD"].flatMap { value in
                value.isEmpty || value.allSatisfy { $0 == "0" } ? nil : GitCommitID(value)
            }
            result.append(GitWorktreeInfo(path: path, head: head,
                branchRef: fields["branch"], isMain: result.isEmpty,
                isCurrent: (path as NSString).standardizingPath == (currentPath as NSString).standardizingPath,
                isBare: fields["bare"] != nil, lockedReason: fields["locked"], prunableReason: fields["prunable"]))
            fields.removeAll(keepingCapacity: true)
        }
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty { append(); continue }
            let parts = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        append()
        return result
    }
}

extension GitRepositoryService {
    func worktrees(for repository: GitRepositoryIdentity, includeStatus: Bool = false) async throws -> [GitWorktreeInfo] {
        let result = try await (executor ?? repository.executor).execute(arguments: ["worktree", "list", "--porcelain", "-z"],
            workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 512 * 1024)
        guard result.isSuccess else { throw GitDiffServiceError.gitFailed(result.stderrString) }
        let currentPath: String
        switch repository.target {
        case .local: currentPath = URL(fileURLWithPath: repository.worktreePath).resolvingSymlinksInPath().path
        case .ssh: currentPath = repository.worktreePath
        }
        var worktrees = try GitWorktreeInfo.parse(result.stdout, currentPath: currentPath)
        if includeStatus {
            let execution = executor ?? repository.executor
            // Bound concurrent status processes for repositories with many worktrees.
            for start in stride(from: 0, to: worktrees.count, by: 4) {
                let batch = Array(worktrees[start..<min(start + 4, worktrees.count)])
                let updated = await withTaskGroup(of: GitWorktreeInfo.self, returning: [GitWorktreeInfo].self) { group in
                    for worktree in batch where worktree.canOpen {
                        group.addTask {
                            var value = worktree
                            do {
                                let status = try await execution.execute(arguments: ["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=normal"],
                                    workingDirectory: worktree.path, stdin: nil, maxOutputBytes: 512 * 1024)
                                guard status.isSuccess else { throw GitDiffServiceError.gitFailed(status.stderrString) }
                                value.isDirty = !status.stdout.isEmpty
                            } catch { value.statusError = error.localizedDescription }
                            return value
                        }
                    }
                    var values: [GitWorktreeInfo] = []
                    for await value in group { values.append(value) }
                    return values
                }
                for value in updated { if let index = worktrees.firstIndex(where: { $0.id == value.id }) { worktrees[index] = value } }
                try Task.checkCancellation()
            }
        }
        return worktrees
    }
}
