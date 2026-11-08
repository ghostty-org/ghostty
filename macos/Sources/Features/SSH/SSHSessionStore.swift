import Combine
import Foundation

@MainActor
final class SSHSessionStore: ObservableObject {
    @Published private(set) var document = SSHSessionDocument()
    @Published var error: String?
    @Published private(set) var canSave = false
    private let file: SSHSessionFile

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
        file = SSHSessionFile(url: directory.appendingPathComponent("ssh-sessions.json"))
        reload()
    }

    func reload() {
        do { document = try file.load(); canSave = true; error = nil }
        catch { canSave = false; self.error = error.localizedDescription }
    }

    func save(_ profile: SSHProfile, password: String?, passphrase: String?,
              keepPassword: Bool, keepPassphrase: Bool) throws {
        try profile.validate()
        var updated = profile
        let old = document.profiles.first { $0.id == profile.id }
        if let old, SSHCredentialContext(old) != SSHCredentialContext(profile) {
            updated.passwordID = nil
            updated.passphraseID = nil
        }
        var created: [UUID] = []
        do {
            if !keepPassword || profile.authentication != .password { updated.passwordID = nil }
            if !keepPassphrase || ![.privateKey, .certificate].contains(profile.authentication) { updated.passphraseID = nil }
            if keepPassword, profile.authentication == .password, let password, !password.isEmpty {
                let id = try SSHCredentialStore.create(password, label: profile.name, for: profile)
                created.append(id)
                updated.passwordID = id
            }
            if keepPassphrase, [.privateKey, .certificate].contains(profile.authentication),
               let passphrase, !passphrase.isEmpty {
                let id = try SSHCredentialStore.create(passphrase, label: profile.name + " (key)", for: profile)
                created.append(id)
                updated.passphraseID = id
            }
            var next = document
            if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) { next.profiles[index] = updated }
            else { next.profiles.append(updated) }
            try commit(next)
        } catch {
            for id in created { try? SSHCredentialStore.delete(id) }
            throw error
        }
        for id in [old?.passwordID, old?.passphraseID].compactMap({ $0 })
            where id != updated.passwordID && id != updated.passphraseID {
            removeCredential(id)
        }
    }

    func delete(_ profile: SSHProfile) throws {
        var next = document
        next.profiles.removeAll { $0.id == profile.id }
        try commit(next)
        for id in [profile.passwordID, profile.passphraseID].compactMap({ $0 }) { removeCredential(id) }
    }

    func toggleFavorite(_ profile: SSHProfile) throws {
        var next = document
        guard let index = next.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        next.profiles[index].favorite.toggle()
        try commit(next)
    }

    func addFolder(_ name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SSHError.message("Enter a folder name.") }
        var next = document
        next.folders.append(SSHFolder(name: name))
        try commit(next)
    }

    func deleteFolder(_ id: UUID) throws {
        var next = document
        next.folders.removeAll { $0.id == id }
        for index in next.profiles.indices where next.profiles[index].folderID == id { next.profiles[index].folderID = nil }
        try commit(next)
    }

    private func commit(_ next: SSHSessionDocument) throws {
        guard canSave else { throw SSHError.message("Reload the SSH session file before saving.") }
        try file.save(next)
        document = next
    }

    private func removeCredential(_ id: UUID) {
        do { try SSHCredentialStore.delete(id) }
        catch { self.error = "The session was saved, but an unused Keychain item could not be removed: \(error.localizedDescription)" }
    }
}
