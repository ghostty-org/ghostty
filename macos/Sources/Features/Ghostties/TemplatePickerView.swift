import SwiftUI
import UniformTypeIdentifiers

/// A popover presenting available session templates for a project.
///
/// Shown when the user clicks "New Session" in the detail panel. Selecting a
/// template creates a new AgentSession, wires it to a Ghostty surface, and
/// inserts the surface into the split tree.
///
/// Templates are organized into sections:
/// - **PRESETS**: File-based presets from `~/.ghostties/presets/`
/// - **BUILT-IN**: Shell and Claude Code defaults
/// - **YOUR TEMPLATES**: User-created custom templates
///
/// Clicking a preset shows a preview card (unless "Don't show previews" is set).
/// Non-default templates have a context menu for Edit, Duplicate, and Delete.
struct TemplatePickerView: View {
    let project: Project

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var editingTemplate: AgentTemplate?
    @State private var showDeleteConfirmation = false
    @State private var templateToDelete: AgentTemplate?
    @State private var previewingTemplate: AgentTemplate?

    @AppStorage("ghostties.skipPresetPreview") private var skipPresetPreview = false

    /// Preset templates loaded from `~/.ghostties/presets/` (have a `templateDescription`).
    private var presetTemplates: [AgentTemplate] {
        store.templates.filter { $0.templateDescription != nil && $0.isDefault }
    }

    /// Built-in templates (Shell, Claude Code, etc.) — no preset description.
    private var builtinTemplates: [AgentTemplate] {
        store.templates.filter { $0.templateDescription == nil && $0.isDefault }
    }

    /// User-created custom templates.
    private var customTemplates: [AgentTemplate] {
        store.templates.filter { !$0.isDefault }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if previewingTemplate != nil {
                previewCard
            } else {
                templateList
            }
        }
        .frame(width: 220)
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

    // MARK: - Template List

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Presets section
            if !presetTemplates.isEmpty {
                sectionHeader("PRESETS")
                    .padding(.top, 8)

                ForEach(presetTemplates) { template in
                    templateRow(template, isPreset: true)
                }
            }

            // Built-in section
            if !builtinTemplates.isEmpty {
                if !presetTemplates.isEmpty {
                    Divider()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }

                ForEach(builtinTemplates) { template in
                    templateRow(template)
                }
            }

            // Custom templates section
            if !customTemplates.isEmpty {
                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                sectionHeader("YOUR TEMPLATES")

                ForEach(customTemplates) { template in
                    templateRow(template)
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            addCustomButton

            Spacer()
                .frame(height: 8)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    // MARK: - Template Row

    /// Unified row builder for presets, built-ins, and custom templates.
    ///
    /// - Parameters:
    ///   - template: The template to display.
    ///   - isPreset: Whether this is a file-based preset (uses preview-or-launch tap behavior).
    @ViewBuilder
    private func templateRow(_ template: AgentTemplate, isPreset: Bool = false) -> some View {
        Button(action: { isPreset ? handlePresetTap(template) : createSession(from: template) }, label: {
            HStack(spacing: 8) {
                Image(systemName: resolvedIcon(for: template))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 12, weight: .medium))
                    if let description = template.templateDescription {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !isPreset, let command = template.command {
                        Text(command)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else if !isPreset {
                        Text("Default shell")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .contextMenu {
            if isPreset {
                Button("Duplicate and Edit...") {
                    if let copy = store.duplicateTemplate(id: template.id) {
                        editingTemplate = copy
                    }
                }
                if template.templateDescription != nil {
                    Button("Edit Preset File...") {
                        openPresetInEditor(template)
                    }
                }
            } else if template.isDefault {
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

    // MARK: - Preview Card

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let template = previewingTemplate {
                // Header: icon + name
                HStack(spacing: 8) {
                    Image(systemName: resolvedIcon(for: template))
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text(template.name)
                        .font(.system(size: 13, weight: .semibold))
                }

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    if let model = template.agent?.model {
                        metadataRow(label: "Model", value: model)
                    }
                    if let access = template.accessLabel {
                        metadataRow(label: "Access", value: access)
                    }
                    if let permissionMode = template.agent?.permissionMode {
                        metadataRow(label: "Mode", value: permissionMode)
                    }
                }

                // Description
                if let description = template.templateDescription {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Don't show previews toggle
                Toggle(isOn: $skipPresetPreview) {
                    Text("Don't show previews")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)

                // Action buttons
                HStack {
                    Button("Back") {
                        previewingTemplate = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Launch") {
                        createSession(from: template)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
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
            .padding(.vertical, 5)
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
        case .browser: return "globe"
        }
    }

    /// Resolve the display icon for a template, preferring its explicit icon
    /// over the kind-based default.
    private func resolvedIcon(for template: AgentTemplate) -> String {
        template.icon ?? iconName(for: template)
    }

    private func handlePresetTap(_ template: AgentTemplate) {
        if skipPresetPreview {
            createSession(from: template)
        } else {
            previewingTemplate = template
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

    private func openPresetInEditor(_ template: AgentTemplate) {
        // Find the preset file by name in ~/.ghostties/presets/
        let filename = template.name.lowercased().replacingOccurrences(of: " ", with: "-") + ".md"
        let path = (PresetLoader.presetsDirectoryPath as NSString).appendingPathComponent(filename)

        // Validate the resolved path stays within the presets directory.
        let resolvedPath = (path as NSString).standardizingPath
        let presetsDir = (PresetLoader.presetsDirectoryPath as NSString).standardizingPath
        guard resolvedPath.hasPrefix(presetsDir + "/") else { return }

        let url = URL(fileURLWithPath: resolvedPath)
        if FileManager.default.fileExists(atPath: resolvedPath) {
            NSWorkspace.shared.open(url)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Template")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
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
                            .frame(height: 48)
                            .border(Color(.separatorColor), width: 0.5)
                        Text("KEY=VALUE, one per line")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 420)

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
