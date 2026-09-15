import SwiftUI

struct AgentIntegrationSettingsView: View {
    let strings: SettingsStrings
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject var manager: AgentIntegrationManager = .shared
    @ObservedObject var registry: SSHHostRegistry = .shared
    var exportInstaller: () -> Void = {}
    var exportError: String?
    var refreshOnAppear = true
    @State var target = AgentIntegrationManager.localID
    @State private var showingUpdateSettings = false

    private var snapshot: AgentIntegrationSnapshot { manager.snapshots[target] ?? registry.host(target)?.snapshot ?? .init() }
    private var busy: Bool { manager.busy.contains(target) || registry.pending.contains(target) }
    private var local: Bool { target == AgentIntegrationManager.localID }
    private var hostName: String { local ? strings.agentLocalHost : registry.host(target)?.name ?? strings.agentLocalHost }

    var body: some View {
        Section {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { scheduleSummary; Spacer(minLength: 16); toolbarActions }
                VStack(alignment: .leading, spacing: 10) { scheduleSummary; toolbarActions }
            }
            .padding(.vertical, 4)
            if let error = snapshot.error ?? exportError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            ForEach(SupportedAgent.allCases) { agent in row(agent).padding(.vertical, 6) }
        } header: {
            SSHHostPicker(items: [.init(id: AgentIntegrationManager.localID, title: strings.agentLocalHost)] +
                registry.hosts.map { .init(id: $0.id, title: $0.name + " · " + ($0.endpoint ?? $0.connection.displayEndpoint)) }, selection: $target) {
                HStack(spacing: 8) {
                    Text(strings.agentIntegrationSection)
                    Circle().fill(.secondary).frame(width: 3, height: 3)
                    Text(hostName).textCase(nil)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .fixedSize().help(strings.agentHostLabel)
        }

        .task(id: target) {
            if local {
                if refreshOnAppear { await manager.refresh(target: target) }
            } else {
                manager.loadCached(target: target)
            }
        }
        .onReceive(registry.$hosts.receive(on: RunLoop.main)) { hosts in
            let ids = hosts.map(\.id)
            if !local && !ids.contains(target) { target = AgentIntegrationManager.localID } else if !local { manager.loadCached(target: target) }
        }
    }

    private var scheduleSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(scheduleText, systemImage: "clock.arrow.circlepath").font(.callout)
            if !local && !manager.connectedTargets.contains(target) {
                Text(strings.agentWaitingForConnection).font(.caption).foregroundStyle(.secondary)
            }
            if let date = local ? manager.policy(for: target).lastSuccess : registry.host(target)?.capturedAt {
                Text(strings.agentLastChecked + " " + date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var scheduleText: String {
        let policy = manager.policy(for: target)
        guard policy.checkAutomatically else { return strings.agentManualChecks }
        let interval: String = switch policy.intervalHours {
        case 1: strings.agentEveryHour
        case 168: strings.agentEveryWeek
        default: strings.agentEveryDay
        }
        return interval + " · " + (policy.updateHooksAutomatically ? strings.agentAutomaticHooksShort : strings.agentCheckOnly)
    }

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Button { showingUpdateSettings.toggle() } label: {
                Label(strings.agentUpdateSettings, systemImage: "slider.horizontal.3")
            }
            .popover(isPresented: $showingUpdateSettings, arrowEdge: .bottom) { updateSettings }
            Button(strings.agentCheckNow, systemImage: "arrow.clockwise") {
                let capturedTarget = target
                Task { await manager.refresh(target: capturedTarget) }
            }
            .disabled(busy)
        }
        .controlSize(.small).fixedSize()
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(strings.agentUpdateSettings + " · " + hostName).font(.headline)
            Toggle(strings.agentAutomaticCheck, isOn: binding(\.checkAutomatically))
            Picker(strings.agentCheckInterval, selection: binding(\.intervalHours)) {
                Text(strings.agentEveryHour).tag(1)
                Text(strings.agentEveryDay).tag(24)
                Text(strings.agentEveryWeek).tag(168)
            }
            .disabled(!manager.policy(for: target).checkAutomatically)
            Toggle(strings.agentAutomaticHooks, isOn: binding(\.updateHooksAutomatically))
                .disabled(!manager.policy(for: target).checkAutomatically)
            Text(local ? strings.agentUpdateScopeCaption : strings.agentSSHScopeCaption)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(strings.agentStatusHooksLabel, isOn: $settings.agentStatusHooksEnabled)
            Button(strings.exportSSHInstallerButton, systemImage: "square.and.arrow.up", action: exportInstaller)
        }
        .toggleStyle(.switch).controlSize(.small).padding(20).frame(width: 360)
    }

