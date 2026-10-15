//
//  QuickTerminalSizeTests.swift
//  GhosttyTests
//
//  Tests for QuickTerminalSize.calculate() and QuickTerminalSize.Size.toPixels().
//

import Testing
@testable import Ghostty

struct QuickTerminalSizeTests {
    // MARK: - Size.toPixels

    @Test func percentageConversionHorizontal() {
        let size = QuickTerminalSize.Size.percentage(50)
        #expect(size.toPixels(parentDimension: 1920) == 960)
    }

    @Test func percentageConversionVertical() {
        let size = QuickTerminalSize.Size.percentage(30)
        #expect(size.toPixels(parentDimension: 1080) == 324)
    }

    @Test func percentageBoundaryZero() {
        let size = QuickTerminalSize.Size.percentage(0)
        #expect(size.toPixels(parentDimension: 1000) == 0)
    }

    @Test func percentageBoundaryOneHundred() {
        let size = QuickTerminalSize.Size.percentage(100)
        #expect(size.toPixels(parentDimension: 1000) == 1000)
    }

    @Test func pixelPassthrough() {
        let size = QuickTerminalSize.Size.pixels(400)
        // parentDimension should have no effect for pixels
        #expect(size.toPixels(parentDimension: 1920) == 400)
        #expect(size.toPixels(parentDimension: 800) == 400)
    }

    // MARK: - calculate: left / right

    @Test func leftWithPercentagePrimary() {
        let qtSize = QuickTerminalSize(primary: .percentage(40), secondary: .percentage(80))
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .left, screenDimensions: screen)
        // left: width = primary(40% of 1920) = 768, height = secondary(80% of 1080) = 864
        #expect(result.width == 768)
        #expect(result.height == 864)
    }

    @Test func rightWithPixelPrimary() {
        let qtSize = QuickTerminalSize(primary: .pixels(500), secondary: .pixels(900))
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .right, screenDimensions: screen)
        #expect(result.width == 500)
        #expect(result.height == 900)
    }

    @Test func leftDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .left, screenDimensions: screen)
        // primary nil → width defaults to 400; secondary nil → height defaults to full screen height
        #expect(result.width == 400)
        #expect(result.height == 1080)
    }

    @Test func rightDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 2560, height: 1440)
        let result = qtSize.calculate(position: .right, screenDimensions: screen)
        #expect(result.width == 400)
        #expect(result.height == 1440)
    }

    // MARK: - calculate: top / bottom

    @Test func topWithPercentagePrimary() {
        let qtSize = QuickTerminalSize(primary: .percentage(50), secondary: .percentage(100))
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .top, screenDimensions: screen)
        // top: width = secondary(100% of 1920) = 1920, height = primary(50% of 1080) = 540
        #expect(result.width == 1920)
        #expect(result.height == 540)
    }

    @Test func bottomWithPixelPrimary() {
        let qtSize = QuickTerminalSize(primary: .pixels(300), secondary: .pixels(1280))
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .bottom, screenDimensions: screen)
        #expect(result.width == 1280)
        #expect(result.height == 300)
    }

    @Test func topDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .top, screenDimensions: screen)
        // primary nil → height defaults to 400; secondary nil → width defaults to full screen width
        #expect(result.width == 1920)
        #expect(result.height == 400)
    }

    @Test func bottomDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 2560, height: 1440)
        let result = qtSize.calculate(position: .bottom, screenDimensions: screen)
        #expect(result.width == 2560)
        #expect(result.height == 400)
    }

    // MARK: - calculate: center (landscape)

    @Test func centerLandscapeWithPercentages() {
        let qtSize = QuickTerminalSize(primary: .percentage(60), secondary: .percentage(40))
        let screen = CGSize(width: 1920, height: 1080)  // landscape: width >= height
        let result = qtSize.calculate(position: .center, screenDimensions: screen)
        // landscape: width = primary(60% of 1920) = 1152, height = secondary(40% of 1080) = 432
        #expect(result.width == 1152)
        #expect(result.height == 432)
    }

    @Test func centerLandscapeDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 1920, height: 1080)
        let result = qtSize.calculate(position: .center, screenDimensions: screen)
        #expect(result.width == 800)
        #expect(result.height == 400)
    }

    @Test func centerSquareCountsAsLandscape() {
        // width == height: the code uses >=, so this is treated as landscape
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 1000, height: 1000)
        let result = qtSize.calculate(position: .center, screenDimensions: screen)
        #expect(result.width == 800)
        #expect(result.height == 400)
    }

    // MARK: - calculate: center (portrait)

    @Test func centerPortraitWithPercentages() {
        let qtSize = QuickTerminalSize(primary: .percentage(60), secondary: .percentage(40))
        let screen = CGSize(width: 800, height: 1280)  // portrait: height > width
        let result = qtSize.calculate(position: .center, screenDimensions: screen)
        // portrait: width = secondary(40% of 800) = 320, height = primary(60% of 1280) = 768
        #expect(result.width == 320)
        #expect(result.height == 768)
    }

    @Test func centerPortraitDefaultsWhenNil() {
        let qtSize = QuickTerminalSize()
        let screen = CGSize(width: 800, height: 1280)
        let result = qtSize.calculate(position: .center, screenDimensions: screen)
        #expect(result.width == 400)
        #expect(result.height == 800)
    }
}
