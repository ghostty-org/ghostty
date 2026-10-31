import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeHoverRoutingTests {
    private final class Window: NSWindow {
        var testPointer = NSPoint.zero
        override var isKeyWindow: Bool { true }
        override var isVisible: Bool { true }
        override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
    }

    private final class Row: NativeHoverRowView {
        let close = NativeActionControl(frame: .init(x: 250, y: 5, width: 28, height: 24))

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            close.configure(title: "", symbol: "xmark", help: "Close", enabled: true,
                            style: .plain, identifier: nil)
            close.isHidden = true
            addSubview(close)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hoverStateDidChange(_ hovered: Bool) {
            close.isHidden = !hovered
        }
    }

    private final class Table: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
        private lazy var hover = NativeTableHover(table: self)
        var rows: [Row] = []

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            hover.update()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { 10 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = Row()
            rows.append(view)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTextField(labelWithString: "Row \(row)")
        }
    }

    private func tableFixture() throws -> (Window, Table) {
        let table = Table(frame: .init(x: 0, y: 0, width: 300, height: 160))
        let column = NSTableColumn(identifier: .init("label"))
        column.width = 300
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = table
        table.delegate = table

        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 300, height: 160))
        scroll.hasVerticalScroller = false
        scroll.documentView = table
        let window = Window(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        for row in 0..<4 { _ = table.rowView(atRow: row, makeIfNecessary: true) }
        table.updateTrackingAreas()
        return (window, table)
    }

    private func event(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow,
        index: Int
    ) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, trackingNumber: 0, userData: nil))
        }
        return try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: index, clickCount: 0, pressure: 0
        ))
    }

    @Test func activeTableTrackingOwnerRespondsToAppKitMouseSelectors() throws {
        let (window, table) = try tableFixture()
        defer { window.contentView = nil; window.close() }
        let tracking = try #require(table.trackingAreas.first { $0.owner is NativeTableHover })
        let owner = try #require(tracking.owner as? NativeTableHover)
        let selectors = ["mouseEntered:", "mouseMoved:", "mouseExited:"].map(NSSelectorFromString)
        let missing = selectors.filter { !owner.responds(to: $0) }
        #expect(missing.isEmpty, "Tracking owner is missing AppKit selectors: \(missing)")
    }

    /// Exercises Objective-C target/action dispatch for the owner stored in
    /// NSTrackingArea. It does not emulate WindowServer pointer/exit delivery.
    @Test func trackingOwnerDispatchMovesUniqueHoverAndCloseWithTheRow() throws {
        let (window, table) = try tableFixture()
        defer { window.contentView = nil; window.close() }
        let tracking = try #require(table.trackingAreas.first { $0.owner is NativeTableHover })
        let owner = try #require(tracking.owner as? NativeTableHover)
        let selector = #selector(NSResponder.mouseMoved(with:))
        try #require(owner.responds(to: selector))
        let entered = #selector(NSResponder.mouseEntered(with:))
        let exited = #selector(NSResponder.mouseExited(with:))
        let first = try #require(table.rowView(atRow: 0, makeIfNecessary: false) as? Row)
        let second = try #require(table.rowView(atRow: 1, makeIfNecessary: false) as? Row)

        let firstCloseCenter = first.close.convert(.init(x: first.close.bounds.midX, y: first.close.bounds.midY), to: nil)
        #expect(NSApp.sendAction(entered, to: owner,
                                 from: try event(.mouseEntered, at: firstCloseCenter, window: window, index: 1)))
        #expect(first.isHovered && !first.close.isHidden)
        #expect(!second.isHovered && second.close.isHidden)

        let secondBodyCenter = second.convert(NSPoint(x: 90, y: second.bounds.midY), to: nil)
        #expect(NSApp.sendAction(selector, to: owner,
                                 from: try event(.mouseMoved, at: secondBodyCenter, window: window, index: 2)))
        #expect(second.isHovered && !first.isHovered)
        #expect(first.close.isHidden && !second.close.isHidden)

        let secondCloseCenter = second.close.convert(.init(x: second.close.bounds.midX, y: second.close.bounds.midY), to: nil)
        #expect(NSApp.sendAction(selector, to: owner,
                                 from: try event(.mouseMoved, at: secondCloseCenter, window: window, index: 3)))
        #expect(second.isHovered && !second.close.isHidden)
        #expect(!first.isHovered && first.close.isHidden)

        let outside = NSPoint(x: window.contentView!.bounds.maxX + 20,
                              y: window.contentView!.bounds.maxY + 20)
        #expect(NSApp.sendAction(exited, to: owner, from: try event(.mouseExited, at: outside, window: window, index: 4)))
        #expect(!first.isHovered && !second.isHovered)
        #expect(first.close.isHidden && second.close.isHidden)
        #expect(table.selectedRow == -1)
    }

    @Test func stationaryPointerReconcilesHoverAfterClipViewScroll() async throws {
        let (window, table) = try tableFixture()
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(table.enclosingScrollView)
        let clip = scroll.contentView
        let original = try #require(table.rowView(atRow: 2, makeIfNecessary: true))
        let center = original.convert(.init(x: 100, y: original.bounds.midY), to: nil)
        window.testPointer = center
        let tracking = try #require(table.trackingAreas.first { $0.owner is NativeTableHover })
        let owner = try #require(tracking.owner as? NativeTableHover)
        let enter = try event(.mouseEntered, at: center, window: window, index: 1)
        #expect(NSApp.sendAction(#selector(NSResponder.mouseEntered(with:)), to: owner, from: enter))
        let originalRow = table.row(at: table.convert(center, from: nil))
        let hoveredBeforeScroll = try #require(table.rowView(atRow: originalRow, makeIfNecessary: true) as? Row)
        #expect(hoveredBeforeScroll.isHovered)

        var clipNotifications = 0
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { _ in MainActor.assumeIsolated { clipNotifications += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        clip.scroll(to: .init(x: 0, y: CGFloat(table.rowHeight) * 4))
        scroll.reflectScrolledClipView(clip)
        for _ in 0..<20 where clipNotifications == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(clipNotifications > 0)
        let stationaryRow = table.row(at: table.convert(center, from: nil))
        #expect(stationaryRow >= 0 && stationaryRow != originalRow)
        for _ in 0..<20 {
            if table.rowView(atRow: stationaryRow, makeIfNecessary: false) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let newlyHovered = try #require(table.rowView(atRow: stationaryRow, makeIfNecessary: true) as? Row)
        for _ in 0..<20 where !newlyHovered.isHovered {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(newlyHovered.isHovered, "A bounds notification must reconcile hover at the stationary window pointer.")
        var hoveredRows: [Int] = []
        table.enumerateAvailableRowViews { row, rowIndex in
            if (row as? NativeHoverRowView)?.isHovered == true { hoveredRows.append(rowIndex) }
        }
        #expect(hoveredRows == [stationaryRow])
        #expect(!newlyHovered.close.isHidden)
        #expect(table.selectedRow == -1)
        let exit = try event(.mouseExited, at: center, window: window, index: 2)
        #expect(NSApp.sendAction(#selector(NSResponder.mouseExited(with:)), to: owner, from: exit))
        clip.scroll(to: .zero)
        try await Task.sleep(for: .milliseconds(20))
        table.enumerateAvailableRowViews { row, _ in
            #expect((row as? NativeHoverRowView)?.isHovered == false)
        }
    }
}
