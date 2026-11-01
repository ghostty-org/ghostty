import AppKit
import Combine
import Foundation

struct AgentIntegrationPolicy: Codable, Equatable {
    var checkAutomatically = true
    /// Automatic Hook maintenance: repairs stale integrations and adopts
    /// integrations for newly installed Agent CLIs. Enabled by default so that
    /// installing an Agent CLI is enough for OMG to recognize it; a user can still
    /// turn it off, and detector-only Agents removed by the user stay removed.
    var updateHooksAutomatically = true
    var automaticallyUpdatedAgents: Set<SupportedAgent> = []
    var intervalHours = 24
    var lastAttempt: Date?
    var lastSuccess: Date?
    var checkedIntegrationRevision: String?
    // Optional for compatibility with existing per-Agent policies.
    var updateAllCLIsAutomatically: Bool?
    var checkOnConnection: Bool?
    var lastMaintenance: Date?
    var lastMaintenanceError: String?

    var updatesCLIs: Bool { updateAllCLIsAutomatically == true || !automaticallyUpdatedAgents.isEmpty }

    func updatesCLI(_ agent: SupportedAgent) -> Bool {
        updateAllCLIsAutomatically == true || automaticallyUpdatedAgents.contains(agent)
    }

    var nextCheck: Date? {
        guard checkAutomatically, let lastAttempt else { return nil }
        return lastAttempt.addingTimeInterval(Double(max(1, intervalHours)) * 3_600)
    }

    func needsIntegrationCheck(revision: String) -> Bool {
        checkAutomatically && checkedIntegrationRevision != revision
    }

    func isDue(at date: Date) -> Bool {
        checkAutomatically && date.timeIntervalSince(lastAttempt ?? .distantPast) >=
            Double(max(1, intervalHours)) * 3_600
    }
}

struct AgentCLIInstallation: Codable, Equatable, Sendable {
    var version: String?
    var latest: String?
    var package: String?
    var path: String?
    var updater: String?

    var canAutomaticallyUpdate: Bool { package != nil || updater == "native" }
    var needsUpdateCheck: Bool { updateAvailable || updater == "native" }

    var updateAvailable: Bool {
        guard package != nil, let version, let latest else { return false }
        // Keep prerelease/pinned channels untouched and never downgrade when
        // an npm dist-tag points at a version older than the installed one.
        let stableVersion = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
        guard version.range(of: stableVersion, options: .regularExpression) != nil,
              latest.range(of: stableVersion, options: .regularExpression) != nil else { return false }
        let current = version.split(separator: ".").compactMap { Int($0) }
        let available = latest.split(separator: ".").compactMap { Int($0) }
        guard current.count == 3, available.count == 3 else { return false }
        return current.lexicographicallyPrecedes(available)
    }
}

struct AgentIntegrationSnapshot: Codable, Sendable {
    var hooks: [SupportedAgent: AgentHookInstallationState] = [:]
    var cli: [SupportedAgent: AgentCLIInstallation] = [:]
    var error: String?
    var hooksChanged: Bool?
    /// CLI maintenance is independent of Hook setup. Never present it as a Hook failure.
    var cliError: String?

