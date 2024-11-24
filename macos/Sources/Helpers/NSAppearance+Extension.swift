import Cocoa

extension NSAppearance {
    /// Returns true if the appearance is some kind of dark.
    var isDark: Bool {
        return name.rawValue.lowercased().contains("dark")
    }
}
