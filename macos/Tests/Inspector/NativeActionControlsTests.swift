import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeActionControlsTests {
    @Test func windowDisplayUsesCustomDrawingForControlsAndRows() async throws {
        final class Probe: NativeActionControl {
            var drawCount = 0
            override func draw(_ dirtyRect: NSRect) { drawCount += 1; super.draw(dirtyRect) }
        }
        let root = OMGNativeSurfaceView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "OMG Native Control Review"
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let buttons = ["ellipsis", "arrow.up.arrow.down", "arrow.clockwise", "chevron.left"].enumerated().map { index, symbol in
            let button = Probe(frame: .init(x: 20 + index * 40, y: 240, width: 28, height: 28))
            button.configure(title: "", symbol: symbol, help: symbol, enabled: true, style: .plain, identifier: nil)
            root.addSubview(button)
            return button
        }
        for (index, title) in ["No Grouping", "By Project", "By Date"].enumerated() {
            let button = Probe(frame: .init(x: 20, y: 190 - index * 36, width: 360, height: 30))
            button.configure(title: title, symbol: index == 0 ? "checkmark" : nil, help: nil, enabled: true,
                             style: .plain, identifier: nil)
            button.alignment = .left
            root.addSubview(button)
        }
        for (index, title) in ["Cancel", "Save"].enumerated() {
            let button = Probe(frame: .init(x: 220 + index * 80, y: 20, width: 70, height: 28))
            button.configure(title: title, symbol: nil, help: nil, enabled: true,
                             style: index == 0 ? .bordered : .prominent, identifier: nil)
            root.addSubview(button)
        }
        root.applyTheme(.init(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                              foreground: NSColor(white: 0.85, alpha: 1), accent: .systemBlue))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(100))
        for button in buttons {
            #expect(!button.wantsUpdateLayer)
            button.needsDisplay = true
            button.displayIfNeeded()
            #expect(button.drawCount > 0, "Test the real AppKit display dispatch, not a direct draw() call.")
        }
        for row in [NativeHoverRowView(), GitCollectionRowView(), TerminalWorkspaceSelectionRow()] {
            #expect(!row.wantsUpdateLayer)
        }
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        func sampleBackground(of button: NSView) throws -> NSColor {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let rect = root.convert(button.bounds, from: button)
            let scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
            return try #require(bitmap.colorAt(x: Int((rect.minX + 4) * scale),
                                              y: Int((root.bounds.height - rect.midY) * scale)))
        }
        let probe = buttons[0]
        probe.setHovered(false)
        probe.displayIfNeeded()
        let idle = try sampleBackground(of: probe)
        probe.setHovered(true)
        probe.displayIfNeeded()
        #expect(try sampleBackground(of: probe) != idle)
        probe.setHovered(false)
        probe.displayIfNeeded()
        #expect(try sampleBackground(of: probe) == idle)
        #expect(probe.drawCount >= 3)
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/omg-native-dispatch-review.png"))
    }

    @Test func symbolsKeepTheirAspectRatioAndRepositoryLabelDoesNotHighlight() throws {
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
        button.showsHover = false
        button.setHovered(true)
        #expect(button.effectiveFill == .clear)
    }

    @Test func detachedControlsRejectStaleEnterEventsAndTablesHaveOnlyOneHoveredRow() {
        let button = NativeActionControl()
        button.setHovered(true)
        let other = NativeActionControl()
        other.setHovered(true)
        #expect(!button.isHovered && other.isHovered)
        button.setHovered(true)
        #expect(button.isHovered && !other.isHovered)
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
