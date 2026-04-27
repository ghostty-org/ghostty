import XCTest
@testable import GhosttiesCore

final class FrontmatterTests: XCTestCase {

    // MARK: - split

    func testSplitKnownGoodFixture() throws {
        let raw = """
        ---
        title: Fix CEF build
        source: github
        source-id: GH-287
        status: running
        created: 2026-04-22T22:35:00Z
        ---

        ## Goal

        Body text.
        """
        let result = Frontmatter.split(raw)
        XCTAssertNotNil(result)
        let pairs = result!.pairs
        XCTAssertEqual(pairs.count, 5)
        XCTAssertEqual(Frontmatter.value(for: "title", in: pairs), "Fix CEF build")
        XCTAssertEqual(Frontmatter.value(for: "source", in: pairs), "github")
        XCTAssertEqual(Frontmatter.value(for: "source-id", in: pairs), "GH-287")
        XCTAssertEqual(Frontmatter.value(for: "status", in: pairs), "running")
        XCTAssertEqual(Frontmatter.value(for: "created", in: pairs), "2026-04-22T22:35:00Z")
        XCTAssertTrue(result!.body.contains("## Goal"))
        XCTAssertTrue(result!.body.contains("Body text."))
    }

    func testSplitPreservesKeyOrder() throws {
        let raw = """
        ---
        zebra: 1
        apple: 2
        mango: 3
        ---
        body
        """
        let pairs = Frontmatter.split(raw)?.pairs ?? []
        XCTAssertEqual(pairs.map(\.0), ["zebra", "apple", "mango"])
    }

    func testSplitReturnsNilWhenMissingLeadingFence() {
        let raw = """
        title: No frontmatter
        status: running
        """
        XCTAssertNil(Frontmatter.split(raw))
    }

    func testSplitReturnsNilWhenMissingClosingFence() {
        let raw = """
        ---
        title: Unterminated
        status: running
        body text with no closing fence
        """
        XCTAssertNil(Frontmatter.split(raw))
    }

