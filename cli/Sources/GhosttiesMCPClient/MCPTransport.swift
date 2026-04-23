import Foundation

/// Transport abstraction for MCP. The client never talks to a pipe or a socket
/// directly — every transport implementation is responsible for line-delimited
/// JSON framing (one message per `\n`-terminated line per the MCP spec).
///
/// Implementations must:
///   - Frame `send` calls as a single JSON document followed by `\n`
///   - Emit each received message (one per stream element) as unframed `Data`
///     so the client can decode directly
///   - Route any diagnostic output (e.g. stderr from a subprocess) to their
///     own logger. Diagnostic output MUST NOT appear in the received stream.
public protocol MCPTransport: Sendable {
    /// Send a single JSON document. The transport MUST append `\n` framing.
    func send(_ data: Data) async throws

    /// An unbounded stream of incoming messages. Each element is a single JSON
    /// document with any trailing newline already stripped.
    func receive() -> AsyncStream<Data>

    /// Shut down the transport. After this returns, `send` throws and the
    /// stream from `receive` finishes.
    func close() async
}
