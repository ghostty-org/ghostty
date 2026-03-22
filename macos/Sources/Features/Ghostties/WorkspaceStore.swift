import AppKit
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
    @Published private(set) var templates: [AgentTemplate] = []

    /// Global session status — shared across all windows so that a session
    /// running in Window A shows a green dot in Window B's sidebar too.
    /// Coordinators write via `updateSessionStatus`; views read directly.
    @Published private(set) var globalStatuses: [UUID: SessionStatus] = [:]

    /// Current sidebar mode. Persisted across launches.
    /// `.overlay` is transient — always saved as `.closed`.
    /// Only `WorkspaceViewContainer.transitionTo(_:)` should mutate this
    /// (via `updateSidebarMode`) to keep the UI and store in sync.
    private(set) var sidebarMode: SidebarMode = .pinned {
        didSet { if oldValue != sidebarMode { persist() } }
    }

    /// Called by `WorkspaceViewContainer` after state transitions.
    func updateSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
    }

    /// The last selected project ID, used to restore selection on launch.
    var lastSelectedProjectId: UUID? {
        didSet { if oldValue != lastSelectedProjectId { persist() } }
    }

    private init() {
        let state = WorkspacePersistence.load()
        self.projects = state.projects
        self.sessions = state.sessions
        self.sidebarMode = state.sidebarMode
        self.lastSelectedProjectId = state.lastSelectedProjectId

        // Seed bundled presets to ~/.ghostties/presets/ on first launch.
        PresetLoader.seedIfNeeded()

        // Load file-based presets from ~/.ghostties/presets/.
        let presets = PresetLoader.loadPresets()

        // Merge persisted custom templates with built-in defaults and presets.
        // Order: presets first, then built-in defaults, then custom templates.
        let customTemplates = state.templates.filter { !$0.isDefault }
        self.templates = presets + AgentTemplate.defaults + customTemplates
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

    /// Sessions for a specific project, ordered by sortOrder (then name for ties/nils).
    ///
    /// Sessions with an explicit `sortOrder` come first (ascending), followed by
    /// sessions without one (alphabetical). This preserves backward compatibility —
    /// old sessions that predate drag-and-drop sort alphabetically until reordered.
    func sessions(for projectId: UUID) -> [AgentSession] {
        sessions.filter { $0.projectId == projectId }
            .sorted { a, b in
                switch (a.sortOrder, b.sortOrder) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
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

        let usedGhosts = Set(projects.compactMap(\.ghostCharacter))
        let project = Project(
            name: url.lastPathComponent,
            rootPath: path,
            isPinned: true,
            ghostCharacter: GhostCharacter.randomUnused(excluding: usedGhosts)
        )
        projects.append(project)
        persist()
    }

    func removeProject(id: UUID) {
        // Notify coordinators so they can close running sessions before we delete records.
        NotificationCenter.default.post(
            name: .workspaceProjectWillBeRemoved,
            object: nil,
            userInfo: ["projectId": id]
        )

        // Remove sessions belonging to this project, then the project itself.
        sessions.removeAll { $0.projectId == id }
        projects.removeAll { $0.id == id }
        if lastSelectedProjectId == id { lastSelectedProjectId = nil }
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
        let maxOrder = sessions.filter { $0.projectId == projectId }
            .compactMap(\.sortOrder).max() ?? -1
        let session = AgentSession(
            name: name,
            templateId: templateId,
            projectId: projectId,
            sortOrder: maxOrder + 1
        )
        sessions.append(session)
        persist()
        return session
    }

    func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    /// Rename a session in place.
    func renameSession(id: UUID, name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = name
        persist()
    }

    /// Move a session to a new position within its project.
    func moveSession(id: UUID, toIndex newIndex: Int, inProject projectId: UUID) {
        var projectSessions = sessions(for: projectId)
        guard let fromIndex = projectSessions.firstIndex(where: { $0.id == id }),
              newIndex >= 0, newIndex < projectSessions.count else { return }

        let moved = projectSessions.remove(at: fromIndex)
        projectSessions.insert(moved, at: newIndex)

        // Reassign sortOrder values for all sessions in this project.
        for (order, session) in projectSessions.enumerated() {
            if let globalIndex = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[globalIndex].sortOrder = order
            }
        }
        persist()
    }

    // MARK: - Project Mutation

    /// Update a project's display name, ghost character, and/or default template.
    func updateProject(id: UUID, name: String? = nil, ghostCharacter: GhostCharacter? = nil, defaultTemplateId: UUID? = nil) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        if let name { projects[index].name = name }
        if let ghost = ghostCharacter { projects[index].ghostCharacter = ghost }
        if let templateId = defaultTemplateId { projects[index].defaultTemplateId = templateId }
        persist()
    }

    /// Clear a project's default template (user picked "None" / "Always ask").
    func clearDefaultTemplate(for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[index].defaultTemplateId = nil
        persist()
    }

    // MARK: - Session Status

    /// Update a single session's global status (called by coordinators).
    func updateSessionStatus(id: UUID, status: SessionStatus) {
        globalStatuses[id] = status
    }

    /// Remove a session's global status entry (called on cleanup).
    func removeSessionStatus(id: UUID) {
        globalStatuses.removeValue(forKey: id)
    }

    // MARK: - Template Actions

    @discardableResult
    func addTemplate(_ template: AgentTemplate) -> AgentTemplate {
        let sanitized = WorkspacePersistence.sanitizeTemplate(template)
        templates.append(sanitized)
        persist()
        return sanitized
    }

    func updateTemplate(
        id: UUID,
        name: String? = nil,
        kind: AgentTemplate.Kind? = nil,
        command: String? = nil,
        environmentVariables: [String: String]? = nil,
        workingDirectory: String? = nil,
        isGlobal: Bool? = nil,
        projectId: UUID?? = nil,
        agent: AgentTemplate.AgentConfig?? = nil
    ) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        guard !templates[index].isDefault else { return }
        if let name { templates[index].name = name }
        if let kind { templates[index].kind = kind }
        if let command { templates[index].command = command }
        if let environmentVariables { templates[index].environmentVariables = environmentVariables }
        if let workingDirectory { templates[index].workingDirectory = workingDirectory }
        if let isGlobal { templates[index].isGlobal = isGlobal }
        if let projectId { templates[index].projectId = projectId }
        if let agent { templates[index].agent = agent }
        templates[index] = WorkspacePersistence.sanitizeTemplate(templates[index])
        persist()
    }

    @discardableResult
    func duplicateTemplate(id: UUID) -> AgentTemplate? {
        guard let original = templates.first(where: { $0.id == id }) else { return nil }
        // NOTE: Update this if AgentTemplate gains new stored properties.
        // id is `let`, so encode/decode can't assign a fresh UUID — memberwise init is required.
        let copy = AgentTemplate(
            name: "Copy of \(original.name)",
            kind: original.kind,
            command: original.command,
            environmentVariables: original.environmentVariables,
            workingDirectory: original.workingDirectory,
            isGlobal: original.isGlobal,
            projectId: original.projectId,
            agent: original.agent,
            templateDescription: original.templateDescription,
            icon: original.icon,
            accessLabel: original.accessLabel
        )
        let sanitized = WorkspacePersistence.sanitizeTemplate(copy)
        templates.append(sanitized)
        persist()
        return sanitized
    }

    func removeTemplate(id: UUID) {
        guard let template = templates.first(where: { $0.id == id }),
              !template.isDefault else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    /// Whether any session references a given template.
    func templateInUse(id: UUID) -> Bool {
        sessions.contains { $0.templateId == id }
    }

    /// Returns templates available for a given project context.
    /// Global templates are always included, plus any scoped to the specific project.
    func templates(for projectId: UUID?) -> [AgentTemplate] {
        templates.filter { template in
            template.isGlobal || template.projectId == projectId
        }
    }

    // MARK: - Folder Picker

    /// Presents an NSOpenPanel and adds the selected directory as a project.
    /// Returns the new or existing project's ID, or nil if the user cancelled.
    @discardableResult
    func addProjectViaFolderPicker() -> UUID? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        addProject(at: url)
        return sortedProjects.first(where: {
            $0.rootPath == url.standardizedFileURL.path
        })?.id
    }

    // MARK: - Private

    /// Debounced persistence — coalesces rapid mutations into a single disk write
    /// on a background thread to avoid blocking the main actor.
    private var persistTask: Task<Void, Never>?

    private func persist() {
        persistTask?.cancel()
        persistTask = Task { [projects, sessions, templates, sidebarMode, lastSelectedProjectId] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let customTemplates = templates.filter { !$0.isDefault }
            // Overlay is transient — persist as closed so next launch starts closed.
            let persistedMode: SidebarMode = sidebarMode == .overlay ? .closed : sidebarMode
            let state = WorkspacePersistence.State(
                projects: projects,
                sessions: sessions,
                templates: customTemplates,
                sidebarMode: persistedMode,
                lastSelectedProjectId: lastSelectedProjectId
            )
            await Task.detached(priority: .utility) {
                WorkspacePersistence.save(state)
            }.value
        }
    }
}
