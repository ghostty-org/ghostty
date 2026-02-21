import Foundation
import Testing
@testable import Ghostree

struct RestorablePathTests {
    @Test func normalizedExistingDirectoryPathReturnsExistingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = directory.path + "/"
        let result = RestorablePath.normalizedExistingDirectoryPath(input)

        #expect(result == directory.standardizedFileURL.path)
    }

    @Test func normalizedExistingDirectoryPathRejectsMissingOrFilePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing", isDirectory: true).path
        #expect(RestorablePath.normalizedExistingDirectoryPath(missing) == nil)

        let file = root.appendingPathComponent("file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(RestorablePath.normalizedExistingDirectoryPath(file.path) == nil)
    }

    @Test func normalizedExistingDirectoryPathRejectsRelativePathComponents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathWithRelativeComponent = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true).path

        #expect(RestorablePath.normalizedExistingDirectoryPath(pathWithRelativeComponent) == nil)
    }

    @Test func existingDirectoryURLReturnsOnlyExistingDirectoryURLs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = RestorablePath.existingDirectoryURL(root)
        #expect(existing?.path == root.standardizedFileURL.path)

        let missing = root.appendingPathComponent("gone", isDirectory: true)
        #expect(RestorablePath.existingDirectoryURL(missing) == nil)
    }

    @Test func existingDirectoryURLRejectsRelativePathComponents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urlWithRelativeComponent = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)

        #expect(RestorablePath.existingDirectoryURL(urlWithRelativeComponent) == nil)
    }
}
