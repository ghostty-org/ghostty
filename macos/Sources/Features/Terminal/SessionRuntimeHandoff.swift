import AppKit

/// A terminal OSC only names a private request file. It never carries a command
/// or authority: the request must match this local pane's random capability.
@MainActor
final class SessionRuntimeHandoff {
    static let shared = SessionRuntimeHandoff()
    private var tokens: [UUID: String] = [:]
    private let directory: URL
    private let resources: URL
    private let applicationSupportRoot: URL?
    private let homeDirectory: URL?

    init(
        resources: URL? = nil,
        directory: URL? = nil,
        applicationSupportRoot: URL? = nil,
        homeDirectory: URL? = nil
    ) {
        self.resources = resources ?? SessionRuntimeConnections.resources
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-handoff-" + UUID().uuidString)
        self.applicationSupportRoot = applicationSupportRoot
        self.homeDirectory = homeDirectory
    }

    func restoredInlineSession(for local: SessionRuntimeDescriptor?, pane: UUID) -> SessionRuntimeInlineSession? {
        guard let local, local.isLocal,
              let bridge = try? SessionRuntimeBridgeStorage.directory(
                for: local, pane: pane, purpose: "handoff",
                applicationSupportRoot: applicationSupportRoot, homeDirectory: homeDirectory),
              let data = try? SessionRuntimeBridgeStorage.readPrivateFile(
                at: bridge.appendingPathComponent("active.json"), maximumSize: 65_536),
              let session = try? JSONDecoder().decode(SessionRuntimeInlineSession.self, from: data),
              session.localPane == pane, session.localDescriptor?.identity == local.identity,
              session.isRunningInThisBoot else { return nil }
        return session
    }

    private func ownerRecordURL(_ remotePane: UUID) -> URL {
        (applicationSupportRoot ?? OMGApplicationEnvironment.applicationSupportURL())
            .appendingPathComponent("session-runtime/inline-owners")
            .appendingPathComponent(remotePane.uuidString.lowercased() + ".json")
    }

    func inlineOwner(for remotePane: UUID) -> SessionRuntimeInlineSession? {
        guard let data = try? SessionRuntimeBridgeStorage.readPrivateFile(
            at: ownerRecordURL(remotePane), maximumSize: 65_536),
              let owner = try? JSONDecoder().decode(SessionRuntimeInlineSession.self, from: data),
              owner.pane == remotePane, owner.localPane != nil, owner.localDescriptor?.isLocal == true,
              owner.isRunningInThisBoot else { return nil }
        return owner
    }