    func testSplitSkipsBlankAndCommentLines() {
        let raw = """
        ---
        title: Example

        # a yaml comment
        status: running
        ---
        body
        """
        let pairs = Frontmatter.split(raw)?.pairs ?? []
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].0, "title")
        XCTAssertEqual(pairs[1].0, "status")
    }

    func testSplitStripsDoubleAndSingleQuotes() {
        let raw = """
        ---
        double: "hello world"
        single: 'hi there'
        unquoted: plain
        ---
        body
        """
        let pairs = Frontmatter.split(raw)?.pairs ?? []
        XCTAssertEqual(Frontmatter.value(for: "double", in: pairs), "hello world")
        XCTAssertEqual(Frontmatter.value(for: "single", in: pairs), "hi there")
        XCTAssertEqual(Frontmatter.value(for: "unquoted", in: pairs), "plain")
    }

    func testSplitHandlesISODateValues() {
        let raw = """
        ---
        created: 2026-04-22T22:35:00Z
        completed: 2026-04-22T22:45:30.123Z
        ---
        body
        """
        let pairs = Frontmatter.split(raw)?.pairs ?? []
        XCTAssertEqual(Frontmatter.value(for: "created", in: pairs), "2026-04-22T22:35:00Z")
        XCTAssertEqual(Frontmatter.value(for: "completed", in: pairs), "2026-04-22T22:45:30.123Z")
    }

    func testSplitLinesWithoutColonAreIgnored() {
        let raw = """
        ---
        title: Good
        malformed line no colon
        status: running
        ---
        body
        """
        let pairs = Frontmatter.split(raw)?.pairs ?? []
        XCTAssertEqual(pairs.count, 2)
    }

    // MARK: - assemble / round-trip

    func testAssembleRoundTripsSplit() {
        let original = """
        ---
        title: Round trip
        status: backlog
        project: ghostties
        ---

        ## Goal

        x
        """
        let (pairs, body) = Frontmatter.split(original)!
        let rebuilt = Frontmatter.assemble(pairs: pairs, body: body)
        // Parsing the rebuilt output should give identical pairs + body.
        let (pairs2, body2) = Frontmatter.split(rebuilt)!
        XCTAssertEqual(pairs.map(\.0), pairs2.map(\.0))
        XCTAssertEqual(pairs.map(\.1), pairs2.map(\.1))
        XCTAssertEqual(body, body2)
    }

    func testAssembleLeadsBodyWithNewline() {
        let out = Frontmatter.assemble(pairs: [("title", "X")], body: "## Goal\n")
        // Body that doesn't start with \n gets a leading \n
        XCTAssertTrue(out.contains("---\ntitle: X\n---\n\n## Goal"))
    }

    // MARK: - set / value

    func testSetOverwritesExistingKey() {
        let pairs: [(String, String)] = [("title", "A"), ("status", "running")]
        let updated = Frontmatter.set("status", "done", in: pairs)
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(Frontmatter.value(for: "status", in: updated), "done")
        XCTAssertEqual(updated.map(\.0), ["title", "status"])
    }

    func testSetAppendsMissingKey() {
        let pairs: [(String, String)] = [("title", "A")]
        let updated = Frontmatter.set("updated", "2026-04-23T10:00:00Z", in: pairs)
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated.last?.0, "updated")
    }

    // MARK: - project-path + template round-trip

    /// Create a task with both new fields, write via TaskStore, read back
    /// via loadFile, and assert the fields survive round-trip.
    func testProjectPathAndTemplateRoundTrip() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TaskStore(directory: tmpDir)
        let pairs: [(String, String)] = [
            ("title", "Round-trip task"),
            ("source", "shell"),
            ("source-id", "round-trip"),
            ("branch", "null"),
            ("project", "ghostties"),
            ("created", "2026-04-23T10:00:00Z"),
            ("status", "backlog"),
            ("project-path", "~/Code/ghostties"),
            ("template", "Orchestrator")
        ]
        let url = try store.create(id: "round-trip", pairs: pairs, body: "\n## Goal\n\n")

        guard let reloaded = store.loadFile(at: url) else {
            XCTFail("failed to reload task from disk")
            return
        }
        XCTAssertEqual(reloaded.projectPath, "~/Code/ghostties")
        XCTAssertEqual(reloaded.template, "Orchestrator")
    }

    // MARK: - priority round-trip

    /// All four priority values round-trip through TaskStore write → load.
    func testPriorityRoundTrip() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-priority-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TaskStore(directory: tmpDir)
        let values: [(String, TaskPriority)] = [
            ("high",   .high),
            ("medium", .medium),
            ("low",    .low),
            ("none",   .none)
        ]
        for (rawValue, expected) in values {
            let id = "priority-\(rawValue)"
            let pairs: [(String, String)] = [
                ("title", "Priority \(rawValue)"),
                ("source", "shell"),
                ("source-id", id),
                ("branch", "null"),
                ("project", "ghostties"),
                ("created", "2026-04-25T10:00:00Z"),
                ("status", "backlog"),
                ("priority", rawValue)
            ]
            let url = try store.create(id: id, pairs: pairs, body: "\n## Goal\n\n")
            guard let reloaded = store.loadFile(at: url) else {
                XCTFail("failed to reload task with priority=\(rawValue)")
                continue
            }
            XCTAssertEqual(reloaded.priority, expected,
                           "priority '\(rawValue)' did not round-trip correctly")
        }
    }

    /// A file with no `priority:` key defaults to `.none` — legacy files keep loading.
    func testMissingPriorityDefaultsToNone() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-priority-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let raw = """
        ---
        title: Legacy no-priority
        source: shell
        source-id: no-priority
        branch: null
        project: ghostties
        created: 2026-04-25T10:00:00Z
        status: backlog
        ---

        ## Goal

        """
        let url = tmpDir.appendingPathComponent("no-priority.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let store = TaskStore(directory: tmpDir)
        guard let task = store.loadFile(at: url) else {
            XCTFail("legacy task without priority key failed to load")
            return
        }
        XCTAssertEqual(task.priority, .none, "missing priority key must default to .none")
    }

    /// An unknown priority value (e.g. `urgent`) must NOT crash — falls back to `.none`.
    func testUnknownPriorityValueDefaultsToNone() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-priority-unknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let raw = """
        ---
        title: Unknown priority
        source: shell
        source-id: unknown-priority
        branch: null
        project: ghostties
        created: 2026-04-25T10:00:00Z
        status: backlog
        priority: urgent
        ---

        ## Goal

        """
        let url = tmpDir.appendingPathComponent("unknown-priority.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let store = TaskStore(directory: tmpDir)
        guard let task = store.loadFile(at: url) else {
            XCTFail("task with unknown priority value failed to load (should not crash)")
            return
        }
        XCTAssertEqual(task.priority, .none,
                       "unknown priority value 'urgent' must fall back to .none")
    }

    /// A file with none of the new keys must still load cleanly — old fixtures
    /// pre-date the project-path/template additions and must continue to work.
    func testFileWithoutNewFieldsStillLoads() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let raw = """
        ---
        title: Legacy task
        source: shell
        source-id: legacy-one
        branch: null
        project: ghostties
        created: 2026-04-22T22:35:00Z
        status: backlog
        ---

        ## Goal

        """
        let url = tmpDir.appendingPathComponent("legacy-one.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let store = TaskStore(directory: tmpDir)
        guard let task = store.loadFile(at: url) else {
            XCTFail("legacy task without new fields failed to load")
            return
        }
        XCTAssertNil(task.projectPath)
        XCTAssertNil(task.template)
        XCTAssertEqual(task.title, "Legacy task")
    }
}
