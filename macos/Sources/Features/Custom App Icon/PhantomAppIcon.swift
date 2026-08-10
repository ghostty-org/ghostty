import AppKit

/// The app icons Phantom ships, and which one is in use.
///
/// Separate from Ghostty's `AppIcon`, which is driven by its own config file
/// (`macos-icon`) and by a colourizer for the ghost artwork. This is Phantom's
/// own set: whole images, chosen in Settings, remembered in `UserDefaults`.
/// Keeping it apart also keeps it out of `GuiConfigStore` — an unknown key in
/// there raises Ghostty's "Configuration Errors" window.
///
/// **Adding one is two steps.** Drop a PNG into
/// `Assets.xcassets/Phantom Icons/<Name>.imageset` and add a case whose raw
/// value is that name. The raw value *is* the asset name, so there is no second
/// list to keep in step, and `allCases` drives the picker, the About animation
/// and everything else.
enum PhantomAppIcon: String, CaseIterable, Identifiable, Codable, Sendable {
    case phantom = "Phantom"
    case dark = "Phantom Dark"
    case light = "Phantom Light"
    case black = "Phantom Black"
    case spectre = "Phantom Spectre"
    case nebula = "Phantom Nebula"
    case bullsEye = "Phantom Bulls Eye"
    case pcbDark = "Phantom PCB Dark"
    case pcbLight = "Phantom PCB Light"

    case tribute = "Phantom Ghostty Tribute"
    case tributeDark = "Phantom Dark Ghostty Tribute"
    case tributeLight = "Phantom Light Ghostty Tribute"
    case tributeBlack = "Phantom Black Ghostty Tribute"
    case tributeSpectre = "Phantom Spectre Ghostty Tribute"
    case tributeNebula = "Phantom Nebula Ghostty Tribute"
    case tributeBullsEye = "Phantom Bulls Eye Ghostty Tribute"
    case tributePCBDark = "Phantom PCB Dark Ghostty Tribute"
    case tributePCBLight = "Phantom PCB Light Ghostty Tribute"

    var id: String { rawValue }

    /// The asset name, which is the raw value by construction.
    var assetName: String { rawValue }

    /// Which group the picker shows it under.
    enum Family: String, CaseIterable, Identifiable {
        case phantom
        case ghosttyTribute

        var id: String { rawValue }

        var title: String {
            switch self {
            case .phantom: return "Phantom"
            case .ghosttyTribute: return "Ghostty Tribute"
            }
        }
    }

    /// The suffix that marks a tribute, and the whole of how families are
    /// decided.
    ///
    /// Read from the name rather than declared per case, so adding a tribute
    /// icon needs nothing beyond the case itself — there is no third list to
    /// fall out of step with the assets and the enum.
    static let tributeSuffix = " Ghostty Tribute"

    var family: Family {
        rawValue.hasSuffix(Self.tributeSuffix) ? .ghosttyTribute : .phantom
    }

    /// What the picker calls it: the name with the product prefix and the
    /// family suffix taken off, since every entry in a section repeats both and
    /// a column of "Phantom … Ghostty Tribute" is all noise and no information.
    var title: String {
        var name = rawValue
        if name.hasSuffix(Self.tributeSuffix) {
            name = String(name.dropLast(Self.tributeSuffix.count))
        }
        let prefix = "Phantom"
        if name == prefix { return "Default" }
        if name.hasPrefix(prefix + " ") {
            name = String(name.dropFirst(prefix.count + 1))
        }
        return name.isEmpty ? "Default" : name
    }

    /// The icons in one family, in declaration order.
    static func all(in family: Family) -> [PhantomAppIcon] {
        allCases.filter { $0.family == family }
    }

    /// The one the app is built with, and what "reset" means.
    static let `default`: PhantomAppIcon = .phantom

    func image() -> NSImage? {
        NSImage(named: assetName)
    }
}

/// Reads and writes the chosen icon, and applies it to the running app.
///
/// **Two different icons, and both have to be set.** `NSWorkspace.setIcon`
/// writes the *file's* icon — what Finder shows for the bundle, and what the
/// Dock reads the next time the app is launched. The Dock tile of an app that
/// is *already running* comes from `NSApp.applicationIconImage` instead.
/// Setting only the first is why the choice used to appear on the next launch
/// and not on the click.
///
/// The default is expressed by passing `nil` to both: that *removes* the
/// override and lets the icon compiled into the app show through, rather than
/// writing a copy of it over itself.
@MainActor
enum PhantomAppIconStore {
    static let defaultsKey = "PhantomAppIcon"

    /// Posted after the icon changes, so anything showing it can catch up.
    static let didChangeNotification = Notification.Name("PhantomAppIconDidChange")

    static var current: PhantomAppIcon {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIcon.init(rawValue:)) ?? .default
    }

    /// Applies an icon and remembers it.
    @discardableResult
    static func apply(_ icon: PhantomAppIcon) -> Bool {
        UserDefaults.standard.set(icon.rawValue, forKey: defaultsKey)

        // The override image, or nil to fall back to what was compiled in.
        let override = icon == .default ? nil : icon.image()

        // The running app's Dock tile and ⌘⇥ entry, which change immediately.
        NSApp.applicationIconImage = override

        // And the bundle on disk, so Finder agrees and the next launch starts
        // out right.
        let applied = NSWorkspace.shared.setIcon(override, forFile: Bundle.main.bundlePath)
        // Finder caches icons aggressively; without this the Dock updates and
        // the bundle in a window does not.
        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)

        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return applied
    }

    /// Re-applies the remembered choice at launch.
    ///
    /// Needed because `setIcon` writes to the bundle, and a rebuild replaces
    /// the bundle — so a fresh build comes up wearing the compiled-in icon
    /// even though a different one was chosen.
    static func restore() {
        let icon = current
        guard icon != .default else { return }
        apply(icon)
    }
}
