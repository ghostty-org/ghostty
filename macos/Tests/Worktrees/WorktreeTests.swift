import Foundation
import Testing
@testable import Ghostty

struct WorktreeTests {
    @Test func repoRootReturnsNilForNonRepo() async throws {
        let directory = try TemporaryDirectory()

        let model = GitWorktreeModel()
        let root = await model.repoRoot(forCwd: directory.url)
        let worktrees = await model.worktrees(forCwd: directory.url)

        #expect(root == nil)
        #expect(worktrees.isEmpty)
    }

    @Test func repoRootPinsLinkedWorktreeCwdToMainRepo() async throws {
        let fixture = try GitWorktreeFixture()

        let root = await GitWorktreeModel().repoRoot(forCwd: fixture.featureWorktree.appendingPathComponent("nested"))

        #expect(root?.standardizedFileURL == fixture.main.standardizedFileURL)
    }

    @Test func worktreesEnumeratesMainFirstAndDetachedFallbackBranch() async throws {
        let fixture = try GitWorktreeFixture()

        let worktrees = await GitWorktreeModel().worktrees(forCwd: fixture.featureWorktree)

        #expect(worktrees.count == 3)
        #expect(worktrees.map { $0.path.standardizedFileURL } == [
            fixture.main.standardizedFileURL,
            fixture.featureWorktree.standardizedFileURL,
            fixture.detachedWorktree.standardizedFileURL,
        ])
        #expect(worktrees.first?.path.standardizedFileURL == fixture.main.standardizedFileURL)
        #expect(worktrees.first?.branch == "main")
        #expect(worktrees.first?.isMain == true)
        #expect(worktrees.first?.isDetached == false)

        let branches = Dictionary(uniqueKeysWithValues: worktrees.compactMap { worktree -> (String, Worktree)? in
            guard let branch = worktree.branch else { return nil }
            return (branch, worktree)
        })

        #expect(branches["feature"]?.path.standardizedFileURL == fixture.featureWorktree.standardizedFileURL)
        #expect(branches["feature"]?.isMain == false)
        #expect(branches["feature"]?.isDetached == false)

        #expect(branches[fixture.detachedWorktree.lastPathComponent]?.path.standardizedFileURL == fixture.detachedWorktree.standardizedFileURL)
        #expect(branches[fixture.detachedWorktree.lastPathComponent]?.isMain == false)
        #expect(branches[fixture.detachedWorktree.lastPathComponent]?.isDetached == true)
    }

    @Test func gitFailureFailsSoft() async throws {
        let directory = try TemporaryDirectory()
        let model = GitWorktreeModel(runner: StubGitRunner(result: .failure(status: 128, stderr: "bad git")))

        let root = await model.repoRoot(forCwd: directory.url)
        let worktrees = await model.worktrees(forCwd: directory.url)

        #expect(root == nil)
        #expect(worktrees.isEmpty)
    }

    @Test func gitTimeoutFailsSoft() async throws {
        let directory = try TemporaryDirectory()
        let model = GitWorktreeModel(runner: StubGitRunner(result: .timedOut))

        let root = await model.repoRoot(forCwd: directory.url)
        let worktrees = await model.worktrees(forCwd: directory.url)

        #expect(root == nil)
        #expect(worktrees.isEmpty)
    }

    @Test func createWorktreeAddsSiblingUsingBranchName() async throws {
        let fixture = try GitWorktreeFixture()
        let branch = "topic/new-flow"
        let expected = GitWorktreeModel.defaultNewWorktreePath(repoRoot: fixture.main, branchName: branch)

        let result = await GitWorktreeModel().createWorktree(branchName: branch, forCwd: fixture.main)

        guard case .success(let path) = result else {
            Issue.record("Expected worktree creation to succeed")
            return
        }

        #expect(path.standardizedFileURL == expected.standardizedFileURL)

        let worktrees = await GitWorktreeModel().worktrees(forCwd: fixture.main)
        let created = worktrees.first { $0.branch == branch }
        #expect(created?.path.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test func createWorktreeRejectsEmptyBranchBeforeGit() async throws {
        let directory = try TemporaryDirectory()
        let model = GitWorktreeModel(runner: StubGitRunner(result: .success("unused")))

        let result = await model.createWorktree(branchName: "   ", forCwd: directory.url)

        #expect(result == .failure(.init(message: "Enter a branch name.")))
    }

    @Test func createWorktreeReportsGitFailure() async throws {
        let directory = try TemporaryDirectory()
        let model = GitWorktreeModel(runner: CreateFailureGitRunner())

        let result = await model.createWorktree(branchName: "bad branch", forCwd: directory.url)

        #expect(result == .failure(.init(message: "fatal: invalid branch name")))
    }
}

private struct StubGitRunner: GitCommandRunning {
    let result: GitCommandResult

    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        result
    }
}

private struct CreateFailureGitRunner: GitCommandRunning {
    func runGit(arguments: [String], cwd: URL, timeout: TimeInterval) async -> GitCommandResult {
        if arguments == ["rev-parse", "--git-common-dir"] {
            return .success(".git")
        }
        if arguments.starts(with: ["worktree", "add"]) {
            return .failure(status: 128, stderr: "fatal: invalid branch name")
        }
        return .failure(status: 1, stderr: "unexpected command \(arguments)")
    }
}

private struct GitWorktreeFixture {
    let temporaryDirectory: TemporaryDirectory
    let main: URL
    let featureWorktree: URL
    let detachedWorktree: URL

    init() throws {
        temporaryDirectory = try TemporaryDirectory()
        main = temporaryDirectory.url.appendingPathComponent("main")
        featureWorktree = temporaryDirectory.url.appendingPathComponent("feature")
        detachedWorktree = temporaryDirectory.url.appendingPathComponent("detached-head")

        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"], cwd: main)
        try git(["config", "user.name", "Ghostty Tests"], cwd: main)
        try git(["config", "user.email", "ghostty-tests@example.com"], cwd: main)

        let readme = main.appendingPathComponent("README.md")
        try "fixture\n".write(to: readme, atomically: true, encoding: .utf8)
        try git(["add", "README.md"], cwd: main)
        try git(["commit", "-m", "Initial commit"], cwd: main)

        try git(["branch", "feature"], cwd: main)
        try git(["worktree", "add", featureWorktree.path, "feature"], cwd: main)

        try FileManager.default.createDirectory(
            at: featureWorktree.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )

        let commit = try git(["rev-parse", "HEAD"], cwd: main).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["worktree", "add", "--detach", detachedWorktree.path, commit], cwd: main)
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-worktree-tests")
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@discardableResult
private func git(_ arguments: [String], cwd: URL) throws -> String {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw GitFixtureError(arguments: arguments, status: process.terminationStatus, stderr: error)
    }

    return output
}

private struct GitFixtureError: Error, CustomStringConvertible {
    let arguments: [String]
    let status: Int32
    let stderr: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed with status \(status): \(stderr)"
    }
}
