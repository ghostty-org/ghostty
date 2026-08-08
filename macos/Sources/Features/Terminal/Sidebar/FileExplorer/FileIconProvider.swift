import AppKit
import SwiftUI

/// What to draw next to a row in the file explorer.
enum FileIcon: Equatable {
    /// Artwork from an icon theme, already carrying its own brand colors —
    /// draw it as-is, never as a template.
    case image(NSImage)

    /// The built-in fallback: an SF Symbol plus the tint it should take.
    case symbol(name: String, color: Color)
}

/// Resolves a filename to an icon, and owns the set of installed icon
/// themes.
///
/// Themes come from two places, mirroring how `ThemeCatalog` handles color
/// themes: the one bundled with the app, and anything the user drops in
/// `~/.config/phantom/icon-themes/<name>/`. Any SVG-based VS Code icon
/// theme works — copy the extension's folder in, no install step.
///
/// With no theme selected the explorer still looks like an explorer: the
/// `symbolFallback` table below maps the common extensions onto SF Symbols
/// so a fresh install isn't a wall of identical page icons.
@MainActor
final class FileIconProvider: ObservableObject {
    static let shared = FileIconProvider()

    /// Persisted by name rather than index so reordering or removing a
    /// theme can't silently switch the user to a different one.
    static let selectionKey = "FileExplorerIconTheme"

    /// The value stored in `selectionKey` for "no theme, use SF Symbols".
    static let symbolsOnly = ""

    @Published private(set) var themes: [IconTheme] = []
    @Published private(set) var active: IconTheme?

    /// Keyed by icon id, cleared whenever the active theme changes. SVG
    /// decoding is not free and the same handful of ids repeat down every
    /// directory listing.
    private var imageCache: [String: NSImage] = [:]

    private init() {
        reload()
    }

    // MARK: Catalog

    /// The directory inside the app bundle holding themes we ship.
    static var bundledThemesDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("icon-themes", isDirectory: true)
    }

    func reload() {
        var found: [IconTheme] = []

        for dir in [Self.bundledThemesDir, GuiConfigStore.shared.iconThemesDirURL].compactMap({ $0 }) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let theme = IconTheme.load(directory: entry)
                else { continue }
                found.append(theme)
            }
        }

        themes = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        applySelection()
    }

    /// Selects a theme by name, or `symbolsOnly` to fall back to SF Symbols.
    func select(_ name: String) {
        UserDefaults.standard.set(name, forKey: Self.selectionKey)
        applySelection()
    }

    var selectedName: String {
        UserDefaults.standard.string(forKey: Self.selectionKey) ?? Self.defaultThemeName
    }

    /// Symbols ships with the app and is what the explorer is designed
    /// against, so a fresh install gets it without having to pick anything.
    static let defaultThemeName = "symbols"

    private func applySelection() {
        let name = selectedName
        let next = name == Self.symbolsOnly
            ? nil
            : themes.first { $0.name == name && $0.isSupported }

        guard next != active else { return }
        active = next
        imageCache.removeAll()
    }

    // MARK: Icon resolution

    func icon(forFile fileName: String) -> FileIcon {
        if let theme = active,
           let id = theme.iconID(forFile: fileName),
           let image = image(for: id, in: theme) {
            return .image(image)
        }
        return Self.symbolFallback(forFile: fileName)
    }

    func icon(forFolder folderName: String, expanded: Bool, isRoot: Bool = false) -> FileIcon {
        if let theme = active,
           let id = theme.iconID(forFolder: folderName, expanded: expanded, isRoot: isRoot),
           let image = image(for: id, in: theme) {
            return .image(image)
        }
        return .symbol(name: expanded ? "folder.fill" : "folder", color: .secondary)
    }

    private func image(for id: String, in theme: IconTheme) -> NSImage? {
        if let cached = imageCache[id] { return cached }
        guard let url = theme.iconURL(for: id),
              let image = NSImage(contentsOf: url)
        else { return nil }
        imageCache[id] = image
        return image
    }

    // MARK: SF Symbols fallback

    /// Extension → SF Symbol, for when no icon theme is active or the theme
    /// has no artwork for this file. Grouped by what the file *is* rather
    /// than by language, since SF Symbols has no per-language glyphs.
    private static let symbolsByExtension: [String: (String, Color)] = {
        var map: [String: (String, Color)] = [:]

        func put(_ symbol: String, _ color: Color, _ extensions: [String]) {
            for ext in extensions { map[ext] = (symbol, color) }
        }

        put("curlybraces", .orange, [
            "swift", "zig", "rs", "go", "c", "h", "cpp", "cc", "hpp", "m", "mm",
            "java", "kt", "kts", "rb", "py", "php", "cs", "scala", "dart", "lua",
            "ex", "exs", "erl", "hs", "clj", "vue", "svelte",
        ])
        put("chevron.left.forwardslash.chevron.right", .blue, [
            "ts", "tsx", "js", "jsx", "mjs", "cjs", "html", "htm", "xml",
        ])
        put("paintbrush", .pink, ["css", "scss", "sass", "less", "styl"])
        put("list.bullet.rectangle", .yellow, [
            "json", "yml", "yaml", "toml", "ini", "conf", "cfg", "plist", "env",
        ])
        put("doc.text", .secondary, ["md", "markdown", "txt", "rst", "adoc", "org"])
        put("photo", .purple, [
            "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico", "tiff", "heic",
        ])
        put("film", .purple, ["mp4", "mov", "avi", "mkv", "webm"])
        put("waveform", .purple, ["mp3", "wav", "flac", "aac", "ogg", "m4a"])
        put("terminal", .green, ["sh", "bash", "zsh", "fish", "bat", "ps1"])
        put("shippingbox", .brown, ["zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg"])
        put("lock", .gray, ["lock", "pem", "key", "crt", "cer"])
        put("cylinder.split.1x2", .cyan, ["sql", "db", "sqlite", "sqlite3"])
        put("doc.richtext", .red, ["pdf"])
        put("textformat", .secondary, ["ttf", "otf", "woff", "woff2", "eot"])

        return map
    }()

    /// Filenames that read better by name than by extension.
    private static let symbolsByName: [String: (String, Color)] = [
        "dockerfile": ("shippingbox", .blue),
        "makefile": ("hammer", .orange),
        "license": ("scroll", .secondary),
        "readme.md": ("book", .blue),
        ".gitignore": ("arrow.triangle.branch", .orange),
        ".gitattributes": ("arrow.triangle.branch", .orange),
        "package.json": ("shippingbox", .red),
    ]

    static func symbolFallback(forFile fileName: String) -> FileIcon {
        let lowered = fileName.lowercased()

        if let match = symbolsByName[lowered] {
            return .symbol(name: match.0, color: match.1)
        }

        for candidate in IconTheme.extensionCandidates(for: lowered) {
            if let match = symbolsByExtension[candidate] {
                return .symbol(name: match.0, color: match.1)
            }
        }

        return .symbol(name: "doc", color: .secondary)
    }
}

/// Draws whichever kind of icon the provider returned at a consistent size.
struct FileIconView: View {
    let icon: FileIcon
    var size: CGFloat = 14

    var body: some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size - 2))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}
