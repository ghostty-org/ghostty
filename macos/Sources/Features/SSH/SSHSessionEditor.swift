import AppKit
import SwiftUI

struct SSHSessionEditor: View {
    @ObservedObject var store: SSHSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SSHProfile
    @State private var port: String
    @State private var password = ""
    @State private var passphrase = ""
    @State private var keepPassword: Bool
    @State private var keepPassphrase: Bool
    @State private var error: String?

    init(store: SSHSessionStore, profile: SSHProfile) {
        self.store = store
        _profile = State(initialValue: profile)
        _port = State(initialValue: profile.port.map(String.init) ?? "")
        _keepPassword = State(initialValue: profile.passwordID != nil)
        _keepPassphrase = State(initialValue: profile.passphraseID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH Connection").font(.title2)
            Form {
                TextField("Name", text: $profile.name)
                Picker("Folder", selection: $profile.folderID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(store.document.folders) { folder in
                        Text(folder.name).tag(Optional(folder.id))
                    }
                }
                TextField("Host or SSH alias", text: $profile.destination)
                TextField("Username", text: $profile.username)
                TextField("Port (from SSH config if empty)", text: $port)
                Picker("Authentication", selection: $profile.authentication) {
                    ForEach(SSHProfile.Authentication.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Picker("Terminal type (TERM)", selection: $profile.terminalType) {
                    ForEach(SSHProfile.TerminalType.allCases) { terminal in Text(terminal.title).tag(terminal) }
                }
                Picker("Character encoding", selection: $profile.encoding) {
                    ForEach(SSHProfile.Encoding.allCases) { encoding in Text(encoding.title).tag(encoding) }
                }
                Text("Choose the terminal definition and character encoding supported by the server. UTF-8 is recommended.")
                    .font(.caption).foregroundColor(.secondary)
                if profile.authentication == .password {
                    Toggle("Save password in Keychain", isOn: $keepPassword)
                    if keepPassword {
                        SecureField(profile.passwordID == nil ? "Password" : "New password (empty keeps saved value)", text: $password)
                    }
                    Text("Saved passwords are used only for direct password authentication. Use manual authentication for OTP or jump hosts.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if [.privateKey, .certificate].contains(profile.authentication) {
                    filePicker("Private key", path: $profile.identityFile)
                    if profile.authentication == .certificate {
                        filePicker("OpenSSH certificate", path: $profile.certificateFile)
                        Text("The selected key and certificate are offered to OpenSSH. The server may also accept the same key without its certificate.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Toggle("Save key passphrase in Keychain", isOn: $keepPassphrase)
                    if keepPassphrase {
                        SecureField(profile.passphraseID == nil ? "Key passphrase" : "New passphrase (empty keeps saved value)", text: $passphrase)
                    }
                }
                Toggle("Favorite", isOn: $profile.favorite)
                Text("Changing connection or key settings clears saved credentials unless you enter them again.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error { Text(error).foregroundColor(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!store.canSave)
            }
        }
        .padding(20).frame(width: 890)
    }

    private func filePicker(_ title: String, path: Binding<String>) -> some View {
        HStack {
            TextField(title, text: path)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                panel.message = title
                if !path.wrappedValue.isEmpty {
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue).deletingLastPathComponent()
                }
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    private func save() {
        do {
            let value = port.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                guard let number = Int(value) else { throw SSHError.message("Port must be a number between 1 and 65535.") }
                profile.port = number
            } else { profile.port = nil }
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.destination = profile.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.save(profile, password: password, passphrase: passphrase,
                           keepPassword: keepPassword, keepPassphrase: keepPassphrase)
            password = ""
            passphrase = ""
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
