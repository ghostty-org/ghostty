import AppKit
import Combine
import Foundation

struct AgentIntegrationPolicy: Codable, Equatable {
    var checkAutomatically = true
    var updateHooksAutomatically = false
    var automaticallyUpdatedAgents: Set<SupportedAgent> = []
    var intervalHours = 24
    var lastAttempt: Date?
    var lastSuccess: Date?

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
}

/// App-owned maintenance survives closing Settings. Each operation captures a
/// target and publishes only to that target, including errors and timestamps.
@MainActor
final class AgentIntegrationManager: ObservableObject {
    static let shared = AgentIntegrationManager(registry: .shared)
    static let localID = "local"
    @Published private(set) var policies: [String: AgentIntegrationPolicy]
    @Published private(set) var snapshots: [String: AgentIntegrationSnapshot] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var connectedTargets: Set<String> = []
    let registry: SSHHostRegistry
    private var registryObserver: AnyCancellable?
    private let defaults: UserDefaults
    private let homeURL: URL
    private let connectionTargets: @MainActor () -> Set<String>
    private var timer: AnyCancellable?
    private var connectionObserver: AnyCancellable?
    private var closeObserver: AnyCancellable?
    private var automaticTasks: [String: Task<Void, Never>] = [:]
    private var automaticTargets: Set<String> = []
    private let storageKey = "OMG.AgentIntegration.Policies.v1"

