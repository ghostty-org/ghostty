import Combine
import Foundation
import Testing
@testable import Ghostty

private actor IndexExecutionProbe: GitExecutor {
    private(set) var commands: [[String]] = []
    private(set) var inputs: [Data?] = []
    private(set) var maximumConcurrentWrites = 0
    private var activeWrites = 0
    private var failurePath: String?
    private var timeOutWrite = false
    private let executor: any GitExecutor
    init(executor: any GitExecutor = LocalGitExecutor()) { self.executor = executor }
    func timeoutNextWrite() { timeOutWrite = true }
    func fail(_ path: String?) { failurePath = path }
    func clear() { commands = []; inputs = []; maximumConcurrentWrites = 0 }
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        commands.append(arguments)
        inputs.append(stdin)
        let writes = arguments.contains("add") || arguments.contains("reset")
        if writes {
            activeWrites += 1
            maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        }
        defer { if writes { activeWrites -= 1 } }
        if writes {
            if timeOutWrite { timeOutWrite = false; throw GitExecutionError.timedOut }
            try await Task.sleep(for: .milliseconds(60))
            if let failurePath, arguments.contains(failurePath) || stdin.map({ data in
                data.split(separator: 0).contains { String(bytes: $0, encoding: .utf8) == failurePath }
            }) == true {
                return .init(exitCode: 1, stdout: Data(), stderr: Data("Injected index write failure".utf8))
            }
        }
        return try await executor.execute(arguments: arguments, workingDirectory: workingDirectory,
                                                     stdin: stdin, maxOutputBytes: maxOutputBytes)
    }
}

