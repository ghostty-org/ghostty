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
            .interfaceFont()
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

    /// Applies just the interface font override, without the tint and
    /// window-appearance parts of `themedChrome()`. The main terminal
    /// window already manages its own appearance and tint elsewhere
    /// (`TerminalWindow.syncAppearance`, the sidebar's own accent handling);
    /// its sidebar chrome only needs the font piece.
    func interfaceFont() -> some View {
        modifier(InterfaceFontModifier())
    }
}

private struct InterfaceFontModifier: ViewModifier {
    @AppStorage(AppFont.interfaceFamilyKey) private var interfaceFamily = ""

    func body(content: Content) -> some View {
        content.font(AppFont.interfaceFont(family: interfaceFamily))
    }
}

/// Phantom's own interface font — distinct from `font-family`, which is the
/// terminal's. This isn't a Ghostty core concept, so it can't live in
/// `GuiConfigStore`: that store's values are written straight into
/// `gui-settings`, which the core loads as config, and a key it doesn't
/// recognize surfaces as a "Configuration Errors" popup. `UserDefaults` is
/// where other Phantom-only chrome preferences already live (the sidebar
/// divider mode).
///
/// Empty means "system default." A custom family is applied at
/// `NSFont.systemFontSize` — matching the type size most unstyled text in
/// these windows already renders at — rather than tied to a text style, so
/// controls that already pin their own size (captions, titles) keep it and
/// only the chrome that inherits the environment default picks up the
/// family. A full swap of every explicit size in these windows would be a
/// much larger change than a font field calls for.
enum AppFont {
    static let interfaceFamilyKey = "AppInterfaceFontFamily"

    static func interfaceFont(family: String) -> Font? {
        family.isEmpty ? nil : .custom(family, size: NSFont.systemFontSize)
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
