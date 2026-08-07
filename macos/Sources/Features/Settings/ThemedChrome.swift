import AppKit
import SwiftUI

/// Puts Phantom's own windows under the terminal theme.
///
/// Settings, the theme browser and the editor followed the system light/dark
/// setting and the system accent, so a dark theme could sit behind a light
/// settings window and a selection there was a different colour from the
/// same selection in the sidebar. The theme is the app's palette, not just
/// the terminal's, so these windows take their chrome and tint from it.
struct ThemedChrome<Content: View>: View {
    @ObservedObject private var palette: ThemePalette = .shared

    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .tint(palette.accent)
            .background(
                WindowAppearance(isLight: palette.isLightBackground)
                    .frame(width: 0, height: 0)
            )
    }
}

extension View {
    /// Wraps this view so the window hosting it follows the terminal theme.
    func themedChrome() -> some View {
        ThemedChrome { self }
    }
}

/// Reaches the hosting window to set its appearance. A window's appearance
/// isn't expressible in SwiftUI, and setting it on the controller would miss
/// theme changes made while the window is open.
private struct WindowAppearance: NSViewRepresentable {
    let isLight: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let name: NSAppearance.Name = isLight ? .aqua : .darkAqua
        // Deferred: during an update pass the view may not be in a window
        // yet, and assigning appearance re-enters layout.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            guard window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }
}
