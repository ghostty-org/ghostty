import SwiftUI
import Testing
@testable import Ghostty

/// Regression coverage for https://github.com/jischeng/oh-my-ghostty/issues/15
///
/// Terminal-adjacent chrome (tab sidebar, inspector, quick input) must paint
/// the exact same color the terminal surface resolves to. When the window is
/// opaque (native fullscreen or the opaque-background toggle), the terminal
/// renderer's semi-transparent background composited over the opaque
/// same-colored window background yields the opaque background color, so the
/// chrome must also paint fully opaque. Painting another semi-transparent
/// SwiftUI layer in that state produces a visible color mismatch.
struct TerminalChromeBackgroundTests {
    private let background = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 1)

    @Test func opaqueWindowForcesOpaqueChrome() {
        let chrome = TerminalController.chromeBackground(
            color: background,
            opacity: 0.85,
            windowIsOpaque: true
        )
        let opacity = NSColor(chrome).cgColor.alpha
        #expect(opacity == 1)
    }

    @Test func opaqueWindowMatchesRenderedColor() {
        let chrome = TerminalController.chromeBackground(
            color: background,
            opacity: 0.85,
            windowIsOpaque: true
        )
        let expected = TerminalRenderColorQuantizer.matchingRenderedColor(
            background,
            colorspaceIsDisplayP3: false
        )
        #expect(NSColor(chrome).usingColorSpace(.displayP3) ==
                NSColor(expected).usingColorSpace(.displayP3))
    }

    @Test func transparentWindowMatchesRendererOpacityAndPremultipliedBytes() throws {
        let chrome = TerminalController.chromeBackground(
            color: background,
            opacity: 0.85,
            windowIsOpaque: false,
            colorspaceIsDisplayP3: true
        )
        let color = try #require(NSColor(chrome).usingColorSpace(.displayP3))
        #expect(Int((color.alphaComponent * 255).rounded()) == 217)
        #expect(Int((color.redComponent * color.alphaComponent * 255).rounded()) == 43)
        #expect(Int((color.greenComponent * color.alphaComponent * 255).rounded()) == 87)
        #expect(Int((color.blueComponent * color.alphaComponent * 255).rounded()) == 130)
    }

    @Test func explicitLinearBlendingRetainsItsExistingFillPolicy() {
        let chrome = TerminalController.chromeBackground(
            color: background, opacity: 0.85, windowIsOpaque: false, linearBlending: true
        )
        #expect(chrome == background.opacity(0.85))
    }

    @Test func fullyOpaqueConfigStaysOpaque() {
        let chrome = TerminalController.chromeBackground(
            color: background,
            opacity: 1,
            windowIsOpaque: false
        )
        #expect(NSColor(chrome).cgColor.alpha == 1)
    }

    @Test func opacityIsClamped() {
        let low = TerminalController.chromeBackground(
            color: background,
            opacity: -0.5,
            windowIsOpaque: false
        )
        #expect(NSColor(low).alphaComponent == 0)

        let high = TerminalController.chromeBackground(
            color: background,
            opacity: 0.7,
            windowIsOpaque: false
        )
        #expect(Int((NSColor(high).alphaComponent * 255).rounded()) == 179)
    }
}
