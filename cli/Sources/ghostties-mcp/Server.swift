import Foundation
import GhosttiesCore

/// Stdio MCP server. One line = one JSON-RPC message. stdout is protocol-only;
/// stderr is for logs.
///
/// Supports the minimum verbs a Claude-Code-style client drives:
///   - initialize               → capabilities + server info
///   - notifications/initialized (no response expected)
///   - tools/list               → all 9 tools + schemas
///   - tools/call               → dispatch to the named tool handler
final class Server {
    /// MCP protocol version this server speaks. Current stable as of Jan 2026.
    static let protocolVersion = "2024-11-05"
    static let serverName = "ghostties-mcp"
    static let serverVersion = "0.1.0"

    private let tools: [Tool]
    private let resolver: TasksDirectoryResolver
    private var initialized = false

    init(resolver: TasksDirectoryResolver) {
        self.tools = allTools()
        self.resolver = resolver
    }

    /// Read stdin line-by-line until EOF. Every line is a JSON-RPC message.
    func run() {
        Log.info("starting (protocol \(Self.protocolVersion))")

        let stdin = FileHandle.standardInput
        var buffer = Data()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                // EOF — exit cleanly so the parent process sees a normal shutdown.
                Log.info("stdin closed, shutting down")
                return
            }
            buffer.append(chunk)

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIdx)
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                handleLine(trimmed)
            }
        }
    }

    private func handleLine(_ line: String) {
        let (parsed, parseError) = RPCRequest.parse(line)
        guard let req = parsed else {
            if parseError {
                // id is unknown on parse failure — spec says null.
                rpcWriteError(code: -32700, message: "Parse error", id: .null)
            }
            return
        }

        Log.info("recv \(req.method)")

        switch req.method {
        case "initialize":
            handleInitialize(req)
        case "notifications/initialized":
            // Notification; no response. Mark initialized for logs only.
            initialized = true
        case "tools/list":
            handleToolsList(req)
        case "tools/call":
            handleToolsCall(req)
        case "ping":
            if let id = req.id {
                rpcWrite(result: .object([:]), id: id)
            }
        default:
            if let id = req.id {
                rpcWriteError(code: -32601, message: "Method not found: \(req.method)", id: id)
            }
        }
    }

    // MARK: - Handlers

    private func handleInitialize(_ req: RPCRequest) {
        guard let id = req.id else { return }
        let result: JSONValue = .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(Self.serverVersion)
            ])
        ])
        rpcWrite(result: result, id: id)
    }

    private func handleToolsList(_ req: RPCRequest) {
        guard let id = req.id else { return }
        let items: [JSONValue] = tools.map { t in
            .object([
                "name": .string(t.name),
                "description": .string(t.description),
                "inputSchema": t.inputSchema
            ])
        }
        rpcWrite(result: .object(["tools": .array(items)]), id: id)
    }

    private func handleToolsCall(_ req: RPCRequest) {
        guard let id = req.id else { return }
        guard let name = req.params["name"]?.string else {
            rpcWriteError(code: -32602, message: "tools/call missing 'name'", id: id)
            return
        }
        let args = req.params["arguments"] ?? .object([:])

        guard let tool = tools.first(where: { $0.name == name }) else {
            rpcWriteError(code: -32602, message: "unknown tool: \(name)", id: id)
            return
        }

        Log.info("call \(name)")
        let result = tool.handler(args, resolver)
        if result.isError {
            // Log tool-level errors so they're visible when debugging a client.
            let firstText = result.content.first?["text"]?.string ?? "(no message)"
            Log.error("tool \(name) returned isError: \(firstText)")
        }
        rpcWrite(result: result.asJSON, id: id)
    }
}
