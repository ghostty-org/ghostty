import SwiftUI

/// The Claude mark, tinted for the active theme.
///
/// The asset is a template image, so the single flat fill of the original
/// artwork is reproduced by tinting rather than by shipping a second
/// colored copy: dark themes get a light tint so the mark stays legible,
/// light themes get the artwork's own clay color.
struct ClaudeIcon: View {
    /// Which tint the mark takes.
    enum Tint {
        /// Follows the terminal theme: legible on dark, the artwork's own
        /// color on light. For anything drawn over a themed surface.
        case theme

        /// Always the artwork's own color. For surfaces that follow the
        /// system appearance rather than the terminal theme — the settings
        /// window, for one.
        case original
    }

    var size: CGFloat = 12
    var tint: Tint = .theme

    @ObservedObject private var themePalette: ThemePalette = .shared

    /// The artwork's own fill.
    private static let claySwatch = Color(
        .sRGB,
        red: 0xd9 / 255,
        green: 0x77 / 255,
        blue: 0x57 / 255
    )

    private var color: Color {
        switch tint {
        case .original:
            return Self.claySwatch
        case .theme:
            let isLight = themePalette.background?.isLightColor ?? false
            return isLight ? Self.claySwatch : Color.white
        }
    }

    var body: some View {
        Image("ClaudeIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
