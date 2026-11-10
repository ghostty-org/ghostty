import AppKit
import Foundation
import Testing
@testable import Ghostty

struct NewSessionInheritanceTests {
    private let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                             cache: false, args: ["devbox"], localWorkingDirectory: "/Users/me/src")
    private let conversation = AgentConversationID("conv-123")

    @Test func defaultsPreserveTabDirectoryAndSplitSSHBehavior() {
        #expect(NewSessionInheritance.defaultValue(for: .tab) == .workingDirectory)
        #expect(NewSessionInheritance.defaultValue(for: .split) == .ssh)
        #expect(NewSessionInheritance.allCases.map(\.rawValue) == ["default", "directory", "ssh", "agent", "agentResume"])
        #expect(!NewSessionInheritance.workingDirectory.inheritsSSH)
        #expect(NewSessionInheritance.agentNewSession.inheritsSSH && NewSessionInheritance.agentResume.inheritsSSH)
        #expect(!NewSessionInheritance.ssh.inheritsAgent)
    }

    @Test func nonAgentLevelsNeverBuildAnAgentLaunch() {
        for level in [NewSessionInheritance.defaultDirectory, .workingDirectory, .ssh] {
            #expect(NewSessionInheritance.agentLaunch(
                level: level, agent: .claude, conversationID: conversation, remote: nil,
                localWorkingDirectory: "/tmp", executablePath: "/omg"
            ) == nil)
        }
    }

    @Test func localAgentStartsNewSessionOrResumesTheSameID() throws {
        let fresh = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .claude, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp/project", executablePath: "/omg"
        ))
        #expect(fresh.descriptor.scope == .local)
        #expect(fresh.descriptor.conversationID == nil)
        #expect(fresh.descriptor.workingDirectory == "/tmp/project")
        #expect(!fresh.command.contains("conv-123"))

        let resumed = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .claude, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp/project", executablePath: "/omg"
        ))
        #expect(resumed.descriptor.conversationID == conversation)
        #expect(resumed.command.contains("conv-123"))
    }

    @Test func resumeFallsBackToNewSessionWithoutIDOrResumeSupport() throws {
        let withoutID = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .claude, conversationID: nil, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        #expect(withoutID.descriptor.conversationID == nil)
        // Amp declares no resume arguments.
        let unsupported = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .amp, conversationID: conversation, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        #expect(unsupported.descriptor.conversationID == nil)
        #expect(!unsupported.command.contains("conv-123"))
    }

    @Test func remoteAgentKeepsTheSSHConnectionAndRemoteDirectory() throws {
        let fresh = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .codex, conversationID: conversation, remote: .init(replay: replay, workingDirectory: "/srv/app"),
            localWorkingDirectory: "/Users/me/src", executablePath: "/omg"
        ))
        #expect(fresh.descriptor.scope == .remote)
        #expect(fresh.descriptor.sshReplay == replay)
        #expect(fresh.descriptor.workingDirectory == "/srv/app")
        #expect(fresh.command.contains("'--remote-agent=codex'"))
        #expect(fresh.command.contains("'--remote-working-directory=/srv/app'"))
        #expect(!fresh.command.contains("--remote-agent-session"))

        let resumed = try #require(NewSessionInheritance.agentLaunch(
            level: .agentResume, agent: .codex, conversationID: conversation, remote: .init(replay: replay, workingDirectory: "/srv/app"),
            localWorkingDirectory: "/Users/me/src", executablePath: "/omg"
        ))
        #expect(resumed.command.contains("'--remote-agent-session=conv-123'"))
        #expect(resumed.descriptor.conversationID == conversation)
    }

    @Test func agentConfigurationRunsTheLaunchWithoutRuntimeBackend() throws {
        let launch = try #require(NewSessionInheritance.agentLaunch(
            level: .agentNewSession, agent: .claude, conversationID: nil, remote: nil,
            localWorkingDirectory: "/tmp", executablePath: "/omg"
        ))
        var inherited = Ghostty.SurfaceConfiguration()
        inherited.environmentVariables[SessionRuntimeDescriptor.environmentKey] = "{}"
        inherited.environmentVariables["OMG_RUNTIME_SOCKET"] = "/tmp/sock"
        inherited.initialInput = "ls\n"
        let configuration = NewSessionInheritance.configuration(for: launch, inherited: inherited,
                                                                localWorkingDirectory: "/tmp")
        #expect(configuration.workingDirectory == "/tmp")
        #expect(configuration.command == TerminalController.replaySurvivalCommand(launch.command))
        #expect(configuration.initialInput == nil)
        #expect(configuration.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
        #expect(configuration.environmentVariables["OMG_RUNTIME_SOCKET"] == nil)
    }

    @MainActor
    @Test func splitLevelsFromRemotePaneControlSSHInheritance() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        let descriptor = SessionRuntimeDescriptor(
            connection: try GitSSHConnection(destination: "host", localWorkingDirectory: "/tmp"),
            revision: "test", policy: .init()
        )
        view.runtimeDescriptor = descriptor
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }
        try descriptor.configure(&config)
        config.workingDirectory = "/remote/only"

        let directory = try controller.newSplitLaunch(inherited: config, from: view, level: .workingDirectory)
        #expect(directory.configuration?.workingDirectory == "/tmp")
        #expect(directory.configuration?.command == nil)
        #expect(directory.agentDescriptor == nil)
        #expect(directory.configuration?.environmentVariables["OH_MY_GHOSTTY_SESSION"] ==
            controller.tabSessionID.uuidString)

        let fallback = try controller.newSplitLaunch(inherited: config, from: view, level: .defaultDirectory)
        #expect(fallback.configuration?.workingDirectory == nil)
        #expect(fallback.configuration?.command == nil)

        let tab = controller.newTabLaunch(inherited: config, from: view, level: .defaultDirectory)
        #expect(tab.configuration?.workingDirectory == nil)
        #expect(tab.configuration?.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil)
    }

    @MainActor
    @Test func agentLevelsReuseTheFocusedPaneAgentDescriptor() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let view = Ghostty.SurfaceView(try #require(app.app), baseConfig: config)
        view.pwd = "/tmp/agent-project"
        let controller = TerminalController(app, withSurfaceTree: .init(view: view))
        defer { controller.window?.delegate = nil; controller.window?.close() }

        // Without an Agent, Agent levels fall back to the SSH/directory result.
        let plain = try controller.newSplitLaunch(inherited: config, from: view, level: .agentResume)
        #expect(plain.agentDescriptor == nil)

        controller.adoptAgentResumeDescriptor(
            AgentResumeDescriptor(agent: .claude, conversationID: conversation, scope: .local,
                                  workingDirectory: "/tmp/agent-project"),
            for: view
        )
        let fresh = try controller.newSplitLaunch(inherited: config, from: view, level: .agentNewSession)
        #expect(fresh.agentDescriptor?.agent == .claude)
        #expect(fresh.agentDescriptor?.conversationID == nil)
        #expect(fresh.configuration?.workingDirectory == "/tmp/agent-project")
        #expect(fresh.configuration?.command?.contains("conv-123") == false)

        let resumed = controller.newTabLaunch(inherited: config, from: view, level: .agentResume)
        #expect(resumed.agentDescriptor?.conversationID == conversation)
        #expect(resumed.configuration?.command?.contains("conv-123") == true)
    }

    @MainActor
    @Test func settingsPersistBothEntriesIndependently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-inheritance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.newTabInheritance == .workingDirectory)
        #expect(settings.newSplitInheritance == .ssh)
        settings.newTabInheritance = .defaultDirectory
        settings.newSplitInheritance = .agentResume
        #expect(NewSessionInheritance.current(for: .tab, settings: settings) == .defaultDirectory)
        #expect(NewSessionInheritance.current(for: .split, settings: settings) == .agentResume)
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.newTabInheritance == .defaultDirectory)
        #expect(restored.newSplitInheritance == .agentResume)
        let ids = OhMyGhosttySettings.descriptors.map(\.id)
        #expect(ids.contains("sessions.newTabInheritance") && ids.contains("sessions.newSplitInheritance"))
    }
}