    init(
        defaults: UserDefaults = .standard,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        snapshots: [String: AgentIntegrationSnapshot] = [:],
        connectionTargets: @escaping @MainActor () -> Set<String> = AgentIntegrationManager.liveConnectionTargets,
        registry: SSHHostRegistry? = nil
    ) {
        let registry = registry ?? SSHHostRegistry(defaults: defaults)
        self.registry = registry
        self.defaults = defaults
        self.homeURL = homeURL
        self.snapshots = Dictionary(uniqueKeysWithValues: registry.hosts.map { ($0.id, $0.snapshot) })
            .merging(snapshots, uniquingKeysWith: { _, fresh in fresh })
        self.connectionTargets = connectionTargets
        self.connectedTargets = connectionTargets()
        policies = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: AgentIntegrationPolicy].self, from: $0) } ?? [:]
    }

    func start() {
        guard timer == nil else { return }
        // The app-hosted test runner must never schedule real maintenance.
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        registry.start()
        registryObserver = registry.$hosts.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkDueTargets() }
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
        let currentConnections = connectionTargets()
        if currentConnections != connectedTargets { connectedTargets = currentConnections }
        for (target, task) in automaticTasks where !allowsAutomaticWork(target) {
            task.cancel()
        }
        let targets = Set(policies.keys).union([Self.localID])
        for target in targets where policy(for: target).isDue(at: date) && !busy.contains(target)
            && automaticTasks[target] == nil && allowsAutomaticWork(target) {
            automaticTasks[target] = Task { [weak self] in
                guard let self else { return }
                await refresh(target: target, automatic: true)
                automaticTasks[target] = nil
            }
        }
    }

    static func liveConnectionTargets() -> Set<String> {
        Set(SSHHostRegistry.liveConnections().map { RegisteredSSHHost.id(for: $0) })
    }

    func allowsAutomaticWork(_ target: String) -> Bool {
        target == Self.localID || (registry.host(target) != nil && connectionTargets().contains(target))
    }

    func loadCached(target: String) {
        guard let host = registry.host(target) else { return }
        snapshots[target] = host.snapshot
    }

    func forget(_ target: String) {
        automaticTasks[target]?.cancel()
        registry.unregister(target)
        snapshots[target] = nil
        policies[target] = nil
        if let data = try? JSONEncoder().encode(policies) { defaults.set(data, forKey: storageKey) }
    }

    func refresh(target: String, automatic: Bool = false) async {
        guard !busy.contains(target), !registry.isCollecting(target) else { return }
        guard !automatic || policy(for: target).checkAutomatically else { return }
        guard !automatic || allowsAutomaticWork(target), !Task.isCancelled else { return }
        busy.insert(target)
        if automatic { automaticTargets.insert(target) }
        defer {
            busy.remove(target)
            automaticTargets.remove(target)
        }
        var policy = policy(for: target)
        policy.lastAttempt = Date()
        setPolicy(policy, for: target)
        var snapshot = snapshots[target] ?? registry.host(target)?.snapshot ?? AgentIntegrationSnapshot()
        snapshot.error = nil
        var captured = false
        do {
            snapshot.hooks = try await readHooks(target: target)
            captured = true
            if automatic {
                for agent in SupportedAgent.allCases where snapshot.hooks[agent] == .updateAvailable {
                    guard !Task.isCancelled, allowsAutomaticWork(target), self.policy(for: target).checkAutomatically,
                          self.policy(for: target).updateHooksAutomatically else { break }
                    do { try await changeHook(agent, target: target, remove: false) } catch { snapshot.error = error.localizedDescription }
                }
                snapshot.hooks = try await readHooks(target: target)
            }
            var current = self.policy(for: target)
            current.lastSuccess = Date()
            setPolicy(current, for: target)
        } catch {
            if Task.isCancelled || (automatic && !allowsAutomaticWork(target)) { return }
            snapshot.error = error.localizedDescription
        }
        snapshots[target] = snapshot
        if captured { registry.storeSnapshot(snapshot, target: target) }
        if automatic && self.policy(for: target).automaticallyUpdatedAgents.isEmpty { return }
        // CLI discovery/network failures must not prevent Hook maintenance.
        do {
            snapshot.cli = try await readCLI(target: target)
            captured = true
            if automatic {
                var updatedCLI = false
                for agent in SupportedAgent.allCases where snapshot.cli[agent]?.updateAvailable == true {
                    guard !Task.isCancelled, allowsAutomaticWork(target), self.policy(for: target).checkAutomatically else { break }
                    guard self.policy(for: target).automaticallyUpdatedAgents.contains(agent) else { continue }
                    do {
                        try await installCLI(agent, target: target)
                        updatedCLI = true
                    } catch { snapshot.error = error.localizedDescription }
                }
                if updatedCLI { snapshot.cli = try await readCLI(target: target) }
            }
        } catch {
            snapshot.error = [snapshot.error, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
        }
        snapshots[target] = snapshot
        if captured { registry.storeSnapshot(snapshot, target: target) }
    }

    func update(_ agent: SupportedAgent, target: String, cli: Bool = false, remove: Bool = false) async {
        guard !busy.contains(target), !registry.isCollecting(target) else { return }
        busy.insert(target)
        snapshots[target, default: .init()].error = nil
        var captured = false
        do {
            if cli { try await installCLI(agent, target: target) } else { try await changeHook(agent, target: target, remove: remove) }
            snapshots[target, default: .init()].hooks = try await readHooks(target: target)
            captured = true
            if cli { snapshots[target, default: .init()].cli = try await readCLI(target: target) }
        } catch {
            snapshots[target, default: .init()].error = error.localizedDescription
        }
        if captured, let snapshot = snapshots[target] { registry.storeSnapshot(snapshot, target: target) }
        busy.remove(target)
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

    private func readCLI(target: String) async throws -> [SupportedAgent: AgentCLIInstallation] {
        let output = try await runPython(try Self.cliScript(), target: target, loginShell: true)
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
        let executable: String
        let arguments: [String]
        // Feed scripts through stdin, avoiding remote command/ARG_MAX limits.
        let invocation = "exec python3 -"
        if target == Self.localID {
            executable = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
            arguments = [loginShell ? "-lic" : "-lc", invocation]
        } else {
            guard let host = registry.host(target) else { throw AgentHistoryRemoteError.unavailable }
            return try await SSHSessionTransport.python(script, connection: host.connection, loginShell: loginShell)
        }

        // Shell startup output is separated from the actual script output.
        let wrapped = "print('OMG_AGENT_RESULT_BEGIN', flush=True)\n" + script
        let result = try await GitProcessRunner().run(
            executablePath: executable, arguments: arguments,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
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
    installed[agent] = item

if UPDATE:
    item = installed[UPDATE]
    if not item.get("package"): raise RuntimeError("Agent is not managed by this npm installation")
    latest = outdated_packages([item["package"]]).get(item["package"], {}).get("latest", item["version"])
    if newer(item["version"], latest):
        result = run([npm, "install", "--global", "--", item["package"] + "@" + latest], timeout=180)
        if result.returncode != 0: raise RuntimeError(result.stderr.strip()[:2000])
else:
    names = sorted(set(item["package"] for item in installed.values() if item.get("package")))
    if names and CHECK_LATEST:
        outdated = outdated_packages(names)
        for item in installed.values():
            if item.get("package"):
                item["latest"] = outdated.get(item["package"], {}).get("latest", item["version"])
    print(json.dumps(installed))
"""#
    }
}
