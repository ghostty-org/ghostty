import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitNativeDialogTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    private func render(_ view: NSView, to path: String) throws {
        guard FileManager.default.fileExists(atPath: "/tmp/omg-native-controls-render") else { return }
        let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    @Test func tagDialogUsesNativeControlsAndValidatesNames() throws {
        let repository = GitRepositoryIdentity(
            worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git"
        )
        let commit = GitHistoryCommit(
            id: .init("1234567"), parentIDs: [], authorName: "A", authorEmail: "",
            authoredAt: .distantPast, subject: "Initial commit"
        )
        let controller = GitTagDialogController(repository: repository, commit: commit) { _ in }
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: GitTagDialog.panelSize)
        view.layoutSubtreeIfNeeded()
        try render(view, to: "/tmp/omg-native-tag.png")
        #expect(find(NSHostingView<AnyView>.self, in: view).isEmpty)
        let fittingHeight = find(NSStackView.self, in: view).last?.fittingSize.height ?? .greatestFiniteMagnitude
        #expect(fittingHeight <= GitTagDialog.panelSize.height)
        let fields = find(NSTextField.self, in: view)
        #expect(fields.contains { $0.stringValue == "Initial commit" })
        let name = try #require(fields.first { $0.placeholderString == "v1.2.0" })
        name.stringValue = "v1.2.0"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        #expect(find(NSButton.self, in: view).contains { $0.title == GitL10n.text("Create Tag") && $0.isEnabled })
        name.stringValue = "invalid tag"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        #expect(find(NSButton.self, in: view).contains { $0.title == GitL10n.text("Create Tag") && !$0.isEnabled })
    }

    @Test func commitIntegrationUsesCommitAsSourceAndNativeControls() throws {
        let repository = GitRepositoryIdentity(
            worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git"
        )
        let commit = GitHistoryCommit(
            id: .init("1234567890"), parentIDs: [.init("parent-a"), .init("parent-b")],
            authorName: "A", authorEmail: "", authoredAt: .distantPast, subject: "Merge commit"
        )
        let branches = [
            GitBranchInfo(name: "main", commit: .init("1234567"), isCurrent: true, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "origin/main", commit: .init("1234567"), isCurrent: false, isRemote: true, upstream: "", tracking: "")
        ]
        let controller = GitIntegrationDialogController(
            kind: .cherryPick, repository: repository, branches: branches,
            initialSource: nil, commit: commit
        ) { _ in }
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: GitIntegrationDialog.panelSize)
        view.layoutSubtreeIfNeeded()
        try render(view, to: "/tmp/omg-native-integration.png")
        #expect(controller.source == commit.id.rawValue)
        #expect(find(NSHostingView<AnyView>.self, in: view).isEmpty)
        let fittingHeight = find(NSStackView.self, in: view).last?.fittingSize.height ?? .greatestFiniteMagnitude
        #expect(fittingHeight <= GitIntegrationDialog.panelSize.height)
        #expect(!find(NSTextView.self, in: view).isEmpty)
        let scroll = try #require(find(NSScrollView.self, in: view).first)
        #expect(scroll.frame.width >= 500)
        #expect(scroll.frame.height == 150)
        #expect((scroll.documentView?.frame.width ?? 0) >= 500)
        #expect(!find(NSPopUpButton.self, in: view).isEmpty)
        let proceed = try #require(find(NSButton.self, in: view).first { $0.title == GitL10n.text("Continue…") })
        #expect(proceed.isEnabled)
        #expect(proceed.keyEquivalent.isEmpty, "Return in the message editor must remain a newline.")
        let message = try #require(scroll.documentView as? NSTextView)
        message.string = " \n "
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: message))
        #expect(!proceed.isEnabled)
    }

    @Test func reviewPickerKeepsLocalSourcesAndCurrentBranchFallback() throws {
        let repository = GitRepositoryIdentity(
            worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git"
        )
        let source = "refs/heads/feature"
        let key = "git.reviewTarget." + repository.stateKey
        UserDefaults.ghostty.set(source, forKey: key)
        defer { UserDefaults.ghostty.removeObject(forKey: key) }
        let branches = [
            GitBranchInfo(name: "main", commit: .init("aaaaaaa"), isCurrent: true, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "feature", commit: .init("bbbbbbb"), isCurrent: false, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "develop", commit: .init("ccccccc"), isCurrent: false, isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "origin/main", commit: .init("aaaaaaa"), isCurrent: false, isRemote: true, upstream: "", tracking: "")
        ]
        let controller = GitIntegrationDialogController(
            kind: .review, repository: repository, branches: branches,
            initialSource: source, commit: nil
        ) { _ in }
        let view = controller.view
        #expect(controller.source == source)
        #expect(controller.target == "refs/heads/main")
        #expect(find(NSPopUpButton.self, in: view).allSatisfy { picker in
            !(0..<picker.numberOfItems).contains { picker.item(at: $0)?.title == "origin/main" }
        })
    }
}
