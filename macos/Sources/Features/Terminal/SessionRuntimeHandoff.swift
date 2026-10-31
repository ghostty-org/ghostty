import AppKit

/// A terminal OSC only names a private request file. It never carries a command
/// or authority: the request must match this local pane's random capability.
@MainActor
final class SessionRuntimeHandoff {
    static let shared = SessionRuntimeHandoff()
    private var tokens: [UUID: String] = [:]
    private let directory: URL
    private let resources: URL

    init(resources: URL? = nil, directory: URL? = nil) {
        self.resources = resources ?? SessionRuntimeConnections.resources
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-handoff-" + UUID().uuidString)
    }

    func configure(_ config: inout Ghostty.SurfaceConfiguration, pane: UUID) {
        // LaunchServices can inherit the launching terminal's environment.
        // Always shadow its pane capability, even in an app-only build without
        // runtime resources. Removing a dictionary entry would inherit it again.
        for key in ["OMG_SSH_HANDOFF_HELPER", "OMG_SSH_HANDOFF_DIRECTORY", "OMG_SSH_HANDOFF_TOKEN"] {
            config.environmentVariables[key] = ""
        }
        tokens.removeValue(forKey: pane)
        guard config.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil else { return }
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

    @discardableResult
    func openRemoteTab(_ descriptor: SessionRuntimeDescriptor, in controller: TerminalController) throws -> TerminalController {
        guard let connection = descriptor.connection,
              controller.ghostty.app != nil,
              let parent = controller.window else {
            throw CocoaError(.coderInvalidValue)
        }
        var config = Ghostty.SurfaceConfiguration()
        try descriptor.configure(&config)
        config.workingDirectory = connection.localWorkingDirectory
        guard let destination = TerminalController.newTab(
            controller.ghostty,
            from: parent,
            withBaseConfig: config
        ), destination.surfaceTree.first != nil else {
            throw NSError(domain: "OMGSessionRuntime", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Could not create the native SSH terminal tab."])
        }
        return destination
    }

    func accept(_ signal: Ghostty.ContextSignal, source: Ghostty.SurfaceView, controller: TerminalController) -> Bool {
        let prefix = "omg-runtime-request-"
        guard signal.id.hasPrefix(prefix) else { return false }
        guard source.runtimeDescriptor == nil, signal.action == .start else { return true }
        let name = String(signal.id.dropFirst(prefix.count))
        guard name.count == 32, name.allSatisfy(\.isHexDigit) else { return true }
        let file = directory.appendingPathComponent(name + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        struct Request: Decodable { let token: String; let ssh: String; let args: [String]; let cwd: String }
        var authenticated = false
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65536 else { return true }
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: file))
            guard request.token == tokens[source.id] else { return true }
            authenticated = true
            guard let parsed = OpenSSHArguments(request.args),
                  let destination = parsed.interactiveDestination,
                  let executable = SSHProcessArguments.executablePath(for: request.ssh, workingDirectory: request.cwd) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let connection = try GitSSHConnection(destination: destination, options: parsed.options.flatMap(\.arguments),
                executablePath: executable, localWorkingDirectory: request.cwd)
            let descriptor = try SessionRuntimeConnections.descriptor(connection: connection, policy: OhMyGhosttySettings.shared.runtimePolicy)
            try openRemoteTab(descriptor, in: controller)
            try Data().write(to: directory.appendingPathComponent(name + ".accepted"), options: .atomic)
        } catch {
            if authenticated {
                try? Data(error.localizedDescription.utf8).write(
                    to: directory.appendingPathComponent(name + ".failed"), options: .atomic
                )
            }
            Ghostty.logger.error("Native SSH handoff failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
