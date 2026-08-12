import AppKit

/// The app icons Phantom ships, and which one is in use.
///
/// Separate from Ghostty's `AppIcon`, which is driven by its own config file
/// (`macos-icon`) and by a colourizer for the ghost artwork. This is Phantom's
/// own set: whole images, chosen in Settings, remembered in `UserDefaults`.
/// Keeping it apart also keeps it out of `GuiConfigStore` — an unknown key in
/// there raises Ghostty's "Configuration Errors" window.
///
/// Every icon here is drawn by Icon Composer — a glyph plus the Liquid Glass
/// material and per-appearance variants it renders around one — not artwork
/// Phantom composes itself. The `.icon` documents are kept in
/// `images/PhantomIcons/` as the source of truth, and their rendered
/// exports live in `macos/Resources/PhantomIconVariants/` as
/// `<Icon>-<Style>.png`.
///
/// **Why exports rather than the `.icon` documents themselves**, which would
/// be the obvious thing: the Icon Composer pipeline renders exactly *one*
/// icon per app bundle — the one named by `ASSETCATALOG_COMPILER_APPICON_NAME`.
/// `actool` accepts every other `.icon` in the project as an input without
/// complaint and materialises none of them: no `.icns`, no catalog entry, no
/// generated symbol. There is no runtime API that renders a `.icon` either,
/// and `NSApp.applicationIconImage`/`NSWorkspace.setIcon` — the only way to
/// change a running app's icon — take an `NSImage` and nothing else. So a
/// chooser with more than one icon in it has to be built from renders, and
/// these come from Icon Composer's own export rather than from anything
/// Phantom approximates.
///
/// `productionDefault` is the exception and keeps the real thing: it *is* the
/// compiled-in icon, so it needs no override and gets the live material,
/// including following the system's own appearance.
///
/// **Adding one is three steps.** Put the `.icon` in `images/PhantomIcons/`,
/// export its variants into `macos/Resources/PhantomIconVariants/` following
/// the `<Icon>-<Style>.png` naming, and add a case whose raw value is the
/// icon's name. The raw value *is* the file-name stem, so there is no second
/// list to keep in step, and `allCases` drives the picker, the About
/// animation, and everything else.
enum PhantomAppIcon: String, CaseIterable, Identifiable, Codable, Sendable {
    case bullsEye = "Bulls Eye"
    case circuits = "Circuits"
    case standard = "Default"
    case development = "Development"
    case fractalNoise = "Fractal Noise"
    case nebula = "Nebula"
    case purpleHaze = "Purple Haze"

    case tributeBullsEye = "Ghostty Tribute Bulls Eye"
    case tributeCircuits = "Ghostty Tribute Circuits"
    case tributeStandard = "Ghostty Tribute Default"
    case tributeDevelopment = "Ghostty Tribute Development"
    case tributeFractalNoise = "Ghostty Tribute Fractal Noise"
    case tributeNebula = "Ghostty Tribute Nebula"
    case tributePurpleHaze = "Ghostty Tribute Purple Haze"

    var id: String { rawValue }

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

    /// The prefix that marks a tribute, and the whole of how families are
    /// decided.
    ///
    /// Read from the name rather than declared per case, so adding a tribute
    /// icon needs nothing beyond the case itself — there is no third list to
    /// fall out of step with the assets and the enum.
    static let tributePrefix = "Ghostty Tribute "

    var family: Family {
        rawValue.hasPrefix(Self.tributePrefix) ? .ghosttyTribute : .phantom
    }

    /// What the picker calls it: the name with the family prefix taken off,
    /// since the section header already says it and repeating it in every
    /// row is noise, not information.
    var title: String {
        rawValue.hasPrefix(Self.tributePrefix)
            ? String(rawValue.dropFirst(Self.tributePrefix.count))
            : rawValue
    }

    /// The icons in one family, in declaration order.
    static func all(in family: Family) -> [PhantomAppIcon] {
        allCases.filter { $0.family == family }
    }

    /// The one the app is actually compiled against, and so the one value
    /// `apply(_:)` can skip writing an override for — it is already what is on
    /// disk.
    ///
    /// Its source is `images/PhantomAppIcon.icon`, which carries the same
    /// artwork as this case; the name differs because the app icon is
    /// selected by the `ASSETCATALOG_COMPILER_APPICON_NAME` build setting,
    /// and pointing that at a file called `Default` would read as a
    /// placeholder rather than a choice.
    static let productionDefault: PhantomAppIcon = .standard

