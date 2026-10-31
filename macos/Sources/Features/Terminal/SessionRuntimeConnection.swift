import AppKit
import CryptoKit
import Darwin
import Foundation

struct SessionRuntimePolicy: Codable, Equatable, Sendable {
    var detachedTTLSeconds = 259_200
    var expiresAt: Int?
    var closeOnAgentDone = false
    var agentDoneGraceSeconds = 60
    var terminateGraceSeconds = 5
    var hostIdleSeconds = 300
    var recordRetentionSeconds = 604_800

    enum CodingKeys: String, CodingKey {
        case detachedTTLSeconds = "detached_ttl_seconds"
        case expiresAt = "expires_at"
        case closeOnAgentDone = "close_on_agent_done"
        case agentDoneGraceSeconds = "agent_done_grace_seconds"
        case terminateGraceSeconds = "terminate_grace_seconds"
        case hostIdleSeconds = "host_idle_seconds"
        case recordRetentionSeconds = "record_retention_seconds"
    }
}

enum SessionRuntimeConnectionState: Equatable, Sendable {
    case connecting(attempt: Int)
    case reconnecting(attempt: Int, retryInMilliseconds: Int?)
    case attention(attempt: Int, message: String?)
    case ready
    case failed(message: String?, retryable: Bool = true)
    case exited(exitCode: Int)

    private struct Payload: Decodable {
        let state: String
        var attempt: Int?
        var retryInMS: Int?
        var message: String?
        var retryable: Bool?
        var exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case state, attempt, message, retryable
            case retryInMS = "retry_in_ms"
            case exitCode = "exit_code"
        }
    }

    static func decode(_ metadata: String) -> Self? {
        guard metadata.utf8.count <= 8_192,
              let data = metadata.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let attempt = max(0, min(payload.attempt ?? 0, 1_000_000))
        let retry = payload.retryInMS.map { max(0, min($0, 86_400_000)) }
        let message = payload.message.map { value in
            String(value.unicodeScalars.prefix(2_048).map {
                CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
            })
        }
        if payload.state == "exited" {
            guard let exitCode = payload.exitCode else { return nil }
            return .exited(exitCode: exitCode)
        }
        return switch payload.state {
        case "connecting": .connecting(attempt: attempt)
        case "reconnecting": .reconnecting(attempt: attempt, retryInMilliseconds: retry)
        case "attention": .attention(attempt: attempt, message: message)
        case "ready": .ready
        case "failed": .failed(message: message, retryable: payload.retryable ?? true)
        default: nil
        }
    }

    var canRetry: Bool {
        switch self {
        case .ready, .connecting, .exited: false
        case .reconnecting(_, let delay): delay != nil
        case .attention: true
        case .failed(_, let retryable): retryable
        }
    }

    var attempt: Int {
        switch self {
        case .connecting(let attempt), .attention(let attempt, _): attempt
        case .reconnecting(let attempt, _): attempt
        case .ready, .failed, .exited: 0
        }
    }
}

struct SessionRuntimeDescriptor: Codable, Equatable, Sendable {
    static let environmentKey = "OMG_SESSION_RUNTIME_DESCRIPTOR"
    /// Nil identifies a local host runtime. Older archives always contain an SSH connection.
    var connection: GitSSHConnection?
    var revision: String
    var policy: SessionRuntimePolicy
    var localWorkingDirectory: String?
    /// Used only when creating this pane. Reattach never changes a live cwd.
    var initialWorkingDirectory: String?

