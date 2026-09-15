import SwiftUI

struct SSHRegistrationSettingsView: View {
    let strings: SettingsStrings
    @ObservedObject var registry = SSHHostRegistry.shared
    @ObservedObject var agents = AgentIntegrationManager.shared
    @State private var selectedID = ""
    @State private var registering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(strings.sshAutomaticRegistration, isOn: $registry.automaticallyRegister)
                .toggleStyle(.switch).controlSize(.small)
            HStack {
                Menu(selectedConnection?.displayEndpoint ?? strings.sshRegistrationTarget) {
                    ForEach(registry.connections.keys.sorted(), id: \.self) { id in
                        if let connection = registry.connections[id] {
                            Button(connection.displayEndpoint) { selectedID = id }
                        }
                    }
                }
                .disabled(registry.connections.isEmpty)
                Spacer()
                Button(strings.sshRegister) { register() }
                    .disabled(registering || selectedConnection == nil || !agents.busy.isEmpty)
                if registering || !registry.pending.isEmpty { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            Text(strings.sshRegistrationCaption).font(.caption).foregroundStyle(.secondary)
            ForEach(registry.hosts) { host in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.name).fontWeight(.medium)
                        Text(host.connection.displayEndpoint)
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
        }
        .onReceive(registry.$connections) { connections in
            if connections[selectedID] == nil { selectedID = connections.count == 1 ? connections.keys.first ?? "" : "" }
        }
    }

    private var selectedConnection: GitSSHConnection? { registry.connections[selectedID] }

    private func register() {
        guard let connection = selectedConnection else { return }
        registering = true
        Task {
            defer { registering = false }
            await registry.register(connection)
        }
    }
}
