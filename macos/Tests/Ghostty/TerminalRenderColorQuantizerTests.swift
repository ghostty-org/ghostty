import SwiftUI
import Testing
@testable import Ghostty

/// Regression coverage for https://github.com/jischeng/oh-my-ghostty/issues/15
///
/// The terminal renderer converts sRGB colors to Display P3 in the shader
/// and quantizes to the 8-bit IOSurface. SwiftUI chrome must paint the same
/// quantized Display P3 code values or a sub-1/255 mismatch (visible in the
/// blue channel, e.g. Catppuccin Mocha's #1e1e2e) appears on opaque windows.
struct TerminalRenderColorQuantizerTests {
    /// Catppuccin Mocha background: sRGB (30, 30, 46) renders as P3 (30, 30, 45).
    @Test func catppuccinMochaBackground() {
        let p3 = TerminalRenderColorQuantizer.renderedP3(srgbR: 30 / 255, g: 30 / 255, b: 46 / 255)
        #expect(p3.r * 255 == 30)
        #expect(p3.g * 255 == 30)
        #expect(p3.b * 255 == 45)
    }

    /// Catppuccin Mocha mantle: sRGB (24, 24, 37) renders as P3 (24, 24, 36).
    @Test func catppuccinMochaMantle() {
        let p3 = TerminalRenderColorQuantizer.renderedP3(srgbR: 24 / 255, g: 24 / 255, b: 37 / 255)
        #expect(p3.r * 255 == 24)
        #expect(p3.g * 255 == 24)
        #expect(p3.b * 255 == 36)
    }

    /// Pure white and black are fixed points of the conversion.
    @Test func extremesAreFixedPoints() {
        let white = TerminalRenderColorQuantizer.renderedP3(srgbR: 1, g: 1, b: 1)
        #expect(white.r * 255 == 255)
        #expect(white.g * 255 == 255)
        #expect(white.b * 255 == 255)

        let black = TerminalRenderColorQuantizer.renderedP3(srgbR: 0, g: 0, b: 0)
        #expect(black.r == 0)
        #expect(black.g == 0)
        #expect(black.b == 0)
    }

    /// With `window-colorspace = display-p3` the shader skips conversion and
    /// only quantizes the sRGB code values.
    @Test func displayP3ColorspaceSkipsConversion() throws {
        let color = Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 46 / 255, opacity: 1)
        let matched = TerminalRenderColorQuantizer.matchingRenderedColor(
            color,
            colorspaceIsDisplayP3: true
        )
        let nsColor = try #require(NSColor(matched).usingColorSpace(.displayP3))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        #expect(r * 255 == 30)
        #expect(g * 255 == 30)
        #expect(b * 255 == 46)
    }

    /// The matching color is expressed in Display P3 with the quantized values.
    @Test func matchingColorIsQuantizedDisplayP3() throws {
        let color = Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 46 / 255, opacity: 1)
        let matched = TerminalRenderColorQuantizer.matchingRenderedColor(
            color,
            colorspaceIsDisplayP3: false
        )
        let nsColor = try #require(NSColor(matched).usingColorSpace(.displayP3))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: nil)
        #expect(r * 255 == 30)
        #expect(g * 255 == 30)
        #expect(b * 255 == 45)
    }
}
