import SwiftUI

/// The first offer uses cached inventory. After either choice, only a newly
/// discovered CLI can prompt again; stale/missing Hooks are handled in Settings.
enum SSHAgentHookOnboarding: Equatable {
    case checkRequired
    case setupRequired([SupportedAgent])

    static func prompt(snapshot: AgentIntegrationSnapshot?) -> Self? {
        guard let snapshot, snapshot.error == nil, !snapshot.cli.isEmpty else { return .checkRequired }
        let installed = SupportedAgent.allCases.filter {
            $0.definition.hook.kind != .none && snapshot.cli[$0]?.path != nil
        }
        let needed = installed.filter {
            snapshot.hooks[$0] == .missing || snapshot.hooks[$0] == .updateAvailable
        }
        if !needed.isEmpty { return .setupRequired(needed) }
        if installed.contains(where: { snapshot.hooks[$0] == nil }) { return .checkRequired }
        return nil
    }
}

struct SSHAgentHookOnboardingBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var registry: SSHHostRegistry = .shared
    @ObservedObject var manager: AgentIntegrationManager = .shared
    @ObservedObject var settings: OhMyGhosttySettings = .shared
    @State private var sessionRevision: UInt64 = 0
    @State private var hiddenStatus: Set<String> = []
    @State private var startedHere: Set<String> = []

    private var strings: SettingsStrings { .init(language: settings.language) }

    private var connection: GitSSHConnection? {
        _ = sessionRevision
        let surface = controller.focusedSurface ?? controller.surfaceTree.first
        // Managed SSH deploys its runtime hooks as part of connection setup.
        // Further agent choices stay in Settings instead of covering the shell.
        guard surface?.runtimeInlineSession == nil, surface?.runtimeDescriptor?.isLocal != false else { return nil }
        guard let session = controller.paneSessionContext(for: surface),
              case .sshReady = session.state else { return nil }
        return try? GitSSHConnection(session: session)
    }

    var body: some View {
        Group {
            if settings.agentStatusHooksEnabled, let connection {
                let target = registry.targetID(for: connection)
                let prompt = manager.onboardingPrompt(target: target)
                let status = hiddenStatus.contains(target) || !startedHere.contains(target) || prompt != nil
                    ? nil : manager.setupStates[target]
                if prompt != nil || status != nil {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(strings.sshAgentHookTitle + " · " + connection.destination).fontWeight(.medium)
                            if let status {
                                AgentHookSetupStatusView(state: status, operation: manager.operations[target], strings: strings)
                            } else {
                                Text(strings.agentSetupBrief).foregroundStyle(.secondary)
                                if case .setupRequired(let agents) = prompt {
                                    Text(agents.map(\.displayName).joined(separator: " · ")).foregroundStyle(.secondary)
                                }
                            }
                            if status?.isActive != true {
                                HStack(spacing: 10) {
                                    if status == nil || setupFailed(status) {
                                        Button(status == nil ? strings.agentSetupAll : strings.agentRetrySetup) {
                                            setup(connection, installAll: true)
                                        }.buttonStyle(.borderedProminent)
                                    }
                                    Button(strings.agentSetupCustom) { setup(connection, installAll: false) }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            manager.acknowledgeOnboarding(target: target)
                            hiddenStatus.insert(target)
                            manager.dismissSetupResult(target: target)
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help(strings.agentSetupDismiss)
                            .accessibilityLabel(strings.agentSetupDismiss)
                    }
                    .font(.caption).controlSize(.small).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                }
            }
        }
        .onChange(of: connection) { _ in
            startedHere.removeAll()
            hiddenStatus.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalPaneSessionContextsDidChange)) { _ in
            sessionRevision &+= 1
        }
    }

    private func setupFailed(_ state: AgentHookSetupState?) -> Bool {
        if case .finished(let result) = state { return result.error != nil }
        return false
    }

    private func setup(_ connection: GitSSHConnection, installAll: Bool) {
        let target = registry.prepareSetup(connection)
        hiddenStatus.remove(target)
        if installAll { startedHere.insert(target) }
        manager.beginSetup(target: target, installAll: installAll)
        // One click means installation, not navigation and another click.
        if !installAll { SettingsNavigation.openAgentIntegration(target: target) }
    }
}
