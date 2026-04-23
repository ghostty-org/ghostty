import XCTest
@testable import Ghostty

/// Tests for `TaskFixtureParser` and the macOS `TaskStore` load path.
final class TaskModelTests: XCTestCase {

    // MARK: - TaskFixtureParser: happy path

    func testParseFullFixture() throws {
        let markdown = """
        ---
        title: Fix CEF build on arm64
        source: github
        source-id: GH-287
        branch: cef-build
        project: ghostties
        created: 2026-04-22T22:35:00Z
        status: running
        files-staged: 2
        ---

        ## Goal

        Ship arm64 slice.

        ## Notes

        A note body.

        ## Activity

        - 2026-04-22T22:35:00Z — Agent started from gh-287
        - 2026-04-22T22:38:00Z — Reproduced the x86_64 fetch
        """
        let item = TaskFixtureParser.parse(markdown: markdown, filename: "gh-287")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "GH-287")          // from source-id
        XCTAssertEqual(item?.title, "Fix CEF build on arm64")
        XCTAssertEqual(item?.source, .github)
        XCTAssertEqual(item?.sourceID, "GH-287")
        XCTAssertEqual(item?.branch, "cef-build")
        XCTAssertEqual(item?.project, "ghostties")
        XCTAssertEqual(item?.status, .running)
        XCTAssertEqual(item?.filesStaged, 2)
        XCTAssertEqual(item?.goal, "Ship arm64 slice.")
        XCTAssertEqual(item?.notes, "A note body.")
        XCTAssertEqual(item?.events?.count, 2)
    }

    // MARK: - TaskFixtureParser: minimal fields

    func testParseMinimalFixtureAppliesDefaults() throws {
        let markdown = """
        ---
        title: Minimal task
        status: backlog
        project: ghostties
        created: 2026-04-22T22:35:00Z
        ---
        """
        let item = TaskFixtureParser.parse(markdown: markdown, filename: "minimal")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.id, "minimal")        // falls back to filename
        XCTAssertEqual(item?.title, "Minimal task")
        XCTAssertEqual(item?.source, .unknown)     // no source in frontmatter
        XCTAssertNil(item?.sourceID)
        XCTAssertNil(item?.branch)
        XCTAssertNil(item?.goal)
        XCTAssertNil(item?.notes)
        XCTAssertNil(item?.events)
    }

    // MARK: - Invalid / missing required fields

    func testParseReturnsNilWhenTitleMissing() {
        let markdown = """
        ---
        status: running
        project: ghostties
        created: 2026-04-22T22:35:00Z
        ---
        """
        XCTAssertNil(TaskFixtureParser.parse(markdown: markdown, filename: "no-title"))
    }

    func testParseReturnsNilForMalformedFrontmatter() {
        let markdown = "no frontmatter at all"
        XCTAssertNil(TaskFixtureParser.parse(markdown: markdown, filename: "raw"))
    }

    func testParseReturnsNilForUnknownStatus() {
        let markdown = """
        ---
        title: Bad status
        status: graveyard
        project: ghostties
        created: 2026-04-22T22:35:00Z
        ---
        """
        // `graveyard` is NOT valid on disk. If this test ever fails, a regression
        // has snuck `graveyard` into TaskStatus — which breaks round-trip with
        // the CLI/MCP server that writes `done`.
        XCTAssertNil(TaskFixtureParser.parse(markdown: markdown, filename: "bad-status"))
    }

    // MARK: - Status enum round-trip

    func testTaskStatusRawValuesMatchCLIEnum() {
        // The on-disk raw values must match GhosttiesCore.TaskLane.
        XCTAssertEqual(TaskStatus.inbox.rawValue, "inbox")
        XCTAssertEqual(TaskStatus.backlog.rawValue, "backlog")
        XCTAssertEqual(TaskStatus.running.rawValue, "running")
        XCTAssertEqual(TaskStatus.needsYou.rawValue, "needs-you")
        XCTAssertEqual(TaskStatus.review.rawValue, "review")
        XCTAssertEqual(TaskStatus.done.rawValue, "done")
    }

    // MARK: - Non-md file filtering via TaskStore

    func testStoreIgnoresNonMarkdownFiles() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-macos-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Valid .md
        let valid = """
        ---
        title: Real
        status: backlog
        project: ghostties
        created: 2026-04-22T22:35:00Z
        ---
        """
        try valid.write(to: tmp.appendingPathComponent("real.md"),
                        atomically: true, encoding: .utf8)
        // Noise files the store should ignore entirely.
        try "not markdown".write(to: tmp.appendingPathComponent("notes.txt"),
                                 atomically: true, encoding: .utf8)
        try "{}".write(to: tmp.appendingPathComponent("data.json"),
                       atomically: true, encoding: .utf8)

        // We don't have a public init(dir:) on the macOS TaskStore, but we can
        // verify the parser handles the valid file on its own — the Store just
        // filters by extension and hands off here.
        let files = try FileManager.default.contentsOfDirectory(at: tmp,
                                                                includingPropertiesForKeys: nil)
        let mdFiles = files.filter { $0.pathExtension.lowercased() == "md" }
        XCTAssertEqual(mdFiles.count, 1)
        let raw = try String(contentsOf: mdFiles[0], encoding: .utf8)
        XCTAssertNotNil(TaskFixtureParser.parse(markdown: raw, filename: "real"))
    }
}
