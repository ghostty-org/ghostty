import Foundation
import SwiftUI

/// Central state manager for workspace projects, sessions, and templates.
///
/// Manages the global project list and session metadata shared across all windows.
/// Per-window state (like which project is selected) lives in the view layer.
/// Runtime session state (SurfaceView references) lives in SessionCoordinator.
@MainActor
final class WorkspaceStore: ObservableObject {
    /// Shared instance used by all windows. Created once on first access.
    static let shared = WorkspaceStore()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var templates: [SessionTemplate] = []

    private init() {
        let state = WorkspacePersistence.load()
        self.projects = state.projects
        self.sessions = state.sessions

        // Merge persisted custom templates with built-in defaults.
        // Defaults are always present; custom templates are additive.
        let customTemplates = state.templates.filter { !$0.isDefault }
        self.templates = SessionTemplate.defaults + customTemplates
    }

    // MARK: - Computed (Projects)

    /// Pinned projects first (by name), then unpinned (by name).
    var sortedProjects: [Project] {
        let pinned = projects.filter(\.isPinned)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let unpinned = projects.filter { !$0.isPinned }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return pinned + unpinned
    }

    // MARK: - Computed (Sessions)

    /// Sessions for a specific project, ordered by name.
    func sessions(for projectId: UUID) -> [AgentSession] {
        sessions.filter { $0.projectId == projectId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Project Actions

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        // Don't add duplicates (same path).
        if let index = projects.firstIndex(where: { $0.rootPath == path }) {
            projects[index].isPinned = true
            persist()
            return
        }

        let project = Project(
            name: url.lastPathComponent,
            rootPath: path,
            isPinned: true
        )
        projects.append(project)
        persist()
    }

    func removeProject(id: UUID) {
        // Also remove sessions belonging to this project.
        sessions.removeAll { $0.projectId == id }
        projects.removeAll { $0.id == id }
        persist()
    }

    func togglePin(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isPinned.toggle()
        persist()
    }

    // MARK: - Session Actions

    @discardableResult
    func addSession(name: String, templateId: UUID, projectId: UUID) -> AgentSession {
        let session = AgentSession(name: name, templateId: templateId, projectId: projectId)
        sessions.append(session)
        persist()
        return session
    }

    func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Private

    private func persist() {
        let customTemplates = templates.filter { !$0.isDefault }
        let state = WorkspacePersistence.State(
            projects: projects,
            sessions: sessions,
            templates: customTemplates
        )
        WorkspacePersistence.save(state)
    }
}