    private func row(_ agent: SupportedAgent) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                identity(agent).frame(minWidth: 190, alignment: .leading)
                Spacer(minLength: 12)
                cliSummary(agent).frame(width: 200, alignment: .leading)
                actions(agent).frame(width: 180, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { identity(agent); Spacer(minLength: 12); actions(agent) }
                cliSummary(agent).padding(.leading, 36)
            }
        }
    }

    private func identity(_ agent: SupportedAgent) -> some View {
        HStack(spacing: 12) {
            Image(agent.assetName).resizable().scaledToFit().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.displayName).fontWeight(.medium)
                Text(!local && agent.definition.hook.kind == .none ? strings.agentHostDetectorOnly
                     : hookStatus(snapshot.hooks[agent], detector: agent.definition.hook.kind == .none))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func cliSummary(_ agent: SupportedAgent) -> some View {
        HStack(spacing: 6) {
            Text(cliStatus(snapshot.cli[agent])).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let cli = snapshot.cli[agent], cli.path != nil, !cli.canAutomaticallyUpdate {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                    .help(strings.agentExternalUpdater).accessibilityLabel(strings.agentExternalUpdater)
            }
            if manager.policy(for: target).automaticallyUpdatedAgents.contains(agent) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).help(strings.agentAutomaticCLI)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
    }

    private func actions(_ agent: SupportedAgent) -> some View {
        let hook = snapshot.hooks[agent]
        let supportsHooks = local || agent.definition.hook.kind != .none
        return HStack(spacing: 10) {
            if supportsHooks, let hook, hook != .current {
                Button(agent.definition.hook.kind == .none
                       ? (hook.isInstalled ? strings.agentUpdateDetector : strings.agentInstallDetector)
                       : (hook.isInstalled ? strings.agentUpdateHook : strings.agentInstallHook)) { perform(agent) }
            }
            if snapshot.cli[agent]?.needsUpdateCheck == true {
                Button(snapshot.cli[agent]?.updater == "native" ? strings.agentCheckAndUpdateCLI : strings.agentUpdateCLI) { perform(agent, cli: true) }
            }
            Menu {
                Toggle(strings.agentAutomaticCLI, isOn: automaticCLIBinding(agent))
                    .disabled(snapshot.cli[agent]?.canAutomaticallyUpdate != true && !manager.policy(for: target).automaticallyUpdatedAgents.contains(agent))
                if snapshot.cli[agent]?.path != nil && snapshot.cli[agent]?.canAutomaticallyUpdate != true { Text(strings.agentExternalUpdater) }
                if supportsHooks, hook?.isInstalled == true {
                    Divider()
                    Button(agent.definition.hook.kind == .none ? strings.agentReinstallDetector : strings.agentReinstallHook) { perform(agent) }
                    Button(strings.agentRemoveButton, role: .destructive) { perform(agent, remove: true) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(strings.agentActions).accessibilityLabel(agent.displayName + " · " + strings.agentActions)
        }
        .controlSize(.small).disabled(busy).fixedSize()
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
        if let latest = cli.latest, cli.updateAvailable { return "CLI · \(version) → \(latest)" }
        return "CLI · " + version
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
