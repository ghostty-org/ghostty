import SwiftUI

/// A popover presenting available session templates for a project.
///
/// Shown when the user clicks "New Session" in the detail panel. Selecting a
/// template creates a new AgentSession, wires it to a Ghostty surface, and
/// inserts the surface into the split tree.
struct TemplatePickerView: View {
    let project: Project

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Session")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            ForEach(store.templates) { template in
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
            }
        }
        .padding(.bottom, 8)
        .frame(width: 180)
    }

    private func iconName(for template: SessionTemplate) -> String {
        if template.command == "claude" {
            return "sparkle"
        }
        return "terminal"
    }

    private func createSession(from template: SessionTemplate) {
        let sessionName = "\(template.name) — \(project.name)"
        let session = store.addSession(
            name: sessionName,
            templateId: template.id,
            projectId: project.id
        )
        coordinator.createSession(session: session, template: template, project: project)
        dismiss()
    }
}
