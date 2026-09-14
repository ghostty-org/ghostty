import AppKit
import Foundation
import Testing
@testable import Ghostty

struct EditorWorkspaceTests {
    @Test @MainActor func branchSwitchGuardOnlyDetectsDirtyDocumentsInThatWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: file)
        let store = EditorWorkspaceStore()
        let surface = UUID()
        defer { store.remove(surfaceIDs: [surface]) }
        let workspace = store.workspace(for: UUID(), surfaceID: surface)
        workspace.open(path: file.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        await waitUntil { !workspace.isLoading }
        let document = try #require(workspace.selectedDocument)
        document.suspendAutoSave()
        #expect(!store.hasUnsavedDocuments(in: root.path))
        document.text = "dirty"
        #expect(store.hasUnsavedDocuments(in: root.path))
        #expect(!store.hasUnsavedDocuments(in: root.path + "/other"))
        document.text = "original"
        #expect(!store.hasUnsavedDocuments(in: root.path))
    }

    @Test @MainActor func gitPreviewPreservesDirtyDocumentAndCannotBeSavedOverIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: file)
        let workspace = EditorWorkspace()
        defer { workspace.cancelAndClear() }
        workspace.open(path: file.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        await waitUntil { !workspace.isLoading }
        let document = try #require(workspace.selectedDocument)
        document.suspendAutoSave()
        document.text = "unsaved"
        workspace.openGitDiff(GitEditorDiffRequest(repository: .init(worktreePath: root.path,
                              gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git"),
                              target: .staged, file: nil))
        #expect(workspace.selectedDocument == nil)
        #expect(workspace.documents.count == 1)
        #expect(document.isDirty && document.text == "unsaved")
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        workspace.selectedID = document.id
        #expect(workspace.gitDiff == nil)
        #expect(workspace.selectedDocument === document)
    }

    @Test @MainActor func diffTabsSurviveFileSwitchesDeduplicateAndParticipateInNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: file)
        let workspace = EditorWorkspace()
        defer { workspace.cancelAndClear() }
        let repo = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git")
        let first = GitEditorDiffRequest(repository: repo, target: .staged, file: nil)
        let second = GitEditorDiffRequest(repository: repo, target: .unstaged, file: nil)
        workspace.openGitDiff(first)
        workspace.open(path: file.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        await waitUntil { !workspace.isLoading }
        let document = try #require(workspace.selectedDocument)
        #expect(workspace.gitDiffs.map(\.id) == [first.id])
        workspace.selectAdjacentDocument(offset: 1)
        #expect(workspace.gitDiff?.id == first.id)
        workspace.openGitDiff(second)
        workspace.openGitDiff(GitEditorDiffRequest(repository: repo, target: .staged, file: nil))
        #expect(workspace.gitDiffs.map(\.id) == [first.id, second.id])
        #expect(workspace.gitDiff?.id == first.id)
        workspace.selectAdjacentDocument(offset: -1)
        #expect(workspace.selectedDocument === document)
        workspace.closeGitDiff(second)
        #expect(workspace.selectedDocument === document)
        await workspace.close(document, window: nil)
        #expect(workspace.gitDiff?.id == first.id && workspace.isVisible)
        workspace.closeGitDiff(first)
        #expect(!workspace.isVisible && workspace.gitDiffs.isEmpty)
    }

    @Test @MainActor func gitRestoreProtectsUnsavedEditsAndReloadsCleanOpenFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.swift")
        try Data("changed on disk".utf8).write(to: url)
        let store = EditorWorkspaceStore()
        let surface = UUID()
        defer { store.remove(surfaceIDs: [surface]) }
        let workspace = store.workspace(for: UUID(), surfaceID: surface)
        workspace.open(path: url.path, filesystem: LocalWorkspaceFilesystem(workingDirectory: root.path))
        await waitUntil { !workspace.isLoading }
        let document = try #require(workspace.selectedDocument)
        document.suspendAutoSave()
        let repo = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git")
        let file = GitDiffFile(path: "file.swift", status: "M")
        document.text = "unsaved"
        var called = false
        await #expect(throws: (any Error).self) {
            try await store.withGitFileRestore(file, repository: repo) { called = true }
        }
        #expect(!called && document.text == "unsaved")
        document.text = "changed on disk"
        try await store.withGitFileRestore(file, repository: repo) {
            #expect(document.isRestoringFromGit)
            try Data("restored".utf8).write(to: url)
        }
        #expect(document.text == "restored" && !document.isDirty && !document.isRestoringFromGit)
        try await store.withGitFileRestore(file, repository: repo) { try FileManager.default.removeItem(at: url) }
        #expect(workspace.documents.isEmpty)
    }

    @Test @MainActor func batchRestoreChecksEveryEditorBeforeWritingAndReloadsPartialFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorWorkspaceStore()
        let surface = UUID()
        defer { store.remove(surfaceIDs: [surface]) }
        let workspace = store.workspace(for: UUID(), surfaceID: surface)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        var documents: [EditorDocument] = []
        for name in ["a.swift", "b.swift"] {
            let url = root.appendingPathComponent(name)
            try Data("disk".utf8).write(to: url)
            workspace.open(path: url.path, filesystem: filesystem)
            await waitUntil { !workspace.isLoading }
            let document = try #require(workspace.selectedDocument)
            document.suspendAutoSave()
            documents.append(document)
        }
        let repo = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git", commonGitDirPath: root.path + "/.git")
        let files = ["a.swift", "b.swift"].map { GitDiffFile(path: $0, status: "M") }
        documents[1].text = "unsaved"
        var called = false
        await #expect(throws: (any Error).self) {
            try await store.withGitFilesRestore(files, repository: repo) { called = true }
        }
        #expect(!called && documents[1].text == "unsaved")
        documents[1].text = "disk"
        await #expect(throws: (any Error).self) {
            try await store.withGitFilesRestore(files, repository: repo) {
                #expect(documents.allSatisfy { $0.isRestoringFromGit })
                try Data("restored".utf8).write(to: root.appendingPathComponent("a.swift"))
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(documents[0].text == "restored" && documents[1].text == "disk")
        #expect(documents.allSatisfy { !$0.isRestoringFromGit && !$0.isDirty })
    }

    @Test @MainActor func renameGuardFindsOpenDocumentsThroughLocalSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let file = real.appendingPathComponent("file.md")
        try Data("text".utf8).write(to: file)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let store = EditorWorkspaceStore()
        let surfaceID = UUID()
        let workspace = store.workspace(for: UUID(), surfaceID: surfaceID)
        defer { store.remove(surfaceIDs: [surfaceID]) }
        workspace.open(path: alias.appendingPathComponent("file.md").path, filesystem: filesystem)
        await waitUntil { !workspace.isLoading }
        #expect(workspace.documents.count == 1)
        #expect(store.containsOpenDocument(path: file.path, descriptor: filesystem.descriptor))
        #expect(store.containsOpenDocument(path: real.path, descriptor: filesystem.descriptor))
        #expect(store.containsOpenDocument(path: alias.path, descriptor: filesystem.descriptor))
        #expect(!store.containsOpenDocument(path: real.appendingPathComponent("other.md").path,
                                           descriptor: filesystem.descriptor))
    }

    @Test @MainActor func paneDocumentsFollowTheirSurfaceAndStayIndependent() {
        let store = EditorWorkspaceStore()
        let tab = UUID()
        let movedTab = UUID()
        let left = UUID()
        let right = UUID()
        let leftWorkspace = store.workspace(for: tab, surfaceID: left)
        let rightWorkspace = store.workspace(for: tab, surfaceID: right)
        #expect(leftWorkspace !== rightWorkspace)
        #expect(store.workspace(for: movedTab, surfaceID: right) === rightWorkspace)
        store.remove(tabID: tab)
        #expect(store.workspace(for: movedTab, surfaceID: right) === rightWorkspace)
        #expect(store.workspace(for: tab, surfaceID: left) !== leftWorkspace)
    }

    @Test @MainActor func tabNavigationWrapsAndSaveAllWritesEachDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)
        let workspace = EditorWorkspace()
        for name in ["first.txt", "second.txt"] {
            let file = root.appendingPathComponent(name)
            try Data("original".utf8).write(to: file)
            workspace.open(path: file.path, filesystem: filesystem)
            await waitUntil { !workspace.isLoading }
        }
        #expect(workspace.documents.count == 2)
        let first = try #require(workspace.documents.first)
        let second = try #require(workspace.documents.last)
        workspace.selectAdjacentDocument(offset: 1)
        #expect(workspace.selectedID == first.id)
        workspace.selectAdjacentDocument(offset: -1)
        #expect(workspace.selectedID == second.id)
        first.text = "first edit"
        second.text = "second edit"
        #expect(await workspace.saveAll())
        #expect(!first.isDirty && !second.isDirty)
        #expect(try String(contentsOfFile: first.path, encoding: .utf8) == "first edit")
        #expect(try String(contentsOfFile: second.path, encoding: .utf8) == "second edit")
    }

    @Test func shortcutModifiersIgnoreCapsLockButDistinguishShiftAndControl() {
        #expect(EditorKeyStroke(key: "F", modifiers: [.command, .capsLock]) ==
            EditorKeyStroke(key: "f", modifiers: .command))
        #expect(EditorKeyStroke(key: "g", modifiers: [.command, .shift]) !=
            EditorKeyStroke(key: "g", modifiers: .command))
        #expect(EditorKeyStroke(key: "\t", modifiers: .control) !=
            EditorKeyStroke(key: "\t", modifiers: [.control, .shift]))
    }

    @Test @MainActor func staleConcurrentOpenCannotReplaceNewerSelection() async throws {
        let filesystem = ControlledEditorWorkspaceFilesystem()
        let workspace = EditorWorkspace()

        workspace.open(path: "/first", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/first")
        workspace.open(path: "/second", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/second")
        await filesystem.finishRead(at: "/second", with: Data("second".utf8))
        await waitUntil { workspace.selectedDocument?.path == "/second" }

        await filesystem.finishRead(at: "/first", with: Data("first".utf8))
        await Task.yield()

        #expect(workspace.documents.map(\.path) == ["/second"])
        #expect(workspace.selectedDocument?.text == "second")
        #expect(!workspace.isLoading)
    }

    @Test @MainActor func repeatedOpenKeepsExistingDirtyDocument() async throws {
        let filesystem = ControlledEditorWorkspaceFilesystem()
        let workspace = EditorWorkspace()

        workspace.open(path: "/project/file", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/project/file")
        await filesystem.finishRead(at: "/project/file", with: Data("original".utf8))
        await waitUntil { workspace.documents.count == 1 }
        let original = try #require(workspace.selectedDocument)
        original.text = "unsaved"

        workspace.open(path: "/project/./file", filesystem: filesystem)

        #expect(workspace.documents.count == 1)
        #expect(workspace.selectedDocument === original)
        #expect(workspace.selectedDocument?.text == "unsaved")
        #expect(workspace.selectedDocument?.isDirty == true)
        #expect(!workspace.isLoading)
        #expect(await filesystem.readCount() == 1)
    }

    @Test @MainActor func failedSavePublishesReasonAndKeepsDirtyState() async throws {
        let reason = "Remote disk is read-only."
        let filesystem = ControlledEditorWorkspaceFilesystem(writeFailure: reason)
        let workspace = EditorWorkspace()
        workspace.open(path: "/file", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/file")
        await filesystem.finishRead(at: "/file", with: Data("original".utf8))
        await waitUntil { workspace.selectedDocument != nil }
        let document = try #require(workspace.selectedDocument)
        document.text = "changed"

        let saved = await workspace.save(document)

        #expect(!saved)
        #expect(document.isDirty)
        #expect(!document.isSaving)
        #expect(workspace.errorMessage == reason)
    }

    @Test @MainActor func slowSaveDoesNotDropSubsequentSaveOrSaveAll() async throws {
        let filesystem = ControlledEditorWorkspaceFilesystem(deferWrites: true)
        let workspace = EditorWorkspace()
        workspace.open(path: "/doc1", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/doc1")
        await filesystem.finishRead(at: "/doc1", with: Data("doc1".utf8))
        await waitUntil { workspace.documents.count == 1 }

        workspace.open(path: "/doc2", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/doc2")
        await filesystem.finishRead(at: "/doc2", with: Data("doc2".utf8))
        await waitUntil { workspace.documents.count == 2 }

        let doc1 = try #require(workspace.documents.first)
        let doc2 = try #require(workspace.documents.last)
        doc1.text = "edit1"
        doc2.text = "edit2"

        // Trigger save on doc1 in background
        let doc1SaveTask = Task { await workspace.save(doc1) }
        await filesystem.waitUntilWriteStarts(at: "/doc1")
        #expect(doc1.isSaving)

        // While doc1 is saving, call saveAll()
        let saveAllTask = Task { await workspace.saveAll() }

        // Finish doc1's initial write
        await filesystem.finishWrite(at: "/doc1")
        let doc1Saved = await doc1SaveTask.value
        #expect(doc1Saved)

        // Wait for doc2's write to start and finish
        await filesystem.waitUntilWriteStarts(at: "/doc2")
        await filesystem.finishWrite(at: "/doc2")

        let allSaved = await saveAllTask.value
        #expect(allSaved)
        #expect(!doc1.isDirty && !doc2.isDirty)
    }

    @Test @MainActor func closingSurfaceCleansUpWorkspaceAndCancelsInFlightReads() async throws {
        let store = EditorWorkspaceStore()
        let tabID = UUID()
        let surface1 = UUID()
        let surface2 = UUID()

        let ws1 = store.workspace(for: tabID, surfaceID: surface1)
        let ws2 = store.workspace(for: tabID, surfaceID: surface2)

        let filesystem = ControlledEditorWorkspaceFilesystem()
        ws1.open(path: "/file1", filesystem: filesystem)
        await filesystem.waitUntilReadStarts(at: "/file1")

        // Now remove surface1 (as would happen when closing a split pane)
        store.remove(surfaceIDs: [surface1])

        #expect(!ws1.isLoading && ws1.documents.isEmpty)
        // Ensure ws2 is untouched
        #expect(store.workspace(for: tabID, surfaceID: surface2) === ws2)
        // Ensure surface1 gets a fresh workspace if reopened
        #expect(store.workspace(for: tabID, surfaceID: surface1) !== ws1)
    }

    @Test @MainActor func movingSurfaceTransfersWorkspaceOwnershipWithoutClearingDocuments() async throws {
        let store = EditorWorkspaceStore()
        let tab1 = UUID()
        let tab2 = UUID()
        let surface = UUID()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("move-test.txt")
        try Data("content".utf8).write(to: file)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)

        let ws = store.workspace(for: tab1, surfaceID: surface)
        ws.open(path: file.path, filesystem: filesystem)
        await waitUntil { !ws.isLoading }
        #expect(ws.documents.count == 1)

        // Moving surface from tab1 to tab2 transfers ownership and preserves documents
        let transferred = store.workspace(for: tab2, surfaceID: surface)
        #expect(transferred === ws)
        #expect(transferred.documents.count == 1)
        #expect(transferred.documents.first?.text == "content")
    }

    @Test @MainActor func confirmAndSaveDirtyDocumentsPreservesDocumentList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("preserve-test.txt")
        try Data("original".utf8).write(to: file)
        let filesystem = LocalWorkspaceFilesystem(workingDirectory: root.path)

        let workspace = EditorWorkspace()
        workspace.open(path: file.path, filesystem: filesystem)
        await waitUntil { !workspace.isLoading }
        guard let doc = workspace.documents.first else {
            Issue.record("Document failed to open")
            return
        }

        // Clean document: confirmAndSaveDirtyDocuments returns true and documents list remains intact
        let ok = await workspace.confirmAndSaveDirtyDocuments(window: nil)
        #expect(ok)
        #expect(workspace.documents.count == 1)
        #expect(workspace.documents.first === doc)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for editor workspace state")
    }
}

private actor ControlledEditorWorkspaceFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .local,
        id: "local",
        displayName: "test",
        workingDirectory: "/"
    )

    private struct PendingRead {
        let continuation: CheckedContinuation<Data, Error>
    }

    private let writeFailure: String?
    private let deferWrites: Bool
    private var pendingReads: [String: PendingRead] = [:]
    private var readWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingWrites: [String: CheckedContinuation<Void, Error>] = [:]
    private var writeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var reads = 0

    init(writeFailure: String? = nil, deferWrites: Bool = false) {
        self.writeFailure = writeFailure
        self.deferWrites = deferWrites
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] { [] }
    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}

    func readFile(at path: String) async throws -> Data {
        reads += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[path] = PendingRead(continuation: continuation)
            readWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
        }
    }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        if let writeFailure {
            throw WorkspaceFilesystemError.operationFailed(writeFailure)
        }
        if deferWrites {
            try await withCheckedThrowingContinuation { continuation in
                pendingWrites[path] = continuation
                writeWaiters.removeValue(forKey: path)?.forEach { $0.resume() }
            }
        }
    }

    func waitUntilWriteStarts(at path: String) async {
        if pendingWrites[path] != nil { return }
        await withCheckedContinuation { continuation in
            writeWaiters[path, default: []].append(continuation)
        }
    }

    func finishWrite(at path: String) {
        pendingWrites.removeValue(forKey: path)?.resume()
    }

    func waitUntilReadStarts(at path: String) async {
        if pendingReads[path] != nil { return }
        await withCheckedContinuation { continuation in
            readWaiters[path, default: []].append(continuation)
        }
    }

    func finishRead(at path: String, with data: Data) {
        pendingReads.removeValue(forKey: path)?.continuation.resume(returning: data)
    }

    func readCount() -> Int { reads }
}
