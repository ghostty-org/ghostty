import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitInspectorLayoutTests {
    @Test func historyOmitsModeAndBranchAddPrecedesModes() async throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo/oh-my-ghostty", gitDirPath: "/repo/.git",
                                               commonGitDirPath: "/repo/.git")
        let content = InspectorGitContent(repository: repository, branch: "main",
            status: .ready(repository: repository, branch: "main", headCommitID: nil), activeTab: .history)
        let theme = OMGNativeTheme(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                                   foreground: NSColor(white: 0.85, alpha: 1))
        func presentation(_ value: InspectorGitContent) -> some View {
            InspectorGitView(content: value, perform: { _ in })
                .environment(\.gitCollectionColors, GitCollectionColors(nativeTheme: theme))
                .background(Color(theme.background))
        }
        let host = NSHostingView(rootView: presentation(content))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        #expect(!all(host).contains { $0.accessibilityIdentifier() == "git.collection.mode" })
        let branches = InspectorGitContent(repository: repository, branch: "main",
            status: .ready(repository: repository, branch: "main", headCommitID: nil), activeTab: .branches)
        host.rootView = presentation(branches)
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let add = try #require(all(host).first { $0.accessibilityIdentifier() == "git.new-worktree" })
        let modes = try #require(all(host).first { $0.accessibilityIdentifier() == "git.collection.mode" })
        #expect(add.convert(add.bounds, to: host).maxX <= modes.convert(modes.bounds, to: host).minX)
        if FileManager.default.fileExists(atPath: "/tmp/omg-unified-theme-preview") {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/omg-git-unified.png"))
        }
    }

    @Test func historyFitsMinimumInspectorWidthWithLongRefs() async throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let commit = GitHistoryCommit(id: GitCommitID("1234567890"), parentIDs: [], authorName: "Contributor",
                                      authorEmail: "author@example.com", authoredAt: Date(timeIntervalSince1970: 0),
                                      subject: "A long commit subject that must truncate within the sidebar",
                                      refDecorations: [
                                        .init(name: "feature/very-long-current-branch", kind: .currentBranch),
                                        .init(name: "v1.2.3", kind: .tag),
                                        .init(name: "origin/main", kind: .remoteBranch),
                                      ])
        var content = InspectorGitContent(repository: repository, branch: "feature/very-long-current-branch",
                                          status: .ready(repository: repository, branch: "main", headCommitID: commit.id),
                                          history: .init(commits: [commit]))
        content.workingTree.branches = [
            .init(name: "feature/very-long-current-branch", commit: commit.id, isCurrent: true,
                  isRemote: false, upstream: "origin/main", tracking: "[ahead 12, behind 3]"),
        ]
        for width in [220.0, 360.0] {
            let view = NSHostingView(rootView: InspectorGitView(content: content, perform: { _ in })
                .background(Color(NSColor.windowBackgroundColor)))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.orderFront(nil)
            window.setContentSize(NSSize(width: width, height: 500))
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let table = try #require(descendant(NSTableView.self, in: view))
            #expect(table.bounds.width <= width)
            #expect(table.tableColumns[0].width <= width)
            #expect(table.numberOfRows == 1)
            if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-history-\(Int(width)).png"))

            }
            if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
                var expanded = content
                expanded.expandedCommits[commit.id] = GitCommitExpansion(metadata: .init(commitID: commit.id,
                    authorName: "Contributor", authorEmail: "author@example.com", authoredAt: "2026-09-09 12:00",
                    parents: [], message: "Clarify history metadata\n\nKeep author and time visible before the message."),
                    files: [.init(path: "Sources/History.swift", status: "M"),
                            .init(path: "Sources/Status.swift", status: "A"),
                            .init(path: "Sources/OldWindow.swift", status: "D")])
                view.rootView = InspectorGitView(content: expanded, perform: { _ in })
                    .background(Color(NSColor.windowBackgroundColor))
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-history-expanded-\(Int(width)).png"))
            }
            window.contentView = nil
            window.close()
        }
    }

    @Test func sourceComparisonUsesReadOnlyEditorAndLineTint() async throws {
        let source = """
        import Foundation

        struct Commit {
            let subject: String
            let count = 42
        }
        """
        let view = NSHostingView(rootView: CodeEditorView(text: .constant(source),
            fileURL: URL(fileURLWithPath: "/example.swift"), diffLines: [4: true], isEditable: false, terminalTheme: .oneDark)
            .frame(width: 640, height: 300).background(Color(NSColor.textBackgroundColor)))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let editor = try #require(descendant(TextView.self, in: view))
        #expect(editor.string == source)
        #expect(!editor.isEditable)
        let numberOffset = (source as NSString).range(of: "42").location
        for _ in 0..<40 {
            let color = editor.textStorage.attribute(.foregroundColor, at: numberOffset, effectiveRange: nil) as? NSColor
            if color != nil && color != editor.textColor { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let numberColor = editor.textStorage.attribute(.foregroundColor, at: numberOffset, effectiveRange: nil) as? NSColor
        #expect(numberColor != nil && numberColor != editor.textColor)
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-editor.png"))
        }
    }

    @Test func worktreesShowTheirOwnActionsAndProtectCurrentAndLockedDirectories() async throws {
        let repo = GitRepositoryIdentity(worktreePath: "/repo/main", gitDirPath: "/repo/main/.git", commonGitDirPath: "/repo/main/.git")
        let branch = GitBranchInfo(name: "main", commit: .init("abc"), isCurrent: true, isRemote: false, upstream: "", tracking: "")
        let worktrees = [
            GitWorktreeInfo(path: "/repo/main", head: .init("abc"), branchRef: "refs/heads/main", isMain: true, isCurrent: true),
            GitWorktreeInfo(path: "/repo/feature-ui", head: .init("def"), branchRef: "refs/heads/feature/ui", isMain: false, isCurrent: false),
            GitWorktreeInfo(path: "/repo/review", head: .init("def"), branchRef: nil, isMain: false, isCurrent: false, lockedReason: "Review in progress"),
        ]
        var content = InspectorGitContent(repository: repo, branch: "main", status: .ready(repository: repo, branch: "main", headCommitID: .init("abc")), activeTab: .branches)
        content.workingTree.branches = [branch]
        content.workingTree.worktrees = worktrees
        var actions: [InspectorPaneActionKind] = []
        let view = NSHostingView(rootView: InspectorGitView(content: content) { actions.append($0) }
            .background(Color(NSColor.windowBackgroundColor)))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let tree = try #require(descendant(GitCollectionTableView.self, in: view))
        let coordinator = try #require(tree.target as? GitCollectionView.Coordinator)
        let menu = try #require(tree.menu)
        for worktree in worktrees {
            let row = try #require(coordinator.rows.firstIndex { $0.id == "worktree:" + worktree.path })
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            coordinator.activateSelected()
            #expect(actions.last == .gitAction(.openWorktree(worktree.path)))
            coordinator.menuNeedsUpdate(menu)
            #expect(menu.items.map(\.title) ==
                ["Open in New Tab", "Copy Worktree Path", "Remove Worktree…"].map(GitL10n.text))
            #expect(menu.items.last?.isEnabled == worktree.canRemove)
            let cell = try #require(tree.view(atColumn: 0, row: row, makeIfNecessary: true))
            #expect(cell.toolTip?.contains(worktree.path) == true)
        }
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-worktrees.png"))
        }
    }

    @Test func branchSelectionDoesNotNavigateUntilDoubleClickAndMenuHasWriteActions() async throws {
        let branch = GitBranchInfo(name: "main", commit: GitCommitID("abc"), isCurrent: true,
                                   isRemote: false, upstream: "origin/main", tracking: "")
        var actions: [InspectorGitAction] = []
        let view = NSHostingView(rootView: GitRefBrowser(branches: [branch], isBusy: false) { actions.append($0) }
            .frame(width: 240, height: 260))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let tree = try #require(descendant(GitCollectionTableView.self, in: view))
        tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(actions.isEmpty)
        let coordinator = try #require(tree.target as? GitCollectionView.Coordinator)
        coordinator.activateSelected()
        #expect(actions == [.browseBranch(branch.id)])
        let menu = try #require(tree.menu)
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == GitL10n.text("New Branch from Here…") })
        #expect(menu.items.contains { $0.title == GitL10n.text("Push to…") })
        #expect(menu.items.contains { $0.title == GitL10n.text("Set Upstream…") })
        #expect(menu.items.first(where: { $0.title == GitL10n.text("Switch Branch") })?.isEnabled == false)
        #expect(coordinator.rows[0].item.isCategory)
        #expect(!coordinator.rows[0].item.isSelectable)
        #expect(actions == [.browseBranch(branch.id)])
    }

    @Test func linkedDiffScrollsBothDirectionsBySourceLinesAndCanBeDisabled() async throws {
        let beforeLines = (0..<200).map { "line \($0)" }
        var afterLines = beforeLines
        afterLines.insert(contentsOf: ["inserted one", "inserted two"], at: 21)
        let before = beforeLines.joined(separator: "\n") + "\n"
        let after = afterLines.joined(separator: "\n") + "\n"
        let link = GitDiffScrollLink()
        link.presentation = GitDiffPresentation(before: before, after: after,
                                                        patch: "@@ -21,0 +22,2 @@\n+inserted one\n+inserted two\n")
        func root(_ identity: String) -> some View {
            HStack(spacing: 0) {
                GitDiffLinkedEditor(text: before, path: "/before.txt", highlights: [:], isActive: true,
                                    theme: .oneDark, link: link, side: 0, close: {}).id(identity + "-left")
                GitDiffLinkedEditor(text: after, path: "/after.txt", highlights: [:], isActive: true,
                                    theme: .oneDark, link: link, side: 1, close: {}).id(identity + "-right")
            }.frame(width: 900, height: 300)
        }
        let view = NSHostingView(rootView: root("first"))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(250))
        func editors(_ view: NSView) -> [TextView] {
            if let text = view as? TextView { return [text] }
            return view.subviews.flatMap(editors)
        }
        let values = editors(view)
        #expect(values.count == 2)
        let left = try #require(values.first)
        let right = try #require(values.last)
        func scroll(_ text: TextView, to index: Int) throws {
            let line = try #require(text.layoutManager.textLineForIndex(index))
            let clip = try #require(text.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: line.yPos))
            text.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        func expectPosition(_ text: TextView, at index: Int) throws {
            let line = try #require(text.layoutManager.textLineForIndex(index))
            let origin = try #require(text.enclosingScrollView?.contentView.bounds.minY)
            // NSClipView rounds scroll origins to backing pixels. A fractional
            // sliver of the preceding line must not count as a whole-line error.
            #expect(abs(origin - line.yPos) <= 1)
        }
        try scroll(left, to: 80)
        try expectPosition(right, at: 82)
        try scroll(right, to: 120)
        try expectPosition(left, at: 118)
        link.enabled = false
        let previous = right.enclosingScrollView?.contentView.bounds.origin
        try scroll(left, to: 30)
        #expect(right.enclosingScrollView?.contentView.bounds.origin == previous)
        link.enabled = true
        view.rootView = root("replacement")
        try await Task.sleep(for: .milliseconds(200))
        let replacements = editors(view)
        let nextLeft = try #require(replacements.first)
        let nextRight = try #require(replacements.last)
        #expect(nextLeft !== left && nextRight !== right)
        try scroll(nextLeft, to: 60)
        try expectPosition(nextRight, at: 62)
        try scroll(nextRight, to: 100)
        try expectPosition(nextLeft, at: 98)
    }

    @Test func deletedCRLFFileOpensNativeBeforeAndAfterEditors() async throws {
        let defaults = UserDefaults.standard
        let savedReview = defaults.object(forKey: "git.diff.review")
        let savedMode = defaults.object(forKey: "git.diff.viewMode")
        let savedWrap = defaults.object(forKey: "git.diff.wordWrap")
        defaults.set(true, forKey: "git.diff.wordWrap")
        defaults.set(false, forKey: "git.diff.review")
        defaults.set(GitL10n.text("Side by Side"), forKey: "git.diff.viewMode")
        defer {
            defaults.set(savedReview, forKey: "git.diff.review")
            defaults.set(savedMode, forKey: "git.diff.viewMode")
            defaults.set(savedWrap, forKey: "git.diff.wordWrap")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-deleted-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import Foundation\r\n\r\nlet removed = 42\r\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("removed.swift"))
        for arguments in [["init", "--quiet"], ["config", "core.autocrlf", "false"], ["add", "."]] {
            let result = try await LocalGitExecutor().execute(arguments: arguments, workingDirectory: root.path)
            try #require(result.isSuccess)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.swift"))
        let repository = GitRepositoryIdentity(worktreePath: root.path, gitDirPath: root.path + "/.git",
                                               commonGitDirPath: root.path + "/.git")
        let request = GitEditorDiffRequest(repository: repository, target: .unstaged,
                                           file: .init(path: "removed.swift", status: "D"))
        let view = NSHostingView(rootView: GitEditorDiffView(request: request, theme: .oneDark, close: {})
            .background(Color(NSColor.windowBackgroundColor)))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func editors(in view: NSView) -> [TextView] {
            if let text = view as? TextView { return [text] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        for _ in 0..<100 {
            if editors(in: view).count == 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        view.layoutSubtreeIfNeeded()
        let sources = editors(in: view)
        #expect(sources.count == 2)
        #expect(sources.contains { $0.string == source })
        #expect(sources.contains { $0.string.isEmpty })
        #expect(sources.allSatisfy { !$0.isEditable })
        #expect(sources.allSatisfy { $0.wrapLines })
        func buttons(in root: NSView) -> [NativeActionControl] {
            (root as? NativeActionControl).map { [$0] } ?? root.subviews.flatMap { buttons(in: $0) }
        }
        let wrap = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Wrap diff lines") })
        let refresh = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Refresh diff") })
        let refreshX = refresh.convert(refresh.bounds, to: view).minX
        wrap.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(editors(in: view).allSatisfy { !$0.wrapLines })
        for review in [true, false] {
            defaults.set(review, forKey: "git.diff.review")
            for mode in [GitL10n.text("Inline"), GitL10n.text("Side by Side")] {
                defaults.set(mode, forKey: "git.diff.viewMode")
                try await Task.sleep(for: .milliseconds(100))
                view.layoutSubtreeIfNeeded()
                let visibleWrap = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Wrap diff lines") })
                #expect(!visibleWrap.isHiddenOrHasHiddenAncestor)
                let currentRefresh = try #require(buttons(in: view).first { $0.toolTip == GitL10n.text("Refresh diff") })
                #expect(abs(currentRefresh.convert(currentRefresh.bounds, to: view).minX - refreshX) < 1)
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/omg-git-render") {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/omg-git-deleted-source.png"))
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }
}
