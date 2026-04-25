import XCTest
@testable import GhosttiesCore

final class TasksDirectoryTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-dir-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - find

    func testFindReturnsTasksDirWhenAtCurrentLevel() throws {
        let tasksDir = sandbox.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)

        let found = TasksDirectory.find(startingAt: sandbox)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.standardizedFileURL.path, tasksDir.standardizedFileURL.path)
    }

    func testFindWalksUpFromNestedDirectory() throws {
        let tasksDir = sandbox.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)

        let deepDir = sandbox.appendingPathComponent("src/lib/feature", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

        let found = TasksDirectory.find(startingAt: deepDir)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.standardizedFileURL.path, tasksDir.standardizedFileURL.path)
    }

    func testFindReturnsNilWhenNoTasksDirExists() throws {
        // sandbox has no .ghostties dir. Walking up will terminate at / or $HOME.
        let deepDir = sandbox.appendingPathComponent("nested/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let found = TasksDirectory.find(startingAt: deepDir)
        XCTAssertNil(found)
    }

    // MARK: - require

    func testRequireThrowsWhenNoTasksDirFound() throws {
        let nowhereURL = sandbox.appendingPathComponent("nowhere", isDirectory: true)
        try FileManager.default.createDirectory(at: nowhereURL, withIntermediateDirectories: true)

        // Only run this assertion if sandbox is outside $HOME so the walk-up
        // doesn't incidentally find a real .ghostties dir. NSTemporaryDirectory()
        // on macOS lives under /var/folders/… which is not under $HOME.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard !nowhereURL.standardizedFileURL.path.hasPrefix(home) else {
            throw XCTSkip("tmp dir unexpectedly under $HOME; skipping")
        }

        XCTAssertThrowsError(try TasksDirectory.require(startingAt: nowhereURL)) { error in
            guard case CLIError.notFound = error else {
                XCTFail("expected notFound, got \(error)")
                return
            }
        }
    }

    // MARK: - findOrCreate

    func testFindOrCreateCreatesDirectoryWhenNoneFound() throws {
        let workDir = sandbox.appendingPathComponent("fresh-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard !workDir.standardizedFileURL.path.hasPrefix(home) else {
            throw XCTSkip("tmp dir unexpectedly under $HOME; skipping")
        }

        let created = try TasksDirectory.findOrCreate(startingAt: workDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(created.lastPathComponent, "tasks")
        XCTAssertEqual(created.standardizedFileURL.path,
                       workDir.appendingPathComponent(".ghostties/tasks").standardizedFileURL.path)
    }

    // MARK: - stateDirectory

    func testStateDirectoryIsParentOfTasks() {
        let tasks = URL(fileURLWithPath: "/tmp/repo/.ghostties/tasks", isDirectory: true)
        let state = TasksDirectory.stateDirectory(from: tasks)
        XCTAssertEqual(state.lastPathComponent, ".ghostties")
    }
}
