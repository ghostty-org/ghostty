import Cocoa

extension NSAppearance {
    /// Returns true if the appearance is some kind of dark.
    var isDark: Bool {
        return name.rawValue.lowercased().contains("dark")
    }

    /// Initialize a desired NSAppearance for the Ghostty configuration.
    convenience init?(ghosttyConfig config: Ghostty.Config) {
        guard let theme = config.windowTheme else { return nil }
        switch (theme) {
        case "dark":
            self.init(named: .darkAqua)

        case "light":
            self.init(named: .aqua)

        case "auto":
            let color = OSColor(config.backgroundColor)
            if color.isLightColor {
                self.init(named: .aqua)
            } else {
                self.init(named: .darkAqua)
            }

        default:
            return nil
        }
    }
}
