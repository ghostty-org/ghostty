import AppKit

/// What the highlighter recognizes.
///
/// Deliberately small. These are the distinctions a terminal palette can
/// actually express — sixteen colors, of which a handful read as different
/// at a glance — so a richer set would be invented precision that nothing
/// downstream could show.
enum TokenKind: String, CaseIterable, Equatable, Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case attribute
    case punctuation
}

/// The colors a code view paints with.
///
/// A plain value on purpose: the engine must never reach for the app's
/// theme singleton. The host builds one of these from whatever it calls a
/// theme and hands it over, which is what lets this whole directory move
/// into a package later without dragging Phantom behind it.
struct CodeTheme: Equatable {
    var foreground: NSColor
    var background: NSColor
    var tokens: [TokenKind: NSColor]

    /// The gutter's digits, and the rule between gutter and text.
    var lineNumber: NSColor
    var currentLineNumber: NSColor
    var currentLineBackground: NSColor?

    func color(for kind: TokenKind) -> NSColor {
        tokens[kind] ?? foreground
    }

    /// The colours brackets cycle through, by nesting depth.
    ///
    /// Borrowed from the token colours rather than added to the theme: a
    /// terminal theme has sixteen colours and no notion of a bracket, so
    /// inventing three more would mean inventing them out of nothing. These
    /// three are far enough apart to tell at a glance and are already in the
    /// palette the reader chose.
    var bracketColors: [NSColor] {
        [
            color(for: .number),
            color(for: .keyword),
            color(for: .type),
        ]
    }

    /// A neutral theme, used before a host supplies one and by the tests.
    static var fallback: CodeTheme {
        CodeTheme(
            foreground: .textColor,
            background: .textBackgroundColor,
            tokens: [
                .keyword: .systemPurple,
                .string: .systemGreen,
                .comment: .secondaryLabelColor,
                .number: .systemOrange,
                .type: .systemTeal,
                .function: .systemBlue,
                .attribute: .systemPink,
                .punctuation: .secondaryLabelColor,
            ],
            lineNumber: .tertiaryLabelColor,
            currentLineNumber: .secondaryLabelColor,
            currentLineBackground: nil
        )
    }
}

/// How the code view behaves: everything a preferences screen would drive.
///
/// Also a value, for the same reason as `CodeTheme` — the engine reads no
/// `UserDefaults` of its own.
struct CodeEditorConfiguration: Equatable {
    var font: NSFont
    var showsLineNumbers: Bool
    var wrapsLines: Bool

    /// Spaces a tab is drawn as. Only affects display; what gets typed is
    /// decided by `insertsSpacesForTab`.
    var tabWidth: Int
    var insertsSpacesForTab: Bool
    var highlightsCurrentLine: Bool

    /// Whether brackets are coloured by nesting depth.
    var colorsBracketPairs: Bool = true

    /// Whether the minimap is drawn beside the text.
    ///
    /// Part of the configuration rather than a property of its own, so that
    /// turning it off in Settings is a change the appearance pass *notices*.
    /// As a separate value it was only read when the view was first made, and
    /// the switch did nothing until the file was reopened.
    var showsMinimap: Bool = true

    static var `default`: CodeEditorConfiguration {
        CodeEditorConfiguration(
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            showsLineNumbers: true,
            wrapsLines: false,
            tabWidth: 4,
            insertsSpacesForTab: true,
            highlightsCurrentLine: true,
            colorsBracketPairs: true,
            showsMinimap: true
        )
    }
}