    var maintenanceError: String? {
        let errors = [error, cliError].compactMap { $0 }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

/// App-owned maintenance survives closing Settings. Each operation captures a
/// target and publishes only to that target, including errors and timestamps.
@MainActor
final class AgentIntegrationManager: ObservableObject {
    static let shared = AgentIntegrationManager(registry: .shared)
    static let localID = "local"
    typealias ScriptRunner = @Sendable (_ script: String, _ target: String, _ loginShell: Bool) async throws -> Data
    @Published private(set) var policies: [String: AgentIntegrationPolicy]
    @Published private(set) var snapshots: [String: AgentIntegrationSnapshot] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var connectedTargets: Set<String> = []
    @Published private(set) var onboarding: [String: AgentIntegrationOnboarding] = [:]
    @Published private(set) var operations: [String: AgentIntegrationOperation] = [:]
    @Published private(set) var setupStates: [String: AgentHookSetupState] = [:]
    private var setupTasks: [String: Task<Void, Never>] = [:]
    private let onboardingKey = "OMG.AgentIntegration.Onboarding.v1"
    private let localSnapshotKey = "OMG.AgentIntegration.LocalSnapshot.v1"
    let registry: SSHHostRegistry
    private var registryObserver: AnyCancellable?
    private let defaults: UserDefaults
    private let homeURL: URL
    private let scriptRunner: ScriptRunner?
    private let connectionTargets: @MainActor () -> Set<String>
    private var timer: AnyCancellable?
    private var connectionObserver: AnyCancellable?
    private var closeObserver: AnyCancellable?
    private var automaticTasks: [String: Task<Void, Never>] = [:]
    private var automaticTargets: Set<String> = []
    private var checkedConnections: Set<String> = []
    private let storageKey = "OMG.AgentIntegration.Policies.v1"
    /// One-shot flag for enabling automatic Hook adoption on stored policies.
    private static let automaticHookAdoptionKey = "OMG.AgentIntegration.AutomaticHookAdoption.v1"
    let integrationRevision: String

    static var bundledIntegrationRevision: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] ?? "development")/" +
            "\(info["CFBundleVersion"] ?? "0")/hooks-\(AgentHookInstaller.hookVersion)"
    }

    init(
        defaults: UserDefaults = .standard,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        snapshots: [String: AgentIntegrationSnapshot] = [:],
        connectionTargets: @escaping @MainActor () -> Set<String> = AgentIntegrationManager.liveConnectionTargets,
        registry: SSHHostRegistry? = nil,
        integrationRevision: String? = nil,
        scriptRunner: ScriptRunner? = nil
    ) {
        self.integrationRevision = integrationRevision ?? Self.bundledIntegrationRevision
        let registry = registry ?? SSHHostRegistry(defaults: defaults)
        self.registry = registry
        self.defaults = defaults
        self.homeURL = homeURL
        self.scriptRunner = scriptRunner
        self.connectionTargets = connectionTargets
        self.connectedTargets = connectionTargets()
        policies = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: AgentIntegrationPolicy].self, from: $0) } ?? [:]
        if !defaults.bool(forKey: Self.automaticHookAdoptionKey) {
            // Policies saved before automatic Hook adoption existed carry the old
            // `false` default, which suppressed the feature entirely. Adopting is
            // now the default, so enable it once for those stored policies too.
            // Running once (not on every launch) keeps a later opt-out effective.
            for (target, var stored) in policies where !stored.updateHooksAutomatically {
                stored.updateHooksAutomatically = true
                policies[target] = stored
            }
            defaults.set(true, forKey: Self.automaticHookAdoptionKey)
            if let data = try? JSONEncoder().encode(policies) {
                defaults.set(data, forKey: storageKey)
            }
        }
        self.snapshots = Dictionary(uniqueKeysWithValues: registry.hosts.map { ($0.id, $0.snapshot) })
            .merging(snapshots, uniquingKeysWith: { _, fresh in fresh })
        if self.snapshots[Self.localID] == nil,
           let data = defaults.data(forKey: localSnapshotKey),
           let saved = try? JSONDecoder().decode(AgentIntegrationSnapshot.self, from: data) {
            self.snapshots[Self.localID] = saved
        }
        onboarding = defaults.data(forKey: onboardingKey)
            .flatMap { try? JSONDecoder().decode([String: AgentIntegrationOnboarding].self, from: $0) } ?? [:]
    }

    func start() {
        guard timer == nil else { return }
        // The app-hosted test runner must never schedule real maintenance.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        registry.start()
        registryObserver = registry.$hosts.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] hosts in
                guard let self else { return }
                for host in hosts where onboarding[host.id]?.awaitingFirstInventory == true {
                    loadCached(target: host.id)
                }
                checkDueTargets()
            }
        timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.checkDueTargets() }
        connectionObserver = NotificationCenter.default.publisher(for: .terminalPaneSessionContextsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkDueTargets() }
        closeObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkDueTargets() }
        checkDueTargets()
    }

    func policy(for target: String) -> AgentIntegrationPolicy {
        policies[target] ?? AgentIntegrationPolicy(checkAutomatically: target == Self.localID)
    }

    func setPolicy(_ policy: AgentIntegrationPolicy, for target: String) {
        policies[target] = policy
        if let data = try? JSONEncoder().encode(policies) { defaults.set(data, forKey: storageKey) }
    }

    func checkDueTargets(at date: Date = Date()) {
        registry.reconcile()
        let currentConnections = connectionTargets().union(registry.connections.keys)
        checkedConnections.subtract(connectedTargets.subtracting(currentConnections))
        if currentConnections != connectedTargets { connectedTargets = currentConnections }
        for (target, task) in automaticTasks where !allowsAutomaticWork(target) {
            task.cancel()
        }
        let targets = Set(policies.keys).union([Self.localID]).union(registry.hosts.map(\.id))
        for target in targets where shouldCheck(target, at: date) && !busy.contains(target)
            && automaticTasks[target] == nil && setupTasks[target] == nil {
            let hooksOnly = !policy(for: target).isDue(at: date) && !needsConnectionCheck(target)
            automaticTasks[target] = Task { [weak self] in
                guard let self else { return }
                await refresh(target: target, automatic: true, hooksOnly: hooksOnly)
                automaticTasks[target] = nil
            }
        }
    }

    func shouldCheck(_ target: String, at date: Date) -> Bool {
        let policy = policy(for: target)
        return allowsAutomaticWork(target) &&
            (policy.isDue(at: date) || policy.needsIntegrationCheck(revision: integrationRevision) || needsConnectionCheck(target))
    }

    private func needsConnectionCheck(_ target: String) -> Bool {
        let policy = policy(for: target)
        return policy.checkAutomatically && policy.checkOnConnection == true && !checkedConnections.contains(target)
    }

    static func liveConnectionTargets() -> Set<String> {
        Set(SSHHostRegistry.liveConnections().map { RegisteredSSHHost.id(for: $0) })
    }

    func allowsAutomaticWork(_ target: String) -> Bool {
        target == Self.localID || (registry.host(target) != nil && (connectionTargets().contains(target) || registry.isConnected(target)))
    }

    func snapshot(for target: String) -> AgentIntegrationSnapshot? {
        target == Self.localID ? snapshots[target] : registry.host(target)?.snapshot ?? snapshots[target]
    }

    func acknowledgeOnboarding(target: String) {
        var choice = AgentIntegrationOnboarding.choice(snapshot: snapshot(for: target))
        choice.knownAgents.formUnion(onboarding[target]?.knownAgents ?? [])
        onboarding[target] = choice
        saveOnboarding()
    }

    func onboardingPrompt(target: String) -> SSHAgentHookOnboarding? {
        let snapshot = snapshot(for: target)
        if let choice = onboarding[target] {
            let discovered = choice.newlyDetected(in: snapshot)
            let newAgents = SupportedAgent.allCases.filter {
                discovered.contains($0) && (target == Self.localID || $0.definition.hook.kind != .none)
            }
            return newAgents.isEmpty ? nil : .setupRequired(newAgents)
        }
        return SSHAgentHookOnboarding.prompt(snapshot: snapshot)
    }

    private func saveOnboarding() {
        if let data = try? JSONEncoder().encode(onboarding) { defaults.set(data, forKey: onboardingKey) }
    }

    private func publish(_ snapshot: AgentIntegrationSnapshot, target: String) {
        snapshots[target] = snapshot
        registry.storeSnapshot(snapshot, target: target)
        if var choice = onboarding[target], choice.awaitingFirstInventory {
            choice.receive(snapshot)
            onboarding[target] = choice
            saveOnboarding()
        }
        if target == Self.localID, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: localSnapshotKey)
        }
    }

    func loadCached(target: String) {
        guard let host = registry.host(target) else { return }
        snapshots[target] = host.snapshot
        if var choice = onboarding[target], choice.awaitingFirstInventory {
            choice.receive(host.snapshot)
            onboarding[target] = choice
            saveOnboarding()
        }
    }

    /// Owns the full one-click job, independent of whether Settings is open.
    /// Coalesce repeated clicks, publish queued state synchronously, and never
    /// navigate here. Only the caller's explicit Customize action opens Settings.
    @discardableResult
    func beginSetup(target: String, installAll: Bool) -> Task<Void, Never> {
        if let existing = setupTasks[target] { return existing }
        acknowledgeOnboarding(target: target)
        if !installAll {
            return Task {
                while registry.isCollecting(target) || busy.contains(target) {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                if snapshot(for: target)?.cli.isEmpty != false { await refresh(target: target, checkLatest: false) }
            }
        }
        setupStates[target] = .queued
        let task = Task { [self] in
            defer { setupTasks[target] = nil }
            while registry.isCollecting(target) || busy.contains(target) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            setupStates[target] = .running
            let result = await installDetectedHooks(target: target)
            if !Task.isCancelled { setupStates[target] = .finished(result) }
        }
        setupTasks[target] = task
        return task
    }

    func dismissSetupResult(target: String) {
        guard setupStates[target]?.isActive != true else { return }
        setupStates[target] = nil
    }

    @discardableResult
    func installDetectedHooks(target: String) async -> AgentHookSetupResult {
        guard !busy.contains(target), !registry.isCollecting(target) else {
            return .init(error: "Another operation is in progress.")
        }
        busy.insert(target)
        operations[target] = .init(kind: .checking)
        defer { busy.remove(target); operations[target] = nil }
        var snapshot = snapshot(for: target) ?? .init()
        snapshot.error = nil
        var errors: [String] = []
        var result = AgentHookSetupResult()
        do {
            if snapshot.cli.isEmpty { snapshot.cli = try await readCLI(target: target, checkLatest: false) }
            snapshot.hooks = try await readHooks(target: target)
            result.detected = snapshot.cli.filter {
                $0.value.path != nil && (target == Self.localID || $0.key.definition.hook.kind != .none)
            }.count
            let agents = Self.hookSetupCandidates(snapshot: snapshot, local: target == Self.localID)
            for (index, agent) in agents.enumerated() {
                try Task.checkCancellation()
                operations[target] = .init(kind: .hooks, agent: agent, completed: index, total: agents.count)
                do {
                    try await changeHook(agent, target: target, remove: false)
                    snapshot.hooks[agent] = .current
                    snapshot.hooksChanged = true
                    result.installed += 1
                } catch { errors.append(agent.displayName + ": " + error.localizedDescription) }
            }
        } catch { errors.append(error.localizedDescription) }
        guard !Task.isCancelled else { return .init(error: "Cancelled.") }
        snapshot.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        result.error = snapshot.error
        publish(snapshot, target: target)
        return result
    }

    static func hookSetupCandidates(snapshot: AgentIntegrationSnapshot, local: Bool) -> [SupportedAgent] {
        SupportedAgent.allCases.filter {
            snapshot.cli[$0]?.path != nil && (local || $0.definition.hook.kind != .none) &&
                snapshot.hooks[$0] != .current
        }
    }

    func forget(_ target: String) {
        automaticTasks[target]?.cancel()
        setupTasks[target]?.cancel()
        setupStates[target] = nil
        registry.unregister(target)
        snapshots[target] = nil
        policies[target] = nil
        if let data = try? JSONEncoder().encode(policies) { defaults.set(data, forKey: storageKey) }
    }

    func refresh(target: String, automatic: Bool = false, hooksOnly: Bool = false, checkLatest: Bool = true) async {
        guard !busy.contains(target), !registry.isCollecting(target) else { return }
        guard !automatic || policy(for: target).checkAutomatically else { return }
        guard !automatic || allowsAutomaticWork(target), !Task.isCancelled else { return }
        busy.insert(target)
        operations[target] = .init(kind: .checking)
        if automatic { automaticTargets.insert(target) }
        if !hooksOnly { checkedConnections.insert(target) }
        defer {
            busy.remove(target)
            operations[target] = nil
            automaticTargets.remove(target)
            if automatic, !Task.isCancelled, allowsAutomaticWork(target) {
                var current = self.policy(for: target)
                current.lastMaintenance = Date()
                current.lastMaintenanceError = self.snapshot(for: target)?.maintenanceError
                setPolicy(current, for: target)
            }
        }
        var policy = policy(for: target)
        if !hooksOnly { policy.lastAttempt = Date() }
        setPolicy(policy, for: target)
        var snapshot = snapshot(for: target) ?? AgentIntegrationSnapshot()
        snapshot.error = nil
        do {
            snapshot.hooks = try await readHooks(target: target)
            if automatic {
                // Stale integrations are repaired on every automatic pass. No CLI
                // lookup is needed for that, which is why it does not wait for the
                // discovery step below.
                if await repairStaleHooks(target: target, snapshot: &snapshot) {
                    snapshot.hooks = try await readHooks(target: target)
                }
            }
            var current = self.policy(for: target)
            current.lastSuccess = Date()
            current.checkedIntegrationRevision = integrationRevision
            setPolicy(current, for: target)
        } catch {
            if Task.isCancelled || (automatic && !allowsAutomaticWork(target)) { return }
            snapshot.error = error.localizedDescription
        }
        publish(snapshot, target: target)
        if hooksOnly { return }
        if automatic && !self.policy(for: target).updatesCLIs { return }
        // CLI discovery/network failures must not prevent Hook maintenance.
        snapshot.cliError = nil
        do {
            snapshot.cli = try await readCLI(target: target, checkLatest: checkLatest)
            if automatic, await adoptDiscoveredAgents(target: target, snapshot: &snapshot) {
                snapshot.hooks = try await readHooks(target: target)
            }
            if automatic {
                var updatedCLI = false
                for agent in SupportedAgent.allCases where snapshot.cli[agent]?.needsUpdateCheck == true {
                    guard !Task.isCancelled, allowsAutomaticWork(target), self.policy(for: target).checkAutomatically else { break }
                    guard self.policy(for: target).updatesCLI(agent),
                          snapshot.cli[agent]?.canAutomaticallyUpdate == true else { continue }
                    operations[target] = .init(kind: .cli, agent: agent)
                    do {
                        try await installCLI(agent, target: target)
                        updatedCLI = true
                    } catch {
                        snapshot.cliError = [snapshot.cliError, agent.displayName + ": " + error.localizedDescription]
                            .compactMap { $0 }.joined(separator: "\n")
                    }
                }
                if updatedCLI { snapshot.cli = try await readCLI(target: target) }
            }
        } catch {
            snapshot.cliError = [snapshot.cliError, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
        publish(snapshot, target: target)
    }

    /// Repairs integrations that exist but are stale. Runs whenever automatic
    /// checks are enabled, independent of the opt-in new-CLI adoption below, so a
    /// Hook version bump always reaches already-enabled integrations.
    private func repairStaleHooks(
        target: String,
        snapshot: inout AgentIntegrationSnapshot
    ) async -> Bool {
        guard policy(for: target).updateHooksAutomatically else { return false }
        var changed = false
        for agent in SupportedAgent.allCases where snapshot.hooks[agent] == .updateAvailable {
            guard !Task.isCancelled, allowsAutomaticWork(target),
                  policy(for: target).checkAutomatically else { break }
            operations[target] = .init(kind: .hooks, agent: agent)
            do {
                try await changeHook(agent, target: target, remove: false)
                snapshot.hooks[agent] = .current
                snapshot.hooksChanged = true
                changed = true
            } catch {
                snapshot.error = [snapshot.error, agent.displayName + ": " + error.localizedDescription]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }
        return changed
    }

    /// Adopts integrations for Agent CLIs that are installed but not yet integrated.
    ///
    /// This is what makes "install the Agent CLI, then open OMG" enough for the
    /// Agent to be recognized instead of requiring a manual Install. It only ever
    /// touches a `.missing` state, so it can never overwrite an existing Hook, and
    /// it stays behind the `updateHooksAutomatically` opt-in because it writes
    /// vendor configuration files. Detector-only Agents are adopted on the local
    /// host only: their markers are Host policy and are never exported remotely.
    private func adoptDiscoveredAgents(
        target: String,
        snapshot: inout AgentIntegrationSnapshot
    ) async -> Bool {
        guard policy(for: target).updateHooksAutomatically else { return false }
        var changed = false
        let local = target == Self.localID
        let installer = AgentHookInstaller(homeURL: homeURL)
        for agent in Self.hookSetupCandidates(
            snapshot: snapshot,
            local: local
        ) where snapshot.hooks[agent] == .missing {
            // A detector the user removed stays removed until they re-enable it.
            guard !(local && installer.isDetectorRemovedByUser(agent)) else { continue }
            guard !Task.isCancelled, allowsAutomaticWork(target),
                  policy(for: target).checkAutomatically else { break }
            operations[target] = .init(kind: .hooks, agent: agent)
            do {
                try await changeHook(agent, target: target, remove: false)
                snapshot.hooks[agent] = .current
                snapshot.hooksChanged = true
                changed = true
            } catch {
                snapshot.error = [snapshot.error, agent.displayName + ": " + error.localizedDescription]
                    .compactMap { $0 }.joined(separator: "\n")
            }
        }
        return changed
    }

    func update(_ agent: SupportedAgent, target: String, cli: Bool = false, remove: Bool = false) async {
        guard !busy.contains(target), !registry.isCollecting(target) else { return }
        busy.insert(target)
        operations[target] = .init(kind: cli ? .cli : .hooks, agent: agent)
        defer { busy.remove(target); operations[target] = nil }
        snapshots[target] = snapshot(for: target) ?? .init()
        if cli {
            snapshots[target, default: .init()].cliError = nil
        } else {
            snapshots[target, default: .init()].error = nil
        }
        do {
            if cli {
                try await installCLI(agent, target: target)
                snapshots[target, default: .init()].cli = try await readCLI(target: target)
            } else {
                try await changeHook(agent, target: target, remove: remove)
                snapshots[target, default: .init()].hooksChanged = true
                snapshots[target, default: .init()].hooks = try await readHooks(target: target)
            }
        } catch {
            let message = agent.displayName + ": " + error.localizedDescription
            if cli {
                snapshots[target, default: .init()].cliError = message
            } else {
                snapshots[target, default: .init()].error = message
            }
        }
        if let snapshot = snapshots[target] { publish(snapshot, target: target) }
    }

    private func readHooks(target: String) async throws -> [SupportedAgent: AgentHookInstallationState] {
        if target == Self.localID {
            let home = homeURL
            return await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: SupportedAgent.allCases.map {
                    ($0, AgentHookInstaller(homeURL: home).installationState($0))
                })
            }.value
        }
        let script = try AgentHookInstaller.remoteInstallerScript(action: .status)
        let output = try await runPython(script, target: target)
        let states = try JSONDecoder().decode([String: String].self, from: output)
        return Dictionary(uniqueKeysWithValues: states.compactMap { key, value in
            guard let agent = SupportedAgent(rawValue: key) else { return nil }
            let state: AgentHookInstallationState
            switch value {
            case "current": state = .current
            case "updateAvailable": state = .updateAvailable
            case "missing": state = .missing
            default: return nil
            }
            return (agent, state)
        })
    }

    private func changeHook(_ agent: SupportedAgent, target: String, remove: Bool) async throws {
        if target == Self.localID {
            let home = homeURL
            try await Task.detached(priority: .utility) {
                let installer = AgentHookInstaller(homeURL: home)
                if remove { try installer.uninstall(agent) } else { try installer.install(agent) }
            }.value
        } else {
            guard agent.definition.hook.kind != .none else { return }
            let script = try AgentHookInstaller.remoteInstallerScript(
                action: remove ? .remove : .install, agents: [agent]
            )
            _ = try await runPython(script, target: target)
        }
    }

    private func readCLI(target: String, checkLatest: Bool = true) async throws -> [SupportedAgent: AgentCLIInstallation] {
        let output = try await runPython(try Self.cliScript(checkLatest: checkLatest), target: target, loginShell: true)
        let values = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: output)
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            SupportedAgent(rawValue: key).map { ($0, value) }
        })
    }

    private func installCLI(_ agent: SupportedAgent, target: String) async throws {
        _ = try await runPython(try Self.cliScript(update: agent), target: target, loginShell: true)
    }

    private func runPython(_ script: String, target: String, loginShell: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        if automaticTargets.contains(target), !allowsAutomaticWork(target) { throw CancellationError() }
        if let scriptRunner { return try await scriptRunner(script, target, loginShell) }
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        if target == Self.localID {
            executable = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
            let interpreter: LocalPythonInterpreter
            do {
                interpreter = try await LocalPythonInterpreter.resolve()
            } catch LocalPythonInterpreterError.unavailable {
                interpreter = try await LocalPythonInterpreter.resolveFromLoginShell(
                    shellPath: executable,
                    loginShell: loginShell
                )
            }
            let invocation = "\(interpreter.shellEnvironmentPreamble); exec \(interpreter.shellQuotedExecutable) -"
            arguments = [loginShell ? "-lic" : "-lc", invocation]
            environment = interpreter.environment
        } else {
            guard let host = registry.host(target) else { throw AgentHistoryRemoteError.unavailable }
            return try await SSHSessionTransport.python(script, connection: registry.connections[target] ?? host.connection, loginShell: loginShell)
        }

        // Shell startup output is separated from the actual script output.
        let wrapped = "print('OMG_AGENT_RESULT_BEGIN', flush=True)\n" + script
        let result = try await GitProcessRunner().run(
            executablePath: executable, arguments: arguments,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: environment,
            stdin: Data(wrapped.utf8), maxOutputBytes: 1_048_576, timeout: 360
        )
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        guard let marker = result.stdoutString.range(of: "OMG_AGENT_RESULT_BEGIN\n") else {
            throw AgentHistoryRemoteError.unavailable
        }
        return Data(result.stdoutString[marker.upperBound...].utf8)
    }

    /// Resolve the command to its actual npm bin before offering updates. A
    /// same-named Homebrew/native executable must never be replaced through npm.
    nonisolated static func cliScript(update: SupportedAgent? = nil, checkLatest: Bool = true) throws -> String {
        let commands = Dictionary(uniqueKeysWithValues: SupportedAgent.allCases.map {
            ($0.rawValue, $0.definition.command)
        })
        let data = try JSONEncoder().encode(commands)
        return #"""
import base64, json, os, pathlib, re, shutil, subprocess
COMMANDS = json.loads(base64.b64decode("\#(data.base64EncodedString())"))
UPDATE = "\#(update?.rawValue ?? "")"
CHECK_LATEST = \#(checkLatest ? "True" : "False")
# Explicit policy, not a capability probe: vendor commands own version checks.
NATIVE_UPDATES = {
    "codex": ["update"], "claude": ["update"],
    "omp": ["update"], "qoder": ["update"],
    "opencode": ["upgrade"], "pi": ["update", "--all"],
    "reasonix": ["upgrade"], "antigravity": ["update"],
    "cursor": ["update"], "amp": ["update"],
    "copilot": ["update"], "droid": ["update"],
    "kimi": ["upgrade", "--yes"],
    "hermes": ["update", "--yes", "--no-gateway-restart"],
    "grok": ["update"], "cline": ["update"], "qwen": ["update"],
}

def run(args, timeout=30):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip()[:2000] or "Command failed: " + args[0])
    return result

