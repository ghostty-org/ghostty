import Foundation

// MARK: - JSONValue
//
// Flexible JSON value type. Mirrors the shape used by the in-repo MCP server
// (`cli/Sources/ghostties-mcp/JsonRpc.swift`) so client ↔ server share a
// vocabulary. Encoded/decoded with JSONSerialization to preserve arbitrary
// shapes — Codable can't easily round-trip `Any`.

/// A loose JSON value for request params, tool arguments, and tool results.
public enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Convert from a JSONSerialization-produced `Any`.
    public static func from(_ any: Any?) -> JSONValue {
        guard let any else { return .null }
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber {
            let t = String(cString: n.objCType)
            if t == "q" || t == "i" || t == "l" || t == "s" || t == "c" {
                return .int(n.intValue)
            }
            return .double(n.doubleValue)
        }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(JSONValue.from)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = .from(v) }
            return .object(out)
        }
        return .null
    }

    /// Convert to a JSONSerialization-consumable `Any`.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.any }
            return out
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - JSON-RPC 2.0 envelopes

/// A JSON-RPC 2.0 id. Spec allows string, number, or null; we preserve whatever
/// was sent so responses can round-trip to the sender's id.
public enum MCPRequestId: Equatable {
    case int(Int)
    case string(String)
    case null

    public var any: Any {
        switch self {
        case .int(let i): return i
        case .string(let s): return s
        case .null: return NSNull()
        }
    }

    public static func from(_ any: Any?) -> MCPRequestId {
        if let i = any as? Int { return .int(i) }
        if let n = any as? NSNumber { return .int(n.intValue) }
        if let s = any as? String { return .string(s) }
        return .null
    }
}

/// JSON-RPC 2.0 request frame. `id` is required for requests; notifications use
/// `MCPNotification` instead.
public struct MCPRequest: Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId
    public let method: String
    public let params: JSONValue?

    public init(id: MCPRequestId, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    /// Encode as a single line of JSON (no trailing newline — caller frames).
    public func encode() throws -> Data {
        var obj: [String: Any] = [
            "jsonrpc": jsonrpc,
            "id": id.any,
            "method": method
        ]
        if let params {
            obj["params"] = params.any
        }
        return try JSONSerialization.data(withJSONObject: obj,
                                          options: [.withoutEscapingSlashes, .sortedKeys])
    }

    /// Decode from a single JSON document.
    public static func decode(_ data: Data) throws -> MCPRequest {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.decodingFailed("request is not a JSON object")
        }
        guard let method = obj["method"] as? String else {
            throw MCPError.decodingFailed("request missing 'method'")
        }
        let id = MCPRequestId.from(obj["id"])
        let params = obj["params"].map { JSONValue.from($0) }
        return MCPRequest(id: id, method: method, params: params)
    }
}

/// A JSON-RPC error object carried inside an `MCPResponse`.
public struct MCPErrorObject: Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// JSON-RPC 2.0 response. Exactly one of `result` / `error` is populated on the
/// wire; we model both as optional so round-trips are straightforward.
public struct MCPResponse: Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId
    public let result: JSONValue?
    public let error: MCPErrorObject?

    public init(id: MCPRequestId, result: JSONValue? = nil, error: MCPErrorObject? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public func encode() throws -> Data {
        var obj: [String: Any] = [
            "jsonrpc": jsonrpc,
            "id": id.any
        ]
        if let result {
            obj["result"] = result.any
        }
        if let error {
            var err: [String: Any] = [
                "code": error.code,
                "message": error.message
            ]
            if let data = error.data {
                err["data"] = data.any
            }
            obj["error"] = err
        }
        return try JSONSerialization.data(withJSONObject: obj,
                                          options: [.withoutEscapingSlashes, .sortedKeys])
    }

    public static func decode(_ data: Data) throws -> MCPResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.decodingFailed("response is not a JSON object")
        }
        let id = MCPRequestId.from(obj["id"])
        let result = obj["result"].map { JSONValue.from($0) }
        var errObj: MCPErrorObject?
        if let e = obj["error"] as? [String: Any] {
            let code = (e["code"] as? Int) ?? ((e["code"] as? NSNumber)?.intValue ?? 0)
            let message = (e["message"] as? String) ?? ""
            let data = e["data"].map { JSONValue.from($0) }
            errObj = MCPErrorObject(code: code, message: message, data: data)
        }
        return MCPResponse(id: id, result: result, error: errObj)
    }
}

/// JSON-RPC 2.0 notification — same shape as a request but with no `id`, and no
/// response is expected.
public struct MCPNotification: Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }

    public func encode() throws -> Data {
        var obj: [String: Any] = [
            "jsonrpc": jsonrpc,
            "method": method
        ]
        if let params {
            obj["params"] = params.any
        }
        return try JSONSerialization.data(withJSONObject: obj,
                                          options: [.withoutEscapingSlashes, .sortedKeys])
    }

    public static func decode(_ data: Data) throws -> MCPNotification {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.decodingFailed("notification is not a JSON object")
        }
        guard let method = obj["method"] as? String else {
            throw MCPError.decodingFailed("notification missing 'method'")
        }
        if obj["id"] != nil {
            throw MCPError.decodingFailed("notification must not have 'id'")
        }
        let params = obj["params"].map { JSONValue.from($0) }
        return MCPNotification(method: method, params: params)
    }
}

// MARK: - MCP domain types

/// A tool definition returned by `tools/list`.
public struct MCPTool: Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public static func from(_ value: JSONValue) -> MCPTool? {
        guard case .object(let obj) = value,
              let name = obj["name"]?.string else { return nil }
        let description = obj["description"]?.string ?? ""
        let schema = obj["inputSchema"] ?? .object([:])
        return MCPTool(name: name, description: description, inputSchema: schema)
    }
}
