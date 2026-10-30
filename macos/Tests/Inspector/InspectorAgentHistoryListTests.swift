import AppKit
import Testing
@testable import Ghostty

@MainActor
struct InspectorAgentHistoryListTests {
    @Test func vectorAgentLogosFillTheirNativeSlotsInBothAppearances() throws {
        let agents: [SupportedAgent] = [.codex, .pi, .claude]
        let sessions = try agents.enumerated().map { index, agent in
            AgentHistorySession(agent: agent,
                conversationID: try #require(AgentConversationID("logo-\(index)")),
                title: "\(agent.displayName) session", workingDirectory: "/project",
                updatedAt: Date(), sourcePath: "/tmp/logo-\(index).jsonl", isActive: false)
        }
        let originals = try agents.map { try #require(NSImage(named: $0.assetName)).size }
        let controller = InspectorAgentHistoryListController()
        controller.update(InspectorAgentHistoryList(
            rows: sessions.map { .session($0, snippet: nil) }, query: "",
            strings: .init(language: .english), select: { _ in }, toggleGroup: { _ in },
            loadMore: {}, perform: { _ in }
        ))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 340, height: 280))
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: 280)
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        let scroll = try #require(controller.view as? NSScrollView)
        let table = try #require(scroll.documentView as? NSTableView)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            scroll.drawsBackground = true
            scroll.backgroundColor = .windowBackgroundColor
            controller.view.layoutSubtreeIfNeeded()
            for row in sessions.indices {
                let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let imageView = try #require(cell.subviews.compactMap { $0 as? NSImageView }.first)
                #expect(try paintedPixels(in: imageView) > 100,
                        "A down-only 1-point logo paints only a few pixels in the 40-pixel backing.")
                #expect(imageView.imageScaling == .scaleProportionallyUpOrDown)
                #expect(imageView.image?.size == originals[row], "Do not resize shared catalog image objects.")
            }
            if FileManager.default.fileExists(atPath: "/tmp/omg-native-visual-review") {
                window.displayIfNeeded()
                let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.effectiveAppearance.performAsCurrentDrawingAppearance {
                    scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                }
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: "/tmp/omg-agent-history-logos-\(name).png")
                )
            }
        }
    }

    private func paintedPixels(in view: NSImageView) throws -> Int {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cell?.draw(withFrame: view.bounds, in: view)
        }
        return (0..<40).reduce(0) { count, y in
            count + (0..<40).count { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
    }

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
