import SwiftUI

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

/// An inline sheet for editing a custom template's name, command, and environment variables.
struct TemplateEditForm: View {
    let template: AgentTemplate

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var kind: AgentTemplate.Kind = .custom
    @State private var command: String = ""
    @State private var envVarsText: String = ""

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
        .frame(width: 320)
        .onAppear {
            name = template.name
            kind = template.kind
            command = template.command ?? ""
            envVarsText = template.environmentVariables
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "\n")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let envVars = parseEnvironmentVariables(envVarsText)
        store.updateTemplate(
            id: template.id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            command: trimmedCommand.isEmpty ? nil : trimmedCommand,
            environmentVariables: envVars
        )
        dismiss()
    }

    /// Environment variable keys that could alter process loading behavior or
    /// override fundamental system paths.
    private static let dangerousEnvKeys: Set<String> = [
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "PYTHONPATH", "NODE_PATH", "RUBYLIB", "GEM_HOME", "GEM_PATH",
    ]

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
            guard !Self.dangerousEnvKeys.contains(key.uppercased()) else { continue }
            result[key] = value
        }
        return result
    }
}
