import AppKit
import Testing
@testable import Ghostty

@MainActor
struct AgentHistoryNativeToolbarTests {
    @Test func transcriptFindShortcutOnlyHandlesItsFocusedContent() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let transcript = AgentHistoryTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let messages = NSTextView(frame: transcript.bounds)
        let otherInput = NSTextView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        transcript.documentView = messages
        content.addSubview(transcript)
        content.addSubview(otherInput)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.contentView = nil; window.close() }
        var requests = 0
        transcript.onFind = { requests += 1 }
        let findEvent = try key(3, modifiers: .command, characters: "f")
        #expect(window.makeFirstResponder(otherInput))
        #expect(!AgentHistoryFindShortcut.accepts(findEvent, in: transcript))
        #expect(window.makeFirstResponder(messages))
        #expect(transcript.performKeyEquivalent(with: findEvent))
        #expect(requests == 1)
        messages.setMarkedText("查", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!AgentHistoryFindShortcut.accepts(findEvent, in: transcript))
        messages.unmarkText()
        transcript.isHidden = true
        #expect(!AgentHistoryFindShortcut.accepts(findEvent, in: transcript))
    }

    @Test func searchFieldRetainsMarkedTextAndPublishesCommittedInput() throws {
        let controller = AgentHistoryToolbarController()
        var changed: [String] = []
        var snapshot = toolbarSnapshot(query: "", searchChanged: { changed.append($0) })
        controller.update(snapshot)
        let surface = try #require(controller.view as? OMGNativeSurfaceView)
        #expect(!surface.paintsBackground)
        surface.updateLayer()
        #expect(surface.layer?.backgroundColor?.alpha == 0)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        host.addSubview(controller.view)
        controller.view.frame = host.bounds
        controller.view.layoutSubtreeIfNeeded()
        let input = controller.searchFieldForTesting
        #expect(input.frame.width > 80)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(input))
        let editor = try #require(input.currentEditor() as? NSTextView)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        snapshot = toolbarSnapshot(query: "external", searchChanged: { changed.append($0) })
        controller.update(snapshot)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "拼")
        editor.unmarkText()
        input.stringValue = "project"
        controller.controlTextDidChange(Notification(name: NSText.didChangeNotification, object: input))
        #expect(changed.last == "project")
    }

    @Test func filterContentFitsWithoutRedundantDirectorySubtitle() throws {
        let controller = AgentHistoryFilterController()
        var filter = AgentHistoryFilterState()
        filter.directory = .currentTree
        let sessions = [session("one", path: "/repo/sub")]
        controller.update(sessions: sessions, agents: [.claude], filter: filter,
                          strings: .init(language: .english), currentDirectory: "/repo")
        controller.view.frame = NSRect(origin: .zero, size: controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.preferredContentSize.width == 320)
        #expect(controller.preferredContentSize.height >= controller.view.fittingSize.height)
        #expect(controller.directoryHintForTesting.stringValue == "repo")
        #expect(controller.directoryHintForTesting.isHidden == true)
        for control in controller.filterControlsForTesting.values {
            #expect(control.frame.width > 0)
            #expect(control.frame.minX >= 0)
            #expect(control.frame.maxX <= controller.view.bounds.maxX)
        }
    }

    @Test func sessionHeaderKeepsCountAndRoutesRefreshAtInspectorWidth() throws {
        let controller = AgentHistorySessionListHeaderController()
        var refreshCount = 0
        controller.update(AgentHistorySessionListHeader(
            title: "cloud: 12 sessions",
            isRemote: true,
            isLoading: false,
            strings: .init(language: .english),
            refresh: { refreshCount += 1 }
        ))
        controller.view.frame = NSRect(x: 0, y: 0, width: 220, height: 40)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.titleFieldForTesting.stringValue == "cloud: 12 sessions")
        #expect(controller.titleFieldForTesting.frame.width > 0)
        #expect(controller.refreshButtonForTesting.frame.width == 28)
        controller.refreshButtonForTesting.performClick(nil)
        #expect(refreshCount == 1)
    }

    @Test func filterPopoverClosesAndRestoresPriorResponder() async throws {
        let controller = AgentHistoryToolbarController()
        controller.update(toolbarSnapshot())
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let prior = NSButton(title: "Prior", target: nil, action: nil)
        prior.frame = NSRect(x: 0, y: 40, width: 100, height: 24)
        content.addSubview(prior)
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 32)
        content.addSubview(controller.view)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(prior))
        controller.togglePopover()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.popoverForTesting.isShown)
        controller.popoverForTesting.performClose(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.firstResponder === prior)
    }

    @Test func transcriptSearchPreservesMarkedTextAndRoutesEscapeAndCommandF() throws {
        let field = AgentHistoryTranscriptSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let window = NSWindow(contentRect: field.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(field))
        var escapes = 0
        var finds = 0
        field.onEscape = { escapes += 1 }
        field.onFind = { finds += 1 }
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        field.keyDown(with: try key(53, modifiers: []))
        #expect(escapes == 0)
        editor.unmarkText()
        field.keyDown(with: try key(53, modifiers: []))
        #expect(escapes == 1)
        #expect(field.performKeyEquivalent(with: try key(3, modifiers: .command, characters: "f")))
        #expect(finds == 1)
    }

    @Test func transcriptToolbarOwnsFocusAndRoutesNativeButtons() async throws {
        let controller = AgentHistoryTranscriptToolbarController()
        let session = session("toolbar", path: "/repo")
        var backCount = 0
        var resumeCount = 0
        var toggleCount = 0
        var escapeCount = 0
        var latestQuery = ""
        let prior = NSButton(title: "Prior", target: nil, action: nil)
        prior.frame = NSRect(x: 0, y: 130, width: 80, height: 24)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
        content.addSubview(prior)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 112)
        content.addSubview(controller.view)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(prior))

        func update(visible: Bool, requestID: Int) {
            controller.update(AgentHistoryTranscriptToolbar(
                session: session, strings: .init(language: .english), query: latestQuery,
                isSearchVisible: visible, focusRequestID: requestID, matchCount: 0,
                onQueryChange: { latestQuery = $0 }, onToggleSearch: { toggleCount += 1 },
                onEscape: { escapeCount += 1 }, onBack: { backCount += 1 }, onResume: { resumeCount += 1 }
            ))
            controller.view.layoutSubtreeIfNeeded()
        }

        update(visible: false, requestID: 0)
        update(visible: true, requestID: 1)
        try await Task.sleep(for: .milliseconds(30))
        let editor = try #require(controller.searchFieldForTesting.currentEditor() as? NSTextView)
        #expect(window.firstResponder === editor)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!controller.control(controller.searchFieldForTesting, textView: editor,
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(escapeCount == 0)
        editor.unmarkText()
        #expect(controller.control(controller.searchFieldForTesting, textView: editor,
                                   doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(escapeCount == 1)
        #expect(controller.control(controller.searchFieldForTesting, textView: editor,
                                   doCommandBy: #selector(NSTextView.performFindPanelAction(_:))))
        #expect(toggleCount == 1)
        controller.backButtonForTesting.performClick(nil)
        controller.resumeButtonForTesting.performClick(nil)
        controller.findButtonForTesting.performClick(nil)
        controller.searchFieldForTesting.stringValue = "needle"
        controller.controlTextDidChange(Notification(name: NSText.didChangeNotification,
                                                      object: controller.searchFieldForTesting))
        #expect(backCount == 1)
        #expect(resumeCount == 1)
        #expect(toggleCount == 2)
        #expect(latestQuery == "needle")

        update(visible: false, requestID: 1)
        #expect(window.firstResponder === prior)
    }

    private func toolbarSnapshot(
        query: String = "",
        searchChanged: @escaping (String) -> Void = { _ in }
    ) -> AgentHistoryToolbar {
        AgentHistoryToolbar(query: query, isSearching: true, filter: .init(), sessions: [], agents: [],
                            strings: .init(language: .english), currentDirectory: nil,
                            searchChanged: searchChanged, filterChanged: { _ in })
    }

    private func session(_ id: String, path: String) -> AgentHistorySession {
        AgentHistorySession(agent: .claude, conversationID: AgentConversationID(id)!, title: id,
                            workingDirectory: path, updatedAt: Date(), sourcePath: "/tmp/\(id).jsonl",
                            isActive: false)
    }

    private func key(
        _ code: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String = ""
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
