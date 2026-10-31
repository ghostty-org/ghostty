import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeRowHoverRenderingTests {
    private final class Row: NativeHoverRowView {}

    private final class DataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 10 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { Row() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            NSTextField(labelWithString: "Row \(row)")
        }
    }

    @Test func changingHoveredRowRepaintsBothBackgroundsThroughWindowDisplay() async throws {
        let data = DataSource()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("label")))
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = data
        table.delegate = data
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 300, height: 300))
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(80))
        let first = try #require(table.rowView(atRow: 0, makeIfNecessary: true) as? Row)
        let second = try #require(table.rowView(atRow: 1, makeIfNecessary: true) as? Row)
        func pixel(_ row: NSView) throws -> NSColor {
            let width = Int(row.bounds.width), height = Int(row.bounds.height)
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            try #require(row.layer).render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            return try #require(bitmap.colorAt(x: width - 8, y: height / 2))
        }
        let idle = try pixel(first)
        let hover = NativeTableHover(table: table)
        hover.setRow(first)
        window.displayIfNeeded()
        #expect(try pixel(first) != idle)
        hover.setRow(second)
        window.displayIfNeeded()
        #expect(try pixel(first) == idle)
        #expect(try pixel(second) != idle)
        #expect(!first.isHovered && second.isHovered)
        second.isSelected = true
        #expect(try pixel(second) == idle)
        #expect(second.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
        let layer = try #require(first.layer?.sublayers?.first { $0.name == "omg.row.hover" } as? CAShapeLayer)
        let path = try #require(layer.path)
        for _ in 0..<100 {
            first.isHovered.toggle()
            first.layout()
        }
        #expect(layer.path === path, "Hover and unchanged layout must reuse the existing shape.")
    }
}
