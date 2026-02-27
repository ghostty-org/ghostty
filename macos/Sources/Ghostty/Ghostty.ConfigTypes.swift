// This file contains the configuration types for Ghostty so that alternate targets
// can get typed information without depending on all the dependencies of GhosttyKit.

extension Ghostty {
    /// macos-icon
    enum MacOSIcon: String, Sendable {
        case official
        case blueprint
        case chalkboard
        case glass
        case holographic
        case microchip
        case paper
        case retro
        case xray
        case custom
        case customStyle = "custom-style"

        /// Bundled asset name for built-in icons
        var assetName: String? {
            switch self {
            case .official: return nil
            case .blueprint: return "BlueprintImage"
            case .chalkboard: return "ChalkboardImage"
            case .microchip: return "MicrochipImage"
            case .glass: return "GlassImage"
            case .holographic: return "HolographicImage"
            case .paper: return "PaperImage"
            case .retro: return "RetroImage"
            case .xray: return "XrayImage"
            case .custom, .customStyle: return nil
            }
        }
    }

    /// macos-icon-frame
    enum MacOSIconFrame: String, Codable {
        case aluminum
        case beige
        case plastic
        case chrome
    }
}
