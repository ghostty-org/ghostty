import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitBatchInteractionTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        return window
    }
    private func key(_ code: UInt16, character: String, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }
    private func click(_ row: Int, table: GitCollectionTableView, modifiers: NSEvent.ModifierFlags = []) throws {
        let point = table.convert(NSPoint(x: 180, y: table.rect(ofRow: row).midY), to: nil)
        let number = try #require(table.window?.windowNumber)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers,
            timestamp: 0.01, windowNumber: number, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        table.mouseDown(with: down)
        table.mouseUp(with: up)
    }

    @Test(arguments: GitCollectionMode.allCases)
    func commandSelectionCheckboxAndSpaceShareBatchSemantics(mode: GitCollectionMode) async throws {
        let a = GitDiffFile(path: "src/a.cpp", status: "M")
        let b = GitDiffFile(path: "src/b.cpp", status: "M")
        let c = GitDiffFile(path: "src/c.cpp", status: "M")
        var actions: [InspectorGitAction] = []
        var root = GitCollectionView(source: .changes(staged: [a], unstaged: [b, c], stagedError: nil, unstagedError: nil),
            mode: mode, perform: { actions.append($0) })
        let host = NSHostingView(rootView: root); host.sizingOptions = []
        let win = window(host)
        defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        func row(_ path: String, _ section: GitChangeSection) throws -> Int {
            try #require(coordinator.rows.firstIndex { $0.id == section.rowID(path: path) })
        }
        try click(row(a.path, .staged), table: table)
        let navigations = actions.count
        try click(row(b.path, .unstaged), table: table, modifiers: .command)
        try click(row(c.path, .unstaged), table: table, modifiers: .command)
        #expect(table.selectedRowIndexes.count == 3 && actions.count == navigations)
        #expect(table.clickModifiers.isEmpty)
        let checkbox = try #require(table.view(atColumn: 0, row: row(a.path, .staged), makeIfNecessary: true) as? GitCollectionCell).checkbox
        checkbox.performClick(nil)
        if case .setFilesStaged(let files, let staged) = actions.last {
            #expect(staged && Set(files.map(\.path)) == [a.path, b.path, c.path])
        } else { Issue.record("Expected one batch request") }
        root.source = .changes(staged: [a, b, c], unstaged: [], stagedError: nil, unstagedError: nil)
        host.rootView = root
        try await Task.sleep(for: .milliseconds(80))
        #expect(table.selectedRowIndexes.count == 3)
        #expect(table.selectedRowIndexes.allSatisfy { if case .file(_, .staged) = coordinator.rows[$0].item.kind { return true }; return false })
        table.keyDown(with: try key(49, character: " ", window: win))
        if case .setFilesStaged(let files, let staged) = actions.last { #expect(!staged && files.count == 3) } else { Issue.record("Space must unstage the selected files") }
        table.keyDown(with: try key(53, character: "\u{1b}", window: win))
        #expect(table.selectedRowIndexes.isEmpty)
    }

    @Test(arguments: GitCollectionMode.allCases, [false, true])
    func shiftSelectionContextMenuUsesWholeBatch(mode: GitCollectionMode, staged: Bool) async throws {
        let files = ["a", "b", "c", "outside"].map { GitDiffFile(path: $0, status: "M") }
        var actions: [InspectorGitAction] = []
        var root = GitCollectionView(source: .changes(staged: staged ? files : [], unstaged: staged ? [] : files,
            stagedError: nil, unstagedError: nil), mode: mode, perform: { actions.append($0) })
        let host = NSHostingView(rootView: root); host.sizingOptions = []
        let win = window(host); defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(80))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        let section: GitChangeSection = staged ? .staged : .unstaged
        func row(_ file: GitDiffFile) throws -> Int {
            try #require(coordinator.rows.firstIndex { $0.id == section.rowID(path: file.path) })
        }
        try click(row(files[0]), table: table)
        try click(row(files[2]), table: table, modifiers: .shift)
        #expect(table.selectedRowIndexes.count == 3)
        #expect(coordinator.contextBatch(row: try row(files[3]))?.files == [files[3]])
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        for title in [staged ? "Unstage Selected Files" : "Stage Selected Files", "Discard Selected Changes…"] {
            let item = try #require(menu.items.first { $0.title == GitL10n.text(title) })
            #expect(item.isEnabled)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(actions.suffix(2) == [
            .setFilesStaged(Array(files.prefix(3)), !staged),
            .discardSelectedChanges(.init(entries: files.prefix(3).map { .init(file: $0, section: section) }))
        ])
        root.pending = [files[2].path]
        host.rootView = root
        try await Task.sleep(for: .milliseconds(60))
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.prefix(2).allSatisfy { !$0.isEnabled })
        root.pending = []; root.canWrite = false
        host.rootView = root
        try await Task.sleep(for: .milliseconds(60))
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.prefix(2).allSatisfy { !$0.isEnabled })
    }

    @Test func shiftUsesVisibleFilesAndFolderCheckboxHasIndependentHitTarget() async throws {
        let a = GitDiffFile(path: "src/a.cpp", status: "M")
        let files = [a, .init(path: "src/b.cpp", status: "M"), .init(path: "hidden/c.cpp", status: "M"), .init(path: "hidden/d.cpp", status: "M"), .init(path: "z.cpp", status: "M")]
        var actions: [InspectorGitAction] = []
        let root = GitCollectionView(source: .changes(staged: [a], unstaged: files, stagedError: nil, unstagedError: nil),
            mode: .tree, perform: { actions.append($0) })
        let host = NSHostingView(rootView: root); host.sizingOptions = []
        let win = window(host); defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(80))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        coordinator.toggleFolder("changes/unstaged/folder/hidden")
        #expect(!coordinator.rows.contains { $0.id == GitChangeSection.unstaged.rowID(path: "hidden/c.cpp") })
        func index(_ id: String) throws -> Int { try #require(coordinator.rows.firstIndex { $0.id == id }) }
        try click(index(GitChangeSection.unstaged.rowID(path: a.path)), table: table)
        let count = actions.count
        try click(index(GitChangeSection.unstaged.rowID(path: "z.cpp")), table: table, modifiers: .shift)
        #expect(actions.count == count)
        let selected = table.selectedRowIndexes.compactMap { index -> String? in
            if case .file(let file, _) = coordinator.rows[index].item.kind { return file.path }; return nil
        }
        #expect(Set(selected) == ["src/a.cpp", "src/b.cpp", "z.cpp"])
        coordinator.toggleFolder("changes/unstaged/folder/src")
        #expect(!coordinator.rows.contains { $0.id == GitChangeSection.staged.rowID(path: a.path) })
        coordinator.toggleFolder("changes/unstaged/folder/src")
        let folderID = "changes/unstaged/folder/src"
        let folder = try #require(table.view(atColumn: 0, row: index(folderID), makeIfNecessary: true) as? GitCollectionCell)
        #expect(folder.checkbox.state == .mixed)
        let expanded = coordinator.rows[try index(folderID)].expanded
        folder.checkbox.performClick(nil)
        #expect(coordinator.rows[try index(folderID)].expanded == expanded)
        if case .setFilesStaged(let files, let stage) = actions.last { #expect(stage && Set(files.map(\.path)) == ["src/a.cpp", "src/b.cpp"]) } else { Issue.record("Folder checkbox should batch its descendants") }
        #expect(!coordinator.rows.contains { $0.id == "changes/master" })
    }

    @Test func hoverHasOneOwnerAcrossScrollingRecyclingAndModelUpdates() async throws {
        let files = (0..<1400).map { GitDiffFile(path: "file-\($0).cpp", status: "M") }
        var root = GitCollectionView(source: .changes(staged: [], unstaged: files, stagedError: nil, unstagedError: nil), perform: { _ in })
        let host = NSHostingView(rootView: root); host.sizingOptions = []
        let win = window(host); defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(GitCollectionTableView.self, in: host).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        for row in 4..<12 {
            table.setHover(at: NSPoint(x: 100, y: table.rect(ofRow: row).midY))
            #expect(find(GitCollectionRowView.self, in: table).filter(\.isPointerHovered).count <= 1)
        }
        table.scrollRowToVisible(800)
        try await Task.sleep(for: .milliseconds(40))
        #expect(find(GitCollectionRowView.self, in: table).filter(\.isPointerHovered).count <= 1)
        root.source = .changes(staged: [files[800]], unstaged: files.enumerated().filter { $0.offset != 800 }.map(\.element), stagedError: nil, unstagedError: nil)
        host.rootView = root
        try await Task.sleep(for: .milliseconds(60))
        #expect(find(GitCollectionRowView.self, in: table).filter(\.isPointerHovered).count <= 1)
        #expect(table.hoveredRowID == nil || coordinator.rows.contains { $0.id == table.hoveredRowID })
        table.clearHover()
        #expect(find(GitCollectionRowView.self, in: table).allSatisfy { !$0.isPointerHovered })
    }

    @Test func searchFieldRetainsOrdinarySpaceInput() async throws {
        var query = "feature"
        let host = NSHostingView(rootView: GitCollectionSearchField(
            query: Binding(get: { query }, set: { query = $0 }), placeholder: "Search changes…",
            autofocus: false, colors: .init(), controller: .init(), cancel: {}))
        let win = window(host); defer { win.contentView = nil; win.close() }
        try await Task.sleep(for: .milliseconds(60))
        let field = try #require(find(GitCollectionSearchField.Field.self, in: host).first)
        win.makeFirstResponder(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(.init(location: editor.string.count, length: 0))
        let event = try key(49, character: " ", window: win)
        #expect(!EditorCommandRouter.shared.handle(event))
        editor.keyDown(with: event)
        #expect(editor.string == "feature ")
    }

    @Test func spaceIsNotCapturedWhileEditingText() async throws {
        let editor = GitCommitTextView()
        editor.string = "draft"
        let table = GitCollectionTableView()
        var toggles = 0
        table.toggleStageSelection = { toggles += 1 }
        let container = NSView(frame: .init(x: 0, y: 0, width: 380, height: 200))
        editor.frame = .init(x: 0, y: 0, width: 380, height: 70)
        table.frame = .init(x: 0, y: 80, width: 380, height: 100)
        container.addSubview(editor); container.addSubview(table)
        let win = window(container); defer { win.contentView = nil; win.close() }
        win.makeFirstResponder(editor)
        editor.setSelectedRange(.init(location: 5, length: 0))
        let event = try key(49, character: " ", window: win)
        #expect(!EditorCommandRouter.shared.handle(event))
        editor.keyDown(with: event)
        #expect(editor.string == "draft " && toggles == 0)
    }
}
