import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeActionControlsTests {
    @Test func hoverUsesDeliveredCoordinatesAndRecoversWithoutAnotherEnter() throws {
        // Model key-window eligibility without taking focus from the desktop.
        final class Window: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isVisible: Bool { true }
        }
        let window = Window(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let button = NativeActionControl(frame: .init(x: 20, y: 20, width: 80, height: 28))
        root.addSubview(button)
        button.updateTrackingAreas()
        #expect(button.trackingAreas.contains { $0.options.contains(.mouseMoved) })
        func event(at point: NSPoint, number: Int? = nil) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number ?? window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let inside = try event(at: button.convert(.init(x: 10, y: 10), to: nil))
        button.mouseMoved(with: inside)
        #expect(button.isHovered)
        button.setHovered(false)
        button.mouseMoved(with: inside)
        #expect(button.isHovered, "Movement must recover hover after reuse or activation, without a new enter event.")
        button.mouseMoved(with: try event(at: .init(x: 200, y: 150)))
        #expect(!button.isHovered)
        button.mouseMoved(with: try event(at: inside.locationInWindow, number: 0))
        #expect(!button.isHovered)
        button.isHidden = true
        button.mouseMoved(with: inside)
        #expect(!button.isHovered)
        button.isHidden = false
        button.removeFromSuperview()
        button.mouseMoved(with: inside)
        #expect(!button.isHovered)
    }

    @Test func firstPointerMovementHighlightsNativeRowsWithoutScrollingOrClicking() throws {
        final class Window: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isVisible: Bool { true }
        }
        let controller = InspectorFileTreeController()
        let nodes = (0..<20).map {
            InspectorFileNode(id: "/repo/\($0)", name: "file-\($0)", isDirectory: false,
                icon: .init(systemImage: "doc", tint: .secondary), isExpanded: false, isLoading: false, children: nil)
        }
        controller.update(.init(rootName: "repo", rootPath: "/repo", nodes: nodes), isLight: false, perform: { _ in })
        let window = Window(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.contentView = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        outline.updateTrackingAreas()
        let hover = try #require(outline.trackingAreas.compactMap { $0.owner as? NativeTableHover }.first)
        for index in [0, 1, 2, 0] {
            let rect = outline.rect(ofRow: index)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: outline.convert(.init(x: rect.midX, y: rect.midY), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 0, pressure: 0))
            hover.mouseMoved(with: event)
            let row = try #require(outline.rowView(atRow: index, makeIfNecessary: false) as? NativeHoverRowView)
            #expect(row.isHovered)
            outline.enumerateAvailableRowViews { row, rowIndex in
                #expect((row as? NativeHoverRowView)?.isHovered == (rowIndex == index))
            }
        }
        #expect(outline.selectedRow == -1)
    }

    @Test func unchangedConfigurationPreservesImageAndTrackingIdentity() throws {
        let button = NativeActionControl(frame: .init(x: 0, y: 0, width: 28, height: 28))
        func configure() {
            button.configure(title: "", symbol: "terminal", help: "Terminal", enabled: true, style: .plain, identifier: nil)
            button.updateTrackingAreas()
        }
        configure()
        let image = try #require(button.image)
        let tracking = button.trackingAreas
        for _ in 0..<100 { configure() }
        #expect(button.image === image)
        #expect(button.trackingAreas == tracking)
        button.configure(title: "Stop", symbol: "stop.fill", help: nil, enabled: false, style: .bordered, identifier: nil)
        #expect(button.image !== image)
        #expect(button.title == "Stop" && !button.isEnabled)
        button.configure(title: "Text", symbol: nil, help: nil, enabled: true, style: .plain, identifier: nil)
        #expect(button.image == nil)
    }

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