    /// What a build with nothing chosen yet falls back to.
    ///
    /// A local build falls back to `.development`, so it reads as a local
    /// build from the Dock alone — before Settings has even been opened once.
    /// This only decides the *fallback*; picking anything else still sticks
    /// exactly like it does in a release build. See
    /// `PhantomAppIconStore.seedDevelopmentDefaultIfNeeded` for how a fresh
    /// dev environment ends up with that fallback actually persisted rather
    /// than merely computed.
    static var `default`: PhantomAppIcon {
        DevelopmentBuild.isActive ? .development : .productionDefault
    }

    /// Where the rendered exports are bundled.
    static let variantsDirectory = "PhantomIconVariants"

    /// This icon in one style, as Icon Composer exported it.
    func image(variant: PhantomAppIconVariant, isDark: Bool) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: "\(rawValue)-\(variant.fileSuffix(isDark: isDark))",
            withExtension: "png",
            subdirectory: Self.variantsDirectory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// This icon in the style currently chosen — what the picker draws and
    /// what gets applied.
    @MainActor
    func image() -> NSImage? {
        image(
            variant: PhantomAppIconVariantStore.current,
            isDark: PhantomAppIconVariantStore.isDarkAppearance
        )
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
/// The default icon in its default style is expressed by passing `nil` to
/// both: that *removes* the override and lets the icon compiled into the app
/// show through, rather than writing a copy of it over itself. That pairing is
/// also the only one that gets the live Liquid Glass material and follows the
/// system's own appearance — every other choice is a rendered export, because
/// neither `setIcon` nor `applicationIconImage` accepts anything but an
/// `NSImage`.
@MainActor
enum PhantomAppIconStore {
    static let defaultsKey = "PhantomAppIcon"

    /// Posted after the icon changes, so anything showing it can catch up.
    static let didChangeNotification = Notification.Name("PhantomAppIconDidChange")

    static var current: PhantomAppIcon {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIcon.init(rawValue:)) ?? .default
    }

    /// Applies an icon and remembers it, keeping the chosen style.
    @discardableResult
    static func apply(_ icon: PhantomAppIcon) -> Bool {
        UserDefaults.standard.set(icon.rawValue, forKey: defaultsKey)
        return applyCurrent()
    }

    /// Applies a style and remembers it, keeping the chosen icon.
    @discardableResult
    static func apply(_ variant: PhantomAppIconVariant) -> Bool {
        PhantomAppIconVariantStore.set(variant)
        return applyCurrent()
    }

    /// Puts whatever is currently chosen — icon and style together — on the
    /// app.
    @discardableResult
    static func applyCurrent() -> Bool {
        let icon = current

        // No override for the compiled-in pairing: leaving it alone is what
        // keeps the live material rather than freezing a render over it.
        let isCompiledIn = icon == .productionDefault
            && PhantomAppIconVariantStore.current == .default
        let override = isCompiledIn ? nil : icon.image()

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
        seedDevelopmentDefaultIfNeeded()

        guard current != .productionDefault
            || PhantomAppIconVariantStore.current != .default
        else { return }
        applyCurrent()
    }

    /// A dev build with nothing chosen yet starts on the Development icon
    /// instead of wearing what a release would — so a local build is
    /// distinguishable from `/Applications`'s copy from the very first launch,
    /// before Settings has ever been opened.
    ///
    /// Seeds an explicit, *persisted* choice rather than only leaning on what
    /// `PhantomAppIcon.default` computes to: after this runs once,
    /// "Development" is a remembered pick like any other, so choosing a
    /// different icon later behaves exactly like it does in a release build —
    /// nothing here fights that choice on the next launch.
    ///
    /// Checked the same way `current` resolves a stored value — parsed, not
    /// just present — so a name left behind by a renamed or removed case reads
    /// as "nothing meaningfully chosen" rather than as an explicit pick this
    /// must not override.
    private static func seedDevelopmentDefaultIfNeeded() {
        let hasAKnownChoice = UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PhantomAppIcon.init(rawValue:)) != nil
        guard DevelopmentBuild.isActive, !hasAKnownChoice else { return }
        apply(.development)
    }
}
