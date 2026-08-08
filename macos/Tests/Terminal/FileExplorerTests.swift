import Foundation
@testable import Ghostty
import Testing

/// The file explorer's directory listing: ordering and hidden-file
/// handling, against a real temp directory tree.
struct FileExplorerTests {
    /// Resolved through the POSIX `realpath` rather than
    /// `URL.resolvingSymlinksInPath()`, which leaves the `/var` →
    /// `/private/var` symlink that temp directories sit behind alone —
    /// `FileManager` returns the resolved form, so constructed expectations
    /// would never match. Same reason `SidebarGroupTests` does this.
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func makeFile(_ base: URL, _ name: String) throws {
        try Data().write(to: base.appendingPathComponent(name))
    }

    private func makeDir(_ base: URL, _ name: String) throws {
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func node(_ name: String, isDirectory: Bool) -> FileNode {
        FileNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory
        )
    }

    // MARK: Sorting

    @Test func directoriesSortBeforeFiles() {
        let sorted = FileExplorerModel.sorted([
            node("zebra", isDirectory: true),
            node("alpha", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["zebra", "alpha"])
    }

    /// Lowercase and uppercase names interleaving by ASCII value is the
    /// classic wrong-looking listing — `Zoo` must not sort before `apple`.
    @Test func namesSortCaseInsensitively() {
        let sorted = FileExplorerModel.sorted([
            node("Zoo", isDirectory: false),
            node("apple", isDirectory: false),
            node("Banana", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["apple", "Banana", "Zoo"])
    }

    @Test func sortingIsStableAcrossBothRules() {
        let sorted = FileExplorerModel.sorted([
            node("src", isDirectory: true),
            node("README.md", isDirectory: false),
            node("Assets", isDirectory: true),
            node("build.zig", isDirectory: false),
        ])
        #expect(sorted.map(\.name) == ["Assets", "src", "build.zig", "README.md"])
    }

    // MARK: Scanning

    @Test func scanListsDirectoriesFirstThenFiles() throws {
        let base = try tempDirectory()
        try makeDir(base, "src")
        try makeFile(base, "README.md")
        try makeDir(base, "macos")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        #expect(scanned.map(\.name) == ["macos", "src", "README.md"])
        #expect(scanned.first?.isDirectory == true)
    }

    @Test func scanSkipsHiddenEntriesByDefault() throws {
        let base = try tempDirectory()
        try makeFile(base, "visible.txt")
        try makeFile(base, ".hidden")
        try makeDir(base, ".git")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        #expect(scanned.map(\.name) == ["visible.txt"])
    }

    @Test func scanIncludesHiddenEntriesWhenAsked() throws {
        let base = try tempDirectory()
        try makeFile(base, "visible.txt")
        try makeFile(base, ".hidden")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: true)
        #expect(Set(scanned.map(\.name)) == [".hidden", "visible.txt"])
    }

    /// A folder the user can't read is a normal thing to scroll past; it
    /// must not throw or blank the tree.
    @Test func scanningSomethingUnreadableYieldsAnEmptyList() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)", isDirectory: true)
        #expect(FileExplorerModel.scan(directory: missing, showHidden: false).isEmpty)
    }

    @Test func scanMarksDirectoriesCorrectly() throws {
        let base = try tempDirectory()
        try makeDir(base, "folder")
        try makeFile(base, "file.txt")

        let scanned = FileExplorerModel.scan(directory: base, showHidden: false)
        let byName = Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0.isDirectory) })
        #expect(byName["folder"] == true)
        #expect(byName["file.txt"] == false)
    }

    // MARK: Shell quoting

    /// The explorer builds a shell command from a path it did not choose.
    /// Spaces and quotes in Mac filenames are ordinary, and unquoted they
    /// would re-split into a command that opens something else entirely.
    @Test func pathsAreQuotedForTheShell() {
        #expect(FileOpener.shellQuoted("/tmp/plain.txt") == "'/tmp/plain.txt'")
        #expect(FileOpener.shellQuoted("/tmp/with space.txt") == "'/tmp/with space.txt'")
        #expect(FileOpener.shellQuoted("/tmp/$HOME.txt") == "'/tmp/$HOME.txt'")
    }

    @Test func embeddedSingleQuotesAreEscaped() {
        #expect(FileOpener.shellQuoted("/tmp/it's.txt") == "'/tmp/it'\\''s.txt'")
    }
}
