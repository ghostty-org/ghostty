import Foundation

extension OSColor {
    var isLightColor: Bool {
        return self.luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed:green:blue:alpha requires sRGB space
        #if canImport(AppKit)
        guard let rgb = self.usingColorSpace(.sRGB) else { return 0 }
        #else
        let rgb = self
        #endif
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    var hexString: String? {
#if canImport(AppKit)
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(rgb.redComponent * 255)
        let green = Int(rgb.greenComponent * 255)
        let blue = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
#elseif canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard self.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        // Convert to 0–255 range
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)

        // Format to hexadecimal
        return String(format: "#%02X%02X%02X", r, g, b)
#endif
    }

    func darken(by amount: CGFloat) -> OSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return OSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }
}
