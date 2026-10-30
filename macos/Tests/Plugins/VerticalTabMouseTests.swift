import AppKit
import SwiftUI
import Testing
@testable import Ghostty

// Optional real CoreDrag regression, not a routine app-hosted unit test.
// Run after native tab/drag changes on an unlocked, foreground desktop.
@Suite(.tags(.interactiveDesktop))
@MainActor
struct VerticalTabMouseTests {
    private final class MonitorOwner { var received = 0 }

    @Test func repeatedKeyboardCreationAndPointerTracking() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let oldGrouping = settings.groupingMode
        let oldOrdering = settings.orderingMode
        defer { settings.groupingMode = oldGrouping; settings.orderingMode = oldOrdering }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let window = try #require(first.window)
        var controllers = [first]
        defer {
            for controller in controllers { controller.window?.delegate = nil; controller.window?.close() }
        }
        first.showWindow(nil)
        first.setTabGroupingMode(.none)
        first.setTabOrderingMode(.manual)
        first.setSidebarVisible(true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: "/tmp/omg-sidebar-desktop-test.pid", atomically: true, encoding: .utf8
        )
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires the foreground test window")
        try #require(CGPreflightPostEventAccess(), "Optional pointer test requires permission to post system mouse events")
        let group = try #require(window.tabGroup)
        for index in 0..<20 {
            let source = try #require(group.selectedWindow ?? window)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: source.windowNumber,
                context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: index > 0, keyCode: 17
            ))
            NSApp.sendEvent(event)
            for _ in 0..<60 {
                if group.windows.count > controllers.count { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            controllers.append(try #require(group.windows.compactMap { $0.windowController as? TerminalController }
                .first { candidate in !controllers.contains { $0 === candidate } }))
        }
        try await Task.sleep(for: .milliseconds(100))
        let last = try #require(controllers.last)
        let selectedWindow = try #require(group.selectedWindow)
        #expect(selectedWindow === last.window)
        #expect(first.tabLayoutState.sidebarHost.mountCount == 1)
        let live = try #require(first.tabLayoutState.sidebarHost.liveView)
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView).first
        }
        let scroll = try #require(scrollView(live))
        let document = try #require(scroll.documentView)
        let rowHeight = settings.tabRowDensity.rowHeight
        // Use the visible rows after auto-scrolling to the selected tab.
        let firstVisibleRow = Int(ceil(scroll.contentView.bounds.minY / (rowHeight + 2)))
        var latencies: [Double] = []
        for index in 0..<24 {
            let row = firstVisibleRow + index % 8
            let point = document.convert(NSPoint(x: 80, y: 2 + CGFloat(row) * (rowHeight + 2) + rowHeight / 2), to: nil)
            let screen = selectedWindow.convertPoint(toScreen: point)
            let cgPoint = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left))
            let start = ContinuousClock.now
            event.post(tap: .cghidEventTap)
            let target = ObjectIdentifier(controllers[row])
            for _ in 0..<40 {
                if last.hoveredTabID == target { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let duration = start.duration(to: .now).components
            latencies.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            #expect(last.hoveredTabID == target, "Pointer movement \(index) must reach row \(row)")
        }
        print("TAB_POINTER max=\(latencies.max() ?? 0) count=\(latencies.count)")
    }
    @Test func mouseSelectionKeepsWorkingAcrossNativeWindows() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let previousGrouping = settings.groupingMode
        let previousOrdering = settings.orderingMode
        defer { settings.groupingMode = previousGrouping; settings.orderingMode = previousOrdering }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        config.workingDirectory = "/tmp"
        let first = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: .vertical)
        var controllers = [first]
        let firstWindow = try #require(first.window)
        first.titleOverride = "mouse-tab-0"
        first.showWindow(nil)
        for index in 1..<3 {
            let next = try #require(TerminalController.newTab(app.ghostty, from: firstWindow, withBaseConfig: config))
            next.titleOverride = "mouse-tab-\(index)"
            controllers.append(next)
        }
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        first.setTabGroupingMode(.none); first.setTabOrderingMode(.manual); first.setSidebarVisible(true)
        first.selectVerticalTab(first)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        for _ in 0..<20 {
            if NSApp.isActive && firstWindow.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && firstWindow.isKeyWindow,
            "Optional desktop test needs an unlocked desktop and the test window in foreground; do not diagnose a drag regression without these preconditions.")
        let group = try #require(firstWindow.tabGroup)
        first.selectVerticalTab(first)
        try await Task.sleep(for: .milliseconds(50))
        func sidebarScroll(in window: NSWindow) -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    if frame.minX < 40 && frame.width < 400 && frame.height > 100 { return scroll }
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }
        // Drive the actual SwiftUI source and native drag loop. A pasteboard
        // change proves these gestures reached onDrag rather than only clicks.
        func nativeDrag(toRow destination: Int) async throws {
            let dragWindow = try #require(group.selectedWindow)
            let document = try #require(sidebarScroll(in: dragWindow)?.documentView)
            let height = OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            let sourceIndex = try #require(group.windows.firstIndex { $0 === controllers[0].window })
            func point(row: Int, fraction: CGFloat) -> NSPoint {
                let y = 2 + CGFloat(row) * (height + 2) + height * fraction
                return document.convert(.init(x: 70, y: document.isFlipped ? y : document.bounds.height - y), to: nil)
            }
            let start = point(row: sourceIndex, fraction: 0.5)
            let finish = point(row: destination, fraction: 0.8)
            func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: dragWindow.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            let pasteboard = NSPasteboard(name: .drag)
            let before = pasteboard.changeCount
            // CoreDrag starts in a run-loop observer. Move and release only
            // after it starts tracking, so the OS sees the entire gesture.
            var tick = 0
            let timer = Timer(timeInterval: 0.05, repeats: true) { firingTimer in
                MainActor.assumeIsolated {
                    tick += 1
                    if tick == 2 { firingTimer.invalidate() }
                    if tick == 1, let moved = try? event(.leftMouseDragged, at: finish) {
                        NSApp.postEvent(moved, atStart: false)
                    } else if let up = try? event(.leftMouseUp, at: finish) {
                        NSApp.postEvent(up, atStart: false)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            NSApp.postEvent(try event(.leftMouseDragged, at: .init(x: start.x + 18, y: start.y)), atStart: false)
            NSApp.sendEvent(try event(.leftMouseDown, at: start))
            while let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(pasteboard.changeCount > before, "The native drag source must actually run for destination row \(destination)")
        }
        let initialOrder = group.windows
        try await nativeDrag(toRow: 0)
        #expect(group.windows == initialOrder, "Dragging within the source row must keep tab order")
        // The header is outside all row drop destinations, so release there
        // must cancel without committing tab order. Native drag lifecycle is covered by
        // VerticalNativeTabOutlineDesktopTests.
        try await nativeDrag(toRow: -1)
        #expect(group.windows == initialOrder, "A rejected drop must preserve native tab order")
        try await nativeDrag(toRow: 2)
        #expect(group.windows == [initialOrder[1], initialOrder[2], initialOrder[0]], "A completed drag must commit native tab order")

        var owner: MonitorOwner? = MonitorOwner()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown,
            handler: WeakLocalEventMonitor.handler(for: owner!) { owner, event in owner.received += 1; return event })
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        for step in 0..<64 {
            if step == 28 {
                #expect((owner?.received ?? 0) > 0, "Exercise application-level event monitors")
                owner = nil
            }
            let target = controllers[step % 3]
            let sourceWindow = try #require(group.selectedWindow)
            let scroll = try #require(sidebarScroll(in: sourceWindow))
            let document = try #require(scroll.documentView)
            let height = OhMyGhosttySettings.shared.tabRowDensity.rowHeight
            let targetIndex = try #require(group.windows.firstIndex { $0 === target.window })
            let rowY = 2 + CGFloat(targetIndex) * (height + 2) + height / 2
            let point = document.convert(.init(x: 70, y: document.isFlipped ? rowY : document.bounds.height - rowY), to: nil)
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: step * 2, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: step * 2 + 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
            try await Task.sleep(for: .milliseconds(35))
            #expect(group.selectedWindow === target.window, "Mouse click \(step) must select its target window")
        }
        // A row action may outlive a native group change. Its target still
        // identifies a live window even after the source cache drops it.
        let moved = controllers[2]
        let movedWindow = try #require(moved.window)
        group.removeWindow(movedWindow)
        movedWindow.makeKeyAndOrderFront(nil)
        firstWindow.makeKeyAndOrderFront(nil)
        first.selectVerticalTab(first)
        #expect(!first.tabControllers.contains { $0 === moved })
        first.selectVerticalTab(moved)
        #expect(movedWindow.isKeyWindow)
    }
}
