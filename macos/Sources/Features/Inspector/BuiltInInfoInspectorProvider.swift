import AppKit
import Darwin
import Foundation
import OSLog

extension Notification.Name {
    static let terminalHistoryDidChange = Notification.Name("com.oh-my-ghostty.terminal-history-did-change")
    static let terminalPaneSessionContextsDidChange = Notification.Name(
        "com.oh-my-ghostty.terminal-pane-session-contexts-did-change"
    )
}

enum InspectorPortForwardStatus: Equatable, Sendable {
    case starting
    case active
    case failed(String)
}

struct InspectorPortForwardItem: Identifiable, Equatable, Sendable {
    let id: String
    let remoteHost: String
    let remotePort: Int
    let localPort: Int?
    let processName: String?
    let status: InspectorPortForwardStatus
}

struct InspectorPortForwardList: Equatable, Sendable {
    let hostAlias: String
    let items: [InspectorPortForwardItem]
    var canCreate = true
}

struct PortForwardTarget: Equatable, Sendable {
    static let loopbackHost = "127.0.0.1"

    let host: String
    let port: Int

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    var sshHost: String { host.contains(":") ? "[\(host)]" : host }
    var displayValue: String {
        host == Self.loopbackHost ? String(port) : "\(sshHost):\(port)"
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(value), validPort(port) {
            return .init(host: loopbackHost, port: port)
        }

        let host: String
        let portText: String
        if value.hasPrefix("["), let closing = value.lastIndex(of: "]"),
           value.index(after: closing) < value.endIndex,
           value[value.index(after: closing)] == ":" {
            host = String(value[value.index(after: value.startIndex)..<closing])
            portText = String(value[value.index(closing, offsetBy: 2)...])
        } else if let separator = value.lastIndex(of: ":"),
                  !value[..<separator].contains(":") {
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        } else {
            return nil
        }
        guard validHost(host), let port = Int(portText), validPort(port) else {
            return nil
        }
        return .init(host: host, port: port)
    }

    private static func validPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_:%")
        )
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct InspectorInfoContent: Equatable, Sendable {
    /// Reserved for a future machine-status summary. Nil keeps the section hidden.
    let status: InspectorField?
    let fields: [InspectorField]
    let portForwards: InspectorPortForwardList
    let historyItems: [InspectorHistoryItem]
    let isAgentSession: Bool
    let agentName: String?
    let historyState: PaneAgentHistoryService.State

    init(
        status: InspectorField? = nil,
        fields: [InspectorField] = [],
        portForwards: InspectorPortForwardList = .init(hostAlias: "", items: []),
        historyItems: [InspectorHistoryItem] = [],
        isAgentSession: Bool = false,
        agentName: String? = nil,
        historyState: PaneAgentHistoryService.State = .ready
    ) {
        self.status = status
        self.fields = fields
        self.portForwards = portForwards
        self.historyItems = historyItems
        self.isAgentSession = isAgentSession
        self.agentName = agentName
        self.historyState = historyState
    }
}

