import Foundation
import SwiftUI

/// A terminal session that hasn't been promoted to a task yet.
///
/// Lives in memory + persists to `.ghostties/sessions.json`. GC'd on terminal
/// close if never promoted. Named `SessionDraft` (not `Session`) because
/// `SessionCoordinator` + `AgentSession` already own that word — a draft is
/// explicitly "hasn't committed to being a task yet."
///
/// `terminalSessionId` links to the live `AgentSession.id` in `SessionCoordinator`;
/// nil after app restart before the user clicks, or if the owning terminal
/// process exited. `promotedToTaskId` holds the filename stem of the `.md`
/// once promoted — non-nil means the row has morphed into a proper task.
///
/// Not `ObservableObject` by itself — mutation goes through `SessionDraftStore`
/// which publishes the array. This avoids `@MainActor` fighting with Codable
/// conformance on a reference type.
final class SessionDraft: Identifiable, Codable {
    let id: String
    let cwd: String
    let startedAt: Date
    var terminalSessionId: UUID?
    var promotedToTaskId: String?

    /// A draft is "stale" when there's no live terminal attached — either it
    /// was restored from disk after an app restart, or its terminal closed
    /// without the draft being GC'd (shouldn't happen, but defensive).
    var isStale: Bool { terminalSessionId == nil }

    init(id: String = UUID().uuidString,
         cwd: String,
         startedAt: Date = Date(),
         terminalSessionId: UUID? = nil,
         promotedToTaskId: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.startedAt = startedAt
        self.terminalSessionId = terminalSessionId
        self.promotedToTaskId = promotedToTaskId
    }

    // Codable keys intentionally OMIT `terminalSessionId`: runtime UUIDs don't
    // survive an app restart. Decoded drafts come back stale until re-attached.
    enum CodingKeys: String, CodingKey {
        case id, cwd, startedAt, promotedToTaskId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.cwd = try c.decode(String.self, forKey: .cwd)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.terminalSessionId = nil
        self.promotedToTaskId = try c.decodeIfPresent(String.self, forKey: .promotedToTaskId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(promotedToTaskId, forKey: .promotedToTaskId)
    }
}
