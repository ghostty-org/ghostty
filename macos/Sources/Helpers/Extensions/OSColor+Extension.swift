import Foundation
import AppKit
#if !DOCK_TILE_PLUGIN
import GhosttyKit
#endif

extension NSColor {
    var isLightColor: Bool {
        return self.luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed:green:blue:alpha requires sRGB space
        guard let rgb = self.usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    var hexString: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(rgb.redComponent * 255)
        let green = Int(rgb.greenComponent * 255)
        let blue = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Create an NSColor from a hex string.
    convenience init?(hex: String) {
        var cleanedHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove `#` if present
        if cleanedHex.hasPrefix("#") {
            cleanedHex.removeFirst()
        }

        guard cleanedHex.count == 6 || cleanedHex.count == 8 else { return nil }

        let scanner = Scanner(string: cleanedHex)
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber) else { return nil }

        let red, green, blue, alpha: CGFloat
        if cleanedHex.count == 8 {
            alpha = CGFloat((hexNumber & 0xFF000000) >> 24) / 255
            red   = CGFloat((hexNumber & 0x00FF0000) >> 16) / 255
            green = CGFloat((hexNumber & 0x0000FF00) >> 8) / 255
            blue  = CGFloat(hexNumber & 0x000000FF) / 255
        } else { // 6 characters
            alpha = 1.0
            red   = CGFloat((hexNumber & 0xFF0000) >> 16) / 255
            green = CGFloat((hexNumber & 0x00FF00) >> 8) / 255
            blue  = CGFloat(hexNumber & 0x0000FF) / 255
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }
}

// MARK: Ghostty Types
#if !DOCK_TILE_PLUGIN
extension NSColor {
    /// Create a color from a Ghostty color.
    convenience init(ghostty: ghostty_config_color_s) {
        let red = Double(ghostty.r) / 255
        let green = Double(ghostty.g) / 255
        let blue = Double(ghostty.b) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
