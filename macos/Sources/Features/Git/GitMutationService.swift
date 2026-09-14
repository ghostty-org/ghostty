import Foundation

enum GitBranchOperation: String, Equatable, Sendable {
    case checkout
    case create
    case push
    case setUpstream
}

enum GitMutation: Equatable, Sendable {
    case createBranch(name: String, commit: GitCommitID)
    case applyCommit(GitCommitOperation, GitCommitID, mainline: Int?)
    case addWorktree(path: String, start: String, branch: String?, detached: Bool)
    case removeWorktree(String)
    case discard(GitDiffFile, staged: Bool)
    case discardBatch(GitStageBatch)
    case stage([String])
    case unstage([String])
    case commit(String)
    case checkout(String)
    case create(name: String, start: String)
    case push(branch: String, remote: String, destination: String)
    case setUpstream(branch: String, upstream: String)

    var updatesIndexOnly: Bool {
        switch self {
        case .stage, .unstage: true
        default: false
        }
    }

    var indexPaths: [String]? {
        switch self {
        case .stage(let paths), .unstage(let paths): paths
        default: nil
        }
    }

    var title: String {
        switch self {
        case .createBranch: return GitL10n.text("Creating branch…")
        case .applyCommit(let operation, _, _): return operation == .cherryPick ? GitL10n.text("Cherry-picking…") : GitL10n.text("Reverting…")
        case .addWorktree: return GitL10n.text("Creating worktree…")
        case .removeWorktree: return GitL10n.text("Removing worktree…")
        case .discard, .discardBatch: return GitL10n.text("Discarding changes…")
        case .stage: return GitL10n.text("Staging files…")
        case .unstage: return GitL10n.text("Unstaging files…")
        case .commit: return GitL10n.text("Committing…")
        case .checkout: return GitL10n.text("Switching branch…")
        case .create: return GitL10n.text("Creating branch…")
        case .push: return GitL10n.text("Pushing…")
        case .setUpstream: return GitL10n.text("Setting upstream…")
        }
    }
}

struct GitMutationService: Sendable {
    let executor: (any GitExecutor)?
    init(executor: (any GitExecutor)? = nil) { self.executor = executor }

