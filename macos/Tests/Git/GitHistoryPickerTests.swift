import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryPickerTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test func pickerSearchArrowEnterAndEscapeUseFullReferencesAndWorktreeIdentity() async throws {
        let branches = ["main", "feature/query", "feature/quota", "origin/foo"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: $0 == "main", isRemote: $0.hasPrefix("origin/"), upstream: "", tracking: "")
        }
        let worktree = GitWorktreeInfo(path: "/dev/repo-feature", head: .init("abc1234"), branchRef: "refs/heads/feature/query", isMain: false, isCurrent: false)
        var actions: [InspectorGitAction] = []
        let picker = GitHistoryScopePicker(title: "All branches", branches: branches, enabled: true,
            worktrees: [worktree], selectedID: "scope:allBranches") { actions.append($0) }
        let host = NSHostingView(rootView: picker)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let control = try #require(find(GitHistoryScopePicker.Control.self, in: host).first)

        func open() async throws -> (NSPopover, NSSearchField, GitCollectionTableView) {
            control.showPicker()
            try await Task.sleep(for: .milliseconds(100))
            let popover = try #require(control.popover)
            let view = try #require(popover.contentViewController?.view)
            let search = try #require(find(NSSearchField.self, in: view).first)
            let table = try #require(find(GitCollectionTableView.self, in: view).first)
            let owner = try #require(popover.contentViewController as? GitHistoryScopePopoverController)
            #expect(search.cell is GitSearchFieldCell)
            #expect(search.focusRingType == .none)
            #expect(view.layer?.backgroundColor != nil)
            #expect(owner.scopeControlForTesting.bounds.width == 320)
            #expect(owner.scopeControlForTesting.buttonsForTesting.map(\.title) == GitHistoryScope.allCases.map(\.displayName))
            #expect(owner.scopeControlForTesting.bounds.height == 26)
            for button in owner.modeControlForTesting.buttonsForTesting {
                #expect(!button.isBordered)
                #expect(abs(button.bounds.height - 24) < 1)
            }
            #expect(table.visibleRect.height > 120 && search.bounds.width > 150)
            #expect(popover.contentSize.height <= 340 && popover.contentSize.width == 340)
            #expect(table.visibleRect.minY <= 1, "Initial branch rows must not be clipped")
            let editor = try #require(search.currentEditor() as? NSTextView)
            let textRect = search.convert(editor.bounds, from: editor)
            #expect(textRect.minX + editor.textContainerInset.width + (editor.textContainer?.lineFragmentPadding ?? 0) >= 16,
                    "Focused search text must leave room for the search icon")
            if FileManager.default.fileExists(atPath: "/tmp/omg-native-visual-review") {
                for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let appearance = try #require(NSAppearance(named: name))
                    popover.contentViewController?.view.appearance = appearance
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    appearance.performAsCurrentDrawingAppearance {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                    }
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/tmp/omg-git-history-picker-\(suffix).png"))
                }
            }
            return (popover, search, table)
        }
        func type(_ text: String, into field: NSSearchField) async throws {
            field.stringValue = text
            let delegate = try #require(field.delegate as? GitHistoryScopePopoverController)
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(for: .milliseconds(80))
        }
        func key(_ selector: String, in field: NSSearchField) throws {
            let delegate = try #require(field.delegate as? GitHistoryScopePopoverController)
            let editor = field.currentEditor() as? NSTextView ?? NSTextView()
            #expect(delegate.control(field, textView: editor, doCommandBy: NSSelectorFromString(selector)))
        }
        let (popover, search, table) = try await open()
        try await type("FEATURE/QU", into: search)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/query")
        try key("moveDown:", in: search)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/quota")
        try key("moveUp:", in: search)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/query")
        try key("moveDown:", in: search)
        try key("insertNewline:", in: search)
        #expect(actions == [.browseBranch("refs/heads/feature/quota")])
        #expect(!popover.isShown)

        let (worktreePopover, worktreeSearch, _) = try await open()
        try await type("REPO-FEATURE", into: worktreeSearch)
        try key("insertNewline:", in: worktreeSearch)
        #expect(actions.last == .browseWorktree(worktree.path))
        #expect(!worktreePopover.isShown)

        let (cancelled, cancelledSearch, _) = try await open()
        try await type("origin/FOO", into: cancelledSearch)
        let before = actions
        try key("cancelOperation:", in: cancelledSearch)
        #expect(!cancelled.isShown && actions == before)
    }
}
