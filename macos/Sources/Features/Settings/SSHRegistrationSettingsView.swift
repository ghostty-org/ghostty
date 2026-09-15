import SwiftUI

struct SSHRegistrationSettingsView: View {
    let strings: SettingsStrings
    @ObservedObject var registry = SSHHostRegistry.shared
    @ObservedObject var agents = AgentIntegrationManager.shared
    var initialChoices: [SSHRegistrationChoice]?
    @State private var selectedID = ""
    @State private var registering = false
    @State private var choices: [SSHRegistrationChoice] = []
    @State private var loadingHosts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(strings.sshAutomaticRegistration, isOn: $registry.automaticallyRegister)
                .toggleStyle(.switch).controlSize(.small)
            HStack {
                SSHHostPicker(items: choices.map { .init(id: $0.id, title: $0.title) }, selection: $selectedID) {
                    HStack(spacing: 8) {
                        Image(systemName: "network").foregroundStyle(.secondary)
                        Text(choices.first(where: { $0.id == selectedID })?.title ?? strings.sshRegistrationTarget)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                }
                .disabled(choices.isEmpty || loadingHosts)
                Button(strings.sshRegister) { register() }
                    .disabled(registering || selectedConnection == nil || !agents.busy.isEmpty)
                if registering || loadingHosts || !registry.pending.isEmpty { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            Text(strings.sshRegistrationCaption).font(.caption).foregroundStyle(.secondary)
            ForEach(registry.hosts) { host in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.name).fontWeight(.medium)
                        Text(host.endpoint ?? host.connection.displayEndpoint)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(registry.connections[host.id] == nil ? strings.sshCached : strings.sshConnected)
                        .font(.caption).foregroundStyle(.secondary)
                    Button(strings.sshUnregister) { agents.forget(host.id) }
                        .disabled(agents.busy.contains(host.id) || registry.pending.contains(host.id))
                }.controlSize(.small)
            }
            if let error = registry.errors.sorted(by: { $0.key < $1.key }).first?.value {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task {
            registry.reconcile()
            await loadChoices()
        }
        .onReceive(registry.$connections) { _ in
            Task { await loadChoices() }
        }
    }

    private var selectedConnection: GitSSHConnection? { choices.first { $0.id == selectedID }?.connection }

    private func loadChoices() async {
        guard !loadingHosts else { return }
        loadingHosts = true
        defer { loadingHosts = false }
        if let initialChoices { choices = initialChoices } else { choices = await SSHConfigurationCatalog.choices(live: Array(registry.connections.values)) }
        if !choices.contains(where: { $0.id == selectedID }) { selectedID = choices.count == 1 ? choices.first?.id ?? "" : "" }
    }

    private func register() {
        guard let connection = selectedConnection else { return }
        let choice = choices.first { $0.id == selectedID }
        registering = true
        Task {
            defer { registering = false }
            await registry.register(connection, endpoint: choice?.endpoint, fromConfiguration: choice?.fromConfiguration ?? false)
        }
    }
}
