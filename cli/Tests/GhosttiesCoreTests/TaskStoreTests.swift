import XCTest
@testable import GhosttiesCore

final class TaskStoreTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    private func makeStore() -> TaskStore { TaskStore(directory: tmpDir) }

    private func writeFixture(id: String,
                              title: String = "Sample task",
                              status: String = "backlog",
                              extra: [(String, String)] = [],
                              body: String = "\n## Notes\n\n") throws -> URL {
        var pairs: [(String, String)] = [
            ("title", title),
            ("source", "shell"),
            ("source-id", id),
            ("branch", "null"),
            ("project", "ghostties"),
            ("created", "2026-04-22T22:35:00Z"),
            ("status", status)
        ]
        pairs.append(contentsOf: extra)
        let store = makeStore()
        return try store.create(id: id, pairs: pairs, body: body)
    }

    // MARK: - create + loadAll

    func testCreateWritesFileAndLoadAllSeesIt() throws {
        _ = try writeFixture(id: "test-task-abc123")
        let tasks = makeStore().loadAll()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, "test-task-abc123")
        XCTAssertEqual(tasks.first?.title, "Sample task")
        XCTAssertEqual(tasks.first?.lane, .backlog)
    }

    func testCreateThrowsWhenFileExists() throws {
        _ = try writeFixture(id: "duplicate")
        XCTAssertThrowsError(try writeFixture(id: "duplicate"))
    }

    func testLoadAllIgnoresNonMarkdownFiles() throws {
        _ = try writeFixture(id: "good")
        try "not a task".write(to: tmpDir.appendingPathComponent("README.txt"),
                               atomically: true, encoding: .utf8)
        try "{}".write(to: tmpDir.appendingPathComponent("data.json"),
                       atomically: true, encoding: .utf8)
        let tasks = makeStore().loadAll()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, "good")
    }

    func testLoadAllSkipsMalformedFiles() throws {
        _ = try writeFixture(id: "valid")
        let badURL = tmpDir.appendingPathComponent("broken.md")
        try "no frontmatter at all".write(to: badURL, atomically: true, encoding: .utf8)
        let tasks = makeStore().loadAll()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, "valid")
    }

    // MARK: - status update round-trip

    func testStatusUpdatePersistsAcrossReload() throws {
        let url = try writeFixture(id: "status-change", status: "backlog")
        let store = makeStore()
        let (task, _) = try store.resolve(idOrPrefix: "status-change")
        let updated = Frontmatter.set("status", "running", in: task.frontmatter)
        try store.write(pairs: updated, body: task.body, to: url)

        let reloaded = store.loadFile(at: url)
        XCTAssertEqual(reloaded?.lane, .running)
    }

    // MARK: - notes append round-trip

    func testBodyWritePersistsAcrossReload() throws {
        let url = try writeFixture(id: "notes-task",
                                   body: "\n## Notes\n\n")
        let store = makeStore()
        let (task, _) = try store.resolve(idOrPrefix: "notes-task")
        let newBody = task.body + "- [2026-04-23 10:00] first note\n"
        try store.write(pairs: task.frontmatter, body: newBody, to: url)

        let reloaded = store.loadFile(at: url)
        XCTAssertNotNil(reloaded)
        XCTAssertTrue(reloaded!.body.contains("first note"))
    }

    // MARK: - resolve — prefix + ambiguity + not found

    func testResolveMatchesUniquePrefix() throws {
        _ = try writeFixture(id: "alpha-one-111111")
        _ = try writeFixture(id: "beta-two-222222")
        let store = makeStore()
        let (task, _) = try store.resolve(idOrPrefix: "alpha")
        XCTAssertEqual(task.id, "alpha-one-111111")
    }

    func testResolveExactMatchBeatsPrefix() throws {
        _ = try writeFixture(id: "foo")
        _ = try writeFixture(id: "foo-longer")
        let store = makeStore()
        let (task, _) = try store.resolve(idOrPrefix: "foo")
        XCTAssertEqual(task.id, "foo")
    }

    func testResolveThrowsAmbiguousOnMultiplePrefixMatches() throws {
        _ = try writeFixture(id: "share-one")
        _ = try writeFixture(id: "share-two")
        XCTAssertThrowsError(try makeStore().resolve(idOrPrefix: "share")) { error in
            guard case CLIError.ambiguousID(_, let matches) = error else {
                XCTFail("expected ambiguousID, got \(error)")
                return
            }
            XCTAssertEqual(Set(matches), Set(["share-one", "share-two"]))
        }
    }

    func testResolveThrowsNotFoundForNonexistentId() throws {
        _ = try writeFixture(id: "exists")
        XCTAssertThrowsError(try makeStore().resolve(idOrPrefix: "missing")) { error in
            guard case CLIError.notFound(let msg) = error else {
                XCTFail("expected notFound, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("missing"))
        }
    }

    // MARK: - loadFile edge cases

    func testLoadFileReturnsNilForMissingURL() {
        let missing = tmpDir.appendingPathComponent("does-not-exist.md")
        XCTAssertNil(makeStore().loadFile(at: missing))
    }

    func testLoadFileReturnsNilWhenRequiredFieldsMissing() throws {
        let url = tmpDir.appendingPathComponent("no-title.md")
        let contents = """
        ---
        status: running
        ---
        body
        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(makeStore().loadFile(at: url))
    }

    // MARK: - resolveByFilename fast path

    func testResolveByFilenameExactHit() throws {
        _ = try writeFixture(id: "fast-task-abc123", title: "Fast task")
        let (task, _) = try makeStore().resolveByFilename(idOrPrefix: "fast-task-abc123")
        XCTAssertEqual(task.id, "fast-task-abc123")
        XCTAssertEqual(task.title, "Fast task")
    }

    func testResolveByFilenameFallsBackToPrefixScan() throws {
        _ = try writeFixture(id: "prefix-only-xyz789", title: "Prefix task")
        // Pass only a prefix — no exact filename match, must fall back to full scan.
        let (task, _) = try makeStore().resolveByFilename(idOrPrefix: "prefix-only")
        XCTAssertEqual(task.id, "prefix-only-xyz789")
    }

    func testResolveByFilenameThrowsNotFoundWhenMissing() throws {
        _ = try writeFixture(id: "exists-task")
        XCTAssertThrowsError(try makeStore().resolveByFilename(idOrPrefix: "does-not-exist")) { error in
            guard case CLIError.notFound(_) = error else {
                XCTFail("expected notFound, got \(error)")
                return
            }
        }
    }
}
