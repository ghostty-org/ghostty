import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalLinkCheckBatcherTests {
    @Test func viewportUsesOneBatchAndOneRefreshWithShortLivedCache() async {
        let filesystem = CountingLinkFilesystem()
        var now: TimeInterval = 0
        let batcher = TerminalLinkCheckBatcher(ttl: 3, now: { now })
        let scope = TerminalLinkCheckBatcher.Scope(revision: 0, filesystemID: "ssh:test", directory: "/repo")
        var replies: [Bool] = []
        var refreshes = 0
        for i in 0..<60 {
            batcher.enqueue(path: "/repo/f\(i)", scope: scope, filesystem: filesystem,
                            reply: { replies.append($0) }, refresh: { refreshes += 1 })
        }
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { replies.append($0) }, refresh: { refreshes += 1 })
        batcher.enqueue(path: "/repo/missing", scope: scope, filesystem: filesystem,
                        reply: { replies.append($0) }, refresh: { refreshes += 1 })
        await batcher.flush()
        #expect(await filesystem.calls.count == 1)
        #expect(await filesystem.calls.first?.count == 61)
        #expect(replies.count == 62)
        #expect(replies.filter { !$0 }.count == 1)
        #expect(refreshes == 1)

        // Repeated Cmd press uses cached positives and negatives without SSH.
        for path in ["/repo/f0", "/repo/missing"] {
            batcher.enqueue(path: path, scope: scope, filesystem: filesystem,
                            reply: { replies.append($0) }, refresh: { refreshes += 1 })
        }
        await batcher.flush()
        #expect(await filesystem.calls.count == 1)
        #expect(refreshes == 2)
        now = 4
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { replies.append($0) }, refresh: {})
        await batcher.flush()
        #expect(await filesystem.calls.count == 2)
        let changed = TerminalLinkCheckBatcher.Scope(revision: 1, filesystemID: "ssh:test", directory: "/repo")
        batcher.enqueue(path: "/repo/f0", scope: changed, filesystem: filesystem, reply: { _ in }, refresh: {})
        await batcher.flush()
        #expect(await filesystem.calls.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func cachedLinksDoNotWaitForUnrelatedColdPaths() async throws {
        let filesystem = CountingLinkFilesystem()
        let batcher = TerminalLinkCheckBatcher()
        let scope = TerminalLinkCheckBatcher.Scope(revision: 0, filesystemID: "ssh:test", directory: "/repo")
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem, reply: { _ in }, refresh: {})
        await batcher.flush()
        await filesystem.delayNext()
        var warmAnswered = false
        var coldAnswered = false
        let completion = AsyncStream<Bool>.makeStream()
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { warmAnswered = $0 }, refresh: {})
        batcher.enqueue(path: "/repo/f1", scope: scope, filesystem: filesystem,
                        reply: {
                            coldAnswered = $0
                            completion.continuation.yield($0)
                            completion.continuation.finish()
                        }, refresh: {})
        let flushing = Task { await batcher.flush() }
        for _ in 0..<100 {
            if await filesystem.calls.count == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(warmAnswered)
        #expect(!coldAnswered)
        await flushing.value
        // enqueue's scheduled flush can win the race; the explicit flush then
        // returns while that owner is still draining. Await the actual reply.
        var replies = completion.stream.makeAsyncIterator()
        #expect(await replies.next() == true)
        #expect(coldAnswered)
        #expect(await filesystem.calls.last == ["/repo/f1"])
    }

    @Test func transportFailuresAreRetriedRatherThanNegativeCached() async {
        let filesystem = CountingLinkFilesystem()
        let batcher = TerminalLinkCheckBatcher()
        let scope = TerminalLinkCheckBatcher.Scope(revision: 0, filesystemID: "ssh:test", directory: "/repo")
        var answers: [Bool] = []
        await filesystem.failNext()
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { answers.append($0) }, refresh: {})
        await batcher.flush()
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { answers.append($0) }, refresh: {})
        await batcher.flush()
        #expect(answers == [false, true])
        #expect(await filesystem.calls.count == 2)
    }

    @Test func arrivalsDuringAnActiveBatchReuseItsResult() async throws {
        let filesystem = CountingLinkFilesystem()
        await filesystem.delayNext()
        let batcher = TerminalLinkCheckBatcher()
        let scope = TerminalLinkCheckBatcher.Scope(revision: 0, filesystemID: "ssh:test", directory: "/repo")
        var answers: [Bool] = []
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { answers.append($0) }, refresh: {})
        let first = Task { await batcher.flush() }
        for _ in 0..<100 {
            if await filesystem.calls.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        batcher.enqueue(path: "/repo/f0", scope: scope, filesystem: filesystem,
                        reply: { answers.append($0) }, refresh: {})
        await batcher.flush()
        await first.value
        #expect(answers == [true, true])
        #expect(await filesystem.calls.count == 1)
    }

    @Test func remoteBatchCommandsAreBoundedAndResponsesStrict() throws {
        let paths = (0..<150).map { "/repo/d\($0)" }
        let batches = try SSHWorkspaceFilesystem.itemTypeBatches(paths + [paths[0]])
        #expect(batches.count == 2)
        #expect(batches.flatMap { $0 }.count == 150)
        #expect(batches.allSatisfy { $0.count <= 128 })
        #expect(throws: WorkspaceFilesystemError.self) {
            try SSHWorkspaceFilesystem.parseItemTypes("DF", paths: ["a"])
        }
        #expect(throws: WorkspaceFilesystemError.self) {
            try SSHWorkspaceFilesystem.parseItemTypes("!", paths: ["a"])
        }
        let types = try SSHWorkspaceFilesystem.parseItemTypes("DFM", paths: ["a", "b", "c"])
        #expect(types["a"] == .directory)
        #expect(types["b"] == .file)
        #expect(types["c"] == nil)
    }

    @Test func batchShellChecksLiteralPathsWithoutEnumeratingChildren() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 ' $(echo injected)\n.md")
        try Data().write(to: file)
        let paths = [root.path, file.path, root.appendingPathComponent("absent").path]
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHWorkspaceFilesystem.itemTypesCommand(paths)]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: data, encoding: .utf8) == "DFM")
    }
}

private actor CountingLinkFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(kind: .ssh, id: "ssh:test", displayName: "test", workingDirectory: "/repo")
    private(set) var calls: [[String]] = []
    private var fail = false
    private var delay = false
    func failNext() { fail = true }
    func delayNext() { delay = true }
    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}
    func itemTypes(at paths: [String]) async throws -> [String: WorkspaceItemType] {
        calls.append(paths)
        if fail {
            fail = false
            throw WorkspaceFilesystemError.unavailable
        }
        if delay {
            delay = false
            try await Task.sleep(for: .milliseconds(40))
        }
        return Dictionary(uniqueKeysWithValues: paths.filter { !$0.hasSuffix("missing") }.map { ($0, .file) })
    }
}
