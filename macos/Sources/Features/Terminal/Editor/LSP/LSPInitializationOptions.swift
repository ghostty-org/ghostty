import Foundation

/// How to resolve `initializationOptions` for a language, when a user
/// override doesn't already supply one.
///
/// `LSPServerDefinition` stays a plain, `Hashable` value — a closure there
/// would give every definition its own identity and break the equality
/// `LSPServerRegistry.distinctServers`'s dedup relies on. A tag plus a
/// resolver that switches on it keeps the data pure and the resolution
/// (which touches the filesystem, and for one case a subprocess) in one
/// place that can be tested on its own.
enum LSPInitializationOptionsKind: Hashable, Sendable {
    case none

    /// Volar has no way to find TypeScript itself the way an editor that
    /// already indexed the project would — without this, it stays silent
    /// on every `.vue` file's `<script>` block rather than reporting an
    /// error.
    case vueTypeScriptSDK
}

enum LSPInitializationOptions {
    /// The concrete alternative to the silence this whole feature exists to
    /// replace: shown when neither a project-local nor a global TypeScript
    /// can be found.
    static let missingTypeScriptMessage = """
    Volar needs TypeScript to check .vue files, and none was found in this \
    project or globally. Install it with "npm i -D typescript" in the \
    project, or "npm i -g typescript".
    """

    /// Where Volar should look for TypeScript: the project's own copy
    /// first, so a workspace pinning a version is checked against that
    /// version rather than whatever else happens to be on the machine.
    ///
    /// The global lookup shells out to `npm`, so this belongs off the main
    /// actor — see the call in `LSPCenter.server(for:)`.
    static func vueTypeScriptSDK(
        root: String,
        searchPath: String,
        fileManager: FileManager = .default
    ) -> LSPOutcome<String> {
        let local = (root as NSString).appendingPathComponent("node_modules/typescript/lib")
        if fileManager.fileExists(atPath: local) { return .success(local) }

        if let global = globalTypeScriptLib(searchPath: searchPath, fileManager: fileManager) {
            return .success(global)
        }
        return .failure(missingTypeScriptMessage)
    }

    /// `npm root -g` rather than guessing at Homebrew/nvm/volta layouts:
    /// npm already knows exactly where it put things, and a guess would be
    /// wrong for exactly the setups a guess is hardest to get right for.
    private static func globalTypeScriptLib(searchPath: String, fileManager: FileManager) -> String? {
        guard let npm = LSPProcess.locate("npm", searchPath: searchPath) else { return nil }
        guard let output = ShellCommand.run(npm, ["root", "-g"], timeout: 5) else { return nil }

        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }

        let candidate = (root as NSString).appendingPathComponent("typescript/lib")
        return fileManager.fileExists(atPath: candidate) ? candidate : nil
    }

    /// The value to send as `initializationOptions`, for a resolved `tsdk`.
    static func vueValue(tsdk: String) -> LSPValue {
        ["typescript": ["tsdk": .string(tsdk)]]
    }
}
