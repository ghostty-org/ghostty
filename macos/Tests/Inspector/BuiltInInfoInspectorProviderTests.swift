import Foundation
import Testing
@testable import Ghostty

@MainActor
struct BuiltInInfoInspectorProviderTests {
    @Test func infoSurvivesSSHPluginDisconnection() throws {
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(registry: registry,
            persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try provider.setEnabled(true)
        defer { provider.shutdown() }
        registry.disconnectPlugin("builtin.ssh")
        #expect(registry.descriptor(id: BuiltInInfoInspectorProvider.paneID)?.source == .coreFeature("builtin.info"))
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "Local", workingDirectory: "/tmp")
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        guard case .info = registry.content(for: BuiltInInfoInspectorProvider.paneID, context: context) else {
            Issue.record("Local Info must be available without an installed plugin"); return
        }
    }

    @Test func forwardsOncePerAliasAndRestoresPersistedIntent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-test-\(UUID().uuidString)")
        let persistenceURL = root.appendingPathComponent("port-forwards.json")
        defer { try? FileManager.default.removeItem(at: root) }

        struct Launch: Equatable {
            let alias: String
            let host: String
            let remote: Int
            let local: Int
        }
        var launches: [Launch] = []
        var stopped: [Int] = []
        var openedURLs: [URL] = []
        var copiedAddresses: [String] = []
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: persistenceURL,
            processLauncher: { alias, host, remote, local, _ in
                launches.append(.init(
                    alias: alias,
                    host: host,
                    remote: remote,
                    local: local
                ))
                return { stopped.append(local) }
            },
            localPortAllocator: { _ in 41_000 },
            forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, ports in Dictionary(uniqueKeysWithValues: ports.map { ($0, "node") }) },
            openURL: { openedURLs.append($0) },
            copyAddress: { copiedAddresses.append($0) }
        )
        try provider.setEnabled(true)

        let serverID = "hostkey-SHA256:testserver="
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-1"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.presentationDidChange(
            to: BuiltInInfoInspectorProvider.paneID,
            context: context
        )
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "8080")
            )
        )

        #expect(launches.count == 1)
        #expect(launches.first?.alias == "cloud")
        #expect(launches.first?.host == PortForwardTarget.loopbackHost)
        #expect(launches.first?.remote == 8_080)
        #expect(launches.first?.local == 41_000)
        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))

        try await Task.sleep(for: .milliseconds(350))
        let list = provider.content(for: serverID, alias: "cloud")
        #expect(list.items == [
            .init(
                id: "\(serverID)|127.0.0.1|8080",
                remoteHost: PortForwardTarget.loopbackHost,
                remotePort: 8_080,
                localPort: 41_000,
                processName: "node",
                status: .active
            ),
        ])
        guard case .info(let info) = registry.content(
            for: BuiltInInfoInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected typed Info content")
            return
        }
        #expect(info.status == nil)
        #expect(info.fields.isEmpty)
        #expect(info.portForwards == list)

        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .openPortForward(id: "\(serverID)|127.0.0.1|8080")
            )
        )
        #expect(openedURLs.map(\.absoluteString) == ["http://127.0.0.1:41000"])
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .copyPortForward(id: "\(serverID)|127.0.0.1|8080")
            )
        )
        #expect(copiedAddresses == ["localhost:41000"])

        // A second alias or direct-IP connection with the same authenticated
        // server identity shares the forward and keeps it alive.
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "10.0.0.12"]
        ))
        #expect(stopped.isEmpty)
        provider.synchronizeConnections(.init())
        #expect(stopped == [41_000])

        provider.shutdown()
        try provider.setEnabled(false)

        struct RestoredLaunch: Equatable {
            let alias: String
            let host: String
            let remote: Int
            let local: Int
        }
        var restoredLaunches: [RestoredLaunch] = []
        let restoredRegistry = InspectorRegistry()
        let restored = BuiltInInfoInspectorProvider(
            registry: restoredRegistry,
            persistenceURL: persistenceURL,
            processLauncher: { alias, host, remote, local, _ in
                restoredLaunches.append(.init(
                    alias: alias,
                    host: host,
                    remote: remote,
                    local: local
                ))
                return {}
            },
            localPortAllocator: { _ in 42_000 },
            forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in [:] },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try restored.setEnabled(true)
        restored.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "10.0.0.12"]
        ))
        #expect(restoredLaunches.count == 1)
        #expect(restoredLaunches.first?.alias == "10.0.0.12")
        #expect(restoredLaunches.first?.host == PortForwardTarget.loopbackHost)
        #expect(restoredLaunches.first?.remote == 8_080)
        #expect(restoredLaunches.first?.local == 42_000)
        restored.shutdown()
    }

    @Test func processProbesFollowInfoVisibilityWithoutStoppingTunnels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = InspectorRegistry()
        var probes = 0
        var stops = 0
        let provider = BuiltInInfoInspectorProvider(
            registry: registry, persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in { stops += 1 } },
            localPortAllocator: { _ in 41_000 }, forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in
                probes += 1
                guard probes == 1 else { throw BuiltInInfoInspectorProvider.ProcessProbeError.unavailable }
                return [8080: "node"]
            },
            processRefreshInterval: .milliseconds(30)
        )
        try provider.setEnabled(true)
        defer { provider.shutdown() }
        let serverID = "hostkey-SHA256:visibility="
        let context = sshContext(alias: "cloud", serverID: serverID, connectionID: "omg-ssh-1")
        provider.synchronizeConnections(.init(connected: [serverID], readyAliases: [serverID: "cloud"]))
        registry.performAction(paneID: BuiltInInfoInspectorProvider.paneID,
                               action: .init(context: context, kind: .createPortForward(target: "8080")))
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes == 0)
        #expect(provider.content(for: serverID, alias: "cloud").items.first?.status == .active)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes > 1)
        #expect(provider.content(for: serverID, alias: "cloud").items.first?.processName == "node")
        registry.presentationDidChange(to: nil, context: context)
        let hiddenCount = probes
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes == hiddenCount)
        #expect(stops == 0)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probes > hiddenCount)
        provider.synchronizeConnections(.init())
        let disconnectedCount = probes
        try await Task.sleep(for: .milliseconds(100))
        #expect(probes == disconnectedCount)
        #expect(stops == 1)
    }

    @Test func plainSSHPaneCreatesForwardsWithoutRegistryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = InspectorRegistry()
        var launches: [(alias: String, remote: Int)] = []
        var stops = 0
        let provider = BuiltInInfoInspectorProvider(
            registry: registry, persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { alias, _, remote, _, _ in
                launches.append((alias, remote))
                return { stops += 1 }
            },
            localPortAllocator: { _ in 41_000 }, forwardReadiness: { _ in true }
        )
        try provider.setEnabled(true)
        defer { provider.shutdown() }

        let context = plainSSHContext(alias: "cloud", connectionID: "omg-ssh-foreground-42")
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        guard case .info(let info) = registry.content(
            for: BuiltInInfoInspectorProvider.paneID, context: context
        ) else {
            Issue.record("Expected typed Info content")
            return
        }
        #expect(info.portForwards.canCreate)

        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(context: context, kind: .createPortForward(target: "8080"))
        )
        #expect(launches.count == 1)
        #expect(launches.first?.alias == "cloud")
        #expect(launches.first?.remote == 8_080)

        // Registry synchronization does not own plain panes; the live pane does.
        provider.synchronizeConnections(.init())
        #expect(stops == 0)
        #expect(provider.content(for: "ssh-destination:cloud", alias: "cloud").items.count == 1)
    }

    @Test func batchesPortsAndSharesDemandAcrossInfoPresentations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = InspectorRegistry()
        var batches: [[Int]] = []
        var cancellations = 0
        let provider = BuiltInInfoInspectorProvider(
            registry: registry, persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in {} },
            localPortAllocator: { $0 }, forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { alias, ports in
                #expect(alias == "cloud")
                batches.append(ports)
                if batches.count > 1 {
                    do { try await Task.sleep(for: .seconds(60)) } catch { cancellations += 1; throw error }
                }
                return Dictionary(uniqueKeysWithValues: ports.map { ($0, "node") })
            },
            processRefreshInterval: .milliseconds(30)
        )
        try provider.setEnabled(true)
        defer { provider.shutdown() }
        let serverID = "hostkey-SHA256:batch="
        let first = sshContext(alias: "cloud", serverID: serverID, connectionID: "omg-ssh-1")
        let second = sshContext(alias: "cloud", serverID: serverID, connectionID: "omg-ssh-2")
        provider.synchronizeConnections(.init(connected: [serverID], readyAliases: [serverID: "cloud"]))
        let ports = [5175, 5176, 5178, 5180, 5181, 5186, 10100, 15244]
        for port in ports {
            registry.performAction(paneID: BuiltInInfoInspectorProvider.paneID,
                                   action: .init(context: first, kind: .createPortForward(target: String(port))))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(batches.isEmpty)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: first)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: second)
        try await Task.sleep(for: .milliseconds(100))
        #expect(batches == [ports, ports])
        #expect(provider.content(for: serverID, alias: "cloud").items.allSatisfy { $0.processName == "node" })
        registry.presentationDidChange(to: nil, context: first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancellations == 0)
        #expect(batches.count == 2)
        registry.presentationDidChange(to: nil, context: second)
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancellations == 1)
        #expect(batches.count == 2)
    }

    @Test func cancelledBatchCannotPublishIntoReopenedInfo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = InspectorRegistry()
        var reply: CheckedContinuation<[Int: String], Never>?
        var calls = 0
        let provider = BuiltInInfoInspectorProvider(
            registry: registry, persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in {} },
            localPortAllocator: { $0 }, forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in
                calls += 1
                if calls == 1 { return await withCheckedContinuation { reply = $0 } }
                return [:]
            }
        )
        try provider.setEnabled(true)
        defer { provider.shutdown() }
        let serverID = "hostkey-SHA256:late="
        let context = sshContext(alias: "cloud", serverID: serverID, connectionID: "omg-ssh-1")
        provider.synchronizeConnections(.init(connected: [serverID], readyAliases: [serverID: "cloud"]))
        registry.performAction(paneID: BuiltInInfoInspectorProvider.paneID,
                               action: .init(context: context, kind: .createPortForward(target: "8080")))
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        for _ in 0..<100 where reply == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pending = try #require(reply)
        registry.presentationDidChange(to: nil, context: context)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        #expect(calls == 1) // replacement waits for the old resolver to settle
        pending.resume(returning: [8080: "stale"])
        for _ in 0..<100 where calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 2)
        #expect(provider.content(for: serverID, alias: "cloud").items.first?.processName == nil)
    }

    @Test func batchFailuresBackOffAndPreserveCachedNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = InspectorRegistry()
        var calls: [ContinuousClock.Instant] = []
        let provider = BuiltInInfoInspectorProvider(
            registry: registry, persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in {} },
            localPortAllocator: { $0 }, forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in
                calls.append(.now)
                if calls.count == 1 { return [8080: "node"] }
                if calls.count < 4 { throw BuiltInInfoInspectorProvider.ProcessProbeError.unavailable }
                return [:] // successful probe confirms no listener; clear the old name
            },
            processRefreshInterval: .milliseconds(30)
        )
        try provider.setEnabled(true)
        defer { provider.shutdown() }
        let serverID = "hostkey-SHA256:backoff="
        let context = sshContext(alias: "cloud", serverID: serverID, connectionID: "omg-ssh-1")
        provider.synchronizeConnections(.init(connected: [serverID], readyAliases: [serverID: "cloud"]))
        registry.performAction(paneID: BuiltInInfoInspectorProvider.paneID,
                               action: .init(context: context, kind: .createPortForward(target: "8080")))
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        for _ in 0..<100 where calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(provider.content(for: serverID, alias: "cloud").items.first?.processName == "node")
        for _ in 0..<200 where calls.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        registry.presentationDidChange(to: nil, context: context)
        try #require(calls.count >= 4)
        #expect(calls[2] - calls[1] >= .milliseconds(60))
        #expect(calls[3] - calls[2] >= .milliseconds(120))
        #expect(provider.content(for: serverID, alias: "cloud").items.first?.processName == nil)
    }

    @Test func batchShellScansListenersOnceAndHandlesMissingPorts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = [
            "lsof": "#!/bin/sh\nprintf 'scan\\n' >> \"$PROBE_SCAN_LOG\"\nprintf 'p123\\ncnode\\nn127.0.0.1:8080\\nn[::1]:8081\\np124\\ncpython\\nn*:9000\\n'\n",
            "ps": "#!/bin/sh\nprintf '/usr/bin/node server.js\\n'\n"
        ]
        for (name, script) in scripts {
            let file = root.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):/usr/bin:/bin"
        let log = root.appendingPathComponent("scans")
        environment["PROBE_SCAN_LOG"] = log.path
        let ports = [8080, 8081, 8082]
        let result = try await GitProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", BuiltInInfoInspectorProvider.remoteProcessCommand(ports: ports)],
            workingDirectory: root.path, environment: environment, maxOutputBytes: 64 * 1024, timeout: 6
        )
        #expect(result.exitCode == 0)
        #expect(try BuiltInInfoInspectorProvider.parseRemoteProcessOutput(result.stdout, ports: ports) ==
                [8080: "node", 8081: "node"])
        #expect(try String(contentsOf: log, encoding: .utf8) == "scan\n")
    }

    @Test func batchOutputRequiresCompleteBoundedPortRecords() throws {
        let ports = [8080, 8081]
        let names = try BuiltInInfoInspectorProvider.parseRemoteProcessOutput(
            Data("8080\tnode\n8081\t\nOMG_PROCESS_PROBE_V1\n".utf8), ports: ports
        )
        #expect(names == [8080: "node"])
        for invalid in [
            "8080\tnode\n", // incomplete/missing completion marker
            "8080\tnode\nOMG_PROCESS_PROBE_V1\n", // missing requested port
            "8080\tnode\n8080\tnode\nOMG_PROCESS_PROBE_V1\n", // duplicate
            "8080\tnode\n9000\tssh\nOMG_PROCESS_PROBE_V1\n", // unrequested
            "8080\tnode\r\n8081\t\nOMG_PROCESS_PROBE_V1\n", // control character
            "8080\t" + String(repeating: "x", count: 129) + "\n8081\t\nOMG_PROCESS_PROBE_V1\n"
        ] {
            #expect(throws: BuiltInInfoInspectorProvider.ProcessProbeError.self) {
                try BuiltInInfoInspectorProvider.parseRemoteProcessOutput(Data(invalid.utf8), ports: ports)
            }
        }
        let command = BuiltInInfoInspectorProvider.remoteProcessCommand(ports: [8081, -1, 8080, 8080, 65536])
        #expect(command.contains("for port in 8080 8081; do"))
        #expect(command.components(separatedBy: "lsof -nP").count == 2)
        #expect(command.components(separatedBy: "ss -H").count == 2)
    }

    @Test func supportsExplicitTargetsAndMigratesLoopbackPersistence() async throws {
        #expect(PortForwardTarget.parse("5175") == .init(
            host: PortForwardTarget.loopbackHost,
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("10.0.0.8:5175") == .init(
            host: "10.0.0.8",
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("[::1]:5175") == .init(
            host: "::1",
            port: 5_175
        ))
        #expect(PortForwardTarget.parse("bad target:5175") == nil)

        let legacy = Data("""
        [{"serverID":"machine-legacy","remotePort":5175}]
        """.utf8)
        let migrated = try JSONDecoder().decode(
            [BuiltInInfoInspectorProvider.DesiredForward].self,
            from: legacy
        )
        #expect(migrated.first?.remoteHost == PortForwardTarget.loopbackHost)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var launchedHost: String?
        var processProbeCount = 0
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, host, _, _, _ in
                launchedHost = host
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in
                processProbeCount += 1
                return [:]
            },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        let serverID = "machine-target"
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-target"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "10.0.0.8:5175")
            )
        )
        await Task.yield()
        #expect(launchedHost == "10.0.0.8")
        #expect(processProbeCount == 0)
        #expect(provider.content(
            for: serverID,
            alias: "cloud"
        ).items.first?.remoteHost == "10.0.0.8")
        provider.shutdown()
    }

    @Test func duplicateAndInvalidPortsDoNotLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var launchCount = 0
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, _ in
                launchCount += 1
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in true },
            remoteProcessBatchResolver: { _, _ in [:] },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        let serverID = "machine-0123456789abcdef"
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-2"
        )

        for port in [0, 65_536, 3_000, 3_000] {
            registry.performAction(
                paneID: BuiltInInfoInspectorProvider.paneID,
                action: .init(
                    context: context,
                    kind: .createPortForward(target: String(port))
                )
            )
        }
        #expect(launchCount == 1)
        #expect(provider.content(
            for: serverID,
            alias: "cloud"
        ).items.map(\.remotePort) == [3_000])
        provider.shutdown()
    }

    @Test func exposesDetailedSSHFailureReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-ssh-forward-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var termination: ((Int32, String) -> Void)?
        let registry = InspectorRegistry()
        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            persistenceURL: root.appendingPathComponent("port-forwards.json"),
            processLauncher: { _, _, _, _, callback in
                termination = callback
                return {}
            },
            localPortAllocator: { $0 },
            forwardReadiness: { _ in
                try? await Task.sleep(for: .seconds(1))
                return false
            },
            remoteProcessBatchResolver: { _, _ in [:] },
            openURL: { _ in },
            copyAddress: { _ in }
        )
        try provider.setEnabled(true)
        let strings = InfoStrings.current
        #expect(registry.descriptor(id: BuiltInInfoInspectorProvider.paneID)?.title == strings.infoTitle)

        let serverID = "hostkey-SHA256:failure="
        let context = sshContext(
            alias: "cloud",
            serverID: serverID,
            connectionID: "omg-ssh-failure"
        )
        provider.synchronizeConnections(.init(
            connected: [serverID],
            readyAliases: [serverID: "cloud"]
        ))
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .createPortForward(target: "5175")
            )
        )
        termination?(255, "bind [127.0.0.1]:5175: Address already in use")
        await Task.yield()

        guard case .failed(let message) = provider.content(
            for: serverID,
            alias: "cloud"
        ).items.first?.status else {
            Issue.record("Expected a detailed forwarding failure")
            return
        }
        #expect(message == strings.localPortInUse(5_175))
        provider.shutdown()
    }

    @Test func localizesInfoStrings() {
        let english = InfoStrings(language: .english)
        let chinese = InfoStrings(language: .simplifiedChinese)
        #expect(english.infoTitle == "Info")
        #expect(chinese.infoTitle == "信息")
        #expect(english.targetPlaceholder == "Port or host:port")
        #expect(chinese.targetPlaceholder == "端口或 host:port")
        #expect(chinese.localPortInUse(5_175) == "本地端口 5175 已被占用。")
        #expect(english.historyTitle == "Command History")
        #expect(chinese.historyTitle == "历史命令")
        #expect(english.agentPromptsTitle == "Agent Prompts")
        #expect(chinese.agentPromptsTitle == "提问历史")
        #expect(chinese.clickToJump == "跳转到这次输入的位置")
        #expect(!chinese.noTerminalAnchor.isEmpty)
        #expect(!english.historyLimited.isEmpty)
    }

    @Test func agentInfoHistoryIsHiddenWhileShellCanStillNavigate() {
        func activity(_ state: TabActivityState) -> TabActivity {
            .init(source: "agent", state: state, label: nil, message: nil,
                  detail: nil, progress: nil, icon: nil)
        }
        #expect(!BuiltInInfoInspectorProvider.hidesAgentHistory(descriptorPresent: false, activity: nil))
        #expect(BuiltInInfoInspectorProvider.hidesAgentHistory(descriptorPresent: true, activity: nil))
        for state in TabActivityState.allCases {
            #expect(BuiltInInfoInspectorProvider.hidesAgentHistory(descriptorPresent: false,
                                                                    activity: activity(state)))
        }
    }

    @Test func connectingSSHStillShowsPaneHistoryWhilePortActionWaits() throws {
        let pane = UUID()
        let registry = InspectorRegistry()
        let service = TerminalHistoryService { $0 == pane ? [
            .init(id: "saved-local", kind: .command, text: "pwd",
                  location: .unavailable(.expired), sourceLabel: "Local")
        ] : [] }
        let provider = BuiltInInfoInspectorProvider(registry: registry, historyService: service)
        try provider.setEnabled(true)
        var session = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "shell")
        session.apply(.init(action: .start, id: "omg-ssh-42",
                            metadata: "type=remote;targethost=cloud"),
                      currentWorkingDirectory: "/tmp", currentTerminalTitle: "shell")
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: pane, title: "cloud",
                                           workingDirectory: nil, workspace: nil, session: session)
        registry.presentationDidChange(to: BuiltInInfoInspectorProvider.paneID, context: context)
        guard case .info(let info) = registry.content(for: BuiltInInfoInspectorProvider.paneID,
                                                       context: context) else {
            Issue.record("Expected Info content during SSH connection")
            return
        }
        #expect(info.historyItems.map(\.text) == ["pwd"])
        #expect(info.portForwards.hostAlias == "cloud")
        #expect(!info.portForwards.canCreate)
        provider.shutdown()
    }

    @Test func publishesHistoryItemsAndHandlesJumpAction() async throws {
        let registry = InspectorRegistry()
        let surfaceID = UUID()
        var records: [InspectorHistoryItem] = [
            .init(kind: .command, text: "git status"),
            .init(kind: .command, text: "swift build"),
        ]
        let historyService = TerminalHistoryService { $0 == surfaceID ? records : [] }

        let provider = BuiltInInfoInspectorProvider(
            registry: registry,
            historyService: historyService
        )
        try provider.setEnabled(true)

        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: surfaceID,
            title: "terminal",
            workingDirectory: "/Users/test/code"
        )

        registry.presentationDidChange(
            to: BuiltInInfoInspectorProvider.paneID,
            context: context
        )

        guard case .info(let info) = registry.content(
            for: BuiltInInfoInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected typed Info content with history")
            return
        }

        #expect(!info.historyItems.isEmpty)
        #expect(info.historyItems.first?.text == "git status")

        records.insert(.init(kind: .command, text: "new command"), at: 0)
        NotificationCenter.default.post(name: .terminalHistoryDidChange, object: UUID())
        await Task.yield()
        if case .info(let unchanged) = registry.content(for: BuiltInInfoInspectorProvider.paneID, context: context) {
            #expect(unchanged.historyItems.first?.text == "git status")
        }
        NotificationCenter.default.post(name: .terminalHistoryDidChange, object: surfaceID)
        for _ in 0..<10 { await Task.yield() }
        if case .info(let refreshed) = registry.content(for: BuiltInInfoInspectorProvider.paneID, context: context) {
            #expect(refreshed.historyItems.first?.text == "new command")
        } else {
            Issue.record("Expected history content after completion notification")
        }

        let targetItem = info.historyItems.first!
        registry.performAction(
            paneID: BuiltInInfoInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .jumpToHistoryItem(targetItem)
            )
        )

        provider.shutdown()
    }

    private func sshContext(
        alias: String,
        serverID: String,
        connectionID: String
    ) -> InspectorPaneContext {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: connectionID,
                metadata: "type=remote;targethost=\(alias);serverid=\(serverID);cwd=/home/test"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "remote"
        )
        return .init(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
    }

    private func plainSSHContext(alias: String, connectionID: String) -> InspectorPaneContext {
        var session = PaneSessionContext(
            workingDirectory: "/Users/test/code",
            terminalTitle: "code"
        )
        session.apply(
            .init(
                action: .start,
                id: connectionID,
                metadata: "type=remote;targethost=\(alias);cwd=/home/test"
            ),
            currentWorkingDirectory: "/Users/test/code",
            currentTerminalTitle: "remote"
        )
        return .init(
            tabID: UUID(),
            surfaceID: UUID(),
            title: session.presentationTitle,
            workingDirectory: session.workingDirectory,
            workspace: session.workspace,
            session: session
        )
    }
}
