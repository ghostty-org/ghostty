import AppKit
import Testing
@testable import Ghostty

@MainActor
struct QuickTerminalPositionTests {
    private let screen = MockQuickTerminalScreen(
        visibleFrame: NSRect(x: 1200, y: 80, width: 1601, height: 901))

    private func window() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 45, y: 67, width: 600, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
    }

    @Test func finalOriginUsesVisibleFrame() {
        let window = window()
        let expected: [(QuickTerminalPosition, CGPoint)] = [
            (.top, CGPoint(x: 1701, y: 681)),
            (.bottom, CGPoint(x: 1701, y: 80)),
            (.left, CGPoint(x: 1200, y: 381)),
            (.right, CGPoint(x: 2201, y: 381)),
            (.center, CGPoint(x: 1701, y: 381)),
        ]

        for (position, origin) in expected {
            #expect(position.finalOrigin(for: window, on: screen) == origin)
        }
    }

    @Test func centeredOriginRecentersOnlyApplicableAxes() {
        let window = window()
        let expected: [(QuickTerminalPosition, CGPoint)] = [
            (.top, CGPoint(x: 1701, y: 67)),
            (.bottom, CGPoint(x: 1701, y: 67)),
            (.left, CGPoint(x: 45, y: 67)),
            (.right, CGPoint(x: 45, y: 67)),
            (.center, CGPoint(x: 1701, y: 381)),
        ]

        for (position, origin) in expected {
            #expect(position.centeredOrigin(for: window, on: screen) == origin)
        }
    }

    @Test func verticallyCenteredOriginRecentersOnlySidePositions() {
        let window = window()
        let expected: [(QuickTerminalPosition, CGPoint)] = [
            (.top, CGPoint(x: 45, y: 67)),
            (.bottom, CGPoint(x: 45, y: 67)),
            (.left, CGPoint(x: 45, y: 381)),
            (.right, CGPoint(x: 45, y: 381)),
            (.center, CGPoint(x: 45, y: 67)),
        ]

        for (position, origin) in expected {
            #expect(position.verticallyCenteredOrigin(for: window, on: screen) == origin)
        }
    }
}

private final class MockQuickTerminalScreen: NSScreen {
    private let mockVisibleFrame: NSRect

    init(visibleFrame: NSRect) {
        self.mockVisibleFrame = visibleFrame
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var visibleFrame: NSRect { mockVisibleFrame }
}
