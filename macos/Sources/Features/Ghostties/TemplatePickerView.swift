import SwiftUI
import UniformTypeIdentifiers

/// A popover presenting available session templates for a project.
///
/// Shown when the user clicks "New Session" in the detail panel. Selecting a
/// template creates a new AgentSession, wires it to a Ghostty surface, and
/// inserts the surface into the split tree.
///
/// Non-default templates have a context menu for Edit, Duplicate, and Delete.
struct TemplatePickerView: View {
    let project: Project

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var editingTemplate: AgentTemplate?
    @State private var showDeleteConfirmation = false
    @State private var templateToDelete: AgentTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Session")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ForEach(store.templates) { template in
                templateRow(template)
            }

            Divider()
                .padding(.horizontal, 8)

            addCustomButton
        }
        .padding(.bottom, 8)
        .frame(width: 200)
        .sheet(item: $editingTemplate) { template in
            TemplateEditForm(template: template)
        }
        .alert(
            "Delete Template?",
            isPresented: $showDeleteConfirmation,
            presenting: templateToDelete
        ) { template in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.removeTemplate(id: template.id)
            }
        } message: { template in
            if store.templateInUse(id: template.id) {
                Text("Sessions using \"\(template.name)\" will keep their current configuration but won't be relaunchable with this template.")
            } else {
                Text("This will permanently remove \"\(template.name)\".")
            }
        }
    }

    // MARK: - Template Row

    private func templateRow(_ template: AgentTemplate) -> some View {
        Button(action: { createSession(from: template) }) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: template))
                    .font(.system(size: 12))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 12, weight: .medium))
                    if let command = template.command {
                        Text(command)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Default shell")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if template.isDefault {
                Button("Duplicate and Edit...") {
                    if let copy = store.duplicateTemplate(id: template.id) {
                        editingTemplate = copy
                    }
                }
            } else {
                Button("Edit...") {
                    editingTemplate = template
                }
                Button("Duplicate") {
                    store.duplicateTemplate(id: template.id)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    templateToDelete = template
                    showDeleteConfirmation = true
                }
            }
        }
    }

    // MARK: - Add Custom Template

    private var addCustomButton: some View {
        Button(action: addCustomTemplate) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text("Custom Template...")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func iconName(for template: AgentTemplate) -> String {
        switch template.kind {
        case .shell: return "terminal"
        case .claudeCode: return template.agent != nil ? "cpu" : "sparkle"
        case .custom: return "gearshape"
        }
    }

    private func createSession(from template: AgentTemplate) {
        Task {
            await coordinator.createQuickSession(for: project, template: template)
        }
        dismiss()
    }

    private func addCustomTemplate() {
        let newTemplate = store.addTemplate(AgentTemplate(name: "New Template", kind: .custom))
        editingTemplate = newTemplate
    }
}

// MARK: - Template Edit Form

/// An inline sheet for editing a template's name, kind, agent configuration,
/// command, and environment variables.
///
/// The "Agent Configuration" section is only shown when `kind` is `.claudeCode`
/// or `.custom`, since `.shell` sessions have no AI config.
struct TemplateEditForm: View {
    let template: AgentTemplate

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    // Basic fields
    @State private var name: String = ""
    @State private var kind: AgentTemplate.Kind = .custom
    @State private var command: String = ""
    @State private var envVarsText: String = ""