    var isLocal: Bool { connection == nil }
    var displayEndpoint: String {
        connection?.displayEndpoint ?? localWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    var launchWorkingDirectory: String {
        connection?.localWorkingDirectory ?? localWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func validWorkingDirectory(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 4096, !value.contains("\0") else { return nil }
        return value
    }

    var identity: String {
        let endpoint = connection?.identity ?? "local:\(OMGApplicationEnvironment.applicationSupportURL().path)"
        return SHA256.hash(data: Data((endpoint + "\0" + revision).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func configure(_ config: inout Ghostty.SurfaceConfiguration) throws {
        config.environmentVariables[Self.environmentKey] = String(data: try JSONEncoder().encode(self), encoding: .utf8)
    }

    func openRequest(pane: UUID, restoring: Bool) throws -> String {
        struct Request: Encodable {
            let id: String
            let policy: SessionRuntimePolicy
            let create: Bool
            let cwd: String?
        }
        let directory = initialWorkingDirectory ?? (isLocal ? localWorkingDirectory : nil)
        let data = try JSONEncoder().encode(Request(id: pane.uuidString.lowercased(), policy: policy,
            create: !restoring, cwd: restoring ? nil : Self.validWorkingDirectory(directory)))
        guard let result = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

enum SessionRuntimeRetryCommand {
    static func arguments(socket: URL, interactive: Bool) -> [String] {
        ["retry-local", socket.path] + (interactive ? ["--interactive"] : [])
    }
}

@MainActor
protocol SessionRuntimeRetrying {
    func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws
}

/// Owns one relay process per exact host/revision. Each surface gets a descriptor,
/// never a process-global SSH target. Remote PTYs outlive this coordinator.
@MainActor
final class SessionRuntimeConnections: SessionRuntimeRetrying {
    static let shared = SessionRuntimeConnections()
    private struct Relay { let process: Process; let socket: URL }
    private var relays: [String: Relay] = [:]

    static var resources: URL {
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime", isDirectory: true)
    }

    static func descriptor(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws -> SessionRuntimeDescriptor {
        let revision = try String(contentsOf: resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(connection: connection, revision: revision, policy: policy)
    }

    static func localDescriptor(workingDirectory: String, policy: SessionRuntimePolicy) throws -> SessionRuntimeDescriptor {
        let directory = SessionRuntimeDescriptor.validWorkingDirectory(workingDirectory)
        guard let directory else { throw CocoaError(.validationMissingMandatoryProperty) }
        let revision = try String(contentsOf: resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(
            connection: nil,
            revision: revision,
            policy: policy,
            localWorkingDirectory: directory,
            initialWorkingDirectory: directory
        )
    }

    private func artifactDirectory(revision: String) throws -> URL {
        guard !revision.isEmpty, revision.count <= 128,
              revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let current = try String(contentsOf: Self.resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = OMGApplicationEnvironment.applicationSupportURL().appendingPathComponent("session-runtime/versions")
        let cached = root.appendingPathComponent(revision)
        if revision == current && !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = root.appendingPathComponent(".copy-" + UUID().uuidString)
            try FileManager.default.copyItem(at: Self.resources, to: staging)
            do { try FileManager.default.moveItem(at: staging, to: cached) } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        guard FileManager.default.fileExists(atPath: cached.appendingPathComponent("revision").path) else {
            throw NSError(domain: "OMGSessionRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The runtime version for this session is unavailable. Its remote process has not been restarted."])
        }
        let currentSnapshot = try String(contentsOf: Self.resources.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        let cachedSnapshot = try String(contentsOf: cached.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        guard currentSnapshot == cachedSnapshot else {
            throw NSError(domain: "OMGSessionRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This session uses an incompatible terminal snapshot version. Its remote process is preserved; reopen it with the matching app version."])
        }
        return cached
    }

    func prepare(_ descriptor: SessionRuntimeDescriptor, interactive: Bool = true) throws -> URL {
        if let relay = relays[descriptor.identity], relay.process.isRunning { return relay.socket }
        // Darwin sockaddr_un paths are capped near 104 bytes; the user's
        // /var/folders temporary path plus a host identity can exceed that.
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("omg-runtime-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let artifacts = try artifactDirectory(revision: descriptor.revision)
        let key = String(descriptor.identity.prefix(16))
        let socket = root.appendingPathComponent(key + ".sock")
        let configURL = root.appendingPathComponent(key + ".json")
        struct Configuration: Encodable {
            let transport: String
            let executable: String
            let arguments: [String]
            let cwd: String
            let localShell: String
            let bundle: String
            let policy: SessionRuntimePolicy
            let revision: String
            let hooks: String?
            let localStateDirectory: String?

            enum CodingKeys: String, CodingKey {
                case transport, executable, arguments, cwd, bundle, policy, revision, hooks
                case localShell = "local_shell"
                case localStateDirectory = "local_state_directory"
            }
        }
        let connection = descriptor.connection
        let localStateHash = SHA256.hash(data: Data((OMGApplicationEnvironment.applicationSupportURL().path +
            "\0" + descriptor.revision).utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        let localStateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omg/run/\(localStateHash)").path
        let config = Configuration(transport: descriptor.isLocal ? "local" : "ssh",
            executable: connection?.executablePath ?? "/usr/bin/ssh",
            arguments: connection?.arguments.map {
                $0 == "BatchMode=yes" || $0 == "BatchMode=no" ? "BatchMode=\(interactive ? "no" : "yes")" : $0
            } ?? [],
            cwd: descriptor.launchWorkingDirectory,
            localShell: Self.localLoginShell,
            bundle: artifacts.path, policy: descriptor.policy, revision: descriptor.revision,
            hooks: connection == nil ? nil : try AgentHookInstaller.remoteInstallerScript(agents: [.codex, .claude, .pi]),
            localStateDirectory: connection == nil ? localStateDirectory : nil)
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        try? FileManager.default.removeItem(at: socket)
        let process = Process()
        // Use the current transport optimizations for compatible cached runtimes;
        // the connection JSON still pins deployment to the original revision.
        process.executableURL = Self.resources.appendingPathComponent("omgd")
        process.arguments = ["connect", socket.path, configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Finder launches have no reliable inherited stderr. Keep helper
        // diagnostics in this connection's private directory instead.
        let logURL = root.appendingPathComponent(key + ".log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let diagnostics = try FileHandle(forWritingTo: logURL)
        try diagnostics.seekToEnd()
        defer { try? diagnostics.close() }
        process.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = artifacts.appendingPathComponent("askpass").path
        environment["SSH_ASKPASS_REQUIRE"] = interactive ? "force" : "never"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "omg:0"
        process.environment = environment
        try process.run()
        relays[descriptor.identity] = .init(process: process, socket: socket)
        return socket
    }

    func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        let socket = try prepare(descriptor)
        let process = Process()
        process.executableURL = Self.resources.appendingPathComponent("omgd")
        process.arguments = SessionRuntimeRetryCommand.arguments(socket: socket, interactive: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in onFailure("The runtime relay did not accept the retry request.") }
        }
        try process.run()
    }

    func shutdown() {
        SessionRuntimeCloseQueue.shared.stop()
        for relay in relays.values where relay.process.isRunning { relay.process.terminate() }
        relays.removeAll()
    }

    private static var localLoginShell: String {
        if let environmentShell = ProcessInfo.processInfo.environment["SHELL"],
           environmentShell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: environmentShell) {
            return environmentShell
        }
        if let account = getpwuid(getuid()), let shell = account.pointee.pw_shell,
           let path = String(validatingUTF8: shell),
           path.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/sh"
    }

    func open(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws {
        let descriptor = try Self.descriptor(connection: connection, policy: policy)
        try open(descriptor)
    }

    func openLocal(workingDirectory: String, policy: SessionRuntimePolicy) throws {
        try open(Self.localDescriptor(workingDirectory: workingDirectory, policy: policy))
    }

    private func open(_ descriptor: SessionRuntimeDescriptor) throws {
        var config = Ghostty.SurfaceConfiguration()
        try descriptor.configure(&config)
        config.workingDirectory = descriptor.launchWorkingDirectory
        guard let delegate = NSApp.delegate as? AppDelegate else { throw CocoaError(.featureUnsupported) }
        if let parent = TerminalController.preferredParent?.window {
            guard TerminalController.newTab(delegate.ghostty, from: parent, withBaseConfig: config) != nil else {
                throw CocoaError(.featureUnsupported)
            }
        } else {
            _ = TerminalController.newWindow(delegate.ghostty, withBaseConfig: config)
        }
    }
}
