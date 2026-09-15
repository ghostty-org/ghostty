import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct BuiltInGitInspectorProviderTests {
    private actor CountingExecutor: GitExecutor {
        var count = 0
        func execute(arguments: [String], workingDirectory: String, stdin: Data?,
                     maxOutputBytes: Int?) async throws -> GitExecutionResult {
            count += 1
            return try await LocalGitExecutor().execute(arguments: arguments,
                workingDirectory: workingDirectory, stdin: stdin, maxOutputBytes: maxOutputBytes)
        }
    }

    @Test(arguments: [InspectorGitContent.ActiveTab.history, .branches])
    func unchangedPollingSkipsCommandsAndFileEditsStillRefresh(tab: InspectorGitContent.ActiveTab) async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: dir.path)
        try runCommand(["git", "config", "core.fsmonitor", "true"], in: dir.path)
        let executor = CountingExecutor()
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, executor: executor)
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: UUID(), title: "test", workingDirectory: dir.path)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: context)
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.selectTab(tab))))
        defer { registry.presentationDidChange(to: nil, context: context) }
        try await Task.sleep(for: .seconds(1))
        provider.pollPresentedTabs() // Consume the initial watch snapshot.
        try await Task.sleep(for: .seconds(1))
        let before = await executor.count
        #expect(before > 0)
        for _ in 0..<3 {
            provider.pollPresentedTabs()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await executor.count == before)
        try Data("new file".utf8).write(to: dir.appendingPathComponent("change.txt"))
        var found = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            provider.pollPresentedTabs()
            if case .git(let content) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
               content.workingTree.unstaged.contains(where: { $0.path == "change.txt" }) {
                found = true; break
            }
        }
        #expect(found)
        #expect(await executor.count > before)
        let refreshed = await executor.count
        registry.performAction(paneID: BuiltInGitInspectorProvider.paneID,
                               action: .init(context: context, kind: .gitAction(.refresh)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await executor.count > refreshed)
    }

    @Test func commandLaunchProvidesRepositoryContextBeforeAnyShellPrompt() async throws {
        let directory = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try runCommand(["git", "init", "-b", "main"], in: directory.path)
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = directory.path
        configuration.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: configuration)
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.surfaceTree.first)
        #expect(surface.pwd == directory.path)
        let session = try #require(controller.paneSessionContext(for: surface))
        #expect(session.workingDirectory == directory.path)
        let status = await GitRepositoryService().resolveStatus(workingDirectory: session.workingDirectory, session: session)
        #expect(status.repository != nil)
        // A later OSC 7 update still wins over the launch directory.
        let subdirectory = directory.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        surface.pwd = subdirectory.path
        #expect(controller.paneSessionContext(for: surface)?.workingDirectory == subdirectory.path)
    }

    private func createTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-provider-test-\(UUID().uuidString)")
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
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestCommand", code: Int(process.terminationStatus))
        }
    }

    @Test func registersGitInspectorPaneDescriptor() throws {
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()

        let descriptor = try #require(registry.descriptor(id: BuiltInGitInspectorProvider.paneID))
        #expect(descriptor.title == "Git")
        #expect(descriptor.systemImage == "arrow.triangle.branch")
        #expect(descriptor.preferredWidth == RightInspectorMetrics.defaultWidth)
    }

    @Test func loadsRepositoryOnAppeared() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "first commit"], in: dir.path)
        try runCommand(["git", "worktree", "add", "--detach", "--", dir.path + "/linked"], in: dir.path)

        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()

        let tabID = UUID()
        let context = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: dir.path
        )

        registry.presentationDidChange(
            to: BuiltInGitInspectorProvider.paneID,
            context: context
        )

        // Allow async load to complete
        for _ in 0..<30 {
            if case .git(let content) = registry.content(
                for: BuiltInGitInspectorProvider.paneID,
                context: context
            ), case .ready = content.status {
                #expect(content.workingTree.worktreesError == nil)
                #expect(content.workingTree.worktrees.count == 2)
                #expect(content.workingTree.worktrees.first?.isCurrent == true)
                #expect(content.workingTree.worktrees.last?.branchRef == nil)
                #expect(content.branch == "main")
                #expect(content.repository?.worktreePath.hasSuffix(dir.lastPathComponent) == true)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        Issue.record("Timed out waiting for repository status to become ready")
    }

    @Test func switchesTabAndPreservesAcrossSameWorktreeSubdirectories() async throws {
        let dir = createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try runCommand(["git", "init", "-b", "main"], in: dir.path)
        try runCommand(["git", "commit", "--allow-empty", "-m", "initial"], in: dir.path)

        let subDir = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()

        let tabID = UUID()
        let context1 = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: dir.path
        )

        registry.presentationDidChange(
            to: BuiltInGitInspectorProvider.paneID,
            context: context1
        )

        // Wait for ready
        for _ in 0..<30 {
            if case .git(let content) = registry.content(
                for: BuiltInGitInspectorProvider.paneID,
                context: context1
            ), case .ready = content.status {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Select Changes tab
        registry.performAction(
            paneID: BuiltInGitInspectorProvider.paneID,
            action: .init(context: context1, kind: .gitAction(.selectTab(.changes)))
        )

        guard case .git(let changedTabContent) = registry.content(
            for: BuiltInGitInspectorProvider.paneID,
            context: context1
        ) else {
            Issue.record("Expected .git content")
            return
        }
        #expect(changedTabContent.activeTab == InspectorGitContent.ActiveTab.changes)

        // Switch to subdirectory of same worktree
        let context2 = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: subDir.path
        )

        registry.presentationDidChange(
            to: BuiltInGitInspectorProvider.paneID,
            context: context2
        )

        for _ in 0..<30 {
            if case .git(let content) = registry.content(
                for: BuiltInGitInspectorProvider.paneID,
                context: context2
            ), case .ready = content.status {
                #expect(content.activeTab == InspectorGitContent.ActiveTab.changes)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        Issue.record("Timed out waiting for subdirectory context update")
    }

    @Test func handlesSSHContextImmediately() throws {
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry, repositoryService: GitRepositoryService(executor: UnavailableGitExecutor()))
        try provider.register()

        var session = PaneSessionContext(workingDirectory: "/local", terminalTitle: "Terminal")
        session.observeForegroundSSH(
            alias: "remote-host",
            transferTarget: "user@host",
            processGroupID: 9999,
            currentWorkingDirectory: "/local",
            currentTerminalTitle: "Terminal",
            remoteWorkingDirectory: "/remote/project"
        )

        let tabID = UUID()
        let context = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: "/remote/project",
            session: session
        )

        registry.presentationDidChange(
            to: BuiltInGitInspectorProvider.paneID,
            context: context
        )

        guard case .git(let content) = registry.content(
            for: BuiltInGitInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected .git content")
            return
        }

        #expect(content.isLoading)
        #expect(content.repository == nil)
        registry.presentationDidChange(to: nil, context: context)

    }
}

private struct UnavailableGitExecutor: GitExecutor {
    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        throw GitExecutionError.executionFailed("Unavailable test transport.")
    }
}
