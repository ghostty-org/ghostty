import SwiftUI

/// A project row in the disclosure list that expands to show sessions inline.
///
/// Absorbs functionality from the former IconRailView (context menu, settings popover)
/// and SessionDetailView (session list, rename, drag/drop, new session button).
struct ProjectDisclosureRow: View {
    let project: Project
    @Binding var isExpanded: Bool
    @Binding var selectedProjectId: UUID?

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var settingsProject: Project?
    @State private var showingTemplatePicker = false
    @State private var editingSessionId: UUID?
    @State private var editingName: String = ""
    @State private var isHeaderHovered = false
    @State private var isNewSessionHovered = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 2) {
            // Project header row (tap to expand/collapse)
            projectHeader

            // Expanded children: sessions + "New Session" button
            if isExpanded {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRow(
                        session: session,
                        indicatorState: coordinator.indicatorState(for: session.id),
                        ghostCharacter: project.ghostCharacter,
                        isActive: coordinator.activeSessionId == session.id,
                        isEditing: editingSessionId == session.id,
                        editingName: editingSessionId == session.id ? $editingName : .constant(""),
                        isRenameFocused: $renameFieldFocused,
                        onCommitRename: { commitRename(session: session) },
                        onCancelRename: { cancelRename() }
                    )
                    .padding(.leading, 20)
                    .onTapGesture(count: 2) {
                        beginRename(session: session)
                    }
                    .onTapGesture {
                        selectedProjectId = project.id
                        coordinator.focusSession(id: session.id)
                    }
                    .contextMenu {
                        Button("Rename") {
                            beginRename(session: session)
                        }
                        Divider()
                        if index > 0 {
                            Button("Move Up") {
                                store.moveSession(id: session.id, toIndex: index - 1, inProject: project.id)
                            }
                        }
                        if index < sessions.count - 1 {
                            Button("Move Down") {
                                store.moveSession(id: session.id, toIndex: index + 1, inProject: project.id)
                            }
                        }
                        if index > 0 || index < sessions.count - 1 {
                            Divider()
                        }
                        if coordinator.isRunning(id: session.id) {
                            Button("Stop") {
                                coordinator.closeSession(id: session.id)
                            }
                        } else {
                            Button("Relaunch") {
                                relaunchSession(session)
                            }
                            Button("Remove", role: .destructive) {
                                coordinator.clearRuntime(id: session.id)
                                store.removeSession(id: session.id)
                            }
                        }
                    }
                    .draggable(session.id.uuidString) {
                        Text(session.name)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let droppedString = items.first,
                              let droppedId = UUID(uuidString: droppedString) else { return false }
                        guard let targetIndex = sessions.firstIndex(where: { $0.id == session.id }) else { return false }
                        store.moveSession(id: droppedId, toIndex: targetIndex, inProject: project.id)
                        return true
                    }
                }

                newSessionButton
                    .padding(.leading, 20)
            }
        }
        .background(expandedContainerBackground)
    }

    // MARK: - Project Header

    private var projectHeader: some View {
        Button {
            let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeInOut(duration: 0.2)
            withAnimation(animation) {
                isExpanded.toggle()
            }
            selectedProjectId = project.id
        } label: {
            HStack(spacing: 4) {
                PixelChevronView(
                    color: projectHeaderColor,
                    isExpanded: isExpanded
                )

                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(-0.13)
                    .lineLimit(1)

                Spacer()

                if isExpanded {
                    Button(action: handleNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("New session")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHeaderHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .contextMenu {
            Button("Settings\u{2026}") {
                settingsProject = project
            }
            Divider()
            Button(project.isPinned ? "Unpin" : "Pin") {
                store.togglePin(id: project.id)
            }
            Divider()
            Button("Remove", role: .destructive) {
                store.removeProject(id: project.id)
            }
        }
        .popover(
            isPresented: Binding(
                get: { settingsProject?.id == project.id },
                set: { if !$0 { settingsProject = nil } }
            ),
            arrowEdge: .trailing
        ) {
            ProjectSettingsView(project: project) {
                settingsProject = nil
            }
            .environmentObject(store)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name) project\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand")")
    }

    // MARK: - Container Background

    @ViewBuilder
    private var expandedContainerBackground: some View {
        if isExpanded {
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? WorkspaceLayout.expandedContainerDark : WorkspaceLayout.expandedContainerLight)
        }
    }

    // MARK: - Status

    /// The highest-priority indicator state among all sessions in this project.
    private var projectHeaderIndicator: SessionIndicatorState {
        store.sessions(for: project.id)
            .map { coordinator.indicatorState(for: $0.id) }
            .max() ?? .inactive
    }

    /// Map the aggregated indicator to a chevron color (same palette as session rows).
    private var projectHeaderColor: Color {
        switch projectHeaderIndicator {
        case .error:       return Color(nsColor: .systemRed)
        case .waiting:     return WorkspaceLayout.waitingTerracotta
        case .longRunning: return Color(nsColor: .systemYellow)
        case .processing:  return Color(nsColor: .systemGreen)
        case .idle:        return Color(.secondaryLabelColor)
        case .inactive:    return Color(.tertiaryLabelColor)
        }
    }

    // MARK: - Sessions

    private var sessions: [AgentSession] {
        store.sessions(for: project.id)
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        Button(action: handleNewSession) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                Text("New Session")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isNewSessionHovered ? .secondary : .tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onHover { isNewSessionHovered = $0 }
        .popover(isPresented: $showingTemplatePicker) {
            TemplatePickerView(project: project)
        }
    }

    // MARK: - Actions

    private func handleNewSession() {
        selectedProjectId = project.id
        if let defaultId = project.defaultTemplateId,
           !NSEvent.modifierFlags.contains(.option),
           let template = store.templates.first(where: { $0.id == defaultId }) {
            Task {
                await coordinator.createQuickSession(for: project, template: template)
            }
        } else {
            showingTemplatePicker = true
        }
    }

    private func relaunchSession(_ session: AgentSession) {
        guard let template = store.templates.first(where: { $0.id == session.templateId }) else {
            // Template was deleted — cannot relaunch.
            print("Warning: Template for session '\(session.name)' not found (templateId: \(session.templateId))")
            return
        }

        // For agent templates, verify the command can be built.
        // If a prompt file is missing, fall back to the base command.
        var launchTemplate = template
        if template.agent != nil {
            let built = template.buildCommand()
            if built.isEmpty && template.command != nil {
                // buildCommand returned empty but template has a base command —
                // something went wrong with agent config. Launch with base command only.
                print("Warning: Agent template '\(template.name)' buildCommand() returned empty, using base command")
                launchTemplate = AgentTemplate(
                    id: template.id,
                    name: template.name,
                    kind: template.kind,
                    command: template.command,
                    environmentVariables: template.environmentVariables,
                    workingDirectory: template.workingDirectory,
                    isDefault: template.isDefault,
                    isGlobal: template.isGlobal,
                    projectId: template.projectId,
                    agent: nil
                )
            }
        }

        coordinator.clearRuntime(id: session.id)
        Task {
            await coordinator.createSession(session: session, template: launchTemplate, project: project)
        }
    }

    // MARK: - Rename

    private func beginRename(session: AgentSession) {
        editingName = session.name
        editingSessionId = session.id
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename(session: AgentSession) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.name {
            store.renameSession(id: session.id, name: trimmed)
        }
        editingSessionId = nil
    }

    private func cancelRename() {
        editingSessionId = nil
    }
}
