import AppKit
import SwiftUI

/// Turns the terminal's palette into editor colors.
///
/// This is the whole meaning of "syntax highlighting from the active
/// theme". A terminal theme is **sixteen ANSI colors and a background** —
/// it has no notion of a keyword or a string, so somebody has to decide
/// which slot each one borrows. That decision is here, and it follows what
/// terminal editors have always done, which is why the result looks like it
/// belongs in this app rather than like a web editor dropped into it.
enum EditorTheme {
    /// ANSI indices, by their conventional names.
    private enum ANSI {
        static let red = 1
        static let green = 2
        static let yellow = 3
        static let blue = 4
        static let magenta = 5
        static let cyan = 6
        static let brightBlack = 8
    }

    /// The mapping, kept as data so the reasoning is inspectable and the
    /// tests can assert it.
    ///
    /// Comment takes bright black because that is the one slot every theme
    /// makes deliberately dim; string takes green and keyword magenta
    /// because that pairing is what `vim` and every 16-color scheme has
    /// used for decades, so it reads as familiar rather than invented.
    static let ansiSlots: [TokenKind: Int] = [
        .keyword: ANSI.magenta,
        .string: ANSI.green,
        .comment: ANSI.brightBlack,
        .number: ANSI.yellow,
        .type: ANSI.cyan,
        .function: ANSI.blue,
        .attribute: ANSI.red,
        .punctuation: ANSI.brightBlack,
    ]

    @MainActor
    static func make(from palette: ThemePalette) -> CodeTheme {
        make(colors: palette.colors, background: palette.background)
    }

    /// The pure half, so the mapping can be tested against a palette that
    /// isn't the running app's.
    ///
    /// A theme with fewer than sixteen colors — or none at all, before the
    /// config has loaded — falls back rather than reaching past the end of
    /// the array. Highlighting that is briefly plain is a great deal better
    /// than a crash on launch.
    static func make(colors: [NSColor], background: NSColor?) -> CodeTheme {
        guard colors.count >= 16 else { return .fallback }

        let backgroundColor = background ?? .textBackgroundColor
        let foreground = colors[7]

        var tokens: [TokenKind: NSColor] = [:]
        for (kind, slot) in ansiSlots {
            tokens[kind] = colors[slot]
        }
        tokens[.plain] = foreground

        return CodeTheme(
            foreground: foreground,
            background: backgroundColor,
            tokens: tokens,
            lineNumber: colors[ANSI.brightBlack],
            currentLineNumber: foreground,
            currentLineBackground: foreground.withAlphaComponent(0.06)
        )
    }
}

/// Where the editor's preferences live, and their defaults.
///
/// `UserDefaults` rather than `GuiConfigStore`: an unknown key in
/// `gui-settings` makes Ghostty's own core raise a "Configuration Errors"
/// popup, so everything Phantom adds has to stay out of it.
enum EditorSettings {
    static let fontSizeKey = "EditorFontSize"
    static let fontFamilyKey = "EditorFontFamily"
    static let wrapsLinesKey = "EditorWrapsLines"
    static let showsLineNumbersKey = "EditorShowsLineNumbers"
    static let tabWidthKey = "EditorTabWidth"

    static let defaultFontSize = 12.0
    static let defaultTabWidth = 4

    /// The editor's own font if one is set, else the interface family, else
    /// the system monospace.
    ///
    /// Falls back whenever the named family fails to produce a font, which
    /// is what happens when a font is uninstalled after being chosen — the
    /// editor should keep working, not come up blank.
    static func font(size: Double, family: String) -> NSFont {
        let chosen = UserDefaults.standard.string(forKey: fontFamilyKey) ?? ""
        let name = chosen.isEmpty ? family : chosen

        if !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
