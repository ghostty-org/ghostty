import AppKit
import System

#if !DOCK_TILE_PLUGIN
import GhosttyKit
#endif

extension Ghostty {
    /// For DockTilePlugin to generate icon
    /// without relying on ``Ghostty/Ghostty/Config``
    enum CustomAppIcon: Equatable, Codable {
        case official
        case blueprint
        case chalkboard
        case glass
        case holographic
        case microchip
        case paper
        case retro
        case xray
        /// Save image data to avoid sandboxing issues
        case custom(fileData: Data)
        case customStyle(ghostColorHex: String, screenColorHexes: [String], iconFrame: Ghostty.MacOSIconFrame)

        /// Restore the icon from previously saved values
        init?(string: String) {
            switch string {
            case MacOSIcon.official.rawValue:
                self = .official
            case MacOSIcon.blueprint.rawValue:
                self = .blueprint
            case MacOSIcon.chalkboard.rawValue:
                self = .chalkboard
            case MacOSIcon.glass.rawValue:
                self = .glass
            case MacOSIcon.holographic.rawValue:
                self = .holographic
            case MacOSIcon.microchip.rawValue:
                self = .microchip
            case MacOSIcon.paper.rawValue:
                self = .paper
            case MacOSIcon.retro.rawValue:
                self = .retro
            case MacOSIcon.xray.rawValue:
                self = .xray
            default:
                /*
                 let colorStrings = ([ghostColor] + screenColors).compactMap(\.hexString)
                 appIconName = (colorStrings + [config.macosIconFrame.rawValue])
                     .joined(separator: "_")
                 */
                var parts = string.split(separator: "_").map(String.init)
                if
                    let _ = parts.first.flatMap(NSColor.init(hex:)),
                    let frame = parts.last.flatMap(Ghostty.MacOSIconFrame.init(rawValue:))
                {
                    let ghostC = parts.removeFirst()
                    _ = parts.removeLast()
                    self = .customStyle(
                        ghostColorHex: ghostC,
                        screenColorHexes: parts,
                        iconFrame: frame
                    )
                } else {
                    // Due to sandboxing with `com.apple.dock.external.extra.arm64`,
                    // we can’t restore custom icon file automatically.
                    // The user must open the app to update it.
                    return nil
                }
            }
        }

        func image(in bundle: Bundle) -> NSImage? {
            switch self {
            case .official:
                return nil
            case .blueprint:
                return bundle.image(forResource: "BlueprintImage")!
            case .chalkboard:
                return bundle.image(forResource: "ChalkboardImage")!
            case .glass:
                return bundle.image(forResource: "GlassImage")!
            case .holographic:
                return bundle.image(forResource: "HolographicImage")!
            case .microchip:
                return bundle.image(forResource: "MicrochipImage")!
            case .paper:
                return bundle.image(forResource: "PaperImage")!
            case .retro:
                return bundle.image(forResource: "RetroImage")!
            case .xray:
                return bundle.image(forResource: "XrayImage")!
            case let .custom(file):
                if let userIcon = NSImage(data: file) {
                    return userIcon
                } else {
                    return nil
                }
            case let .customStyle(ghostColorHex, screenColorHexes, macosIconFrame):
                let screenColors = screenColorHexes.compactMap(NSColor.init(hex:))
                guard
                    let ghostColor = NSColor(hex: ghostColorHex),
                    let icon = ColorizedGhosttyIcon(
                        screenColors: screenColors,
                        ghostColor: ghostColor,
                        frame: macosIconFrame
                    ).makeImage(in: bundle)
                else {
                    return nil
                }
                return icon
            }
        }
    }
}

#if !DOCK_TILE_PLUGIN
extension Ghostty.CustomAppIcon {
    init?(config: Ghostty.Config) {
        switch config.macosIcon {
        case .official:
            return nil
        case .blueprint:
            self = .blueprint
        case .chalkboard:
            self = .chalkboard
        case .glass:
            self = .glass
        case .holographic:
            self = .holographic
        case .microchip:
            self = .microchip
        case .paper:
            self = .paper
        case .retro:
            self = .retro
        case .xray:
            self = .xray
        case .custom:
            if let data = try? Data(contentsOf: URL(filePath: config.macosCustomIcon, relativeTo: nil)) {
                self = .custom(fileData: data)
            } else {
                return nil
            }
        case .customStyle:
            // Discard saved icon name
            // if no valid colours were found
            guard
                let ghostColor = config.macosIconGhostColor?.hexString,
                let screenColors = config.macosIconScreenColor?.compactMap(\.hexString)
            else {
                return nil
            }
            self = .customStyle(ghostColorHex: ghostColor, screenColorHexes: screenColors, iconFrame: config.macosIconFrame)
        }
    }
}
#endif

extension UserDefaults {
    var appIcon: Ghostty.CustomAppIcon? {
        get {
            defer {
                removeObject(forKey: "CustomGhosttyIcon")
            }
            if let previous = string(forKey: "CustomGhosttyIcon"), let newIcon = Ghostty.CustomAppIcon(string: previous) {
                // update new storage once
                self.appIcon = newIcon
                return newIcon
            }
            guard let data = data(forKey: "NewCustomGhosttyIcon") else {
                return nil
            }
            return try? JSONDecoder().decode(Ghostty.CustomAppIcon.self, from: data)
        }
        set {
            guard let newData = try? JSONEncoder().encode(newValue) else {
                return
            }
            set(newData, forKey: "NewCustomGhosttyIcon")
        }
    }
}

extension Ghostty.Notification {
    static let ghosttyIconDidChange = Notification.Name("com.mitchellh.ghostty.iconDidChange")
}
