import AppKit
import Testing
@testable import Ghostty

struct EditorFilePickerTests {
    @Test @MainActor func staleListingCannotReplaceNewDirectory() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        await filesystem.waitUntilListStarts(at: "/")

        model.open(Self.directory("/project"), fileHandler: { _ in })
        #expect(model.directory == "/project")
        #expect(model.entries.isEmpty)
        await filesystem.waitUntilListStarts(at: "/project")
        await filesystem.finishList(at: "/project", with: [Self.file("/project/current")])
        await waitUntil { model.entries.map(\.path) == ["/project/current"] }

        await filesystem.finishList(at: "/", with: [Self.file("/stale")])
        await Task.yield()
        #expect(model.directory == "/project")
        #expect(model.entries.map(\.path) == ["/project/current"])
    }

    @Test @MainActor func opensDirectoriesAndCallsBackForFiles() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        await filesystem.waitUntilListStarts(at: "/")
        let folder = Self.directory("/project")
        let document = Self.file("/readme.md")
        await filesystem.finishList(at: "/", with: [folder, document])
        await waitUntil { model.entries.count == 2 }

        model.selection = folder.path
        model.openSelection(fileHandler: { _ in Issue.record("Directory was returned as a file") })
        #expect(model.directory == "/project")
        await filesystem.waitUntilListStarts(at: "/project")
        await filesystem.finishList(at: "/project", with: [])

        var openedPath: String?
        model.open(document) { openedPath = $0 }
        #expect(openedPath == "/readme.md")
    }

    @Test @MainActor func navigateInputLoadsDirectoryOrOpensDirectFile() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        await filesystem.waitUntilListStarts(at: "/")
        let document = Self.file("/readme.md")
        await filesystem.finishList(at: "/", with: [document])
        await waitUntil { model.entries.count == 1 }

        var openedPath: String?
        model.navigate(to: "/readme.md") { openedPath = $0 }
        #expect(openedPath == "/readme.md")

        model.navigate(to: "/other/folder") { _ in }
        #expect(model.directory == "/other/folder")
        #expect(model.pathInput == "/other/folder")
    }

    @Test @MainActor func navigateInputDirectlyOpensFilePathOutsideCurrentListing() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        await filesystem.waitUntilListStarts(at: "/")
        await filesystem.finishList(at: "/", with: [Self.directory("/project")])
        await waitUntil { model.entries.count == 1 }

        var openedPath: String?
        // User types /tmp/a.swift directly while current dir is /
        model.navigate(to: "/tmp/a.swift") { openedPath = $0 }
        await waitUntil { openedPath != nil }
        #expect(openedPath == "/tmp/a.swift")
    }

    @Test @MainActor func nativePickerUsesTableSelectionAndOpensSelectedFile() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        let document = Self.file("/readme.md")
        var openedPath: String?
        let controller = EditorFilePickerController(
            model: model,
            onCancel: {},
            onOpen: { openedPath = $0 }
        )
        _ = controller.view
        #expect(controller.tableView.dataSource === controller)
        #expect(controller.tableView.numberOfColumns == 1)

        await filesystem.waitUntilListStarts(at: "/")
        await filesystem.finishList(at: "/", with: [document])
        await waitUntil { controller.tableView.numberOfRows == 1 }

        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: controller.tableView
        ))
        controller.openSelection()
        #expect(openedPath == document.path)
    }

    @Test @MainActor func nativePickerSubmitsTypedPathAndKeepsSelectionAcrossModelUpdates() async {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        let controller = EditorFilePickerController(model: model, onCancel: {}, onOpen: { _ in })
        _ = controller.view
        await filesystem.waitUntilListStarts(at: "/")
        await filesystem.finishList(at: "/", with: [Self.file("/first.md"), Self.file("/second.md")])
        await waitUntil { controller.tableView.numberOfRows == 2 }

        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: controller.tableView
        ))
        model.pathInput = "/typed/directory"
        await waitUntil { controller.pathField.stringValue == "/typed/directory" }
        #expect(controller.tableView.selectedRow == 1)
        #expect(model.selection == "/second.md")
        #expect(controller.pathField.stringValue == "/typed/directory")

        controller.pathField.stringValue = "/typed/directory"
        controller.controlTextDidEndEditing(Notification(
            name: NSText.didEndEditingNotification,
            object: controller.pathField,
            userInfo: ["NSTextMovement": NSReturnTextMovement]
        ))
        await filesystem.waitUntilListStarts(at: "/typed/directory")
        #expect(model.directory == "/typed/directory")
        await filesystem.finishList(at: "/typed/directory", with: [])
    }

    @Test @MainActor func nativePickerDoesNotReplaceMarkedPathWhileDirectoryFinishesLoading() async throws {
        let filesystem = ControlledEditorFilePickerFilesystem()
        let model = EditorFilePickerModel(filesystem: filesystem)
        let controller = EditorFilePickerController(model: model, onCancel: {}, onOpen: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.pathField.frame.width > 300)
        #expect(window.makeFirstResponder(controller.pathField))
        let editor = try #require(controller.pathField.currentEditor() as? NSTextView)
        editor.setMarkedText("路径", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await filesystem.waitUntilListStarts(at: "/")
        await filesystem.finishList(at: "/", with: [Self.file("/readme.md")])
        await waitUntil { controller.tableView.numberOfRows == 1 }
        #expect(editor.hasMarkedText())
        #expect(editor.string == "路径")
        editor.unmarkText()
    }

    private static func directory(_ path: String) -> WorkspaceFileEntry {
        .init(path: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    private static func file(_ path: String) -> WorkspaceFileEntry {
        .init(path: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for file picker state")
    }
}

private actor ControlledEditorFilePickerFilesystem: WorkspaceFilesystem {
    nonisolated let descriptor = WorkspaceDescriptor(
        kind: .ssh,
        id: "ssh:test",
        displayName: "test",
        workingDirectory: "/"
    )

    private var pending: [String: CheckedContinuation<[WorkspaceFileEntry], Error>] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        try await withCheckedThrowingContinuation { continuation in
            pending[path] = continuation
            waiters.removeValue(forKey: path)?.forEach { $0.resume() }
        }
    }

    func createFile(named name: String, in directory: String) async throws {}
    func createDirectory(named name: String, in directory: String) async throws {}

    func waitUntilListStarts(at path: String) async {
        if pending[path] != nil { return }
        await withCheckedContinuation { continuation in
            waiters[path, default: []].append(continuation)
        }
    }

    func finishList(at path: String, with entries: [WorkspaceFileEntry]) {
        pending.removeValue(forKey: path)?.resume(returning: entries)
    }

    func itemType(at path: String) async throws -> WorkspaceItemType? {
        if path.hasSuffix(".md") || path.hasSuffix(".swift") || path.hasSuffix(".txt") {
            return .file
        }
        if path.contains("folder") || path.contains("project") || path == "/" {
            return .directory
        }
        return nil
    }
}
