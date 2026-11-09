import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationManagerTests {
    actor RemoteAutomaticSetupFixture {
        var installs = 0
        var discoveries = 0
        func run(_ script: String) -> Data {
            if script.contains("COMMANDS =") {
                discoveries += 1
                return Data(#"{"pi":{"path":"/bin/pi","version":"1.0.0"}}"#.utf8)
            }
            if script.contains("ACTION = \"install\"") { installs += 1 }
            return Data((installs == 0 ? #"{"pi":"missing"}"# : #"{"pi":"current"}"#).utf8)
        }
    }

    @Test func hostSetupPreferenceGatesAutomaticHooksButAllowsExplicitInstallation() async throws {
        let suite = "HostHookPolicy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] })
        let target = registry.addConfigured(try GitSSHConnection(destination: "setup-policy-fixture"))
        let fixture = RemoteAutomaticSetupFixture()
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { [target] }, registry: registry,
            scriptRunner: { script, _, _ in await fixture.run(script) })
        manager.setPolicy(.init(checkAutomatically: true, updateHooksAutomatically: true), for: target)
        await manager.refresh(target: target, automatic: true)
        #expect(await fixture.installs == 0)
        #expect(await fixture.discoveries == 0)
        registry.configure(target, hooks: true)
        await manager.refresh(target: target, automatic: true)
        #expect(await fixture.installs == 1)
        #expect(await fixture.discoveries == 1)
        registry.configure(target, hooks: false)
        await manager.update(.pi, target: target)
        #expect(await fixture.installs == 2)
    }

    actor SetupFixture {
        let home: URL
        var installs = 0
        var discoveries = 0
        init(home: URL) { self.home = home }

        func run(_ script: String, _ target: String, _ loginShell: Bool) async throws -> Data {
            if script.contains("COMMANDS =") {
                guard script.contains("UPDATE = \"\"") else {
                    throw GitExecutionError.executionFailed("One-click Hook setup must never upgrade a CLI")
                }
                discoveries += 1
                return Data(#"{"pi":{"path":"/bin/pi","version":"1.0.0"}}"#.utf8)
            }
            if script.contains("ACTION = \"install\"") { installs += 1 }
            let result = try await GitProcessRunner().run(
                executablePath: "/usr/bin/python3", arguments: ["-"], workingDirectory: "/tmp",
                environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], stdin: Data(script.utf8), timeout: 30)
            guard result.isSuccess else { throw GitExecutionError.executionFailed(result.stderrString) }
            return result.stdout
        }
    }

    @Test func oneClickInstallsRemoteHooksWithoutSettingsOrSecondClick() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let connection = try GitSSHConnection(destination: "setup-fixture")
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let target = registry.prepareSetup(connection)
        let fixture = SetupFixture(home: home)
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry,
            scriptRunner: { try await fixture.run($0, $1, $2) })
        let navigation = SettingsNavigation.pendingAgentTarget
        let first = manager.beginSetup(target: target, installAll: true)
        #expect(manager.setupStates[target] == .queued)
        let repeated = manager.beginSetup(target: target, installAll: true)
        await first.value
        await repeated.value
        #expect(await fixture.installs == 1)
        #expect(await fixture.discoveries == 1)
        #expect(manager.snapshot(for: target)?.hooks[.pi] == .current)
        #expect(manager.setupStates[target] == .finished(.init(detected: 1, installed: 1)))
        #expect(SettingsNavigation.pendingAgentTarget == navigation)
        #expect(manager.onboardingPrompt(target: target) == nil)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi/agent/extensions/omg-agent-status.ts").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path))
        manager.dismissSetupResult(target: target)
        #expect(manager.setupStates[target] == nil)
    }

    @Test func oneClickWaitsForInventoryThenInstallsWithoutAnotherAction() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let connection = try GitSSHConnection(destination: "setup-fixture")
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in
            try await Task.sleep(for: .milliseconds(80))
            return .init(hooks: [.pi: .missing], cli: [.pi: .init(path: "/bin/pi")])
        })
        let target = registry.prepareSetup(connection)
        let fixture = SetupFixture(home: home)
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry,
            scriptRunner: { try await fixture.run($0, $1, $2) })
        let inventory = Task { await registry.register(connection, endpoint: "fixture") }
        for _ in 0..<50 where !registry.isCollecting(target) { await Task.yield() }
        #expect(registry.isCollecting(target))
        let setup = manager.beginSetup(target: target, installAll: true)
        #expect(manager.setupStates[target] == .queued)
        await inventory.value
        await setup.value
        #expect(await fixture.installs == 1)
        #expect(await fixture.discoveries == 0)
        #expect(manager.setupStates[target] == .finished(.init(detected: 1, installed: 1)))
    }

    @Test func cliFailureIsSeparateFromHookResultAndSurvivesHookSetup() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.pi)
        let initial = AgentIntegrationSnapshot(hooks: [.pi: .current], cli: [.pi: .init(path: "/bin/pi")], error: "existing Hook failure")
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home, snapshots: ["local": initial], connectionTargets: { [] },
            scriptRunner: { _, _, _ in throw GitExecutionError.executionFailed("[unauthenticated] Error") })
        await manager.update(.cursor, target: "local", cli: true)
        #expect(manager.snapshots["local"]?.error == "existing Hook failure")
        #expect(manager.snapshots["local"]?.cliError?.contains("unauthenticated") == true)
        let result = await manager.installDetectedHooks(target: "local")
        #expect(result.error == nil)
        #expect(manager.snapshots["local"]?.error == nil)
        #expect(manager.snapshots["local"]?.cliError?.contains("unauthenticated") == true)
        #expect(installer.installationState(.pi) == .current)
        let restored = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] })
        #expect(restored.snapshots["local"]?.cliError == manager.snapshots["local"]?.cliError)
        #expect(AgentIntegrationErrorHint.isAuthenticationFailure(restored.snapshots["local"]?.cliError ?? ""))
    }

    @Test func sshHookOnboardingUsesInventoryWithoutInstallingAnything() {
        #expect(SSHAgentHookOnboarding.prompt(snapshot: nil) == .checkRequired)
        #expect(SSHAgentHookOnboarding.prompt(snapshot: .init()) == .checkRequired)
        let agy = AgentCLIInstallation(version: "1.3.5", path: "/bin/agy")
        var snapshot = AgentIntegrationSnapshot(hooks: [.antigravity: .missing], cli: [.antigravity: agy])
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == .setupRequired([.antigravity]))
        snapshot.hooks[.antigravity] = .updateAvailable
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == .setupRequired([.antigravity]))
        snapshot.hooks[.antigravity] = .current
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == nil)
        snapshot.hooks.removeValue(forKey: .antigravity)
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == .checkRequired)
        snapshot.error = "Python unavailable"
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == .checkRequired)
    }

    @Test func sshHookOnboardingIgnoresAbsentCLIsAndLocalDetectors() {
        let snapshot = AgentIntegrationSnapshot(
            hooks: [.antigravity: .missing, .codex: .current, .crush: .missing, .hermes: .missing],
            cli: [.antigravity: .init(), .codex: .init(path: "/bin/codex"),
                  .crush: .init(path: "/bin/crush"), .hermes: .init(path: "/bin/hermes")]
        )
        // Crush is detector-only (local Host policy) so SSH never prompts for it;
        // Hermes has a real vendor Hook now, so a remote install is offered.
        #expect(SSHAgentHookOnboarding.prompt(snapshot: snapshot) == .setupRequired([.hermes]))
    }

    @Test func onboardingChoiceSurvivesRestartAndOnlyNewCLIsPrompt() throws {
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var snapshot = AgentIntegrationSnapshot(hooks: [.antigravity: .missing], cli: [.antigravity: .init(path: "/bin/agy")])
        let manager = AgentIntegrationManager(defaults: defaults, snapshots: ["local": snapshot], connectionTargets: { [] })
        manager.acknowledgeOnboarding(target: "local")
        #expect(manager.onboardingPrompt(target: "local") == nil)
        snapshot.hooks[.antigravity] = .updateAvailable
        let reopened = AgentIntegrationManager(defaults: defaults, snapshots: ["local": snapshot], connectionTargets: { [] })
        #expect(reopened.onboardingPrompt(target: "local") == nil)
        snapshot.cli[.pi] = .init(path: "/bin/pi")
        let discovered = AgentIntegrationManager(defaults: defaults, snapshots: ["local": snapshot], connectionTargets: { [] })
        #expect(discovered.onboardingPrompt(target: "local") == .setupRequired([.pi]))
        discovered.acknowledgeOnboarding(target: "local")
        #expect(discovered.onboardingPrompt(target: "local") == nil)
        #expect(discovered.onboardingPrompt(target: "other-host") == .checkRequired)
    }

    @Test func unknownOnboardingBaselineWaitsForInventoryNotAnError() {
        var choice = AgentIntegrationOnboarding.choice(snapshot: nil)
        choice.receive(.init(error: "offline"))
        #expect(choice.awaitingFirstInventory)
        let first = AgentIntegrationSnapshot(cli: [.antigravity: .init(path: "/bin/agy"), .codex: .init()])
        choice.receive(first)
        #expect(!choice.awaitingFirstInventory)
        #expect(choice.knownAgents == [.antigravity])
        #expect(choice.newlyDetected(in: first).isEmpty)
        var second = first
        second.cli[.codex] = .init(path: "/bin/codex")
        choice.receive(second)
        #expect(choice.newlyDetected(in: second) == [.codex])
    }

    @Test func bulkSetupInstallsOnlyDetectedHooksAndReportsPartialFailure() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let hooks = home.appendingPathComponent(".gemini/config/hooks.json")
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unowned = #"{"omg-agent-status":{"Stop":[{"command":"echo user-owned"}]}}"#
        try unowned.write(to: hooks, atomically: true, encoding: .utf8)
        let snapshot = AgentIntegrationSnapshot(cli: [.antigravity: .init(path: "/bin/agy"), .pi: .init(path: "/bin/pi"), .codex: .init()])
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home, snapshots: ["local": snapshot], connectionTargets: { [] })
        manager.acknowledgeOnboarding(target: "local")
        await manager.installDetectedHooks(target: "local")
        let installer = AgentHookInstaller(homeURL: home)
        #expect(installer.installationState(.pi) == .current)
        #expect(installer.installationState(.codex) == .missing)
        #expect(try String(contentsOf: hooks, encoding: .utf8) == unowned)
        #expect(manager.snapshots["local"]?.error?.contains("Antigravity") == true)
        #expect(manager.snapshots["local"]?.hooksChanged == true)
        #expect(manager.busy.isEmpty && manager.operations.isEmpty)
        #expect(manager.onboardingPrompt(target: "local") == nil)
        let restored = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] })
        #expect(restored.snapshots["local"]?.cli[.pi]?.path == "/bin/pi")
        #expect(restored.snapshots["local"]?.error?.contains("Antigravity") == true)
    }

    @Test func bulkSetupSkipsCurrentAbsentAndRemoteDetectorIntegrations() {
        let snapshot = AgentIntegrationSnapshot(hooks: [.pi: .current, .antigravity: .updateAvailable],
            cli: [.pi: .init(path: "/bin/pi"), .antigravity: .init(path: "/bin/agy"),
                  .crush: .init(path: "/bin/crush"), .codex: .init()])
        #expect(AgentIntegrationManager.hookSetupCandidates(snapshot: snapshot, local: false) == [.antigravity])
        #expect(Set(AgentIntegrationManager.hookSetupCandidates(snapshot: snapshot, local: true)) == [.antigravity, .crush])
    }

    @Test func unifiedCLIUpdatesPreserveLegacySelectionUntilExplicitlyEnabled() throws {
        var policy = try JSONDecoder().decode(AgentIntegrationPolicy.self, from: Data(#"{"checkAutomatically":true,"updateHooksAutomatically":false,"automaticallyUpdatedAgents":["pi"],"intervalHours":24}"#.utf8))
        #expect(policy.updateAllCLIsAutomatically == nil)
        #expect(policy.updatesCLI(.pi))
        #expect(!policy.updatesCLI(.antigravity))
        policy.updateAllCLIsAutomatically = true
        #expect(SupportedAgent.allCases.allSatisfy { policy.updatesCLI($0) })
        policy.lastAttempt = Date(timeIntervalSince1970: 100)
        #expect(policy.nextCheck == Date(timeIntervalSince1970: 86_500))
        policy.checkAutomatically = false
        #expect(policy.nextCheck == nil)
    }

    @Test func connectionMaintenanceIsOptInAndRunsOncePerLaunch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home, connectionTargets: { [] })
        var policy = manager.policy(for: "local")
        policy.lastAttempt = Date()
        policy.checkedIntegrationRevision = manager.integrationRevision
        manager.setPolicy(policy, for: "local")
        #expect(!manager.shouldCheck("local", at: Date()))
        policy.checkOnConnection = true
        manager.setPolicy(policy, for: "local")
        #expect(manager.shouldCheck("local", at: Date()))
        await manager.refresh(target: "local", automatic: true)
        #expect(!manager.shouldCheck("local", at: Date()))
        #expect(manager.policy(for: "local").lastMaintenance != nil)
        let restarted = AgentIntegrationManager(defaults: defaults, homeURL: home, connectionTargets: { [] })
        #expect(restarted.shouldCheck("local", at: Date()))
        #expect(!restarted.shouldCheck("ssh:offline", at: Date()))
    }

    @Test func appUpgradeChecksHooksImmediatelyAndPreservesCLIDeadline() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.pi)
        let path = home.appendingPathComponent(".pi/agent/extensions/omg-agent-status.ts")
        try "// marker: _omg_agent_status\n// old adapter\n".write(to: path, atomically: true, encoding: .utf8)
        let now = Date()
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "new-app")
        var policy = manager.policy(for: "local")
        policy.lastAttempt = now
        policy.checkedIntegrationRevision = "old-app"
        manager.setPolicy(policy, for: "local")
        #expect(!policy.isDue(at: now))
        #expect(manager.shouldCheck("local", at: now))
        await manager.refresh(target: "local", automatic: true, hooksOnly: true)
        // Automatic Hook maintenance is on by default, so an app upgrade repairs the
        // stale adapter immediately instead of waiting for the CLI interval.
        #expect(installer.installationState(.pi) == .current)
        #expect(manager.snapshots["local"]?.hooks[.pi] == .current)
        #expect(manager.snapshots["local"]?.cli.isEmpty == true)
        #expect(manager.policy(for: "local").lastAttempt == now)
        #expect(!manager.shouldCheck("local", at: now))
        let reopened = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "new-app")
        #expect(!reopened.shouldCheck("local", at: now))
        let upgraded = AgentIntegrationManager(defaults: defaults, homeURL: home, integrationRevision: "next-app")
        #expect(upgraded.shouldCheck("local", at: now))
        policy.updateHooksAutomatically = true
        upgraded.setPolicy(policy, for: "local")
        await upgraded.refresh(target: "local", automatic: true, hooksOnly: true)
        #expect(installer.installationState(.pi) == .current)
        #expect(installer.installationState(.claude) == .missing)
        #expect(upgraded.snapshots["local"]?.hooksChanged == true)
        policy.checkAutomatically = false
        upgraded.setPolicy(policy, for: "local")
        #expect(!upgraded.shouldCheck("local", at: now))
        #expect(!upgraded.shouldCheck("ssh:offline", at: now))
    }

    @Test func legacyPoliciesDecodeWithoutUpgradeRevision() throws {
        let policy = try JSONDecoder().decode(AgentIntegrationPolicy.self, from: Data(#"{"checkAutomatically":true,"updateHooksAutomatically":false,"automaticallyUpdatedAgents":[],"intervalHours":24}"#.utf8))
        #expect(policy.checkedIntegrationRevision == nil)
        #expect(policy.needsIntegrationCheck(revision: "new-app"))
    }

    @Test func standaloneCodexUsesItsNativeUpdaterWithoutNpm() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("updates")
        try executable(#"""
#!/usr/bin/python3
import os, pathlib, sys
if sys.argv[1:] == ["--version"]: print("codex-cli 0.154.0")
elif sys.argv[1:] == ["update"]: pathlib.Path(os.environ["UPDATE_LOG"]).write_text("native update")
else: sys.exit(2)
"""#, at: home.appendingPathComponent("codex"))
        let environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin", "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory["codex"]?.package == nil)
        #expect(inventory["codex"]?.canAutomaticallyUpdate == true)
        #expect(inventory["codex"]?.needsUpdateCheck == true)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        _ = try await python(AgentIntegrationManager.cliScript(update: .codex), environment: environment)
        #expect(try String(contentsOf: log, encoding: .utf8) == "native update")
    }
    @Test(arguments: [SupportedAgent.codex, .claude, .omp, .qoder, .opencode, .pi, .reasonix,
                      .antigravity, .cursor, .amp, .copilot, .droid, .kimi, .hermes, .grok, .cline, .qwen])
    func nativeUpdatePolicyNeverProbesHelp(agent: SupportedAgent) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("calls.jsonl")
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
with pathlib.Path(os.environ["UPDATE_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["--version"]: print("1.0.0")
elif "--help" in sys.argv: sys.exit(2)
elif os.environ.get("FAIL_UPDATE"):
    print("native update failed", file=sys.stderr)
    sys.exit(1)
"""#, at: home.appendingPathComponent(agent.definition.command))
        var environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin", "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory[agent.rawValue]?.updater == "native")
        #expect(inventory[agent.rawValue]?.canAutomaticallyUpdate == true)
        #expect(inventory[agent.rawValue]?.needsUpdateCheck == true)
        #expect(try String(contentsOf: log, encoding: .utf8) == "[\"--version\"]\n")
        try FileManager.default.removeItem(at: log)
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
        let expected: [String] = switch agent {
        case .pi: ["update", "--all"]
        case .opencode, .reasonix: ["upgrade"]
        case .kimi: ["upgrade", "--yes"]
        case .hermes: ["update", "--yes", "--no-gateway-restart"]
        default: ["update"]
        }
        #expect(calls == [["--version"], expected])
        environment["FAIL_UPDATE"] = "1"
        await #expect(throws: (any Error).self) {
            _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        }
    }

    @Test func npmInstalledPiStillUsesNativeUpdateAll() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("node_modules")
        let package = root.appendingPathComponent("pi-test")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"name":"pi-test","version":"1.0.0","bin":{"pi":"cli"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
pathlib.Path(os.environ["UPDATE_LOG"]).write_text(json.dumps(sys.argv[1:]))
"""#, at: package.appendingPathComponent("cli"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("pi"), withDestinationURL: package.appendingPathComponent("cli")
        )
        // Any npm operation except inventory is a test failure.
        try executable("#!/bin/sh\n[ \"$1\" = root ] || exit 2\nprintf '%s\\n' \"$OMG_TEST_ROOT\"\n",
                       at: home.appendingPathComponent("npm"))
        let log = home.appendingPathComponent("updates.json")
        let environment = ["HOME": home.path, "PATH": home.path + ":/usr/bin:/bin",
                           "OMG_TEST_ROOT": root.path, "UPDATE_LOG": log.path]
        let data = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let inventory = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: data)
        #expect(inventory["pi"]?.package == "pi-test")
        #expect(inventory["pi"]?.updater == "native")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        _ = try await python(AgentIntegrationManager.cliScript(update: .pi), environment: environment)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: log))
        #expect(arguments == ["update", "--all"])
    }

    @Test func offlineSSHIsNotScheduledAndDoesNotAdvanceItsDeadline() async throws {
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var connected: Set<String> = []
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { connected })
        var policy = AgentIntegrationPolicy()
        policy.updateHooksAutomatically = true
        policy.automaticallyUpdatedAgents = [.codex]
        manager.setPolicy(policy, for: "ssh:cloud")
        var localPolicy = manager.policy(for: "local")
        localPolicy.checkAutomatically = false
        manager.setPolicy(localPolicy, for: "local")
        manager.checkDueTargets()
        await manager.refresh(target: "ssh:cloud", automatic: true)
        #expect(manager.policy(for: "ssh:cloud").lastAttempt == nil)
        #expect(manager.snapshots["ssh:cloud"] == nil)
        #expect(manager.busy.isEmpty)
        #expect(manager.allowsAutomaticWork("local"))
        connected = ["ssh:vps-jump"]
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        connected.insert("ssh:cloud")
        // A ready connection alone is no longer sufficient: it must be registered.
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        connected.remove("ssh:cloud")
        #expect(!manager.allowsAutomaticWork("ssh:cloud"))
        #expect(manager.policy(for: "ssh:cloud").isDue(at: Date()))
    }
    @Test func updatePoliciesAreIsolatedPersistedAndRespectIntervals() throws {
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AgentIntegrationManager(defaults: defaults)
        #expect(manager.policy(for: "local").checkAutomatically)
        #expect(!manager.policy(for: "ssh:cloud").checkAutomatically)
        let now = Date(timeIntervalSince1970: 100_000)
        var policy = AgentIntegrationPolicy()
        policy.updateHooksAutomatically = true
        policy.automaticallyUpdatedAgents.insert(.codex)
        policy.lastAttempt = now
        manager.setPolicy(policy, for: "ssh:cloud")
        // Automatic adoption is the default, per-target opt-outs stay independent.
        #expect(manager.policy(for: "local").updateHooksAutomatically)
        #expect(manager.policy(for: "ssh:other").updateHooksAutomatically)
        #expect(manager.policy(for: "ssh:cloud").automaticallyUpdatedAgents == [.codex])
        #expect(manager.policy(for: "local").automaticallyUpdatedAgents.isEmpty)
        #expect(!policy.isDue(at: now.addingTimeInterval(86_399)))
        #expect(policy.isDue(at: now.addingTimeInterval(86_400)))
        policy.checkAutomatically = false
        #expect(!policy.isDue(at: now.addingTimeInterval(1_000_000)))
        let reopened = AgentIntegrationManager(defaults: defaults)
        #expect(reopened.policy(for: "ssh:cloud").updateHooksAutomatically)
        #expect(reopened.policy(for: "ssh:cloud").lastAttempt == now)
    }

    @Test func settingsFrameFitsInvokingDisplayIncludingNegativeCoordinates() {
        let original = NSRect(x: 300, y: 200, width: 820, height: 560)
        let leftDisplay = NSRect(x: -1_920, y: 25, width: 1_920, height: 1_055)
        let moved = OhMyGhosttySettingsWindowController.frame(original, on: leftDisplay)
        #expect(leftDisplay.contains(moved))
        #expect(moved.midX == leftDisplay.midX)
        #expect(moved.size == original.size)
        let smallDisplay = NSRect(x: 0, y: 0, width: 640, height: 400)
        #expect(OhMyGhosttySettingsWindowController.frame(original, on: smallDisplay) == smallDisplay)
    }

    @Test func automaticHookMaintenanceRepairsStaleHooksButNeverReinstallsRemovedOnes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        let hooks = home.appendingPathComponent(".codex/hooks.json")
        let stale = try String(contentsOf: hooks, encoding: .utf8)
            .replacingOccurrences(of: "_omg_agent_status_v\(AgentHookInstaller.hookVersion)", with: "_omg_agent_status_v0")
        try stale.write(to: hooks, atomically: true, encoding: .utf8)
        let manager = AgentIntegrationManager(defaults: defaults, homeURL: home)
        await manager.refresh(target: "local", automatic: true)
        // Automatic Hook maintenance is on by default: the stale adapter is repaired
        // on the very first automatic check.
        #expect(installer.installationState(.codex) == .current)
        #expect(installer.installationState(.claude) == .missing)
        #expect(manager.snapshots["local"]?.error == nil)
        #expect(manager.policy(for: "local").lastSuccess != nil)
        // A removed Hook is not resurrected by later maintenance.
        try installer.uninstall(.codex)
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .updateAvailable
            || installer.installationState(.codex) == .missing)
    }

    @Test func updatesNeverDowngradeOrMovePrereleaseChannels() {
        #expect(AgentCLIInstallation(version: "1.9.0", latest: "1.10.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "2.0.0", latest: "1.10.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "2.0.0-beta.1", latest: "2.0.0", package: "example").updateAvailable)
        #expect(!AgentCLIInstallation(version: "1.0.0", latest: "2.0.0").updateAvailable)
    }

    @Test func remoteHooksTargetOnlySelectedAgentAndPreserveOtherHooks() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let thirdParty = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo third-party"}]}]}}"#
        try thirdParty.write(to: claude, atomically: true, encoding: .utf8)
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.codex, .claude]), environment: environment)
        let codex = home.appendingPathComponent(".codex/hooks.json")
        let codexBefore = try Data(contentsOf: codex)
        let installed = try await hookStates(home: home)
        #expect(installed["codex"] == "current")
        #expect(installed["claude"] == "current")
        #expect(installed["pi"] == "missing")
        let stale = try #require(String(bytes: codexBefore, encoding: .utf8))
            .replacingOccurrences(of: "_omg_agent_status_v\(AgentHookInstaller.hookVersion)", with: "_omg_agent_status_v0")
        try stale.write(to: codex, atomically: true, encoding: .utf8)
        #expect(try await hookStates(home: home)["codex"] == "updateAvailable")
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove, agents: [.claude]), environment: environment)
        #expect(try await hookStates(home: home)["claude"] == "missing")
        #expect(try String(contentsOf: claude, encoding: .utf8).contains("echo third-party"))
        #expect(try String(contentsOf: codex, encoding: .utf8) == stale)
    }

    @Test func remoteHermesYAMLInstallPreservesUserConfigOverSSH() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = "model: claude-sonnet-4\ntelemetry: false\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]

        // Hermes is exported to SSH, so a remote install must work without OMG
        // logging in to the remote account.
        _ = try await python(
            AgentHookInstaller.remoteInstallerScript(agents: [.hermes]),
            environment: environment
        )
        #expect(try await hookStates(home: home)["hermes"] == "current")
        let installed = try String(contentsOf: config, encoding: .utf8)
        #expect(installed.contains("model: claude-sonnet-4"))
        #expect(installed.contains("telemetry: false"))
        #expect(installed.contains("hooks_auto_accept: true"))
        #expect(installed.contains("on_session_start:"))
        #expect(installed.contains("pre_llm_call:"))
        #expect(installed.contains("post_llm_call:"))
        #expect(installed.contains("on_session_finalize:"))
        // Hermes hooks may run from a headless daemon, so the remote installer also
        // ships the helper script the YAML delegates to.
        #expect(installed.contains("hermes-hook.sh"))
        let script = home.appendingPathComponent(
            ".config/oh-my-ghostty/agent-status/hermes-hook.sh"
        )
        #expect(FileManager.default.fileExists(atPath: script.path))
        let scriptText = try String(contentsOf: script, encoding: .utf8)
        #expect(scriptText.contains("_omg_agent_status"))
        // The helper records the state instead of writing OSC: Hermes may run the
        // hook from a daemon with no controlling terminal.
        #expect(!scriptText.contains("> \"/dev/$omg_tty\""))
        #expect(scriptText.contains("hashlib.sha256"))

        _ = try await python(
            AgentHookInstaller.remoteInstallerScript(action: .remove, agents: [.hermes]),
            environment: environment
        )
        #expect(try await hookStates(home: home)["hermes"] == "missing")
        let removed = try String(contentsOf: config, encoding: .utf8)
        #expect(!removed.contains("# >>> OMG agent-status hooks"))
        #expect(removed.contains("model: claude-sonnet-4"))
        #expect(removed.contains("telemetry: false"))
    }

    @Test func remoteStatusAndRemovalCoverEveryExportedHookDialect() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        _ = try await python(AgentHookInstaller.remoteInstallerScript(), environment: environment)
        let installed = try await hookStates(home: home)
        let agents = SupportedAgent.allCases.filter { $0.definition.hook.kind != .none }
        for agent in agents { #expect(installed[agent.rawValue] == "current") }
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove), environment: environment)
        let removed = try await hookStates(home: home)
        for agent in agents { #expect(removed[agent.rawValue] == "missing") }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/oh-my-ghostty/agent-detectors").path))
    }

    @Test(arguments: [SupportedAgent.crush, .qwen, .droid, .grok, .reasonix])
    func npmUpdateUsesVerifiedExecutableAndExactNewerVersion(agent: SupportedAgent) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        let root = home.appendingPathComponent("node_modules")
        let package = root.appendingPathComponent("@example/qwen")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"name":"@example/qwen","version":"1.0.0","bin":{"\#(agent.definition.command)":"cli"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try executable("#!/bin/sh\necho 1.0.0\n", at: package.appendingPathComponent("cli"))
        let command = bin.appendingPathComponent(agent.definition.command)
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: package.appendingPathComponent("cli"))
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
if sys.argv[1] == "root": print(os.environ["OMG_TEST_ROOT"])
elif sys.argv[1] == "outdated":
    print(json.dumps({"@example/qwen": {"latest": os.environ["OMG_TEST_LATEST"]}}))
    sys.exit(1)
elif sys.argv[1] == "install":
    pathlib.Path(os.environ["OMG_TEST_LOG"]).write_text(json.dumps(sys.argv[1:]))
else: sys.exit(2)
"""#, at: bin.appendingPathComponent("npm"))
        let log = home.appendingPathComponent("installed.json")
        var environment = [
            "HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin",
            "OMG_TEST_ROOT": root.path, "OMG_TEST_LATEST": "1.2.0", "OMG_TEST_LOG": log.path,
        ]
        let output = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let values = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: output)
        #expect(values[agent.rawValue]?.updateAvailable == true)
        #expect(values[agent.rawValue]?.updater == nil)
        var installedOnlyEnvironment = environment
        installedOnlyEnvironment.removeValue(forKey: "OMG_TEST_LATEST")
        let inventory = try await python(AgentIntegrationManager.cliScript(checkLatest: false), environment: installedOnlyEnvironment)
        let installedOnly = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: inventory)
        #expect(installedOnly[agent.rawValue]?.version == "1.0.0")
        #expect(installedOnly[agent.rawValue]?.latest == nil)
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("@example/qwen@1.2.0"))
        try FileManager.default.removeItem(at: log)
        environment["OMG_TEST_LATEST"] = "0.9.0"
        _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        try FileManager.default.removeItem(at: command)
        try executable("#!/bin/sh\necho 9.0.0\n", at: command)
        let unmanaged = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let unmanagedValues = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: unmanaged)
        #expect(unmanagedValues[agent.rawValue]?.package == nil)
        if agent == .crush {
            await #expect(throws: (any Error).self) {
                _ = try await python(AgentIntegrationManager.cliScript(update: agent), environment: environment)
            }
        } else {
            #expect(unmanagedValues[agent.rawValue]?.updater == "native")
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test func antigravityHooksPreserveNamedConfigAndEmitOnlyJSONOnStdout() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent(".gemini/config/hooks.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = #"{"third-party":{"Stop":[{"command":"echo preserved"}]}}"#
        try unrelated.write(to: url, atomically: true, encoding: .utf8)
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.antigravity)
        #expect(installer.installationState(.antigravity) == .current)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["third-party"] != nil)
        let hooks = try #require(root["omg-agent-status"] as? [String: Any])
        let pre = try #require((hooks["PreInvocation"] as? [[String: Any]])?.first?["command"] as? String)
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["command"] as? String)
        let data = try JSONEncoder().encode(["pre": pre, "stop": stop])
        let driver = #"""
