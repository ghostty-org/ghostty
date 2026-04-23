import Foundation

/// Transport kinds an MCP source can declare. Only `stdio` is wired up in this
/// wave — `sse` and `http` are placeholders so future config files remain
/// forward-compatible. Selecting an unimplemented transport throws at connect
/// time.
public enum TransportKind: String, Codable, Equatable {
    case stdio
    case sse
    case http
}

/// Persisted configuration for one external MCP source (Linear, Sentry, etc.).
///
/// `id` is a stable user-chosen slug. `name` is the display label.
/// `endpoint` is interpreted per transport:
///   - stdio: absolute path to the binary to launch
///   - sse:   URL string
///   - http:  URL string
public struct MCPSource: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var transport: TransportKind
    public var endpoint: String
    public var args: [String]?
    public var env: [String: String]?

    public init(
        id: String,
        name: String,
        transport: TransportKind,
        endpoint: String,
        args: [String]? = nil,
        env: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.args = args
        self.env = env
    }

    // Explicit Codable conformance using decodeIfPresent for optional fields
    // per the convention in ORCHESTRATOR.md Fragile Area #8 — any future field
    // addition must preserve backward-compat with already-written config files.
    private enum CodingKeys: String, CodingKey {
        case id, name, transport, endpoint, args, env
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.transport = try c.decode(TransportKind.self, forKey: .transport)
        self.endpoint = try c.decode(String.self, forKey: .endpoint)
        self.args = try c.decodeIfPresent([String].self, forKey: .args)
        self.env = try c.decodeIfPresent([String: String].self, forKey: .env)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encodeIfPresent(args, forKey: .args)
        try c.encodeIfPresent(env, forKey: .env)
    }
}
