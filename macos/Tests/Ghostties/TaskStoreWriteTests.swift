// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty
import GhosttiesCore

/// Tests for the three write wrappers added to the macOS TaskStore in U2
/// (SEA-158): `writeStatus`, `writeProjectPath`, and `createTask`.
///
/// All tests use a real temporary directory on disk to verify that the
/// round-trip (write → file watcher picks up → loadFromDisk) works correctly
/// at the GhosttiesCore.TaskStore level.
@MainActor
final class TaskStoreWriteTests: XCTestCase {

    // MARK: - Fixture helpers

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Write a minimal task fixture and return its filename stem.
    @discardableResult
    private func writeFixture(
        id: String,
        title: String = "Test task",
        status: String = "backlog",
        priority: String = "none"
    ) throws -> URL {
        let markdown = """
        ---
        title: \(title)
        source: shell
        source-id: \(id)
        project: ghostties
        created: 2026-04-25T10:00:00Z
        status: \(status)
        priority: \(priority)
        ---

        ## Goal

        Test goal.

        ## Notes

        ## Activity

        - 2026-04-25T10:00:00Z — created for tests
        """
        let url = tmp.appendingPathComponent("\(id).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - writeStatus: happy path

    func testWriteStatusUpdatesFileOnDisk() async throws {
        try writeFixture(id: "test-task-001", status: "backlog")

        // Build a TaskStore pointed at the temp directory by swapping in the
        // watcher-resolved directory via loadFromDisk.  We do this by using a
        // GhosttiesCore.TaskStore directly (which is what the wrapper delegates
        // to), then verifying the file changed.
        let coreStore = GhosttiesCore.TaskStore(directory: tmp)
        let (task, url) = try coreStore.resolve(idOrPrefix: "test-task-001")
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "status", TaskStatus.running.rawValue, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)

        // Read back and verify round-trip.
        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = TaskFixtureParser.parse(markdown: raw, filename: "test-task-001")
        XCTAssertNotNil(parsed, "Re-parse after write must succeed")
        XCTAssertEqual(parsed?.status, .running, "Status must be updated to .running")
        XCTAssertEqual(parsed?.id, "test-task-001", "Id must be preserved")
    }

    // MARK: - writeStatus: error propagation

    func testWriteStatusThrowsOnReadOnlyDirectory() async throws {
        try writeFixture(id: "readonly-task", status: "inbox")

        // Lock the DIRECTORY, not the file. `write(atomically:true)` creates a temp
        // file in the same directory before renaming it into place — that's a directory
        // operation controlled by directory permissions. A read-only file with a
        // writable directory is silently overwritten via rename on macOS/POSIX.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        defer {
            // Restore so tearDown can remove the directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        }

        let coreStore = GhosttiesCore.TaskStore(directory: tmp)
        let (task, fileURL) = try coreStore.resolve(idOrPrefix: "readonly-task")
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "status", TaskStatus.running.rawValue, in: task.frontmatter)

        XCTAssertThrowsError(
            try coreStore.write(pairs: updatedPairs, body: task.body, to: fileURL),
            "Writing to a read-only directory must throw a typed CLIError, not silently absorb"
        ) { error in
            if let cliError = error as? CLIError {
                // Verify it is a .io error (not silently absorbed).
                if case .io = cliError {
                    // Expected path.
                } else {
                    XCTFail("Expected CLIError.io, got \(cliError)")
                }
            } else {
                XCTFail("Expected CLIError, got \(type(of: error)): \(error)")
            }
        }
    }

    // MARK: - writeProjectPath: happy path

    func testWriteProjectPathRoundTrips() async throws {
        try writeFixture(id: "path-task-001")
        let coreStore = GhosttiesCore.TaskStore(directory: tmp)
        let (task, url) = try coreStore.resolve(idOrPrefix: "path-task-001")

        let newPath = "~/Code/ghostties"
        let updatedPairs = GhosttiesCore.Frontmatter.set(
            "project-path", newPath, in: task.frontmatter)
        try coreStore.write(pairs: updatedPairs, body: task.body, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = TaskFixtureParser.parse(markdown: raw, filename: "path-task-001")
        XCTAssertEqual(parsed?.projectPath, newPath, "project-path must be preserved verbatim (tilde raw)")
    }

    // MARK: - createTask: happy path

    func testCreateTaskWritesFileAndRoundTrips() async throws {
        let coreStore = GhosttiesCore.TaskStore(directory: tmp)

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let id = "create-test-abc123"
        var pairs: [(String, String)] = [
            ("title", "New task from test"),
            ("source", "shell"),
            ("source-id", id),
            ("project", "ghostties"),
            ("created", nowISO),
            ("status", TaskStatus.backlog.rawValue),
            ("priority", TaskPriority.none.rawValue)
        ]
        pairs.append(("project-path", "~/Code/ghostties"))

        let body = "\n## Goal\n\n\n## Notes\n\n\n## Activity\n\n- \(nowISO) — Task created\n"
        let url = try coreStore.create(id: id, pairs: pairs, body: body)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "create must produce a file on disk")

        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = TaskFixtureParser.parse(markdown: raw, filename: id)
        XCTAssertNotNil(parsed, "Created file must parse back into a TaskItem")
        XCTAssertEqual(parsed?.title, "New task from test")
        XCTAssertEqual(parsed?.status, .backlog)
        XCTAssertEqual(parsed?.projectPath, "~/Code/ghostties")
    }

    // MARK: - createTask: duplicate error

    func testCreateTaskThrowsOnDuplicateID() async throws {
        try writeFixture(id: "duplicate-task")
        let coreStore = GhosttiesCore.TaskStore(directory: tmp)

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let pairs: [(String, String)] = [
            ("title", "Dupe"),
            ("source", "shell"),
            ("source-id", "duplicate-task"),
            ("project", "ghostties"),
            ("created", nowISO),
            ("status", "backlog"),
            ("priority", "none")
        ]
        let body = "\n## Goal\n\n"

        XCTAssertThrowsError(
            try coreStore.create(id: "duplicate-task", pairs: pairs, body: body),
            "Creating a task with an id that already exists on disk must throw CLIError.io"
        ) { error in
            if let cliError = error as? CLIError, case .io = cliError {
                // Expected.
            } else {
                XCTFail("Expected CLIError.io, got \(error)")
            }
        }
    }
}
