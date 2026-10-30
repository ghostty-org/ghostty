import AppKit
import Testing
@testable import Ghostty

@MainActor
struct QuickInputHistoryNativeTests {
    @Test func filteringRetainsInputClientAndReconcilesNativeRows() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let entries = (0..<100).map {
            QuickInputHistoryEntry(id: UUID(), paneID: pane, tabID: pane,
                                   text: "entry \($0)", sentAt: Date())
        }
        let presentation = model.historyPresentation
        let controller = QuickInputHistoryController()
        func update(_ entries: [QuickInputHistoryEntry]) {
            presentation.reconcile(entries: entries)
            controller.update(QuickInputHistoryNativeView(model: model, store: store, settings: settings,
                                                         presentation: presentation, entries: entries, onSelect: { _ in }))
            controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            controller.view.layoutSubtreeIfNeeded()
        }
        update(entries)
        let table = try #require(find(NSTableView.self, in: controller.view))
        let input = try #require(find(QuickInputHistorySearchTextView.self, in: controller.view))
        #expect(table.numberOfRows == 100)
        #expect(!table.acceptsFirstResponder)
        presentation.moveSelection(by: 40, entries: entries)
        update(entries)
        #expect(table.selectedRow == 40)
        let filtered = Array(entries[35..<50])
        update(filtered)
        #expect(table.numberOfRows == 15)
        #expect(table.selectedRow == 5)
        #expect(find(QuickInputHistorySearchTextView.self, in: controller.view) === input)
        update([])
        #expect(table.numberOfRows == 0)
        #expect(table.selectedRow == -1)
        update(entries)
        #expect(table.numberOfRows == 100)
        #expect(table.selectedRow == 0)
    }

    @Test func hoveringSelectionDoesNotScrollOrReplaceMarkedText() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let entries = (0..<100).map {
            QuickInputHistoryEntry(id: UUID(), paneID: pane, tabID: pane,
                                   text: "entry \($0)", sentAt: Date())
        }
        let presentation = model.historyPresentation
        presentation.open(entries: entries)
        let controller = QuickInputHistoryController()
        let snapshot = QuickInputHistoryNativeView(model: model, store: store, settings: settings,
                                                   presentation: presentation, entries: entries, onSelect: { _ in })
        controller.update(snapshot)
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        let table = try #require(find(NSTableView.self, in: controller.view))
        let input = try #require(find(QuickInputHistorySearchTextView.self, in: controller.view))
        let origin = table.enclosingScrollView?.contentView.bounds.origin
        input.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        presentation.hover(entries[90].id)
        controller.update(snapshot)
        #expect(table.selectedRow == 90)
        #expect(table.enclosingScrollView?.contentView.bounds.origin == origin)
        #expect(input.hasMarkedText())
        #expect(input.string == "拼")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
