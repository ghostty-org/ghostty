import Foundation

/// stderr-only logger. NEVER write to stdout — that's reserved for JSON-RPC
/// protocol frames. Mixing log lines into stdout breaks every MCP client.
enum Log {
    static func info(_ msg: String) {
        emit("[ghostties-mcp] \(msg)")
    }

    static func error(_ msg: String) {
        emit("[ghostties-mcp] error: \(msg)")
    }

    private static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
