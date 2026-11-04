import AppKit

extension NSColor {
    /// Using a color list let's us get localized names.
    private static let appleColorList: NSColorList? = NSColorList(named: "Apple")

    convenience init?(named name: String) {
        guard let colorList = Self.appleColorList,
              let color = colorList.color(withKey: name.capitalized) else {
            return nil
        }
        guard let components = color.usingColorSpace(.sRGB) else {
            return nil
        }
        self.init(
            red: components.redComponent,
            green: components.greenComponent,
            blue: components.blueComponent,
            alpha: components.alphaComponent
        )
    }

    static var colorNames: [String] {
        appleColorList?.allKeys.map { $0.lowercased() } ?? []
    }

    /// Calculates the perceptual distance to another color in RGB space.
    func distance(to other: NSColor) -> Double {
        guard let a = self.usingColorSpace(.sRGB),
              let b = other.usingColorSpace(.sRGB) else { return .infinity }

        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent

        // Weighted Euclidean distance (human eye is more sensitive to green)
        return sqrt(2 * dr * dr + 4 * dg * dg + 3 * db * db)
    }
}
