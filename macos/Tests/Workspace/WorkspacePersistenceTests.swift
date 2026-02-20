import Foundation
import Testing
@testable import Ghostty

struct WorkspacePersistenceTests {
    // MARK: - Helpers

    private func makeProject(id: UUID = UUID(), name: String = "Test") -> Project {
        Project(id: id, name: name, rootPath: "/tmp/\(name)", isPinned: false)
    }

    private func makeTemplate(id: UUID = UUID(), name: String = "Custom") -> SessionTemplate {
        SessionTemplate(id: id, name: name, command: "/bin/zsh", isDefault: false)
    }

    private func makeSession(
        projectId: UUID,
        templateId: UUID = SessionTemplate.shell.id,
        name: String = "Shell — Test"
    ) -> AgentSession {
        AgentSession(name: name, templateId: templateId, projectId: projectId)
    }

    // MARK: - State Init

    @Test func defaultStateHasSidebarVisible() {
        let state = WorkspacePersistence.State()
        #expect(state.sidebarVisible == true)
    }

    @Test func defaultStateHasNilLastSelectedProjectId() {
        let state = WorkspacePersistence.State()
        #expect(state.lastSelectedProjectId == nil)
    }

    @Test func initWithAllParamsSetsSidebarAndSelection() {
        let uuid = UUID()
        let state = WorkspacePersistence.State(
            sidebarVisible: false,
            lastSelectedProjectId: uuid
        )
        #expect(state.sidebarVisible == false)
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
            sidebarVisible: false,
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
        #expect(decoded.sidebarVisible == false)
        #expect(decoded.lastSelectedProjectId == projectId)
    }

    @Test func decodingOldJsonWithoutNewFieldsUsesDefaults() throws {
        // Simulates workspace.json from before sidebarVisible and lastSelectedProjectId existed.
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)

        #expect(decoded.sidebarVisible == true)
        #expect(decoded.lastSelectedProjectId == nil)
        #expect(decoded.projects.isEmpty)
        #expect(decoded.sessions.isEmpty)
        #expect(decoded.templates.isEmpty)
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
