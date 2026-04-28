import XCTest
import Foundation

/// Drive the `ghostties-mcp` binary as a subprocess, pipe JSON-RPC in on stdin,
/// and assert the responses on stdout. Mirrors `cli/scripts/smoke-mcp.sh` but
/// as XCTest so CI can fail loudly on protocol regressions.
///
/// Requires the `ghostties-mcp` executable. `swift test` builds sibling
/// executable targets in the same build output, so we resolve it relative to
/// the test bundle's build directory.
final class MCPProtocolTests: XCTestCase {
    var tmpDir: URL!
    var tasksDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        tasksDir = tmpDir.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Binary resolution

    /// Resolve the `ghostties-mcp` binary relative to the test bundle. When
    /// running under `swift test`, the bundle lives in `.build/<config>/`
    /// next to the executable.
    private func mcpBinaryURL() throws -> URL {
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        // On macOS the xctest bundle is at .../PackageTests.xctest; its parent
        // holds sibling products including `ghostties-mcp`.
        var dir = bundleURL.deletingLastPathComponent()

        // Walk a few candidate parents in case the bundle structure is different.
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("ghostties-mcp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("ghostties-mcp binary not found next to test bundle")
    }

    // MARK: - Driver

    /// Send a script of JSON-RPC lines, collect stdout lines, return parsed
    /// responses keyed by id.
    private func driveServer(_ requests: [[String: Any]]) throws -> [Int: [String: Any]] {
        let bin = try mcpBinaryURL()

        let process = Process()
        process.executableURL = bin
        process.arguments = ["--tasks-dir", tasksDir.path]
        process.currentDirectoryURL = tmpDir

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write all requests and close stdin so the server exits cleanly.
        for req in requests {
            let data = try JSONSerialization.data(withJSONObject: req, options: [])
            stdinPipe.fileHandleForWriting.write(data)
            stdinPipe.fileHandleForWriting.write(Data([0x0A]))
        }
        try stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: stdoutData, encoding: .utf8) ?? ""
        var byID: [Int: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let id = obj["id"] as? Int {
                byID[id] = obj
            }
        }
        return byID
    }

    // MARK: - Helpers for result-shape assertions

    private func toolResultText(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else { return nil }
        return text
    }

    private func toolIsError(_ response: [String: Any]) -> Bool {
        guard let result = response["result"] as? [String: Any],
              let isError = result["isError"] as? Bool else { return false }
        return isError
    }

    // MARK: - Tests

