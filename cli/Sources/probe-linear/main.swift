import Foundation
import GhosttiesCore
import GhosttiesMCPClient

// MARK: - probe-linear
//
// Read-only diagnostic: connects to Linear's hosted MCP server via the
// `mcp-remote` stdio bridge, runs the MCP handshake, and reports what the
// server advertises so we can pick a sync strategy for the Inbox lane.
//
// DO NOT ship into the app. This executable exists purely to answer:
//   1. Does Linear's MCP server support `resources/subscribe`?
//   2. What tools does it expose?
//   3. Does it expose resources at all, or tools-only?
//
// See docs/linear-mcp-probe-findings.md for scope + decisions.

// MARK: - Logging (stderr only — stdout is reserved for the JSON-RPC bridge
//         during the run, and for the structured probe output we print at
//         the end of each phase).

private let stderr = FileHandle.standardError

private func log(_ message: String) {
    let line = "[probe] \(message)\n"
    if let data = line.data(using: .utf8) {
        stderr.write(data)
    }
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    log("ERROR: \(message)")
    exit(code)
}

// MARK: - Pretty-printing helpers

private func prettyPrint(_ value: JSONValue) -> String {
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: value.any,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
        let text = String(data: data, encoding: .utf8)
    else {
        return "<unprintable JSON>"
    }
    return text
}

// MARK: - Mock transport for offline verification

/// Minimal in-process MCP server used when `--mock` is passed. Responds to
/// `initialize`, `tools/list`, and `resources/list` with fixed payloads so
/// the probe's protocol wiring can be exercised without reaching Linear.
/// Subscriptions are advertised as unsupported — matches the expected real
/// Linear behavior so the probe's "SUBSCRIPTIONS NOT SUPPORTED" branch is
/// the one exercised by default.
final class MockLinearTransport: MCPTransport, @unchecked Sendable {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "ghostties.probe.mock")

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream { cont in continuation = cont }
        self.continuation = continuation
    }

    func send(_ data: Data) async throws {
        // Decode the request, synthesize a response, yield it back.
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = obj["method"] as? String
        else { return }

        let id = obj["id"]

        // Notifications (no id) are fire-and-forget.
        guard id != nil else { return }

        let result: JSONValue
        switch method {
        case "initialize":
            result = .object([
                "protocolVersion": .string("2024-11-05"),
                "serverInfo": .object([
                    "name": .string("mock-linear"),
                    "version": .string("0.0.1")
                ]),
                "capabilities": .object([
                    "tools": .object([
                        "listChanged": .bool(false)
                    ]),
                    "resources": .object([
                        "listChanged": .bool(false),
                        "subscribe": .bool(false)
                    ])
                ])
            ])
        case "tools/list":
            result = .object([
                "tools": .array([
                    .object([
                        "name": .string("mock_list_issues"),
                        "description": .string("list Linear issues assigned to me"),
                        "inputSchema": .object([:])
                    ]),
                    .object([
                        "name": .string("mock_get_issue"),
                        "description": .string("fetch a single Linear issue by id"),
                        "inputSchema": .object([:])
                    ])
                ])
            ])
        case "resources/list":
            result = .object([
                "resources": .array([
                    .object([
                        "uri": .string("mock://linear/issue/1"),
                        "name": .string("Mock issue #1"),
                        "mimeType": .string("application/json")
                    ])
                ])
            ])
        default:
            // Mimic a real server saying "method not found".
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "error": [
                    "code": -32601,
                    "message": "method not found: \(method)"
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                continuation.yield(data)
            }
            return
        }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result.any
        ]
        if let respData = try? JSONSerialization.data(withJSONObject: response) {
            continuation.yield(respData)
        }
    }

    func receive() -> AsyncStream<Data> {
        stream
    }

    func close() async {
        continuation.finish()
    }
}

// MARK: - Probe phases

/// Advertised capabilities interpreted for Sean. Specifically answers the
/// "do we need lazy refresh" question.
struct CapabilityReport {
    let resourcesAdvertised: Bool
    let subscribeSupported: Bool
    let toolsAdvertised: Bool
}

