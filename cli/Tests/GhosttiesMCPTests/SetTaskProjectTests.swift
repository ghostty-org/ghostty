import XCTest
import Foundation

/// Tests for `set_task_project` — happy paths, missing required fields, and
/// nonexistent-id error.
final class SetTaskProjectTests: XCTestCase {
    var tmpDir: URL!
    var tasksDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("set-task-project-tests-\(UUID().uuidString)", isDirectory: true)
        tasksDir = tmpDir.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Binary resolution + driver (mirrors MCPProtocolTests)

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

    // MARK: - Happy path

    func testSetProjectPathHappyPath() throws {
        let responses = try driveServer([
            initRequest(),
            // Create the task first.
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Project update target"]]],
            // Now set its project path.
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["id": "project-update-target",
                                      "project_path": "~/Code/ghostties"]]]
        ])
        guard let createResp = responses[2] else {
            XCTFail("no response to create_task"); return
        }
        XCTAssertFalse(toolIsError(createResp), "create_task returned error")

        guard let setResp = responses[3] else {
            XCTFail("no response to set_task_project"); return
        }
        XCTAssertFalse(toolIsError(setResp), "set_task_project returned error")
        let text = toolResultText(setResp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["project_path"] as? String, "~/Code/ghostties",
                       "set_task_project must echo project_path in response")

        // Verify on disk.
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("project-update-target") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("project-path: ~/Code/ghostties"),
                      "project-path not persisted to disk; got:\n\(raw)")
    }

    func testSetProjectPathWithTemplate() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Template update target"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["id": "template-update-target",
                                      "project_path": "~/Code/myapp",
                                      "template": "Orchestrator"]]]
        ])
        guard let setResp = responses[3] else {
            XCTFail("no response to set_task_project"); return
        }
        XCTAssertFalse(toolIsError(setResp), "set_task_project returned error")
        let text = toolResultText(setResp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["project_path"] as? String, "~/Code/myapp")
        XCTAssertEqual(obj["template"] as? String, "Orchestrator")

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("template-update-target") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("project-path: ~/Code/myapp"),
                      "project-path not persisted; got:\n\(raw)")
        XCTAssertTrue(raw.contains("template: Orchestrator"),
                      "template not persisted; got:\n\(raw)")
    }

    func testSetProjectPathLeavesTemplateUnchanged() throws {
        // Create a task with a template, then set project_path without supplying template.
        // The existing template must be preserved.
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Preserve template task",
                                      "template": "MyTemplate"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["id": "preserve-template-task",
                                      "project_path": "~/Code/newpath"]]]
        ])
        guard let setResp = responses[3] else {
            XCTFail("no response to set_task_project"); return
        }
        XCTAssertFalse(toolIsError(setResp))
        let text = toolResultText(setResp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        // Template must survive the project-path-only update.
        XCTAssertEqual(obj["template"] as? String, "MyTemplate",
                       "template must be preserved when not supplied to set_task_project")
    }

    // MARK: - Missing required fields

    func testMissingIdReturnsError() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["project_path": "~/Code/ghostties"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertTrue(toolIsError(resp), "missing id must set isError=true")
        let text = toolResultText(resp) ?? ""
        XCTAssertTrue(text.lowercased().contains("id"),
                      "error message should mention the missing 'id' arg")
    }

    func testMissingProjectPathReturnsError() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["id": "some-task"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertTrue(toolIsError(resp), "missing project_path must set isError=true")
        let text = toolResultText(resp) ?? ""
        XCTAssertTrue(text.lowercased().contains("project_path") || text.lowercased().contains("project"),
                      "error message should mention the missing 'project_path' arg")
    }

    // MARK: - Nonexistent id

    func testNonexistentIdReturnsError() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "set_task_project",
                        "arguments": ["id": "does-not-exist-at-all",
                                      "project_path": "~/Code/ghostties"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertTrue(toolIsError(resp), "nonexistent task id must set isError=true")
    }
}
