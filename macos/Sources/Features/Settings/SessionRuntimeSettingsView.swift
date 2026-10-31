import SwiftUI

struct SessionRuntimeSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    @State private var host = ""
    @State private var localWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @ObservedObject private var closes = SessionRuntimeCloseQueue.shared
    let strings: SettingsStrings
    @State private var error: String?
    private func text(_ english: String, _ chinese: String) -> String { strings.t(english, chinese) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.runtimeTitle).font(.headline)
            HStack {
                TextField(strings.runtimeHostPlaceholder, text: $host)
                Button(strings.runtimeConnect) { connect() }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(strings.runtimeConnectCaption)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(strings.runtimeLocalDirectory, text: $localWorkingDirectory)
                Button(strings.runtimeLocalOpen) { connectLocal() }
                    .disabled(localWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(strings.runtimeLocalCaption)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(strings.runtimeDetachedHours)
                Spacer()
                TextField("72", value: $settings.runtimeDetachedHours, format: .number).frame(width: 80)
            }
            Text(strings.runtimeDetachedCaption)
                .font(.caption).foregroundStyle(.secondary)
            TextField(strings.runtimeExpirationPlaceholder, text: $settings.runtimeExpiration)
            Toggle(strings.runtimeCloseOnDone, isOn: $settings.runtimeCloseOnAgentDone)
            Text(strings.runtimeCloseOnDoneCaption)
                .font(.caption).foregroundStyle(.secondary)
            if settings.runtimeCloseOnAgentDone {
                HStack {
                    Text(strings.runtimeDoneGrace)
                    Spacer()
                    TextField("60", value: $settings.runtimeDoneGraceSeconds, format: .number).frame(width: 80)
                }
                Text(strings.runtimeDoneGraceCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !closes.requests.isEmpty {
                Text(text("Remote sessions awaiting close confirmation: ", "等待远端确认关闭的会话：") + String(closes.requests.count))
                    .font(.caption).foregroundStyle(.orange)
                Button(text("Retry pending closes", "重试待关闭会话")) { closes.retry() }
            }
            Text(strings.runtimeIdleCaption)
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private func connect() {
        do {
            if !settings.runtimeExpiration.isEmpty && settings.runtimePolicy.expiresAt == nil {
                error = strings.runtimeInvalidDeadline
                return
            }
            let connection = try GitSSHConnection(destination: host.trimmingCharacters(in: .whitespacesAndNewlines))
            try SessionRuntimeConnections.shared.open(connection: connection, policy: settings.runtimePolicy)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func connectLocal() {
        do {
            if !settings.runtimeExpiration.isEmpty && settings.runtimePolicy.expiresAt == nil {
                error = strings.runtimeInvalidDeadline
                return
            }
            let directory = localWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            try SessionRuntimeConnections.shared.openLocal(workingDirectory: directory, policy: settings.runtimePolicy)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