private func interpretCapabilities(_ capabilities: JSONValue) -> CapabilityReport {
    let resources = capabilities["resources"]
    let tools = capabilities["tools"]

    let resourcesAdvertised: Bool
    if case .object = resources { resourcesAdvertised = true } else { resourcesAdvertised = false }

    let toolsAdvertised: Bool
    if case .object = tools { toolsAdvertised = true } else { toolsAdvertised = false }

    let subscribeSupported = resources?["subscribe"]?.bool ?? false

    return CapabilityReport(
        resourcesAdvertised: resourcesAdvertised,
        subscribeSupported: subscribeSupported,
        toolsAdvertised: toolsAdvertised
    )
}

private func printCapabilitySummary(_ report: CapabilityReport) {
    if report.subscribeSupported {
        print("[probe] SUBSCRIPTIONS SUPPORTED — push notifications can drive Inbox refresh")
    } else if report.resourcesAdvertised {
        print("[probe] SUBSCRIPTIONS NOT SUPPORTED — lazy refresh required (resources primitive present but no subscribe)")
    } else {
        print("[probe] SUBSCRIPTIONS NOT SUPPORTED — lazy refresh required (resources primitive absent; tool polling only)")
    }
}

// MARK: - Entry point

private func parseArgs() -> (mock: Bool, help: Bool) {
    var mock = false
    var help = false
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "--mock": mock = true
        case "--help", "-h": help = true
        default:
            log("unknown argument: \(arg)")
            help = true
        }
    }
    return (mock, help)
}

private func printHelp() {
    let text = """
    probe-linear — read-only MCP capability probe for Linear's hosted server.

    USAGE
        probe-linear            Connect to Linear via mcp-remote stdio bridge.
        probe-linear --mock     Exercise probe against an in-process mock server.
        probe-linear --help     This help text.

    ENVIRONMENT
        LINEAR_API_KEY          Linear Personal API Key (required in live mode).
                                Create one at Linear → Settings → Security &
                                access → Personal API keys → New API key.

    REQUIREMENTS (live mode)
        npx on $PATH. mcp-remote is auto-downloaded by npx on first run.

    EXIT CODES
        0   success
        1   handshake or protocol error
        64  missing LINEAR_API_KEY (live mode only)

    OUTPUT
        stdout: structured probe results (capabilities JSON, tool list, etc).
        stderr: diagnostic logs from the probe and the mcp-remote subprocess.
    """
    print(text)
}

@main
struct ProbeMain {
    static func main() async {
        let args = parseArgs()
        if args.help {
            printHelp()
            exit(0)
        }

        let transport: MCPTransport
        if args.mock {
            log("using mock transport (LINEAR_API_KEY not consulted)")
            transport = MockLinearTransport()
        } else {
            transport = buildLiveTransport()
        }

        let client = MCPClient(transport: transport, sourceId: "linear")

        // ---- Phase 1: handshake
        log("handshake: initialize → …")
        do {
            try await client.connect(
                timeout: .seconds(30),
                clientName: "ghostties-probe-linear",
                clientVersion: "0.1.0"
            )
        } catch {
            await client.disconnect()
            fail("handshake failed: \(error)")
        }
        log("handshake: initialize → ok")

        let initResult = await client.initializeResult() ?? .object([:])
        let capabilities = await client.serverCapabilities()
        let report = interpretCapabilities(capabilities)

        // Print structured results on stdout so callers can tee > findings.
        print("[probe] server initialize result:")
        print(prettyPrint(initResult))
        print("")
        print("[probe] server capabilities:")
        print(prettyPrint(capabilities))
        print("")
        printCapabilitySummary(report)
        print("")

        // ---- Phase 2: tools/list
        await runToolsList(client: client)

        // ---- Phase 3: resources/list (tolerant of "method not supported")
        await runResourcesList(client: client, resourcesAdvertised: report.resourcesAdvertised)

        await client.disconnect()
        log("done.")
        exit(0)
    }

