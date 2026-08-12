import AppKit

/// Which rendering of an app icon to use.
///
/// macOS 26 draws an app icon in one of four styles, and the choice is
/// normally the *system's*: System Settings › Appearance has an icon-and-widget
/// style control, and every app's icon follows it. There is no Apple pattern
/// for an app offering this itself, because Apple made it a global setting
/// rather than a per-app one.
///
/// Phantom offers it anyway, deliberately: this fork's icon is a personal
/// choice rather than a brand, and picking "the clear one" for it alone is a
/// reasonable thing to want. It is exposed as a plain segmented control,
/// which is the standard macOS control for a small set of exclusive options.
/// Icon Composer also renders a *tinted* style, which is deliberately not
/// offered: it washed the ghost out to the point of being hard to tell the
/// icons apart, and an option nobody would pick is just a wider control.
enum PhantomAppIconVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "Default"
    case dark = "Dark"
    case clear = "Clear"

    var id: String { rawValue }

    /// What the segmented control shows.
    var title: String { rawValue }

    /// Whether this style has separate light and dark renderings.
    ///
    /// `Default` and `Dark` are already answers to "which appearance" —
    /// `Default` *is* the light one. `Clear` is a material, drawn differently
    /// in light and dark, so it follows the system while the other two
    /// override it.
    var followsSystemAppearance: Bool {
        switch self {
        case .standard, .dark: return false
        case .clear: return true
        }
    }

    /// The suffix Icon Composer's export uses for this style, given whether
    /// the system is currently in dark mode.
    func fileSuffix(isDark: Bool) -> String {
        switch self {
        case .standard: return "Default"
        case .dark: return "Dark"
        case .clear: return isDark ? "ClearDark" : "ClearLight"
        }
    }

    /// The default, which is also what the app is compiled with.
    static let `default`: PhantomAppIconVariant = .standard
}

/// Reads and writes the chosen variant.
///
/// Its own key, separate from the icon's: the two are independent choices —
/// changing icon keeps the style, and changing style keeps the icon.
@MainActor
enum PhantomAppIconVariantStore {
    static let defaultsKey = "PhantomAppIconVariant"

    static var current: PhantomAppIconVariant {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIconVariant.init(rawValue:)) ?? .default
    }

    static func set(_ variant: PhantomAppIconVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: defaultsKey)
    }

    /// Whether the system is drawing in dark mode right now, for the two
    /// styles that follow it.
    static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
