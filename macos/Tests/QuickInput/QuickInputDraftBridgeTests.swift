import AppKit
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct QuickInputDraftBridgeTests {
    @Test func unresponsiveAgentCannotDelayComposerPresentation() throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let previous = settings.quickInputImportShortcut
        settings.quickInputImportShortcut = "auto"
        defer { settings.quickInputImportShortcut = previous }
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/sleep 30"
        configuration.workingDirectory = "/tmp"
        let controller = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: .vertical)
        defer {
            controller.dismissQuickInput()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.focusedSurface)
        controller.adoptAgentResumeDescriptor(
            AgentResumeDescriptor(agent: .pi, scope: .local, workingDirectory: "/tmp"), for: surface
        )
        controller.quickInputModel.dismiss()
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.targetSurfaceID == surface.id)
        controller.toggleQuickInput()
        #expect(!controller.quickInputModel.isPresented)
    }

    @Test func terminalEditorShortcutActuallyImportsDraft() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("agent.py")
        let ready = root.appendingPathComponent("ready")
        try #"""
        import os, tty, subprocess
        from pathlib import Path
        tty.setraw(0)
        # Pi requests Kitty's disambiguated keyboard encoding.
        os.write(1, b"\x1b[>1u")
        root = Path(__file__).parent
        (root / "ready").touch()
        while True:
            data = os.read(0, 64)
            (root / "keys").write_bytes(data)
            if b"\x1b[103;5u" in data:
                draft = root / "draft"
                draft.write_text("中文 agent draft\nsecond line")
                subprocess.run([os.environ["EDITOR"], str(draft)], check=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/usr/bin/python3 \(script.path)"
        let controller = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: .vertical)
        defer {
            controller.dismissQuickInput()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.focusedSurface)
        controller.adoptAgentResumeDescriptor(
            AgentResumeDescriptor(agent: .pi, scope: .local, workingDirectory: "/tmp"), for: surface
        )
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        controller.quickInputModel.dismiss()
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        for _ in 0..<50 {
            if !controller.quickInputModel.draft.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.quickInputModel.draft == "中文 agent draft\nsecond line")
        #expect(try String(contentsOf: root.appendingPathComponent("keys"), encoding: .utf8).contains("\u{1b}[103;5u"))
    }

    @Test(arguments: [false, true])
    func sshComposerDoesNotLaunchRemoteEditor(ready: Bool) async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        let settings = OhMyGhosttySettings.shared
        let previous = settings.quickInputImportShortcut
        // Even an explicitly configured shortcut must not use a local bridge remotely.
        settings.quickInputImportShortcut = "control+g"
        defer { settings.quickInputImportShortcut = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("remote.py")
        try #"""
        import os, tty
        from pathlib import Path
        tty.setraw(0)
        root = Path(__file__).parent
        (root / "ready").touch()
        while True:
            data = os.read(0, 64)
            (root / "keys").write_bytes(data)
        """#.write(to: script, atomically: true, encoding: .utf8)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/usr/bin/python3 \(script.path)"
        let controller = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: .vertical)
        defer {
            controller.dismissQuickInput()
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.focusedSurface)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        var context = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "ssh")
        context.observeForegroundSSH(
            alias: "example", transferTarget: "user@example", processGroupID: 123,
            currentWorkingDirectory: "/tmp", currentTerminalTitle: "ssh",
            remoteWorkingDirectory: ready ? "/home/user" : nil
        )
        controller.restorePaneSessionState(.init(
            context: context, activity: nil, resumeDescriptor: nil, resumeContextID: nil,
            reducer: nil, typedHookContextID: nil, observedForegroundProcessID: nil,
            detectedAgent: nil, screenSignature: nil, screenStableTicks: nil, quickInputState: nil
        ), for: surface.id)
        controller.quickInputModel.dismiss()
        controller.toggleQuickInput()
        #expect(controller.quickInputModel.isPresented)
        #expect(controller.quickInputModel.targetSurfaceID == surface.id)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("keys").path))
    }

    @Test func agentSnapshotDoesNotAppendExistingPrefix() {
        let model = AgentQuickInputModel()
        model.present(for: UUID())
        model.draft = "你好\ncontinued"
        let focus = model.focusRequestID
        for snapshot in ["", "你好", "你好\ncontinued"] {
            model.importAgentDraft(snapshot)
            #expect(model.draft == "你好\ncontinued")
            #expect(model.focusRequestID == focus)
        }
        model.importAgentDraft("different")
        #expect(model.draft == "你好\ncontinued\ndifferent")
        model.draft = ""
        model.importAgentDraft("first\nsecond")
        #expect(model.draft == "first\nsecond")
    }

    @Test func agentSnapshotDoesNotAppendExistingSuffix() {
        let model = AgentQuickInputModel()
        model.present(for: UUID())
        model.draft = "123456\n1234567"
        let focus = model.focusRequestID
        model.importAgentDraft("1234567")
        #expect(model.draft == "123456\n1234567")
        #expect(model.focusRequestID == focus)
        model.draft = "prefix 1234567 middle"
        model.importAgentDraft("1234567")
        #expect(model.draft == "prefix 1234567 middle\n1234567")
    }

    @Test func remoteSnapshotIsRemovedAfterDeadline() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = "/bin/sleep 30"
        let controller = TerminalController(app.ghostty, withBaseConfig: configuration, tabLayout: .vertical)
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }
        let surface = try #require(controller.focusedSurface)
        controller.showWindow(nil)
        let parent = try #require(surface.superview)
        let count = parent.subviews.count
        let snapshot = QuickInputTerminalSnapshot(surface: surface, maximumDuration: .milliseconds(200))
        #expect(parent.subviews.count == count + 1)
        #expect(parent.subviews.last is NSImageView)
        try await Task.sleep(for: .milliseconds(350))
        #expect(parent.subviews.count == count)
        snapshot.remove()
        #expect(parent.subviews.count == count)
    }

    @Test func draftSnapshotIsInvalidatedByPaneResize() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controller = TerminalController(app, withBaseConfig: config)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(50))
        let surface = try #require(controller.focusedSurface)
        let parent = try #require(surface.superview)
        let count = parent.subviews.count
        let snapshot = QuickInputTerminalSnapshot(surface: surface)
        #expect(parent.subviews.count == count + 1)
        surface.setFrameSize(NSSize(width: surface.frame.width, height: surface.frame.height - 30))
        #expect(parent.subviews.count == count)
        snapshot.remove()
    }

    @Test func sendingImportedPrefixAppendsOnlySuffixAndRecordsFullMessage() {
        let model = AgentQuickInputModel()
        let pane = UUID()
        model.present(for: pane)
        model.importAgentDraft("你好\noriginal")
        #expect(model.submissionSuffix("你好\noriginal，继续", for: pane) == "，继续")
        #expect(model.submissionSuffix("你好\noriginal", for: pane) == "")
        #expect(model.submissionSuffix("changed prefix", for: pane) == nil)
        #expect(model.submissionSuffix("independent", for: UUID()) == "independent")
        model.didSubmitAgentDraft(for: pane)
        #expect(model.submissionSuffix("next message", for: pane) == "next message")
        model.importAgentDraft("old")
        model.importAgentDraft("")
        #expect(model.submissionSuffix("after clearing agent", for: pane) == "after clearing agent")
    }

    @Test func automaticallySelectsKnownAndGenericShortcuts() {
        for agent in [SupportedAgent.pi, .codex, .claude] {
            #expect(QuickInputDraftBridge.shortcut(setting: "auto", agent: agent) == "control+g")
        }
        #expect(QuickInputDraftBridge.shortcut(setting: "auto", agent: nil) == "control+g")
        let opencode = QuickInputDraftBridge.shortcut(setting: "auto", agent: .opencode)
        #expect(opencode == "control+x,e")
        #expect(QuickInputDraftBridge.keys(opencode)?.last?.text == "e")
        #expect(QuickInputDraftBridge.keys(opencode)?.last?.mods.isEmpty == true)
        #expect(QuickInputDraftBridge.shortcut(setting: "", agent: .pi).isEmpty)
        #expect(QuickInputDraftBridge.shortcut(setting: "control+x,control+e", agent: .pi) == "control+x,control+e")
    }

    @Test func sharedImportPolicyCoversEveryAgentAndCustomBindings() {
        for agent in SupportedAgent.allCases {
            let keys = QuickInputDraftBridge.importKeys(setting: "auto", agent: agent, hasAgentActivity: false)
            #expect(keys != nil)
            #expect(keys?.map(\.key) == (agent == .opencode ? [.x, .e] : [.g]))
            #expect(QuickInputDraftBridge.importKeys(setting: "", agent: agent, hasAgentActivity: true) == nil)
        }
        #expect(QuickInputDraftBridge.importKeys(setting: "auto", agent: nil, hasAgentActivity: false) == nil)
        #expect(QuickInputDraftBridge.importKeys(setting: "auto", agent: nil, hasAgentActivity: true)?.first?.key == .g)
        #expect(QuickInputDraftBridge.importKeys(
            setting: "control+x,control+e", agent: nil, hasAgentActivity: false
        )?.map(\.key) == [.x, .e])
    }

    @Test func remoteDraftResponsePreservesTextAndRejectsInvalidPayloads() throws {
        let text = "中文 draft\nsecond line\n"
        let valid = GitExecutionResult(exitCode: 0,
                                       stdout: Data(("login banner\nOMG_REMOTE_DRAFT_V1\n" + text).utf8),
                                       stderr: Data())
        #expect(try QuickInputRemoteDraftBridge.decode(valid) == text)
        for payload in [Data("missing marker".utf8),
                        Data("OMG_REMOTE_DRAFT_V1\n\0".utf8),
                        Data("OMG_REMOTE_DRAFT_V1\n".utf8) + Data([0xff]),
                        Data("OMG_REMOTE_DRAFT_V1\n".utf8) + Data(repeating: 120, count: 1_048_577)] {
            #expect(throws: (any Error).self) {
                try QuickInputRemoteDraftBridge.decode(.init(exitCode: 0, stdout: payload, stderr: Data()))
            }
        }
        #expect(throws: (any Error).self) {
            try QuickInputRemoteDraftBridge.decode(.init(exitCode: 1, stdout: valid.stdout, stderr: Data()))
        }
    }

    @Test func parsesGenericEditorShortcuts() throws {
        let keys = try #require(QuickInputDraftBridge.keys("control+x, control+e"))
        #expect(keys.map(\.key) == [.x, .e])
        #expect(keys.allSatisfy { $0.mods == .ctrl })
        #expect(QuickInputDraftBridge.keys("control+1")?.first?.key == .digit1)
        for invalid in ["", "g", "command+g", "control+g,", "control+;", "control+g,control+g,control+g,control+g,control+g"] {
            #expect(QuickInputDraftBridge.keys(invalid) == nil)
        }
    }

    @Test func helperCopiesCompleteDraftWithoutChangingAgentFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try #require(LocalPythonInterpreter.cached())
        let pythonAlias = root.appendingPathComponent("python with ' spaces")
        try FileManager.default.createSymbolicLink(atPath: pythonAlias.path,
                                                  withDestinationPath: python.executablePath)
        let helper = try QuickInputDraftBridge.installHelper(
            in: root.appendingPathComponent("bridge with ' spaces"),
            pythonExecutable: pythonAlias.path
        )
        let surface = UUID().uuidString
        let identifier = UUID().uuidString
        let request = root.appendingPathComponent("\(surface).request")
        let draft = root.appendingPathComponent("agent draft.txt")
        let text = "中文 🐱\nsecond line\n\n"
        try text.write(to: draft, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: [
            "id": identifier, "expires": Date().timeIntervalSince1970 + 30,
        ]).write(to: request)
        let process = Process()
        process.executableURL = helper
        process.arguments = [draft.path]
        process.environment = [
            "OMG_QUICK_INPUT_BRIDGE": root.path,
            "OMG_QUICK_INPUT_SURFACE": surface,
            "SDKROOT": "/nonexistent/omg-test-sdk",
            "DEVELOPER_DIR": "/nonexistent/omg-test-developer",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: draft, encoding: .utf8) == text)
        #expect(try String(contentsOf: root.appendingPathComponent("\(identifier).response"), encoding: .utf8) == text)
        // A helper inherited by a different pane must use its own request.
        let otherPane = Process()
        otherPane.executableURL = process.executableURL
        otherPane.arguments = process.arguments
        otherPane.environment = process.environment
        otherPane.environment?["OMG_QUICK_INPUT_SURFACE"] = UUID().uuidString
        otherPane.environment?["OMG_QUICK_INPUT_ORIGINAL_EDITOR"] = "/usr/bin/true"
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(identifier).response"))
        try otherPane.run()
        otherPane.waitUntilExit()
        #expect(otherPane.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(identifier).response").path))
    }

    @Test func helperDelegatesOrdinaryEditingToOriginalEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try #require(LocalPythonInterpreter.cached())
        let helper = try QuickInputDraftBridge.installHelper(
            in: root, pythonExecutable: python.executablePath
        )
        let draft = root.appendingPathComponent("file with spaces.txt")
        let process = Process()
        process.executableURL = helper
        process.arguments = [draft.path]
        process.environment = [
            "OMG_QUICK_INPUT_BRIDGE": root.path,
            "OMG_QUICK_INPUT_SURFACE": UUID().uuidString,
            "OMG_QUICK_INPUT_ORIGINAL_EDITOR": "/usr/bin/touch",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: draft.path))
    }

    @Test func missingPythonKeepsOriginalEditorAndDisablesDraftRequests() {
        let settings = OhMyGhosttySettings.shared
        let previous = settings.quickInputImportShortcut
        settings.quickInputImportShortcut = "auto"
        defer { settings.quickInputImportShortcut = previous }
        let bridge = QuickInputDraftBridge(pythonExecutable: { nil })
        let surfaceID = UUID()
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.environmentVariables = ["EDITOR": "/usr/bin/vi", "VISUAL": "/usr/bin/vi"]
        let expected = configuration.environmentVariables
        bridge.configure(&configuration, surfaceID: surfaceID)
        #expect(configuration.environmentVariables == expected)
        #expect(throws: CocoaError.self) { try bridge.begin(surfaceID: surfaceID) }
    }
}