import base64, fcntl, json, os, pty, subprocess, termios
commands = json.loads(base64.b64decode("\#(data.base64EncodedString())"))
def execute(command, payload, remote=False, terminal=True):
    environment = dict(os.environ)
    environment.pop("SSH_CONNECTION", None)
    if remote: environment["SSH_CONNECTION"] = "test"
    master, slave = pty.openpty()
    def setup():
        os.setsid()
        if terminal: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    process = subprocess.Popen(["/bin/sh", "-c", command], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        preexec_fn=setup, pass_fds=(slave,))
    process.stdin.write(json.dumps(payload).encode())
    process.stdin.close()
    stdout = process.stdout.read()
    stderr = process.stderr.read()
    response = json.loads(stdout)
    os.set_blocking(master, False)
    try: sequence = os.read(master, 65536).decode()
    except BlockingIOError: sequence = ""
    # macOS can defer the session leader's reap until the PTY is closed.
    os.close(master); os.close(slave)
    assert process.wait(timeout=10) == 0, stderr
    return response, sequence
for remote in (False, True):
    response, sequence = execute(commands["pre"], {"conversationId": "test-123"}, remote)
    assert response == {}
    assert "omg_state=working" in sequence
    assert "omg_scope=" + ("remote" if remote else "local") in sequence
    assert "omg_conversation=test-123" in sequence
    response, sequence = execute(commands["stop"], {"conversationId": "test-123", "fullyIdle": True}, remote)
    assert response == {"decision": "allow"}
    assert "omg_state=done" in sequence
    _, sequence = execute(commands["stop"], {"fullyIdle": False}, remote)
    assert "omg_state=working" in sequence
    _, sequence = execute(commands["stop"], {"terminationReason": "error"}, remote)
    assert "omg_state=error" in sequence
    _, sequence = execute(commands["stop"], {"terminationReason": "ERROR"}, remote)
    assert "omg_state=error" in sequence
    _, sequence = execute(commands["stop"], {"terminationReason": "TERMINAL_STEP_TYPE", "fullyIdle": True}, remote)
    assert "omg_state=needsAttention" in sequence and "omg_attention=question" in sequence
    _, sequence = execute(commands["stop"], {"terminationReason": "USER_CANCELED", "fullyIdle": True}, remote)
    assert "omg_state=idle" in sequence
