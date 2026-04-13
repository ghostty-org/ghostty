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

            // Expanded children: grouped sessions + "New Session" button
            if isExpanded {
                expandedSessionList
                newSessionButton
                    .padding(.leading, 20)
            }
        }
        .background(expandedContainerBackground)
    }

    // MARK: - Expanded Session List

    /// Sessions for this project, grouped into `.active` / `.recent` / `.idle`
    /// buckets. Drag-drop reordering still respects the project's flat
    /// `sortOrder` — drag is bucket-local for now (R-D requirements).
    private var sessionGroups: [(SessionBucket, [AgentSession])] {
        store.sessionGroups(forProject: project.id)
    }

    @ViewBuilder
    private var expandedSessionList: some View {
        let groups = sessionGroups
        let multipleBuckets = groups.count > 1

        ForEach(groups, id: \.0) { bucket, bucketSessions in
            if multipleBuckets {
                SessionGroupHeader(bucket: bucket)
                    .padding(.leading, 20)
                    .padding(.top, bucket == groups.first?.0 ? 2 : 6)
            }

            ForEach(Array(bucketSessions.enumerated()), id: \.element.id) { index, session in
                sessionRowView(
                    for: session,
                    index: index,
                    bucketSessions: bucketSessions
                )
            }
        }
    }

    @ViewBuilder
    private func sessionRowView(
        for session: AgentSession,
        index: Int,
        bucketSessions: [AgentSession]
    ) -> some View {
        SessionRow(
            session: session,
            indicatorState: coordinator.indicatorState(for: session.id),
            ghostCharacter: project.ghostCharacter,
            isActive: coordinator.activeSessionId == session.id,
            isEditing: editingSessionId == session.id,
            agentTemplateName: agentTemplateName(for: session),
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
                    moveWithinBucket(
                        session: session,
                        from: index,
                        to: index - 1,
                        bucketSessions: bucketSessions
                    )
                }
            }
            if index < bucketSessions.count - 1 {
                Button("Move Down") {
                    moveWithinBucket(
                        session: session,
                        from: index,
                        to: index + 1,
                        bucketSessions: bucketSessions
                    )
                }
            }
            if index > 0 || index < bucketSessions.count - 1 {
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
            // Only allow drag-drop within the same bucket — cross-bucket
            // reorders would let the user move "Idle" sessions ahead of
            // "Active" ones, which fights the bucketing logic.
            guard bucketSessions.contains(where: { $0.id == droppedId }) else {
                return false
            }
            guard let targetIndexInBucket = bucketSessions.firstIndex(where: { $0.id == session.id })
            else { return false }
            moveWithinBucket(
                draggedId: droppedId,
                toIndexInBucket: targetIndexInBucket,
                bucketSessions: bucketSessions
            )
            return true
        }
    }

    /// Translate a within-bucket move into the project-flat `moveSession` call
    /// the store understands. The flat list is the source of truth for
    /// `sortOrder`; bucket order is computed downstream.
    private func moveWithinBucket(
        session: AgentSession,
        from sourceIndexInBucket: Int,
        to targetIndexInBucket: Int,
        bucketSessions: [AgentSession]
    ) {
        guard targetIndexInBucket >= 0,
              targetIndexInBucket < bucketSessions.count else { return }
        let target = bucketSessions[targetIndexInBucket]
        let flatSessions = store.sessions(for: project.id)
        guard let flatTargetIndex = flatSessions.firstIndex(where: { $0.id == target.id })
        else { return }
        store.moveSession(id: session.id, toIndex: flatTargetIndex, inProject: project.id)
    }

    /// Drag-drop variant: the dragged session ID is not necessarily the row
    /// being rendered — find its flat index and move it next to the target.
    private func moveWithinBucket(
        draggedId: UUID,
        toIndexInBucket: Int,
        bucketSessions: [AgentSession]
    ) {
        guard toIndexInBucket >= 0,
              toIndexInBucket < bucketSessions.count else { return }
        let target = bucketSessions[toIndexInBucket]
        let flatSessions = store.sessions(for: project.id)
        guard let flatTargetIndex = flatSessions.firstIndex(where: { $0.id == target.id })
        else { return }
        store.moveSession(id: draggedId, toIndex: flatTargetIndex, inProject: project.id)
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
            HStack(spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
                // Ghost icon — color reflects the project's aggregate activity
                // state (terracotta = live work, primary = recent, muted = idle).
                // The ghost collapses two signals (project identity + activity)
                // into one mark, per the smart-sections design.
                //
                // The frame width matches `sidebarIconColumnWidth` so the
                // ghost's x-center lines up with the section-header icon
                // (pin/bolt/clock/grid) on the row directly above it.
                Group {
                    if let ghost = project.ghostCharacter {
                        GhostCharacterView(
                            character: ghost,
                            color: store.projectActivityColor(for: project)
                        )
                        .frame(width: 12, height: 12)
                    }
                }
                .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)

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
            .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
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
        case .error:          return Color(nsColor: .systemRed)
        case .needsAttention: return WorkspaceLayout.needsAttentionPurple
        case .waiting:        return WorkspaceLayout.waitingTerracotta
        case .longRunning:    return Color(nsColor: .systemYellow)
        case .processing:     return Color(nsColor: .systemGreen)
        case .idle:           return Color(.secondaryLabelColor)
        case .inactive:       return Color(.tertiaryLabelColor)
        }
    }

    // MARK: - Sessions

    private var sessions: [AgentSession] {
        store.sessions(for: project.id)
    }

    /// Returns the template name if the session was launched with agent config, nil otherwise.
    private func agentTemplateName(for session: AgentSession) -> String? {
        guard let template = store.templates.first(where: { $0.id == session.templateId }),
              template.agent != nil else {
            return nil
        }
        return template.name
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

        // No pre-check needed — SessionCoordinator.createSession() calls
        // buildCommand() itself and handles missing prompt files gracefully.
        coordinator.clearRuntime(id: session.id)
        Task {
            await coordinator.createSession(session: session, template: template, project: project)
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

// MARK: - Session Group Header

/// Smaller, subtler variant of the sidebar section header — used inside an
/// expanded project to label the "Active / Recent / Idle" buckets when more
/// than one is populated. Shares the muted vocabulary of the top-level headers
/// but at a smaller scale because they're nested.
private struct SessionGroupHeader: View {
    let bucket: SessionBucket

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10, alignment: .center)

            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)

            Spacer(minLength: 0)
        }
        .foregroundStyle(WorkspaceLayout.sessionGroupHeaderForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        switch bucket {
        case .active: return "Active"
        case .recent: return "Recent"
        case .idle:   return "Idle"
        }
    }

    private var iconName: String {
        switch bucket {
        case .active: return "bolt.fill"
        case .recent: return "clock.fill"
        case .idle:   return "moon.zzz.fill"
        }
    }
}
