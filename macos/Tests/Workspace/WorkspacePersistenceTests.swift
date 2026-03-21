import Foundation
import Testing
@testable import Ghostty

struct WorkspacePersistenceTests {
    // MARK: - Helpers

    private func makeProject(id: UUID = UUID(), name: String = "Test") -> Project {
        Project(id: id, name: name, rootPath: "/tmp/\(name)", isPinned: false)
    }

    private func makeTemplate(id: UUID = UUID(), name: String = "Custom") -> AgentTemplate {
        AgentTemplate(id: id, name: name, kind: .custom, command: "/bin/zsh", isDefault: false)
    }

    private func makeSession(
        projectId: UUID,
        templateId: UUID = AgentTemplate.shell.id,
        name: String = "Shell — Test"
    ) -> AgentSession {
        AgentSession(name: name, templateId: templateId, projectId: projectId)
    }

    // MARK: - State Init

    @Test func defaultStateHasSidebarPinned() {
        let state = WorkspacePersistence.State()
        #expect(state.sidebarMode == .pinned)
    }

    @Test func defaultStateHasNilLastSelectedProjectId() {
        let state = WorkspacePersistence.State()
        #expect(state.lastSelectedProjectId == nil)
    }

    @Test func initWithAllParamsSetsSidebarAndSelection() {
        let uuid = UUID()
        let state = WorkspacePersistence.State(
            sidebarMode: .closed,
            lastSelectedProjectId: uuid
        )
        #expect(state.sidebarMode == .closed)
        #expect(state.lastSelectedProjectId == uuid)
    }

    // MARK: - Codable Round-Trip

    @Test func encodingDecodingPreservesAllFields() throws {
        let projectId = UUID()
        let project = makeProject(id: projectId, name: "MyProject")
        let session = makeSession(projectId: projectId)
        let template = makeTemplate()
        let original = WorkspacePersistence.State(
            projects: [project],
            sessions: [session],
            templates: [template],
            sidebarMode: .closed,
            lastSelectedProjectId: projectId
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)

        #expect(decoded.projects.count == 1)
        #expect(decoded.projects[0].id == projectId)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.sessions[0].projectId == projectId)
        #expect(decoded.templates.count == 1)
        #expect(decoded.templates[0].name == "Custom")
        #expect(decoded.sidebarMode == .closed)
        #expect(decoded.lastSelectedProjectId == projectId)
    }

    @Test func decodingOldJsonWithoutNewFieldsUsesDefaults() throws {
        // Simulates workspace.json from before sidebarMode and lastSelectedProjectId existed.
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)

        #expect(decoded.sidebarMode == .pinned)
        #expect(decoded.lastSelectedProjectId == nil)
        #expect(decoded.projects.isEmpty)
        #expect(decoded.sessions.isEmpty)
        #expect(decoded.templates.isEmpty)
    }

    @Test func decodingLegacySidebarVisibleTrueMigratesToPinned() throws {
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": [],
            "sidebarVisible": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.sidebarMode == .pinned)
    }

    @Test func decodingLegacySidebarVisibleFalseMigratesToClosed() throws {
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": [],
            "sidebarVisible": false
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.sidebarMode == .closed)
    }

    @Test func decodingInvalidSidebarModeRawValueDefaultsToPinned() throws {
        // An out-of-range raw value should gracefully default to .pinned,
        // not throw a DecodingError that wipes all state.
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": [],
            "sidebarMode": 99
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.sidebarMode == .pinned)
        #expect(decoded.projects.isEmpty)
    }

    @Test func encodingOverlayModePersistsAsClosed() throws {
        let state = WorkspacePersistence.State(sidebarMode: .overlay)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.sidebarMode == .closed)
    }

    // MARK: - Validation

    @Test func validateClearsStaleLastSelectedProjectId() {
        let deletedId = UUID()
        let state = WorkspacePersistence.State(
            projects: [],
            lastSelectedProjectId: deletedId
        )

        let validated = WorkspacePersistence.validate(state)
        #expect(validated.lastSelectedProjectId == nil)
    }

    @Test func validatePreservesValidLastSelectedProjectId() {
        let project = makeProject()
        let state = WorkspacePersistence.State(
            projects: [project],
            lastSelectedProjectId: project.id
        )

        let validated = WorkspacePersistence.validate(state)
        #expect(validated.lastSelectedProjectId == project.id)
    }

    @Test func validateRemovesSessionsWithOrphanedProjectId() {
        let validProject = makeProject()
        let deletedProjectId = UUID()
        let goodSession = makeSession(projectId: validProject.id)
        let orphanedSession = makeSession(projectId: deletedProjectId, name: "Orphan")
        let state = WorkspacePersistence.State(
            projects: [validProject],
            sessions: [goodSession, orphanedSession]
        )

        let validated = WorkspacePersistence.validate(state)
        #expect(validated.sessions.count == 1)
        #expect(validated.sessions[0].id == goodSession.id)
    }

    @Test func validateRemovesSessionsWithOrphanedTemplateId() {
        let project = makeProject()
        let deletedTemplateId = UUID()
        let goodSession = makeSession(projectId: project.id)
        let orphanedSession = makeSession(
            projectId: project.id,
            templateId: deletedTemplateId,
            name: "Orphan"
        )
        let state = WorkspacePersistence.State(
            projects: [project],
            sessions: [goodSession, orphanedSession]
        )

        let validated = WorkspacePersistence.validate(state)
        #expect(validated.sessions.count == 1)
        #expect(validated.sessions[0].id == goodSession.id)
    }
}
