import Foundation

// MARK: - JSONValue
//
// Single source of truth for the loose JSON shape used across the three MCP
// surfaces: the in-repo `ghostties-mcp` server, the generic `GhosttiesMCPClient`
// (Linear, Sentry, …), and anything else that needs to round-trip arbitrary
// JSON-RPC payloads. Lives in GhosttiesCore so the server and client can't
// drift apart (Fragile Area #14 — three-surface schema coherence).
//
// Encoded/decoded with JSONSerialization to preserve arbitrary shapes — Codable
// can't easily round-trip `Any`.

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
            // Distinguish int vs double via objCType — NSNumber is slippery.
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
