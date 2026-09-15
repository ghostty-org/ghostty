import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationManagerTests {
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
        #expect(manager.allowsAutomaticWork("ssh:cloud"))
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
        #expect(!manager.policy(for: "local").updateHooksAutomatically)
        #expect(!manager.policy(for: "ssh:other").updateHooksAutomatically)
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
        #expect(installer.installationState(.codex) == .updateAvailable)
        var policy = manager.policy(for: "local")
        policy.updateHooksAutomatically = true
        manager.setPolicy(policy, for: "local")
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .current)
        #expect(installer.installationState(.claude) == .missing)
        #expect(manager.snapshots["local"]?.error == nil)
        #expect(manager.policy(for: "local").lastSuccess != nil)
        try installer.uninstall(.codex)
        await manager.refresh(target: "local", automatic: true)
        #expect(installer.installationState(.codex) == .missing)
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

    @Test func npmUpdateUsesVerifiedExecutableAndExactNewerVersion() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        let root = home.appendingPathComponent("node_modules")
        let package = root.appendingPathComponent("@example/codex")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"name":"@example/codex","version":"1.0.0","bin":{"codex":"cli"}}"#
            .write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try executable("#!/bin/sh\necho 1.0.0\n", at: package.appendingPathComponent("cli"))
        let command = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: package.appendingPathComponent("cli"))
        try executable(#"""
#!/usr/bin/python3
import json, os, pathlib, sys
if sys.argv[1] == "root": print(os.environ["OMG_TEST_ROOT"])
elif sys.argv[1] == "outdated":
    print(json.dumps({"@example/codex": {"latest": os.environ["OMG_TEST_LATEST"]}}))
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
        #expect(values["codex"]?.updateAvailable == true)
        _ = try await python(AgentIntegrationManager.cliScript(update: .codex), environment: environment)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("@example/codex@1.2.0"))
        try FileManager.default.removeItem(at: log)
        environment["OMG_TEST_LATEST"] = "0.9.0"
        _ = try await python(AgentIntegrationManager.cliScript(update: .codex), environment: environment)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        try FileManager.default.removeItem(at: command)
        try executable("#!/bin/sh\necho 9.0.0\n", at: command)
        let unmanaged = try await python(AgentIntegrationManager.cliScript(), environment: environment)
        let unmanagedValues = try JSONDecoder().decode([String: AgentCLIInstallation].self, from: unmanaged)
        #expect(unmanagedValues["codex"]?.package == nil)
        await #expect(throws: (any Error).self) {
            _ = try await python(AgentIntegrationManager.cliScript(update: .codex), environment: environment)
        }
        #expect(!FileManager.default.fileExists(atPath: log.path))
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
