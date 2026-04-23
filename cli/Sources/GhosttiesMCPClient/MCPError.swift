import Foundation

/// Typed errors for the MCP client. Kept intentionally small — callers pattern
/// match to decide between "retry the transport" and "tell the user something
/// is wrong with the source config".
public enum MCPError: Error, Equatable {
    /// The underlying transport failed (process died, pipe broke, connect refused).
    case transportFailed(String)

    /// The remote server returned a JSON-RPC error object.
    case protocolError(code: Int, message: String)

    /// The source config requests a transport kind that this wave doesn't implement.
    case unsupportedTransport(TransportKind)

    /// A call was made before `connect()` completed, or after `disconnect()`.
    case notConnected

    /// Malformed JSON on disk or over the wire.
    case decodingFailed(String)
}

extension MCPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .transportFailed(let msg):
            return "transport failed: \(msg)"
        case .protocolError(let code, let message):
            return "protocol error \(code): \(message)"
        case .unsupportedTransport(let kind):
            return "unsupported transport: \(kind.rawValue)"
        case .notConnected:
            return "client is not connected"
        case .decodingFailed(let msg):
            return "decoding failed: \(msg)"
        }
    }
}
