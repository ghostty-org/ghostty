import AppKit
import Testing
@testable import Ghostty

struct NSColorDistanceTests {
    @Test func distanceBetweenInvalidAndValidColorsReturnsInfinity() {
        let originalColor = NSColor()
        let otherColor = NSColor.blue

        #expect(originalColor.distance(to: otherColor) == .infinity)
    }

    @Test func distanceBetweenSameColorsReturnsZeroDistance() {
        let originalColor = NSColor.blue
        let otherColor = NSColor.blue

        #expect(originalColor.distance(to: otherColor) == 0.0)
    }

    @Test func distanceBetweenDifferentColorsReturnsNonZeroDistance() {
        let originalColor = NSColor.red
        let otherColor = NSColor.blue

        #expect(originalColor.distance(to: otherColor) > 0.0)
    }
}
