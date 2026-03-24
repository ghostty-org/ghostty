import Foundation
import Testing
@testable import Ghostty

struct PresetLoaderTests {

    // MARK: - parseFrontmatter (via parsePreset)

    @Test func testParseFrontmatterSimple() throws {
        let content = """
        ---
        name: Code Reviewer
        model: sonnet
        description: Reviews code for bugs
        command: claude
        ---

        You are a code reviewer.
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let file = tmpDir.appendingPathComponent("test-simple-\(UUID().uuidString).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let template = PresetLoader.parsePreset(at: file, filename: file.lastPathComponent)
        #expect(template != nil)
        #expect(template?.name == "Code Reviewer")
        #expect(template?.agent?.model == "sonnet")
        #expect(template?.templateDescription == "Reviews code for bugs")
        #expect(template?.command == "claude")
        #expect(template?.kind == .claudeCode)
    }

    @Test func testParseFrontmatterMissingName() throws {
        let content = """
        ---
        model: sonnet
        description: No name field
        ---

        Body text here.
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let file = tmpDir.appendingPathComponent("test-noname-\(UUID().uuidString).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let template = PresetLoader.parsePreset(at: file, filename: file.lastPathComponent)
        #expect(template == nil)
    }

    @Test func testParseFrontmatterMissingDelimiter() throws {
        let content = """
        name: No Delimiter
        model: sonnet
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let file = tmpDir.appendingPathComponent("test-nodelim-\(UUID().uuidString).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let template = PresetLoader.parsePreset(at: file, filename: file.lastPathComponent)
        #expect(template == nil)
    }

    @Test func testParseFrontmatterWithAllowedToolsList() throws {
        let content = """
        ---
        name: Restricted Agent
        command: claude
        model: sonnet
        allowedTools:
          - Read
          - Grep
          - Glob
        ---

        You have limited tool access.
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let file = tmpDir.appendingPathComponent("test-tools-\(UUID().uuidString).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let template = PresetLoader.parsePreset(at: file, filename: file.lastPathComponent)
        #expect(template != nil)
        #expect(template?.name == "Restricted Agent")
        #expect(template?.agent?.allowedTools == ["Read", "Grep", "Glob"])
    }

    // MARK: - Deterministic UUID

    @Test func testDeterministicUUID() {
        // Same filename must always produce the same UUID.
        let uuid1 = PresetLoader.deterministicUUID(from: "code-reviewer.md")
        let uuid2 = PresetLoader.deterministicUUID(from: "code-reviewer.md")
        #expect(uuid1 == uuid2)
    }

    @Test func testDeterministicUUIDDifferentInputs() {
        // Different filenames must produce different UUIDs.
        let uuid1 = PresetLoader.deterministicUUID(from: "code-reviewer.md")
        let uuid2 = PresetLoader.deterministicUUID(from: "orchestrator.md")
        #expect(uuid1 != uuid2)
    }
}
