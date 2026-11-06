import Testing
import AppKit
@testable import Ghostty

struct SplitViewGeometryTests {
    @Test(arguments: [CGFloat(12), 101, 999, 1920])
    func horizontalGuttersRemainExact(width: CGFloat) {
        let layout = SplitViewGeometry(size: CGSize(width: width, height: 600), direction: .horizontal,
                                       ratio: 0.67, gap: 6, increments: NSSize(width: 1, height: 1))
        #expect(layout.trailing.minX - layout.leading.maxX == 6)
        #expect(layout.trailing.maxX == width)
        #expect(layout.leading.minX == 0)
        #expect(layout.dividerCenter.x == layout.leading.maxX + 3)
        #expect(layout.leading.height == 600 && layout.trailing.height == 600)
    }

    @Test(arguments: [CGFloat(12), 101, 601, 1080])
    func verticalGuttersRemainExact(height: CGFloat) {
        let layout = SplitViewGeometry(size: CGSize(width: 800, height: height), direction: .vertical,
                                       ratio: 0.5, gap: 6, increments: NSSize(width: 1, height: 1))
        #expect(layout.trailing.minY - layout.leading.maxY == 6)
        #expect(layout.trailing.maxY == height)
        #expect(layout.dividerCenter.y == layout.leading.maxY + 3)
    }

    @Test(arguments: [CGFloat(-1), 0, 0.5, 1, 2, .nan])
    func tinyWindowsAndInvalidRatiosNeverOverlap(ratio: CGFloat) {
        let layout = SplitViewGeometry(size: CGSize(width: 3, height: 100), direction: .horizontal,
                                       ratio: ratio, gap: 6, increments: NSSize(width: 1, height: 1))
        #expect(layout.leading.width >= 0)
        #expect(layout.trailing.width >= 0)
        #expect(layout.trailing.maxX == 3)
        #expect(layout.leading.maxX <= layout.trailing.minX)
    }

    @Test func resizeUsesTranslationWithoutJumping() {
        #expect(SplitViewGeometry.resizedRatio(from: 0.4, translation: 0, extent: 1006,
                                              gap: 6, minimumPane: 10) == 0.4)
        #expect(SplitViewGeometry.resizedRatio(from: 0.4, translation: 100, extent: 1006,
                                              gap: 6, minimumPane: 10) == 0.5)
        #expect(SplitViewGeometry.resizedRatio(from: 0.4, translation: -1000, extent: 1006,
                                              gap: 6, minimumPane: 10) == 0.01)
        #expect(SplitViewGeometry.resizedRatio(from: 0.4, translation: 1000, extent: 3,
                                              gap: 6, minimumPane: 10) == 0.5)
    }

    @Test func cellRoundingPreservesTotalWidth() {
        let layout = SplitViewGeometry(size: CGSize(width: 999, height: 600), direction: .horizontal,
                                       ratio: 0.5, gap: 6, increments: NSSize(width: 9, height: 18))
        #expect(layout.leading.width.truncatingRemainder(dividingBy: 9) == 0)
        #expect(layout.leading.width + layout.trailing.width + 6 == 999)
    }
}
