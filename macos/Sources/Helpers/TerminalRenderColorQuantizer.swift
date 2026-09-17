import SwiftUI

/// Reproduces the exact on-screen code values of the Ghostty terminal
/// renderer for a given sRGB color.
///
/// The terminal surface renders into an 8-bit BGRA IOSurface tagged as
/// Display P3 (`src/renderer/metal/Target.zig`). With the default
/// `window-colorspace = srgb`, the shader converts every sRGB color to
/// Display P3 (`src/renderer/shaders/shaders.metal`, `load_color`) and the
/// GPU rounds the result when writing to the 8-bit target. That rounding is
/// lossy (e.g. Catppuccin Mocha's background #1e1e2e becomes P3 code values
/// 30/30/45), so SwiftUI chrome painted with the original sRGB color shows
/// a subtle but visible mismatch next to the terminal on an opaque window.
///
/// Painting the quantized Display P3 color makes Core Animation emit the
/// exact same code values the terminal surface produced, so both render
/// stacks match bit-for-bit on P3 and sRGB displays alike.
///
/// See: https://github.com/jischeng/oh-my-ghostty/issues/15
enum TerminalRenderColorQuantizer {
    /// Returns the color the terminal renderer produces for `color`,
    /// expressed in the Display P3 color space after 8-bit quantization.
    ///
    /// With `window-colorspace = srgb` (the default) the shader converts
    /// sRGB to Display P3 before quantizing; with `display-p3` the sRGB code
    /// values are emitted as-is (the shader skips conversion). The returned
    /// color is always a Display P3 color matching the rendered code values.
    static func matchingRenderedColor(_ color: Color, colorspaceIsDisplayP3: Bool) -> Color {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return color
        }

        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

        let p3 = colorspaceIsDisplayP3
            ? (r: quantize8(Double(r)), g: quantize8(Double(g)), b: quantize8(Double(b)))
            : renderedP3(srgbR: Double(r), g: Double(g), b: Double(b))
        return Color(.displayP3, red: p3.r, green: p3.g, blue: p3.b, opacity: Double(a))
    }

    /// AppKit variant of ``matchingRenderedColor(_:colorspaceIsDisplayP3:)``
    /// that avoids a SwiftUI Color round-trip.
    static func matchingRenderedNSColor(_ color: NSColor, colorspaceIsDisplayP3: Bool) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return color
        }

        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

        let p3 = colorspaceIsDisplayP3
            ? (r: quantize8(Double(r)), g: quantize8(Double(g)), b: quantize8(Double(b)))
            : renderedP3(srgbR: Double(r), g: Double(g), b: Double(b))
        return NSColor(displayP3Red: CGFloat(p3.r), green: CGFloat(p3.g), blue: CGFloat(p3.b), alpha: a)
    }

    // MARK: - Shader math

    /// Converts an sRGB color to the 8-bit Display P3 code values the
    /// terminal renderer produces, returned as 0...1 Display P3 components.
    ///
    /// The matrices below are copied verbatim from
    /// `src/renderer/shaders/shaders.metal` and must stay in sync with it:
    /// the shader composes `sRGB_DP3 = XYZ_DP3 * sRGB_XYZ`, applies it to
    /// the linearized color, then unlinearizes with the sRGB transfer
    /// function (Display P3 shares it) before the GPU rounds to 8 bits.
    static func renderedP3(srgbR r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let lr = linearize(r)
        let lg = linearize(g)
        let lb = linearize(b)
        let m = sRGBDP3

        let p3r = m[0][0] * lr + m[0][1] * lg + m[0][2] * lb
        let p3g = m[1][0] * lr + m[1][1] * lg + m[1][2] * lb
        let p3b = m[2][0] * lr + m[2][1] * lg + m[2][2] * lb

        return (
            r: quantize8(unlinearize(p3r)),
            g: quantize8(unlinearize(p3g)),
            b: quantize8(unlinearize(p3b))
        )
    }

    /// D50-adapted sRGB to XYZ conversion matrix.
    /// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
    private static let sRGBXYZ: [[Double]] = [
        [0.4360747, 0.3850649, 0.1430804],
        [0.2225045, 0.7168786, 0.0606169],
        [0.0139322, 0.0971045, 0.7141733],
    ]

    /// XYZ to Display P3 conversion matrix.
    /// http://endavid.com/index.php?entry=79
    private static let xyzDP3: [[Double]] = [
        [2.40414768, -0.99010704, -0.39759019],
        [-0.84239098, 1.79905954, 0.01597023],
        [0.04838763, -0.09752546, 1.27393636],
    ]

    /// sRGB to Display P3 conversion matrix, `XYZ_DP3 * sRGB_XYZ`.
    private static let sRGBDP3: [[Double]] = {
        var result = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                result[i][j] = xyzDP3[i][0] * sRGBXYZ[0][j]
                    + xyzDP3[i][1] * sRGBXYZ[1][j]
                    + xyzDP3[i][2] * sRGBXYZ[2][j]
            }
        }
        return result
    }()

    /// sRGB transfer function, gamma encoded to linear.
    private static func linearize(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB transfer function, linear to gamma encoded.
    private static func unlinearize(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Round a 0...1 gamma-encoded component the same way the GPU does when
    /// writing to the 8-bit IOSurface.
    static func quantize8(_ v: Double) -> Double {
        (v * 255).rounded() / 255
    }
}
