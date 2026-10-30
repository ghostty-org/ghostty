import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeActionControlsTests {
    @Test func symbolsKeepTheirAspectRatioAndHoverPixelsAreErased() throws {
        let button = NativeActionControl(frame: .init(x: 0, y: 0, width: 28, height: 28))
        for symbol in ["ellipsis", "arrow.up.arrow.down", "arrow.clockwise", "stop.fill"] {
            button.configure(title: "", symbol: symbol, help: nil, enabled: true, style: .plain, identifier: nil)
            let image = try #require(button.image)
            #expect(abs(button.glyphRect.width / button.glyphRect.height - image.size.width / image.size.height) < 0.001)
            #expect(button.glyphRect.midX == button.bounds.midX)
            #expect(button.glyphRect.midY == button.bounds.midY)
        }
        button.image = nil
        button.applyTheme(.init(background: .black, foreground: .white))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        button.setHovered(true)
        button.draw(button.bounds)
        #expect((bitmap.colorAt(x: 14, y: 14)?.alphaComponent ?? 0) > 0)
        button.setHovered(false)
        button.draw(button.bounds)
        #expect(bitmap.colorAt(x: 14, y: 14)?.alphaComponent == 0)
        button.showsHover = false
        button.setHovered(true)
        #expect(button.effectiveFill == .clear)
    }

    @Test func detachedControlsRejectStaleEnterEventsAndTablesHaveOnlyOneHoveredRow() {
        let button = NativeActionControl()
        button.setHovered(true)
        button.mouseEntered(with: NSEvent())
        #expect(!button.isHovered)
        let table = NSTableView()
        let hover = NativeTableHover(table: table)
        let first = NativeHoverRowView()
        let second = NativeHoverRowView()
        hover.setRow(first)
        #expect(first.isHovered && !second.isHovered)
        hover.setRow(second)
        #expect(!first.isHovered && second.isHovered)
        hover.setRow(nil)
        #expect(!first.isHovered && !second.isHovered)
        #expect(table.selectedRow == -1)
    }

    @Test func menusKeepTheOriginalActionAndDoNotReenableUnavailableItems() throws {
        var events: [String] = []
        var entries: [NativeMenuEntry] = [
            .action("Unavailable", enabled: false) { events.append("disabled") },
            .action("Original", checked: true) { events.append("original") },
            .submenu("Options", entries: [.action("Nested") { events.append("nested") }])
        ]
        let menu = NativeActionMenu.make(entries)
        entries = [.action("Replacement") { events.append("replacement") }]
        _ = NativeActionMenu.make(entries)
        menu.update()
        #expect(!menu.autoenablesItems)
        let unavailable = try #require(menu.item(at: 0))
        #expect(!unavailable.isEnabled)
        NSApp.sendAction(try #require(unavailable.action), to: unavailable.target, from: unavailable)
        #expect(events.isEmpty)
        let original = try #require(menu.item(at: 1))
        #expect(original.state == .on)
        NSApp.sendAction(try #require(original.action), to: original.target, from: original)
        let nested = try #require(menu.item(at: 2)?.submenu?.item(at: 0))
        NSApp.sendAction(try #require(nested.action), to: nested.target, from: nested)
        #expect(events == ["original", "nested"])
    }

    @Test func nativeButtonHasExplicitTargetAndDisabledActionsAreIgnored() throws {
        let button = NativeActionControl()
        button.configure(title: "Action", symbol: "plus", help: "Create",
                         enabled: true, style: .bordered, identifier: "test.action")
        var presses = 0
        button.onPress = { presses += 1 }
        #expect(button.target === button)
        NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(presses == 1)
        button.isEnabled = false
        NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(presses == 1)
        #expect(button.keyEquivalent.isEmpty)
    }
}
