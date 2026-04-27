import XCTest
@testable import GhosttiesCore

/// Tests for `gt new --priority` CLI behavior. The test exercises:
///
/// 1. Writing a task with each priority value — asserts on-disk frontmatter.
/// 2. Default behavior (no flag) — asserts `priority:` field is absent.
/// 3. Cross-surface coherence — a file written via `gt new --priority high`
///    must load with `task.priority == .high`, same as MCP `create_task` with
///    `priority: "high"` (both delegate to `TaskStore.create`).
/// 4. CLI-layer strict parsing — invalid value must error; tests the guard
///    logic indirectly through the error contract.
///
/// Note: `NewCommand` lives in an executable target and cannot be imported.
/// These tests use `TaskStore` directly (the same path the command takes)
/// to assert the shared contract. The strict-parse guard at the CLI layer
/// is covered by the binary-invocation tests in `NewCommandBinaryTests`.
final class NewCommandTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-newcmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeStore() -> TaskStore { TaskStore(directory: tmpDir) }

    /// Simulates `gt new "<title>" --priority <value>` by calling the same
    /// `TaskStore.create` path the command uses.
    private func createTask(id: String,
                            title: String,
                            priority: TaskPriority = .none) throws -> URL {
        let nowISO = "2026-04-26T10:00:00Z"
        var pairs: [(String, String)] = [
            ("title", title),
            ("source", "shell"),
            ("source-id", id),
            ("branch", "null"),
            ("project", "ghostties"),
            ("created", nowISO),
            ("status", TaskLane.backlog.rawValue)
        ]
        // Mirror NewCommand: .none is NOT written to disk.
        if priority != .none {
            pairs.append(("priority", priority.rawValue))
        }
        return try makeStore().create(id: id, pairs: pairs,
                                      body: "\n## Goal\n\n\n## Notes\n\n")
    }

    // MARK: - Priority written to disk

    func testPriorityHighOnDisk() throws {
        let url = try createTask(id: "high-task", title: "High priority task", priority: .high)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("priority: high"),
                      "expected 'priority: high' in frontmatter:\n\(raw)")
    }

    func testPriorityMediumOnDisk() throws {
        let url = try createTask(id: "medium-task", title: "Medium priority task", priority: .medium)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("priority: medium"),
                      "expected 'priority: medium' in frontmatter:\n\(raw)")
    }

    func testPriorityLowOnDisk() throws {
        let url = try createTask(id: "low-task", title: "Low priority task", priority: .low)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("priority: low"),
                      "expected 'priority: low' in frontmatter:\n\(raw)")
    }

    // MARK: - Default behavior: .none omitted from frontmatter

    func testDefaultPriorityNoneIsOmitted() throws {
        // No --priority flag → .none → field must NOT appear on disk.
        let url = try createTask(id: "no-priority-task", title: "No priority task")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("priority:"),
                       "priority: field must be absent when priority is .none; got:\n\(raw)")
    }

    func testExplicitNonePriorityIsOmitted() throws {
        // --priority none → same behavior as omitting the flag.
        let url = try createTask(id: "explicit-none-task", title: "Explicit none", priority: .none)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("priority:"),
                       "priority: field must be absent when priority is .none; got:\n\(raw)")
    }

    // MARK: - Cross-surface round-trip coherence

    /// A task written by `gt new --priority high` (via TaskStore.create) must
    /// reload with `priority == .high`. This is the three-surface contract:
    /// TaskStore is the single write path for both CLI and MCP.
    func testPriorityRoundTrips() throws {
        let cases: [(TaskPriority, Bool)] = [
            (.high, true),
            (.medium, true),
            (.low, true),
            (.none, false)   // .none is not written, must reload as .none
        ]
        for (priority, expectOnDisk) in cases {
            let id = "roundtrip-\(priority.rawValue)"
            let url = try createTask(id: id, title: "Round-trip \(priority.rawValue)",
                                     priority: priority)
            let raw = try String(contentsOf: url, encoding: .utf8)

            if expectOnDisk {
                XCTAssertTrue(raw.contains("priority: \(priority.rawValue)"),
                              "priority: \(priority.rawValue) must appear on disk")
            } else {
                XCTAssertFalse(raw.contains("priority:"),
                               "priority: must be absent for .none")
            }

            guard let task = makeStore().loadFile(at: url) else {
                XCTFail("failed to reload task for priority \(priority.rawValue)")
                continue
            }
            XCTAssertEqual(task.priority, priority,
                           "loaded priority must match written priority for \(priority.rawValue)")
        }
    }

    // MARK: - CLI strict-parse contract

    /// The CLI layer must reject unknown priority values at parse time. This is
    /// the D27 contract. We test the guard logic by checking that
    /// `TaskPriority(rawValue:)` returns nil for invalid values, which is the
    /// exact condition NewCommand checks before throwing CLIError.usage.
    func testUnknownPriorityRawValueReturnsNil() {
        // These must all be nil — the CLI guard maps nil to CLIError.usage.
        let invalidValues = ["urgent", "critical", "normal", "HIGH", "  high  ", ""]
        for val in invalidValues {
            XCTAssertNil(TaskPriority(rawValue: val),
                         "TaskPriority(rawValue: \"\(val)\") must be nil — " +
                         "NewCommand uses this to detect invalid --priority input")
        }
    }

    /// The four valid raw values must all parse successfully (positive contract).
    func testValidPriorityRawValuesParseSuccessfully() {
        let valid: [(String, TaskPriority)] = [
            ("high", .high),
            ("medium", .medium),
            ("low", .low),
            ("none", .none)
        ]
        for (raw, expected) in valid {
            let parsed = TaskPriority(rawValue: raw)
            XCTAssertNotNil(parsed,
                            "TaskPriority(rawValue: \"\(raw)\") must parse successfully")
            XCTAssertEqual(parsed, expected,
                           "'\(raw)' must parse as .\(expected)")
        }
    }
}
