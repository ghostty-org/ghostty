import Foundation
import GhosttiesCore
import GhosttiesMCPClient
import SwiftUI

/// SwiftUI-facing store around `MCPSourceStore` (disk) + `Keychain` (secrets).
///
/// The Settings pane binds to this; the future Wave 3 data fetcher will read
/// sources directly via `MCPSourceStore.discover()` and pull the API key at
/// use-time via `Keychain.get`. Credentials never live on this object or in
/// the Codable `MCPSource` model.
@MainActor
final class MCPSourceSettingsStore: ObservableObject {
    /// UI status for each configured source. Not persisted.
    enum SourceStatus: Equatable {
        /// Default — we haven't connected yet in this session.
        case untested
        /// Test-connection succeeded at some point this session.
        case connected
        /// Test-connection failed; carries a human-readable reason.
        case error(String)
    }

    @Published private(set) var sources: [MCPSource] = []
    @Published private(set) var status: [String: SourceStatus] = [:]
    @Published private(set) var loadError: String?

    private let store: MCPSourceStore

    init(store: MCPSourceStore = .discover()) {
        self.store = store
        reload()
    }

    // MARK: - Reads

    /// Fetch the API key for `source` from the Keychain. Returns `nil` if none
    /// was stored (e.g. a stdio source that doesn't need one, or the user
    /// hasn't entered one yet).
    func apiKey(for source: MCPSource) -> String? {
        Keychain.get(account: source.id)
    }

    // MARK: - Mutations

    /// Load sources from disk. Called on init and after every save/delete so
    /// the UI reflects the canonical on-disk state.
    func reload() {
        do {
            self.sources = try store.load()
            self.loadError = nil
        } catch {
            self.sources = []
            self.loadError = (error as? MCPError)?.description ?? error.localizedDescription
        }
    }

    /// Persist `source`, replacing any existing entry with the same id. If
    /// `apiKey` is non-empty, write it to the Keychain; if it's empty and an
    /// entry exists, leave the Keychain alone (avoids clobbering on edits
    /// where the user didn't retype the key).
    func save(_ source: MCPSource, apiKey: String) throws {
        var updated = sources
        if let idx = updated.firstIndex(where: { $0.id == source.id }) {
            updated[idx] = source
        } else {
            updated.append(source)
        }
        try store.save(updated)

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Keychain.set(account: source.id, value: trimmed)
        }

        reload()
    }

    /// Delete the source by id: removes from disk and clears its Keychain
    /// entry. Safe to call on an id that no longer exists.
    func delete(id: String) throws {
        let filtered = sources.filter { $0.id != id }
        try store.save(filtered)
        Keychain.delete(account: id)
        status.removeValue(forKey: id)
        reload()
    }

    /// Reserve a status update for `id`. Used by `AddMCPSourceSheet`'s test
    /// button and the future connect-at-use-time code path.
    func setStatus(_ newStatus: SourceStatus, for id: String) {
        status[id] = newStatus
    }

    func status(for id: String) -> SourceStatus {
        status[id] ?? .untested
    }
}