    private func discard(_ file: GitDiffFile, staged: Bool, in repository: GitRepositoryIdentity) async throws {
        let paths = [file.path] + (file.kind == .renamed ? file.oldPath.map { [$0] } ?? [] : [])
        if file.isUntracked {
            // No directory recursion or ignored-file removal. Literal pathspecs keep wildcards inert.
            _ = try await run(["--literal-pathspecs", "clean", "-f", "--"] + paths, in: repository)
        } else {
            var arguments = ["--literal-pathspecs", "restore", "--worktree"]
            if staged {
                let head = try await (executor ?? repository.executor).execute(arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
                    workingDirectory: repository.worktreePath, stdin: nil, maxOutputBytes: 1024)
                let source: String
                if head.isSuccess { source = head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) } else if head.exitCode == 1 {
                    source = try await run(["hash-object", "-w", "-t", "tree", "--stdin"], in: repository, stdin: Data())
                        .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                } else { throw GitExecutionError.processFailed(exitCode: head.exitCode, stderr: head.stderrString) }
                arguments += ["--staged", "--source=" + source]
            }
            _ = try await run(arguments + ["--"] + paths, in: repository)
        }
    }

    func remotes(in repository: GitRepositoryIdentity) async throws -> [String] {
        let result = try await run(["remote"], in: repository)
        return result.stdoutString.split(separator: "\n").map(String.init)
    }

    func perform(_ mutation: GitMutation, in repository: GitRepositoryIdentity) async throws {
        switch mutation {
        case .createBranch(let name, let commit):
            try await validateBranch(name, in: repository)
            try await validateCommit(commit, in: repository)
            _ = try await run(["branch", "--", name, commit.rawValue], in: repository)
        case .applyCommit(let operation, let commit, let mainline):
            guard operation == .cherryPick || operation == .revert else { throw GitDiffServiceError.gitFailed(GitL10n.text("Invalid commit operation.")) }
            try await validateCommit(commit, in: repository)
            let status = try await run(["status", "--porcelain=v1", "-z"], in: repository)
            guard status.stdout.isEmpty else { throw GitDiffServiceError.gitFailed(GitL10n.text("Commit or stash local changes before this operation.")) }
            var arguments = [operation == .cherryPick ? "cherry-pick" : "revert", "--no-edit"]
            if let mainline { arguments += ["--mainline", String(mainline)] }
            _ = try await run(arguments + ["--", commit.rawValue], in: repository)
        case .addWorktree(let path, let start, let branch, let detached):
            try validateWorktreePath(path)
            if start != "HEAD" {
                if start.hasPrefix("refs/") { try validateRef(start) } else { try await validateCommit(GitCommitID(start), in: repository) }
            }
            var arguments = ["worktree", "add"]
            if let branch {
                try await validateBranch(branch, in: repository)
                arguments += ["-b", branch]
            } else if detached { arguments.append("--detach") } else if !start.hasPrefix("refs/heads/") { throw GitDiffServiceError.gitFailed(GitL10n.text("Select a local branch or create a new branch.")) }
            let revision = branch == nil && !detached ? String(start.dropFirst("refs/heads/".count)) : start
            _ = try await run(arguments + ["--", path, revision], in: repository)
        case .removeWorktree(let path):
            try validateWorktreePath(path)
            let worktrees = try await GitRepositoryService(executor: executor).worktrees(for: repository, includeStatus: true)
            guard let worktree = worktrees.first(where: { $0.path == path }), worktree.canRemove else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Cannot remove this worktree: it is current, main, locked, dirty, unavailable, or its status could not be checked."))
            }
            _ = try await run(["worktree", "remove", "--", path], in: repository)
        case .discardBatch(let batch):
            let entries = batch.discardEntries
            // Validate every target before the first destructive operation.
            for section in [GitChangeSection.staged, .unstaged] {
                let selected = entries.filter { $0.section == section }
                guard !selected.isEmpty else { continue }
                let current = try await GitDiffService(executor: executor).listFiles(for: repository, target: section.target)
                for entry in selected {
                    try validate([entry.file.path] + (entry.file.oldPath.map { [$0] } ?? []))
                    guard entry.file.kind != .unmerged else {
                        throw GitDiffServiceError.gitFailed(GitL10n.text("Resolve merge conflicts before discarding changes."))
                    }
                    guard current.files.contains(entry.file) else {
                        throw GitDiffServiceError.gitFailed(GitL10n.text("The file changed. Refresh and try again."))
                    }
                }
            }
            for entry in entries {
                try await discard(entry.file, staged: entry.section == .staged, in: repository)
            }
        case .discard(let file, let staged):
            let paths = [file.path] + (file.kind == .renamed ? file.oldPath.map { [$0] } ?? [] : [])
            try validate(paths)
            guard file.kind != .unmerged else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Resolve merge conflicts before discarding changes."))
            }
            let current = try await GitDiffService(executor: executor).listFiles(for: repository, target: staged ? .staged : .unstaged)
            guard current.files.contains(file) else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("The file changed. Refresh and try again."))
            }
            try await discard(file, staged: staged, in: repository)
        case .stage(let paths):
            try validate(paths)
            if paths.count > 1 {
                _ = try await run(["--literal-pathspecs", "add", "--pathspec-from-file=-", "--pathspec-file-nul"],
                    in: repository, stdin: Data((paths.joined(separator: "\0") + "\0").utf8))
            } else { _ = try await run(["--literal-pathspecs", "add", "--"] + paths, in: repository) }
        case .unstage(let paths):
            try validate(paths)
            // With no explicit revision, path reset also handles an unborn
            // HEAD. Only the selected index entries change; files stay intact.
            if paths.count > 1 {
                _ = try await run(["--literal-pathspecs", "reset", "--quiet", "--pathspec-from-file=-", "--pathspec-file-nul"],
                    in: repository, stdin: Data((paths.joined(separator: "\0") + "\0").utf8))
            } else { _ = try await run(["--literal-pathspecs", "reset", "--quiet", "--"] + paths, in: repository) }
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("Enter a commit message."))
            }
            _ = try await run(["commit", "--file=-"], in: repository, stdin: Data(message.utf8))
        case .checkout(let name):
            try await validateBranch(name, in: repository)
            _ = try await run(["switch", "--no-guess", name, "--"], in: repository)
        case .create(let name, let start):
            try await validateBranch(name, in: repository)
            try validateRef(start)
            _ = try await run(["switch", "-c", name, start, "--"], in: repository)
        case .push(let branch, let remote, let destination):
            try await validateBranch(branch, in: repository)
            try await validateBranch(destination, in: repository)
            guard try await remotes(in: repository).contains(remote) else {
                throw GitDiffServiceError.gitFailed(GitL10n.text("The selected remote no longer exists."))
            }
            _ = try await run(["push", "--porcelain", "--", remote,
                              "refs/heads/\(branch):refs/heads/\(destination)"], in: repository)
        case .setUpstream(let branch, let upstream):
            try await validateBranch(branch, in: repository)
            try validateRef(upstream)
            _ = try await run(["branch", "--set-upstream-to=\(upstream)", "--", branch], in: repository)
        }
    }

    private func validateCommit(_ commit: GitCommitID, in repository: GitRepositoryIdentity) async throws {
        guard commit.rawValue.range(of: "^[a-fA-F0-9]{7,64}$", options: .regularExpression) != nil else {
            throw GitDiffServiceError.invalidCommit(commit)
        }
        _ = try await run(["rev-parse", "--verify", commit.rawValue + "^{commit}"], in: repository)
    }

    private func validateWorktreePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Enter an absolute worktree directory."))
        }
    }

    private func validate(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.allSatisfy({
            !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/").contains("..")
        }) else { throw GitDiffServiceError.gitFailed(GitL10n.text("Invalid file selection.")) }
    }

    private func validateRef(_ ref: String) throws {
        guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/"),
              !ref.contains("\0") else { throw GitDiffServiceError.gitFailed(GitL10n.text("Invalid branch reference.")) }
    }

    private func validateBranch(_ name: String, in repository: GitRepositoryIdentity) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.contains("@{") else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Invalid branch name."))
        }
        _ = try await run(["check-ref-format", "--branch", name], in: repository)
    }

    private func run(_ arguments: [String], in repository: GitRepositoryIdentity,
                     stdin: Data? = nil) async throws -> GitExecutionResult {
        let result = try await (executor ?? repository.executor).execute(arguments: arguments, workingDirectory: repository.worktreePath,
                                                stdin: stdin, maxOutputBytes: 1024 * 1024)
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result
    }
}
