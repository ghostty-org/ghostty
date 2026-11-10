import Foundation

/// What a new tab or split carries over from the focused pane (#42). Levels
/// are cumulative: an Agent level also keeps the SSH connection, which in turn
/// keeps the (remote) working directory. Ghostty's `tab/split-inherit-working-
/// directory` remain authoritative for the directory itself; when they are off
/// the inherited directory is already absent and the pane uses the default.
enum NewSessionInheritance: String, CaseIterable, Identifiable, Sendable {
    /// Local shell in Ghostty's configured default directory.
    case defaultDirectory = "default"
    /// Local shell in the focused pane's local directory (the pre-SSH
    /// directory when the pane is connected over SSH).
    case workingDirectory = "directory"
    /// Same SSH host and remote directory when the pane is connected.
    case ssh
    /// Start a new conversation of the focused pane's Agent.
    case agentNewSession = "agent"
    /// Resume the focused pane's Agent conversation by ID. Two live processes
    /// then append to one transcript without seeing each other's turns.
    case agentResume

    enum Entry: Sendable { case tab, split }

    var id: String { rawValue }
    var inheritsSSH: Bool { self == .ssh || inheritsAgent }
    var inheritsAgent: Bool { self == .agentNewSession || self == .agentResume }

    /// Defaults preserve the behavior before this setting existed.
    static func defaultValue(for entry: Entry) -> Self {
        switch entry {
        case .tab: .workingDirectory
        case .split: .ssh
        }
    }

    @MainActor
    static func current(for entry: Entry, settings: OhMyGhosttySettings = .shared) -> Self {
        switch entry {
        case .tab: settings.newTabInheritance
        case .split: settings.newSplitInheritance
        }
    }

    /// Host-validated launch for an inherited Agent.
    struct AgentLaunch: Equatable, Sendable {
        let descriptor: AgentResumeDescriptor
        let command: String
    }

    /// An SSH pane's exact replay and its current remote directory.
    struct Remote: Equatable, Sendable {
        let replay: SSHReplayDescriptor
        let workingDirectory: String?
    }

    /// Builds the Agent launch for an Agent level. Remote panes require an
    /// exact SSH replay; resume requires a conversation ID and an Agent with
    /// resume arguments, otherwise a new conversation starts.
    static func agentLaunch(
        level: Self,
        agent: SupportedAgent,
        conversationID: AgentConversationID?,
        remote: Remote?,
        localWorkingDirectory: String?,
        executablePath: String
    ) -> AgentLaunch? {
        guard level.inheritsAgent else { return nil }
        let canResume = level == .agentResume && !agent.definition.resume.resumeArguments.isEmpty
        let resumedID = canResume ? conversationID : nil
        if let remote {
            let descriptor = AgentResumeDescriptor(
                agent: agent, conversationID: resumedID, scope: .remote,
                workingDirectory: remote.workingDirectory, sshReplay: remote.replay
            )
            guard descriptor.isValid,
                  let command = remote.replay.command(
                    executablePath: executablePath,
                    remoteWorkingDirectory: remote.workingDirectory,
                    remoteAgent: agent,
                    conversationID: resumedID
                  ) else { return nil }
            return .init(descriptor: descriptor, command: command)
        }
        let descriptor = AgentResumeDescriptor(
            agent: agent, conversationID: resumedID, scope: .local,
            workingDirectory: localWorkingDirectory
        )
        // The ID comes from the live source pane, as for an explicit history
        // resume, so skip the on-disk store probe.
        guard let command = descriptor.restorationCommand(executablePath: executablePath, verifyLocalStore: false)
        else { return nil }
        return .init(descriptor: descriptor, command: command)
    }

    /// Surface configuration that runs `launch` instead of a login shell. The
    /// survival wrapper leaves a usable local shell after the Agent/SSH exits.
    static func configuration(
        for launch: AgentLaunch,
        inherited config: Ghostty.SurfaceConfiguration?,
        localWorkingDirectory: String?
    ) -> Ghostty.SurfaceConfiguration {
        var result = config ?? .init()
        for key in [SessionRuntimeDescriptor.environmentKey, SessionRuntimeDescriptor.localRuntimeEnvironmentKey,
                    SessionRuntimeDescriptor.attachExistingEnvironmentKey, "OMG_RUNTIME_SOCKET", "OMG_RUNTIME_PANE_ID"] {
            result.environmentVariables.removeValue(forKey: key)
        }
        result.workingDirectory = localWorkingDirectory
        result.command = TerminalController.replaySurvivalCommand(launch.command)
        result.initialInput = nil
        result.waitAfterCommand = false
        return result
    }
}

/// A resolved new-pane configuration plus the Agent descriptor to adopt once
/// the Surface exists, so status and restoration know the launched Agent.
struct InheritedSessionLaunch {
    var configuration: Ghostty.SurfaceConfiguration?
    var agentDescriptor: AgentResumeDescriptor?
}

