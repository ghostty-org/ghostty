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
        scope: GitHistoryScope,
        favoriteRefs: Set<String> = []
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
        case .favorites:
            tipIDs = branchRefs.filter { ref in
                let prefix = ref.kind == .remoteBranch ? "refs/remotes/" : "refs/heads/"
                return favoriteRefs.contains(prefix + ref.name)
            }.sorted { $0.name < $1.name }.map(\.id)
            if favoriteRefs.contains("HEAD"), let headID {
                tipIDs.append(headID)
            }
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
            let search = GitHistorySearchQuery(query)
            guard !search.isEmpty else {
                return try await loadPage(snapshot: snapshot, repository: repository, offset: offset,
                                          pageSize: pageSize, includeMessage: includeMessage)
            }
            let pathMatches = try await commitIDs(touching: search.paths, snapshot: snapshot, repository: repository)
            var matches: [GitHistoryCommit] = []
            var scanned = 0
            var skipped = 0
            while matches.count <= pageSize {
                try Task.checkCancellation()
                let batch = try await loadPage(snapshot: snapshot, repository: repository,
                    offset: scanned, pageSize: 200, includeMessage: true)
                for commit in batch.commits {
                    guard search.matches(commit), pathMatches?.contains(commit.id) ?? true else { continue }
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
                "--stdin",
            ],
            workingDirectory: repository.worktreePath,
            // Keep frozen revisions out of argv: SSH wraps/encodes its command
            // and large all-branch snapshots can exceed the remote shell limit.
            stdin: Data((snapshot.tipCommitIDs.map(\.rawValue).joined(separator: "\n") + "\n").utf8),
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

    /// Commits in the frozen snapshot that changed any of `paths`, or nil when
    /// no path filter is active. Git evaluates the pathspecs (`git log -- path`);
    /// a bare name also matches that file or directory at any depth.
    private func commitIDs(
        touching paths: [String],
        snapshot: GitHistorySnapshot,
        repository: GitRepositoryIdentity
    ) async throws -> Set<GitCommitID>? {
        guard !paths.isEmpty else { return nil }
        let result = try await (executor ?? repository.executor).execute(
            arguments: ["log", "--no-color", "--format=%H", "--stdin", "--"]
                + paths.flatMap(GitHistorySearchQuery.pathspecs(for:)),
            workingDirectory: repository.worktreePath,
            stdin: Data((snapshot.tipCommitIDs.map(\.rawValue).joined(separator: "\n") + "\n").utf8),
            maxOutputBytes: 64 * 1024 * 1024
        )
        guard result.isSuccess else {
            throw GitHistoryError.commandFailed(result.stderrString)
        }
        return Set(result.stdoutString.split(whereSeparator: \.isNewline).map { GitCommitID(String($0)) })
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

/// History search syntax. Plain text keeps the original behavior: a
/// case-insensitive substring of the subject, full message, author name,
/// author email or hash. Field prefixes narrow individual terms and combine
/// with AND: `author:`, `email:`, `path:` (alias `file:`), `message:` (alias
/// `msg:`) and `hash:` (alias `commit:`). Values may be double-quoted to
/// include spaces, e.g. `author:"Jane Doe" path:src/foo.zig`.
struct GitHistorySearchQuery: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case author, email, path, message, hash

        init?(prefix: String) {
            switch prefix.lowercased() {
            case "author": self = .author
            case "email": self = .email
            case "path", "file": self = .path
            case "message", "msg": self = .message
            case "hash", "commit": self = .hash
            default: return nil
            }
        }
    }

    private(set) var text = ""
    private(set) var terms: [Field: [String]] = [:]

    var paths: [String] { terms[.path] ?? [] }
    var isEmpty: Bool { text.isEmpty && terms.values.allSatisfy(\.isEmpty) }
    var messageTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.message] ?? []) }
    var authorTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.author] ?? []) }
    var emailTerms: [String] { (text.isEmpty ? [] : [text]) + (terms[.email] ?? []) }
    var subjectHighlightTerms: [String] { messageTerms + fileTerms }

    /// Highlight needles for a commit's short SHA, including prefix matches on
    /// the full SHA (`hash:` or free text).
    func hashTerms(for id: GitCommitID) -> [String] {
        var result: [String] = []
        if !text.isEmpty {
            if id.shortSHA.localizedCaseInsensitiveContains(text) {
                result.append(text)
            } else if id.rawValue.lowercased().hasPrefix(text.lowercased()) {
                result.append(id.shortSHA)
            }
        }
        for value in terms[.hash] ?? [] where id.rawValue.lowercased().hasPrefix(value.lowercased()) {
            let prefix = String(id.shortSHA.prefix(value.count))
            if !prefix.isEmpty { result.append(prefix) }
        }
        return result
    }

    /// Highlight needles for changed file/folder rows when `path:` or free text
    /// is active. Includes both full path fragments and individual components
    /// so list mode (`src/foo.zig`) and tree mode (`src`, `foo.zig`) both highlight.
    var fileTerms: [String] {
        var result: [String] = text.isEmpty ? [] : [text]
        for raw in paths {
            let cleaned = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "./*?[]"))
            if !cleaned.isEmpty { result.append(cleaned) }
            for part in raw.split(separator: "/") {
                let segment = part.trimmingCharacters(in: CharacterSet(charactersIn: "*?[]"))
                if !segment.isEmpty, segment != "." && segment != ".." {
                    result.append(segment)
                }
            }
        }
        return result
    }

    /// First non-subject body line matching a message/text term when the
    /// commit's subject itself does not contain that term, or the matched
    /// `path:` filter when not already present in the subject.
    func bodySnippet(for commit: GitHistoryCommit) -> String? {
        let missing = messageTerms.filter { !commit.subject.localizedCaseInsensitiveContains($0) }
        if !missing.isEmpty, !commit.message.isEmpty {
            for (index, rawLine) in commit.message.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if index == 0, line == commit.subject.trimmingCharacters(in: .whitespacesAndNewlines) {
                    continue
                }
                if missing.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                    return line
                }
            }
        }
        if !paths.isEmpty,
           !fileTerms.contains(where: { !$0.isEmpty && commit.subject.localizedCaseInsensitiveContains($0) }) {
            return paths.joined(separator: ", ")
        }
        return nil
    }

    init(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var freeText: [String] = []
        var hasField = false
        for token in Self.tokenize(trimmed) {
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex,
               let field = Field(prefix: String(token[..<colon])) {
                // A prefix still being typed (`author:`) filters nothing yet.
                hasField = true
                let value = Self.unquote(String(token[token.index(after: colon)...]))
                if !value.isEmpty { terms[field, default: []].append(value) }
            } else {
                freeText.append(Self.unquote(token))
            }
        }
        // Without field prefixes, keep the exact phrase (including spacing).
        text = hasField ? freeText.joined(separator: " ") : trimmed
    }

    /// Whether the commit satisfies every non-path term. Path terms need
    /// Git's changed-file information and are applied by the service.
    func matches(_ commit: GitHistoryCommit) -> Bool {
        if !text.isEmpty {
            let haystack = [commit.subject, commit.message, commit.authorName, commit.authorEmail, commit.id.rawValue]
                .joined(separator: "\n")
            guard haystack.localizedCaseInsensitiveContains(text) else { return false }
        }
        for value in terms[.author] ?? [] where !commit.authorName.localizedCaseInsensitiveContains(value) {
            return false
        }
        for value in terms[.email] ?? [] where !commit.authorEmail.localizedCaseInsensitiveContains(value) {
            return false
        }
        for value in terms[.message] ?? [] {
            guard commit.subject.localizedCaseInsensitiveContains(value)
                || commit.message.localizedCaseInsensitiveContains(value) else { return false }
        }
        for value in terms[.hash] ?? [] where !commit.id.rawValue.lowercased().hasPrefix(value.lowercased()) {
            return false
        }
        return true
    }

    /// Repository-root pathspecs for one `path:` value. Values with glob
    /// characters are passed as globs; otherwise the exact path (file or
    /// directory) and the same name at any depth both match.
    static func pathspecs(for value: String) -> [String] {
        var path = value
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return [] }
        if path.contains(where: { "*?[".contains($0) }) { return [":(top,glob)\(path)"] }
        return [":(top,literal)\(path)", ":(top,glob)**/\(path)", ":(top,glob)**/\(path)/**"]
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
    }
}
