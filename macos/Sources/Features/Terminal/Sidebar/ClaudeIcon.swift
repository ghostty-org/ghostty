import SwiftUI

/// The Claude mark, tinted for the active theme.
///
/// The asset is a template image, so the single flat fill of the original
/// artwork is reproduced by tinting rather than by shipping a second
/// colored copy: dark themes get a light tint so the mark stays legible,
/// light themes get the artwork's own clay color.
struct ClaudeIcon: View {
    var size: CGFloat = 12

    @ObservedObject private var themePalette: ThemePalette = .shared

    /// The artwork's own fill.
    private static let claySwatch = Color(
        .sRGB,
        red: 0xd9 / 255,
        green: 0x77 / 255,
        blue: 0x57 / 255
    )

    private var isLightTheme: Bool {
        themePalette.background?.isLightColor ?? false
    }

    var body: some View {
        Image("ClaudeIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(isLightTheme ? Self.claySwatch : Color.white)
    }
}
