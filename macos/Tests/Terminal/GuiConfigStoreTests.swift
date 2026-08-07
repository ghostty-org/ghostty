import Foundation
@testable import Ghostty
import Testing

/// Exercises `GuiConfigStore` against a throwaway config directory rather
/// than the real one, using the `configDir:` seam its initializer already
/// exposes — no production code changed to make this testable.
@MainActor
struct GuiConfigStoreTests {
    private func makeStore() throws -> (store: GuiConfigStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (GuiConfigStore(configDir: dir), dir)
    }

    // MARK: - currentThemeName

    @Test func currentThemeNameIsNilWhenUnset() throws {
        let (store, _) = try makeStore()
        #expect(store.currentThemeName == nil)
    }

    @Test func currentThemeNameReturnsABuiltinNameAsIs() throws {
        let (store, _) = try makeStore()
        store.set("theme", "Dracula Darker")
        #expect(store.currentThemeName == "Dracula Darker")
    }

    /// The bug this regresses: a custom theme is stored as an absolute
    /// path, and comparing that path against a catalog entry's bare name
    /// (`theme.name == currentTheme`) never matched, so the theme in use
    /// never showed as selected. Only the last path component should be
    /// compared.
    @Test func currentThemeNameStripsTheDirectoryFromACustomThemePath() throws {
        let (store, dir) = try makeStore()
        let themePath = dir.appendingPathComponent("themes/My Custom Theme").path
        store.set("theme", themePath)
        #expect(store.currentThemeName == "My Custom Theme")
    }

    // MARK: - currentThemeURL

    @Test func currentThemeURLIsNilWhenUnset() throws {
        let (store, _) = try makeStore()
        #expect(store.currentThemeURL == nil)
    }

    /// The actual bug: a custom theme's `theme` value is an absolute path.
    /// Resolving it must load that exact file rather than searching
    /// Phantom's or the bundle's `themes` directory for a name — that
    /// search is what failed and showed a "theme not found" dialog for a
    /// theme that existed right where it was written.
    @Test func currentThemeURLResolvesAnAbsolutePathDirectly() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/Dracula Darker")
        try FileManager.default.createDirectory(
            at: themeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "background = #000000\n".write(to: themeURL, atomically: true, encoding: .utf8)

        store.set("theme", themeURL.path)
        #expect(store.currentThemeURL == themeURL)
    }

    @Test func currentThemeURLFindsABareNameInTheUserThemesDirectory() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/My Theme")
        try FileManager.default.createDirectory(
            at: themeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "background = #111111\n".write(to: themeURL, atomically: true, encoding: .utf8)

        store.set("theme", "My Theme")
        #expect(store.currentThemeURL == themeURL)
    }

    /// A bare name absent from the user directory falls through to the
    /// bundle's built-in themes — still resolved from a name, never from a
    /// path, so this must not accidentally match `themesDirURL`.
    @Test func currentThemeURLFallsBackToTheBuiltinDirectoryForAnUnknownName() throws {
        let (store, dir) = try makeStore()
        store.set("theme", "Some Builtin Theme")

        let resolved = try #require(store.currentThemeURL)
        #expect(resolved != dir.appendingPathComponent("themes/Some Builtin Theme"))
        #expect(resolved.lastPathComponent == "Some Builtin Theme")
    }

    // MARK: - setTheme

    @Test func setThemeStoresAnAbsolutePathForAUserTheme() throws {
        let (store, dir) = try makeStore()
        let themeURL = dir.appendingPathComponent("themes/Mine")
        let theme = TerminalTheme(name: "Mine", source: .user, url: themeURL)

        store.setTheme(theme)
        #expect(store.string("theme") == themeURL.path)
    }

    @Test func setThemeStoresABareNameForABuiltinTheme() throws {
        let (store, _) = try makeStore()
        let theme = TerminalTheme(
            name: "Dracula",
            source: .builtin,
            url: URL(fileURLWithPath: "/some/bundle/path/Dracula")
        )

        store.setTheme(theme)
        #expect(store.string("theme") == "Dracula")
    }
}
