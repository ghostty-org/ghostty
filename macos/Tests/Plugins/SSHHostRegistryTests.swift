import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHHostRegistryTests {
    actor Probe {
        var calls = 0
        var fail = false
        func setFailure() { fail = true }
        func read(_ connection: GitSSHConnection) throws -> AgentIntegrationSnapshot {
            calls += 1
            if fail { throw AgentHistoryRemoteError.unavailable }
            return .init(hooks: [.codex: .current], cli: [.codex: .init(version: "1.\(calls).0", path: "/bin/codex")])
        }
    }

    @Test func registrationPersistsExactConnectionsAndSwitchingOnlyReadsCache() async throws {
        let suite = "SSHRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let first = try GitSSHConnection(destination: "user@cloud", options: ["-p", "2222", "-J", "jump"], workspaceID: "ssh:cloud")
        let second = try GitSSHConnection(destination: "user@cloud", options: ["-p", "2223", "-J", "jump"], workspaceID: "ssh:cloud")
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { try await probe.read($0) })
        await registry.register(first)
        await registry.register(second)
        #expect(registry.hosts.count == 2)
        #expect(RegisteredSSHHost.id(for: first) != RegisteredSSHHost.id(for: second))
        let restored = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { try await probe.read($0) })
        let manager = AgentIntegrationManager(defaults: defaults, registry: restored)
        for record in restored.hosts {
            manager.loadCached(target: record.id)
            #expect(manager.snapshots[record.id]?.cli[.codex]?.version == record.snapshot.cli[.codex]?.version)
        }
        #expect(await probe.calls == 2)
        #expect(restored.host(RegisteredSSHHost.id(for: first))?.connection.options == first.options)
        await probe.setFailure()
        let before = restored.host(RegisteredSSHHost.id(for: first))?.capturedAt
        await restored.register(first)
        #expect(restored.host(RegisteredSSHHost.id(for: first))?.capturedAt == before)
        #expect(restored.errors[RegisteredSSHHost.id(for: first)] != nil)
    }

    @Test func automaticRegistrationRequiresLiveConnectionAndRespectsUnregister() async throws {
        let suite = "SSHRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = try GitSSHConnection(destination: "cloud")
        var live: [GitSSHConnection] = []
        let probe = Probe()
        let registry = SSHHostRegistry(defaults: defaults, live: { live }, inventory: { try await probe.read($0) })
        registry.automaticallyRegister = true
        #expect(await probe.calls == 0)
        live = [connection, connection]
        registry.reconcile()
        for _ in 0..<100 where registry.hosts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(registry.hosts.count == 1)
        registry.reconcile()
        #expect(await probe.calls == 1)
        let id = RegisteredSSHHost.id(for: connection)
        let manager = AgentIntegrationManager(defaults: defaults, connectionTargets: { Set(live.map { RegisteredSSHHost.id(for: $0) }) }, registry: registry)
        #expect(manager.allowsAutomaticWork(id))
        manager.forget(id)
        registry.reconcile()
        #expect(registry.hosts.isEmpty)
        #expect(!manager.allowsAutomaticWork(id))
        #expect(await probe.calls == 1)
        live = []
        registry.reconcile()
        live = [connection]
        registry.reconcile()
        #expect(registry.hosts.isEmpty)
        await registry.register(connection)
        #expect(registry.hosts.count == 1)
    }

    @Test func disconnectedRegistrationCannotPublishLateInventory() async throws {
        let suite = "SSHRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = try GitSSHConnection(destination: "cloud")
        var live = [connection]
        let registry = SSHHostRegistry(defaults: defaults, live: { live }, inventory: { _ in
            try await Task.sleep(for: .milliseconds(80))
            return .init(hooks: [.codex: .current])
        })
        registry.automaticallyRegister = true
        try await Task.sleep(for: .milliseconds(20))
        live = []
        registry.reconcile()
        try await Task.sleep(for: .milliseconds(100))
        #expect(registry.hosts.isEmpty)
        #expect(registry.pending.isEmpty)
    }

    @Test func sharedTransportRunsGitFilesAndInventoryOnSameExactSSHConnection() async throws {
        let server = try await GitSSHTestServer()
        defer { server.disconnect() }
        let file = server.root.appendingPathComponent("shared 中文.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let git = try await SSHGitExecutor(connection: server.connection).execute(arguments: ["--version"], workingDirectory: "/")
        #expect(git.isSuccess)
        let listing = try await SSHSessionTransport.sftp(batch: "ls -la \"\(file.path)\"", connection: server.connection)
        #expect(listing.contains("shared 中文.txt"))
        let downloaded = server.root.appendingPathComponent("download.txt")
        _ = try await SSHSessionTransport.sftp(batch: "get \"\(file.path)\" \"\(downloaded.path)\"", connection: server.connection)
        #expect(try Data(contentsOf: downloaded) == Data("hello".utf8))
        try FileManager.default.createDirectory(at: server.root.appendingPathComponent("parent/child"), withIntermediateDirectories: true)
        let filesystem = SSHWorkspaceFilesystem(host: .init(alias: "not-a-real-host", hostname: "invalid", user: nil, port: nil, proxyJump: nil),
            workingDirectory: server.root.path, connection: server.connection)
        let rawTree = try await SSHSFTPClient.runCommand("python3 -c " + SSHWorkspaceFilesystem.shellQuote(SSHWorkspaceFilesystem.compactTreeScript)
            + " " + SSHWorkspaceFilesystem.shellQuote(server.root.path), host: "not-a-real-host", connection: server.connection)
        #expect(rawTree.contains("parent/child"))
        let tree = try await filesystem.listTreeDirectory(at: server.root.path)
        #expect(tree.contains { $0.name == "parent/child" })
        let data = try await SSHSessionTransport.python("import json\nprint(json.dumps({'version': 'fixture'}))", connection: server.connection)
        #expect(try JSONDecoder().decode([String: String].self, from: data)["version"] == "fixture")
        await SSHSessionTransport.close(server.connection)
    }
}
