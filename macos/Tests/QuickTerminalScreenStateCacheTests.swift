import Testing
import AppKit
@testable import Ghostty

struct QuickTerminalScreenStateCacheTests {
    private typealias DisplayEntry = QuickTerminalScreenStateCache.DisplayEntry

    private func entry(screenSize: CGSize, scale: CGFloat) -> DisplayEntry {
        DisplayEntry(
            frame: NSRect(x: 0, y: 0, width: screenSize.width, height: 400),
            screenSize: screenSize,
            scale: scale,
            lastSeen: Date(timeIntervalSince1970: 0))
    }

    @Test func validWhenGeometryMatches() {
        let entry = entry(screenSize: .init(width: 1920, height: 1080), scale: 2)
        let screen = MockSizedScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        #expect(entry.isValid(for: screen))
    }

    /// A frame cached on a smaller display must not be reused when the same display
    /// reconnects at a larger resolution, otherwise the quick terminal restores at a
    /// partial size instead of filling the screen.
    @Test func invalidWhenScreenGrows() {
        let entry = entry(screenSize: .init(width: 1512, height: 982), scale: 2)
        let screen = MockSizedScreen(frame: .init(x: 0, y: 0, width: 3440, height: 1440), scale: 2)
        #expect(!entry.isValid(for: screen))
    }

    @Test func invalidWhenScreenShrinks() {
        let entry = entry(screenSize: .init(width: 3440, height: 1440), scale: 2)
        let screen = MockSizedScreen(frame: .init(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(!entry.isValid(for: screen))
    }

    @Test func invalidWhenScaleDiffers() {
        let entry = entry(screenSize: .init(width: 1920, height: 1080), scale: 1)
        let screen = MockSizedScreen(frame: .init(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
        #expect(!entry.isValid(for: screen))
    }
}

/// Mock NSScreen exposing a fixed frame and backing scale factor.
private final class MockSizedScreen: NSScreen {
    private let mockFrame: NSRect
    private let mockScale: CGFloat

    init(frame: NSRect, scale: CGFloat) {
        self.mockFrame = frame
        self.mockScale = scale
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var frame: NSRect { mockFrame }
    override var backingScaleFactor: CGFloat { mockScale }
}
