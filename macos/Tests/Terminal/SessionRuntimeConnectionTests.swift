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
        try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent(name + ".json"))
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
        (directory / (name + '.json')).write_text(json.dumps(payload))
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
        config.command = "/usr/bin/python3 " + script.path
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
            Data(descriptor.openRequest(pane: originalID, restoring: true).utf8)) as? [String: Any])
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
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
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
            policy: .init(),
            localWorkingDirectory: "/tmp"
        )
        descriptor.initialWorkingDirectory = "/tmp"
        view.runtimeDescriptor = descriptor
        view.pwd = "/tmp/project"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }

        var context = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "local")
        context.applyRuntimeConnection(descriptor, workingDirectory: "/tmp/project", state: .ready)
        #expect(!context.isSSHSession)
        #expect(context.workingDirectory == "/tmp/project")
        #expect(context.workspace == nil)

        let tab = try #require(controller.tabConfiguration(inherited: config, from: view))
        let tabEncoded = try #require(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let tabDescriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(tabEncoded.utf8))
        #expect(tabDescriptor.isLocal)
        #expect(tabDescriptor.initialWorkingDirectory == "/tmp/project")

        let split = try #require(try controller.splitConfiguration(inherited: config, from: view, runtimeRevision: "local-next"))
        let splitEncoded = try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey])
        let splitDescriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: Data(splitEncoded.utf8))
        #expect(splitDescriptor.isLocal)
        #expect(splitDescriptor.revision == "local-next")
        #expect(splitDescriptor.initialWorkingDirectory == "/tmp/project")
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
            Data(local.openRequest(pane: id, restoring: false).utf8)) as? [String: Any])
        let restoredRequest = try #require(try JSONSerialization.jsonObject(with:
            Data(local.openRequest(pane: id, restoring: true).utf8)) as? [String: Any])
        #expect(fresh["cwd"] as? String == "/tmp/project")
        #expect(fresh["create"] as? Bool == true)
        #expect(restoredRequest["cwd"] == nil)
        #expect(restoredRequest["create"] as? Bool == false)
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

    @MainActor
    @Test func runtimeSettingsStringsFollowLanguageAndSearch() {
        let en = SettingsStrings(language: .english)
        let zh = SettingsStrings(language: .simplifiedChinese)
        #expect(en.runtimeTitle == "Persistent terminal sessions")
        #expect(zh.runtimeTitle == "持久终端会话")
        #expect(en.runtimeTitle != zh.runtimeTitle)
        #expect(en.runtimeLocalOpen == "New Local Session")
        #expect(zh.runtimeLocalOpen == "新建本地会话")
        #expect(en.runtimeCloseOnDone.contains("[Beta]"))
        #expect(zh.runtimeCloseOnDone.contains("【Beta】"))
        #expect(SettingsStrings(language: .system, preferredLanguages: ["zh-CN"]).runtimeTitle == zh.runtimeTitle)
        #expect(zh.runtimeDoneGraceCaption.contains("最长保留期限"))
        let entries = SettingsSearchCatalog.entries(strings: zh)
        #expect(entries.contains { $0.settingIDs.contains("sessions.runtimeDetachedHours") && $0.title == zh.runtimeTitle })
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
            Data(split.openRequest(pane: id, restoring: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with:
            Data(split.openRequest(pane: id, restoring: true).utf8)) as? [String: Any])
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
        let fresh = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: false).utf8)) as? [String: Any])
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.openRequest(pane: id, restoring: true).utf8)) as? [String: Any])
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
        settings.runtimeDetachedHours = 2
        settings.runtimeCloseOnAgentDone = true
        settings.runtimeDoneGraceSeconds = 15
        settings.runtimeExpiration = "2030-01-01T00:00:00Z"
        let restored = OhMyGhosttySettings(fileURL: url)
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
