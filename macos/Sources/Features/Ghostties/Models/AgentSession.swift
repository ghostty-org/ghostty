import Foundation

/// Persistent metadata for a terminal session.
///
/// This is the Codable record stored in workspace.json. Runtime state (the actual
/// SurfaceView reference, live status) lives in SessionCoordinator and is NOT persisted.
///
/// On app restart, previously active sessions appear as "Exited" with a relaunch option.
struct AgentSession: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var templateId: UUID
    var projectId: UUID

    init(
        id: UUID = UUID(),
        name: String,
        templateId: UUID,
        projectId: UUID
    ) {
        self.id = id
        self.name = name
        self.templateId = templateId
        self.projectId = projectId
    }
}

// MARK: - Runtime State

/// Live status of a running session. Not persisted.
enum SessionStatus {
    case running
    case exited
}