@MainActor
final class BuiltInInfoInspectorProvider {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
        category: "ssh-port-forwarding"
    )

    static let featureID = "builtin.info"
    static let paneID = "builtin.info"

    struct DesiredForward: Codable, Equatable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case serverID
            case remoteHost
            case remotePort
        }

        let serverID: String
        let remoteHost: String
        let remotePort: Int

        var id: String { "\(serverID)|\(remoteHost)|\(remotePort)" }
        var target: PortForwardTarget {
            .init(host: remoteHost, port: remotePort)
        }

        init(serverID: String, remoteHost: String, remotePort: Int) {
            self.serverID = serverID
            self.remoteHost = remoteHost
            self.remotePort = remotePort
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            serverID = try values.decode(String.self, forKey: .serverID)
            remoteHost = try values.decodeIfPresent(
                String.self,
                forKey: .remoteHost
            ) ?? PortForwardTarget.loopbackHost
            remotePort = try values.decode(Int.self, forKey: .remotePort)
        }
    }

    struct ConnectionServers: Equatable {
        var connected: Set<String> = []
        var readyAliases: [String: String] = [:]
    }

    typealias ProcessLauncher = (
        _ alias: String,
        _ remoteHost: String,
        _ remotePort: Int,
        _ localPort: Int,
        _ termination: @escaping (Int32, String) -> Void
    ) throws -> () -> Void
    typealias LocalPortAllocator = (_ preferredPort: Int) throws -> Int
    typealias ForwardReadiness = (_ localPort: Int) async -> Bool
    typealias RemoteProcessBatchResolver = (_ alias: String, _ ports: [Int]) async throws -> [Int: String]
    enum ProcessProbeError: Error { case unavailable, invalidOutput }

    private struct ProcessProbe: Hashable {
        let id: String
        let token: UUID
        let alias: String
        let port: Int
    }

    typealias URLOpener = (URL) -> Void
    typealias AddressCopier = (String) -> Void

    private struct RuntimeForward {
        let desired: DesiredForward
        let alias: String
        let localPort: Int
        let token: UUID
        let stop: () -> Void
        var processName: String?
        var status: InspectorPortForwardStatus
    }

    private let registry: InspectorRegistry
    private let persistenceURL: URL
    private let processLauncher: ProcessLauncher
    private let localPortAllocator: LocalPortAllocator
    private let forwardReadiness: ForwardReadiness
    private let remoteProcessResolver: RemoteProcessBatchResolver
    private let processRefreshInterval: Duration
    private let openURL: URLOpener
    private let copyAddress: AddressCopier
    private var desiredForwards: Set<DesiredForward>
    private var runtimeForwards: [String: RuntimeForward] = [:]
    private var processRefreshTask: Task<Void, Never>?
    private var processRefreshDemand: Set<ProcessProbe> = []
    private var processRefreshGeneration = UUID()
    private var presentedContexts: [UUID: InspectorPaneContext] = [:]
    private var servers = ConnectionServers()
    private var isRegistered = false
    private var notificationObservers: [NSObjectProtocol] = []
    private let historyService: TerminalHistoryService
    // Keep the Agent reader for future verified message anchors, but do not
    // subscribe or publish transcript-only rows in the Info navigation UI.
    private let agentHistory = PaneAgentHistoryService()
    private static let agentHistoryNavigationEnabled = false

    init(
        registry: InspectorRegistry,
        persistenceURL: URL? = nil,
        processLauncher: @escaping ProcessLauncher = BuiltInInfoInspectorProvider.launchProcess,
        localPortAllocator: @escaping LocalPortAllocator = BuiltInInfoInspectorProvider.allocateLocalPort,
        forwardReadiness: @escaping ForwardReadiness = BuiltInInfoInspectorProvider.waitUntilForwardReady,
        remoteProcessBatchResolver: @escaping RemoteProcessBatchResolver = BuiltInInfoInspectorProvider.resolveRemoteProcesses,
        processRefreshInterval: Duration = .seconds(30),
        openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        copyAddress: @escaping AddressCopier = BuiltInInfoInspectorProvider.copyToPasteboard,
        historyService: TerminalHistoryService? = nil
    ) {
        let support = OMGApplicationEnvironment.applicationSupportURL()
        let resolvedPersistenceURL = persistenceURL ?? support.appendingPathComponent("Info/port-forwards.json")
        // Preserve existing forwards without depending on plugin installation.
        if persistenceURL == nil, !FileManager.default.fileExists(atPath: resolvedPersistenceURL.path) {
            let legacy = support.appendingPathComponent("PluginData/builtin.ssh/port-forwards.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.createDirectory(at: resolvedPersistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? FileManager.default.copyItem(at: legacy, to: resolvedPersistenceURL)
            }
        }
        self.registry = registry
        self.persistenceURL = resolvedPersistenceURL
        self.processLauncher = processLauncher
        self.localPortAllocator = localPortAllocator
        self.forwardReadiness = forwardReadiness
        self.remoteProcessResolver = remoteProcessBatchResolver
        self.processRefreshInterval = processRefreshInterval
        self.openURL = openURL
        self.copyAddress = copyAddress
        self.desiredForwards = Self.loadDesiredForwards(from: resolvedPersistenceURL)
        self.historyService = historyService ?? .shared

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalHistoryDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let surfaceID = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRegistered else { return }
                for context in self.presentedContexts.values where context.surfaceID == surfaceID {
                    self.publish(context)
                }
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPaneSessionContextsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeWithTerminalControllers()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: OhMyGhosttySettings.didChangeNotification,
            object: OhMyGhosttySettings.shared,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[
                OhMyGhosttySettings.changedKeyUserInfoKey
            ] as? String == "general.language" else { return }
            Task { @MainActor [weak self] in
                self?.refreshLocalization()
            }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeWithTerminalControllers()
            }
        })
    }

    deinit {
        processRefreshTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled != isRegistered else { return }
        if enabled {
            let descriptor = InspectorPaneDescriptor(
                id: Self.paneID,
                title: InfoStrings.current.infoTitle,
                systemImage: "info.circle",
                source: .coreFeature(Self.featureID),
                preferredWidth: RightInspectorMetrics.defaultWidth,
                minimumWidth: 240
            )
            try registry.registerCorePane(
                descriptor,
                lifecycle: { [weak self] event in self?.handle(event) },
                action: { [weak self] action in self?.handle(action) }
            )
            isRegistered = true
            synchronizeWithTerminalControllers()
        } else {
            shutdown()
            presentedContexts.removeAll()
            registry.unregister(source: .coreFeature(Self.featureID))
            isRegistered = false
        }
    }

    private func refreshLocalization() {
        guard isRegistered else { return }
        do {
            try registry.updateCorePaneTitle(
                paneID: Self.paneID,
                featureID: Self.featureID,
                title: InfoStrings.current.infoTitle
            )
        } catch {
            Self.logger.error(
                "failed to localize Info Inspector: \(error.localizedDescription, privacy: .public)"
            )
        }
        publishPresentedContexts()
    }

    func shutdown() {
        agentHistory.shutdown()
        let running = runtimeForwards.values
        runtimeForwards.removeAll()
        processRefreshTask?.cancel()
        processRefreshTask = nil
        processRefreshDemand.removeAll()
        processRefreshGeneration = UUID()
        for forward in running { forward.stop() }
    }

    func synchronizeConnections(_ next: ConnectionServers) {
        servers = next
        let paneIdentities = livePaneIdentities()
        // Registry connections still own registered forwards; plain panes keep
        // only their destination identities alive.
        let connected = next.connected.union(
            paneIdentities.keys.filter { $0.hasPrefix(Self.paneIdentityPrefix) }
        )

        let staleIDs = runtimeForwards.compactMap { id, runtime in
            connected.contains(runtime.desired.serverID) ? nil : id
        }
        for id in staleIDs { stopRuntimeForward(id: id) }

        for desired in desiredForwards where runtimeForwards[desired.id] == nil {
            guard let alias = next.readyAliases[desired.serverID]
                ?? (desired.serverID.hasPrefix(Self.paneIdentityPrefix)
                    ? paneIdentities[desired.serverID] : nil) else { continue }
            startRuntimeForward(desired, alias: alias)
        }
        reconcileProcessRefresh()
        publishPresentedContexts()
    }

    func content(for serverID: String, alias: String) -> InspectorPortForwardList {
        let items = desiredForwards
            .filter { $0.serverID == serverID }
            .sorted {
                $0.remoteHost == $1.remoteHost
                    ? $0.remotePort < $1.remotePort
                    : $0.remoteHost < $1.remoteHost
            }
            .map { desired -> InspectorPortForwardItem in
                guard let runtime = runtimeForwards[desired.id] else {
                    return .init(
                        id: desired.id,
                        remoteHost: desired.remoteHost,
                        remotePort: desired.remotePort,
                        localPort: nil,
                        processName: nil,
                        status: .starting
                    )
                }
                return .init(
                    id: desired.id,
                    remoteHost: desired.remoteHost,
                    remotePort: desired.remotePort,
                    localPort: runtime.localPort,
                    processName: runtime.processName,
                    status: runtime.status
                )
            }
        return .init(hostAlias: alias, items: items)
    }

    private func handle(_ event: InspectorPaneLifecycleEvent) {
        switch event {
        case .appeared(let context):
            presentedContexts[context.tabID] = context
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
            publish(context)
            reconcilePaneForwards()
        case .disappeared(let context):
            presentedContexts.removeValue(forKey: context.tabID)
            agentHistory.retain(surfaces: Set(presentedContexts.values.compactMap(\.surfaceID)))
            reconcilePaneForwards()
        }
        reconcileProcessRefresh()
    }

    private func handle(_ action: InspectorPaneAction) {
        switch action.kind {
        case .createPortForward(let targetValue):
            guard let server = Self.readyServer(action.context),
                  let target = PortForwardTarget.parse(targetValue) else { return }
            let desired = DesiredForward(
                serverID: server.id,
                remoteHost: target.host,
                remotePort: target.port
            )
            guard desiredForwards.insert(desired).inserted else { return }
            persistDesiredForwards()
            startRuntimeForward(desired, alias: server.alias)
            publishPresentedContexts()

        case .openPortForward(let id):
            guard let runtime = runtimeForwards[id],
                  runtime.status == .active,
                  let url = URL(string: "http://127.0.0.1:\(runtime.localPort)") else { return }
            openURL(url)

        case .copyPortForward(let id):
            guard let runtime = runtimeForwards[id], runtime.status == .active else { return }
            copyAddress("localhost:\(runtime.localPort)")

        case .removePortForward(let id):
            guard let desired = desiredForwards.first(where: { $0.id == id }) else { return }
            desiredForwards.remove(desired)
            stopRuntimeForward(id: id)
            persistDesiredForwards()
            publishPresentedContexts()

        case .jumpToHistoryItem(let item):
            guard let surfaceID = action.context.surfaceID else { return }
            for controller in TerminalController.all {
                if let surfaceView = controller.surfaceTree.first(where: { $0.id == surfaceID }) {
                    if historyService.jump(to: item, in: surfaceView) != .jumped {
                        NSSound.beep()
                        publish(action.context)
                    }
                    return
                }
            }

        default:
            break
        }
    }

    private func synchronizeWithTerminalControllers() {
        var next = ConnectionServers()
        for context in TerminalController.all.flatMap(\.paneSessionContexts.values) {
            switch context.state {
            case .local, .sshConnecting:
                break
            case .sshReady(let ssh, _):
                guard let serverID = ssh.serverID else { continue }
                next.connected.insert(serverID)
                next.readyAliases[serverID] = ssh.alias
            }
        }
        synchronizeConnections(next)
    }

    private func startRuntimeForward(_ desired: DesiredForward, alias: String) {
        guard runtimeForwards[desired.id] == nil else { return }
        do {
            let localPort = try localPortAllocator(desired.remotePort)
            let token = UUID()
            let stop = try processLauncher(
                alias,
                desired.remoteHost,
                desired.remotePort,
                localPort
            ) { [weak self] status, errorOutput in
                Task { @MainActor [weak self] in
                    self?.processDidTerminate(
                        id: desired.id,
                        token: token,
                        status: status,
                        errorOutput: errorOutput
                    )
                }
            }
            runtimeForwards[desired.id] = .init(
                desired: desired,
                alias: alias,
                localPort: localPort,
                token: token,
                stop: stop,
                processName: nil,
                status: .starting
            )
            Task { [weak self] in
                guard let self else { return }
                let ready = await forwardReadiness(localPort)
                guard var runtime = runtimeForwards[desired.id],
                      runtime.token == token,
                      runtime.status == .starting else { return }
                guard ready else {
                    runtime.status = .failed(
                        InfoStrings.current.listenerTimeout(localPort: localPort)
                    )
                    runtimeForwards[desired.id] = runtime
                    runtime.stop()
                    publishPresentedContexts()
                    return
                }
                runtime.status = .active
                runtimeForwards[desired.id] = runtime
                publishPresentedContexts()
                reconcileProcessRefresh()
            }
        } catch {
            let message = Self.failureDescription(error)
            Self.logger.error(
                "failed to start SSH forward alias=\(alias, privacy: .public) remote=\(desired.remotePort) error=\(message, privacy: .public)"
            )
            runtimeForwards[desired.id] = .init(
                desired: desired,
                alias: alias,
                localPort: 0,
                token: UUID(),
                stop: {},
                processName: nil,
                status: .failed(message)
            )
        }
    }

    private func reconcileProcessRefresh() {
        let visibleServers = Set(presentedContexts.values.compactMap { Self.readyServer($0)?.id })
        let demand = Set(runtimeForwards.compactMap { id, runtime -> ProcessProbe? in
            guard runtime.status == .active, runtime.desired.target.isLoopback,
                  visibleServers.contains(runtime.desired.serverID) else { return nil }
            return .init(id: id, token: runtime.token, alias: runtime.alias, port: runtime.desired.remotePort)
        })
        guard demand != processRefreshDemand else { return }
        let previous = processRefreshTask
        previous?.cancel()
        processRefreshDemand = demand
        let generation = UUID()
        processRefreshGeneration = generation
        let resolver = remoteProcessResolver
        let interval = processRefreshInterval
        // A replacement waits for cancellation to settle, so rapid visibility
        // changes cannot overlap old and new SSH subprocesses.
        processRefreshTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, !demand.isEmpty else { return }
            let groups = Dictionary(grouping: demand, by: \.alias)
            var failures: [String: Int] = [:]
            var roundsUntilRetry: [String: Int] = [:]
            while !Task.isCancelled {
                for alias in groups.keys.sorted() {
                    guard !Task.isCancelled, let probes = groups[alias] else { return }
                    if let rounds = roundsUntilRetry[alias], rounds > 0 {
                        roundsUntilRetry[alias] = rounds - 1
                        continue
                    }
                    do {
                        let names = try await resolver(alias, Array(Set(probes.map(\.port))).sorted())
                        guard !Task.isCancelled else { return }
                        self?.applyProcessNames(names, probes: probes, generation: generation)
                        failures[alias] = 0
                    } catch {
                        guard !Task.isCancelled else { return }
                        // Retain cached names on transport/tool failure, and
                        // retry after 2/4 base intervals (60/120s by default).
                        let count = min(2, (failures[alias] ?? 0) + 1)
                        failures[alias] = count
                        roundsUntilRetry[alias] = (1 << count) - 1
                    }
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func applyProcessNames(_ names: [Int: String], probes: [ProcessProbe], generation: UUID) {
        guard generation == processRefreshGeneration else { return }
        var changed = false
        for probe in probes {
            guard var runtime = runtimeForwards[probe.id], runtime.token == probe.token,
                  runtime.status == .active else { continue }
            let name = names[probe.port]
            if runtime.processName != name {
                runtime.processName = name
                runtimeForwards[probe.id] = runtime
                changed = true
            }
        }
        if changed { publishPresentedContexts() }
    }

    private func stopRuntimeForward(id: String) {
        guard let runtime = runtimeForwards.removeValue(forKey: id) else { return }
        runtime.stop()
        reconcileProcessRefresh()
    }

    private func processDidTerminate(
        id: String,
        token: UUID,
        status: Int32,
        errorOutput: String
    ) {
        guard var runtime = runtimeForwards[id], runtime.token == token else { return }
        if case .failed = runtime.status {
            return
        }
        runtime.status = .failed(Self.sshFailureDescription(
            status: status,
            errorOutput: errorOutput,
            localPort: runtime.localPort
        ))
        runtimeForwards[id] = runtime
        reconcileProcessRefresh()
        publishPresentedContexts()
    }

    private func publishPresentedContexts() {
        guard isRegistered else { return }
        for context in presentedContexts.values { publish(context) }
    }

    private struct History {
        var items: [InspectorHistoryItem] = []
        var isAgent = false
        var agentName: String?
        var state: PaneAgentHistoryService.State = .ready
    }

    static func hidesAgentHistory(descriptorPresent: Bool, activity: TabActivity?) -> Bool {
        // A status may remain at `done` or `error` while the Agent is still
        // running. Do not mistake that pane for a plain Shell when discovery
        // has not yet attached a resume descriptor.
        descriptorPresent || activity != nil
    }

    private func currentHistory(for context: InspectorPaneContext) -> History {
        guard let surfaceID = context.surfaceID else { return .init() }
        for controller in TerminalController.all {
            guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) else { continue }
            let descriptor = controller.agentResumeDescriptor(for: view)
            if !Self.agentHistoryNavigationEnabled,
               Self.hidesAgentHistory(descriptorPresent: descriptor != nil,
                                      activity: controller.agentActivity(for: view)) {
                agentHistory.remove(surfaceID)
                return .init(items: historyService.commands(for: surfaceID), isAgent: true)
            }
            guard let descriptor else { continue }
            let session = controller.paneSessionContext(for: view) ?? context.session
            guard let binding = PaneAgentHistoryService.Binding.current(descriptor: descriptor, session: session) else {
                agentHistory.remove(surfaceID)
                return .init(isAgent: true, agentName: descriptor.agent.displayName, state: .unavailable)
            }
            let snapshot = agentHistory.observe(surfaceID: surfaceID, binding: binding) { [weak self] in
                self?.publishPresentedContexts()
            }
            return .init(items: snapshot.items, isAgent: true, agentName: descriptor.agent.displayName,
                         state: snapshot.state)
        }
        agentHistory.remove(surfaceID)
        return .init(items: historyService.commands(for: surfaceID))
    }

    private func publish(_ context: InspectorPaneContext) {
        let historyInfo = currentHistory(for: context)
        let session = context.surfaceID.flatMap { surfaceID in
            TerminalController.all.lazy.compactMap { controller -> PaneSessionContext? in
                guard let view = controller.surfaceTree.first(where: { $0.id == surfaceID }) else { return nil }
                return controller.paneSessionContext(for: view)
            }.first
        } ?? context.session
        let content: InspectorPaneContent

        switch session.state {
        case .local:
            content = .info(.init(historyItems: historyInfo.items, isAgentSession: historyInfo.isAgent,
                                 agentName: historyInfo.agentName, historyState: historyInfo.state))
        case .sshConnecting(let ssh):
            content = .info(.init(
                portForwards: .init(hostAlias: ssh.alias, items: [], canCreate: false),
                historyItems: historyInfo.items, isAgentSession: historyInfo.isAgent,
                agentName: historyInfo.agentName, historyState: historyInfo.state
            ))
        case .sshReady(let ssh, _):
            let forwards = self.content(for: Self.forwardingIdentity(for: ssh), alias: ssh.alias)
            content = .info(.init(portForwards: forwards, historyItems: historyInfo.items,
                                 isAgentSession: historyInfo.isAgent, agentName: historyInfo.agentName,
                                 historyState: historyInfo.state))
        }
        do {
            try registry.updateCoreContent(
                paneID: Self.paneID,
                featureID: Self.featureID,
                tabID: context.tabID,
                content: content
            )
        } catch {
            Self.logger.error("failed to publish SSH Inspector content: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistDesiredForwards() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let forwards = desiredForwards.sorted {
                if $0.serverID != $1.serverID { return $0.serverID < $1.serverID }
                if $0.remoteHost != $1.remoteHost { return $0.remoteHost < $1.remoteHost }
                return $0.remotePort < $1.remotePort
            }
            try JSONEncoder().encode(forwards).write(to: persistenceURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: persistenceURL.path
            )
        } catch {
            Self.logger.error("failed to persist SSH forwards: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadDesiredForwards(from url: URL) -> Set<DesiredForward> {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DesiredForward].self, from: data) else {
            return []
        }
        return Set(decoded.filter { validDesiredForward($0) })
    }

    private static func validDesiredForward(_ forward: DesiredForward) -> Bool {
        guard validServerID(forward.serverID), validPort(forward.remotePort) else {
            return false
        }
        let host = forward.remoteHost.contains(":")
            ? "[\(forward.remoteHost)]"
            : forward.remoteHost
        return PortForwardTarget.parse("\(host):\(forward.remotePort)") != nil
    }

    nonisolated private static func validPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    nonisolated private static func validServerID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".:_+-/=")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func readyServer(
        _ context: InspectorPaneContext
    ) -> (id: String, alias: String)? {
        guard case .sshReady(let ssh, _) = context.session.state else { return nil }
        return (forwardingIdentity(for: ssh), ssh.alias)
    }

    /// Stable identity used to persist and reconcile a pane's port forwards.
    ///
    /// `omg +ssh` panes carry a verified server ID. Plain `ssh` panes inferred
    /// from the foreground process only know their destination, so their
    /// forwards follow the pane lifecycle under a destination identity.
    /// Forwards still launch through the pane's own SSH alias, which resolves
    /// the user's OpenSSH configuration.
    private static func forwardingIdentity(for ssh: PaneSessionContext.SSH) -> String {
        if let serverID = ssh.serverID { return serverID }
        return paneIdentityPrefix + ssh.alias
    }

    private static let paneIdentityPrefix = "ssh-destination:"

    /// Identities and aliases of SSH panes that are ready right now.
    private func livePaneIdentities() -> [String: String] {
        var result: [String: String] = [:]
        for context in presentedContexts.values {
            guard case .sshReady(let ssh, _) = context.session.state else { continue }
            result[Self.forwardingIdentity(for: ssh)] = ssh.alias
        }
        return result
    }

    /// Plain SSH panes are not registry connections, so their persisted
    /// forwards follow the pane lifecycle instead of `synchronizeConnections`.
    private func reconcilePaneForwards() {
        let live = livePaneIdentities()
        let stale = runtimeForwards.compactMap { id, runtime -> String? in
            runtime.desired.serverID.hasPrefix(Self.paneIdentityPrefix) &&
                live[runtime.desired.serverID] == nil ? id : nil
        }
        for id in stale { stopRuntimeForward(id: id) }
        for desired in desiredForwards
        where desired.serverID.hasPrefix(Self.paneIdentityPrefix) && runtimeForwards[desired.id] == nil {
            guard let alias = live[desired.serverID] else { continue }
            startRuntimeForward(desired, alias: alias)
        }
    }

    nonisolated private static func launchProcess(
        alias: String,
        remoteHost: String,
        remotePort: Int,
        localPort: Int,
        termination: @escaping (Int32, String) -> Void
    ) throws -> () -> Void {
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-\(UUID().uuidString).err")
        guard FileManager.default.createFile(
            atPath: errorURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let process = Process()
        let forwardHost = PortForwardTarget(
            host: remoteHost,
            port: remotePort
        ).sshHost
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.monitorScript,
            "omg-ssh-port-forward",
            String(ProcessInfo.processInfo.processIdentifier),
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):\(forwardHost):\(remotePort)",
            alias,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.terminationHandler = { process in
            try? errorHandle.close()
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            try? FileManager.default.removeItem(at: errorURL)
            let output = String(
                bytes: data.prefix(16_384),
                encoding: .utf8
            ) ?? ""
            termination(process.terminationStatus, output)
        }
        do {
            try process.run()
        } catch {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
            throw error
        }
        return {
            if process.isRunning { process.terminate() }
        }
    }

    nonisolated private static let monitorScript = """
    parent_pid="$1"
    shift
    /usr/bin/ssh "$@" &
    ssh_pid=$!
    cleanup() {
      /bin/kill "$ssh_pid" 2>/dev/null || true
      wait "$ssh_pid" 2>/dev/null || true
    }
    trap cleanup EXIT HUP INT TERM
    while /bin/kill -0 "$parent_pid" 2>/dev/null && /bin/kill -0 "$ssh_pid" 2>/dev/null; do
      /bin/sleep 1
    done
    if ! /bin/kill -0 "$parent_pid" 2>/dev/null; then
      /bin/kill "$ssh_pid" 2>/dev/null || true
    fi
    wait "$ssh_pid"
    status=$?
    trap - EXIT HUP INT TERM
    exit "$status"
    """

    nonisolated private static func waitUntilForwardReady(
        localPort: Int
    ) async -> Bool {
        for _ in 0..<100 {
            if !canBind(port: localPort) { return true }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return false
    }

    private static func failureDescription(_ error: Error) -> String {
        if let posix = error as? POSIXError {
            return InfoStrings.current.allocatePortFailed(posix.localizedDescription)
        }
        return error.localizedDescription
    }

    private static func sshFailureDescription(
        status: Int32,
        errorOutput: String,
        localPort: Int
    ) -> String {
        let strings = InfoStrings.current
        let lower = errorOutput.lowercased()
        if lower.contains("address already in use") || lower.contains("cannot listen to port") {
            return strings.localPortInUse(localPort)
        }
        if lower.contains("permission denied") {
            return strings.authenticationFailed
        }
        if lower.contains("host key verification failed") {
            return strings.hostKeyFailed
        }
        if lower.contains("could not resolve hostname") {
            return strings.resolveHostFailed
        }
        if lower.contains("connection refused") {
            return strings.connectionRefused
        }
        if lower.contains("connection timed out") || lower.contains("operation timed out") {
            return strings.connectionTimedOut
        }
        let message = errorOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            .map { String($0.prefix(240)) }
        return message ?? strings.sshExited(status: status)
    }

    nonisolated private static func resolveRemoteProcesses(alias: String, ports: [Int]) async throws -> [Int: String] {
        let command = "exec /bin/sh -c \(shellQuote(remoteProcessCommand(ports: ports)))"
        let result = try await GitProcessRunner().run(
            executablePath: "/usr/bin/ssh",
            arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                        "-o", "ConnectionAttempts=1", "--", alias, command],
            workingDirectory: "/", maxOutputBytes: 64 * 1024, timeout: 6
        )
        guard result.exitCode == 0 else { throw ProcessProbeError.unavailable }
        return try parseRemoteProcessOutput(result.stdout, ports: ports)
    }

    nonisolated static func parseRemoteProcessOutput(_ data: Data, ports: [Int]) throws -> [Int: String] {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ProcessProbeError.invalidOutput
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.popLast() == "OMG_PROCESS_PROBE_V1" else { throw ProcessProbeError.invalidOutput }
        let requested = Set(ports)
        var seen: Set<Int> = []
        var names: [Int: String] = [:]
        for line in lines {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2, let port = Int(fields[0]), requested.contains(port),
                  seen.insert(port).inserted, fields[1].count <= 128,
                  !fields[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProcessProbeError.invalidOutput
            }
            if !fields[1].isEmpty { names[port] = fields[1] }
        }
        guard seen == requested else { throw ProcessProbeError.invalidOutput }
        return names
    }

    nonisolated static func remoteProcessCommand(ports: [Int]) -> String {
        // Only validated integer ports enter the remote shell. lsof/ss each
        // scan listeners once per batch; fuser is the per-port last resort.
        let ports = Array(Set(ports.filter(validPort))).sorted().map(String.init).joined(separator: " ")
        return """
        export LC_ALL=C
        tool=''
        snapshot=''
        if command -v lsof >/dev/null 2>&1; then
          tool=lsof
          snapshot=$(lsof -nP -iTCP -sTCP:LISTEN -Fpcn 2>/dev/null | awk '
            /^p/ { pid=substr($0,2) }
            /^c/ { name=substr($0,2) }
            /^n/ { endpoint=substr($0,2); sub(/^.*:/,"",endpoint); print endpoint " " pid " " name }
          ')
        elif command -v ss >/dev/null 2>&1; then
          tool=ss
          snapshot=$(ss -H -ltnp 2>/dev/null) || exit 69
        elif command -v fuser >/dev/null 2>&1; then
          tool=fuser
        else
          exit 69
        fi
        for port in \(ports); do
          pid=''
          fallback=''
          if [ "$tool" = lsof ]; then
            row=$(printf '%s\\n' "$snapshot" | awk -v port="$port" '$1 == port { print; exit }')
            pid=$(printf '%s' "$row" | awk '{print $2}')
            fallback=$(printf '%s' "$row" | cut -d ' ' -f 3-)
          elif [ "$tool" = ss ]; then
            socket=$(printf '%s\\n' "$snapshot" | awk -v port="$port" '$4 ~ (":" port "$") { print; exit }')
            pid=$(printf '%s' "$socket" | sed -n 's/.*pid=\\([0-9]*\\).*/\\1/p')
            fallback=$(printf '%s' "$socket" | sed -n 's/.*users:(("\\([^"]*\\)".*/\\1/p')
          else
            pid=$(fuser "$port/tcp" 2>/dev/null | awk '{print $1}')
          fi
          name="$fallback"
          if [ -n "$pid" ] && command -v ps >/dev/null 2>&1; then
            args=$(ps -p "$pid" -o args= 2>/dev/null | head -n 1)
            executable=${args%% *}
            [ -z "$executable" ] || name=${executable##*/}
          fi
          printf '%s\\t%s\\n' "$port" "$name"
        done
        printf 'OMG_PROCESS_PROBE_V1\\n'
        """
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func copyToPasteboard(_ value: String) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    nonisolated private static func allocateLocalPort(preferredPort: Int) throws -> Int {
        if validPort(preferredPort), canBind(port: preferredPort) {
            return preferredPort
        }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    nonisolated private static func canBind(port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuseAddress: Int32 = 1
        _ = withUnsafePointer(to: &reuseAddress) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