def newer(current, latest):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", current): return False
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", latest): return False
    return tuple(map(int, latest.split("."))) > tuple(map(int, current.split(".")))

def outdated_packages(names):
    result = run([npm, "outdated", "--global", "--json", "--"] + names, timeout=90)
    outdated = json.loads(result.stdout or "{}")
    if "error" in outdated: raise RuntimeError(str(outdated["error"])[:2000])
    if result.returncode != 0 and not outdated: raise RuntimeError(result.stderr.strip()[:2000])
    return outdated

packages = {}
npm = shutil.which("npm")
if npm:
    result = run([npm, "root", "--global"])
    if result.returncode != 0: raise RuntimeError(result.stderr)
    root = pathlib.Path(result.stdout.strip())
    for manifest in list(root.glob("*/package.json")) + list(root.glob("@*/*/package.json")):
        package = json.loads(manifest.read_text())
        if not re.fullmatch(r"(?:@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*", package.get("name", "")): continue
        bins = package.get("bin", {})
        if isinstance(bins, str): bins = {package["name"].split("/")[-1]: bins}
        for command, relative in bins.items():
            packages[str((manifest.parent / relative).resolve())] = package

installed = {}
for agent, command in COMMANDS.items():
    if UPDATE and agent != UPDATE: continue
    path = shutil.which(command)
    if not path:
        installed[agent] = {}
        continue
    package = packages.get(os.path.realpath(path))
    item = {"path": path}
    if package:
        item.update(version=package["version"], package=package["name"])
    else:
        try:
            version = run([path, "--version"], timeout=8)
            if version.returncode == 0: item["version"] = version.stdout.strip()[:160]
        except (subprocess.TimeoutExpired, OSError): pass
    # Reasonix refuses self-upgrade for package-manager installations. Droid's
    # npm builds are pinned; Grok/Qwen self-update only standalone installs.
    # Use npm only when the resolved executable matches a verified package bin.
    if agent in NATIVE_UPDATES and not (package and agent in ("reasonix", "droid", "grok", "qwen")):
        item["updater"] = "native"
    installed[agent] = item

if UPDATE:
    item = installed[UPDATE]
    if item.get("updater") == "native":
        result = run([item["path"]] + NATIVE_UPDATES[UPDATE], timeout=180)
        if result.returncode != 0: raise RuntimeError(result.stderr.strip()[:2000] or "Native updater failed")
        raise SystemExit(0)
    if not item.get("package"): raise RuntimeError("Agent is not managed by this npm installation")
    latest = outdated_packages([item["package"]]).get(item["package"], {}).get("latest", item["version"])
    if newer(item["version"], latest):
        result = run([npm, "install", "--global", "--", item["package"] + "@" + latest], timeout=180)
        if result.returncode != 0: raise RuntimeError(result.stderr.strip()[:2000])
else:
    names = sorted(set(item["package"] for item in installed.values()
                       if item.get("package") and item.get("updater") != "native"))
    if names and CHECK_LATEST:
        outdated = outdated_packages(names)
        for item in installed.values():
            if item.get("package") and item.get("updater") != "native":
                item["latest"] = outdated.get(item["package"], {}).get("latest", item["version"])
    print(json.dumps(installed))
"""#
    }
}