response, sequence = execute(commands["pre"], {}, terminal=False)
assert response == {} and not sequence
print("PTY local/SSH and headless protocol checks passed")
"""#
        _ = try await python(driver, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let remoteStatus = try await hookStates(home: home)
        #expect(remoteStatus["antigravity"] == "current")
        _ = try await python(AgentHookInstaller.remoteInstallerScript(action: .remove, agents: [.antigravity]), environment: environment)
        #expect(installer.installationState(.antigravity) == .missing)
        _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.antigravity]), environment: environment)
        #expect(installer.installationState(.antigravity) == .current)
        try installer.uninstall(.antigravity)
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(remaining.count == 1 && remaining["third-party"] != nil)
        try #"{"omg-agent-status":{"Stop":[{"command":"echo user-owned"}]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try installer.install(.antigravity) }
        await #expect(throws: (any Error).self) {
            _ = try await python(AgentHookInstaller.remoteInstallerScript(agents: [.antigravity]), environment: environment)
        }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("user-owned"))
    }

    private func hookStates(home: URL) async throws -> [String: String] {
        let data = try await python(AgentHookInstaller.remoteInstallerScript(action: .status),
                                    environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func python(_ script: String, environment: [String: String]) async throws -> Data {
        let result = try await GitProcessRunner().run(
            executablePath: "/usr/bin/python3", arguments: ["-"], workingDirectory: "/tmp",
            environment: environment, stdin: Data(script.utf8), timeout: 30
        )
        guard result.isSuccess else {
            throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
        }
        return result.stdout
    }
}
