import XCTest
@testable import GhosttiesMCPClient

final class MCPSourceStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
        tempDir = base.appendingPathComponent("ghostties-mcp-source-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: -

    func testLoadMissingFileReturnsEmpty() throws {
        let store = MCPSourceStore(fileURL: tempDir.appendingPathComponent("mcp-sources.json"))
        let sources = try store.load()
        XCTAssertEqual(sources, [])
    }

    func testWriteThenReadRoundTripPreservesAllFields() throws {
        let file = tempDir.appendingPathComponent(".ghostties/mcp-sources.json")
        let store = MCPSourceStore(fileURL: file)

        let sources: [MCPSource] = [
            MCPSource(
                id: "linear",
                name: "Linear",
                transport: .stdio,
                endpoint: "/usr/local/bin/mcp-linear",
                args: ["--workspace", "ghostties"],
                env: ["LINEAR_API_KEY": "lin_xxx"]
            ),
            MCPSource(
                id: "sentry",
                name: "Sentry",
                transport: .http,
                endpoint: "https://example.invalid/mcp",
                args: nil,
                env: nil
            )
        ]

        try store.save(sources)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let loaded = try store.load()
        XCTAssertEqual(loaded, sources)

        // First source should have all fields round-tripped
        XCTAssertEqual(loaded[0].id, "linear")
        XCTAssertEqual(loaded[0].transport, .stdio)
        XCTAssertEqual(loaded[0].args, ["--workspace", "ghostties"])
        XCTAssertEqual(loaded[0].env?["LINEAR_API_KEY"], "lin_xxx")

        // Second source should have nil optionals
        XCTAssertNil(loaded[1].args)
        XCTAssertNil(loaded[1].env)
    }

    func testLoadMalformedJSONThrowsDecodingFailed() throws {
        let file = tempDir.appendingPathComponent("mcp-sources.json")
        try "this is not json { bad".write(to: file, atomically: true, encoding: .utf8)

        let store = MCPSourceStore(fileURL: file)

        XCTAssertThrowsError(try store.load()) { err in
            guard case MCPError.decodingFailed = err else {
                return XCTFail("expected MCPError.decodingFailed, got \(err)")
            }
        }
    }

    func testLoadEmptyFileReturnsEmpty() throws {
        let file = tempDir.appendingPathComponent("mcp-sources.json")
        try Data().write(to: file)
        let store = MCPSourceStore(fileURL: file)
        XCTAssertEqual(try store.load(), [])
    }

    func testOptionalFieldsOmittedWhenNil() throws {
        let file = tempDir.appendingPathComponent("mcp-sources.json")
        let store = MCPSourceStore(fileURL: file)
        let source = MCPSource(
            id: "bare",
            name: "Bare",
            transport: .stdio,
            endpoint: "/bin/echo",
            args: nil,
            env: nil
        )
        try store.save([source])

        // Inspect the written JSON — keys for optional nil fields must be absent
        // so the file stays minimal.
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains("\"args\""), "nil args should not be written")
        XCTAssertFalse(raw.contains("\"env\""), "nil env should not be written")

        let loaded = try store.load()
        XCTAssertEqual(loaded, [source])
    }
}
