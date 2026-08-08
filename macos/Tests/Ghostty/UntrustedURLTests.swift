import Foundation
import Testing
@testable import Ghostty

@Suite
struct UntrustedURLTests {
    @Test(arguments: ["http://example.com", "https://example.com/path", "mailto:user@example.com"])
    func allowsSafeSchemes(_ value: String) {
        guard case .allow(let url) = UntrustedURL(value).decision else {
            Issue.record("expected an allowed URL")
            return
        }
        #expect(url.absoluteString == value)
    }

    @Test(arguments: ["https:relative", "http:///missing-host"])
    func rejectsWebURLsWithoutHosts(_ value: String) {
        #expect(UntrustedURL(value).decision == .deny(.invalidWebURL))
    }

    @Test(arguments: ["/tmp/file.txt", "../file.txt", "payload.command"])
    func rejectsSchemeLessTargets(_ value: String) {
        #expect(UntrustedURL(value).decision == .deny(.malformedURL))
    }

    @Test(arguments: ["vscode://file/tmp/example.swift", "ssh://example.com"])
    func confirmsCustomSchemes(_ value: String) {
        guard case .confirm(let url) = UntrustedURL(value).decision else {
            Issue.record("expected a confirmation decision")
            return
        }
        #expect(url.absoluteString == value)
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}"])
    func rejectsInvisibleAndLineBreakingCharacters(_ scalar: String) {
        let value = "https://example.com/before\(scalar)after"
        #expect(UntrustedURL(value).decision == .deny(.unsafeCharacters))
    }

    @Test
    func allowsNonExecutableLocalFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "document.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        guard case .allow(let result) = UntrustedURL(file.absoluteString).decision else {
            Issue.record("expected a safe local file")
            return
        }
        #expect(result == file.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test(arguments: ["payload.command", "payload.tool", "payload.app", "payload.workflow"])
    func rejectsDangerousLocalFileExtensions(_ filename: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: filename)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsScriptContentTypes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.sh")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func rejectsExecutableFilesRegardlessOfExtension() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "payload.txt")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )

        #expect(UntrustedURL(file.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test
    func resolvesSymlinksBeforeClassifyingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appending(path: "payload.command")
        let link = directory.appending(path: "document.txt")
        try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)

        #expect(UntrustedURL(link.absoluteString).decision == .deny(.unsafeFile))
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{2029}"])
    func previewShowsTheEffectiveStandardizedPath(_ separator: String) {
        let value = "/tmp/preview\(separator)////../payload.command////"
        #expect(UntrustedURL(value).displayString == "/tmp/payload.command")
    }

    @Test
    func previewEscapesBidirectionalControls() {
        let value = "https://example.com/a\u{202E}b"
        #expect(UntrustedURL(value).displayString == "https://example.com/a\\u{202E}b")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: result,
            withIntermediateDirectories: false
        )
        return result
    }
}
