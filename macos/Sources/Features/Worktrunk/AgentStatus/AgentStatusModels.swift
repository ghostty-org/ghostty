import Foundation

enum AgentLifecycleEventType: String, Codable {
    case start = "Start"
    case stop = "Stop"
    case permissionRequest = "PermissionRequest"
}

struct AgentLifecycleEvent: Codable, Hashable {
    var timestamp: Date
    var eventType: AgentLifecycleEventType
    var cwd: String
}

enum WorktreeAgentStatus: String, Codable, Hashable {
    case working
    case permission
    case review
}

struct WorktreeAgentStatusEntry: Codable, Hashable {
    var status: WorktreeAgentStatus
    var updatedAt: Date
}