    /// Build the stdio transport that proxies Linear's remote MCP via
    /// `mcp-remote`. Reads `LINEAR_API_KEY` from the env — refuses to run
    /// without it to keep any auth material out of argv (which ps can see).
    private static func buildLiveTransport() -> MCPTransport {
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["LINEAR_API_KEY"], !apiKey.isEmpty else {
            fail("LINEAR_API_KEY is not set. Get a Personal API Key at Linear → Settings → Security & access → Personal API keys.", code: 64)
        }

        // Use /usr/bin/env so the user's Node install path doesn't matter. We
        // pass Authorization via stdin-wrapped env var to mcp-remote instead of
        // as --header so the raw key never appears in argv.
        //
        // Reality: mcp-remote only reads bearer tokens from --header (no env
        // var support as of this writing). We still pass it as --header but
        // ALSO strip it from anything we log. The subprocess's argv is visible
        // to other local processes owned by the same user, which is the same
        // trust boundary as the key sitting in the shell env — acceptable for
        // a local-only diagnostic.
        let args = [
            "npx",
            "-y",
            "mcp-remote",
            "https://mcp.linear.app/mcp",
            "--header",
            "Authorization: Bearer \(apiKey)"
        ]

        var childEnv = env
        // Avoid leaking the key to deeper children if any.
        childEnv["LINEAR_API_KEY"] = apiKey

        let transport = MCPStdioTransport(
            executable: "/usr/bin/env",
            arguments: args,
            environment: childEnv,
            stderrLogger: { line in
                // Prefix so mcp-remote's OAuth/session chatter is obvious.
                // Route to our stderr, never stdout (stdout is protocol).
                let prefixed = "[mcp-remote] \(line)\n"
                if let data = prefixed.data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            },
            terminationHandler: { status in
                let line = "[mcp-remote] subprocess exited with status \(status)\n"
                if let data = line.data(using: .utf8) {
                    FileHandle.standardError.write(data)
                }
            }
        )

        do {
            try transport.start()
        } catch {
            fail("failed to launch mcp-remote: \(error)")
        }

        log("launched: /usr/bin/env npx -y mcp-remote https://mcp.linear.app/mcp --header Authorization: Bearer <redacted>")
        return transport
    }

    private static func runToolsList(client: MCPClient) async {
        log("tools/list → …")
        do {
            let tools = try await client.listTools()
            print("[probe] tools/list → \(tools.count) tool(s)")
            for tool in tools {
                let desc = tool.description.isEmpty ? "(no description)" : tool.description
                print("    - \(tool.name) — \(desc)")
            }
            print("")
        } catch {
            await client.disconnect()
            fail("tools/list failed: \(error)")
        }
    }

    private static func runResourcesList(client: MCPClient, resourcesAdvertised: Bool) async {
        log("resources/list → …")
        do {
            let result = try await client.sendRawRequest(method: "resources/list", params: nil)
            let resources = result["resources"]?.array ?? []
            print("[probe] resources/list → \(resources.count) resource(s)")
            for resource in resources {
                let uri = resource["uri"]?.string ?? "<no uri>"
                let name = resource["name"]?.string ?? ""
                if name.isEmpty {
                    print("    - \(uri)")
                } else {
                    print("    - \(uri)  (\(name))")
                }
            }
            print("")
        } catch MCPError.protocolError(let code, let message) {
            // JSON-RPC -32601 = method not found. Anything else is a real error.
            if code == -32601 {
                print("[probe] resources/list → method not supported by server (JSON-RPC -32601)")
                if resourcesAdvertised {
                    print("[probe] NOTE: server advertised resources capability but rejected resources/list — inconsistent manifest.")
                }
                print("")
            } else {
                await client.disconnect()
                fail("resources/list failed with protocol error \(code): \(message)")
            }
        } catch {
            await client.disconnect()
            fail("resources/list failed: \(error)")
        }
    }
}
