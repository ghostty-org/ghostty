import Foundation
import Testing
@testable import Ghostty

struct GitMutationServiceTests {
    private func repository() async throws -> GitRepositoryIdentity {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("git-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = directory.resolvingSymlinksInPath().path
        let repo = GitRepositoryIdentity(worktreePath: canonical, gitDirPath: canonical + "/.git",
                                         commonGitDirPath: canonical + "/.git")
        _ = try await git(["init", "-b", "main"], repo)
        _ = try await git(["config", "user.name", "Git Mutation Test"], repo)
        _ = try await git(["config", "user.email", "mutation@example.com"], repo)
        _ = try await git(["config", "commit.gpgSign", "false"], repo)
        _ = try await git(["config", "core.hooksPath", repo.gitDirPath + "/hooks"], repo)
        let root = try await git(["rev-parse", "--show-toplevel"], repo)
        return GitRepositoryIdentity(worktreePath: root, gitDirPath: root + "/.git", commonGitDirPath: root + "/.git")
    }

    private func git(_ args: [String], _ repo: GitRepositoryIdentity) async throws -> String {
        let result = try await LocalGitExecutor().execute(arguments: args, workingDirectory: repo.worktreePath)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func write(_ text: String, _ name: String, _ repo: GitRepositoryIdentity) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: repo.worktreePath).appendingPathComponent(name))
    }

    @Test func batchDiscardHandlesMixedSectionsAndDuplicatePaths() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        for name in ["a", "b", "outside"] { try write("base", name, repo) }
        try await service.perform(.stage(["a", "b", "outside"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        for name in ["a", "b"] { try write("index", name, repo) }
        try await service.perform(.stage(["a", "b"]), in: repo)
        for name in ["a", "b", "outside", "new"] { try write("worktree", name, repo) }
        let staged = try await GitDiffService().listFiles(for: repo, target: .staged).files
        let unstaged = try await GitDiffService().listFiles(for: repo, target: .unstaged).files
        let entries = GitStageBatch.entries(staged: staged.filter { $0.path == "a" }, unstaged: unstaged.filter { $0.path != "outside" })
        // A stale later target must prevent earlier files from being discarded.
        await #expect(throws: (any Error).self) {
            try await service.perform(.discardBatch(.init(entries: entries + [.init(file: .init(path: "missing", status: "M"), section: .unstaged)])), in: repo)
        }
        #expect(try String(contentsOfFile: repo.worktreePath + "/a", encoding: .utf8) == "worktree")
        try await service.perform(.discardBatch(.init(entries: entries)), in: repo)
        #expect(try String(contentsOfFile: repo.worktreePath + "/a", encoding: .utf8) == "base")
        #expect(try String(contentsOfFile: repo.worktreePath + "/b", encoding: .utf8) == "index")
        #expect(try await git(["show", ":b"], repo) == "index")
        #expect(try String(contentsOfFile: repo.worktreePath + "/outside", encoding: .utf8) == "worktree")
        #expect(!FileManager.default.fileExists(atPath: repo.worktreePath + "/new"))
    }

    @Test func discardSeparatesIndexAndWorktreeAndLeavesOtherFilesUntouched() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        let name = "中文 [literal]\nfile.txt"
        try write("base", name, repo)
        try write("other base", "other", repo)
        try await service.perform(.stage([name, "other"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        try write("staged", name, repo)
        try await service.perform(.stage([name]), in: repo)
        try write("unstaged", name, repo)
        try write("untouched", "other", repo)
        let unstaged = try await GitDiffService().listFiles(for: repo, target: .unstaged)
        try await service.perform(.discard(try #require(unstaged.files.first { $0.path == name }), staged: false), in: repo)
        #expect(try String(contentsOfFile: repo.worktreePath + "/" + name, encoding: .utf8) == "staged")
        #expect(try await git(["show", ":" + name], repo) == "staged")
        try write("later edit", name, repo)
        let staged = try await GitDiffService().listFiles(for: repo, target: .staged)
        try await service.perform(.discard(try #require(staged.files.first { $0.path == name }), staged: true), in: repo)
        #expect(try String(contentsOfFile: repo.worktreePath + "/" + name, encoding: .utf8) == "base")
        #expect(try await git(["diff", "--cached", "--name-only"], repo).isEmpty)
        #expect(try String(contentsOfFile: repo.worktreePath + "/other", encoding: .utf8) == "untouched")
    }

    @Test func discardAddedUntrackedDeletedAndRenamedFiles() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("new", "unborn", repo)
        try await service.perform(.stage(["unborn"]), in: repo)
        let unborn = try await GitDiffService().listFiles(for: repo, target: .staged)
        try await service.perform(.discard(try #require(unborn.files.first), staged: true), in: repo)
        #expect(!FileManager.default.fileExists(atPath: repo.worktreePath + "/unborn"))
        try write("base contents", "old", repo)
        try await service.perform(.stage(["old"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        _ = try await git(["mv", "old", "new"], repo)
        let renamed = try await GitDiffService().listFiles(for: repo, target: .staged)
        #expect(renamed.files.first?.kind == .renamed)
        try await service.perform(.discard(try #require(renamed.files.first), staged: true), in: repo)
        #expect(try String(contentsOfFile: repo.worktreePath + "/old", encoding: .utf8) == "base contents")
        #expect(!FileManager.default.fileExists(atPath: repo.worktreePath + "/new"))
        try FileManager.default.removeItem(atPath: repo.worktreePath + "/old")
        let deleted = try await GitDiffService().listFiles(for: repo, target: .unstaged)
        try await service.perform(.discard(try #require(deleted.files.first), staged: false), in: repo)
        #expect(FileManager.default.fileExists(atPath: repo.worktreePath + "/old"))
        try write("remove", "[untracked]", repo)
        try write("keep", "untouched", repo)
        let untracked = try await GitDiffService().listFiles(for: repo, target: .unstaged)
        try await service.perform(.discard(try #require(untracked.files.first { $0.path == "[untracked]" }), staged: false), in: repo)
        #expect(!FileManager.default.fileExists(atPath: repo.worktreePath + "/[untracked]"))
        #expect(FileManager.default.fileExists(atPath: repo.worktreePath + "/untouched"))
        await #expect(throws: (any Error).self) {
            try await service.perform(.discard(GitDiffFile(path: "../outside", status: "M"), staged: false), in: repo)
        }
    }

    @Test func checkedFilesCommitIndexWithoutUnselectedOrLaterWorkingTreeEdits() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("selected version", "中文 selected.txt", repo)
        try write("leave me", "unselected.txt", repo)
        try await service.perform(.stage(["中文 selected.txt", "unselected.txt"]), in: repo)
        try await service.perform(.unstage(["unselected.txt"]), in: repo)
        try write("later unstaged edit", "中文 selected.txt", repo)
        try await service.perform(.commit("only the checked index snapshot\n\nDetails"), in: repo)
        #expect(try await git(["show", "HEAD:中文 selected.txt"], repo) == "selected version")
        #expect(try await git(["ls-tree", "--name-only", "HEAD"], repo) != "unselected.txt")
        let unstaged = try await GitDiffService().listFiles(for: repo, target: .unstaged)
        #expect(Set(unstaged.files.map(\.path)) == ["中文 selected.txt", "unselected.txt"])
        #expect(try await git(["log", "-1", "--format=%B"], repo) == "only the checked index snapshot\n\nDetails")
    }

    @Test func unstageBeforeAndAfterFirstCommitPreservesFiles() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("first", "file.txt", repo)
        try await service.perform(.stage(["file.txt"]), in: repo)
        try write("edited after staging", "file.txt", repo)
        try await service.perform(.unstage(["file.txt"]), in: repo)
        #expect(FileManager.default.fileExists(atPath: repo.worktreePath + "/file.txt"))
        try await service.perform(.stage(["file.txt"]), in: repo)
        try await service.perform(.commit("first"), in: repo)
        try write("second", "file.txt", repo)
        try await service.perform(.stage(["file.txt"]), in: repo)
        try await service.perform(.unstage(["file.txt"]), in: repo)
        #expect(try await git(["diff", "--cached", "--name-only"], repo).isEmpty)
        #expect(try String(contentsOfFile: repo.worktreePath + "/file.txt", encoding: .utf8) == "second")
    }

    @Test func branchCreateSwitchPushAndUpstreamUseSelectedBranch() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        let remotePath = repo.worktreePath + "/remote.git"
        _ = try await git(["init", "--bare", remotePath], repo)
        _ = try await git(["remote", "add", "origin", remotePath], repo)
        try await service.perform(.create(name: "feature/one", start: "refs/heads/main"), in: repo)
        #expect(try await git(["branch", "--show-current"], repo) == "feature/one")
        try write("feature", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("feature"), in: repo)
        let feature = try await git(["rev-parse", "HEAD"], repo)
        try await service.perform(.checkout("main"), in: repo)
        try await service.perform(.push(branch: "feature/one", remote: "origin", destination: "review/one"), in: repo)
        #expect(try await git(["rev-parse", "refs/remotes/origin/review/one"], repo) == feature)
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        try await service.perform(.setUpstream(branch: "feature/one", upstream: "refs/remotes/origin/review/one"), in: repo)
        let branches = try await GitRepositoryService().branches(for: repo)
        #expect(branches.first(where: { $0.name == "feature/one" })?.upstream == "origin/review/one")
        try await service.perform(.create(name: "tracking", start: "refs/remotes/origin/review/one"), in: repo)
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], repo) == "origin/review/one")
        try write("advanced", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("advanced"), in: repo)
        try await service.perform(.push(branch: "tracking", remote: "origin", destination: "review/one"), in: repo)
        let advanced = try await git(["rev-parse", "refs/remotes/origin/review/one"], repo)
        await #expect(throws: (any Error).self) {
            try await service.perform(.push(branch: "feature/one", remote: "origin", destination: "review/one"), in: repo)
        }
        #expect(try await git(["rev-parse", "refs/remotes/origin/review/one"], repo) == advanced)
    }

    @Test func failedCheckoutAndCommitKeepChangesAndDoNotForce() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        try await service.perform(.create(name: "feature", start: "refs/heads/main"), in: repo)
        try write("feature", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("feature"), in: repo)
        try await service.perform(.checkout("main"), in: repo)
        try write("dirty", "file", repo)
        await #expect(throws: (any Error).self) { try await service.perform(.checkout("feature"), in: repo) }
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        #expect(try String(contentsOfFile: repo.worktreePath + "/file", encoding: .utf8) == "dirty")
        try await service.perform(.stage(["file"]), in: repo)
        let hook = repo.gitDirPath + "/hooks/pre-commit"
        try Data("#!/bin/sh\necho test-hook-rejected >&2\nexit 1\n".utf8).write(to: URL(fileURLWithPath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        await #expect(throws: (any Error).self) { try await service.perform(.commit("must fail"), in: repo) }
        #expect(try await git(["diff", "--cached", "--name-only"], repo) == "file")
        #expect(try await git(["log", "-1", "--format=%s"], repo) == "base")
    }

    @Test func commitActionsCreateWithoutSwitchingCompareCherryPickAndRevert() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base\n", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        let base = GitCommitID(try await git(["rev-parse", "HEAD"], repo))
        try await service.perform(.createBranch(name: "feature", commit: base), in: repo)
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        try await service.perform(.checkout("feature"), in: repo)
        try write("feature\n", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("feature"), in: repo)
        let feature = GitCommitID(try await git(["rev-parse", "HEAD"], repo))
        let target = GitDiffTarget.comparison(base: base, head: feature)
        let diff = GitDiffService()
        let files = try await diff.listFiles(for: repo, target: target)
        #expect(files.files.map(\.path) == ["file"])
        let file = try #require(files.files.first)
        let sources = try await diff.sourceVersions(for: file, repository: repo, target: target)
        #expect(sources.before == "base\n" && sources.after == "feature\n")
        #expect(try await diff.loadDiff(for: file, repository: repo, target: target).text.contains("+feature"))
        try await service.perform(.checkout("main"), in: repo)
        try await service.perform(.applyCommit(.cherryPick, feature, mainline: nil), in: repo)
        #expect(try await git(["show", "HEAD:file"], repo) == "feature")
        try await service.perform(.applyCommit(.revert, feature, mainline: nil), in: repo)
        #expect(try await git(["show", "HEAD:file"], repo) == "base")
        try write("dirty", "file", repo)
        await #expect(throws: (any Error).self) { try await service.perform(.applyCommit(.cherryPick, feature, mainline: nil), in: repo) }
        #expect(try String(contentsOfFile: repo.worktreePath + "/file", encoding: .utf8) == "dirty")
        try write("divergent\n", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("divergent"), in: repo)
        do {
            try await service.perform(.applyCommit(.cherryPick, feature, mainline: nil), in: repo)
            Issue.record("Expected cherry-pick conflict")
        } catch GitExecutionError.processFailed(let code, let stderr) {
            #expect(code != 0 && stderr.contains("could not apply"))
        }
        #expect(try await git(["rev-parse", "CHERRY_PICK_HEAD"], repo) == feature.rawValue)
    }

    @Test func worktreesCreateListOpenBranchAndRemoveWithoutDiscardingChanges() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        try write("base", "file", repo)
        try await service.perform(.stage(["file"]), in: repo)
        try await service.perform(.commit("base"), in: repo)
        let linked = repo.worktreePath + "/linked '中文\nline"
        let startingCommit = try await git(["rev-parse", "HEAD"], repo)
        try await service.perform(.addWorktree(path: linked, start: startingCommit, branch: "feature/new", detached: false), in: repo)
        var worktrees = try await GitRepositoryService().worktrees(for: repo)
        #expect(worktrees.count == 2 && worktrees[0].isMain && worktrees[0].isCurrent)
        #expect(worktrees[1].path == linked)
        #expect(worktrees[1].branchRef == "refs/heads/feature/new")
        #expect(worktrees[1].canRemove)
        #expect(try await GitRepositoryService().worktrees(for: repo, includeStatus: true)[1].isDirty == false)
        #expect(try await git(["branch", "--show-current"], repo) == "main")
        try Data("dirty".utf8).write(to: URL(fileURLWithPath: linked + "/file"))
        let dirty = try await GitRepositoryService().worktrees(for: repo, includeStatus: true)[1]
        #expect(dirty.isDirty == true && !dirty.canRemove)
        await #expect(throws: (any Error).self) { try await service.perform(.removeWorktree(linked), in: repo) }
        #expect(try String(contentsOfFile: linked + "/file", encoding: .utf8) == "dirty")
        try Data("base".utf8).write(to: URL(fileURLWithPath: linked + "/file"))
        _ = try await git(["worktree", "lock", "--reason", "test lock", "--", linked], repo)
        worktrees = try await GitRepositoryService().worktrees(for: repo)
        #expect(worktrees[1].lockedReason == "test lock" && !worktrees[1].canRemove)
        await #expect(throws: (any Error).self) { try await service.perform(.removeWorktree(linked), in: repo) }
        _ = try await git(["worktree", "unlock", "--", linked], repo)
        let linkedRepo = GitRepositoryIdentity(worktreePath: linked, gitDirPath: repo.gitDirPath, commonGitDirPath: repo.commonGitDirPath)
        await #expect(throws: (any Error).self) { try await service.perform(.removeWorktree(linked), in: linkedRepo) }
        await #expect(throws: (any Error).self) { try await service.perform(.removeWorktree(repo.worktreePath), in: repo) }
        try await service.perform(.removeWorktree(linked), in: repo)
        #expect(!FileManager.default.fileExists(atPath: linked))
        #expect(try await GitRepositoryService().branches(for: repo).contains { $0.id == "refs/heads/feature/new" })
        try await service.perform(.addWorktree(path: linked, start: "refs/heads/feature/new", branch: nil, detached: false), in: repo)
        #expect(try await GitRepositoryService().worktrees(for: repo).last?.branchRef == "refs/heads/feature/new")
        try await service.perform(.removeWorktree(linked), in: repo)
        try await service.perform(.addWorktree(path: linked, start: "HEAD", branch: nil, detached: true), in: repo)
        #expect(try await GitRepositoryService().worktrees(for: repo).last?.branchRef == nil)
        try await service.perform(.removeWorktree(linked), in: repo)
    }

    @Test func worktreePorcelainPreservesPathsAndFlags() throws {
        let text = "worktree /repo\0bare\0\0worktree /linked\nwith space\0HEAD abc\0detached\0locked line1\nline2\0prunable missing directory\0\0"
        let values = try GitWorktreeInfo.parse(Data(text.utf8), currentPath: "/linked\nwith space")
        #expect(values.count == 2 && values[0].isBare && !values[0].canOpen)
        #expect(values[1].isCurrent && values[1].branchRef == nil && values[1].head == GitCommitID("abc"))
        #expect(values[1].lockedReason == "line1\nline2" && values[1].prunableReason == "missing directory")
        #expect(!values[1].canOpen && !values[1].canRemove)
        #expect(throws: (any Error).self) { try GitWorktreeInfo.parse(Data([0xff]), currentPath: "/") }
    }

    @Test func rejectsPathTraversalAndOptionLikeBranchNames() async throws {
        let repo = try await repository()
        defer { try? FileManager.default.removeItem(atPath: repo.worktreePath) }
        let service = GitMutationService()
        await #expect(throws: (any Error).self) { try await service.perform(.stage(["../outside"]), in: repo) }
        await #expect(throws: (any Error).self) { try await service.perform(.checkout("--discard-changes"), in: repo) }
    }
}