extension TerminalController {
    /// Applies the configured new-tab inheritance on top of Ghostty's
    /// inherited configuration for `source`.
    func newTabLaunch(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView,
        level requested: NewSessionInheritance? = nil
    ) -> InheritedSessionLaunch {
        let level = requested ?? .current(for: .tab)
        if let launch = inheritedAgentLaunch(level: level, inherited: config, from: source) {
            return launch
        }
        switch level {
        case .defaultDirectory:
            var result = tabConfiguration(inherited: withoutWorkingDirectory(config), from: source)
            result?.workingDirectory = nil
            return .init(configuration: result)
        case .workingDirectory:
            return .init(configuration: tabConfiguration(inherited: config, from: source))
        case .ssh, .agentNewSession, .agentResume:
            guard sourceIsRemote(source),
                  let remote = try? splitConfiguration(inherited: config, from: source) else {
                return .init(configuration: tabConfiguration(inherited: config, from: source))
            }
            return .init(configuration: remote)
        }
    }

    /// Applies the configured split inheritance. Throws when SSH inheritance
    /// is requested but the connection cannot be reproduced.
    func newSplitLaunch(
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView,
        level requested: NewSessionInheritance? = nil
    ) throws -> InheritedSessionLaunch {
        let level = requested ?? .current(for: .split)
        if let launch = inheritedAgentLaunch(level: level, inherited: config, from: source) {
            return .init(configuration: Self.injectingSessionID(tabSessionID, into: launch.configuration),
                         agentDescriptor: launch.agentDescriptor)
        }
        switch level {
        case .defaultDirectory, .workingDirectory:
            let base = level == .defaultDirectory ? withoutWorkingDirectory(config) : config
            guard sourceIsRemote(source) else {
                return .init(configuration: try splitConfiguration(inherited: base, from: source))
            }
            // Same local result as a new tab from an SSH pane: a fresh local
            // shell, never the remote path on this Mac.
            var result = tabConfiguration(inherited: base, from: source) ?? .init()
            if level == .defaultDirectory { result.workingDirectory = nil }
            let settings = OhMyGhosttySettings.shared
            _ = SessionRuntimeConnections.automaticallyConfigureLocalRuntime(
                &result, policy: settings.runtimePolicy, enabled: settings.localRuntimeEnabled
            )
            return .init(configuration: Self.injectingSessionID(tabSessionID, into: result))
        case .ssh, .agentNewSession, .agentResume:
            return .init(configuration: try splitConfiguration(inherited: config, from: source))
        }
    }

    private func withoutWorkingDirectory(_ config: Ghostty.SurfaceConfiguration?) -> Ghostty.SurfaceConfiguration? {
        guard var config else { return nil }
        config.workingDirectory = nil
        return config
    }

    private func sourceIsRemote(_ source: Ghostty.SurfaceView) -> Bool {
        if let runtime = source.runtimeDescriptor, !runtime.isLocal { return true }
        if source.runtimeInlineSession?.descriptor.connection != nil { return true }
        if agentResumeDescriptor(for: source)?.scope == .remote { return true }
        guard let context = paneSessionContext(for: source) else { return false }
        if case .local = context.state { return false }
        return true
    }

    /// nil when the level does not inherit an Agent, the pane runs none, or
    /// its SSH connection cannot be replayed; callers then fall back to the
    /// SSH/directory behavior.
    private func inheritedAgentLaunch(
        level: NewSessionInheritance,
        inherited config: Ghostty.SurfaceConfiguration?,
        from source: Ghostty.SurfaceView
    ) -> InheritedSessionLaunch? {
        guard level.inheritsAgent, let executablePath = Bundle.main.executablePath else { return nil }
        let resume = agentResumeDescriptor(for: source)
        guard let agent = resume?.agent
                ?? agentActivity(for: source).flatMap({ SupportedAgent(rawValue: $0.source) }) else { return nil }
        let context = paneSessionContext(for: source)
        var replay: SSHReplayDescriptor?
        var remoteDirectory: String?
        switch context?.state {
        case .sshConnecting(let ssh)?:
            replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
        case .sshReady(let ssh, let directory)?:
            replay = ssh.replay ?? SSHReplayStore.load(connectionID: ssh.connectionID)
            remoteDirectory = directory
        case .local?, nil:
            if resume?.scope == .remote {
                replay = resume?.sshReplay
                remoteDirectory = resume?.workingDirectory
            }
        }
        if replay == nil, sourceIsRemote(source) { return nil }
        let localDirectory: String? = if replay != nil {
            context?.local.workingDirectory ?? replay?.localWorkingDirectory
        } else {
            source.pwd ?? resume?.workingDirectory ?? config?.workingDirectory
        }
        guard let launch = NewSessionInheritance.agentLaunch(
            level: level,
            agent: agent,
            conversationID: resume?.agent == agent ? resume?.conversationID : nil,
            remote: replay.map { .init(replay: $0, workingDirectory: remoteDirectory ?? resume?.workingDirectory) },
            localWorkingDirectory: localDirectory,
            executablePath: executablePath
        ) else { return nil }
        return .init(
            configuration: NewSessionInheritance.configuration(
                for: launch, inherited: config,
                localWorkingDirectory: localDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            ),
            agentDescriptor: launch.descriptor
        )
    }
}
