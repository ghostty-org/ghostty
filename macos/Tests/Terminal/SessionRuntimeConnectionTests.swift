import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
private final class SessionRuntimeRetryRecorder: SessionRuntimeRetrying {
    private(set) var descriptor: SessionRuntimeDescriptor?
    private(set) var onFailure: (@MainActor @Sendable (String) -> Void)?

    func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        self.descriptor = descriptor
        self.onFailure = onFailure
    }
}

struct SessionRuntimeConnectionTests {
    @MainActor
    @Test func missingRuntimeClearsInheritedHandoffCapability() {
        var config = Ghostty.SurfaceConfiguration()
        let keys = ["OMG_SSH_HANDOFF_HELPER", "OMG_SSH_HANDOFF_DIRECTORY", "OMG_SSH_HANDOFF_TOKEN"]
        for key in keys { config.environmentVariables[key] = "stale-from-another-app" }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SessionRuntimeHandoff(resources: missing).configure(&config, pane: UUID())
        for key in keys { #expect(config.environmentVariables[key] == "") }
    }

    @MainActor
    @Test func handoffCapabilityBelongsToTheCurrentAppAndPane() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("omgd")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let directory = root.appendingPathComponent("requests")
        let handoff = SessionRuntimeHandoff(resources: root, directory: directory)
        var first = Ghostty.SurfaceConfiguration()
        first.environmentVariables["OMG_SSH_HANDOFF_DIRECTORY"] = "old-app"
        handoff.configure(&first, pane: UUID())
        var second = Ghostty.SurfaceConfiguration()
        handoff.configure(&second, pane: UUID())
        #expect(first.environmentVariables["OMG_SSH_HANDOFF_HELPER"] == helper.path)
        #expect(first.environmentVariables["OMG_SSH_HANDOFF_DIRECTORY"] == directory.path)
        #expect(first.environmentVariables["OMG_SSH_HANDOFF_TOKEN"] != second.environmentVariables["OMG_SSH_HANDOFF_TOKEN"])

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var base = Ghostty.SurfaceConfiguration()
        base.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: base)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        handoff.configure(&first, pane: surface.id)
        let name = String(repeating: "a", count: 32)
        let request: [String: Any] = ["token": first.environmentVariables["OMG_SSH_HANDOFF_TOKEN"]!,
            "ssh": "/usr/bin/ssh", "args": ["-N", "host"], "cwd": root.path]
        try SessionRuntimeBridgeStorage.writePrivateFile(
            at: directory.appendingPathComponent(name + ".json"),
            data: JSONSerialization.data(withJSONObject: request),
            permissions: 0o600
        )
        #expect(handoff.accept(.init(action: .start, id: "omg-runtime-request-" + name, metadata: "type=app"),
                               source: surface, controller: controller))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".failed").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".accepted").path))
        #expect(controller.surfaceTree.first === surface)
    }

    @MainActor
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath:
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime/omgd").path),
        "Requires the bundled Session Runtime helper"))
    func packagedHandoffReachesOwningPaneWithoutConnectingToSSH() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("request.py")
        let result = root.appendingPathComponent("result")
        try """
        import json, os, pathlib, time
        directory = pathlib.Path(os.environ['OMG_SSH_HANDOFF_DIRECTORY'])
        name = '1234567890abcdef1234567890abcdef'
        payload = dict(token=os.environ['OMG_SSH_HANDOFF_TOKEN'], ssh='/usr/bin/ssh', args=['-N', 'host'], cwd=os.getcwd())
        request = directory / (name + '.json')
        fd = os.open(request, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, json.dumps(payload).encode())
        os.fsync(fd)
        os.close(fd)
        os.write(1, ('\\x1b]3008;start=omg-runtime-request-' + name + ';type=app\\x07').encode())
        failed = directory / (name + '.failed')
        for _ in range(100):
            if failed.exists():
                pathlib.Path(\(String(reflecting: result.path))).write_text('acknowledged')
                failed.unlink()
                break
            time.sleep(.05)
        """.write(to: script, atomically: true, encoding: .utf8)
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        let python = try #require(LocalPythonInterpreter.cached())
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: result, encoding: .utf8) == "acknowledged")
        #expect(controller.surfaceTree.first?.runtimeDescriptor == nil)
    }

    @MainActor
    @Test func retryTargetsTheExistingSessionWithoutReplacingItsPane() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let original = Ghostty.SurfaceView(native, baseConfig: config)
        // An unavailable revision avoids launching SSH in this UI integration
        // test; identity must survive even when connection preparation fails.
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "host"),
                                                   revision: "unavailable-test-revision", policy: .init())
        original.runtimeDescriptor = descriptor
        original.runtimeConnectionState = .attention(attempt: 4, message: "offline")
        let controller = TerminalController(app, withSurfaceTree: .init(view: original))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let originalID = original.id
        let retryer = SessionRuntimeRetryRecorder()
        controller.retryRuntimeConnection(for: original, using: retryer)
        #expect(retryer.descriptor == descriptor)
        #expect(original.runtimeConnectionState == .reconnecting(attempt: 5, retryInMilliseconds: nil))
        #expect(controller.surfaceTree.first === original)
        retryer.onFailure?("relay offline")
        #expect(original.runtimeConnectionState == .failed(message: "relay offline"))
        controller.retryRuntimeConnection(for: original, using: retryer)
        let lateFailure = try #require(retryer.onFailure)
        original.runtimeConnectionState = .ready
        lateFailure("stale relay failure")
        #expect(original.runtimeConnectionState == .ready)
        let request = try #require(try JSONSerialization.jsonObject(with:
            Data(descriptor.openRequest(pane: originalID, attachExisting: true).utf8)) as? [String: Any])
        let socket = URL(fileURLWithPath: "/tmp/runtime.sock")
        #expect(SessionRuntimeRetryCommand.arguments(socket: socket, interactive: true) ==
                ["retry-local", socket.path, "--interactive"])
        #expect(SessionRuntimeRetryCommand.arguments(socket: socket, interactive: false) ==
                ["retry-local", socket.path])
        #expect(controller.surfaceTree.first === original)
        #expect(original.id == originalID)
        #expect(original.runtimeDescriptor == descriptor)
        #expect(request["id"] as? String == original.id.uuidString.lowercased())
        #expect(request["create"] as? Bool == false)
    }

    @MainActor
    @Test func runtimeStatusAndFailedAttachKeepTheSameSurfaceAndOutput() async throws {
        let root = URL(fileURLWithPath: "/tmp/omg-error-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("s")
        let server = Process()
        let python = try #require(LocalPythonInterpreter.cached())
        server.executableURL = URL(fileURLWithPath: python.executablePath)
        server.arguments = ["-c", """
        import socket,struct,sys
        import time
        s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(1)
        c,_=s.accept();c.recv(65536)
        status=b'{"state":"reconnecting","attempt":2,"retry_in_ms":1500}'
        c.sendall(struct.pack('>cQI',b'T',1,len(status))+status)
        time.sleep(.3)
        message=b'authentication failed'
        c.sendall(struct.pack('>cQI',b'E',1,len(message))+message)
        time.sleep(.4)
        c.close();s.close()
        """, socket.path]
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: socket.path))
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables["OMG_RUNTIME_SOCKET"] = socket.path
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = UUID().uuidString.lowercased()
        let view = Ghostty.SurfaceView(native, baseConfig: config)
        view.runtimeDescriptor = .init(connection: try GitSSHConnection(destination: "host"), revision: "test", policy: .init())
        view.runtimeConnectionState = .connecting(attempt: 0)
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        for _ in 0..<150 where view.runtimeConnectionState != .reconnecting(attempt: 2, retryInMilliseconds: 1_500) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.runtimeConnectionState == .reconnecting(attempt: 2, retryInMilliseconds: 1_500))
        for _ in 0..<150 where view.runtimeConnectionState != .failed(message: "authentication failed") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.runtimeConnectionState == .failed(message: "authentication failed"))
        #expect(controller.surfaceTree.first === view)
        #expect(view.contextSignal?.id == "omg-runtime-state")
    }

    @MainActor
    @Test func inMemoryCloseQueueKeepsTestIntentWithoutStartingUserConnections() throws {
        let queue = SessionRuntimeCloseQueue(url: nil)
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "test-only-host"),
                                                   revision: "test", policy: .init())
        let request = SessionRuntimeCloseRequest(pane: UUID(), descriptor: descriptor)
        try queue.enqueue([request])
        queue.start()
        queue.retry()
        #expect(queue.requests == [request])
        try queue.acknowledge(request)
        #expect(queue.requests.isEmpty)
    }

    @MainActor
    @Test func closeIntentSurvivesRestartAndRequiresAcknowledgement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("closes.json")
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "host"),
                                                   revision: "test", policy: .init())
        let request = SessionRuntimeCloseRequest(pane: UUID(), descriptor: descriptor)
        let first = SessionRuntimeCloseQueue(url: url)
        try first.enqueue([request, request])
        let restarted = SessionRuntimeCloseQueue(url: url)
        #expect(restarted.requests == [request])
        try restarted.acknowledge(request)
        #expect(SessionRuntimeCloseQueue(url: url).requests.isEmpty)
        try Data("invalid".utf8).write(to: url)
        let corrupt = SessionRuntimeCloseQueue(url: url)
        #expect(throws: (any Error).self) { try corrupt.enqueue([request]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "invalid")
    }

    @MainActor
    @Test func sshHandoffOpensSiblingTabAndLeavesLocalSurfaceVisible() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        let local = try #require(controller.surfaceTree.first)
        let descriptor = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"),
            revision: "unavailable-test-revision",
            policy: .init()
        )
        let remoteController = try SessionRuntimeHandoff().openRemoteTab(descriptor, in: controller)
        defer {
            remoteController.window?.delegate = nil
            remoteController.window?.close()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let remote = try #require(remoteController.surfaceTree.first)
        #expect(controller.surfaceTree.first === local)
        #expect(remoteController !== controller)
        #expect(remote.runtimeDescriptor == descriptor)
        #expect(remoteController.workspaceID == controller.workspaceID)
    }

    @MainActor
    @Test func newTabIsLocalButSplitInheritsRuntime() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(native, baseConfig: config)
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"), revision: "test", policy: .init())
        view.runtimeDescriptor = descriptor
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        try descriptor.configure(&config)
        config.environmentVariables["OMG_RUNTIME_SOCKET"] = "/tmp/remote.sock"
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = "old"
        let tab = try #require(controller.tabConfiguration(inherited: config, from: view))
        #expect(tab.workingDirectory == "/tmp")
        #expect(tab.command == nil)
        #expect(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
        #expect(tab.environmentVariables["OMG_RUNTIME_SOCKET"] == nil)
        #expect(tab.environmentVariables["OMG_RUNTIME_PANE_ID"] == nil)
        view.pwd = "/srv/project with spaces/中文"
        let split = try #require(try controller.splitConfiguration(inherited: config, from: view, runtimeRevision: "current"))
        let encoded = try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let next = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(encoded.utf8))
        #expect(next.connection == descriptor.connection)
        #expect(next.revision == "current")
        #expect(next.policy == descriptor.policy)
        #expect(next.initialWorkingDirectory == view.pwd)
        #expect(view.runtimeDescriptor == descriptor)
        #expect(split.workingDirectory == nil)
        #expect(split.command == nil)
        #expect(split.environmentVariables["OMG_RUNTIME_SOCKET"] == nil)
        #expect(split.environmentVariables["OMG_RUNTIME_PANE_ID"] == nil)
    }

    @MainActor
    @Test func localRuntimeStaysLocalAndNewTabsInheritItsDurableBackend() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        var descriptor = SessionRuntimeDescriptor(
            connection: nil,
            revision: "local-test",
            policy: .init(detachedTTLSeconds: 86_400, closeOnAgentDone: false),
            localWorkingDirectory: "/tmp"
        )
        descriptor.initialWorkingDirectory = "/tmp"
        view.runtimeDescriptor = descriptor
        view.pwd = "/tmp/project"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        var currentPolicy = SessionRuntimePolicy()
        currentPolicy.detachedTTLSeconds = 3_600
        currentPolicy.expiresAt = 1_900_000_000
        currentPolicy.closeOnAgentDone = true
        currentPolicy.agentDoneGraceSeconds = 20
        currentPolicy.recordRetentionSeconds = 172_800

        var context = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "local")
        context.applyRuntimeConnection(descriptor, workingDirectory: "/tmp/project", state: .ready)
        #expect(!context.isSSHSession)
        #expect(context.workingDirectory == "/tmp/project")
        #expect(context.workspace == nil)

        let tab = try #require(controller.tabConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-current",
            runtimePolicy: currentPolicy
        ))
        let tabEncoded = try #require(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let tabDescriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(tabEncoded.utf8))
        #expect(tabDescriptor.isLocal)
        #expect(tabDescriptor.revision == "local-current")
        #expect(tabDescriptor.policy == currentPolicy)
        #expect(view.runtimeDescriptor == descriptor)
        #expect(tabDescriptor.initialWorkingDirectory == nil)
        #expect(tab.workingDirectory == nil)
        #expect(tab.command == config.command)
        #expect(tab.initialInput == config.initialInput)

        let split = try #require(try controller.splitConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-next",
            runtimePolicy: currentPolicy
        ))
        let splitEncoded = try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let splitDescriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(splitEncoded.utf8))
        #expect(splitDescriptor.isLocal)
        #expect(splitDescriptor.revision == "local-next")
        #expect(splitDescriptor.policy == currentPolicy)
        #expect(splitDescriptor.initialWorkingDirectory == nil)
        #expect(view.runtimeDescriptor == descriptor)
        #expect(split.workingDirectory == nil)
        #expect(split.command == config.command)
        #expect(split.initialInput == config.initialInput)
    }

    @MainActor
    @Test func localRuntimeTabsAndSplitsKeepCustomDefaultAndDisabledCwdInheritance() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/env"
        config.workingDirectory = "/tmp/custom-default"
        config.initialInput = "start"
        config.environmentVariables["CUSTOM_VALUE"] = "kept"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        view.runtimeDescriptor = .init(
            connection: nil,
            revision: "local-test",
            policy: .init(),
            localWorkingDirectory: "/tmp/original"
        )
        view.pwd = "/tmp/terminal-current"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }

        let tab = try #require(controller.tabConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-current"
        ))
        let tabDescriptor = try JSONDecoder().decode(
            SessionRuntimeDescriptor.self,
            from: Data(try #require(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey]).utf8)
        )
        #expect(tab.workingDirectory == "/tmp/custom-default")
        #expect(tabDescriptor.initialWorkingDirectory == "/tmp/custom-default")
        #expect(tab.command == config.command)
        #expect(tab.initialInput == config.initialInput)
        #expect(tab.environmentVariables["CUSTOM_VALUE"] == "kept")

        let split = try #require(try controller.splitConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-current"
        ))
        let splitDescriptor = try JSONDecoder().decode(
            SessionRuntimeDescriptor.self,
            from: Data(try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey]).utf8)
        )
        #expect(split.workingDirectory == "/tmp/custom-default")
        #expect(splitDescriptor.initialWorkingDirectory == "/tmp/custom-default")
        #expect(split.command == config.command)
        #expect(split.initialInput == config.initialInput)
        #expect(split.environmentVariables["CUSTOM_VALUE"] == "kept")

        config.workingDirectory = nil
        let defaultTab = try #require(controller.tabConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-current"
        ))
        let defaultDescriptor = try JSONDecoder().decode(
            SessionRuntimeDescriptor.self,
            from: Data(try #require(defaultTab.environmentVariables[SessionRuntimeDescriptor.environmentKey]).utf8)
        )
        #expect(defaultTab.workingDirectory == nil)
        #expect(defaultDescriptor.initialWorkingDirectory == nil)
        let defaultSplit = try #require(try controller.splitConfiguration(
            inherited: config,
            from: view,
            runtimeRevision: "local-current"
        ))
        let defaultSplitDescriptor = try JSONDecoder().decode(
            SessionRuntimeDescriptor.self,
            from: Data(try #require(defaultSplit.environmentVariables[SessionRuntimeDescriptor.environmentKey]).utf8)
        )
        #expect(defaultSplit.workingDirectory == nil)
        #expect(defaultSplitDescriptor.initialWorkingDirectory == nil)
    }

    @MainActor
    @Test func windowCloseSuspendsRetainedRuntimeSurfaceAndReattachResumesIt() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let runtimeSurface = Ghostty.SurfaceView(native, baseConfig: config)
        runtimeSurface.runtimeDescriptor = .init(
            connection: nil,
            revision: "window-lifecycle",
            policy: .init()
        )
        let runtimeController = TerminalController(app, withSurfaceTree: .init(view: runtimeSurface))
        let originalID = runtimeSurface.id
        var restoredController: TerminalController?

        let execSurface = Ghostty.SurfaceView(native, baseConfig: config)
        let execController = TerminalController(app, withSurfaceTree: .init(view: execSurface))
        defer {
            for controller in [runtimeController, restoredController, execController].compactMap({ $0 }) {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        _ = try #require(runtimeController.window)
        runtimeController.closeWindowImmediately()
        #expect(runtimeSurface.runtimeAttachmentSuspended)

        restoredController = TerminalController(app, withSurfaceTree: .init(view: runtimeSurface))
        _ = try #require(restoredController?.window)
        #expect(runtimeSurface.id == originalID)
        #expect(!runtimeSurface.runtimeAttachmentSuspended)

        _ = try #require(execController.window)
        execController.closeWindowImmediately()
        #expect(!execSurface.runtimeAttachmentSuspended)
    }

    @MainActor
    @Test func disablingLocalRuntimePreservesInheritedGhosttyLaunchConfiguration() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/env"
        config.workingDirectory = nil
        config.initialInput = "initial draft"
        config.waitAfterCommand = true
        config.environmentVariables["CUSTOM_VALUE"] = "kept"
        let descriptor = SessionRuntimeDescriptor(
            connection: nil,
            revision: "old-local",
            policy: .init(),
            localWorkingDirectory: "/tmp/original"
        )
        let view = Ghostty.SurfaceView(native, baseConfig: config)
        view.runtimeDescriptor = descriptor
        view.pwd = "/tmp/current-terminal"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        try descriptor.configure(&config)
        config.environmentVariables["OMG_RUNTIME_SOCKET"] = "/tmp/old.sock"
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = "old-pane"

        let tab = try #require(controller.tabConfiguration(
            inherited: config,
            from: view,
            localRuntimeEnabled: false
        ))
        let split = try #require(try controller.splitConfiguration(
            inherited: config,
            from: view,
            localRuntimeEnabled: false
        ))
        let routingKeys = [
            SessionRuntimeDescriptor.environmentKey,
            SessionRuntimeDescriptor.localRuntimeEnvironmentKey,
            SessionRuntimeDescriptor.attachExistingEnvironmentKey,
            "OMG_RUNTIME_SOCKET",
            "OMG_RUNTIME_PANE_ID",
        ]

        for result in [tab, split] {
            #expect(result.workingDirectory == nil)
            #expect(result.command == config.command)
            #expect(result.initialInput == config.initialInput)
            #expect(result.waitAfterCommand == config.waitAfterCommand)
            #expect(result.environmentVariables["CUSTOM_VALUE"] == "kept")
            for key in routingKeys { #expect(result.environmentVariables[key] == nil) }
        }
    }

    @Test func runtimeDescriptorsReadLegacySSHArchivesAndLocalRequests() throws {
        let remote = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "devbox"),
            revision: "old",
            policy: .init()
        )
        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(remote)) as? [String: Any])
        legacyObject.removeValue(forKey: "localWorkingDirectory")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restored = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: legacyData)
        #expect(restored.connection?.destination == "devbox")

        let local = SessionRuntimeDescriptor(
            connection: nil,
            revision: "new",
            policy: .init(),
            localWorkingDirectory: "/tmp/project",
            initialWorkingDirectory: "/tmp/project"
        )
        let id = UUID()
        let fresh = try #require(try JSONSerialization.jsonObject(with:
            Data(local.openRequest(pane: id, attachExisting: false).utf8)) as? [String: Any])
        let restoredRequest = try #require(try JSONSerialization.jsonObject(with:
            Data(local.openRequest(pane: id, attachExisting: true).utf8)) as? [String: Any])
        #expect(fresh["cwd"] as? String == "/tmp/project")
        #expect(fresh["create"] as? Bool == true)
        #expect(restoredRequest["cwd"] == nil)
        #expect(restoredRequest["create"] as? Bool == false)

        var config = Ghostty.SurfaceConfiguration()
        try local.configure(&config)
        #expect(config.environmentVariables[SessionRuntimeDescriptor.localRuntimeEnvironmentKey] == "1")
        #expect(config.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] == "")
        try local.configureAttachExisting(&config)
        #expect(config.environmentVariables[SessionRuntimeDescriptor.attachExistingEnvironmentKey] == "1")
    }

    @MainActor
    @Test func automaticLocalRuntimePreservesGhosttyLaunchConfiguration() throws {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/python3 -c 'print(1)'"
        config.workingDirectory = "/tmp/custom default"
        config.initialInput = "initial draft"
        config.waitAfterCommand = true
        config.environmentVariables["CUSTOM_LAUNCH_ENV"] = "kept"

        let descriptor = try SessionRuntimeConnections.configureLocalRuntime(
            &config,
            policy: .init(),
            revision: "launch-test"
        )
        #expect(descriptor.isLocal)
        #expect(descriptor.localWorkingDirectory == "/tmp/custom default")
        #expect(config.command == "/usr/bin/python3 -c 'print(1)'")
        #expect(config.workingDirectory == "/tmp/custom default")
        #expect(config.initialInput == "initial draft")
        #expect(config.waitAfterCommand)
        #expect(config.environmentVariables["CUSTOM_LAUNCH_ENV"] == "kept")

        var inheritedDefault = Ghostty.SurfaceConfiguration()
        let noInheritedDirectory = try SessionRuntimeConnections.configureLocalRuntime(
            &inheritedDefault,
            policy: .init(),
            revision: "launch-test"
        )
        #expect(inheritedDefault.workingDirectory == nil)
        #expect(noInheritedDirectory.initialWorkingDirectory == nil)
    }

    @MainActor
    @Test func automaticLocalRuntimeFallsBackWithoutPackagedResourcesOrDuringTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("session-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("revision\n".utf8).write(to: runtime.appendingPathComponent("revision"))
        try Data("snapshot\n".utf8).write(to: runtime.appendingPathComponent("snapshot-revision"))
        let helper = runtime.appendingPathComponent("omgd")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        #expect(!SessionRuntimeConnections.hasAutomaticLocalRuntimeResources(at: nil, isRunningTests: false))
        #expect(!SessionRuntimeConnections.hasAutomaticLocalRuntimeResources(at: root, isRunningTests: true))
        #expect(SessionRuntimeConnections.hasAutomaticLocalRuntimeResources(at: root, isRunningTests: false))

        var enabledConfig = Ghostty.SurfaceConfiguration()
        #expect(SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
            &enabledConfig,
            policy: .init(),
            enabled: true,
            resources: root,
            isRunningTests: false
        ))
        #expect(enabledConfig.environmentVariables[SessionRuntimeDescriptor.localRuntimeEnvironmentKey] == "1")

        var testConfig = Ghostty.SurfaceConfiguration()
        #expect(!SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
            &testConfig,
            policy: .init(),
            enabled: true,
            resources: root,
            isRunningTests: true
        ))
        #expect(testConfig.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)

        try FileManager.default.removeItem(at: helper)
        #expect(!SessionRuntimeConnections.hasAutomaticLocalRuntimeResources(at: root, isRunningTests: false))
    }

    @MainActor
    @Test func persistedSessionUsesItsCachedRevisionHelper() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let version = support.appendingPathComponent("session-runtime/versions/older", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: support) }
        try Data("older\n".utf8).write(to: version.appendingPathComponent("revision"))
        try Data("snapshot-older\n".utf8).write(to: version.appendingPathComponent("snapshot-revision"))
        let helper = version.appendingPathComponent("omgd")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        #expect(try SessionRuntimeConnections.cachedHelperURL(
            forRevision: "older",
            applicationSupportRoot: support
        ) == helper)
        #expect(throws: (any Error).self) {
            try SessionRuntimeConnections.cachedHelperURL(forRevision: "current", applicationSupportRoot: support)
        }
    }

    @Test func localStateNamespacesAreStableAndSeparateForAppUsersAndRevisions() {
        let descriptor = SessionRuntimeDescriptor(connection: nil, revision: "current", policy: .init())
        let home = URL(fileURLWithPath: "/tmp/local-runtime-user-a", isDirectory: true)
        let support = URL(fileURLWithPath: "/tmp/OMG Dev", isDirectory: true)
        let first = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: support,
            homeDirectory: home
        )
        let same = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: support,
            homeDirectory: home
        )
        let otherUser = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: URL(fileURLWithPath: "/tmp/OMG", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/tmp/local-runtime-user-b", isDirectory: true)
        )
        var older = descriptor
        older.revision = "older"
        let olderRevision = SessionRuntimeConnections.localStateDirectory(
            for: older,
            applicationSupportRoot: support,
            homeDirectory: home
        )
        #expect(first == same)
        #expect(first != otherUser)
        #expect(first != olderRevision)
    }

    @Test func localRuntimeBridgeCapabilityIsStablePrivateAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = SessionRuntimeDescriptor(connection: nil, revision: "bridge-test", policy: .init())
        let pane = UUID()
        let first = try SessionRuntimeBridgeStorage.directory(
            for: descriptor,
            pane: pane,
            purpose: "handoff",
            applicationSupportRoot: support,
            homeDirectory: home
        )
        let second = try SessionRuntimeBridgeStorage.directory(
            for: descriptor,
            pane: pane,
            purpose: "handoff",
            applicationSupportRoot: support,
            homeDirectory: home
        )
        #expect(first == second)
        let token = try SessionRuntimeBridgeStorage.capabilityToken(in: first)
        #expect(token == (try SessionRuntimeBridgeStorage.capabilityToken(in: second)))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.appendingPathComponent("capability").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let capability = first.appendingPathComponent("capability")
        try FileManager.default.removeItem(at: capability)
        let target = root.appendingPathComponent("outside")
        try Data(token.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: capability, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try SessionRuntimeBridgeStorage.capabilityToken(in: first)
        }
    }

    @Test func privateRuntimeDirectoryValidationChecksOwnerModeAndSymlink() throws {
        let directoryMode = S_IFDIR | mode_t(0o700)
        #expect(SessionRuntimeBridgeStorage.hasPrivateDirectoryMetadata(
            owner: getuid(),
            mode: directoryMode
        ))
        #expect(!SessionRuntimeBridgeStorage.hasPrivateDirectoryMetadata(
            owner: getuid() &+ 1,
            mode: directoryMode
        ))
        #expect(!SessionRuntimeBridgeStorage.hasPrivateDirectoryMetadata(
            owner: getuid(),
            mode: S_IFDIR | mode_t(0o755)
        ))
        #expect(!SessionRuntimeBridgeStorage.hasPrivateDirectoryMetadata(
            owner: getuid(),
            mode: S_IFLNK | mode_t(0o700)
        ))

    }

    @MainActor
    @Test func relayPreparationRejectsUnsafeRootBeforeWritingRuntimeFiles() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unsafeRoot = parent.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: unsafeRoot, withDestinationURL: target)

        let descriptor = SessionRuntimeDescriptor(
            connection: nil,
            revision: "unsafe-root-\(UUID().uuidString)",
            policy: .init()
        )
        #expect(throws: (any Error).self) {
            try SessionRuntimeConnections.shared.prepare(descriptor, runtimeRoot: unsafeRoot)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)

        let sharedRoot = parent.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let sharedDescriptor = SessionRuntimeDescriptor(
            connection: nil,
            revision: "unsafe-mode-\(UUID().uuidString)",
            policy: .init()
        )
        #expect(throws: (any Error).self) {
            try SessionRuntimeConnections.shared.prepare(sharedDescriptor, runtimeRoot: sharedRoot)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.path).isEmpty)
    }

    @Test func runtimeStatusFramesDecodeRetryStateAndBoundUntrustedDetails() throws {
        #expect(SessionRuntimeConnectionState.decode(
            #"{"state":"reconnecting","attempt":3,"retry_in_ms":1200,"message":"network offline"}"#
        ) == .reconnecting(attempt: 3, retryInMilliseconds: 1_200))
        #expect(SessionRuntimeConnectionState.decode(
            #"{"state":"attention","attempt":5,"message":"credential expired"}"#
        ) == .attention(attempt: 5, message: "credential expired"))
        #expect(SessionRuntimeConnectionState.decode(#"{"state":"ready","attempt":0}"#) == .ready)
        #expect(SessionRuntimeConnectionState.decode(
            #"{"state":"exited","attempt":0,"exit_code":17}"#
        ) == .exited(exitCode: 17))
        #expect(SessionRuntimeConnectionState.decode(#"{"state":"exited","attempt":0}"#) == nil)
        #expect(SessionRuntimeConnectionState.decode(#"{"state":"other","attempt":0}"#) == nil)
        #expect(SessionRuntimeConnectionState.decode(String(repeating: "x", count: 9_000)) == nil)
        #expect(SessionRuntimeConnectionState.failed(message: nil).canRetry)
        #expect(SessionRuntimeConnectionState.decode(
            #"{"state":"failed","retryable":false,"message":"incompatible"}"#
        ) == .failed(message: "incompatible", retryable: false))
        #expect(!SessionRuntimeConnectionState.failed(message: "incompatible", retryable: false).canRetry)
        #expect(!SessionRuntimeConnectionState.ready.canRetry)
        #expect(!SessionRuntimeConnectionState.exited(exitCode: 17).canRetry)
        #expect(SessionRuntimeConnectionState.reconnecting(attempt: 2, retryInMilliseconds: 1_000).canRetry)
        #expect(!SessionRuntimeConnectionState.reconnecting(attempt: 2, retryInMilliseconds: nil).canRetry)
    }

    @Test func startupModesAttachOnlySavedSessionArchives() {
        #expect(SessionRuntimeRestorationPolicy.attachesSavedRuntime(for: .restoreSessions))
        #expect(!SessionRuntimeRestorationPolicy.attachesSavedRuntime(for: .restoreTabs))
        #expect(!SessionRuntimeRestorationPolicy.attachesSavedRuntime(for: .newTerminal))
        #expect(SessionRuntimeRestorationPolicy.createsFreshPaneIDsFromSavedState(for: .restoreTabs))
        #expect(!SessionRuntimeRestorationPolicy.createsFreshPaneIDsFromSavedState(for: .newTerminal))
        #expect(!SessionRuntimeRestorationPolicy.createsFreshPaneIDsFromSavedState(for: .restoreSessions))
    }

    @MainActor
    @Test func terminationCopyMatchesOrdinaryPersistentAndMixedTargets() {
        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        let ordinary = SessionRuntimeCloseCopy(hasPersistentRuntime: false, hasOrdinaryProcess: true)
        let persistent = SessionRuntimeCloseCopy(hasPersistentRuntime: true, hasOrdinaryProcess: false)
        let mixed = SessionRuntimeCloseCopy(hasPersistentRuntime: true, hasOrdinaryProcess: true)

        #expect(ordinary.windowMessage(allWindows: false, strings: english)
                == "All terminal sessions in this window will be terminated.")
        #expect(ordinary.quitMessage(multipleWindows: false, strings: english)
                == "The terminal still has a running process. If you quit, the process will be killed.")
        #expect(ordinary.quitButtonTitle(multipleWindows: true, strings: english) == "Terminate Processes")

        #expect(persistent.windowMessage(allWindows: false, strings: english)
                == "Persistent sessions in this window will continue running in the background.")
        #expect(persistent.quitButtonTitle(multipleWindows: false, strings: english) == "Quit")

        #expect(mixed.windowMessage(allWindows: true, strings: english)
                == "Ordinary terminal processes will be terminated; persistent sessions will continue in the background.")
        #expect(mixed.quitMessage(multipleWindows: true, strings: english)
                == "If you quit without reviewing windows, ordinary terminal processes will be terminated; persistent sessions will continue in the background.")
        #expect(mixed.quitButtonTitle(multipleWindows: true, strings: english) == "Quit")
        #expect(mixed.windowMessage(allWindows: false, strings: chinese)
                == "此窗口中的普通终端进程将被终止；持久会话会在后台继续运行。")
        #expect(mixed.quitButtonTitle(multipleWindows: false, strings: chinese) == "退出")
    }

    @MainActor
    @Test func runtimeSettingsStringsFollowLanguageAndSearch() {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)
        #expect(en.runtimeTitle == "Persistent terminal sessions")
        #expect(zh.runtimeTitle == "持久终端会话")
        #expect(en.runtimeTitle != zh.runtimeTitle)
        #expect(en.runtimeLocalOpen == "New Local Session")
        #expect(zh.runtimeLocalOpen == "新建本地会话")
        #expect(en.runtimeLocalRuntimeEnabled == "Use durable runtime for new local terminals")
        #expect(zh.runtimeLocalRuntimeEnabled == "新建本地终端使用后台会话运行时")
        #expect(en.runtimeLibrary == "Browse Sessions…")
        #expect(en.runtimeCloseOnDone.contains("[Beta]"))
        #expect(zh.runtimeCloseOnDone.contains("【Beta】"))
        #expect(SettingsStrings(language: .system, preferredLanguages: ["zh-CN"]).runtimeTitle == zh.runtimeTitle)
        #expect(zh.runtimeDoneGraceCaption.contains("最长保留期限"))
        let entries = SettingsSearchCatalog.entries(strings: zh)
        #expect(entries.contains { $0.settingIDs.contains("sessions.runtimeDetachedHours") && $0.title == zh.runtimeTitle })
        #expect(entries.contains { $0.settingIDs.contains("sessions.localRuntimeEnabled") && $0.title == zh.runtimeTitle })
    }

    @Test func hostIdentityIncludesExactRoutingAndRuntimeRevision() throws {
        let a = try GitSSHConnection(destination: "devbox", options: ["-p", "2222", "-J", "jump"])
        let b = try GitSSHConnection(destination: "devbox", options: ["-p", "2223", "-J", "jump"])
        let first = SessionRuntimeDescriptor(connection: a, revision: "abc", policy: .init())
        let second = SessionRuntimeDescriptor(connection: b, revision: "abc", policy: .init())
        #expect(first.identity != second.identity)
        #expect(first.identity != SessionRuntimeDescriptor(connection: a, revision: "def", policy: .init()).identity)
        let decoded = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
    }

    @Test func splitDirectoryIsOnlyUsedForCreationAndDoesNotChangeConnectionIdentity() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"),
            revision: "current", policy: .init())
        var split = descriptor
        split.initialWorkingDirectory = "/srv/dir with spaces/中文;$(not-a-command)"
        #expect(split.identity == descriptor.identity)
        let id = UUID()
        let fresh = try #require(try JSONSerialization.jsonObject(with:
            Data(split.openRequest(pane: id, attachExisting: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with:
            Data(split.openRequest(pane: id, attachExisting: true).utf8)) as? [String: Any])
        #expect(fresh["cwd"] as? String == split.initialWorkingDirectory)
        #expect(restored["cwd"] == nil)
        #expect(restored["create"] as? Bool == false)
        // The optional field must not invalidate pre-upgrade restore archives.
        let oldData = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: oldData).initialWorkingDirectory == nil)
        for invalid in ["relative/path", "", "/bad\0path", "/" + String(repeating: "界", count: 1500)] {
            #expect(SessionRuntimeDescriptor.validWorkingDirectory(invalid) == nil)
        }
    }

    @Test func restoredPaneCannotSilentlyCreateANewRemoteProcess() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"), revision: "abc", policy: .init())
        let id = UUID()
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, attachExisting: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, attachExisting: true).utf8)) as? [String: Any])
        #expect(fresh["id"] as? String == id.uuidString.lowercased())
        #expect(fresh["create"] as? Bool == true)
        #expect(restored["create"] as? Bool == false)
        #expect((restored["policy"] as? [String: Any])?["detached_ttl_seconds"] as? Int == 259200)
        #expect((restored["policy"] as? [String: Any])?["close_on_agent_done"] as? Bool == false)
    }

    @MainActor
    @Test func lifetimeSettingsPersistAndRemainBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.runtimePolicy.detachedTTLSeconds == 259200)
        #expect(!settings.runtimePolicy.closeOnAgentDone)
        #expect(settings.localRuntimeEnabled)
        settings.runtimeDetachedHours = 2
        settings.runtimeCloseOnAgentDone = true
        settings.runtimeDoneGraceSeconds = 15
        settings.runtimeExpiration = "2030-01-01T00:00:00Z"
        settings.localRuntimeEnabled = false
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(!restored.localRuntimeEnabled)
        #expect(restored.runtimePolicy.detachedTTLSeconds == 7200)
        #expect(restored.runtimePolicy.closeOnAgentDone)
        #expect(restored.runtimePolicy.agentDoneGraceSeconds == 15)
        #expect(restored.runtimePolicy.expiresAt == 1_893_456_000)
        settings.runtimeDetachedHours = -1
        #expect(settings.runtimePolicy.detachedTTLSeconds == 0)
    }

    @Test func runtimeSidebarUsesSSHIdentityAndRemoteDirectory() throws {
        let descriptor = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "user@devbox"),
            revision: "test", policy: .init())
        var context = PaneSessionContext(workingDirectory: "/Users/test/code", terminalTitle: "local")
        context.applyRuntimeConnection(descriptor, workingDirectory: nil)
        #expect(context.isSSHSession)
        #expect(context.presentationTitle == "user@devbox")
        context.applyRuntimeConnection(descriptor, workingDirectory: "/srv/project", state: .ready)
        #expect(context.workingDirectory == "/srv/project")
        #expect(context.remoteTabBreadcrumb?.host == "user@devbox")
        #expect(context.remoteTabBreadcrumb?.directory == "project")
    }

    @Test func existingSessionPoliciesKeepTheirExplicitValues() throws {
        let old = SessionRuntimeDescriptor(connection: try GitSSHConnection(destination: "devbox"),
            revision: "previous", policy: .init(detachedTTLSeconds: 86400, closeOnAgentDone: true))
        let restored = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: JSONEncoder().encode(old))
        #expect(restored.policy.detachedTTLSeconds == 86400)
        #expect(restored.policy.closeOnAgentDone)
        #expect(SessionRuntimePolicy().detachedTTLSeconds == 259200)
        #expect(!SessionRuntimePolicy().closeOnAgentDone)
    }
}
