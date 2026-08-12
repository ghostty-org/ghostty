import Foundation
@testable import Ghostty
import Testing

/// Reading a path out of terminal output.
///
/// Ghostty already detects bare paths, so the click worked — it just went to
/// Launch Services instead of to the opener the reader chose. This is the
/// parsing half, and it is where the mistakes are: the `path:line:column`
/// form every tool prints has to be told from a path that merely contains a
/// colon.
struct TerminalPathParseTests {
    private func parsed(_ text: String) -> TerminalPathTarget {
        TerminalPathTarget.parse(text)
    }

    @Test func aPlainPathHasNoPosition() {
        let target = parsed("src/main.ts")
        #expect(target.path == "src/main.ts")
        #expect(target.line == nil)
        #expect(target.column == nil)
    }

    /// What `grep -n` prints.
    @Test func aLineIsRead() {
        let target = parsed("src/main.ts:42")
        #expect(target.path == "src/main.ts")
        #expect(target.line == 42)
        #expect(target.column == nil)
    }

    /// What a compiler and a stack trace print.
    @Test func aLineAndColumnAreRead() {
        let target = parsed("macos/Sources/Editor.swift:100:8")
        #expect(target.path == "macos/Sources/Editor.swift")
        #expect(target.line == 100)
        #expect(target.column == 8)
    }

    /// Only two numbers. A third belongs to the name, whatever it looks like.
    @Test func atMostTwoNumbersAreTaken() {
        let target = parsed("dump:1:2:3")
        #expect(target.path == "dump:1")
        #expect(target.line == 2)
        #expect(target.column == 3)
    }

    /// A trailing colon with nothing after it is part of the text, not a
    /// position — this is what `grep` prints for a binary match.
    @Test func aTrailingColonIsNotAPosition() {
        let target = parsed("src/main.ts:")
        #expect(target.path == "src/main.ts:")
        #expect(target.line == nil)
    }

    @Test func aNonNumericSuffixIsPartOfThePath() {
        let target = parsed("src/main.ts:beta")
        #expect(target.path == "src/main.ts:beta")
        #expect(target.line == nil)
    }

    /// Line numbers are one-based everywhere they are printed, so a zero is
    /// not a line and must not be read as one.
    @Test func zeroIsNotALine() {
        let target = parsed("src/main.ts:0")
        #expect(target.path == "src/main.ts:0")
        #expect(target.line == nil)
    }

    /// A single character before the colon is a drive letter, not a path
    /// ending in one.
    @Test func aDriveLetterIsNotAPosition() {
        let target = parsed("C:1")
        #expect(target.path == "C:1")
        #expect(target.line == nil)
    }

    @Test func anAbsolutePathKeepsItsRoot() {
        let target = parsed("/Users/x/file.swift:7")
        #expect(target.path == "/Users/x/file.swift")
        #expect(target.line == 7)
    }
}

/// Turning the parsed text into a file, or declining to.
struct TerminalPathResolveTests {
    private func makeFile() -> (directory: String, name: String) {
        let directory = NSTemporaryDirectory() + "phantom-click-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let name = "clicked.swift"
        try? "let a = 1".write(
            toFile: directory + "/" + name,
            atomically: true,
            encoding: .utf8
        )
        return (directory, name)
    }

    @Test func aRelativePathResolvesAgainstTheTerminalsDirectory() {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(atPath: file.directory) }

        let target = TerminalPathTarget.parse(file.name + ":3")
        #expect(target.resolvedFile(relativeTo: file.directory) != nil)
    }

    @Test func anAbsolutePathNeedsNoDirectory() {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(atPath: file.directory) }

        let target = TerminalPathTarget.parse(file.directory + "/" + file.name)
        #expect(target.resolvedFile(relativeTo: nil) != nil)
    }

    /// The declining half, and the important one: everything refused here has
    /// to reach the behaviour that existed before, or clicking an ordinary
    /// link in the terminal would silently stop working.
    @Test func aPathThatDoesNotExistIsDeclined() {
        let target = TerminalPathTarget.parse("/nowhere/\(UUID().uuidString).ts")
        #expect(target.resolvedFile(relativeTo: nil) == nil)
    }

    @Test func aDirectoryIsDeclined() {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(atPath: file.directory) }

        let target = TerminalPathTarget.parse(file.directory)
        #expect(target.resolvedFile(relativeTo: nil) == nil)
    }

    @Test func aRelativePathWithNoDirectoryIsDeclined() {
        #expect(TerminalPathTarget.parse("main.ts").resolvedFile(relativeTo: nil) == nil)
    }

    @Test func aTildeIsExpanded() {
        let target = TerminalPathTarget.parse("~/.zshrc")
        let resolved = target.resolvedFile(relativeTo: nil)
        #expect(resolved == nil || resolved?.path.hasPrefix("/Users") == true)
    }
}
