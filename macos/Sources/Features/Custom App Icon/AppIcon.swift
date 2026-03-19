import AppKit
import System

/// The icon style for the Ghostty App.
enum AppIcon: Equatable, Codable {
    case official
    case blueprint
    case chalkboard
    case glass
    case holographic
    case microchip
    case paper
    case retro
    case xray
    /// Save full image data to avoid sandboxing issues
    case custom(_ iconFile: Data)
    case customStyle(_ icon: ColorizedGhosttyIcon)

#if !DOCK_TILE_PLUGIN
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
                self = .custom(data)
            } else {
                return nil
            }
        case .customStyle:
            // Discard saved icon name
            // if no valid colours were found
            guard
                let ghostColor = config.macosIconGhostColor,
                let screenColors = config.macosIconScreenColor
            else {
                return nil
            }
            self = .customStyle(ColorizedGhosttyIcon(screenColors: screenColors, ghostColor: ghostColor, frame: config.macosIconFrame))
        }
    }
#endif

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
            return NSImage(data: file)
        case let .customStyle(customIcon):
            return customIcon.makeImage(in: bundle)
        }
    }
}
