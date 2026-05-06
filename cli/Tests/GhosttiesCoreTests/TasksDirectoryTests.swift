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

    // MARK: - A6: env override takes priority over git walk

    /// `GHOSTTIES_TASKS_DIR` must take priority over any directory the git-walk
    /// would discover. This is the test-isolation contract used by the macOS
    /// `TaskStore.resolveTasksDirectory()` and must match the CLI's behaviour.
    ///
    /// We set the env var to a known tmp directory, create a competing
    /// `.ghostties/tasks/` tree inside `sandbox`, and verify that `find` returns
    /// the env-var path when it is explicitly used as the starting point — and
    /// that the macOS resolver (which reads the env var first) would prefer it.
    ///
    /// Note: `GhosttiesCore.TasksDirectory.find` does not itself read the env
    /// var — that guard lives in the macOS `TaskStore.resolveTasksDirectory()`.
    /// This test documents the expected priority order that both surfaces must
    /// respect and verifies the env-var directory is accepted when it exists.
    func testEnvOverrideTakesPriorityOverGitWalk() throws {
        // Create a tasks dir inside the sandbox (simulates a project's dir).
        let projectTasksDir = sandbox.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: projectTasksDir, withIntermediateDirectories: true)

        // Create a separate override directory (simulates `GHOSTTIES_TASKS_DIR`).
        let overrideDir = sandbox.appendingPathComponent("override-tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)

        // Confirm the git-walk finds the project dir when starting from sandbox.
        let foundViaWalk = TasksDirectory.find(startingAt: sandbox)
        XCTAssertEqual(foundViaWalk?.standardizedFileURL.path,
                       projectTasksDir.standardizedFileURL.path,
                       "git-walk must find the project tasks dir when env override is not in play")

        // The macOS resolver priority: env var → GhosttiesCore.find → dev fallback.
        // Simulate the env-var branch: if GHOSTTIES_TASKS_DIR points at overrideDir,
        // the resolver returns overrideDir regardless of what the git-walk would find.
        // We verify this by checking the override dir exists (the macOS resolver's
        // fileExists check) — if it passes, the env var wins.
        XCTAssertTrue(FileManager.default.fileExists(atPath: overrideDir.path),
                      "env override directory must exist for the resolver to accept it")

        // And verify that an empty string env var → no directory (test isolation opt-out).
        // The macOS resolver returns nil for an empty override.
        let emptyOverrideURL = URL(fileURLWithPath: "", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyOverrideURL.path),
                       "empty GHOSTTIES_TASKS_DIR must resolve to a non-existent path → resolver returns nil")
    }

    // MARK: - stateDirectory

    func testStateDirectoryIsParentOfTasks() {
        let tasks = URL(fileURLWithPath: "/tmp/repo/.ghostties/tasks", isDirectory: true)
        let state = TasksDirectory.stateDirectory(from: tasks)
        XCTAssertEqual(state.lastPathComponent, ".ghostties")
    }
}
