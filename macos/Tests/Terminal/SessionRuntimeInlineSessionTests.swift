import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimeInlineSessionTests {
    @Test func historyInlineSplitDoesNotRequireALocalRuntimeDescriptor() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = nil
        let remote = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "cloud", options: ["-J", "jump"],
                localWorkingDirectory: "/tmp"), revision: "old", policy: .init(),
            initialWorkingDirectory: "/srv/original"
        )
        surface.runtimeInlineSession = SessionRuntimeInlineSession(
            descriptor: remote, pane: UUID(), connectionID: "omg-ssh-history-split",
            socket: URL(fileURLWithPath: "/tmp/unused.sock"), helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: try #require(SessionRuntimeInlineSession.currentBootID), workingDirectory: "/srv/current"
        )
        let result = try #require(try controller.splitConfiguration(
            inherited: nil, from: surface, runtimeRevision: "current"
        ))
        let data = try #require(result.environmentVariables[SessionRuntimeDescriptor.environmentKey]?.data(using: .utf8))
        let descriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: data)
        #expect(descriptor.connection == remote.connection)
        #expect(descriptor.initialWorkingDirectory == "/srv/current")
        #expect(descriptor.revision == "current")
        #expect(result.command == nil)
    }

    @Test(arguments: [false, true])
    func historySplitBeforeInlineHandoffReplaysSSHWithoutResumingTheAgent(localRuntime: Bool) throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        config.workingDirectory = "/tmp"
        let controller = TerminalController(app, withBaseConfig: config)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = localRuntime
            ? .init(connection: nil, revision: "old", policy: .init(), localWorkingDirectory: "/tmp") : nil
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
            terminfo: false, cache: false, args: ["-J", "jump", "cloud"])
        controller.adoptAgentResumeDescriptor(.init(agent: .codex,
            conversationID: AgentConversationID("history"), scope: .remote,
            workingDirectory: "/srv/project", sshReplay: replay), for: surface)
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.environmentVariables["KEEP"] = "value"
        inherited.environmentVariables[SessionRuntimeDescriptor.environmentKey] = "stale"
        inherited.environmentVariables["OMG_RUNTIME_PANE_ID"] = UUID().uuidString
        let result = try #require(try controller.splitConfiguration(inherited: inherited, from: surface))
        #expect(result.command?.contains("'+ssh'") == true)
        #expect(result.command?.contains("'--remote-working-directory=/srv/project'") == true)
        #expect(result.command?.contains("'cloud'") == true)
        #expect(result.command?.contains("'jump'") == true)
        #expect(result.command?.contains("--remote-agent") == false)
        #expect(result.environmentVariables["KEEP"] == "value")
        #expect(result.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
        #expect(result.environmentVariables["OMG_RUNTIME_PANE_ID"] == nil)
    }

    @Test(arguments: [0, 1, 2])
    func historyRemoteSplitRejectsMissingOrInvalidReplay(kind: Int) throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let replay: SSHReplayDescriptor? = kind == 0 ? nil : .init(
            version: kind == 1 ? 99 : 1, ssh: "/usr/bin/ssh", forwardEnv: false,
            terminfo: false, cache: false, args: kind == 2 ? ["-V"] : ["cloud"]
        )
        controller.adoptAgentResumeDescriptor(.init(agent: .codex,
            conversationID: AgentConversationID("invalid-replay"), scope: .remote,
            workingDirectory: "/srv/project", sshReplay: replay), for: surface)
        for localRuntime in [false, true] {
            surface.runtimeDescriptor = localRuntime
                ? .init(connection: nil, revision: "local", policy: .init(), localWorkingDirectory: "/tmp") : nil
            #expect(throws: WorkspaceFilesystemError.self) {
                _ = try controller.splitConfiguration(inherited: nil, from: surface)
            }
        }
    }

    @Test func runtimeSnapshotReplacesAgentStateWithoutCompletionActions() async throws {
        let settings = OhMyGhosttySettings.shared
        let previous = (settings.agentStatusHooksEnabled, settings.openQuickInputOnAgentStart,
                        settings.openQuickInputOnAgentComplete)
        settings.agentStatusHooksEnabled = true
        settings.openQuickInputOnAgentStart = false
        settings.openQuickInputOnAgentComplete = true
        defer {
            settings.agentStatusHooksEnabled = previous.0
            settings.openQuickInputOnAgentStart = previous.1
            settings.openQuickInputOnAgentComplete = previous.2
        }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        surface.contextSignal = .init(action: .start, id: "omg-ssh-snapshot-test",
                                      metadata: "type=remote;targethost=cloud;cwd=/srv")
        surface.contextSignal = .init(action: .start, id: "omg-agent-pi-42",
                                      metadata: "type=app;omg_agent=pi;omg_scope=remote;omg_state=working")
        controller.quickInputModel.present(for: surface.id, requestFocus: false)
        controller.quickInputModel.draft = "must remain queued"
        #expect(controller.quickInputModel.enqueueDraft() != nil)
        controller.quickInputModel.dismiss()
        for state in ["needsAttention", "working", "done"] {
            surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
            // Hydration is atomic: do not display partial snapshots.
            let old = controller.agentActivities[surface.id]
            surface.contextSignal = .init(action: .start, id: "omg-agent-omp-43",
                metadata: "type=app;omg_agent=omp;omg_scope=remote;omg_state=\(state)")
            surface.contextSignal = .init(action: .start, id: "omg-inline-password", metadata: "0")
            #expect(controller.agentActivities[surface.id] == old)
            surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
            #expect(controller.agentActivities[surface.id]?.source == "omp")
            #expect(controller.agentActivities[surface.id]?.state.rawValue == state)
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.quickInputModel.state(for: surface.id)?.queue.count == 1)
        #expect(!controller.quickInputModel.isPresented)
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        surface.contextSignal = .init(action: .start, id: "omg-program-status",
                                      metadata: "state=blocked:app=codex:kind=permission")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(controller.agentActivities[surface.id]?.source == "codex")
        #expect(controller.agentActivities[surface.id]?.attentionKind == .permission)
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "begin")
        surface.contextSignal = .init(action: .start, id: "omg-agent-sync", metadata: "end")
        #expect(controller.agentActivities[surface.id] == nil)
        #expect(controller.agentResumeDescriptor(for: surface) == nil)
    }

    @Test func runtimeDirectoryUpdatesDoNotClearRemoteCodexStatus() throws {
        let settings = OhMyGhosttySettings.shared
        let enabled = settings.agentStatusHooksEnabled
        settings.agentStatusHooksEnabled = true
        defer { settings.agentStatusHooksEnabled = enabled }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        let remote = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "cloud", localWorkingDirectory: "/tmp"),
            revision: "remote", policy: .init())
        let inline = SessionRuntimeInlineSession(
            descriptor: remote, pane: UUID(), connectionID: "omg-ssh-inline-status",
            socket: URL(fileURLWithPath: "/tmp/not-used.sock"),
            helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: try #require(SessionRuntimeInlineSession.currentBootID),
            workingDirectory: "/srv/project")
        surface.runtimeInlineSession = inline
        let metadata = try #require(inline.restorationSignal)
        surface.contextSignal = metadata
        for state in ["idle", "working", "done"] {
            surface.contextSignal = .init(action: .start, id: "omg-agent-codex-42",
                metadata: "type=app;omg_agent=codex;omg_scope=remote;omg_state=\(state)")
            #expect(controller.agentActivities[surface.id]?.state.rawValue == state)
            // The runtime sends cwd with attachment/password metadata, even
            // while Codex owns the foreground. It is not a shell prompt.
            surface.contextSignal = metadata
            #expect(controller.agentActivities[surface.id]?.state.rawValue == state)
        }
        surface.contextSignal = .init(action: .end, id: inline.connectionID, metadata: "status=0;cwd=/tmp")
        #expect(controller.agentActivities[surface.id] == nil)
    }

    @Test func inlineSessionSplitsRemotelyButNewTabsKeepTheLocalDirectory() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let controller = TerminalController(app, withBaseConfig: config)
        _ = controller.window
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.surfaceTree.first)
        surface.runtimeDescriptor = .init(connection: nil, revision: "local", policy: .init(),
                                          localWorkingDirectory: "/tmp/local")
        let remote = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp/local"),
            revision: "remote", policy: .init(), initialWorkingDirectory: "/srv/initial")
        let inline = SessionRuntimeInlineSession(
            descriptor: remote, pane: UUID(), connectionID: "omg-ssh-inline-fixture",
            socket: URL(fileURLWithPath: "/tmp/not-used.sock"),
            helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: try #require(SessionRuntimeInlineSession.currentBootID),
            workingDirectory: "/srv/project")
        surface.runtimeInlineSession = inline
        surface.pwd = "/srv/not-a-local-directory"
        #expect(TerminalWorkspaceSessionState.Pane(surface).pwd == "/tmp/local")
        surface.contextSignal = .init(action: .start, id: "omg-inline-password", metadata: "1")
        #expect(surface.passwordInput)
        surface.contextSignal = .init(action: .start, id: "omg-inline-password", metadata: "0")
        #expect(!surface.passwordInput)
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.workingDirectory = "/srv/not-a-local-directory"
        let split = try #require(try controller.splitConfiguration(
            inherited: inherited, from: surface, runtimeRevision: "current"))
        let data = try #require(split.environmentVariables[SessionRuntimeDescriptor.environmentKey]?.data(using: .utf8))
        let splitDescriptor = try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: data)
        #expect(splitDescriptor.connection == remote.connection)
        #expect(splitDescriptor.initialWorkingDirectory == "/srv/project")
        #expect(splitDescriptor.revision == "current")
        #expect(split.command == nil)
        #expect(split.waitAfterCommand == false)
        let tab = try #require(controller.tabConfiguration(
            inherited: inherited, from: surface, runtimeRevision: "current", localRuntimeEnabled: true))
        #expect(tab.workingDirectory == "/tmp/local")
        let tabData = try #require(tab.environmentVariables[SessionRuntimeDescriptor.environmentKey]?.data(using: .utf8))
        #expect(try JSONDecoder().decode(SessionRuntimeDescriptor.self, from: tabData).isLocal)
        #expect(SessionRuntimeLibrary.focusExisting(paneID: inline.pane, in: [controller]))
        #expect(controller.focusedSurface === surface)
        #expect(SessionRuntimeClose.close(.leaf(view: surface)))
        let closes = SessionRuntimeCloseQueue.shared.requests.filter { $0.pane == surface.id || $0.pane == inline.pane }
        #expect(Set(closes.map(\.pane)) == Set([surface.id, inline.pane]))
        #expect(closes.first { $0.pane == inline.pane }?.descriptor == remote)
        for request in closes { try SessionRuntimeCloseQueue.shared.acknowledge(request) }
    }

    @Test func restoredInlineContextKeepsRemoteIdentityAndRejectsAnEarlierBoot() throws {
        let descriptor = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "user@host", localWorkingDirectory: "/tmp/local"),
            revision: "remote", policy: .init())
        let boot = try #require(SessionRuntimeInlineSession.currentBootID)
        let session = SessionRuntimeInlineSession(
            descriptor: descriptor, pane: UUID(), connectionID: "omg-ssh-inline-fixture",
            socket: URL(fileURLWithPath: "/tmp/not-used.sock"), helperPID: ProcessInfo.processInfo.processIdentifier,
            bootID: boot, workingDirectory: "/srv/space name")
        var context = PaneSessionContext(workingDirectory: "/tmp/local", terminalTitle: "local")
        context.apply(try #require(session.restorationSignal),
                      currentWorkingDirectory: "/tmp/local", currentTerminalTitle: "local",
                      sshReplay: session.replay)
        #expect(context.workingDirectory == "/srv/space name")
        #expect(context.remoteTabBreadcrumb?.host == "host")
        if case .sshReady(let ssh, _) = context.state { #expect(ssh.transferTarget == "user@host") }
        context.apply(.init(action: .end, id: session.connectionID, metadata: "status=255;cwd=/tmp/local"),
                      currentWorkingDirectory: "/srv/space name", currentTerminalTitle: "remote")
        #expect(!context.offersSSHRecovery)
        #expect(context.workingDirectory == "/tmp/local")
        #expect(session.isRunningInThisBoot)
        let stale = SessionRuntimeInlineSession(
            descriptor: descriptor, pane: session.pane, connectionID: session.connectionID,
            socket: session.socket, helperPID: session.helperPID, bootID: UUID())
        #expect(!stale.isRunningInThisBoot)
    }
}
