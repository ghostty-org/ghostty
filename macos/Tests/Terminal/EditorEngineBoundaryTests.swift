import Foundation
@testable import Ghostty
import Testing

/// The editor engine must stay extractable into its own package.
///
/// That promise is easy to make and easy to break — one `ThemePalette.shared`
/// reached for in a hurry and the directory can never leave. So instead of
/// a comment nobody rereads, this reads the engine's own source and fails
/// on anything that would tie it to Phantom.
///
/// The rule: **the engine takes what it needs as values.** A theme arrives
/// as `CodeTheme`, configuration as `CodeEditorConfiguration`. Nothing in
/// there asks the app a question.
struct EditorEngineBoundaryTests {
    /// Symbols that would tie the engine to this app.
    ///
    /// `UserDefaults` is on the list for the same reason as the singletons:
    /// a component that reads preferences behind the host's back can't be
    /// configured by a different host.
    private static let forbidden = [
        "ThemePalette",
        "SidebarGroupStore",
        "SidebarTabModel",
        "SidebarTabManager",
        "FileIconProvider",
        "GitCenter",
        "Ghostty.",
        "UserDefaults",
        "GuiConfigStore",
        "TerminalController",
        "AppDelegate",
    ]

    /// Located from this file rather than the bundle: the sources aren't
    /// copied into the test bundle, and the point is to inspect the code as
    /// written.
    private var engineDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/macos/Tests/Terminal/<this>.swift
            .deletingLastPathComponent()          // …/macos/Tests/Terminal
            .deletingLastPathComponent()          // …/macos/Tests
            .deletingLastPathComponent()          // …/macos
            .appendingPathComponent("Sources/Features/Terminal/Editor/Engine")
    }

    private func engineSources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: engineDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// Guards the guard: a wrong path would make every check below pass by
    /// finding nothing.
    @Test func theEngineDirectoryIsWhereWeThinkItIs() throws {
        let sources = try engineSources()
        #expect(!sources.isEmpty, "no engine sources at \(engineDirectory.path)")
    }

    /// Comments are dropped before scanning.
    ///
    /// Prose gets to *name* these things — explaining that the engine takes
    /// a theme as a value rather than reaching for the app's is exactly the
    /// kind of comment worth having, and a check that forbade saying so
    /// would push the explanation out of the file it explains.
    private func code(in source: URL) throws -> String {
        try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                    && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    @Test func theEngineNamesNothingFromPhantom() throws {
        for source in try engineSources() {
            let text = try code(in: source)
            for symbol in Self.forbidden {
                #expect(
                    !text.contains(symbol),
                    "\(source.lastPathComponent) references \(symbol); the engine has to receive that as a value instead, or it can never be extracted"
                )
            }
        }
    }

    /// AppKit and Foundation are the floor a text engine stands on; SwiftUI
    /// is allowed for the view wrapper.
    ///
    /// Anything *not* here is a dependency somebody would have to justify
    /// at extraction time, which is the moment this test exists to make
    /// loud. Tree-sitter will earn its place on this list when it lands;
    /// until then the engine carries nothing.
    @Test func theEngineImportsOnlyItsOwnDependencies() throws {
        let allowed: Set<String> = ["Foundation", "AppKit", "SwiftUI", "CoreText", "os"]

        for source in try engineSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                #expect(
                    allowed.contains(module),
                    "\(source.lastPathComponent) imports \(module)"
                )
            }
        }
    }
}
