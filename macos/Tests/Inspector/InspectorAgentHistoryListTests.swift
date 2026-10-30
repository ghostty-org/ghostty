import AppKit
import Testing
@testable import Ghostty

@MainActor
struct InspectorAgentHistoryListTests {
    @Test func menuKeepsTheContextThatWasPresentedWhenOpened() throws {
        let controller = InspectorAgentHistoryListController()
        let entry = try session(1)
        var original: [InspectorPaneActionKind] = []
        var replacement: [InspectorPaneActionKind] = []
        func update(_ perform: @escaping (InspectorPaneActionKind) -> Void) {
            controller.update(InspectorAgentHistoryList(
                rows: [.session(entry, snippet: nil)], query: "", strings: .init(language: .english),
                select: { _ in }, toggleGroup: { _ in }, loadMore: {}, perform: perform
            ))
        }
        update { original.append($0) }
        let menu = try #require(controller.menu(for: 0))
        let resume = try #require(menu.items.first)
        update { replacement.append($0) }
        #expect(NSApp.sendAction(try #require(resume.action), to: resume.target, from: resume))
        #expect(original == [.resumeAgentHistorySession(id: entry.id)])
        #expect(replacement.isEmpty)
    }

    @Test func groupedInsertAndFilterPreserveSelectedSessionAndViewportAnchor() throws {
        let controller = InspectorAgentHistoryListController()
        let sessions = try (0..<100).map { try session($0) }
        func update(_ rows: [InspectorAgentHistoryListRow]) {
            controller.update(InspectorAgentHistoryList(rows: rows, query: "", strings: .init(language: .english),
                                                       select: { _ in }, toggleGroup: { _ in },
                                                       loadMore: {}, perform: { _ in }))
            controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
            controller.view.layoutSubtreeIfNeeded()
        }
        update(sessions.map { .session($0, snippet: nil) })
        let scroll = try #require(controller.view as? NSScrollView)
        let table = try #require(scroll.documentView as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
        let top = table.rect(ofRow: 38).minY + 4
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        let visibleID = sessions[38].id
        let grouped: [InspectorAgentHistoryListRow] = [
            .group(id: "project", title: "Project", count: 100, collapsed: false),
        ] + sessions.map { .session($0, snippet: nil) }
        update(grouped)
        #expect(table.numberOfRows == 101)
        #expect(table.selectedRow == 41)
        let visibleRow = table.row(at: NSPoint(x: 1, y: scroll.contentView.bounds.minY))
        #expect(grouped[visibleRow].id == "session:" + visibleID)
        #expect(abs(scroll.contentView.bounds.minY - table.rect(ofRow: visibleRow).minY - 4) < 1)
        update(Array(grouped[35..<60]))
        #expect(table.selectedRow == 6)
        update([.group(id: "project", title: "Project", count: 100, collapsed: true)])
        #expect(table.numberOfRows == 1)
        #expect(table.selectedRow == -1)
    }

    @Test func returnAndDisclosureRouteToCurrentRowWithoutActivatingOnSelection() throws {
        let controller = InspectorAgentHistoryListController()
        let entry = try session(1)
        var selected: [String] = []
        var toggled: [String] = []
        var loaded = 0
        controller.update(InspectorAgentHistoryList(
            rows: [.group(id: "project", title: "Project", count: 1, collapsed: true),
                   .session(entry, snippet: nil), .more(remaining: 60)],
            query: "", strings: .init(language: .english), select: { selected.append($0.id) },
            toggleGroup: { toggled.append($0) }, loadMore: { loaded += 1 }, perform: { _ in }
        ))
        let table = try #require((controller.view as? NSScrollView)?.documentView as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(toggled.isEmpty && selected.isEmpty)
        table.keyDown(with: try key(124))
        #expect(toggled == ["project"])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: try key(36))
        #expect(selected == [entry.id])
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        table.keyDown(with: try key(36))
        #expect(loaded == 1)
    }

    private func session(_ index: Int) throws -> AgentHistorySession {
        .init(agent: .claude, conversationID: try #require(AgentConversationID("session-\(index)")),
              title: "Session \(index)", workingDirectory: "/tmp/project", updatedAt: Date(),
              sourcePath: "/tmp/\(index).jsonl", isActive: false)
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }
}
