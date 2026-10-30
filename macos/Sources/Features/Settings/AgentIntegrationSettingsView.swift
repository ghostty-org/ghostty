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
    @State var expanded: Set<SupportedAgent> = []
    @State private var showingSchedule = false
    @State private var showingHelp = false

    private var snapshot: AgentIntegrationSnapshot { manager.snapshot(for: target) ?? .init() }
    private var busy: Bool { manager.busy.contains(target) || registry.isCollecting(target) || manager.setupStates[target]?.isActive == true }
    private var local: Bool { target == AgentIntegrationManager.localID }
    private var hostName: String { local ? strings.agentLocalHost : registry.host(target)?.name ?? target }
    private var policy: AgentIntegrationPolicy { manager.policy(for: target) }
    private var candidates: [SupportedAgent] { AgentIntegrationManager.hookSetupCandidates(snapshot: snapshot, local: local) }
    private var agents: [SupportedAgent] {
        SupportedAgent.allCases.filter { snapshot.cli[$0]?.path != nil } +
            SupportedAgent.allCases.filter { snapshot.cli[$0]?.path == nil }
    }

    var body: some View {
        Section {
            hostPicker
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    setupAction(setupLabel, symbol: candidates.isEmpty && !snapshot.cli.isEmpty ? "checkmark.circle" : "puzzlepiece.extension",
                                enabled: !busy && (snapshot.cli.isEmpty || !candidates.isEmpty)) {
                        manager.beginSetup(target: target, installAll: true)
                    }
                    Divider().frame(height: 18).padding(.horizontal, 8)
                    setupAction(strings.agentCheckNow, symbol: "arrow.clockwise", enabled: !busy) { refresh() }
                }
                if let state = manager.setupStates[target], state.isActive {
                    AgentHookSetupStatusView(state: state, operation: manager.operations[target], strings: strings)
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                } else if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(operationText).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 4)
            if snapshot.hooksChanged == true {
                Label(strings.agentRestartBrief, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = snapshot.error ?? registry.errors[target] ?? exportError {
                AgentIntegrationErrorView(title: strings.agentSetupCheckFailed, message: error, strings: strings)
            }
        } header: {
            HStack {
                Text(strings.agentIntegrationSection)
                Spacer()
                Button { showingHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(strings.agentIntegrationSection)
                .popover(isPresented: $showingHelp) { helpContent }
            }
        }
        .onAppear { selectRequestedTarget() }
        .onReceive(NotificationCenter.default.publisher(for: .omgSelectAgentIntegrationTarget)) { _ in selectRequestedTarget() }
        .onChange(of: target) { _ in expanded.removeAll() }
        .task(id: target) {
            if !local { manager.loadCached(target: target) }
            // Cached hosts switch immediately. Discovery is separate from version checks.
            if refreshOnAppear, snapshot.cli.isEmpty, !busy { refresh(checkLatest: false) }
        }
        .onReceive(registry.$hosts.receive(on: RunLoop.main)) { hosts in
            if !local && !hosts.contains(where: { $0.id == target }) {
                target = AgentIntegrationManager.localID
            } else if !local { manager.loadCached(target: target) }
        }

        Section {
            maintenanceRow(title: strings.agentAutoHooksBrief, subtitle: strings.agentHooksUpdateScope,
                           symbol: "puzzlepiece.extension", selection: automaticHooksBinding)
            maintenanceRow(title: strings.agentAutoCLIsBrief, subtitle: strings.agentCLIUpdateScope,
                           symbol: "terminal", selection: unifiedCLIBinding)
            Button { showingSchedule.toggle() } label: {
                HStack(spacing: 14) {
                    maintenanceIcon("clock.arrow.circlepath")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings.agentScheduleTitle).fontWeight(.medium)
                        Text(scheduleSummary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        .frame(width: 22, height: 28)
                }
                .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingSchedule) { scheduleContent }
            if let error = snapshot.cliError {
                AgentIntegrationErrorView(title: strings.agentCLIUpdateFailed, message: error, strings: strings, cli: true)
            }
        } header: {
            Text(strings.agentUpdateSettings + " · " + hostName)
        }

        Section {
            ForEach(agents) { agent in
                VStack(spacing: 0) {
                    row(agent).padding(.vertical, 8)
                    if expanded.contains(agent) { details(agent).padding(.bottom, 10) }
                }
            }
        } header: {
            Text(strings.agentListTitle)
        }
    }

    private var setupLabel: String {
        guard !snapshot.cli.isEmpty, candidates.isEmpty else { return strings.agentSetupAll }
        let supported = snapshot.cli.contains { $0.value.path != nil && (local || $0.key.definition.hook.kind != .none) }
        return supported ? strings.agentAlreadySetup : strings.agentSetupNoneFound
    }

    private func setupAction(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(title).font(.callout).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentSetupActionStyle())
        .disabled(!enabled)
    }

    private var hostPicker: some View {
        SSHHostPicker(
            items: [
                .init(id: AgentIntegrationManager.localID, title: strings.agentLocalHost,
                      detail: strings.agentLocalMachine, symbol: "desktopcomputer")
            ] + registry.hosts.map { host in
                .init(
                    id: host.id,
                    title: host.name,
                    detail: host.endpoint ?? host.connection.displayEndpoint,
                    status: registry.isConnected(host.id) ? strings.sshConnected : strings.agentSSHNotConnected
                )
            },
            selection: $target,
            accessibilityLabel: strings.agentHostLabel,
            height: 56
        )
        .frame(maxWidth: .infinity)
        .help(strings.agentHostLabel)
    }

    private func row(_ agent: SupportedAgent) -> some View {
        HStack(spacing: 14) {
            Button {
                if !expanded.insert(agent).inserted { expanded.remove(agent) }
            } label: {
                HStack(spacing: 14) {
                    Image(agent.assetName).resizable().scaledToFit().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent.displayName).fontWeight(.medium).lineLimit(1)
                        Text(snapshot.cli[agent]?.path ?? (snapshot.cli[agent] == nil ? strings.agentNotChecked : strings.agentCLIMissing))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            if snapshot.hooks[agent] == .updateAvailable {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).help(strings.agentHooksUpdateRequired)
            }
            if local || agent.definition.hook.kind != .none {
                Text(hookLabel(agent)).font(.caption).foregroundStyle(.secondary).fixedSize()
                Toggle(agent.displayName, isOn: hookBinding(agent))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                    .disabled(busy || snapshot.hooks[agent] == nil ||
                        (snapshot.cli[agent]?.path == nil && snapshot.hooks[agent]?.isInstalled != true))
                    .accessibilityLabel(agent.displayName + " · " + strings.agentIntegrationSection)
            } else {
                Text(strings.agentHostDetectorOnly).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 100)
            }
            Button {
                if !expanded.insert(agent).inserted { expanded.remove(agent) }
            } label: {
                Image(systemName: expanded.contains(agent) ? "chevron.down" : "chevron.right").frame(width: 22, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(agent.displayName + " · " + strings.agentActions)
        }
    }

    private func details(_ agent: SupportedAgent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(strings.agentStatusIntegration).fontWeight(.medium)
                    Text(hookStatus(agent)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if local || agent.definition.hook.kind != .none, let hook = snapshot.hooks[agent] {
                    Button(hookActionLabel(agent, state: hook)) {
                        perform(agent)
                    }.disabled(snapshot.cli[agent]?.path == nil && !hook.isInstalled)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent CLI").fontWeight(.medium)
                    Text(cliStatus(snapshot.cli[agent])).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.cli[agent]?.canAutomaticallyUpdate == true {
                    Button(strings.agentCheckAndUpdateCLI) { perform(agent, cli: true) }
                }
            }
            if let cli = snapshot.cli[agent], cli.path != nil, !cli.canAutomaticallyUpdate {
                Text(strings.agentExternalUpdater).font(.caption).foregroundStyle(.secondary)
            }
            if agent.definition.hook.kind == .none {
                Text(strings.agentDetectorUpdateExplanation).font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small).disabled(busy).padding(.leading, 46)
    }

    private func maintenanceIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 32, height: 32)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private func maintenanceRow(title: String, subtitle: String, symbol: String, selection: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            maintenanceIcon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: selection).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }.padding(.vertical, 8)
    }

    private var automaticHooksBinding: Binding<Bool> {
        Binding(get: { policy.updateHooksAutomatically }, set: {
            var value = policy
            value.updateHooksAutomatically = $0
            if $0 { value.checkAutomatically = true }
            manager.setPolicy(value, for: target)
        })
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.agentUpdateSettings + " · " + hostName).font(.headline)
            Toggle(strings.agentMaintenance, isOn: binding(\.checkAutomatically))
            Toggle(strings.agentCheckOnConnection, isOn: Binding(get: { policy.checkOnConnection == true }, set: {
                var value = policy; value.checkOnConnection = $0; manager.setPolicy(value, for: target)
            }))
            OMGSettingsPicker(title: strings.agentCheckInterval, selection: binding(\.intervalHours),
                              options: [.init(1, strings.agentEveryHour), .init(24, strings.agentEveryDay), .init(168, strings.agentEveryWeek)], width: 150)
            Text(strings.agentScheduleBrief).font(.caption).foregroundStyle(.secondary)
            if policy.updatesCLIs && policy.updateAllCLIsAutomatically != true {
                Text(strings.agentLegacyCLIScope).font(.caption).foregroundStyle(.secondary)
            }
            if let date = policy.lastMaintenance {
                Text(strings.agentLastMaintenance + " " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                Label(policy.lastMaintenanceError == nil ? strings.agentMaintenanceOK : strings.agentMaintenanceFailed,
                      systemImage: policy.lastMaintenanceError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(policy.lastMaintenanceError == nil ? Color.secondary : .orange)
                    .help(policy.lastMaintenanceError ?? strings.agentMaintenanceOK)
            }
            if let date = policy.lastSuccess {
                Text(strings.agentLastChecked + " " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
        }
        .toggleStyle(OMGSettingsToggleStyle()).buttonStyle(OMGSettingsButtonStyle())
        .controlSize(.small).padding(20).frame(width: 370)
    }

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.agentIntegrationSection).font(.headline)
            Text(local ? strings.agentIntegrationExplanation : strings.sshAgentHookExplanation)
            Toggle(strings.agentStatusHooksLabel, isOn: $settings.agentStatusHooksEnabled)
            Button(strings.exportSSHInstallerButton, systemImage: "square.and.arrow.up", action: exportInstaller)
        }.font(.callout).buttonStyle(OMGSettingsButtonStyle())
            .toggleStyle(OMGSettingsToggleStyle()).padding(20).frame(width: 380)
    }

    private var scheduleSummary: String {
        guard policy.checkAutomatically else { return strings.agentManualChecks }
        if !local && !registry.isConnected(target) { return strings.agentWaitingForConnection }
        let interval = policy.intervalHours == 1 ? strings.agentEveryHour :
            policy.intervalHours == 168 ? strings.agentEveryWeek : strings.agentEveryDay
        let trigger = policy.checkOnConnection == true ? interval + " · " + strings.agentLaunchReconnectShort : interval
        guard let next = policy.nextCheck, next > Date() else { return trigger + " · " + strings.agentCheckDue }
        return trigger + " · " + strings.agentNextCheck + " " + next.formatted(date: .abbreviated, time: .shortened)
    }

    private var operationText: String {
        guard let operation = manager.operations[target] else { return strings.agentDiscovering }
        let action = operation.kind == .checking ? strings.agentDiscovering :
            operation.kind == .hooks ? strings.agentInstallingHooks : strings.agentUpdatingCLI
        return action + (operation.agent.map { " · " + $0.displayName } ?? "") +
            (operation.total > 0 ? " (\(operation.completed + 1)/\(operation.total))" : "")
    }

    private var unifiedCLIBinding: Binding<Bool> {
        Binding(get: { policy.updatesCLIs }, set: { enabled in
            var value = policy
            value.updateAllCLIsAutomatically = enabled
            if enabled { value.checkAutomatically = true }
            value.automaticallyUpdatedAgents = []
            manager.setPolicy(value, for: target)
        })
    }

    private func hookBinding(_ agent: SupportedAgent) -> Binding<Bool> {
        Binding(get: { snapshot.hooks[agent]?.isInstalled == true }, set: { enabled in perform(agent, remove: !enabled) })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentIntegrationPolicy, Value>) -> Binding<Value> {
        Binding(get: { policy[keyPath: keyPath] }, set: { value in
            var policy = policy
            policy[keyPath: keyPath] = value
            manager.setPolicy(policy, for: target)
        })
    }

    private func refresh(checkLatest: Bool = true) {
        let captured = target
        Task { await manager.refresh(target: captured, checkLatest: checkLatest) }
    }

    private func perform(_ agent: SupportedAgent, cli: Bool = false, remove: Bool = false) {
        let captured = target
        if !cli { manager.acknowledgeOnboarding(target: captured) }
        Task { await manager.update(agent, target: captured, cli: cli, remove: remove) }
    }

    private func selectRequestedTarget() {
        guard let requested = SettingsNavigation.consumeAgentTarget(), registry.host(requested) != nil else { return }
        target = requested
    }

    private func cliStatus(_ cli: AgentCLIInstallation?) -> String {
        guard let cli else { return strings.agentNotChecked }
        guard cli.path != nil else { return strings.agentCLIMissing }
        let version = cli.version ?? strings.agentVersionUnknown
        if let latest = cli.latest, cli.updateAvailable { return "\(version) → \(latest)" }
        return version
    }

    private func hookLabel(_ agent: SupportedAgent) -> String {
        snapshot.hooks[agent]?.isInstalled == true ? strings.agentEnabled : strings.agentDisabled
    }

    private func hookActionLabel(_ agent: SupportedAgent, state: AgentHookInstallationState) -> String {
        if agent.definition.hook.kind == .none {
            return state == .current ? strings.agentReinstallDetector : state.isInstalled ? strings.agentUpdateDetector : strings.agentInstallDetector
        }
        return state == .current ? strings.agentReinstallHook : state.isInstalled ? strings.agentUpdateHook : strings.agentInstallHook
    }

    private func hookStatus(_ agent: SupportedAgent) -> String {
        if agent.definition.hook.kind == .none {
            guard local else { return strings.agentHostDetectorOnly }
            switch snapshot.hooks[agent] {
            case .none: return strings.agentNotChecked
            case .missing: return strings.agentDetectorMissing
            case .updateAvailable: return strings.agentDetectorUpdateRequired
            case .current: return strings.agentDetectorCurrent
            }
        }
        switch snapshot.hooks[agent] {
        case .none: return strings.agentNotChecked
        case .missing: return strings.agentHooksMissing
        case .updateAvailable: return strings.agentHooksUpdateRequired
        case .current: return strings.agentHooksCurrent
        }
    }
}

private struct AgentSetupActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(
                Color.primary.opacity(isEnabled && (hovering || configuration.isPressed) ?
                    (configuration.isPressed ? 0.08 : 0.04) : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .onHover { hovering = $0 }
    }
}
