import SwiftUI

/// The git mark, wherever the sidebar refers to git.
///
/// A template image, so it takes whatever `foregroundStyle` is in effect
/// instead of the artwork's own orange — the sidebar's icons are a
/// monochrome set that follows the terminal theme, and one branded orange
/// glyph among them reads as a mistake.
struct GitIcon: View {
    var size: CGFloat = 12

    var body: some View {
        Image("GitIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
