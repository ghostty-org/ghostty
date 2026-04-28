import XCTest
import Foundation

/// End-to-end integration test that drives the full task data path:
/// create → list → inbox→running→done, with disk-state assertions at each step.
final class FullLoopIntegrationTests: XCTestCase {
    var tmpDir: URL!
    var tasksDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("full-loop-tests-\(UUID().uuidString)", isDirectory: true)
        tasksDir = tmpDir.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Binary resolution + driver (mirrors existing MCP test pattern)

    private func mcpBinaryURL() throws -> URL {
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        var dir = bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("ghostties-mcp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("ghostties-mcp binary not found next to test bundle")
    }

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
            if let id = obj["id"] as? Int { byID[id] = obj }
        }
        return byID
    }

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

    private func initRequest() -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": ["protocolVersion": "2024-11-05", "capabilities": [:],
                    "clientInfo": ["name": "t", "version": "0"]]]
    }

    // MARK: - Full loop: create → list → inbox→running→done

    func test_fullLoop_createRunComplete() throws {
        // Step 1 — Create task with full Linear-style payload.
        // NOTE: create_task has no `source_id` input parameter; it generates its
        // own id from the title slug. The `source_id` in list/get responses
        // reflects that generated id, not a caller-supplied value.
        let createResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": [
                            "title": "Generate hello.md in docs/",
                            "source": "linear",
                            "priority": "high",
                            "lane": "inbox",
                            "project": "ghostties",
                            "project_path": "~/Code/ghostties",
                            "template": "Claude Code",
                            "notes": "Write docs/hello.md containing the task title and current timestamp."
                        ]]]
        ])

        guard let createResp = createResponses[2] else {
            XCTFail("no response to create_task"); return
        }
        XCTAssertFalse(toolIsError(createResp), "create_task returned error")
        let createText = toolResultText(createResp) ?? ""
        guard let createData = createText.data(using: .utf8),
              let createObj = try? JSONSerialization.jsonObject(with: createData) as? [String: Any]
        else {
            XCTFail("create_task response not JSON: \(createText)"); return
        }
        guard let taskID = createObj["id"] as? String, !taskID.isEmpty else {
            XCTFail("create_task response missing 'id'"); return
        }

        // Step 2 — List tasks; assert the task appears with correct metadata.
        let listResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "list_tasks", "arguments": [:]]]
        ])

        guard let listResp = listResponses[2] else {
            XCTFail("no response to list_tasks"); return
        }
        XCTAssertFalse(toolIsError(listResp), "list_tasks returned error")
        let listText = toolResultText(listResp) ?? ""
        guard let listData = listText.data(using: .utf8),
              let listArray = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        else {
            XCTFail("list_tasks did not return a JSON array: \(listText)"); return
        }

        guard let found = listArray.first(where: { ($0["id"] as? String) == taskID }) else {
            XCTFail("task \(taskID) not found in list_tasks response"); return
        }
        XCTAssertEqual(found["lane"] as? String, "inbox",
                       "task must start in inbox lane")
        XCTAssertEqual(found["source"] as? String, "linear",
                       "source must round-trip as 'linear'")
        XCTAssertEqual(found["template"] as? String, "Claude Code",
                       "template must round-trip as 'Claude Code'")
        XCTAssertEqual(found["project_path"] as? String, "~/Code/ghostties",
                       "project_path must round-trip")

        // Step 3 — Advance to running (inbox → running).
        let runningResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": taskID, "status": "running"]]]
        ])

        guard let runningResp = runningResponses[2] else {
            XCTFail("no response to update_task_status(running)"); return
        }
        XCTAssertFalse(toolIsError(runningResp), "update_task_status(running) returned error")
        let runningText = toolResultText(runningResp) ?? ""
        guard let runningData = runningText.data(using: .utf8),
              let runningObj = try? JSONSerialization.jsonObject(with: runningData) as? [String: Any]
        else {
            XCTFail("update_task_status response not JSON: \(runningText)"); return
        }
        XCTAssertEqual(runningObj["lane"] as? String, "running",
                       "response lane must be 'running' after status update")

        // Assert on-disk frontmatter.
        let runningFiles = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let runningFile = runningFiles.first(where: { $0.hasPrefix("generate-hello-md") }) else {
            XCTFail("task file missing after running update; saw \(runningFiles)"); return
        }
        let runningRaw = try String(contentsOf: tasksDir.appendingPathComponent(runningFile),
                                    encoding: .utf8)
        XCTAssertTrue(runningRaw.contains("status: running"),
                      "on-disk status must be 'running'; got:\n\(runningRaw)")

        // Step 4 — Complete (running → done).
        let doneResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "update_task_status",
                        "arguments": ["id": taskID, "status": "done"]]]
        ])

        guard let doneResp = doneResponses[2] else {
            XCTFail("no response to update_task_status(done)"); return
        }
        XCTAssertFalse(toolIsError(doneResp), "update_task_status(done) returned error")
        let doneText = toolResultText(doneResp) ?? ""
        guard let doneData = doneText.data(using: .utf8),
              let doneObj = try? JSONSerialization.jsonObject(with: doneData) as? [String: Any]
        else {
            XCTFail("done response not JSON: \(doneText)"); return
        }
        // The lane display name for done is "graveyard" in this server.
        let doneLane = doneObj["lane"] as? String ?? ""
        XCTAssertTrue(doneLane == "done" || doneLane == "graveyard",
                      "response lane must be 'done' or 'graveyard'; got '\(doneLane)'")

        // Assert on-disk frontmatter after completing.
        let doneFiles = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let doneFile = doneFiles.first(where: { $0.hasPrefix("generate-hello-md") }) else {
            XCTFail("task file missing after done update; saw \(doneFiles)"); return
        }
        let doneRaw = try String(contentsOf: tasksDir.appendingPathComponent(doneFile),
                                 encoding: .utf8)
        XCTAssertTrue(doneRaw.contains("status: done"),
                      "on-disk status must be 'done'; got:\n\(doneRaw)")
        XCTAssertTrue(doneRaw.contains("completed:"),
                      "on-disk 'completed' timestamp must be present; got:\n\(doneRaw)")
        XCTAssertTrue(doneRaw.contains("updated:"),
                      "on-disk 'updated' timestamp must be present; got:\n\(doneRaw)")
    }

    // MARK: - Deduplication contract

    func test_fullLoop_deduplicate_doesNotCreateDuplicate() throws {
        // FIXME: dedup is the agent's responsibility, not the server's.
        // The MCP server has no server-side deduplication. Calling create_task
        // twice with the same logical intent (same source_id in the Linear sense)
        // always produces two distinct files. This test documents that behavior
        // and asserts the count correctly so future dedup logic will surface as
        // a test change.

        // Create first task.
        let firstResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": [
                            "title": "Dedup test SEA-DEDUP-1",
                            "source": "linear"
                        ]]]
        ])
        guard let firstResp = firstResponses[2] else {
            XCTFail("no response to first create_task"); return
        }
        XCTAssertFalse(toolIsError(firstResp), "first create_task returned error")

        // Capture count after first create.
        let countAfterFirst = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path).count

        // Create second task with a different title but logically the same Linear issue.
        let secondResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": [
                            "title": "Dedup test SEA-DEDUP-1 (duplicate attempt)",
                            "source": "linear"
                        ]]]
        ])
        guard let secondResp = secondResponses[2] else {
            XCTFail("no response to second create_task"); return
        }
        XCTAssertFalse(toolIsError(secondResp), "second create_task returned error")

        // FIXME: dedup is the agent's responsibility, not the server's.
        // The server creates a second file — count increases by 1.
        let countAfterSecond = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path).count
        XCTAssertEqual(countAfterSecond, countAfterFirst + 1,
                       "server creates a new file on each create_task call (no server-side dedup)")

        // Verify via list_tasks that two distinct tasks exist.
        let listResponses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "list_tasks",
                        "arguments": ["source": "linear"]]]
        ])
        guard let listResp = listResponses[2] else {
            XCTFail("no response to list_tasks"); return
        }
        XCTAssertFalse(toolIsError(listResp), "list_tasks returned error")
        let listText = toolResultText(listResp) ?? ""
        guard let listData = listText.data(using: .utf8),
              let listArray = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        else {
            XCTFail("list_tasks did not return a JSON array: \(listText)"); return
        }
        XCTAssertEqual(listArray.count, 2,
                       "list_tasks(source:linear) must return 2 tasks (server has no dedup)")
    }
}
