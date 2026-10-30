import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitInspectorUsabilityTests {
    private func window(_ view: NSView, width: CGFloat = 360, height: CGFloat = 300) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
    private func key(_ char: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: char,
            charactersIgnoringModifiers: char, isARepeat: false, keyCode: char == "c" ? 8 : 0))
    }

    @Test func nativeInspectorSelectionAndRefDetailsActuallyCopyFullValues() async throws {
        let value = "renjiejiang02 · renjiejiang02@deeproute.ai"
        let field = InspectorCopyableTextField(labelWithString: value)
        field.isSelectable = true
        let board = NSPasteboard.withUniqueName()
        field.pasteboard = board
        let host = window(field)
        defer { host.contentView = nil; host.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange((value as NSString).range(of: "renjiejiang02@deeproute.ai"))
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == "renjiejiang02@deeproute.ai")
        #expect(EditorCommandRouter.shared.handle(try key("a", in: host)))
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == value)

        let ref = GitRefDecoration(name: "release/" + String(repeating: "long-reference-", count: 16), kind: .tag)
        let list = GitReferenceListPopoverController(
            refs: [ref], selected: ref, state: GitCollectionState(), colors: .init(),
            pasteboard: board, close: {}
        )
        host.contentViewController = list
        host.setContentSize(GitRefPopoverStyle.size)
        try await Task.sleep(for: .milliseconds(100))
        list.view.layoutSubtreeIfNeeded()
        let detail = try #require(find(GitCollectionTableView.self, in: list.view).first)
        host.makeFirstResponder(detail)
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == ref.name)

    }

    @Test func tableShortcutAndContextMenuCopyCommitFields() async throws {
        let commit = GitHistoryCommit(id: .init("0123456789abcdef"), parentIDs: [], authorName: "Author",
            authorEmail: "author@example.com", authoredAt: Date(), subject: "A full untruncated commit subject")
        let view = NSHostingView(rootView: GitHistoryTable(commits: [commit], selectedCommitID: nil,
            onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }))
        view.sizingOptions = []
        let host = window(view)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(InspectorCopyTableView.self, in: view).first)
        let board = NSPasteboard.withUniqueName()
        table.pasteboard = board
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        host.makeFirstResponder(table)
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == commit.subject)
        let menu = try #require(table.menu as? InspectorCopyMenu)
        (table.target as? GitHistoryTable.Coordinator)?.menuNeedsUpdate(menu)
        menu.pasteboard = board
        let extra = try #require(menu.items.first { $0.title == GitL10n.text("Copy More") }?.submenu as? InspectorCopyMenu)
        extra.pasteboard = board
        let index = try #require(extra.items.firstIndex { $0.title == GitL10n.text("Copy email") })
        extra.performActionForItem(at: index)
        #expect(board.string(forType: .string) == commit.authorEmail)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let subject = try #require(find(NSTextField.self, in: cell).first)
        let center = subject.frame.minY + subject.firstBaselineOffsetFromTop - (subject.font?.capHeight ?? 0) / 2
        #expect(abs(center - GitHistoryRowMetrics.contentAxisY) <= 0.5)
        let identity = try #require(find(InspectorMetadataText.self, in: cell).first { $0.value == commit.authorEmail })
        identity.pasteboard = board
        InspectorCopyMenu.copy("unchanged", to: board)
        identity.performClick(nil)
        #expect(identity.isValueSelected && board.string(forType: .string) == "unchanged")
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == commit.authorEmail)
        #expect(identity.isCopied)

    }

    @Test func metadataCopiesIndependentlyAndDisclosureLivesAfterTheSubject() async throws {
        let commit = GitHistoryCommit(id: .init("0123456789abcdef0123456789abcdef01234567"), parentIDs: [],
            authorName: "jischeng", authorEmail: "j.s.cheng@hotmail.com", authoredAt: Date(), subject: "Commit subject remains primary")
        let view = NSHostingView(rootView: GitHistoryTable(commits: [commit], selectedCommitID: nil,
            onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }).background(Color(NSColor.windowBackgroundColor)))
        view.sizingOptions = []
        let host = window(view, width: 280, height: 200)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(NSTableView.self, in: view).first)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let subject = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        let graph = try #require(find(GitGraphCellView.self, in: cell).first)
        let disclosure = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(graph.frame.maxX < subject.frame.minX)
        #expect(disclosure.frame.minX > subject.frame.maxX)
        #expect(!subject.isSelectable)
        let buttons = find(InspectorMetadataText.self, in: cell)
        let board = NSPasteboard.withUniqueName()
        for value in [commit.authorName, commit.authorEmail, commit.authoredAt.description, commit.id.rawValue] {
            let button = try #require(buttons.first { $0.value == value })
            button.pasteboard = board
            let frame = button.frame
            let title = button.attributedTitle.string
            InspectorCopyMenu.copy("unchanged", to: board)
            button.activate(clickCount: 1)
            #expect(button.isValueSelected && board.string(forType: .string) == "unchanged")
            #expect(buttons.filter(\.isValueSelected).count == 1)
            #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
            #expect(board.string(forType: .string) == value)
            #expect(button.isCopied && button.attributedTitle.string == title)
            #expect(button.frame == frame && button.image == nil)
        }
        try await Task.sleep(for: .milliseconds(1100))
        #expect(buttons.allSatisfy { !$0.isCopied && $0.toolTip != "Copied" })
    }

    @Test func referencesHaveTypedFolderTreesAndClickToCopy() async throws {
        let refs: [GitRefDecoration] = [
            .init(name: "HEAD", kind: .head), .init(name: "main", kind: .currentBranch),
            .init(name: "feature/git/history", kind: .localBranch), .init(name: "feature/git/diff", kind: .localBranch),
            .init(name: "feature/editor/markdown", kind: .localBranch), .init(name: "fix/ssh/reconnect", kind: .localBranch),
            .init(name: "origin/main", kind: .remoteBranch), .init(name: "origin/feature/git/history", kind: .remoteBranch),
            .init(name: "v0.11.2", kind: .tag), .init(name: "releases/dev-v0.11.2-169a6eb4", kind: .tag),
        ]
        let roots = GitCollectionBuilder.nodes(source: .decorations(refs), mode: .tree)
        #expect(roots.map(\.item.title) == ["HEAD", GitL10n.text("Branches"), GitL10n.text("Remote Branches"), GitL10n.text("Tags")])
        let feature = try #require(roots[1].children.first { $0.item.title == "feature" })
        let git = try #require(feature.children.first { $0.item.title == "git" })
        #expect(git.children.map(\.item.title) == ["diff", "history"])
        #expect(git.children.last?.item.id == GitCollectionBuilder.referenceID(refs[2]))
        #expect(roots[2].children.first?.item.title == "origin")
        let board = NSPasteboard.withUniqueName()
        InspectorCopyMenu.copy("unchanged", to: board)
        let list = GitReferenceListPopoverController(
            refs: refs, selected: refs[2], state: GitCollectionState(), colors: .init(),
            pasteboard: board, close: {}
        )
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GitRefPopoverStyle.size.width,
                                                height: GitRefPopoverStyle.size.height),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentViewController = list
        host.makeKeyAndOrderFront(nil)
        host.setContentSize(GitRefPopoverStyle.size)
        defer { host.contentViewController = nil; host.close() }
        try await Task.sleep(for: .milliseconds(150))
        list.view.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let tree = try #require(find(GitCollectionTableView.self, in: list.view).first)
        let coordinator = try #require(tree.target as? GitCollectionView.Coordinator)
        #expect(tree.frame.width > 300 && tree.visibleRect.height > 200)
        let visibleRows = tree.rows(in: tree.visibleRect)
        #expect(visibleRows.length >= 6)
        for index in visibleRows.location..<NSMaxRange(visibleRows) {
            let cell = try #require(tree.view(atColumn: 0, row: index, makeIfNecessary: true))
            cell.layoutSubtreeIfNeeded()
            #expect(find(NSTextField.self, in: cell).first?.bounds.width ?? 0 > 100)
        }
        #expect(board.string(forType: .string) == "unchanged")
        #expect(find(InspectorMetadataText.self, in: list.view).isEmpty)
        #expect(find(NSButton.self, in: list.view).allSatisfy { $0.toolTip?.hasPrefix("Copy") != true })
        coordinator.activateSelected()
        #expect(board.string(forType: .string) == "feature/git/history")
        host.makeFirstResponder(tree)
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == "feature/git/history")
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(list.view.bitmapImageRepForCachingDisplay(in: list.view.bounds))
            list.view.cacheDisplay(in: list.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-reference-tree.png"))
        }
    }

    @Test func messageBodyCopiesAsAWholeWithoutTogglingDisclosure() async throws {
        let commit = GitHistoryCommit(id: .init("1234567"), parentIDs: [], authorName: "Author", authorEmail: "a@example.com",
            authoredAt: Date(), subject: "Subject")
        let body = "alpha beta gamma\nsecond explanatory line"
        let expansion = GitCommitExpansion(metadata: .init(commitID: commit.id, authorName: commit.authorName,
            authorEmail: commit.authorEmail, authoredAt: "2026-09-09", parents: [], message: "Subject\n\n" + body))
        var opened = 0
        let view = NSHostingView(rootView: GitHistoryTable(commits: [commit], selectedCommitID: nil,
            expandedCommits: [commit.id: expansion], onSelect: { _ in }, onOpen: { _ in opened += 1 }, onShowInTerminal: { _ in }))
        view.sizingOptions = []
        let host = window(view)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let table = try #require(find(NSTableView.self, in: view).first)
        let cell = try #require(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let field = try #require(find(InspectorCopyableTextField.self, in: cell).first)
        let board = NSPasteboard.withUniqueName()
        field.pasteboard = board
        #expect(!field.isSelectable)
        let copyTable = try #require(table as? InspectorCopyTableView)
        copyTable.pasteboard = board
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        host.makeFirstResponder(table)
        #expect(EditorCommandRouter.shared.handle(try key("c", in: host)))
        #expect(board.string(forType: .string) == body)
        let before = table.rect(ofRow: 2).height
        let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
        coordinator.activateRow(2, doubleClick: false)
        coordinator.activateRow(2, doubleClick: true)
        #expect(table.rect(ofRow: 2).height == before && opened == 0)
        let controls = cell.subviews.compactMap { $0 as? NSButton }
        #expect(controls.count == 1)
        controls[0].performClick(nil)
        #expect(table.rect(ofRow: 2).height == 28)
    }

    @Test func repositoryHeaderShowsCopyablePathRemoteAndHeadTags() async throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo/oh-my-ghostty", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let rows: [(String, [String], String)] = [
            ("3df9918", ["5f1627b", "b7ee389"], "macos: integrate source-first markdown"),
            ("b7ee389", ["5f1627b"], "macos: replace milkdown with source editor"),
            ("5f1627b", ["67259da"], "macos/preview: restore clean github rendering"),
            ("67259da", [], "macos: set pointer cursor on link hover"),
        ]
        let commits = rows.enumerated().map { index, row in
            GitHistoryCommit(id: .init(row.0), parentIDs: row.1.map(GitCommitID.init), authorName: "jischeng",
                authorEmail: "j.s.cheng@hotmail.com", authoredAt: Date(timeIntervalSince1970: 1_788_800_000), subject: row.2,
                refDecorations: [.init(name: "codex/markdown-source-editor/compact-header-references", kind: index == 0 ? .currentBranch : .localBranch),
                                 .init(name: "dev-v0.11.0-" + row.0, kind: .tag), .init(name: "release-" + row.0, kind: .tag)])
        }
        var content = InspectorGitContent(repository: repository, branch: "codex/markdown-source-editor/compact-header-references",
            status: .ready(repository: repository, branch: "codex/markdown-source-editor/compact-header-references", headCommitID: commits[0].id),
            history: .init(commits: commits))
        content.workingTree.remoteURL = "https://example.com/team/oh-my-ghostty.git"
        let view = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in })
            .background(Color(NSColor.windowBackgroundColor)))
        view.sizingOptions = []
        let host = window(view, width: 265, height: 780)
        host.appearance = NSAppearance(named: .darkAqua)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let fields = find(InspectorCopyableTextField.self, in: view)
        #expect(fields.contains { $0.stringValue == repository.worktreePath })
        #expect(fields.contains { $0.stringValue == content.workingTree.remoteURL })
        let headerRefs = try #require(find(GitHeaderReferencesView.self, in: view).first)
        let namedRefs = find(InspectorCopyableTextField.self, in: headerRefs)
        #expect(namedRefs.map(\.copyValue) == ["codex/markdown-source-editor/compact-header-references", "dev-v0.11.0-3df9918", "release-3df9918"])
        #expect(namedRefs.allSatisfy { $0.frame.maxX <= headerRefs.bounds.width && $0.frame.maxY <= headerRefs.bounds.height })
        #expect(headerRefs.bounds.height > 17)
        #expect(namedRefs.first?.frame.height ?? 0 > 17)
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-usability-overview.png"))
        }
    }

    @Test func foldedRefsKeepANamedTagAndScopePickerUsesFullIDs() async throws {
        let refs = [.init(name: "main", kind: GitRefDecorationKind.currentBranch)] +
            (0..<8).map { GitRefDecoration(name: "very-long-release-tag-\($0)-production", kind: .tag) }
        for width in [144.0, 176.0, 300.0] {
            let badges = GitRefBadgesView.badges(for: refs, width: width)
            #expect(badges.contains { $0.decoration.kind == .tag && !$0.isCount })
            #expect(Set(badges.flatMap(\.refs)) == Set(refs))
        }
        let twoTags = Array(refs.prefix(3))
        let compactTags = GitRefBadgesView.badges(for: twoTags, width: 360)
        #expect(compactTags.filter { $0.decoration.kind == .tag && !$0.isCount }.count == 1)
        #expect(compactTags.contains { $0.decoration.kind == .tag && $0.isCount })
        let name = String(repeating: "超长分支名称/", count: 30)
        let branch = GitBranchInfo(name: name, commit: .init("a"), isCurrent: true, isRemote: false, upstream: "", tracking: "")
        var actions: [InspectorGitAction] = []
        let view = NSHostingView(rootView: GitHistoryScopePicker(title: name, branches: [branch], enabled: true) { actions.append($0) })
        view.sizingOptions = []
        let host = window(view, width: 220, height: 30)
        defer { host.contentView = nil; host.close() }
        try await Task.sleep(for: .milliseconds(100))
        let control = try #require(find(GitHistoryScopePicker.Control.self, in: view).first)
        control.showPicker()
        try await Task.sleep(for: .milliseconds(100))
        let popover = try #require(control.popover)
        let picker = try #require(popover.contentViewController?.view)
        let table = try #require(find(GitCollectionTableView.self, in: picker).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        let index = try #require(coordinator.rows.firstIndex { $0.id == branch.id })
        for _ in 0..<20 { picker.layoutSubtreeIfNeeded() }
        #expect(find(GitCollectionTableView.self, in: picker).first === table)
        coordinator.activate(row: index)
        #expect(actions == [.browseBranch(branch.id)])
        #expect(!popover.isShown)
        #expect(control.bounds.width <= 220)
    }
}
