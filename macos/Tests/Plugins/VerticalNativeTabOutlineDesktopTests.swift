import AppKit
import Testing
@testable import Ghostty

@Suite(.tags(.interactiveDesktop))
@MainActor
struct VerticalNativeTabOutlineDesktopTests {
    @Test func nativeClicksSwitchWindowsAndRetainOutline() async throws {
        try await exerciseOutline(includeDrag: false)
    }

    @Test func nativeDragCommitsAndCancelsWithoutChangingSelection() async throws {
        try #require(CGPreflightPostEventAccess(), "Real drag tests require permission to post system mouse events")
        try await exerciseOutline(includeDrag: true)
    }

    private func exerciseOutline(includeDrag: Bool) async throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let first = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        var controllers = [first]
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        first.showWindow(nil)
        let window = try #require(first.window)
        for _ in 0..<3 {
            controllers.append(try #require(TerminalController.newTab(
                delegate.ghostty, from: window, withBaseConfig: config
            )))
            try await Task.sleep(for: .milliseconds(80))
        }
        first.setTabGroupingMode(.none)
        first.setTabOrderingMode(.manual)
        first.setSidebarVisible(true)
        first.selectVerticalTab(first)
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let pidFile = "/tmp/omg-native-sidebar-desktop-test.pid"
        try String(ProcessInfo.processInfo.processIdentifier).write(
            toFile: pidFile, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        for _ in 0..<600 {
            if NSApp.isActive && window.isKeyWindow { break }
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires an unlocked foreground desktop")
        func findOutline(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap(findOutline).first
        }
        let host = try #require(first.tabLayoutState.sidebarHost.liveView)
        let outline = try #require(findOutline(host))
        let group = try #require(window.tabGroup)
        for index in 0..<16 {
            // Repeat each target to cover clicking an already-selected row.
            let target = controllers[(index / 2 + 1) % controllers.count]
            let row = try #require(group.windows.firstIndex { $0 === target.window })
            outline.scrollRowToVisible(row)
            let source = try #require(outline.window)
            let rect = outline.rect(ofRow: row)
            let point = outline.convert(NSPoint(x: 65, y: rect.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: source.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
                ))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            NSApp.sendEvent(try event(.leftMouseDown))
            try await Task.sleep(for: .milliseconds(60))
            #expect(group.selectedWindow === target.window, "Click \(index) selects its target")
            #expect(outline.window === target.window, "Click \(index) transfers the live outline")
            #expect(findOutline(host) === outline, "Click \(index) preserves outline identity")
            #expect(target.window?.firstResponder === target.focusedSurface, "Click \(index) restores terminal focus")
        }

        let currentWindow = try #require(outline.window)
        #expect(currentWindow.makeFirstResponder(outline))
        let down = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: currentWindow.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        outline.keyDown(with: down)
        try await Task.sleep(for: .milliseconds(80))
        #expect(outline.window?.firstResponder === outline)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: outline.window?.windowNumber ?? 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        outline.keyDown(with: enter)
        try await Task.sleep(for: .milliseconds(80))
        let selectedController = try #require(group.selectedWindow?.windowController as? TerminalController)
        #expect(selectedController.window?.firstResponder === selectedController.focusedSurface)

        guard includeDrag else { return }

        func drag(from sourceRow: Int, to destination: NSPoint) async throws {
            try #require(CGPreflightPostEventAccess(), "Real drag tests require permission to post system mouse events")
            let dragWindow = try #require(outline.window)
            let sourceRect = outline.rect(ofRow: sourceRow)
            let screenHeight = try #require(NSScreen.screens.first).frame.maxY
            func screenPoint(_ point: NSPoint) -> CGPoint {
                let screen = dragWindow.convertPoint(toScreen: outline.convert(point, to: nil))
                return CGPoint(x: screen.x, y: screenHeight - screen.y)
            }
            let start = screenPoint(NSPoint(x: 65, y: sourceRect.midY))
            let finish = screenPoint(destination)
            func post(_ type: CGEventType, at point: CGPoint) throws {
                let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                                mouseCursorPosition: point, mouseButton: .left))
                event.post(tap: .cghidEventTap)
            }
            let pasteboard = NSPasteboard(name: .drag)
            let previousChangeCount = pasteboard.changeCount
            try post(.mouseMoved, at: start)
            try await Task.sleep(for: .milliseconds(50))
            try post(.leftMouseDown, at: start)
            try await Task.sleep(for: .milliseconds(100))
            try post(.leftMouseDragged, at: CGPoint(x: start.x + 18, y: start.y))
            try await Task.sleep(for: .milliseconds(150))
            try post(.leftMouseDragged, at: finish)
            try await Task.sleep(for: .milliseconds(150))
            try post(.leftMouseUp, at: finish)
            try await Task.sleep(for: .milliseconds(400))
            #expect(pasteboard.changeCount > previousChangeCount, "Exercise a real native drag session")
            #expect((outline as? NativeTabOutline)?.isDraggingTab == false)
            #expect(group.selectedWindow === selectedController.window)
            #expect(selectedController.window?.firstResponder === selectedController.focusedSurface)
        }

        let originalOrder = group.windows
        try await drag(from: originalOrder.count - 1, to: NSPoint(x: 65, y: outline.rect(ofRow: 0).minY + 1))
        #expect(group.windows == [try #require(originalOrder.last)] + originalOrder.dropLast())
        let reordered = group.windows
        try await drag(from: 0, to: NSPoint(x: 65, y: -20))
        #expect(group.windows == reordered, "Dropping on the header must cancel without reordering")
        #expect(findOutline(host) === outline)
    }
}
