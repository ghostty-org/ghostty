import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct SessionRuntimeLocalIntegrationTests {
    @MainActor
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath:
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime/omgd").path),
        "Requires the bundled Session Runtime helper"))
    func nativeLocalLaunchPreservesConfigurationAndReattachesTheSameProcess() async throws {
        let root = URL(fileURLWithPath: "/tmp/omg-local-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let resources = Bundle.main.resourceURL!.appendingPathComponent("session-runtime")
        let helper = resources.appendingPathComponent("omgd")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let socket = root.appendingPathComponent("relay.sock")
        let result = root.appendingPathComponent("launch.json")
        let stopped = root.appendingPathComponent("stop")
        let script = root.appendingPathComponent("child.py")
        try """
        import json, os, pathlib, select, sys, time
        incoming = bytearray()
        deadline = time.monotonic() + 10
        while incoming.count(b'\\n') < 2 and time.monotonic() < deadline:
            if select.select([0], [], [], .1)[0]:
                chunk = os.read(0, 1024)
                if not chunk:
                    break
                incoming.extend(chunk)
        lines = incoming.decode().splitlines(keepends=True)
        initial = lines[0] if lines else ''
        early = lines[1] if len(lines) > 1 else ''
        result = dict(cwd=os.getcwd(), custom=os.environ.get('OMG_LOCAL_TEST_VALUE'),
                      term=os.environ.get('TERM'), pid=os.getpid(), pgid=os.getpgrp(),
                      tty=os.ttyname(0), initial=initial, early=early,
                      remote=os.environ.get('OMG_RUNTIME_REMOTE'),
                      socket=os.environ.get('OMG_RUNTIME_SOCKET'))
        pathlib.Path(\(String(reflecting: result.path))).write_text(json.dumps(result))
        print('PERSISTENT_LOCAL_FIXTURE', flush=True)
        deadline = time.monotonic() + 30
        while pathlib.Path(\(String(reflecting: root.path))).exists() and not pathlib.Path(\(String(reflecting: stopped.path))).exists() and time.monotonic() < deadline:
            time.sleep(.02)
        """.write(to: script, atomically: true, encoding: .utf8)

        let broker = Process()
        broker.executableURL = helper
        broker.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        broker.arguments = ["host-local", state.path, "--", "/bin/sh", "-i"]
        broker.standardInput = FileHandle.nullDevice
        broker.standardOutput = FileHandle.nullDevice
        broker.standardError = FileHandle.nullDevice
        let relay = Process()
        var first: TerminalController?
        var second: TerminalController?
        var undone: TerminalController?
        defer {
            try? Data().write(to: stopped)
            for controller in [first, second, undone].compactMap({ $0 }) {
                controller.window?.delegate = nil
                controller.window?.close()
            }
            if relay.isRunning { relay.terminate() }
            if broker.isRunning { broker.terminate() }
            // The fixture child has its own bounded lifetime; do not signal
            // a PID loaded from persistent runtime metadata during cleanup.
            try? FileManager.default.removeItem(at: root)
        }
        try broker.run()
        let hostSocket = state.appendingPathComponent("host.sock")
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: hostSocket.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: hostSocket.path))

        let policy = SessionRuntimePolicy(terminateGraceSeconds: 1, hostIdleSeconds: 2)
        let configuration: [String: Any] = [
            "transport": "local", "executable": "/usr/bin/ssh", "arguments": [],
            "cwd": root.path, "local_shell": "/bin/sh", "bundle": resources.path,
            "local_state_directory": state.path,
            "policy": try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)),
        ]
        let configurationURL = root.appendingPathComponent("relay.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: configurationURL)
        relay.executableURL = helper
        relay.environment = broker.environment
        relay.arguments = ["connect", socket.path, configurationURL.path]
        relay.standardInput = FileHandle.nullDevice
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: socket.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: socket.path))

        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        let identity = UUID()
        let descriptor = SessionRuntimeDescriptor(connection: nil, revision: "fixture", policy: policy)
        var config = Ghostty.SurfaceConfiguration()
        let python = try #require(LocalPythonInterpreter.cached())
        config.command = Ghostty.Shell.quote(python.executablePath) + " " + Ghostty.Shell.quote(script.path)
        config.workingDirectory = root.path
        config.initialInput = "once-only\n"
        config.waitAfterCommand = true
        config.environmentVariables["OMG_LOCAL_TEST_VALUE"] = "native command environment"
        // Raw fixture routing bypasses the user's descriptor/cache directories.
        config.environmentVariables["OMG_RUNTIME_LOCAL"] = "1"
        config.environmentVariables["OMG_RUNTIME_SOCKET"] = socket.path
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = try descriptor.openRequest(
            pane: identity, attachExisting: false
        )
        let original: Ghostty.SurfaceView? = Ghostty.SurfaceView(native, baseConfig: config, uuid: identity)
        original?.runtimeDescriptor = descriptor
        original?.surfaceModel?.sendText("early-typed\n")
        first = TerminalController(app, withSurfaceTree: .init(view: try #require(original)))
        _ = first?.window
        for _ in 0..<350 where !FileManager.default.fileExists(atPath: result.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let launched = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any]
        )
        let launchedDirectory = try #require(launched["cwd"] as? String)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: launchedDirectory)
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect(actualDirectory[.systemNumber] as? NSNumber == expectedDirectory[.systemNumber] as? NSNumber)
        #expect(actualDirectory[.systemFileNumber] as? NSNumber == expectedDirectory[.systemFileNumber] as? NSNumber)
        #expect(launched["custom"] as? String == "native command environment")
        #expect(launched["term"] as? String == "xterm-ghostty")
        #expect(launched["initial"] as? String == "once-only\n")
        #expect(launched["early"] as? String == "early-typed\n")
        #expect(launched["remote"] is NSNull)
        #expect(launched["socket"] is NSNull)
        let processGroup = try #require(launched["pgid"] as? Int)
        for _ in 0..<100 where original?.surfaceModel?.foregroundPID != processGroup ||
            original?.runtimeConnectionState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(original?.surfaceModel?.foregroundPID == processGroup)
        #expect(original?.surfaceModel?.ttyName == launched["tty"] as? String)
        #expect(original?.runtimeConnectionState == .ready)
        var inheritsDirectory = true
        let directoryKey = "tab-inherit-working-directory"
        #expect(ghostty_config_get(
            try #require(app.config.config), &inheritsDirectory, directoryKey,
            UInt(directoryKey.utf8.count)
        ))
        let inherited = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(
            try #require(original?.surface), GHOSTTY_SURFACE_CONTEXT_TAB
        ))
        if inheritsDirectory {
            let inheritedDirectory = try #require(inherited.workingDirectory)
            let inheritedAttributes = try FileManager.default.attributesOfItem(atPath: inheritedDirectory)
            #expect(inheritedAttributes[.systemFileNumber] as? NSNumber == expectedDirectory[.systemFileNumber] as? NSNumber)
        } else {
            #expect(inherited.workingDirectory == nil)
        }

        // Keep the Surface alive as Undo does, without adding shared test undo
        // state. Closing must release its attachment without relying on ARC.
        let undoManager = first?.undoManager
        undoManager?.disableUndoRegistration()
        first?.closeWindowImmediately()
        undoManager?.enableUndoRegistration()
        for _ in 0..<100 where original?.surfaceModel?.foregroundPID != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(original?.surfaceModel?.foregroundPID == nil)
        first = nil
        config.initialInput = "must-not-replay\n"
        config.command = "/usr/bin/false"
        config.environmentVariables["OMG_RUNTIME_PANE_ID"] = try descriptor.openRequest(
            pane: identity, attachExisting: true
        )
        let restored = Ghostty.SurfaceView(native, baseConfig: config, uuid: identity)
        restored.runtimeDescriptor = descriptor
        second = TerminalController(app, withSurfaceTree: .init(view: restored))
        _ = second?.window
        for _ in 0..<250 where restored.runtimeConnectionState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(restored.runtimeConnectionState == .ready)
        #expect(restored.surfaceModel?.foregroundPID == processGroup)
        #expect(restored.surfaceModel?.ttyName == launched["tty"] as? String)
        #expect(restored.id == identity)

        let secondUndoManager = second?.undoManager
        secondUndoManager?.disableUndoRegistration()
        second?.closeWindowImmediately()
        secondUndoManager?.enableUndoRegistration()
        second = nil
        let resumedOriginal = try #require(original)
        undone = TerminalController(app, withSurfaceTree: .init(view: resumedOriginal))
        _ = undone?.window
        for _ in 0..<250 where resumedOriginal.surfaceModel?.foregroundPID != processGroup ||
            resumedOriginal.runtimeConnectionState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!resumedOriginal.runtimeAttachmentSuspended)
        #expect(resumedOriginal.runtimeConnectionState == .ready)
        #expect(resumedOriginal.surfaceModel?.foregroundPID == processGroup)
        #expect(resumedOriginal.id == identity)

        try Data().write(to: stopped)
        for _ in 0..<250 where resumedOriginal.runtimeConnectionState != .exited(exitCode: 0) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(resumedOriginal.runtimeConnectionState == .exited(exitCode: 0))
        #expect(resumedOriginal.surfaceModel?.foregroundPID == nil)

        ghostty_surface_close_session(try #require(resumedOriginal.surface))
        resumedOriginal.suspendRuntimeAttachment()
        resumedOriginal.resumeRuntimeAttachment()
        let closedMessage = SettingsStrings(language: OhMyGhosttySettings.shared.language).t(
            "This session was explicitly closed and cannot be reopened.",
            "此会话已被显式关闭，无法重新打开。"
        )
        #expect(resumedOriginal.runtimeAttachmentSuspended)
        #expect(resumedOriginal.runtimeConnectionState == .failed(message: closedMessage, retryable: false))
        #expect(resumedOriginal.runtimeConnectionError == closedMessage)

        #expect(resumedOriginal.surfaceModel?.foregroundPID == nil)
    }
}
