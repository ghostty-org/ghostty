import Foundation

/// A VS Code file-icon theme: the `icon-theme.json` mapping plus the SVG
/// files it points at.
///
/// Only the SVG half of the format is supported. The other half is
/// font-based — VS Code's own default (Seti) ships a `.woff` and keys icons
/// by `fontCharacter` — and macOS can't register a WOFF without
/// decompressing it first, which would be an entire second rendering path
/// for one theme. Font-based themes parse to an empty `definitions` and are
/// reported as unsupported rather than half-working.
///
/// Parsing is deliberately lenient everywhere else: a theme that omits a
/// key, or names an icon that isn't on disk, falls through to the next rule
/// in the chain instead of failing to load. These are third-party files we
/// don't control.
struct IconTheme: Equatable {
    /// Display name — the containing directory's name.
    let name: String

    /// The directory holding `icon-theme.json`. Every `iconPath` in the
    /// file is relative to this.
    let root: URL

    /// Icon id → path relative to `root`.
    let definitions: [String: String]

    let fileExtensions: [String: String]
    let fileNames: [String: String]
    let languageIds: [String: String]
    let folderNames: [String: String]
    let folderNamesExpanded: [String: String]
    let rootFolderNames: [String: String]

    let defaultFile: String?
    let defaultFolder: String?
    let defaultFolderExpanded: String?
    let defaultRootFolder: String?

    /// Whether this theme resolved any SVG at all. A font-based theme
    /// parses cleanly but can't draw anything, and the picker needs to say
    /// so rather than silently showing blank rows.
    var isSupported: Bool { !definitions.isEmpty }

    // MARK: Resolution

    /// The icon id for a file, in VS Code's own precedence order: an exact
    /// filename match beats an extension match, and a longer extension
    /// beats a shorter one — `foo.component.ts` is an Angular component
    /// before it is TypeScript.
    ///
    /// `languageIds` is consulted last, and only through a guess at the
    /// language, because resolving it properly needs a language service to
    /// say "this file is `typescriptreact`" and a terminal has no such
    /// thing. Skipping it entirely was the first cut and it showed: the
    /// bundled theme defines a Vue icon but never lists `vue` under
    /// `fileExtensions`, so every `.vue` file drew a blank page. Most of
    /// that gap closes by trying the extension *as* a language id — which
    /// is exactly right for `vue`, `php` and `razor` — and the rest by the
    /// small table below.
    func iconID(forFile fileName: String) -> String? {
        let lowered = fileName.lowercased()
        if let id = fileNames[lowered] { return id }

        let candidates = Self.extensionCandidates(for: lowered)
        for candidate in candidates {
            if let id = fileExtensions[candidate] { return id }
        }
        for candidate in candidates {
            if let id = languageIds[candidate] { return id }
            if let language = Self.languageIDsByExtension[candidate],
               let id = languageIds[language] {
                return id
            }
        }
        return defaultFile
    }

    /// Extensions whose VS Code language id isn't just the extension.
    ///
    /// Only needed for themes that key an icon by language and never by
    /// extension. Deliberately short: it covers the languages that actually
    /// turn up and is not trying to be a complete registry.
    static let languageIDsByExtension: [String: String] = [
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure",
        "cr": "crystal",
        "cs": "csharp",
        "erl": "erlang", "hrl": "erlang",
        "ex": "elixir", "exs": "elixir",
        "feature": "gherkin",
        "fs": "fsharp", "fsx": "fsharp",
        "gd": "gdscript",
        "groovy": "groovy",
        "hbs": "handlebars",
        "hs": "haskell",
        "ipynb": "jupyter",
        "jl": "julia",
        "m": "objective-c", "mm": "objective-cpp",
        "pl": "perl", "pm": "perl",
        "tex": "latex", "sty": "latex",
    ]

    /// The icon id for a directory. `isRoot` picks the theme's root-folder
    /// icon when it defines one, which is how themes mark the workspace
    /// root differently from the folders inside it.
    func iconID(forFolder folderName: String, expanded: Bool, isRoot: Bool = false) -> String? {
        let lowered = folderName.lowercased()

        if isRoot {
            if let id = rootFolderNames[lowered] { return id }
            if let id = defaultRootFolder { return id }
        }

        if expanded, let id = folderNamesExpanded[lowered] { return id }
        if let id = folderNames[lowered] { return id }

        if expanded, let id = defaultFolderExpanded { return id }
        return defaultFolder
    }

    /// Where an icon id's artwork lives, or nil when the theme names an id
    /// it never defined.
    ///
    /// Built by appending rather than with `URL(fileURLWithPath:relativeTo:)`:
    /// that initializer resolves against the *parent* when the base URL
    /// carries no trailing slash, which silently drops the theme's own
    /// directory and points every icon one level too high.
    func iconURL(for id: String) -> URL? {
        guard let relative = definitions[id] else { return nil }
        guard !relative.hasPrefix("/") else { return URL(fileURLWithPath: relative) }

        let trimmed = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
        return root.appendingPathComponent(trimmed).standardizedFileURL
    }

    /// Every extension a filename could match, longest first.
    ///
    /// `my.component.ts` yields `component.ts` then `ts`. VS Code treats
    /// every dot as a possible extension boundary, and themes rely on it —
    /// `spec.ts`, `d.ts` and `tar.gz` are all real keys in the bundled
    /// theme and would never match a last-dot-only split.
    static func extensionCandidates(for lowercasedName: String) -> [String] {
        let parts = lowercasedName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[$0...].joined(separator: ".") }
    }

    // MARK: Parsing

    /// Reads `icon-theme.json` (or the first `*icon-theme.json`) out of a
    /// theme directory. Returns nil only when there's no readable theme
    /// file at all.
    static func load(directory: URL) -> IconTheme? {
        let fm = FileManager.default
        var jsonURL = directory.appendingPathComponent("icon-theme.json")

        if !fm.fileExists(atPath: jsonURL.path) {
            let entries = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let match = entries.first(where: {
                $0.lastPathComponent.hasSuffix("icon-theme.json")
            }) else { return nil }
            jsonURL = match
        }

        guard let data = try? Data(contentsOf: jsonURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        return parse(json: json, name: directory.lastPathComponent, root: directory)
    }

    static func parse(json: [String: Any], name: String, root: URL) -> IconTheme {
        var definitions: [String: String] = [:]
        if let raw = json["iconDefinitions"] as? [String: Any] {
            for (id, value) in raw {
                guard let entry = value as? [String: Any],
                      let path = entry["iconPath"] as? String
                else { continue }
                definitions[id] = path
            }
        }

        return IconTheme(
            name: name,
            root: root,
            definitions: definitions,
            fileExtensions: lowercasedKeys(json["fileExtensions"]),
            fileNames: lowercasedKeys(json["fileNames"]),
            languageIds: lowercasedKeys(json["languageIds"]),
            folderNames: lowercasedKeys(json["folderNames"]),
            folderNamesExpanded: lowercasedKeys(json["folderNamesExpanded"]),
            rootFolderNames: lowercasedKeys(json["rootFolderNames"]),
            defaultFile: json["file"] as? String,
            defaultFolder: json["folder"] as? String,
            defaultFolderExpanded: json["folderExpanded"] as? String,
            defaultRootFolder: json["rootFolder"] as? String
        )
    }

    /// Lookups are all done on lowercased names, so the tables are folded
    /// once here rather than at every hit — themes are inconsistent about
    /// case (`Dockerfile` vs `dockerfile`) and a miss is silent.
    private static func lowercasedKeys(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: String] else { return [:] }
        return Dictionary(
            dict.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
