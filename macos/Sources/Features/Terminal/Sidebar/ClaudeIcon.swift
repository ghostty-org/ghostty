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
        /// The same neutral secondary color as the plain SF Symbol icons
        /// it sits beside in a chrome row (the sidebar's titlebar icons, a
        /// group header's action buttons) — so it reads as one more icon
        /// in that row rather than a colored outlier.
        case theme

        /// Always the artwork's own color. For surfaces that follow the
        /// system appearance rather than the terminal theme — the settings
        /// window, for one.
        case original
    }

    var size: CGFloat = 12
    var tint: Tint = .theme

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
            return .secondary
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
