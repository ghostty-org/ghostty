import Testing
import AppKit
import SwiftUI
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct RoundedTerminalTabModelTests {
    private func window(_ title: String) -> TerminalWindow {
        let window = TerminalWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    @Test func snapshotsUseNativeGroupOrderAndSelection() {
        let first = window("First")
        let second = window("Second")
        defer { second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = second
        let model = RoundedTerminalTabModel(hostWindow: first)
        model.refresh()
        #expect(model.tabs.map(\.title) == first.tabGroup?.windows.map(\.title))
        #expect(model.tabs.first(where: \.selected)?.window.value === second)
        second.title = "Renamed"
        model.refresh()
        #expect(model.tabs.contains(where: { $0.title == "Renamed" }))
    }

    @Test func reorderRejectsUnrelatedDragPayloads() {
        let first = window("First")
        defer { first.close() }
        let model = RoundedTerminalTabModel(hostWindow: first)
        model.refresh()
        guard let tab = model.tabs.first else { Issue.record("Missing native window tab"); return }
        #expect(!model.reorder(["unrelated text"], before: tab))
        #expect(!model.reorder([], before: tab))
    }

    @Test func nativeReorderingAndDetachingUpdateSnapshot() {
        let first = window("First")
        let second = window("Second")
        let third = window("Third")
        defer { third.close(); second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        second.addTabbedWindow(third, ordered: .above)
        let model = RoundedTerminalTabModel(hostWindow: first)
        model.refresh()
        guard let last = model.tabs.last else { Issue.record("Missing tabs"); return }
        model.move(last, by: -1)
        model.refresh()
        #expect(model.tabs.map(\.title) == first.tabGroup?.windows.map(\.title))
        #expect(model.tabs[1].id == last.id)
        first.tabGroup?.removeWindow(third)
        model.refresh()
        #expect(!model.tabs.contains(where: { $0.window.value === third }))
    }

    @Test func emptyTitleHasReadableFallback() {
        let first = window("")
        defer { first.close() }
        let model = RoundedTerminalTabModel(hostWindow: first)
        model.refresh()
        #expect(model.tabs.first?.title == "Terminal")
    }

    @Test func renderTabStripFixture() async throws {
        let first = window("Terminal")
        let second = window("Build")
        defer { second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = second
        let bar = RoundedTerminalTabBar(hostWindow: first, store: TabBarSettingsStore(defaults: nil))
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(srgbRed: 0.18, green: 0.19, blue: 0.23, alpha: 1).cgColor
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: 36)
        first.contentView = bar
        first.setContentSize(NSSize(width: 900, height: 36))
        bar.refresh()
        bar.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        guard let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else {
            Issue.record("Could not allocate tab strip fixture bitmap")
            return
        }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GhosttyX-TabStrip.png")
        try data.write(to: output)
        print("Ghostty X synthetic tab fixture: \(output.path)")
        #expect(bitmap.pixelsWide >= 900)
        #expect(modelIsSelected(bar: bar, window: second))
    }

    @Test func titlebarTabsReceiveMouseClicks() async throws {
        let first = window("First")
        let second = window("Second")
        defer { second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        let bar = RoundedTerminalTabBar(hostWindow: first, store: TabBarSettingsStore(defaults: nil))
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: 36)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        first.addTitlebarAccessoryViewController(accessory)
        // Titlebar accessories acquire their final coordinate space only after
        // AppKit orders the offscreen fixture window; no personal windows are used.
        first.orderFront(nil)
        first.makeKey()
        first.displayIfNeeded()
        bar.refresh()
        bar.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        // AppKit's titlebar hit testing may turn an entire draggable hosting view
        // into window movement instead of delivering the event to its controls.
        #expect(!bar.mouseDownCanMoveWindow)
        let secondFrame = try #require(bar.tabFrame(at: 1))
        let location = NSPoint(x: secondFrame.midX, y: secondFrame.midY)
        let hit = try #require(bar.hitTest(location))
        #expect(hit === bar || hit.isDescendant(of: bar))
        let point = bar.convert(location, to: nil)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: 1, windowNumber: first.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0.9, windowNumber: first.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.postEvent(up, atStart: true)
        first.sendEvent(down)
        try await waitForSelection(of: second, in: first)
        #expect(first.tabGroup?.selectedWindow === second)
    }

    @Test func newTabRemainsClickableAboveSplitContent() async throws {
        let first = window("Split tab")
        let second = window("Second")
        let added = window("New tab")
        defer { added.close(); second.close(); first.close() }
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        first.contentView = split
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        let bar = RoundedTerminalTabBar(hostWindow: first, store: TabBarSettingsStore(defaults: nil))
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: 36)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        first.addTitlebarAccessoryViewController(accessory)
        first.orderFront(nil)
        first.makeKey()
        bar.refresh()
        // Add a tab after the native controls have already mounted. Published
        // snapshots must position its new button before the next click.
        second.addTabbedWindow(added, ordered: .above)
        first.tabGroup?.selectedWindow = first
        bar.refresh()
        first.setContentSize(NSSize(width: 680, height: 400))
        first.displayIfNeeded()
        bar.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let addedFrame = try #require(bar.tabFrame(at: 2))
        let local = NSPoint(x: addedFrame.midX, y: addedFrame.midY)
        let hit = try #require(bar.hitTest(local))
        #expect(hit is NSButton)
        let point = bar.convert(local, to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: first.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        first.sendEvent(down)
        try await waitForSelection(of: added, in: first)
        #expect(first.tabGroup?.selectedWindow === added)
    }

    /// Renders the strip in every position and style for visual review. Set
    /// GHOSTTYX_FIXTURE_DIR (TEST_RUNNER_ prefix via xcodebuild) to keep the PNGs.
    @Test func renderEveryPositionAndStyle() throws {
        let dir = ProcessInfo.processInfo.environment["GHOSTTYX_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let theme = RoundedTabTheme.fallback
        for position in TabBarSettings.Position.allCases {
            for style in TabBarSettings.Style.allCases {
                let store = TabBarSettingsStore(defaults: nil)
                store.settings.position = position
                store.settings.style = style
                let model = PreviewTabModel()
                let bar = RoundedTerminalTabBar(model: model, placement: .preview, store: store)
                bar.theme = theme
                let size = position.isVertical ? NSSize(width: store.settings.edgeThickness, height: 300)
                    : NSSize(width: 820, height: store.settings.edgeThickness)
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                host.wantsLayer = true
                host.layer?.backgroundColor = theme.background.cgColor
                host.appearance = NSAppearance(named: .darkAqua)
                bar.frame = host.bounds
                host.addSubview(bar)
                model.refresh()
                bar.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: dir.appendingPathComponent("tabbar-\(position.rawValue)-\(style.rawValue).png"))
                // Every tab and the add control must fit and not overlap.
                let frames = (0..<model.tabs.count).compactMap { bar.tabFrame(at: $0) }
                #expect(frames.count == model.tabs.count)
                for (a, b) in zip(frames, frames.dropFirst()) {
                    #expect(!a.intersects(b))
                }
            }
        }
        print("Ghostty X tab bar fixtures: \(dir.path)")
    }

    @Test func renderSettingsWindow() async throws {
        guard let path = ProcessInfo.processInfo.environment["GHOSTTYX_FIXTURE_DIR"] else { return }
        for position in [TabBarSettings.Position.left, .top] {
            let store = TabBarSettingsStore(defaults: nil)
            store.settings.position = position
            let view = NSHostingView(rootView: TabBarSettingsView(store: store, model: PreviewTabModel()))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 940, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("settings-\(position.rawValue).png"))
        }
    }

    @Test func randomColorsDifferFromNeighbours() {
        for _ in 0..<50 {
            let model = PreviewTabModel()
            model.newTab(); model.newTab()
            let slots = model.tabs.map(\.autoColor)
            #expect(slots.allSatisfy { $0 != nil })
            for (a, b) in zip(slots, slots.dropFirst()) { #expect(a != b) }
            model.shuffleColors()
            let shuffled = model.tabs.map(\.autoColor)
            for (a, b) in zip(shuffled, shuffled.dropFirst()) { #expect(a != b) }
        }
    }

    @Test func nativeTabsKeepTheirColorAcrossStrips() {
        let first = window("First")
        let second = window("Second")
        defer { second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        let a = RoundedTerminalTabModel(hostWindow: first)
        let b = RoundedTerminalTabModel(hostWindow: second)
        a.refresh(); b.refresh()
        #expect(a.tabs.map(\.autoColor) == b.tabs.map(\.autoColor))
        #expect(a.tabs[0].autoColor != a.tabs[1].autoColor)
    }

    @Test func renderEveryColorStyle() throws {
        guard let path = ProcessInfo.processInfo.environment["GHOSTTYX_FIXTURE_DIR"] else { return }
        let theme = RoundedTabTheme.fallback
        for position in [TabBarSettings.Position.top, .left] {
            for colorStyle in TabBarSettings.ColorStyle.allCases {
                let store = TabBarSettingsStore(defaults: nil)
                store.settings.position = position
                store.settings.colorStyle = colorStyle
                let model = PreviewTabModel()
                model.select(model.tabs[1])
                let bar = RoundedTerminalTabBar(model: model, placement: .preview, store: store)
                bar.theme = theme
                let size = position.isVertical ? NSSize(width: store.settings.edgeThickness, height: 300)
                    : NSSize(width: 820, height: store.settings.edgeThickness)
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                host.wantsLayer = true
                host.layer?.backgroundColor = theme.background.cgColor
                host.appearance = NSAppearance(named: .darkAqua)
                bar.frame = host.bounds
                host.addSubview(bar)
                bar.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: path)
                    .appendingPathComponent("colors-\(position.rawValue)-\(colorStyle.rawValue).png"))
            }
        }
    }

    @Test func settingsDecodeToleratesMissingAndInvalidValues() throws {
        let json = #"{"position":"left","tabHeight":99,"style":"sparkles"}"#
        let settings = try JSONDecoder().decode(TabBarSettings.self, from: Data(json.utf8))
        #expect(settings.position == .left)
        #expect(settings.tabHeight == TabBarSettings.heightRange.upperBound)
        #expect(settings.style == .filled)
        #expect(settings.showNumbers)
        #expect(settings.tabColors == .random)
        #expect(settings.colorStyle == .cap)
        let colors = try JSONDecoder().decode(TabBarSettings.self, from: Data(#"{"tabColors":"off","colorStyle":"dot"}"#.utf8))
        #expect(colors.tabColors == .off && colors.colorStyle == .dot)
    }

    /// AppKit applies tab selection asynchronously for offscreen fixture windows.
    private func waitForSelection(of window: NSWindow, in host: NSWindow) async throws {
        for _ in 0..<20 where host.tabGroup?.selectedWindow !== window {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func modelIsSelected(bar: RoundedTerminalTabBar, window: NSWindow) -> Bool {
        bar.model.tabs.first(where: \.selected)?.window.value === window
    }

}
