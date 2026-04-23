import SwiftUI
import GhosttiesCore
import GhosttiesMCPClient

/// Modal form for creating or editing an MCP source. Supports stdio (path +
/// args) and HTTP/SSE (URL) transports. Exposes a "Test connection" button
/// that runs the MCP `initialize` handshake against the configured source
/// using the just-entered values — non-blocking, with an inline result line.
///
/// Secrets live in the Keychain, never in the struct or JSON. The API key
/// field is a SecureField; if the user leaves it blank on an edit, we
/// preserve the existing stored value.
@MainActor
struct AddMCPSourceSheet: View {
    @ObservedObject var store: MCPSourceSettingsStore
    let existing: MCPSource?
    let onClose: () -> Void

    // Form state
    @State private var displayName: String = ""
    @State private var transport: TransportKind = .stdio
    @State private var endpoint: String = ""
    @State private var argsText: String = ""
    @State private var apiKey: String = ""

    // Test state
    @State private var testing: Bool = false
    @State private var testResult: TestResult?

    @State private var saveError: String?

    enum TestResult: Equatable {
        case success(toolCount: Int)
        case failure(String)
    }

    private var isEditing: Bool { existing != nil }

    /// The slug we'll use for `id` and Keychain account. For a new source,
    /// derive from `displayName`. When editing, we keep the original id so
    /// persistence + Keychain entries stay stable across rename.
    private var resolvedId: String {
        if let existing { return existing.id }
        return slugify(displayName)
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !resolvedId.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField
                    transportField
                    endpointField
                    if transport == .stdio {
                        argsField
                    }
                    apiKeyField
                    testRow
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            footer
        }
        .frame(width: 480, height: 560)
        .onAppear(perform: hydrate)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(isEditing ? "Edit MCP Source" : "Add MCP Source")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Linear", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .disabled(isEditing) // renaming would orphan the Keychain entry; defer for v0
            if isEditing {
                Text("Rename isn't supported yet — remove and re-add to change the name.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if !displayName.isEmpty {
                Text("Slug: \(slugify(displayName))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var transportField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transport")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: $transport) {
                Text("stdio (local binary)").tag(TransportKind.stdio)
                Text("HTTP + SSE (remote)").tag(TransportKind.sse)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            if transport == .sse {
                Text("HTTP/SSE transport isn't wired up yet. Config will persist; connecting will fail until Wave 3.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transport == .stdio ? "Executable Path" : "Server URL")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                transport == .stdio ? "/usr/local/bin/linear-mcp" : "https://mcp.example.com/sse",
                text: $endpoint
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private var argsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arguments (optional)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("--flag value --other", text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("Space-separated. No shell expansion.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            SecureField(
                isEditing ? "Leave blank to keep existing key" : "sk-...",
                text: $apiKey
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            Text("Stored in your macOS Keychain under \(Keychain.mcpService). Never written to disk.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var testRow: some View {
        HStack(spacing: 12) {
            Button {
                runTest()
            } label: {
                HStack(spacing: 6) {
                    if testing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                    Text(testing ? "Testing…" : "Test connection")
                }
            }
            .disabled(!canSave || testing || transport != .stdio)

            if let testResult {
                switch testResult {
                case .success(let toolCount):
                    Label("Connected — \(toolCount) tool\(toolCount == 1 ? "" : "s") available",
                          systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                case .failure(let reason):
                    Label(reason, systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            } else if transport != .stdio {
                Text("Test only supported for stdio in this wave.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
            Button(isEditing ? "Save" : "Add") {
                save()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func hydrate() {
        guard let existing else { return }
        displayName = existing.name
        transport = existing.transport
        endpoint = existing.endpoint
        argsText = (existing.args ?? []).joined(separator: " ")
        // Intentionally leave apiKey blank — SecureField shouldn't round-trip.
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedArgs = parseArgs(argsText)

        let source = MCPSource(
            id: resolvedId,
            name: trimmedName,
            transport: transport,
            endpoint: trimmedEndpoint,
            args: parsedArgs.isEmpty ? nil : parsedArgs,
            env: existing?.env
        )

        do {
            try store.save(source, apiKey: apiKey)
            // Reflect any prior test result into the list dot.
            if case .success = testResult {
                store.setStatus(.connected, for: source.id)
            }
            onClose()
        } catch {
            saveError = (error as? MCPError)?.description ?? error.localizedDescription
        }
    }

    private func runTest() {
        guard transport == .stdio else { return }
        testing = true
        testResult = nil

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedArgs = parseArgs(argsText)
        let apiKeyForTest = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (isEditing ? (store.apiKey(for: existing!) ?? "") : "")
            : apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let idForTest = resolvedId

        _Concurrency.Task { @MainActor in
            let result = await performStdioTest(
                executable: trimmedEndpoint,
                arguments: parsedArgs,
                apiKey: apiKeyForTest,
                sourceId: idForTest
            )
            testing = false
            testResult = result
        }
    }

    private nonisolated func performStdioTest(
        executable: String,
        arguments: [String],
        apiKey: String,
        sourceId: String
    ) async -> TestResult {
        // Validate path early — NSTask throws an unhelpful error otherwise.
        let fm = FileManager.default
        guard fm.fileExists(atPath: executable) else {
            return .failure("No executable at \(executable)")
        }
        guard fm.isExecutableFile(atPath: executable) else {
            return .failure("File isn't executable (chmod +x?)")
        }

        // Build env: inherit parent env, overlay API_KEY if present. Many MCP
        // servers read an env var; we surface a generic MCP_API_KEY so the
        // user can wire it through whatever name their server expects.
        var env = ProcessInfo.processInfo.environment
        if !apiKey.isEmpty {
            env["MCP_API_KEY"] = apiKey
        }

        let transport = MCPStdioTransport(
            executable: executable,
            arguments: arguments,
            environment: env
        )
        do {
            try transport.start()
        } catch {
            let desc = (error as? MCPError)?.description ?? error.localizedDescription
            return .failure("Failed to launch: \(desc)")
        }

        let client = MCPClient(transport: transport, sourceId: sourceId)

        do {
            try await client.connect(timeout: .seconds(10))
            let tools = try await client.listTools()
            await client.disconnect()
            return .success(toolCount: tools.count)
        } catch let err as MCPError {
            await client.disconnect()
            return .failure(friendlyError(err))
        } catch {
            await client.disconnect()
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated func friendlyError(_ err: MCPError) -> String {
        switch err {
        case .connectionTimeout:
            return "Timed out after 10s — is the server responding on stdout?"
        case .transportFailed(let msg):
            return "Transport: \(msg)"
        case .protocolError(let code, let message):
            if code == 401 || message.lowercased().contains("unauthor") {
                return "Server returned \(code) — check API key"
            }
            return "Server error \(code): \(message)"
        case .unsupportedTransport(let kind):
            return "\(kind.rawValue) transport not implemented yet"
        case .notConnected:
            return "Disconnected before handshake completed"
        case .decodingFailed(let msg):
            return "Bad response: \(msg)"
        }
    }

    // MARK: - Helpers

    private func slugify(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            } else {
                return "-"
            }
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    private func parseArgs(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
