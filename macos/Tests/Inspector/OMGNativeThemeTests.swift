import AppKit
import Testing
@testable import Ghostty

@MainActor
struct OMGNativeThemeTests {
    @Test func attachedNativeControlsFollowTwoDarkThemesAndOneLightThemeWithoutRemounting() throws {
        let surface = OMGNativeSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        let button = NativeActionControl(frame: NSRect(x: 10, y: 10, width: 120, height: 28))
        button.configure(title: "Commit", symbol: "checkmark", help: nil,
                         enabled: true, style: .prominent, identifier: nil)
        let search = OMGNativeSearchField(frame: NSRect(x: 10, y: 50, width: 300, height: 28))
        search.placeholderString = "Search sessions"
        search.stringValue = "draft"
        surface.addSubview(button)
        surface.addSubview(search)
        let window = NSWindow(contentRect: surface.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.bindTheme(to: window)
        defer { window.contentView = nil; window.close() }
        for background in ["1e2030", "123456", "f5f4ef"] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try "background = \(background)\nforeground = abcdef\npalette = 4=#78aacc\n"
                .write(to: file, atomically: true, encoding: .utf8)
            let config = Ghostty.Config(at: file.path)
            NotificationCenter.default.post(name: .ghosttyConfigDidChange, object: window,
                userInfo: [Notification.Name.GhosttyConfigChangeKey: config])
            let expected = OMGNativeTheme.resolve(for: window, config: config)
            #expect(surface.theme == expected)
            #expect(button.theme == expected)
            #expect(search.theme == expected)
            #expect(search.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
                    as? NSColor == expected.secondary)
            #expect(search.stringValue == "draft")
            #expect(window.contentView === surface)
            if FileManager.default.fileExists(atPath: "/tmp/omg-unified-theme-preview") {
                button.isEnabled = false
                let icon = NativeActionControl(frame: NSRect(x: 142, y: 10, width: 28, height: 28))
                icon.configure(title: "", symbol: "stop.fill", help: "Stop", enabled: true,
                               style: .bordered, identifier: nil)
                surface.addSubview(icon)
                let menu = NativeActionControl(frame: NSRect(x: 182, y: 10, width: 28, height: 28))
                menu.configure(title: "", symbol: "chevron.down", help: "Menu", enabled: true,
                               style: .bordered, identifier: nil)
                menu.menuWillOpen(NSMenu())
                surface.addSubview(menu)
                surface.applyTheme(expected)
                try render(surface, to: "/tmp/omg-controls-\(background).png")
                icon.removeFromSuperview()
                menu.removeFromSuperview()
                button.isEnabled = true
            }
        }
    }

    @Test func disabledProminentButtonIsNeutralAndMenuHasAnExplicitExpandedState() throws {
        let button = NativeActionControl(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.configure(title: "", symbol: "stop.fill", help: "Stop",
                         enabled: false, style: .prominent, identifier: nil)
        let theme = OMGNativeTheme(background: .black, foreground: .white, accent: .systemRed)
        button.applyTheme(theme)
        #expect(button.effectiveFill == theme.controlFill)
        #expect(button.glyphRect.midX == button.bounds.midX && button.glyphRect.midY == button.bounds.midY)
        button.isEnabled = true
        let menu = NSMenu()
        button.menuWillOpen(menu)
        #expect(button.isMenuOpen)
        #expect(button.effectiveFill == theme.selectedFill)
        button.menuDidClose(menu)
        #expect(!button.isMenuOpen)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseEntered(with: event)
        #expect(button.isHovered)
        button.mouseExited(with: event)
        #expect(!button.isHovered)
    }

    @Test func worktreeFormHasNativeValidationAndKeepsExplicitRevisionAndMode() throws {
        let repository = GitRepositoryIdentity(worktreePath: "/repo/main", gitDirPath: "/repo/main/.git",
                                               commonGitDirPath: "/repo/main/.git")
        var result: GitWorktreeActions.Creation?
        let controller = GitWorktreeCreationController(start: "refs/heads/main", repository: repository,
                                                       detached: false) { result = $0 }
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        #expect(!controller.createButton.isEnabled)
        controller.pathField.stringValue = "/repo/feature"
        controller.branchField.stringValue = "feature/test"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.createButton.isEnabled)
        #expect(controller.creation?.mutation == .addWorktree(path: "/repo/feature", start: "refs/heads/main",
                                                              branch: "feature/test", detached: false))
        controller.modePicker.selectItem(at: 1)
        controller.modeChanged()
        #expect(!controller.branchField.isEnabled)
        controller.submit()
        #expect(result?.mutation == .addWorktree(path: "/repo/feature", start: "refs/heads/main", branch: nil, detached: true))
        #expect(result?.openAfterCreation == true)
    }

    @Test func worktreeNativeSurfaceAndControlsShareLivePalette() throws {
        let repo = GitRepositoryIdentity(worktreePath: "/code/omg", gitDirPath: "/code/omg/.git",
                                         commonGitDirPath: "/code/omg/.git")
        let controller = GitWorktreeCreationController(start: "HEAD", repository: repo, detached: false) { _ in }
        let root = try #require(controller.view as? OMGNativeSurfaceView)
        root.frame = NSRect(origin: .zero, size: root.fittingSize)
        root.layoutSubtreeIfNeeded()
        #expect(root.bounds.width == 470)
        #expect(controller.pathField.frame.width > 400)
        for (name, theme) in palettes {
            root.applyTheme(theme)
            root.updateLayer()
            #expect(controller.createButton.theme == theme)
            if FileManager.default.fileExists(atPath: "/tmp/omg-unified-theme-preview") {
                try render(root, to: "/tmp/omg-worktree-\(name).png")
            }
        }
    }

    @Test func historyHeaderSearchAndDenseRowsUseOneTheme() async throws {
        let strings = AgentHistoryStrings(language: .simplifiedChinese)
        let header = AgentHistorySessionListHeaderController()
        header.update(.init(title: "252 个会话", isRemote: false, isLoading: false, strings: strings, refresh: {}))
        let toolbar = AgentHistoryToolbarController()
        toolbar.update(.init(query: "", isSearching: false, filter: .init(), sessions: [], agents: [.codex, .pi],
                             strings: strings, currentDirectory: "/repo", searchChanged: { _ in }, filterChanged: { _ in }))
        let sessions = try ["覆盖安装 OMG Dev", "按功能提交代码，再预览原生界面的主题与交互，确认所有控件都保持统一风格",
                            "oh-my-ghostty", "检查 Agent History 的紧凑布局"].enumerated().map { index, title in
            AgentHistorySession(agent: index.isMultiple(of: 2) ? .pi : .codex,
                conversationID: try #require(AgentConversationID("theme-\(index)")),
                title: title, workingDirectory: "/Users/example/code/oh-my-ghostty", updatedAt: Date(),
                sourcePath: "/tmp/theme-\(index)", isActive: false)
        }
        let list = InspectorAgentHistoryListController()
        list.update(.init(rows: sessions.map { .session($0, snippet: nil) }, query: "", strings: strings,
                          select: { _ in }, toggleGroup: { _ in }, loadMore: {}, perform: { _ in }))
        let root = OMGNativeSurfaceView(frame: NSRect(x: 0, y: 0, width: 340, height: 430))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        for child in [header.view, toolbar.view, list.view] { root.addSubview(child) }
        header.view.frame = NSRect(x: 12, y: 390, width: 316, height: 28)
        toolbar.view.frame = NSRect(x: 12, y: 352, width: 316, height: 28)
        list.view.frame = NSRect(x: 0, y: 0, width: 340, height: 342)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(60))
        root.layoutSubtreeIfNeeded()
        list.viewDidLayout()
        try await Task.sleep(for: .milliseconds(30))
        let table = try #require((list.view as? NSScrollView)?.documentView as? NSTableView)
        #expect(table.rect(ofRow: 0).height < table.rect(ofRow: 1).height)
        for (name, theme) in palettes {
            root.applyTheme(theme)
            #expect(toolbar.searchFieldForTesting.frame.height == 28)
            #expect(header.refreshButtonForTesting.frame.maxX > 280)
            if FileManager.default.fileExists(atPath: "/tmp/omg-unified-theme-preview") {
                try render(root, to: "/tmp/omg-history-unified-\(name).png")
            }
        }
    }

    @Test func historyBranchPopoverGrowsOnlyWhenItHasEnoughRows() {
        let small = GitRefPopoverStyle.pickerSize(branchCount: 1, worktreeCount: 0, tagCount: 0)
        let many = GitRefPopoverStyle.pickerSize(branchCount: 30, worktreeCount: 0, tagCount: 0)
        #expect(small.height == 220)
        #expect(many.height == 520)
        #expect(small.width == many.width)
    }

    private var palettes: [(String, OMGNativeTheme)] {
        [("dark", .init(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                        foreground: NSColor(srgbRed: 0.8, green: 0.82, blue: 0.91, alpha: 1), accent: .systemBlue)),
         ("light", .init(background: NSColor(white: 0.96, alpha: 1),
                         foreground: NSColor(white: 0.15, alpha: 1), accent: .systemBlue))]
    }

    private func render(_ view: NSView, to path: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }
}
