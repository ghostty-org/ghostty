import XCTest
import GhosttiesCore
@testable import GhosttiesMCPClient

final class MCPProtocolTests: XCTestCase {

    // MARK: - Request round-trip

    func testRequestEncodeDecodeRoundTrip() throws {
        let params: JSONValue = .object([
            "name": .string("list_tasks"),
            "arguments": .object([
                "limit": .int(10),
                "include_done": .bool(false)
            ])
        ])
        let original = MCPRequest(id: .int(42), method: "tools/call", params: params)

        let data = try original.encode()
        let decoded = try MCPRequest.decode(data)

        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.id, .int(42))
        XCTAssertEqual(decoded.method, "tools/call")
        XCTAssertEqual(decoded.params?["name"]?.string, "list_tasks")
        XCTAssertEqual(decoded.params?["arguments"]?["limit"]?.int, 10)
    }

    func testRequestEncodeWithoutParams() throws {
        let req = MCPRequest(id: .int(1), method: "tools/list", params: nil)
        let data = try req.encode()
        let decoded = try MCPRequest.decode(data)
        XCTAssertEqual(decoded.method, "tools/list")
        XCTAssertNil(decoded.params)
    }

    // MARK: - Response (success) round-trip

    func testResponseSuccessRoundTrip() throws {
        let result: JSONValue = .object([
            "tools": .array([
                .object([
                    "name": .string("list_issues"),
                    "description": .string("List Linear issues")
                ])
            ])
        ])
        let original = MCPResponse(id: .int(7), result: result, error: nil)

        let data = try original.encode()
        let decoded = try MCPResponse.decode(data)

        XCTAssertEqual(decoded.id, .int(7))
        XCTAssertNil(decoded.error)
        XCTAssertEqual(decoded.result?["tools"]?.array?.count, 1)
        XCTAssertEqual(decoded.result?["tools"]?.array?[0]["name"]?.string, "list_issues")
    }

    // MARK: - Response (error) round-trip

    func testResponseErrorRoundTrip() throws {
        let errObj = MCPErrorObject(code: -32601, message: "Method not found", data: nil)
        let original = MCPResponse(id: .int(9), result: nil, error: errObj)

        let data = try original.encode()
        let decoded = try MCPResponse.decode(data)

        XCTAssertEqual(decoded.id, .int(9))
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, -32601)
        XCTAssertEqual(decoded.error?.message, "Method not found")
    }

    func testResponseErrorWithData() throws {
        let errObj = MCPErrorObject(
            code: -32602,
            message: "Invalid params",
            data: .object(["field": .string("name")])
        )
        let original = MCPResponse(id: .string("abc"), result: nil, error: errObj)

        let data = try original.encode()
        let decoded = try MCPResponse.decode(data)

        XCTAssertEqual(decoded.id, .string("abc"))
        XCTAssertEqual(decoded.error?.data?["field"]?.string, "name")
    }

    // MARK: - Notification round-trip

    func testNotificationRoundTrip() throws {
        let original = MCPNotification(
            method: "notifications/initialized",
            params: .object(["ready": .bool(true)])
        )

        let data = try original.encode()
        let decoded = try MCPNotification.decode(data)

        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.method, "notifications/initialized")
        XCTAssertEqual(decoded.params?["ready"], .bool(true))
    }

    func testNotificationRejectsId() throws {
        // Manually construct a frame with an id — must be rejected by the
        // notification decoder.
        let frame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "id": 1
        ]
        let data = try JSONSerialization.data(withJSONObject: frame)
        XCTAssertThrowsError(try MCPNotification.decode(data)) { err in
            guard case MCPError.decodingFailed = err else {
                return XCTFail("expected decodingFailed, got \(err)")
            }
        }
    }

    // MARK: - MCPTool parsing

    func testMCPToolFromJSONValue() {
        let v: JSONValue = .object([
            "name": .string("get_task"),
            "description": .string("Fetch a single task"),
            "inputSchema": .object(["type": .string("object")])
        ])
        let tool = MCPTool.from(v)
        XCTAssertEqual(tool?.name, "get_task")
        XCTAssertEqual(tool?.description, "Fetch a single task")
    }
}