    func testInitializeHandshake() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05",
                        "capabilities": [:],
                        "clientInfo": ["name": "test", "version": "0"]]]
        ])
        guard let resp = responses[1] else {
            XCTFail("no response to initialize")
            return
        }
        let result = resp["result"] as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "ghostties-mcp")
    }

    func testToolsListReturnsElevenToolsWithSchemas() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]]
        ])
        guard let resp = responses[2],
              let result = resp["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            XCTFail("tools/list did not return a tools array")
            return
        }
        XCTAssertEqual(tools.count, 11, "expected 11 tools, got \(tools.count)")

        let expectedNames: Set<String> = [
            "list_tasks", "get_task", "create_task", "update_task_status",
            "get_active", "get_needs_you", "read_task_notes",
            "append_task_notes", "get_inbox", "write_session_notes",
            "set_task_project"
        ]
        let actualNames = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(actualNames, expectedNames)

        // Every tool must have a valid JSON-Schema inputSchema.
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            let schema = tool["inputSchema"] as? [String: Any]
            XCTAssertNotNil(schema, "tool \(name) missing inputSchema")
            XCTAssertEqual(schema?["type"] as? String, "object",
                           "tool \(name) schema type must be 'object'")
        }
    }

    func testCreateTaskMinimalThenListIncludesIt() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "First task"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "list_tasks", "arguments": [:]]]
        ])
        guard let createResp = responses[2] else {
            XCTFail("no response to create_task")
            return
        }
        XCTAssertFalse(toolIsError(createResp), "create_task returned error")
        let createText = toolResultText(createResp) ?? ""
        XCTAssertTrue(createText.contains("First task"))

        guard let listResp = responses[3],
              let listText = toolResultText(listResp),
              let listArray = try? JSONSerialization.jsonObject(with: Data(listText.utf8)) as? [[String: Any]]
        else {
            XCTFail("list_tasks did not return a JSON array")
            return
        }
        let titles = listArray.compactMap { $0["title"] as? String }
        XCTAssertTrue(titles.contains("First task"))
    }

    func testAppendTaskNotesPersistsToDisk() throws {
        // Pre-create a task via create_task so we know the id prefix.
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Notes target", "lane": "backlog"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "append_task_notes",
                        "arguments": ["id": "notes-target",
                                      "text": "xctest note"]]]
        ])
        guard let appendResp = responses[3] else {
            XCTFail("no response to append_task_notes")
            return
        }
        XCTAssertFalse(toolIsError(appendResp))

        // Verify disk contents.
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let notesFile = files.first(where: { $0.hasPrefix("notes-target") }) else {
            XCTFail("notes-target-*.md not written; saw \(files)")
            return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(notesFile),
                             encoding: .utf8)
        XCTAssertTrue(raw.contains("xctest note"), "note content missing from file")
    }

    func testUpdateStatusWithGraveyardAliasWritesDoneToDisk() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Graveyard candidate"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": "graveyard-candidate",
                                      "status": "graveyard"]]]
        ])
        guard let updateResp = responses[3] else {
            XCTFail("no response to update_task_status")
            return
        }
        XCTAssertFalse(toolIsError(updateResp))
        let text = toolResultText(updateResp) ?? ""
        // lane returned is the display name — that's fine.
        // What matters is the ON-DISK status value.
        XCTAssertTrue(text.contains("\"lane\": \"graveyard\"") || text.contains("graveyard"))

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("graveyard-candidate") }) else {
            XCTFail("file missing: \(files)")
            return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"),
                      "on-disk status must be 'done' after graveyard alias input; got:\n\(raw)")
        XCTAssertFalse(raw.contains("status: graveyard"),
                       "'graveyard' must never appear on disk; got:\n\(raw)")
    }

    func testGetTaskReturnsFullDetail() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Detail target",
                                      "notes": "initial note body"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "get_task",
                        "arguments": ["id": "detail-target"]]]
        ])
        guard let getResp = responses[3] else {
            XCTFail("no response to get_task")
            return
        }
        XCTAssertFalse(toolIsError(getResp))
        let text = toolResultText(getResp) ?? ""
        XCTAssertTrue(text.contains("Detail target"))
        XCTAssertTrue(text.contains("initial note body"))
    }

    // MARK: - Error paths

    func testUnknownToolReturnsJSONRPCErrorOrToolError() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "does_not_exist", "arguments": [:]]]
        ])
        guard let resp = responses[2] else {
            XCTFail("no response for unknown tool")
            return
        }
        // Server maps unknown tool names to JSON-RPC error code -32602.
        if let error = resp["error"] as? [String: Any] {
            XCTAssertEqual(error["code"] as? Int, -32602)
            let message = error["message"] as? String ?? ""
            XCTAssertTrue(message.contains("unknown tool"))
        } else if toolIsError(resp) {
            // Also acceptable (tool-level error block).
            let text = toolResultText(resp) ?? ""
            XCTAssertFalse(text.isEmpty)
        } else {
            XCTFail("unknown tool did not produce an error: \(resp)")
        }
    }

    func testCreateTaskAcceptsProjectPathAndTemplate() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Project path + template",
                                      "project_path": "~/Code/ghostties",
                                      "template": "Orchestrator"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "get_task",
                        "arguments": ["id": "project-path-template"]]]
        ])
        guard let createResp = responses[2] else {
            XCTFail("no response to create_task")
            return
        }
        XCTAssertFalse(toolIsError(createResp), "create_task returned error")

        // Assert round-trip through get_task — the returned JSON body must
        // carry the kebab-case keys we persisted.
        guard let getResp = responses[3] else {
            XCTFail("no response to get_task")
            return
        }
        XCTAssertFalse(toolIsError(getResp))
        let detailText = toolResultText(getResp) ?? ""

        // The MCP response JSON uses snake_case (mirrors source_id convention).
        // Parse it so we can assert values structurally rather than via substring.
        guard let detailData = detailText.data(using: .utf8),
              let detailObj = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any]
        else {
            XCTFail("get_task did not return JSON: \(detailText)")
            return
        }
        XCTAssertEqual(detailObj["project_path"] as? String, "~/Code/ghostties",
                       "get_task must echo projectPath via 'project_path' key")
        XCTAssertEqual(detailObj["template"] as? String, "Orchestrator",
                       "get_task must echo template verbatim")

        // And verify the file on disk uses kebab-case directly.
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("project-path-template") }) else {
            XCTFail("task file missing: \(files)")
            return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file),
                             encoding: .utf8)
        XCTAssertTrue(raw.contains("project-path: ~/Code/ghostties"),
                      "on-disk 'project-path' missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("template: Orchestrator"),
                      "on-disk 'template' missing; got:\n\(raw)")
    }

    func testCreateTaskMissingTitleReturnsError() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": [:]]]
        ])
        guard let resp = responses[2] else {
            XCTFail("no response to malformed create_task")
            return
        }
        // Server returns a tool-level isError for missing arguments; JSON-RPC
        // envelope is still a successful result.
        XCTAssertTrue(toolIsError(resp),
                      "create_task without title must set isError=true")
        let text = toolResultText(resp) ?? ""
        XCTAssertTrue(text.lowercased().contains("title"),
                      "error message should mention the missing 'title' arg")
    }

    // MARK: - Status round-trip

    func test_updateTaskStatus_inboxToRunningToDone_roundTrip() throws {
        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Status round trip",
                                      "lane": "inbox"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": "status-round-trip",
                                      "status": "running"]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": "status-round-trip",
                                      "status": "done"]]]
        ])

        guard let createResp = responses[2] else { XCTFail("no response to create_task"); return }
        XCTAssertFalse(toolIsError(createResp), "create_task returned error")

        guard let runningResp = responses[3] else { XCTFail("no response to running update"); return }
        XCTAssertFalse(toolIsError(runningResp), "update to running returned error")

        guard let doneResp = responses[4] else { XCTFail("no response to done update"); return }
        XCTAssertFalse(toolIsError(doneResp), "update to done returned error")

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("status-round-trip") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"),
                      "final status must be 'done'; got:\n\(raw)")
        // completed: must be present and non-empty after the done transition.
        XCTAssertTrue(raw.contains("completed: "),
                      "completed: must be written when transitioning to done; got:\n\(raw)")
        // updated: must be present after any status change.
        XCTAssertTrue(raw.contains("updated: "),
                      "updated: must be written on every status change; got:\n\(raw)")
    }

    func test_updateTaskStatus_done_doesNotOverwriteExistingCompleted() throws {
        // Pre-write a task file that already has a completed timestamp.
        let existingCompleted = "2026-01-01T00:00:00Z"
        let fileContent = """
        ---
        title: Already completed task
        source: linear
        source-id: already-completed-task
        project: ghostties
        created: 2026-01-01T00:00:00Z
        status: running
        completed: \(existingCompleted)
        ---

        ## Notes

        """
        let fileURL = tasksDir.appendingPathComponent("already-completed-task.md")
        try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let responses = try driveServer([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                        "clientInfo": ["name": "t", "version": "0"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": "already-completed-task",
                                      "status": "done"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response to update_task_status"); return }
        XCTAssertFalse(toolIsError(resp), "update_task_status returned error")

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: done"), "status must be done; got:\n\(raw)")

        XCTAssertTrue(raw.contains("completed: \(existingCompleted)"),
                      "completed: must preserve original timestamp; got:\n\(raw)")
    }
}
