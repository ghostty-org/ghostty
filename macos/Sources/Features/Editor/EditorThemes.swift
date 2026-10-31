import AppKit
import CodeEditSourceEditor
import GhosttyKit

extension EditorTheme {
    /// The workspace paints one backdrop for toolbar, gutter and text, so the
    /// editor's own background must stay transparent.
    ///
    /// This has to be an sRGB clear rather than `NSColor.clear`: the pinned
    /// editor derives minimap contrast from `background.brightnessComponent`,
    /// which raises for colors in the generic gray space that `.clear` uses.
    static var transparentBackground: NSColor {
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    }

    private static func color(_ hex: String, fallback: NSColor) -> NSColor {
        NSColor(hex: hex) ?? fallback
    }

    /// Themes describe text styling with `Attribute` values, which also carry
    /// bold/italic. OMG themes only ever select colors, so keep one adapter
    /// instead of repeating `Attribute(color:)` at every call site.
    fileprivate static func attribute(_ hex: String, fallback: NSColor) -> EditorTheme.Attribute {
        EditorTheme.Attribute(color: color(hex, fallback: fallback))
    }

    fileprivate static func attribute(_ color: NSColor) -> EditorTheme.Attribute {
        EditorTheme.Attribute(color: color)
    }

    /// The iconic Atom One Dark syntax highlighting theme.
    static var oneDark: EditorTheme {
        EditorTheme(
            text: attribute("#abb2bf", fallback: .textColor),
            insertionPoint: color("#528bff", fallback: .controlAccentColor),
            invisibles: attribute("#4b5263", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#528bff", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#3e4451", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#c678dd", fallback: .systemPurple),
            commands: attribute("#61afef", fallback: .systemBlue),
            types: attribute("#e5c07b", fallback: .systemYellow),
            attributes: attribute("#d19a66", fallback: .systemOrange),
            variables: attribute("#e06c75", fallback: .systemRed),
            values: attribute("#d19a66", fallback: .systemOrange),
            numbers: attribute("#d19a66", fallback: .systemOrange),
            strings: attribute("#98c379", fallback: .systemGreen),
            characters: attribute("#98c379", fallback: .systemGreen),
            comments: attribute("#5c6370", fallback: .secondaryLabelColor)
        )
    }

    /// Atom One Light theme.
    static var oneLight: EditorTheme {
        EditorTheme(
            text: attribute("#383a42", fallback: .textColor),
            insertionPoint: color("#526fff", fallback: .controlAccentColor),
            invisibles: attribute("#a0a1a7", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#4078f2", fallback: .controlAccentColor).withAlphaComponent(0.06),
            selection: color("#e5e5e6", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#a626a4", fallback: .systemPurple),
            commands: attribute("#4078f2", fallback: .systemBlue),
            types: attribute("#c18401", fallback: .systemYellow),
            attributes: attribute("#986801", fallback: .systemOrange),
            variables: attribute("#e45649", fallback: .systemRed),
            values: attribute("#986801", fallback: .systemOrange),
            numbers: attribute("#986801", fallback: .systemOrange),
            strings: attribute("#50a14f", fallback: .systemGreen),
            characters: attribute("#50a14f", fallback: .systemGreen),
            comments: attribute("#a0a1a7", fallback: .secondaryLabelColor)
        )
    }

    /// Dracula syntax theme.
    static var dracula: EditorTheme {
        EditorTheme(
            text: attribute("#f8f8f2", fallback: .textColor),
            insertionPoint: color("#f8f8f0", fallback: .white),
            invisibles: attribute("#6272a4", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#bd93f9", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#44475a", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#ff79c6", fallback: .systemPink),
            commands: attribute("#8be9fd", fallback: .systemCyan),
            types: attribute("#8be9fd", fallback: .systemCyan),
            attributes: attribute("#50fa7b", fallback: .systemGreen),
            variables: attribute("#50fa7b", fallback: .systemGreen),
            values: attribute("#bd93f9", fallback: .systemPurple),
            numbers: attribute("#bd93f9", fallback: .systemPurple),
            strings: attribute("#f1fa8c", fallback: .systemYellow),
            characters: attribute("#f1fa8c", fallback: .systemYellow),
            comments: attribute("#6272a4", fallback: .secondaryLabelColor)
        )
    }

    /// GitHub Dark syntax theme.
    static var githubDark: EditorTheme {
        EditorTheme(
            text: attribute("#c9d1d9", fallback: .textColor),
            insertionPoint: color("#58a6ff", fallback: .controlAccentColor),
            invisibles: attribute("#484f58", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#58a6ff", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#388bfd", fallback: .selectedTextBackgroundColor).withAlphaComponent(0.4),
            keywords: attribute("#ff7b72", fallback: .systemRed),
            commands: attribute("#79c0ff", fallback: .systemBlue),
            types: attribute("#ffa657", fallback: .systemOrange),
            attributes: attribute("#d2a8ff", fallback: .systemPurple),
            variables: attribute("#d2a8ff", fallback: .systemPurple),
            values: attribute("#79c0ff", fallback: .systemBlue),
            numbers: attribute("#79c0ff", fallback: .systemBlue),
            strings: attribute("#a5d6ff", fallback: .systemCyan),
            characters: attribute("#a5d6ff", fallback: .systemCyan),
            comments: attribute("#8b949e", fallback: .secondaryLabelColor)
        )
    }

    /// Nord syntax theme.
    static var nord: EditorTheme {
        EditorTheme(
            text: attribute("#d8dee9", fallback: .textColor),
            insertionPoint: color("#88c0d0", fallback: .controlAccentColor),
            invisibles: attribute("#4c566a", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#88c0d0", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#434c5e", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#81a1c1", fallback: .systemPurple),
            commands: attribute("#88c0d0", fallback: .systemBlue),
            types: attribute("#8fbcbb", fallback: .systemTeal),
            attributes: attribute("#d08770", fallback: .systemOrange),
            variables: attribute("#bf616a", fallback: .systemRed),
            values: attribute("#ebcb8b", fallback: .systemYellow),
            numbers: attribute("#b48ead", fallback: .systemPurple),
            strings: attribute("#a3be8c", fallback: .systemGreen),
            characters: attribute("#a3be8c", fallback: .systemGreen),
            comments: attribute("#4c566a", fallback: .secondaryLabelColor)
        )
    }

    /// Monokai syntax theme.
    static var monokai: EditorTheme {
        EditorTheme(
            text: attribute("#f8f8f2", fallback: .textColor),
            insertionPoint: color("#f8f8f0", fallback: .white),
            invisibles: attribute("#75715e", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#fd971f", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#49483e", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#f92672", fallback: .systemPink),
            commands: attribute("#66d9ef", fallback: .systemCyan),
            types: attribute("#66d9ef", fallback: .systemCyan),
            attributes: attribute("#a6e22e", fallback: .systemGreen),
            variables: attribute("#fd971f", fallback: .systemOrange),
            values: attribute("#ae81ff", fallback: .systemPurple),
            numbers: attribute("#ae81ff", fallback: .systemPurple),
            strings: attribute("#e6db74", fallback: .systemYellow),
            characters: attribute("#e6db74", fallback: .systemYellow),
            comments: attribute("#75715e", fallback: .secondaryLabelColor)
        )
    }

    /// Catppuccin Mocha syntax theme.
    static var catppuccinMocha: EditorTheme {
        EditorTheme(
            text: attribute("#cdd6f4", fallback: .textColor),
            insertionPoint: color("#f5e0dc", fallback: .controlAccentColor),
            invisibles: attribute("#585b70", fallback: .tertiaryLabelColor),
            background: EditorTheme.transparentBackground,
            lineHighlight: color("#89b4fa", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#45475a", fallback: .selectedTextBackgroundColor),
            keywords: attribute("#cba6f7", fallback: .systemPurple),
            commands: attribute("#89b4fa", fallback: .systemBlue),
            types: attribute("#f9e2af", fallback: .systemYellow),
            attributes: attribute("#fab387", fallback: .systemOrange),
            variables: attribute("#f38ba8", fallback: .systemRed),
            values: attribute("#fab387", fallback: .systemOrange),
            numbers: attribute("#fab387", fallback: .systemOrange),
            strings: attribute("#a6e3a1", fallback: .systemGreen),
            characters: attribute("#a6e3a1", fallback: .systemGreen),
            comments: attribute("#6c7086", fallback: .secondaryLabelColor)
        )
    }

    /// Adaptive theme derived from terminal colors.
    static func adaptive(background: NSColor, foreground: NSColor) -> EditorTheme {
        EditorTheme(
            text: EditorTheme.Attribute(color: foreground),
            insertionPoint: foreground,
            invisibles: EditorTheme.Attribute(color: .tertiaryLabelColor),
            background: background,
            lineHighlight: .controlAccentColor.withAlphaComponent(0.08),
            selection: .selectedTextBackgroundColor,
            keywords: EditorTheme.Attribute(color: .systemPurple),
            commands: EditorTheme.Attribute(color: .systemBlue),
            types: EditorTheme.Attribute(color: .systemMint),
            attributes: EditorTheme.Attribute(color: .systemOrange),
            variables: EditorTheme.Attribute(color: .systemTeal),
            values: EditorTheme.Attribute(color: .systemIndigo),
            numbers: EditorTheme.Attribute(color: .systemOrange),
            strings: EditorTheme.Attribute(color: .systemGreen),
            characters: EditorTheme.Attribute(color: .systemGreen),
            comments: EditorTheme.Attribute(color: .secondaryLabelColor)
        )
    }
}

/// JSON-serializable theme definition compatible with CodeEdit / TextMate themes.
public struct EditorThemeDefinition: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let text: String?
    public let insertionPoint: String?
    public let invisibles: String?
    public let lineHighlight: String?
    public let selection: String?
    public let keywords: String?
    public let commands: String?
    public let types: String?
    public let attributes: String?
    public let variables: String?
    public let values: String?
    public let numbers: String?
    public let strings: String?
    public let characters: String?
    public let comments: String?

    public func toEditorTheme() -> EditorTheme {
        func parse(_ hex: String?, fallback: NSColor) -> NSColor {
            guard let hex else { return fallback }
            return NSColor(hex: hex) ?? fallback
        }

        return EditorTheme(
            text: EditorTheme.Attribute(color: parse(text, fallback: .textColor)),
            insertionPoint: parse(insertionPoint, fallback: .controlAccentColor),
            invisibles: EditorTheme.Attribute(color: parse(invisibles, fallback: .tertiaryLabelColor)),
            background: EditorTheme.transparentBackground,
            lineHighlight: parse(lineHighlight, fallback: .controlAccentColor.withAlphaComponent(0.08)),
            selection: parse(selection, fallback: .selectedTextBackgroundColor),
            keywords: EditorTheme.Attribute(color: parse(keywords, fallback: .systemPurple)),
            commands: EditorTheme.Attribute(color: parse(commands, fallback: .systemBlue)),
            types: EditorTheme.Attribute(color: parse(types, fallback: .systemYellow)),
            attributes: EditorTheme.Attribute(color: parse(attributes, fallback: .systemOrange)),
            variables: EditorTheme.Attribute(color: parse(variables, fallback: .systemRed)),
            values: EditorTheme.Attribute(color: parse(values, fallback: .systemOrange)),
            numbers: EditorTheme.Attribute(color: parse(numbers, fallback: .systemOrange)),
            strings: EditorTheme.Attribute(color: parse(strings, fallback: .systemGreen)),
            characters: EditorTheme.Attribute(color: parse(characters, fallback: .systemGreen)),
            comments: EditorTheme.Attribute(color: parse(comments, fallback: .secondaryLabelColor))
        )
    }
}

/// Manager for discovering and loading user themes from `~/.config/ghostty/editor-themes/`.
@MainActor
public final class EditorThemeManager: ObservableObject {
    public static let shared = EditorThemeManager()

    @Published public private(set) var customThemes: [String: EditorTheme] = [:]

    private init() {
        reloadCustomThemes()
    }

    public func reloadCustomThemes() {
        let home = NSHomeDirectory()
        let configURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".config/ghostty/editor-themes")
        let appSupportURL = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/com.jischeng.omg/editor-themes")

        var loaded: [String: EditorTheme] = [:]
        for dir in [configURL, appSupportURL] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: file),
                   let def = try? JSONDecoder().decode(EditorThemeDefinition.self, from: data) {
                    loaded[def.name] = def.toEditorTheme()
                }
            }
        }
        self.customThemes = loaded
    }
}

// Reuse Ghostty's resolved config (including light/dark variants and overrides)
// rather than parsing theme files in a second theme loader.
extension Ghostty.Config {
    var editorBackgroundBlur: OhMyGhosttyBackgroundBlur {
        switch backgroundBlur {
        case .macosGlassRegular: .macosGlassRegular
        case .macosGlassClear: .macosGlassClear
        case .disabled: .disabled
        default: .enabled
        }
    }

    /// Native chrome only needs the accent; avoid constructing all 256 palette
    /// colors and syntax attributes for every row draw and hover update.
    func nativeControlAccent(background: NSColor) -> NSColor {
        var palette = ghostty_config_palette_s()
        if ghostty_config_get(config, &palette, "palette", 7) {
            return withUnsafeBytes(of: &palette.colors) {
                NSColor(ghostty: $0.bindMemory(to: ghostty_config_color_s.self)[4])
            }
        }
        return editorTheme(background: background).commands.color
    }

    func editorTheme(background: NSColor) -> EditorTheme {
        func color(_ key: String, fallback: NSColor) -> NSColor {
            var value = ghostty_config_color_s()
            guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return fallback }
            return NSColor(ghostty: value)
        }
        let foreground = color("foreground", fallback: .textColor)
        var theme = EditorTheme.adaptive(background: background, foreground: foreground)
        var palette = ghostty_config_palette_s()
        if ghostty_config_get(config, &palette, "palette", 7) {
            let colors = withUnsafeBytes(of: &palette.colors) {
                Array($0.bindMemory(to: ghostty_config_color_s.self)).map { NSColor(ghostty: $0) }
            }
            theme.keywords = EditorTheme.attribute(colors[5])
            theme.commands = EditorTheme.attribute(colors[4])
            theme.types = EditorTheme.attribute(colors[3])
            theme.attributes = EditorTheme.attribute(colors[6])
            theme.variables = EditorTheme.attribute(colors[1])
            theme.values = EditorTheme.attribute(colors[3])
            theme.numbers = EditorTheme.attribute(colors[3])
            theme.strings = EditorTheme.attribute(colors[2])
            theme.characters = EditorTheme.attribute(colors[2])
            theme.comments = EditorTheme.attribute(colors[8])
        }
        theme.insertionPoint = color("cursor-color", fallback: foreground)
        theme.selection = color("selection-background", fallback: foreground.withAlphaComponent(0.2))
        return theme
    }
}

extension EditorSyntaxTheme {
    var preset: EditorTheme {
        var theme: EditorTheme
        let background: String
        switch self {
        case .oneDark: theme = .oneDark; background = "#282c34"
        case .oneLight: theme = .oneLight; background = "#fafafa"
        case .dracula: theme = .dracula; background = "#282a36"
        case .githubDark: theme = .githubDark; background = "#0d1117"
        case .nord: theme = .nord; background = "#2e3440"
        case .monokai: theme = .monokai; background = "#272822"
        case .catppuccinMocha: theme = .catppuccinMocha; background = "#1e1e2e"
        case .followTerminal:
            return .adaptive(background: .textBackgroundColor, foreground: .textColor)
        }
        theme.background = NSColor(hex: background) ?? .textBackgroundColor
        return theme
    }
}

@MainActor
final class EditorCatalogThemes {
    static let shared = EditorCatalogThemes()
    private var themes: [String: EditorTheme] = [:]

    func theme(named name: String) -> EditorTheme? {
        if let cached = themes[name] { return cached }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/themes"),
            Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes")
        ].compactMap { $0 }
        guard let file = roots.map({ $0.appendingPathComponent(name) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let raw = ghostty_config_new() else { return nil }
        ghostty_config_load_file(raw, file.path)
        ghostty_config_load_recursive_files(raw)
        ghostty_config_finalize(raw)
        let config = Ghostty.Config(config: raw)
        let theme = config.editorTheme(background: NSColor(config.backgroundColor))
        themes[name] = theme
        return theme
    }
}