    // Agent config fields
    @State private var agentModel: String = ""
    @State private var agentSystemPromptFile: String = ""
    @State private var agentPermissionMode: String = ""
    @State private var agentEffort: String = ""
    @State private var agentAllowedTools: String = ""
    @State private var agentAdditionalFlags: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Template")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                field("Name") {
                    TextField("Template name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field("Kind") {
                    Picker("", selection: $kind) {
                        Text("Shell").tag(AgentTemplate.Kind.shell)
                        Text("Claude Code").tag(AgentTemplate.Kind.claudeCode)
                        Text("Custom").tag(AgentTemplate.Kind.custom)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                // Agent Configuration — only for non-shell kinds
                if kind != .shell {
                    agentConfigSection
                }

                sectionHeader("Terminal")

                field("Command") {
                    TextField("e.g. claude, python3", text: $command)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty for default shell")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                field("Environment") {
                    TextEditor(text: $envVarsText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 60)
                        .border(Color(.separatorColor), width: 0.5)
                    Text("KEY=VALUE, one per line")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            name = template.name
            kind = template.kind
            command = template.command ?? ""
            envVarsText = template.environmentVariables
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n")

            // Populate agent config fields from existing template
            if let agent = template.agent {
                agentModel = agent.model ?? ""
                agentSystemPromptFile = agent.systemPromptFile ?? ""
                agentPermissionMode = agent.permissionMode ?? ""
                agentEffort = agent.effort ?? ""
                agentAllowedTools = agent.allowedTools?.joined(separator: ",") ?? ""
                agentAdditionalFlags = agent.additionalFlags?.joined(separator: " ") ?? ""
            }
        }
    }

    // MARK: - Agent Configuration Section

    private var agentConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Agent Configuration")

            field("Model") {
                Picker("", selection: $agentModel) {
                    Text("(none)").tag("")
                    Text("opus").tag("opus")
                    Text("sonnet").tag("sonnet")
                    Text("haiku").tag("haiku")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            field("System Prompt") {
                HStack(spacing: 4) {
                    TextField("Path to .md file", text: $agentSystemPromptFile)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        browseSystemPromptFile()
                    }
                }
            }

            field("Permission Mode") {
                Picker("", selection: $agentPermissionMode) {
                    Text("(none)").tag("")
                    Text("default").tag("default")
                    Text("plan").tag("plan")
                    Text("auto").tag("auto")
                    Text("acceptEdits").tag("acceptEdits")
                    Text("dontAsk").tag("dontAsk")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            field("Effort") {
                Picker("", selection: $agentEffort) {
                    Text("(none)").tag("")
                    Text("low").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                    Text("max").tag("max")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            field("Allowed Tools") {
                TextField("Read,Grep,Bash", text: $agentAllowedTools)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated tool names")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            field("Additional Flags") {
                TextField("--verbose --no-session", text: $agentAdditionalFlags)
                    .textFieldStyle(.roundedBorder)
                Text("Space-separated CLI flags")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 4)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func browseSystemPromptFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = URL(fileURLWithPath: ("~/.claude" as NSString).expandingTildeInPath)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            agentSystemPromptFile = url.path
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let envVars = parseEnvironmentVariables(envVarsText)

        // Build AgentConfig from state if kind is not .shell
        let agentConfig: AgentTemplate.AgentConfig?? = {
            guard kind != .shell else {
                // Clear agent config for shell templates
                return .some(nil)
            }

            let model = agentModel.isEmpty ? nil : agentModel
            let systemPromptFile = agentSystemPromptFile.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : agentSystemPromptFile.trimmingCharacters(in: .whitespaces)
            let permissionMode = agentPermissionMode.isEmpty ? nil : agentPermissionMode
            let effort = agentEffort.isEmpty ? nil : agentEffort

            let allowedTools: [String]? = {
                let trimmed = agentAllowedTools.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }()

            let additionalFlags: [String]? = {
                let trimmed = agentAdditionalFlags.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.split(separator: " ").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }()

            // If all fields are empty, set agent to nil
            if model == nil && systemPromptFile == nil && permissionMode == nil
                && effort == nil && allowedTools == nil && additionalFlags == nil {
                return .some(nil)
            }

            return .some(AgentTemplate.AgentConfig(
                systemPromptFile: systemPromptFile,
                model: model,
                permissionMode: permissionMode,
                effort: effort,
                allowedTools: allowedTools,
                additionalFlags: additionalFlags
            ))
        }()

        store.updateTemplate(
            id: template.id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            command: trimmedCommand.isEmpty ? nil : trimmedCommand,
            environmentVariables: envVars,
            agent: agentConfig
        )
        dismiss()
    }

    /// Parses "KEY=VALUE" lines into a dictionary, ignoring malformed lines
    /// and filtering out security-sensitive environment variable keys.
    private func parseEnvironmentVariables(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            guard !AgentTemplate.dangerousEnvKeys.contains(key.uppercased()) else { continue }
            result[key] = value
        }
        return result
    }
}
