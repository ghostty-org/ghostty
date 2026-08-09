import Foundation

/// How to start one language server, and what to tell the user when it
/// isn't there.
struct LSPServerDefinition: Hashable, Sendable, Identifiable {
    /// The LSP `languageId`, spelled exactly as the specification does —
    /// it is also what goes in every `textDocument/didOpen`, so inventing a
    /// nicer name here would mean translating it back later.
    let languageID: String

    /// For the "install this" row in the UI.
    let displayName: String

    /// Looked up on the login shell's `PATH`, not launched through a shell.
    let command: String

    let arguments: [String]

    /// Almost none of these are installed on a given machine, and a server
    /// that fails to spawn is indistinguishable from one that is broken
    /// unless the UI can say *what* is missing and *how* to get it. The
    /// hint travels with the definition so no view has to keep its own
    /// table of them in sync.
    let installHint: String

    var id: String { languageID }

    /// What a "not installed" message should quote back.
    var invocation: String {
        ([command] + arguments).joined(separator: " ")
    }
}

/// The table of servers this editor knows how to start.
///
/// Pure data and pure lookups — no filesystem, no process, no app state —
/// so a view can ask it what a language *would* need without any of that
/// having happened yet.
enum LSPServerRegistry {
    static let all: [LSPServerDefinition] = [
        LSPServerDefinition(
            languageID: "typescript",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "typescriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "javascript",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "javascriptreact",
            displayName: "TypeScript Language Server",
            command: "typescript-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            languageID: "vue",
            displayName: "Vue Language Server",
            command: "vue-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g @vue/language-server"
        ),
        LSPServerDefinition(
            languageID: "swift",
            displayName: "SourceKit-LSP",
            command: "sourcekit-lsp",
            arguments: [],
            installHint: "Ships with Xcode — run: xcode-select --install"
        ),
        LSPServerDefinition(
            languageID: "kotlin",
            displayName: "Kotlin Language Server",
            command: "kotlin-language-server",
            arguments: [],
            installHint: "brew install kotlin-language-server"
        ),
        LSPServerDefinition(
            languageID: "python",
            displayName: "Pyright",
            command: "pyright-langserver",
            arguments: ["--stdio"],
            installHint: "npm i -g pyright"
        ),
        LSPServerDefinition(
            languageID: "rust",
            displayName: "rust-analyzer",
            command: "rust-analyzer",
            arguments: [],
            installHint: "rustup component add rust-analyzer"
        ),
        LSPServerDefinition(
            languageID: "go",
            displayName: "gopls",
            command: "gopls",
            arguments: [],
            installHint: "go install golang.org/x/tools/gopls@latest"
        ),
        LSPServerDefinition(
            languageID: "zig",
            displayName: "Zig Language Server",
            command: "zls",
            arguments: [],
            installHint: "brew install zls"
        ),
        LSPServerDefinition(
            languageID: "json",
            displayName: "JSON Language Server",
            command: "vscode-json-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g vscode-langservers-extracted"
        ),
        LSPServerDefinition(
            languageID: "yaml",
            displayName: "YAML Language Server",
            command: "yaml-language-server",
            arguments: ["--stdio"],
            installHint: "npm i -g yaml-language-server"
        )
    ]

    private static let byLanguageID: [String: LSPServerDefinition] = Dictionary(
        all.map { ($0.languageID, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The language ids share servers — four of them are the same
    /// TypeScript process — so extensions map to a language first and a
    /// server only through it. `.jsonc` and `.mjs` are here because they
    /// are what real projects contain, not because LSP names them.
    private static let languageIDByExtension: [String: String] = [
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "tsx": "typescriptreact",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "javascriptreact",
        "vue": "vue",
        "swift": "swift",
        "kt": "kotlin",
        "kts": "kotlin",
        "py": "python",
        "pyi": "python",
        "rs": "rust",
        "go": "go",
        "zig": "zig",
        "json": "json",
        "jsonc": "json",
        "yaml": "yaml",
        "yml": "yaml"
    ]

    /// Nil for a language nobody has taught this table about — which is the
    /// normal case for most files a terminal opens, and not an error.
    static func server(forLanguage languageID: String) -> LSPServerDefinition? {
        byLanguageID[languageID.lowercased()]
    }

    static func server(forPath path: String) -> LSPServerDefinition? {
        guard let languageID = languageID(forPath: path) else { return nil }
        return server(forLanguage: languageID)
    }

    static func languageID(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return languageIDByExtension[ext]
    }

    /// One entry per distinct binary, for a UI that lists what could be
    /// installed — listing the TypeScript server four times because four
    /// language ids point at it would be noise.
    static var distinctServers: [LSPServerDefinition] {
        var seen: Set<String> = []
        return all.filter { seen.insert($0.command).inserted }
    }
}
