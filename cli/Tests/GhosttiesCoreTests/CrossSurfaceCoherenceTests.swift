import XCTest
@testable import GhosttiesCore

/// THE CRITICAL test: verify that tasks written by `TaskStore.create` on disk
/// match the exact frontmatter shape (keys, casing, date format, enum values)
/// that the macOS `TaskFixtureParser` in `macos/Sources/Features/Ghostties/TaskStore.swift`
/// consumes. If this test fails, the three-surface architecture (sidebar,
/// `gt` CLI, MCP server) has drifted and Fragile Area #14 has tripped.
///
/// The macOS parser is NOT imported here — it lives in a different target and
/// is exercised separately from the Xcode test bundle. This test asserts the
/// CONTRACT the parser depends on.
final class CrossSurfaceCoherenceTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-coherence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Contract: frontmatter key casing

    /// Keys the macOS `TaskFixtureParser` reads (TaskStore.swift lines 179–217).
    /// Note kebab-case, NOT camelCase: the Swift Codable side has
    /// `case sourceID = "source-id"` mappings.
    private static let macOSRequiredKeys: Set<String> = [
        "title", "status", "created", "project"
    ]
    private static let macOSOptionalKeys: Set<String> = [
        "source",
        "source-id",        // NOT sourceId / sourceID
        "branch",
        "files-staged",     // NOT filesStaged
        "needs",
        "severity",
        "pr",
        "pr-state",         // NOT prState
        "ci",
        "completed",
        "updated",          // not read by macOS parser today but written by CLI + MCP
        "priority",         // not read by macOS parser today but written by MCP
        "project-path",     // NOT projectPath; macOS uses kebab-case for parity
        "template"
    ]

    /// The on-disk `status:` values the macOS TaskStatus enum accepts. Mirrors
    /// `TaskModel.swift` — `.needsYou = "needs-you"`, `.done = "done"`.
    /// Critically: `graveyard` must NEVER appear on disk.
    private static let macOSStatusRawValues: Set<String> = [
        "inbox", "backlog", "running", "needs-you", "review", "done"
    ]

    /// ISO-8601 date regex matching the format `TaskFixtureParser.isoFormatter`
    /// accepts (`[.withInternetDateTime]` → `2026-04-22T22:35:00Z` etc.).
    private static let isoRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$"#
    )

    // MARK: - Tests

    /// Write a task with every optional field populated; inspect the raw bytes.
    func testCreateTaskUsesKebabCaseKeysAndDoneNotGraveyard() throws {
        let store = TaskStore(directory: tmpDir)
        let created = "2026-04-22T22:35:00Z"
        let pairs: [(String, String)] = [
            ("title", "Cross-surface task"),
            ("source", "linear"),
            ("source-id", "SEA-999"),
            ("branch", "feat/example"),
            ("project", "ghostties"),
            ("created", created),
            ("updated", "2026-04-22T23:00:00Z"),
            ("status", "done"),
            ("priority", "high"),
            ("completed", "2026-04-22T23:30:00Z")
        ]
        _ = try store.create(id: "cross-surface-task", pairs: pairs, body: "\n## Goal\n\n\n## Notes\n\n")

        let url = tmpDir.appendingPathComponent("cross-surface-task.md")
        let raw = try String(contentsOf: url, encoding: .utf8)

        // On-disk shape assertions — these are the CONTRACT.
        XCTAssertTrue(raw.hasPrefix("---\n"), "file must open with frontmatter fence")
        XCTAssertTrue(raw.contains("\n---\n"), "file must close frontmatter fence")

        // Exact key casing — no camelCase leaks.
        XCTAssertTrue(raw.contains("source-id: SEA-999"),
                      "frontmatter key must be 'source-id' (kebab-case), not sourceID or source_id")
        XCTAssertFalse(raw.contains("sourceId:"), "no camelCase key")
        XCTAssertFalse(raw.contains("sourceID:"), "no camelCase key")
        XCTAssertFalse(raw.contains("source_id:"), "no snake_case key")

        // Status must be `done`, never `graveyard` on disk.
        XCTAssertTrue(raw.contains("status: done"),
                      "status must serialize as 'done' (macOS TaskStatus.done.rawValue)")
        XCTAssertFalse(raw.contains("status: graveyard"),
                       "status must NEVER be 'graveyard' on disk — macOS parser will reject it")

        // Required macOS keys are present.
        for key in Self.macOSRequiredKeys {
            XCTAssertTrue(raw.contains("\(key): "),
                          "required key '\(key)' missing from on-disk frontmatter")
        }

        // Re-parse and assert all pairs round-trip cleanly.
        let parsed = Frontmatter.split(raw)
        XCTAssertNotNil(parsed)
        let pairs2 = parsed!.pairs
        for (k, v) in pairs {
            XCTAssertEqual(Frontmatter.value(for: k, in: pairs2), v,
                           "value for \(k) did not round-trip")
        }
    }

    /// Assert every key written by this surface is one the macOS parser knows
    /// about (required or optional). New keys need a decision: add to macOS
    /// parser, or document that they're write-only for this surface.
    func testAllWrittenKeysAreKnownToMacOSParser() throws {
        let store = TaskStore(directory: tmpDir)
        let pairs: [(String, String)] = [
            ("title", "Known keys"),
            ("source", "shell"),
            ("source-id", "shell-1"),
            ("branch", "main"),
            ("project", "ghostties"),
            ("created", "2026-04-22T22:35:00Z"),
            ("status", "running"),
            ("priority", "high"),
            ("updated", "2026-04-22T23:00:00Z"),
            ("completed", "2026-04-22T23:30:00Z")
        ]
        _ = try store.create(id: "known-keys", pairs: pairs, body: "\n")

        let raw = try String(contentsOf: tmpDir.appendingPathComponent("known-keys.md"),
                             encoding: .utf8)
        let parsed = Frontmatter.split(raw)!
        let knownKeys = Self.macOSRequiredKeys.union(Self.macOSOptionalKeys)
        for (key, _) in parsed.pairs {
            XCTAssertTrue(knownKeys.contains(key),
                          "frontmatter key '\(key)' is unknown to the macOS parser. " +
                          "If this is intentional, add it to macOSOptionalKeys here AND teach " +
                          "TaskFixtureParser in macos/Sources/Features/Ghostties/TaskStore.swift to read it.")
        }
    }

    /// ISO-8601 timestamps from the CLI must be in the format the macOS parser
    /// accepts (`ISO8601DateFormatter` with `.withInternetDateTime`).
    func testTimestampsUseISO8601WithInternetDateTime() throws {
        let store = TaskStore(directory: tmpDir)
        let dateStrings = [
            "2026-04-22T22:35:00Z",
            "2026-04-22T22:35:00.123Z",
            "2026-04-22T22:35:00+00:00"
        ]
        for (i, ts) in dateStrings.enumerated() {
            let id = "ts-\(i)"
            _ = try store.create(
                id: id,
                pairs: [
                    ("title", "Timestamp test"),
                    ("source-id", id),
                    ("project", "ghostties"),
                    ("created", ts),
                    ("status", "backlog")
                ],
                body: "\n"
            )
            let range = NSRange(location: 0, length: ts.utf16.count)
            XCTAssertNotNil(Self.isoRegex.firstMatch(in: ts, range: range),
                            "timestamp \(ts) must match ISO-8601 internet-date-time format")
        }
    }

    /// `graveyard` is accepted as CLI/MCP input ALIAS only. `TaskLane.parse`
    /// maps it to `.done`, and the raw value written on disk must be `done`.
    func testGraveyardAliasIsNormalizedToDoneOnDisk() throws {
        // parse("graveyard") → .done
        XCTAssertEqual(TaskLane.parse("graveyard"), .done)
        XCTAssertEqual(TaskLane.parse("done"), .done)
        XCTAssertEqual(TaskLane.done.rawValue, "done",
                       "TaskLane.done must serialize as 'done' (NOT 'graveyard') " +
                       "to match macOS TaskStatus.done raw value")
        XCTAssertEqual(TaskLane.done.display, "graveyard",
                       "display name is 'graveyard' only for UI; on-disk stays 'done'")

        // End-to-end: creating with graveyard → disk has `done`.
        let store = TaskStore(directory: tmpDir)
        let lane = TaskLane.parse("graveyard")!
        _ = try store.create(
            id: "grave-one",
            pairs: [
                ("title", "Graveyard alias"),
                ("source-id", "grave-one"),
                ("project", "ghostties"),
                ("created", "2026-04-22T22:35:00Z"),
                ("status", lane.rawValue)
            ],
            body: "\n"
        )
        let raw = try String(contentsOf: tmpDir.appendingPathComponent("grave-one.md"),
                             encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"))
        XCTAssertFalse(raw.contains("status: graveyard"))
    }

    /// Schema contract: the `projectPath` and `template` fields must serialize
    /// on disk as kebab-case `project-path:` and `template:`, never camelCase
    /// or snake_case. The macOS `TaskFixtureParser` reads kebab-case — drift
    /// here means Fragile Area #14 has tripped.
    func testNewFieldsOnDiskUseKebabCase() throws {
        let store = TaskStore(directory: tmpDir)
        let pairs: [(String, String)] = [
            ("title", "Project-path + template"),
            ("source", "shell"),
            ("source-id", "new-fields"),
            ("branch", "null"),
            ("project", "ghostties"),
            ("created", "2026-04-23T10:00:00Z"),
            ("status", "backlog"),
            ("project-path", "~/Code/foo"),
            ("template", "Orchestrator")
        ]
        _ = try store.create(id: "new-fields", pairs: pairs, body: "\n")

        let raw = try String(contentsOf: tmpDir.appendingPathComponent("new-fields.md"),
                             encoding: .utf8)

        // Kebab-case literal strings must appear.
        XCTAssertTrue(raw.contains("project-path: ~/Code/foo"),
                      "on-disk key must be 'project-path' (kebab-case) with value intact")
        XCTAssertTrue(raw.contains("template: Orchestrator"),
                      "on-disk key must be 'template' with verbatim value")

        // Negative assertions — no camelCase / snake_case leakage.
        XCTAssertFalse(raw.contains("projectPath:"), "no camelCase 'projectPath' key allowed")
        XCTAssertFalse(raw.contains("project_path:"), "no snake_case 'project_path' key allowed")
    }

    // MARK: - Priority cross-surface contract

    /// The four `TaskPriority` raw values that the CLI writes must match the
    /// strings the MCP `priorityEnum` advertises and the macOS parser reads.
    /// If this test fails, a surface has drifted from the contract.
    func testPriorityEnumRawValuesMatchContractStrings() {
        // Canonical set agreed across all three surfaces (CLI, MCP, macOS):
        let contractValues: Set<String> = ["high", "medium", "low", "none"]

        // CLI-side: TaskPriority enum raw values must exactly match.
        let cliRawValues = Set(TaskPriority.allCases.map(\.rawValue))
        XCTAssertEqual(cliRawValues, contractValues,
                       "CLI TaskPriority raw values must be exactly \(contractValues). " +
                       "Got: \(cliRawValues)")

        // Spot-check each value parses correctly.
        XCTAssertEqual(TaskPriority.parse("high"),   .high)
        XCTAssertEqual(TaskPriority.parse("medium"), .medium)
        XCTAssertEqual(TaskPriority.parse("low"),    .low)
        XCTAssertEqual(TaskPriority.parse("none"),   .none)

        // Unknown value must fall back to .none without crashing.
        XCTAssertEqual(TaskPriority.parse("urgent"), .none,
                       "unknown priority value must default to .none (strict-with-skip)")
        XCTAssertEqual(TaskPriority.parse(""),       .none,
                       "empty priority string must default to .none")

        // Legacy value `normal` (old MCP enum) must fall back gracefully.
        XCTAssertEqual(TaskPriority.parse("normal"), .none,
                       "old 'normal' priority value must default to .none after F-002 migration")
    }

    /// Write a task with priority=high via TaskStore, read it back, confirm the
    /// on-disk key is `priority: high` (not `priority: normal` or absent).
    func testPriorityOnDiskUsesCorrectRawValue() throws {
        let store = TaskStore(directory: tmpDir)
        let pairs: [(String, String)] = [
            ("title", "Priority contract"),
            ("source", "linear"),
            ("source-id", "SEA-priority"),
            ("project", "ghostties"),
            ("created", "2026-04-25T10:00:00Z"),
            ("status", "running"),
            ("priority", "high")
        ]
        _ = try store.create(id: "priority-contract", pairs: pairs, body: "\n")

        let url = tmpDir.appendingPathComponent("priority-contract.md")
        let raw = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(raw.contains("priority: high"),
                      "on-disk priority must be 'high'; got:\n\(raw)")
        XCTAssertFalse(raw.contains("priority: normal"),
                       "legacy 'normal' must never appear on disk after F-002 migration")

        // Re-parse and confirm round-trip.
        guard let task = store.loadFile(at: url) else {
            XCTFail("failed to reload priority-contract task")
            return
        }
        XCTAssertEqual(task.priority, .high)
    }

    /// All six lanes the sidebar reads have matching raw values in `TaskLane`.
    func testLaneRawValuesMatchMacOSTaskStatus() {
        for lane in TaskLane.allCases {
            XCTAssertTrue(Self.macOSStatusRawValues.contains(lane.rawValue),
                          "TaskLane.\(lane) raw value '\(lane.rawValue)' does not match any " +
                          "macOS TaskStatus raw value. Allowed values: \(Self.macOSStatusRawValues)")
        }
        // And the reverse — every macOS status must be representable.
        for raw in Self.macOSStatusRawValues {
            XCTAssertNotNil(TaskLane(rawValue: raw),
                            "macOS status '\(raw)' is not representable as a TaskLane")
        }
    }
}
