import Foundation
import GhosttiesCore

/// JSON-RPC 2.0 request / response primitives. Minimal shape — MCP only uses a
/// small slice of the spec (method, params, id; error with code + message).
///
/// `JSONValue` lives in GhosttiesCore so the server, the generic client, and
/// any future surface share one definition (Fragile Area #14).

/// A JSON-RPC id can be a string, number, or null. Preserve whatever arrived so
/// the response round-trips to the same id.
enum RPCId {
    case string(String)
    case int(Int)
    case null

    static func from(_ any: Any?) -> RPCId {
        if let i = any as? Int { return .int(i) }
        if let n = any as? NSNumber { return .int(n.intValue) }
        if let s = any as? String { return .string(s) }
        return .null
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .null: return NSNull()
        }
    }
}

struct RPCRequest {
    let method: String
    let params: JSONValue
    let id: RPCId?  // nil for notifications

    var isNotification: Bool { id == nil }

    static func parse(_ line: String) -> (RPCRequest?, parseError: Bool) {
        guard let data = line.data(using: .utf8) else { return (nil, true) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, true)
        }
        guard let method = obj["method"] as? String else {
            return (nil, true)
        }
        let params = JSONValue.from(obj["params"] ?? [:])
        let id: RPCId? = obj["id"] == nil ? nil : RPCId.from(obj["id"])
        return (RPCRequest(method: method, params: params, id: id), false)
    }
}

/// Write a JSON-RPC response line to stdout. One object per line, trailing \n.
func rpcWrite(result: JSONValue, id: RPCId) {
    let envelope: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.any,
        "result": result.any
    ]
    rpcEmit(envelope)
}

func rpcWriteError(code: Int, message: String, id: RPCId) {
    let envelope: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.any,
        "error": [
            "code": code,
            "message": message
        ]
    ]
    rpcEmit(envelope)
}

/// Serialize + write exactly one line to stdout, flush, nothing else.
private func rpcEmit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else {
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
