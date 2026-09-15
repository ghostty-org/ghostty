import AppKit
import Combine
import CryptoKit
import Foundation

struct RegisteredSSHHost: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let connection: GitSSHConnection
    var snapshot: AgentIntegrationSnapshot
    var capturedAt: Date
    var endpoint: String?
    var fromConfiguration: Bool?

    static func id(for connection: GitSSHConnection) -> String {
        "ssh-host:" + SHA256.hash(data: Data(connection.identity.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class SSHHostRegistry: ObservableObject {
    static let shared = SSHHostRegistry()
    typealias Inventory = @Sendable (GitSSHConnection) async throws -> AgentIntegrationSnapshot
    @Published private(set) var hosts: [RegisteredSSHHost]
    @Published private(set) var connections: [String: GitSSHConnection] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var automaticallyRegister: Bool { didSet { save(); reconcile() } }
    private var excluded: Set<String>
    private var attempted: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observers: [AnyCancellable] = []
    private let defaults: UserDefaults
    private let inventory: Inventory
    private let live: @MainActor () -> [GitSSHConnection]
    private let key = "OMG.SSH.Registry.v1"

    private struct Store: Codable {
        var hosts: [RegisteredSSHHost]
        var automaticallyRegister: Bool
        var excluded: Set<String>
    }

    init(defaults: UserDefaults = .standard,
         live: @escaping @MainActor () -> [GitSSHConnection] = SSHHostRegistry.liveConnections,
         inventory: @escaping Inventory = SSHHostRegistry.readInventory) {
        self.defaults = defaults
        self.live = live
        self.inventory = inventory
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
        hosts = saved?.hosts.filter { $0.id == RegisteredSSHHost.id(for: $0.connection) } ?? []
        automaticallyRegister = saved?.automaticallyRegister ?? false
        excluded = saved?.excluded ?? []
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.terminalPaneSessionContextsDidChange, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.reconcile() }.store(in: &observers)
        }
        reconcile()
    }

    static func liveConnections() -> [GitSSHConnection] {
        TerminalController.all.flatMap { controller in
            controller.paneSessionContexts.values.compactMap { context in
                guard case .sshReady = context.state else { return nil }
                return try? GitSSHConnection(session: context)
            }
        }
    }

    func reconcile() {
        let current = Dictionary(live().map { connection in
            let exact = RegisteredSSHHost.id(for: connection)
            let configured = hosts.first { matchesConfiguration($0, connection) }
            return (host(exact)?.id ?? configured?.id ?? exact, connection)
        }, uniquingKeysWith: { first, _ in first })
        let removed = Set(connections.keys).subtracting(current.keys)
        for id in removed {
            tasks[id]?.cancel()
            if let connection = connections[id] { Task { await SSHSessionTransport.close(connection) } }
        }
        attempted.subtract(removed)
        if current != connections { connections = current }
        if !automaticallyRegister {
            for (id, task) in tasks where host(id) == nil { task.cancel() }
        }
        for (id, connection) in current where (host(id) != nil || automaticallyRegister) && !excluded.contains(id)
            && !attempted.contains(id) && !pending.contains(id) {
            attempted.insert(id)
            tasks[id] = Task { [weak self] in
                await self?.register(connection, automatic: true, targetID: id)
                self?.tasks[id] = nil
            }
        }
    }

    func host(_ id: String) -> RegisteredSSHHost? { hosts.first { $0.id == id } }
    func isCollecting(_ id: String) -> Bool { pending.contains(id) || tasks[id] != nil }

    func isConnected(_ id: String) -> Bool {
        live().contains { connection in
            RegisteredSSHHost.id(for: connection) == id || host(id).map { matchesConfiguration($0, connection) } == true
        }
    }

    private func matchesConfiguration(_ record: RegisteredSSHHost, _ connection: GitSSHConnection) -> Bool {
        record.fromConfiguration == true && record.connection.destination == connection.destination &&
            record.connection.workspaceID == connection.workspaceID && record.connection.options == connection.options &&
            record.connection.options.isEmpty && record.connection.executablePath == connection.executablePath
    }

    func register(_ connection: GitSSHConnection, automatic: Bool = false, endpoint: String? = nil,
                  fromConfiguration: Bool = false, targetID: String? = nil) async {
        let id = targetID ?? RegisteredSSHHost.id(for: connection)
        guard !pending.contains(id), !automatic || isConnected(id) else { return }
        if !automatic { excluded.remove(id) }
        if isConnected(id) { attempted.insert(id) }
        pending.insert(id)
        errors[id] = nil
        defer {
            pending.remove(id)
            if !isConnected(id) { Task { await SSHSessionTransport.close(connection) } }
        }
        do {
            var snapshot = try await inventory(connection)
            try Task.checkCancellation()
            guard !excluded.contains(id), !automatic || isConnected(id) else { return }
            guard !automatic || host(id) != nil || automaticallyRegister else { return }
            if snapshot.error != nil, let previous = host(id)?.snapshot {
                if snapshot.hooks.isEmpty { snapshot.hooks = previous.hooks }
                if snapshot.cli.isEmpty { snapshot.cli = previous.cli }
            }
            let name = connection.workspaceID.hasPrefix("ssh:") ? String(connection.workspaceID.dropFirst(4)) : connection.destination
            let resolvedEndpoint: String?
            if let endpoint { resolvedEndpoint = endpoint } else { resolvedEndpoint = try? await SSHConfigurationCatalog.resolve(connection) }
            try Task.checkCancellation()
            guard !excluded.contains(id), !automatic || isConnected(id) else { return }
            let record = RegisteredSSHHost(id: id, name: name, connection: host(id)?.connection ?? connection,
                                           snapshot: snapshot, capturedAt: Date(), endpoint: resolvedEndpoint,
                                           fromConfiguration: host(id)?.fromConfiguration ?? fromConfiguration)
            hosts.removeAll { $0.id == id }
            hosts.append(record)
            hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            save()
        } catch {
            guard !Task.isCancelled else { return }
            errors[id] = error.localizedDescription
        }
    }

    func unregister(_ id: String) {
        tasks[id]?.cancel()
        excluded.insert(id)
        hosts.removeAll { $0.id == id }
        errors[id] = nil
        save()
    }

    func storeSnapshot(_ snapshot: AgentIntegrationSnapshot, target: String) {
        guard let index = hosts.firstIndex(where: { $0.id == target }) else { return }
        hosts[index].snapshot = snapshot
        hosts[index].capturedAt = Date()
        save()
    }

    private func save() {
        let store = Store(hosts: hosts, automaticallyRegister: automaticallyRegister, excluded: excluded)
        if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: key) }
    }

    nonisolated static func readInventory(_ connection: GitSSHConnection) async throws -> AgentIntegrationSnapshot {
        var snapshot = AgentIntegrationSnapshot()
        var captured = false
        do {
            let hooks = try await SSHSessionTransport.python(AgentHookInstaller.remoteInstallerScript(action: .status), connection: connection)
            let states = try JSONDecoder().decode([String: AgentHookInstallationState].self, from: hooks)
            snapshot.hooks = Dictionary(uniqueKeysWithValues: states.compactMap { key, value in
                SupportedAgent(rawValue: key).map { ($0, value) }
            })
            captured = true
        } catch {
            try Task.checkCancellation()
            snapshot.error = error.localizedDescription
        }
        do {
            let data = try await SSHSessionTransport.python(AgentIntegrationManager.cliScript(checkLatest: false),
                                                          connection: connection, loginShell: true)
            let cli = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
            captured = true
            snapshot.cli = Dictionary(uniqueKeysWithValues: cli.compactMap { key, value in
                SupportedAgent(rawValue: key).map { ($0, value) }
            })
        } catch {
            try Task.checkCancellation()
            snapshot.error = [snapshot.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
        guard captured else { throw GitExecutionError.executionFailed(snapshot.error ?? "SSH inventory unavailable") }
        return snapshot
    }
}
