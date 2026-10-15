import Foundation
import Testing
@testable import Ghostty

struct FileExplorerLogicTests {
    /// Creates an empty temporary directory that is removed by the caller.
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerLogicTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listDirectorySortsDirectoriesFirst() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("b".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("10".utf8).write(to: dir.appendingPathComponent("file10.txt"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("file2.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("zdir"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("adir"), withIntermediateDirectories: false)

        let entries = FileExplorerLogic.listDirectory(dir, showHidden: false)
        #expect(entries.map(\.name) == ["adir", "zdir", "a.txt", "b.txt", "file2.txt", "file10.txt"])
        #expect(entries.map(\.isDirectory) == [true, true, false, false, false, false])
    }

    @Test func listDirectoryFiltersHiddenFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try Data().write(to: dir.appendingPathComponent("visible"))

        #expect(FileExplorerLogic.listDirectory(dir, showHidden: false).map(\.name) == ["visible"])

        let all = FileExplorerLogic.listDirectory(dir, showHidden: true)
        #expect(all.map(\.name) == [".hidden", "visible"])
        #expect(all.map(\.isHidden) == [true, false])
    }

    @Test func listDirectoryTreatsPackagesAsFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Test.app/Contents"),
            withIntermediateDirectories: true)

        let entries = FileExplorerLogic.listDirectory(dir, showHidden: false)
        #expect(entries.map(\.name) == ["Test.app"])
        #expect(entries.first?.isDirectory == false)
    }

    @Test func listDirectoryOfMissingDirectoryIsEmpty() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(FileExplorerLogic.listDirectory(url, showHidden: true).isEmpty)
    }

    @Test func previewKind() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let text = dir.appendingPathComponent("main.swift")
        try Data("print(\"hi\")\n".utf8).write(to: text)
        #expect(FileExplorerLogic.previewKind(for: text) == .text)

        let noExtension = dir.appendingPathComponent("Makefile")
        try Data("all:\n".utf8).write(to: noExtension)
        #expect(FileExplorerLogic.previewKind(for: noExtension) == .text)

        let binary = dir.appendingPathComponent("data.bin")
        try Data([0x01, 0x00, 0x02]).write(to: binary)
        #expect(FileExplorerLogic.previewKind(for: binary) == .quickLook)

        // Images are detected by their type, even if the content is not an image.
        let image = dir.appendingPathComponent("image.png")
        try Data("not really a png".utf8).write(to: image)
        #expect(FileExplorerLogic.previewKind(for: image) == .quickLook)

        let large = dir.appendingPathComponent("large.log")
        try Data(repeating: UInt8(ascii: "a"), count: 2048).write(to: large)
        #expect(FileExplorerLogic.previewKind(for: large, maxTextBytes: 1024) == .tooLarge)
    }

    @Test func readText() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let utf8 = dir.appendingPathComponent("utf8.txt")
        try Data("héllo 世界".utf8).write(to: utf8)
        #expect(FileExplorerLogic.readText(utf8) == "héllo 世界")
    }

    @Test func clampPreviewWidth() {
        #expect(FileExplorerLogic.clampPreviewWidth(1) == FileExplorerLogic.previewMinWidth)
        #expect(FileExplorerLogic.clampPreviewWidth(10_000) == FileExplorerLogic.previewMaxWidth)
        #expect(FileExplorerLogic.clampPreviewWidth(.nan) == FileExplorerLogic.previewDefaultWidth)
        #expect(FileExplorerLogic.clampPreviewWidth(500) == 500)
    }

    @Test func effectivePreviewWidth() {
        // Plenty of room.
        #expect(FileExplorerLogic.effectivePreviewWidth(stored: 500, available: 2000) == 500)

        // The terminal keeps its minimum width.
        let available: CGFloat = 600
        #expect(FileExplorerLogic.effectivePreviewWidth(stored: 500, available: available)
            == available - TabSidebarLogic.minTerminalWidth)

        // No room at all.
        #expect(FileExplorerLogic.effectivePreviewWidth(stored: 500, available: 100) == 0)
    }
}
