import SwiftUI

struct AgentIntegrationSettingsView: View {
    let strings: SettingsStrings
    @ObservedObject private var manager = AgentIntegrationManager.shared
    @State private var target = AgentIntegrationManager.localID
    @State private var hosts: [SSHHostConfiguration] = []

    private var snapshot: AgentIntegrationSnapshot { manager.snapshots[target] ?? .init() }
    private var busy: Bool { manager.busy.contains(target) }
    private var local: Bool { target == AgentIntegrationManager.localID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(strings.agentHostLabel, selection: $target) {
                Text(strings.agentLocalHost).tag(AgentIntegrationManager.localID)
                ForEach(hosts, id: \.workspaceID) { host in
                    Text("SSH · \(host.alias)").tag(host.workspaceID)
                }
            }
            Toggle(strings.agentAutomaticCheck, isOn: binding(\.checkAutomatically))
            Picker(strings.agentCheckInterval, selection: binding(\.intervalHours)) {
                Text(strings.agentEveryHour).tag(1)
                Text(strings.agentEveryDay).tag(24)
                Text(strings.agentEveryWeek).tag(168)
            }
            .disabled(!manager.policy(for: target).checkAutomatically)
            Toggle(strings.agentAutomaticHooks, isOn: binding(\.updateHooksAutomatically))
                .disabled(!manager.policy(for: target).checkAutomatically)
            Text(strings.agentUpdateScopeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(strings.agentCheckNow) {
                    let capturedTarget = target
                    Task { await manager.refresh(target: capturedTarget) }
                }
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                if let date = manager.policy(for: target).lastSuccess {
                    Text(strings.agentLastChecked + " " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = snapshot.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(SupportedAgent.allCases) { agent in
                row(agent)
                Divider()
            }
            Text(local ? strings.agentLocalScopeCaption : strings.agentSSHScopeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            var seen: Set<String> = []
            hosts = SSHPlugin.configurations().filter { seen.insert($0.workspaceID).inserted }
        }
        .task(id: target) { await manager.refresh(target: target) }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentIntegrationPolicy, Value>) -> Binding<Value> {
        Binding {
            manager.policy(for: target)[keyPath: keyPath]
        } set: { value in
            var policy = manager.policy(for: target)
            policy[keyPath: keyPath] = value
            manager.setPolicy(policy, for: target)
        }
    }

    private func row(_ agent: SupportedAgent) -> some View {
        let hook = snapshot.hooks[agent]
        let cli = snapshot.cli[agent]
        let detector = agent.definition.hook.kind == .none
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(agent.assetName).resizable().scaledToFit().frame(width: 18, height: 18)
                Text(agent.displayName).fontWeight(.medium)
                Spacer()
                if let cli, cli.updateAvailable {
                    Button(strings.agentUpdateCLI) { perform(agent, cli: true) }
                        .disabled(busy)
                }
            }
            HStack {
                Text(!local && detector ? strings.agentHostDetectorOnly : hookStatus(hook, detector: detector))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if local || !detector {
                    Button(hook?.isInstalled == true ? strings.agentUpdateButton : strings.agentInstallButton) {
                        perform(agent)
                    }
                    .disabled(busy || hook == nil)
                    if hook?.isInstalled == true {
                        Button(strings.agentRemoveButton) { perform(agent, remove: true) }
                            .disabled(busy)
                    }
                }
            }
            HStack {
                Text(cliStatus(cli)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle(strings.agentAutomaticCLI, isOn: automaticCLIBinding(agent))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .disabled(cli?.package == nil && !manager.policy(for: target).automaticallyUpdatedAgents.contains(agent))
                    .help(cli?.package == nil ? strings.agentExternalUpdater : strings.agentAutomaticCLI)
            }
        }
    }

    private func perform(_ agent: SupportedAgent, cli: Bool = false, remove: Bool = false) {
        let capturedTarget = target
        Task { await manager.update(agent, target: capturedTarget, cli: cli, remove: remove) }
    }

    private func automaticCLIBinding(_ agent: SupportedAgent) -> Binding<Bool> {
        Binding {
            manager.policy(for: target).automaticallyUpdatedAgents.contains(agent)
        } set: { enabled in
            var policy = manager.policy(for: target)
            if enabled {
                policy.checkAutomatically = true
                policy.automaticallyUpdatedAgents.insert(agent)
            } else {
                policy.automaticallyUpdatedAgents.remove(agent)
            }
            manager.setPolicy(policy, for: target)
        }
    }

    private func cliStatus(_ cli: AgentCLIInstallation?) -> String {
        guard let cli else { return "CLI · " + strings.agentNotChecked }
        guard cli.path != nil else { return "CLI · " + strings.agentCLIMissing }
        let version = cli.version ?? strings.agentVersionUnknown
        if let latest = cli.latest, cli.updateAvailable { return "CLI · \(version) → \(latest) (npm)" }
        return "CLI · " + version + " · " + (cli.package == nil ? strings.agentExternalUpdater : "npm")
    }

    private func hookStatus(_ state: AgentHookInstallationState?, detector: Bool) -> String {
        guard let state else { return "Hook · " + strings.agentNotChecked }
        switch (detector, state) {
        case (true, .missing): return strings.agentDetectorMissing
        case (true, .updateAvailable): return strings.agentDetectorUpdateRequired
        case (true, .current): return strings.agentDetectorCurrent
        case (false, .missing): return strings.agentHooksMissing
        case (false, .updateAvailable): return strings.agentHooksUpdateRequired
        case (false, .current): return strings.agentHooksCurrent
        }
    }
}
