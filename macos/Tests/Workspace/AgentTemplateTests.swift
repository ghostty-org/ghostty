import Foundation
import Testing
@testable import Ghostty

struct AgentTemplateTests {

    // MARK: - Built-in Templates

    @Test func builtInShellTemplate() {
        let shell = AgentTemplate.shell
        #expect(shell.kind == .shell)
        #expect(shell.command == nil)
        #expect(shell.agent == nil)
        #expect(shell.isDefault == true)
        #expect(shell.isGlobal == true)
    }

    @Test func builtInClaudeCodeTemplate() {
        let cc = AgentTemplate.claudeCode
        #expect(cc.kind == .claudeCode)
        #expect(cc.command == "claude")
        #expect(cc.agent == nil)
        #expect(cc.isDefault == true)
    }

    @Test func builtInOrchestratorTemplate() {
        let orch = AgentTemplate.orchestrator
        #expect(orch.kind == .claudeCode)
        #expect(orch.command == "claude")
        #expect(orch.agent != nil)
        #expect(orch.agent?.model == "opus")
        #expect(orch.agent?.systemPromptFile != nil)
        #expect(orch.isDefault == true)
    }

    @Test func defaultsContainsAllBuiltIns() {
        #expect(AgentTemplate.defaults.count == 3)
        #expect(AgentTemplate.defaults.map(\.name) == ["Shell", "Claude Code", "Orchestrator"])
    }

    @Test func deterministicUUIDs() {
        // UUIDs must be stable across launches for persistence
        #expect(AgentTemplate.shell.id.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(AgentTemplate.claudeCode.id.uuidString == "00000000-0000-0000-0000-000000000002")
        #expect(AgentTemplate.orchestrator.id.uuidString == "00000000-0000-0000-0000-000000000003")
    }

    // MARK: - Kind Enum Codable

    @Test func kindRoundTrip() throws {
        for kind in [AgentTemplate.Kind.shell, .claudeCode, .custom] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(AgentTemplate.Kind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test func kindInvalidRawValueDefaultsToShell() throws {
        // Unknown kind values should not crash -- fall back to .shell
        let json = "\"unknownKind\""
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AgentTemplate.Kind.self, from: data)
        #expect(decoded == .shell)
    }

    // MARK: - AgentConfig Codable

    @Test func agentConfigRoundTrip() throws {
        let config = AgentTemplate.AgentConfig(
            systemPromptFile: "~/.claude/test.md",
            model: "opus",
            permissionMode: "plan",
            effort: "max",
            allowedTools: ["Read", "Grep"],
            additionalFlags: ["--verbose"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentTemplate.AgentConfig.self, from: data)
        #expect(decoded.systemPromptFile == "~/.claude/test.md")
        #expect(decoded.model == "opus")
        #expect(decoded.permissionMode == "plan")
        #expect(decoded.effort == "max")
        #expect(decoded.allowedTools == ["Read", "Grep"])
        #expect(decoded.additionalFlags == ["--verbose"])
    }

    @Test func agentConfigPartialDecode() throws {
        // Only model set, everything else missing -- should decode fine
        let json = """
        {"model": "sonnet"}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AgentTemplate.AgentConfig.self, from: data)
        #expect(decoded.model == "sonnet")
        #expect(decoded.systemPromptFile == nil)
        #expect(decoded.permissionMode == nil)
        #expect(decoded.additionalFlags.isEmpty)
    }

    // MARK: - Full Template Codable

    @Test func templateRoundTrip() throws {
        let template = AgentTemplate(
            id: UUID(),
            name: "Test Agent",
            kind: .claudeCode,
            command: "claude",
            isDefault: false,
            isGlobal: true,
            agent: AgentTemplate.AgentConfig(model: "sonnet")
        )
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(AgentTemplate.self, from: data)
        #expect(decoded.name == "Test Agent")
        #expect(decoded.kind == .claudeCode)
        #expect(decoded.agent?.model == "sonnet")
        #expect(decoded.isGlobal == true)
    }

    @Test func backwardCompatFromOldSessionTemplate() throws {
        // Old SessionTemplate JSON: flat command, no kind, no agent
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "My Shell",
            "isDefault": false,
            "environmentVariables": {}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AgentTemplate.self, from: data)
        #expect(decoded.name == "My Shell")
        #expect(decoded.kind == .shell)  // nil command -> .shell
        #expect(decoded.agent == nil)
        #expect(decoded.isGlobal == true)  // default
    }

    @Test func backwardCompatClaudeCommand() throws {
        // Old SessionTemplate with command "claude" -> .claudeCode
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Claude",
            "command": "claude",
            "isDefault": false,
            "environmentVariables": {}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AgentTemplate.self, from: data)
        #expect(decoded.kind == .claudeCode)
    }

    @Test func backwardCompatCustomCommand() throws {
        // Old SessionTemplate with command "aider" -> .custom
        let json = """
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Aider",
            "command": "aider",
            "isDefault": false,
            "environmentVariables": {"EDITOR": "vim"}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AgentTemplate.self, from: data)
        #expect(decoded.kind == .custom)
        #expect(decoded.command == "aider")
        #expect(decoded.environmentVariables["EDITOR"] == "vim")
    }

    // MARK: - buildCommand

    @Test func buildCommandShell() {
        let shell = AgentTemplate.shell
        let cmd = shell.buildCommand()
        #expect(cmd == "")  // nil command -> empty string, Ghostty uses default shell
    }

    @Test func buildCommandPlainClaude() {
        let cc = AgentTemplate.claudeCode
        let cmd = cc.buildCommand()
        #expect(cmd == "claude")  // no agent config -> just the command
    }

    @Test func buildCommandWithModel() {
        let template = AgentTemplate(
            name: "Test", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(model: "sonnet")
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("claude"))
        #expect(cmd.contains("--model"))
        #expect(cmd.contains("sonnet"))
    }

    @Test func buildCommandWithPermissionMode() {
        let template = AgentTemplate(
            name: "Test", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(permissionMode: "plan")
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("--permission-mode"))
        #expect(cmd.contains("plan"))
    }

    @Test func buildCommandWithEffort() {
        let template = AgentTemplate(
            name: "Test", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(effort: "max")
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("--effort"))
        #expect(cmd.contains("max"))
    }

    @Test func buildCommandWithAllowedTools() {
        let template = AgentTemplate(
            name: "Test", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(allowedTools: ["Read", "Grep", "Bash"])
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("--allowedTools"))
        #expect(cmd.contains("Read,Grep,Bash"))
    }

    @Test func buildCommandWithAdditionalFlags() {
        let template = AgentTemplate(
            name: "Test", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(additionalFlags: ["--verbose", "--no-color"])
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("--verbose"))
        #expect(cmd.contains("--no-color"))
    }

    @Test func buildCommandWithMultipleOptions() {
        let template = AgentTemplate(
            name: "Full", kind: .claudeCode,
            command: "claude",
            agent: AgentTemplate.AgentConfig(
                model: "opus",
                permissionMode: "plan",
                effort: "max"
            )
        )
        let cmd = template.buildCommand()
        #expect(cmd.contains("--model opus"))
        #expect(cmd.contains("--permission-mode plan"))
        #expect(cmd.contains("--effort max"))
    }

    @Test func buildCommandCustomKind() {
        let template = AgentTemplate(
            name: "Aider", kind: .custom,
            command: "aider"
        )
        let cmd = template.buildCommand()
        #expect(cmd == "aider")
    }
}