    func configure(_ config: inout Ghostty.SurfaceConfiguration, pane: UUID) {
        // LaunchServices can inherit the launching terminal's environment.
        // Always shadow its pane capability, even in an app-only build without
        // runtime resources. Removing a dictionary entry would inherit it again.
        for key in ["OMG_SSH_HANDOFF_HELPER", "OMG_SSH_HANDOFF_DIRECTORY", "OMG_SSH_HANDOFF_TOKEN"] {
            config.environmentVariables[key] = ""
        }
        tokens.removeValue(forKey: pane)
        let descriptor = config.environmentVariables[SessionRuntimeDescriptor.environmentKey]
            .flatMap { try? JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data($0.utf8)) }
        if let descriptor {
            guard descriptor.isLocal else { return }
            do {
                let bridge = try SessionRuntimeBridgeStorage.directory(
                    for: descriptor,
                    pane: pane,
                    purpose: "handoff",
                    applicationSupportRoot: applicationSupportRoot,
                    homeDirectory: homeDirectory
                )
                let helper = try SessionRuntimeConnections.shared.cachedHelper(
                    for: descriptor,
                    applicationSupportRoot: applicationSupportRoot
                )
                let token = try SessionRuntimeBridgeStorage.capabilityToken(in: bridge)
                config.environmentVariables["OMG_SSH_HANDOFF_HELPER"] = helper.path
                config.environmentVariables["OMG_SSH_HANDOFF_DIRECTORY"] = bridge.path
                config.environmentVariables["OMG_SSH_HANDOFF_TOKEN"] = token
            } catch {
                Ghostty.logger.error("Could not prepare persistent native SSH handoff")
            }
            return
        }
        let helper = resources.appendingPathComponent("omgd")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let token = UUID().uuidString + UUID().uuidString
            tokens[pane] = token
            config.environmentVariables["OMG_SSH_HANDOFF_HELPER"] = helper.path
            config.environmentVariables["OMG_SSH_HANDOFF_DIRECTORY"] = directory.path
            config.environmentVariables["OMG_SSH_HANDOFF_TOKEN"] = token
        } catch { Ghostty.logger.error("Could not prepare native SSH handoff") }
    }

    func accept(_ signal: Ghostty.ContextSignal, source: Ghostty.SurfaceView, controller: TerminalController) -> Bool {
        let prefix = "omg-runtime-request-"
        guard signal.id.hasPrefix(prefix) else { return false }
        guard source.runtimeDescriptor == nil || source.runtimeDescriptor?.isLocal == true,
              signal.action == .start else { return true }
        let name = String(signal.id.dropFirst(prefix.count))
        guard name.count == 32, name.allSatisfy(\.isHexDigit) else { return true }
        let requestDirectory: URL
        let token: String?
        if let descriptor = source.runtimeDescriptor {
            do {
                requestDirectory = try SessionRuntimeBridgeStorage.directory(
                    for: descriptor,
                    pane: source.id,
                    purpose: "handoff",
                    applicationSupportRoot: applicationSupportRoot,
                    homeDirectory: homeDirectory
                )
                token = try SessionRuntimeBridgeStorage.capabilityToken(in: requestDirectory)
            } catch { return true }
        } else {
            requestDirectory = directory
            token = tokens[source.id]
        }
        let file = requestDirectory.appendingPathComponent(name + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct Request: Decodable {
            let token: String
            let ssh: String
            let args: [String]
            let cwd: String
            let pid: Int32?
            let viewer: String?
            let remoteWorkingDirectory: String?
            enum CodingKeys: String, CodingKey {
                case token, ssh, args, cwd, pid, viewer
                case remoteWorkingDirectory = "remote_cwd"
            }
        }
        var authenticated = false
        do {
            let requestData = try SessionRuntimeBridgeStorage.readPrivateFile(at: file, maximumSize: 65_536)
            let request = try JSONDecoder().decode(Request.self, from: requestData)
            guard request.token == token else { return true }
            authenticated = true
            guard request.viewer == "inline/1", let helperPID = request.pid, helperPID > 1 else {
                throw NSError(domain: "OMGSessionRuntime", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "The SSH helper is outdated. Run SSH with the current OMG application."
                ])
            }
            guard let parsed = OpenSSHArguments(request.args),
                  let destination = parsed.interactiveDestination,
                  let executable = SSHProcessArguments.executablePath(for: request.ssh, workingDirectory: request.cwd) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let connection = try GitSSHConnection(destination: destination, options: parsed.options.flatMap(\.arguments),
                executablePath: executable, localWorkingDirectory: request.cwd)
            var descriptor = try SessionRuntimeConnections.descriptor(connection: connection, policy: OhMyGhosttySettings.shared.runtimePolicy)
            if let cwd = request.remoteWorkingDirectory {
                guard let valid = SessionRuntimeDescriptor.validWorkingDirectory(cwd) else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                descriptor.initialWorkingDirectory = valid
            }
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("omg-inline-\(getuid())-\(name)")
            try SessionRuntimeBridgeStorage.ensurePrivateDirectory(root)
            let socket = root.appendingPathComponent("relay.sock")
            let config = root.appendingPathComponent("connection.json")
            try SessionRuntimeConnections.shared.writeConnectionConfiguration(
                descriptor, to: config, interactive: true, ttyAuthentication: true)
            guard let bootID = SessionRuntimeInlineSession.currentBootID else { throw CocoaError(.coderInvalidValue) }
            let remote = SessionRuntimeInlineSession(
                descriptor: descriptor, pane: UUID(), connectionID: "omg-ssh-inline-" + name,
                socket: socket, helperPID: helperPID,
                bootID: bootID,
                localPane: source.runtimeDescriptor?.isLocal == true ? source.id : nil,
                localDescriptor: source.runtimeDescriptor?.isLocal == true ? source.runtimeDescriptor : nil
            )
            let active = requestDirectory.appendingPathComponent("active.json")
            try SessionRuntimeBridgeStorage.writePrivateFile(
                at: active, data: JSONEncoder().encode(remote), permissions: 0o600)
            let ownerRecord = remote.localPane.map { _ in ownerRecordURL(remote.pane) }
            if let ownerRecord {
                try SessionRuntimeBridgeStorage.ensurePrivateDirectory(ownerRecord.deletingLastPathComponent())
                try SessionRuntimeBridgeStorage.writePrivateFile(
                    at: ownerRecord, data: JSONEncoder().encode(remote), permissions: 0o600)
            }
            struct Approval: Encodable {
                let helper: String
                let configuration: String
                let socket: String
                let open: Open
                let context: Context
                struct Open: Encodable {
                    let id: String
                    let policy: SessionRuntimePolicy
                    let create: Bool
                    let cwd: String?
                    let inlineViewer = true
                    enum CodingKeys: String, CodingKey {
                        case id, policy, create, cwd
                        case inlineViewer = "inline_viewer"
                    }
                }
                struct Context: Encodable {
                    let connectionID: String
                    let target: String
                    let localWorkingDirectory: String
                    let activeRecord: String
                    let ownerRecord: String?
                    enum CodingKeys: String, CodingKey {
                        case target
                        case connectionID = "connection_id"
                        case localWorkingDirectory = "local_cwd"
                        case activeRecord = "active_record"
                        case ownerRecord = "owner_record"
                    }
                }
            }
            let helper = try SessionRuntimeConnections.shared.cachedHelper(for: descriptor)
            let approval = Approval(helper: helper.path, configuration: config.path, socket: socket.path,
                open: .init(id: remote.pane.uuidString.lowercased(), policy: descriptor.policy, create: true,
                            cwd: descriptor.initialWorkingDirectory),
                context: .init(connectionID: remote.connectionID,
                               target: connection.destination.split(separator: "@").last.map(String.init) ?? connection.destination,
                               localWorkingDirectory: request.cwd, activeRecord: active.path,
                               ownerRecord: ownerRecord?.path))
            try SessionRuntimeBridgeStorage.writePrivateFile(
                at: requestDirectory.appendingPathComponent(name + ".accepted"),
                data: JSONEncoder().encode(approval), permissions: 0o600)
            source.runtimeInlineSession = remote
            source.pendingSSHLaunchReplay = remote.replay
            SessionRuntimeCatalog.shared.remember(descriptor)
        } catch {
            if authenticated {
                try? Data(error.localizedDescription.utf8).write(
                    to: requestDirectory.appendingPathComponent(name + ".failed"), options: .atomic
                )
            }
            Ghostty.logger.error("Native SSH handoff failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
