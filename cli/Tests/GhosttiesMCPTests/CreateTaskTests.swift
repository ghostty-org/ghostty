import XCTest
import Foundation

/// Tests for `create_task` — priority round-trips, source default, project
/// defaulting, and error paths.
///
/// Uses the same driveServer / mcpBinaryURL harness from MCPProtocolTests so
/// these are integration tests against the compiled binary.
final class CreateTaskTests: XCTestCase {
    var tmpDir: URL!
    var tasksDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("create-task-tests-\(UUID().uuidString)", isDirectory: true)
        tasksDir = tmpDir.appendingPathComponent(".ghostties/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Binary resolution (mirrors MCPProtocolTests)

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

    // MARK: - Priority round-trips

    func testPriorityHighRoundTrip() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "High priority task", "priority": "high"]]]
        ])
        guard let resp = responses[2] else {
            XCTFail("no response")
            return
        }
        XCTAssertFalse(toolIsError(resp), "create_task returned error")
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)")
            return
        }
        XCTAssertEqual(obj["priority"] as? String, "high")

        // Verify on-disk value.
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("high-priority-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("priority: high"), "on-disk priority missing; got:\n\(raw)")
    }

    func testPriorityMediumRoundTrip() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Medium priority task", "priority": "medium"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["priority"] as? String, "medium")
    }

    func testPriorityLowRoundTrip() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Low priority task", "priority": "low"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["priority"] as? String, "low")
    }

    func testPriorityNoneExplicit() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "None priority task", "priority": "none"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        // Priority "none" is returned as "none" in JSON response.
        XCTAssertEqual(obj["priority"] as? String, "none")
        // On disk, .none is NOT written (keeps legacy fixtures clean).
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("none-priority-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertFalse(raw.contains("priority:"),
                       "priority: none must not be written to disk; got:\n\(raw)")
    }

    func testPriorityMissingDefaultsToNone() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "No priority field"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["priority"] as? String, "none",
                       "missing priority should default to 'none' in response")
    }

    func testPriorityUnknownValueDefaultsToNone() throws {
        // An unrecognised priority value must silently fall back to .none,
        // not return an error (graceful degradation for future enum extensions).
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Unknown priority task", "priority": "critical"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp),
                       "unknown priority value must NOT be a hard error")
        let text = toolResultText(resp) ?? ""
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response not JSON: \(text)"); return
        }
        XCTAssertEqual(obj["priority"] as? String, "none",
                       "unknown priority 'critical' should fall back to 'none'")
    }

    // MARK: - Source default

    func testSourceDefaultsToShell() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Source default task"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        // Verify on disk.
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("source-default-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("source: shell"),
                      "source must default to 'shell' on disk; got:\n\(raw)")
    }

    func testSourceExplicitLinear() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Linear source task", "source": "linear"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))
        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("linear-source-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("source: linear"),
                      "explicit source not persisted; got:\n\(raw)")
    }

    // MARK: - Template + project_path

    func test_createTask_withTemplate_roundTrips() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Template round trip task",
                                      "source": "linear",
                                      "template": "Claude Code",
                                      "project_path": "~/Code/ghostties"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp), "create_task returned error")

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("template-round-trip-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("template: Claude Code"),
                      "on-disk 'template' missing or wrong; got:\n\(raw)")
        XCTAssertTrue(raw.contains("project-path: ~/Code/ghostties"),
                      "on-disk 'project-path' missing or wrong; got:\n\(raw)")
    }

    func test_createTask_withoutTemplate_doesNotWriteTemplateField() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "No template task"]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp))

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("no-template-task") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        // The field must be absent entirely — an omitted template is not written as blank.
        XCTAssertFalse(raw.contains("template:"),
                       "template: must not appear in frontmatter when argument was not supplied; got:\n\(raw)")
    }

    func test_createTask_linearStylePayload_writesAllFields() throws {
        let responses = try driveServer([
            initRequest(),
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": "create_task",
                        "arguments": ["title": "Fix memory leak",
                                      "source": "linear",
                                      "priority": "high",
                                      "lane": "inbox",
                                      "project": "ghostties",
                                      "project_path": "~/Code/ghostties",
                                      "template": "Claude Code",
                                      "notes": "Leak in BrowserTabManager on close."]]]
        ])
        guard let resp = responses[2] else { XCTFail("no response"); return }
        XCTAssertFalse(toolIsError(resp), "create_task returned error")

        let files = try FileManager.default.contentsOfDirectory(atPath: tasksDir.path)
        guard let file = files.first(where: { $0.hasPrefix("fix-memory-leak") }) else {
            XCTFail("task file missing; saw \(files)"); return
        }
        let raw = try String(contentsOf: tasksDir.appendingPathComponent(file), encoding: .utf8)
        XCTAssertTrue(raw.contains("source: linear"),        "source missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("priority: high"),        "priority missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("status: inbox"),         "status missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("project: ghostties"),    "project missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("project-path: ~/Code/ghostties"), "project-path missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("template: Claude Code"), "template missing; got:\n\(raw)")
        XCTAssertTrue(raw.contains("Leak in BrowserTabManager on close."),
                      "seeded notes body missing; got:\n\(raw)")
    }
}
