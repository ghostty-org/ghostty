import Foundation
import Testing
@testable import Ghostty

struct GitHistoryServiceTests {
    @Test func searchMatchesFullMessageAuthorAndHashAcrossPages() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        for index in 0..<205 {
            try runCommand(["git", "commit", "--allow-empty", "-m", "subject \(index)", "-m", "hidden needle \(index)"], in: directory.path)
        }
        let repository = try await identity(for: directory)
        let service = GitHistoryService()
        let snapshot = try await service.captureSnapshot(for: repository, scope: .allBranches)
        let first = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0, pageSize: 2, query: "NEEDLE")
        let second = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 203, pageSize: 2, query: "needle")
        #expect(first.hasMore && !second.hasMore)
        #expect(Set((first.commits + second.commits).map(\.id)).count == 4)
        #expect(first.commits.allSatisfy { !$0.subject.contains("needle") && $0.message.contains("needle") })
        for query in ["history@example.com", "History Test", "subject", String(first.commits[0].id.rawValue.prefix(8))] {
            let page = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0, query: query)
            #expect(!page.commits.isEmpty)
        }
    }
    private func createTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("git-history-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runCommand(_ args: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_AUTHOR_NAME": "History Test",
            "GIT_AUTHOR_EMAIL": "history@example.com",
            "GIT_COMMITTER_NAME": "History Test",
            "GIT_COMMITTER_EMAIL": "history@example.com",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitHistoryTest", code: Int(process.terminationStatus))
        }
    }

    private func identity(for directory: URL) async throws -> GitRepositoryIdentity {
        let status = await GitRepositoryService().resolveStatus(workingDirectory: directory.path)
        guard let identity = status.repository else {
            throw NSError(domain: "GitHistoryTest", code: 1)
        }
        return identity
    }

    @Test func readsParentsAndFrozenBranchDecorations() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: directory.path)
        try runCommand(["git", "branch", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "second"], in: directory.path)
        try runCommand(["git", "checkout", "feature"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "feature commit"], in: directory.path)
        try runCommand(["git", "checkout", "main"], in: directory.path)
        try runCommand(["git", "checkout", "--detach"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "detached commit"], in: directory.path)

        let repository = try await identity(for: directory)
        let service = GitHistoryService()
        let snapshot = try await service.captureSnapshot(for: repository, scope: .allBranches)
        let page = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0)

        #expect(page.commits.count == 4)
        let featureCommit = try #require(page.commits.first(where: { $0.subject == "feature commit" }))
        #expect(featureCommit.parentIDs.count == 1)
        #expect(featureCommit.refDecorations.contains(where: { $0.name == "feature" }))
        #expect(snapshot.branchName == nil)
        #expect(snapshot.tipCommitIDs.count == 3)
        let detachedCommit = try #require(page.commits.first(where: { $0.subject == "detached commit" }))
        #expect(detachedCommit.refDecorations.contains(where: { $0.kind == .head }))
    }

    @Test func paginationUsesFrozenTipsWhenRefsMove() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        for index in 0..<205 {
            try runCommand(["git", "commit", "--allow-empty", "-m", "commit-\(index)"], in: directory.path)
        }

        let repository = try await identity(for: directory)
        let service = GitHistoryService()
        let snapshot = try await service.captureSnapshot(for: repository, scope: .currentBranch)
        let firstPage = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0)
        try runCommand(["git", "commit", "--allow-empty", "-m", "new-after-snapshot"], in: directory.path)
        let secondPage = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 100)

        #expect(firstPage.commits.count == 100)
        #expect(firstPage.hasMore)
        #expect(secondPage.commits.count == 100)
        #expect(secondPage.commits.allSatisfy { !$0.subject.contains("new-after-snapshot") })
        #expect(Set(firstPage.commits.map(\.id)).isDisjoint(with: secondPage.commits.map(\.id)))
    }

    @Test func fetchWithoutPullMarksRemoteOnlyCommitsAndClearsAfterMerge() async throws {
        let remote = createTempDirectory()
        let local = createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: local)
        }
        try runCommand(["git", "init", "--bare", "-b", "main", "."], in: remote.path)
        try runCommand(["git", "clone", remote.path, "."], in: local.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: local.path)
        try runCommand(["git", "push", "-u", "origin", "main"], in: local.path)

        let seed = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: seed) }
        try runCommand(["git", "clone", remote.path, "seed"], in: seed.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "remote one"], in: seed.path + "/seed")
        try runCommand(["git", "commit", "--allow-empty", "-m", "remote two"], in: seed.path + "/seed")
        try runCommand(["git", "push", "origin", "main"], in: seed.path + "/seed")
        try runCommand(["git", "fetch", "origin"], in: local.path)

        let repository = try await identity(for: local)
        let service = GitHistoryService()
        let snapshot = try await service.captureSnapshot(for: repository, scope: .allBranches)
        #expect(snapshot.remoteOnlyCommitIDs.count == 2)
        let page = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0)
        #expect(page.commits.count == 3)
        #expect(page.commits.prefix(2).allSatisfy { $0.isRemoteOnly })
        #expect(page.commits.last?.subject == "initial" && page.commits.last?.isRemoteOnly == false)

        // Fast-forward the checked-out branch like a plain `git pull` would.
        try runCommand(["git", "reset", "--hard", "origin/main"], in: local.path)
        let merged = try await service.captureSnapshot(for: repository, scope: .allBranches)
        #expect(merged.remoteOnlyCommitIDs.isEmpty)
    }

    @Test func controlCharactersAndEmptySubjectsPreserveHistoryRecordsAndPageBoundaries() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        try runCommand(["git", "commit", "--allow-empty", "--allow-empty-message", "--cleanup=verbatim", "-m", ""], in: directory.path)
        let subject = "first\u{1e}second\t尾部"
        try runCommand(["git", "commit", "--allow-empty", "--cleanup=verbatim", "-m", subject], in: directory.path)
        let repository = try await identity(for: directory)
        let service = GitHistoryService()
        let snapshot = try await service.captureSnapshot(for: repository, scope: .currentBranch)
        let first = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 0, pageSize: 1)
        #expect(first.commits.map(\.subject) == [subject])
        #expect(first.hasMore)
        let second = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 1, pageSize: 1)
        #expect(second.commits.map(\.subject) == [""])
        #expect(second.commits.first?.parentIDs == [])
        #expect(!second.hasMore)
        let last = try await service.loadPage(snapshot: snapshot, repository: repository, offset: 2, pageSize: 1)
        #expect(last.commits.isEmpty && !last.hasMore)
    }
}
