import Foundation

enum GitHistoryError: Error, Equatable, Sendable, LocalizedError {
    case commandFailed(String)
    case malformedCommit(String)
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .malformedCommit(let value): GitL10n.format("Git returned an invalid commit record: {0}", String(describing: value))
        case .invalidDate(let value): GitL10n.format("Git returned an invalid author date: {0}", String(describing: value))
        }
    }
}

struct GitHistoryService: Sendable {
    static let pageSize = 100
    /// Cap the remote-only walk so a never-fetched fork cannot stall snapshots.
    static let remoteOnlyLimit = 4096

    private let executor: (any GitExecutor)?

    init(executor: (any GitExecutor)? = nil) {
        self.executor = executor
    }

    func captureSnapshot(
        for repository: GitRepositoryIdentity,
        scope: GitHistoryScope
    ) async throws -> GitHistorySnapshot {
        async let refsResult = (executor ?? repository.executor).execute(
            arguments: [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%1e",
                "refs/heads",
                "refs/remotes",
                "refs/tags",
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 2 * 1024 * 1024
        )
        async let branchResult = (executor ?? repository.executor).execute(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )
        async let headResult = (executor ?? repository.executor).execute(
            arguments: ["rev-parse", "--quiet", "--verify", "HEAD"],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 16 * 1024
        )
        // Fetched but not pulled: reachable from remote-tracking refs only.
        async let remoteOnlyResult = (executor ?? repository.executor).execute(
            arguments: [
                "rev-list",
                "--max-count=\(Self.remoteOnlyLimit)",
                "--remotes",
                "--not",
                "--branches",
            ],
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: 2 * 1024 * 1024
        )

        let (refs, branch, head, remoteOnly) = try await (refsResult, branchResult, headResult, remoteOnlyResult)
        guard refs.isSuccess else {
            throw GitHistoryError.commandFailed(refs.stderrString)
        }

        let branchName = branch.isSuccess
            ? branch.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let headID = head.isSuccess
            ? GitCommitID(head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil

        var refsByName: [(name: String, id: GitCommitID, kind: GitRefDecorationKind)] = []
        for record in refs.stdout.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let fields = record.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let fullName = (String(bytes: fields[0], encoding: .utf8) ?? "")
                .trimmingCharacters(in: .newlines)
            let objectID = (String(bytes: fields[1], encoding: .utf8) ?? "")
                .trimmingCharacters(in: .newlines)
            let peeledID = fields.count >= 3
                ? (String(bytes: fields[2], encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
                : ""
            let rawID = peeledID.isEmpty ? objectID : peeledID
            guard !fullName.isEmpty, !rawID.isEmpty else { continue }
            let kind: GitRefDecorationKind
            if fullName.hasPrefix("refs/remotes/") {
                kind = .remoteBranch
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                kind = .localBranch
            }
            let name = fullName.replacingOccurrences(of: "^refs/(heads|remotes|tags)/", with: "", options: .regularExpression)
            refsByName.append((name, GitCommitID(rawID), kind))
        }

        var decorations: [GitCommitID: [GitRefDecoration]] = [:]
        for ref in refsByName {
            decorations[ref.id, default: []].append(
                GitRefDecoration(name: ref.name, kind: ref.kind)
            )
        }

        if let headID {
            if let branchName {
                decorations[headID]?.removeAll {
                    $0.name == branchName && $0.kind == .localBranch
                }
                decorations[headID, default: []].append(
                    GitRefDecoration(name: branchName, kind: .currentBranch)
                )
            } else {
                decorations[headID, default: []].append(
                    GitRefDecoration(name: "HEAD", kind: .head)
                )
            }
        }

        let branchRefs = refsByName.filter { $0.kind == .localBranch || $0.kind == .remoteBranch }
        var tipIDs: [GitCommitID]
        switch scope {
        case .currentBranch:
            tipIDs = headID.map { [$0] } ?? []
        case .allBranches:
            tipIDs = branchRefs
                .sorted { $0.name < $1.name }
                .map(\.id)
            if let headID, !tipIDs.contains(headID) {
                tipIDs.append(headID)
            }
        }

        // Keep the order deterministic and avoid asking git to walk the same tip twice.
        var seen = Set<GitCommitID>()
        tipIDs = tipIDs.filter { seen.insert($0).inserted }
        for key in decorations.keys {
            decorations[key]?.sort {
                if $0.name == $1.name {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.name < $1.name
            }
        }

        var remoteOnlyIDs = Set<GitCommitID>()
        if remoteOnly.isSuccess {
            for line in remoteOnly.stdoutString.split(whereSeparator: \.isNewline) {
                let value = line.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { remoteOnlyIDs.insert(GitCommitID(value)) }
            }
        }

        return GitHistorySnapshot(
            scope: scope,
            branchName: branchName,
            headCommitID: headID,
            tipCommitIDs: tipIDs,
            decorationsByCommitID: decorations,
            remoteOnlyCommitIDs: remoteOnlyIDs
        )
    }

    func loadPage(
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity,
        offset: Int,
        pageSize: Int = GitHistoryService.pageSize,
        query: String = "",
        includeMessage: Bool = false
    ) async throws -> GitHistoryPage {
        guard offset >= 0, pageSize > 0 else {
            throw GitHistoryError.commandFailed(GitL10n.text("Invalid Git history page range"))
        }
        guard !snapshot.tipCommitIDs.isEmpty else {
            return GitHistoryPage(commits: [], offset: offset, hasMore: false)
        }

        if !query.isEmpty {
            var matches: [GitHistoryCommit] = []
            var scanned = 0
            var skipped = 0
            while matches.count <= pageSize {
                try Task.checkCancellation()
                let batch = try await loadPage(snapshot: snapshot, repository: repository,
                    offset: scanned, pageSize: 200, includeMessage: true)
                for commit in batch.commits {
                    let text = [commit.subject, commit.message, commit.authorName, commit.authorEmail, commit.id.rawValue]
                        .joined(separator: "\n")
                    guard text.localizedCaseInsensitiveContains(query) else { continue }
                    if skipped < offset { skipped += 1 } else { matches.append(commit) }
                }
                scanned += batch.commits.count
                if !batch.hasMore { break }
            }
            return GitHistoryPage(commits: Array(matches.prefix(pageSize)), offset: offset, hasMore: matches.count > pageSize)
        }

        let requestedCount = pageSize + 1
        let result = try await (executor ?? repository.executor).execute(
            arguments: [
                "log",
                "--encoding=UTF-8",
                "--topo-order",
                "--no-color",
                "--no-decorate",
                "-z",
                "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%" + (includeMessage ? "B" : "s"),
                "--skip=\(offset)",
                "--max-count=\(requestedCount)",
            ] + snapshot.tipCommitIDs.map(\.rawValue),
            workingDirectory: repository.worktreePath,
            stdin: nil,
            maxOutputBytes: max(512 * 1024, requestedCount * 512)
        )
        guard result.isSuccess else {
            throw GitHistoryError.commandFailed(result.stderrString)
        }

        // NUL cannot occur in Git's text fields. `-z` terminates each record,
        // so fixed groups of six fields also preserve empty parents/subjects
        // and legal control characters such as the record separator (0x1e).
        guard result.stdout.isEmpty || result.stdout.last == 0 else {
            throw GitHistoryError.malformedCommit(GitL10n.text("Unterminated history record"))
        }
        let fields: [Data] = result.stdout.isEmpty ? [] : result.stdout.dropLast()
            .split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
        guard fields.count.isMultiple(of: 6) else {
            throw GitHistoryError.malformedCommit(GitL10n.text("Incomplete history record"))
        }
        let recordCount = fields.count / 6
        let hasMore = recordCount > pageSize
        let commits = try (0..<min(pageSize, recordCount)).map { index in
            var commit = try parseCommit(fields: Array(fields[(index * 6)..<(index * 6 + 6)]), snapshot: snapshot)
            commit.isRemoteOnly = snapshot.remoteOnlyCommitIDs.contains(commit.id)
            if includeMessage {
                commit.message = commit.subject
                commit.subject = commit.message.components(separatedBy: "\n").first ?? ""
            }
            return commit
        }
        return GitHistoryPage(commits: commits, offset: offset, hasMore: hasMore)
    }

    private func parseCommit(
        fields: [Data],
        snapshot: GitHistorySnapshot
    ) throws -> GitHistoryCommit {
        let id = GitCommitID(String(bytes: fields[0], encoding: .utf8) ?? "")
        let parentIDs = (String(bytes: fields[1], encoding: .utf8) ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map { GitCommitID(String($0)) }
        let dateValue = String(bytes: fields[4], encoding: .utf8) ?? ""
        guard let date = Self.parseDate(dateValue) else {
            throw GitHistoryError.invalidDate(dateValue)
        }
        return GitHistoryCommit(
            id: id,
            parentIDs: parentIDs,
            authorName: String(bytes: fields[2], encoding: .utf8) ?? "",
            authorEmail: String(bytes: fields[3], encoding: .utf8) ?? "",
            authoredAt: date,
            subject: String(bytes: fields[5], encoding: .utf8) ?? "",
            refDecorations: snapshot.decorationsByCommitID[id] ?? []
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone, .withColonSeparatorInTimeZone]
        return formatter.date(from: value)
    }
}
