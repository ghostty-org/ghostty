import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct ProductionTabTitlebarTests {
    private func window(_ title: String) throws -> TitlebarTabsTahoeTerminalWindow {
        let owner = NSWindowController(window: nil)
        let nib = try #require(NSNib(nibNamed: "TerminalTabsTitlebarTahoe", bundle: .main))
        var objects: NSArray?
        #expect(nib.instantiate(withOwner: owner, topLevelObjects: &objects))
        let window = try #require(objects?.compactMap { $0 as? TitlebarTabsTahoeTerminalWindow }.first)
        window.isReleasedWhenClosed = false
        window.title = title
        window.setFrame(NSRect(x: -10000, y: -10000, width: 800, height: 500), display: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        return window
    }

    private func findBar(_ view: NSView) -> RoundedTerminalTabBar? {
        if let bar = view as? RoundedTerminalTabBar { return bar }
        return view.subviews.lazy.compactMap(findBar).first
    }

    @Test func clicksReachTabsInProductionTitlebar() async throws {
        // The titlebar strip only shows tabs when the position is Top; keep the user's choice.
        let saved = TabBarSettingsStore.shared.settings
        TabBarSettingsStore.shared.settings.position = .top
        defer { TabBarSettingsStore.shared.settings = saved }
        let first = try window("Fixture One")
        let second = try window("Fixture Two")
        defer { second.close(); first.close() }
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        first.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        first.setupTabBar()
        first.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let root = try #require(first.contentView?.superview)
        let bar = try #require(findBar(root))
        bar.layoutSubtreeIfNeeded()
        let secondFrame = try #require(bar.tabFrame(at: 1))
        let point = bar.convert(NSPoint(x: secondFrame.midX, y: secondFrame.midY), to: nil)
        let rootPoint = root.convert(point, from: nil)
        let hit = root.hitTest(rootPoint)
        print("PRODUCTION TAB HIT:", hit.map { String(describing: type(of: $0)) } ?? "nil",
              "bar", bar.frame, "root", root.frame)
        #expect(hit?.isDescendant(of: bar) == true)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: first.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        first.sendEvent(event)
        try await waitForSelection(of: second, in: first)
        #expect(first.tabGroup?.selectedWindow === second)

        // Switching tabs makes AppKit re-insert its invisible NSTabBar, which used to
        // land above our strip and swallow every later click. Click back to tab one.
        try await Task.sleep(for: .milliseconds(200))
        let active = try #require(first.tabGroup?.selectedWindow as? TitlebarTabsTahoeTerminalWindow)
        active.setupTabBar()
        let activeRoot = try #require(active.contentView?.superview)
        let activeBar = try #require(findBar(activeRoot))
        activeBar.layoutSubtreeIfNeeded()
        let firstFrame = try #require(activeBar.tabFrame(at: 0))
        let backPoint = activeBar.convert(NSPoint(x: firstFrame.midX, y: firstFrame.midY), to: nil)
        let back = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: backPoint,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: active.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        active.sendEvent(back)
        let backHit = activeRoot.hitTest(activeRoot.convert(backPoint, from: nil))
        #expect(backHit?.isDescendant(of: activeBar) == true)
        try await waitForSelection(of: first, in: first)
        #expect(first.tabGroup?.selectedWindow === first)
    }

    /// AppKit applies tab selection asynchronously for offscreen fixture windows.
    private func waitForSelection(of window: NSWindow, in host: NSWindow) async throws {
        for _ in 0..<20 where host.tabGroup?.selectedWindow !== window {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