@MainActor
struct GitIndexQueueTests {
    @Test(arguments: [false, true]) func bulkWritesUseOneCommandAndOneStatusRefresh(remote: Bool) async throws {
        let server = remote ? try await GitSSHTestServer() : nil
        defer { server?.stop() }
        let executor: any GitExecutor
        if let server { executor = SSHGitExecutor(connection: server.connection) } else { executor = LocalGitExecutor() }
        let probe = IndexExecutionProbe(executor: executor)
        let names = (0..<1100).map { "output/result-\($0).json" } + ["literal [one]*.txt", "换行\n文件.cpp"]
        let fixture = try await Fixture(files: names, probe: probe, server: server)
        defer { fixture.close() }
        let initial = fixture.content
        var stagedCounts: [Int] = []
        let observation = fixture.registry.contentChanges.sink { _ in stagedCounts.append(fixture.content.workingTree.staged.count) }
        defer { observation.cancel() }
        fixture.send(.setFilesStaged(initial.workingTree.unstaged, true))
        let staged = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == names.count }
        let commands = await probe.commands
        #expect(commands.filter { $0.contains("add") }.count == 1)
        #expect(commands.filter { $0.contains("status") }.count == 1)
        #expect(commands.first { $0.contains("add") }?.contains("--pathspec-from-file=-") == true)
        let payload = try #require(await probe.inputs.compactMap { $0 }.first)
        #expect(Set(payload.split(separator: 0).map { String(bytes: $0, encoding: .utf8) }) == Set(names))
        #expect(Set(stagedCounts).isSubset(of: [0, names.count]))
        #expect(staged.history == initial.history && staged.pendingIndexPaths.isEmpty)
        await probe.clear()
        fixture.send(.setFilesStaged(staged.workingTree.staged, false))
        let unstaged = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.isEmpty }
        #expect(unstaged.workingTree.unstaged.count == names.count)
        #expect(await probe.commands.filter { $0.contains("reset") }.count == 1)
        #expect(await probe.commands.filter { $0.contains("status") }.count == 1)
    }

    @Test func closingTabDropsGitPresentationState() async throws {
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: ["a.txt"], probe: probe)
        defer { fixture.close() }
        fixture.send(.updateCommitDraft("draft owned by closed tab"))
        fixture.registry.closeTab(fixture.context.tabID)
        fixture.provider.forgetTab(fixture.context.tabID)
        fixture.registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: fixture.context)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.registry.isTabClosed(fixture.context.tabID))
        if case .git = fixture.registry.content(for: BuiltInGitInspectorProvider.paneID, context: fixture.context) {
            Issue.record("A closed tab must not recreate its Git snapshot")
        }
        fixture.registry.openTab(fixture.context.tabID)
        fixture.registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: fixture.context)
        let restored = try await fixture.wait { $0.repository != nil && !$0.isLoading && !$0.history.isLoading }
        #expect(restored.commitDraft == "draft owned by closed tab")
    }

    @Test func revisitingReadyGitPaneUsesSnapshotWithoutStartingAnotherQuery() async throws {
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: ["file.txt"], probe: probe)
        defer { fixture.close() }
        fixture.send(.updateCommitDraft("retained draft"))
        fixture.registry.presentationDidChange(to: nil, context: fixture.context)
        await probe.clear()
        fixture.registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: fixture.context)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.commands.isEmpty)
        #expect(fixture.content.commitDraft == "retained draft")
    }

    @Test func batchTimeoutClearsPendingAndAllowsTheNextOperation() async throws {
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: ["dir/a", "dir/b"], probe: probe)
        defer { fixture.close() }
        await probe.timeoutNextWrite()
        fixture.send(.setFilesStaged(fixture.content.workingTree.unstaged, true))
        let failed = try await fixture.wait { $0.operation == nil && $0.operationError != nil }
        #expect(failed.pendingIndexPaths.isEmpty && !failed.isUpdatingIndex)
        #expect(failed.workingTree.staged.isEmpty)
        #expect(await probe.commands.filter { $0.contains("status") }.isEmpty)
        fixture.send(.setFilesStaged(failed.workingTree.unstaged, true))
        _ = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 2 }
    }

    @MainActor private final class Fixture {
        let root: URL
        let registry = InspectorRegistry()
        let context: InspectorPaneContext
        let provider: BuiltInGitInspectorProvider
        init(files: [String], probe: IndexExecutionProbe, server: GitSSHTestServer? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("git-index-queue-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let result = try await LocalGitExecutor().execute(arguments: ["init", "-b", "main"], workingDirectory: root.path)
            try #require(result.isSuccess)
            _ = try await LocalGitExecutor().execute(arguments: ["config", "core.excludesFile", "/dev/null"], workingDirectory: root.path)
            for name in files {
                let file = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("original\n".utf8).write(to: file)
            }
            context = .init(tabID: UUID(), surfaceID: UUID(), title: "Index test", workingDirectory: root.path, session: server?.session(directory: root.path))
            provider = BuiltInGitInspectorProvider(registry: registry, executor: probe)
            try provider.register()
            registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
            _ = try await wait { $0.history.snapshot != nil && !$0.history.isLoading && $0.workingTree.unstaged.count == files.count }
            send(.selectTab(.changes))
            await probe.clear()
        }
        var content: InspectorGitContent {
            guard case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context) else { preconditionFailure("Missing Git content") }
            return value
        }
        func send(_ action: InspectorGitAction) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID, action: .init(context: context, kind: .gitAction(action)))
        }
        func wait(_ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<500 {
                if predicate(content) { return content }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "IndexQueueTimeout", code: 1)
        }
        func close() {
            registry.presentationDidChange(to: nil, context: context)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func rapidOperationsInLargeWorktreePublishEveryCountAndQueryOnlyTouchedPaths() async throws {
        let names = (0..<1200).map { "output/result-\($0).json" } + ["literal[1]*.cpp"]
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: names, probe: probe)
        defer { fixture.close() }
        let initial = fixture.content
        let selected = Array(initial.workingTree.unstaged.prefix(3))
        var counts: [(Int, Int)] = []
        let observation = fixture.registry.contentChanges.sink { _ in
            let content = fixture.content
            counts.append((content.workingTree.staged.count, content.workingTree.unstaged.count))
        }
        defer { observation.cancel() }
        for file in selected { fixture.send(.setFileStaged(file, true)) }
        #expect(fixture.content.pendingIndexPaths == Set(selected.map(\.path)))
        #expect(fixture.content.workingTree.staged.isEmpty)
        let staged = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == selected.count }
        #expect(staged.pendingIndexPaths.isEmpty)
        #expect(staged.history == initial.history && staged.activeTab == .changes)
        #expect(await probe.maximumConcurrentWrites == 1)
        for count in 1...selected.count { #expect(counts.contains { $0.0 == count && $0.1 == names.count - count }) }
        #expect(counts.allSatisfy { $0.0 + $0.1 == names.count })
        let commands = await probe.commands
        let statuses = commands.filter { $0.contains("status") }
        #expect(statuses.count == selected.count)
        #expect(statuses.allSatisfy { $0.contains("--literal-pathspecs") && $0.last != "--" })
        #expect(Set(statuses.compactMap(\.last)) == Set(selected.map(\.path)))
        #expect(!commands.contains { $0.contains("log") || $0.contains("for-each-ref") || $0.contains("worktree") })
        for file in staged.workingTree.staged { fixture.send(.setFileStaged(file, false)) }
        let restored = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.isEmpty }
        #expect(restored.workingTree.unstaged == initial.workingTree.unstaged)
        #expect(await probe.maximumConcurrentWrites == 1)
    }

    @Test func failedFileRetainsOriginalStateWhileOtherQueuedFilesComplete() async throws {
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: ["fail.cpp", "good.cpp"], probe: probe)
        defer { fixture.close() }
        await probe.fail("fail.cpp")
        for file in fixture.content.workingTree.unstaged { fixture.send(.setFileStaged(file, true)) }
        let result = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 1 }
        #expect(result.workingTree.staged.map(\.path) == ["good.cpp"])
        #expect(result.workingTree.unstaged.map(\.path) == ["fail.cpp"])
        #expect(result.pendingIndexPaths.isEmpty)
        #expect(result.operationError?.contains("Injected index write failure") == true)
        await probe.fail(nil)
        fixture.send(.setFileStaged(try #require(result.workingTree.unstaged.first), true))
        let retried = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 2 }
        #expect(retried.operationError == nil && retried.workingTree.unstaged.isEmpty)
    }

    @Test func indexPatchKeepsPartiallyStagedFilesOnBothSidesAndLeavesUnrelatedDataAlone() async throws {
        let probe = IndexExecutionProbe()
        let fixture = try await Fixture(files: ["partial.cpp", "other.cpp"], probe: probe)
        defer { fixture.close() }
        let partial = try #require(fixture.content.workingTree.unstaged.first { $0.path == "partial.cpp" })
        fixture.send(.setFileStaged(partial, true))
        _ = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 1 }
        try Data("a later working-tree edit\n".utf8).write(to: fixture.root.appendingPathComponent("partial.cpp"))
        fixture.send(.refresh)
        let both = try await fixture.wait { $0.workingTree.unstaged.contains { $0.path == "partial.cpp" && !$0.isUntracked } }
        #expect(both.workingTree.staged.map(\.path) == ["partial.cpp"])
        let other = try #require(both.workingTree.unstaged.first { $0.path == "other.cpp" })
        fixture.send(.setFileStaged(other, true))
        let stagedOther = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 2 }
        #expect(stagedOther.workingTree.unstaged.map(\.path) == ["partial.cpp"])
        #expect(stagedOther.workingTree.unstaged.first?.isUntracked == false)
        fixture.send(.setFileStaged(try #require(stagedOther.workingTree.staged.first { $0.path == "partial.cpp" }), false))
        let unstaged = try await fixture.wait { $0.operation == nil && $0.workingTree.staged.count == 1 }
        #expect(unstaged.workingTree.staged.map(\.path) == ["other.cpp"])
        #expect(unstaged.workingTree.unstaged.first?.isUntracked == true)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("partial.cpp"), encoding: .utf8) == "a later working-tree edit\n")
    }
}
