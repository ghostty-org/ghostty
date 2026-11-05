import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryPickerTests {
    @Test func unfavoritedStarsAppearOnlyInsideTheirHitRegionAndFavoritesStayVisible() throws {
        let cell = GitCollectionCell(frame: .init(x: 0, y: 0, width: 320, height: 26))
        let branch = GitBranchInfo(name: "main", commit: .init("abc1234"), isCurrent: true,
                                   isRemote: false, upstream: "", tracking: "")
        let row = GitCollectionRow(item: .init(id: branch.id, title: branch.name, kind: .branch(branch, worktrees: [])), depth: 0)
        var toggles = 0
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (false, { toggles += 1 }))
        cell.layoutSubtreeIfNeeded()
        let button = cell.favoriteButton
        #expect(!button.isHidden, "The invisible star must keep its clickable hit region")
        #expect(!button.showsStar)
        #expect(cell.hitTest(.init(x: 300, y: 13)) === button)
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let exited = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseEntered(with: entered)
        #expect(button.showsStar)
        button.mouseExited(with: exited)
        #expect(!button.showsStar)
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (true, {}))
        #expect(button.showsStar)
        button.mouseEntered(with: entered)
        button.mouseExited(with: exited)
        #expect(button.showsStar)
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (false, { toggles += 1 }))
        #expect(!button.showsStar, "Reused cells must clear the previous branch's filled star")
        button.performClick(nil)
        #expect(toggles == 1)
        cell.configure(row, colors: .init(), toggle: {}, stage: {})
        #expect(button.isHidden, "Other Git collections must not acquire a favorite action")
    }

    @Test func favoritesPersistShareWorktreesAndSeparateRepositoriesAndSSHHosts() throws {
        let suite = "GitHistoryFavoritesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let worktree = GitRepositoryIdentity(worktreePath: "/repo-feature", gitDirPath: "/repo/.git/worktrees/feature", commonGitDirPath: "/repo/.git")
        let other = GitRepositoryIdentity(worktreePath: "/other", gitDirPath: "/other/.git", commonGitDirPath: "/other/.git")
        let store = GitHistoryBranchFavorites(repository: repository, defaults: defaults)
        store.toggle("refs/heads/main")
        store.toggle("refs/remotes/origin/main")
        store.toggle("refs/tags/v1")
        #expect(GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs == ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(GitHistoryBranchFavorites(repository: worktree, defaults: defaults).refs == store.refs)
        #expect(GitHistoryBranchFavorites(repository: other, defaults: defaults).refs.isEmpty)
        func remote(_ host: String) throws -> GitHistoryBranchFavorites {
            GitHistoryBranchFavorites(repository: GitRepositoryIdentity(target: .ssh(try GitSSHConnection(destination: host)),
                worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git"), defaults: defaults)
        }
        let firstHost = try remote("host-a")
        let secondHost = try remote("host-b")
        #expect(firstHost.refs.isEmpty)
        firstHost.toggle("refs/heads/remote-only")
        #expect(secondHost.refs.isEmpty)
        #expect(!store.refs.contains("refs/heads/remote-only"))
        store.toggle("refs/heads/main")
        #expect(store.refs == ["refs/remotes/origin/main"])
        store.toggle("refs/remotes/origin/main")
        #expect(store.refs.isEmpty)
    }

    @Test func favoriteFilterKeepsFullRefIdentitySearchAndTreeModes() {
        let branches = [("feature/main", false), ("origin/main", true), ("main", false)].map { name, remote in
            GitBranchInfo(name: name, commit: .init("abc1234"), isCurrent: name == "main", isRemote: remote, upstream: "", tracking: "")
        }
        let source = GitCollectionSource.refs(branches: branches, worktrees: [], scopes: true, branchesError: nil, worktreesError: nil)
        let favorites: Set<String> = ["refs/heads/feature/main", "refs/remotes/origin/main", "refs/heads/deleted"]
        for mode in GitCollectionMode.allCases {
            let nodes = GitCollectionBuilder.nodes(source: source, mode: mode, favoriteBranchIDs: favorites)
            let rows = GitCollectionBuilder.rows(nodes)
            #expect(rows.filter { if case .branch = $0.item.kind { return true }; return false }.map(\.id).sorted()
                == ["refs/heads/feature/main", "refs/remotes/origin/main"])
            let searched = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: mode, query: "ORIGIN",
                favoriteBranchIDs: favorites))
            #expect(searched.contains { $0.id == "refs/remotes/origin/main" })
            #expect(!searched.contains { $0.id == "refs/heads/feature/main" })
        }
        let empty = GitCollectionBuilder.nodes(source: source, mode: .list, favoriteBranchIDs: [])
        #expect(empty.first?.children.first?.item.title == GitL10n.text("No favorite branches. Star a branch to add it here."))
    }

    @Test func favoriteButtonsUpdateWithoutBrowsingAndPickerStillSelectsCurrentScope() throws {
        let suite = "GitHistoryFavoritesPickerTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let branches = ["main", "feature/demo"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: $0 == "main", isRemote: false, upstream: "", tracking: "")
        }
        var actions: [InspectorGitAction] = []
        var closed = false
        let picker = GitHistoryScopePicker(title: "All branches", branches: branches, enabled: true,
            selectedID: "scope:allBranches", repository: repository) { actions.append($0) }
        let controller = GitHistoryScopePopoverController(content: picker, defaults: defaults) { closed = true }
        let window = NSWindow(contentRect: .init(origin: .zero, size: controller.preferredContentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let table = try #require(find(GitCollectionTableView.self, in: controller.view).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        func star(_ id: String) throws -> NSButton {
            let row = try #require(coordinator.rows.firstIndex { $0.id == id })
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? GitCollectionCell)
            cell.layoutSubtreeIfNeeded()
            #expect(!cell.favoriteButton.isHidden)
            #expect(cell.favoriteButton.frame.width == 24)
            return cell.favoriteButton
        }
        try star("refs/heads/main").performClick(nil)
        #expect(GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs == ["refs/heads/main"])
        #expect(actions.isEmpty && !closed)
        #expect(controller.scopeControlForTesting.buttonsForTesting.map(\.title)
            == ["Current", "Favorites", "All"].map { GitL10n.text($0) })
        controller.scopeControlForTesting.buttonsForTesting[1].performClick(nil)
        #expect(coordinator.rows.contains { $0.id == "refs/heads/main" })
        #expect(!coordinator.rows.contains { $0.id == "refs/heads/feature/demo" })
        let selected = try #require(coordinator.rows.firstIndex { $0.id == "refs/heads/main" })
        coordinator.activate(row: selected)
        #expect(actions == [.browseBranch("refs/heads/main")] && closed)
        closed = false
        try star("refs/heads/main").performClick(nil)
        #expect(!coordinator.rows.contains { $0.id == "refs/heads/main" })
        #expect(!closed)
        controller.scopeControlForTesting.buttonsForTesting[2].performClick(nil)
        #expect(coordinator.rows.contains { $0.id == "refs/heads/feature/demo" })
        #expect(actions.last == .selectHistoryScope(.allBranches))
        #expect(closed)
        closed = false
        controller.scopeControlForTesting.buttonsForTesting[0].performClick(nil)
        #expect(actions.last == .selectHistoryScope(.currentBranch))
        #expect(closed)
    }

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
            #expect(owner.scopeControlForTesting.buttonsForTesting.map(\.title)
                == ["Current", "Favorites", "All"].map { GitL10n.text($0) })
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
