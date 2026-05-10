import SwiftUI

/// The Sessions tab content: a flat, time-sorted list of all sessions across projects.
///
/// Layout:
///   + New Session (full-width row → native flyout menu for project selection)
///   ─────────────────────────────────
///   ACTIVE    (sessions with a live indicator state)
///   ARCHIVE   (exited / never-run sessions)
struct RecentsListView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            newSessionRow

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)

            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !activeSessions.isEmpty {
                            SessionSectionHeader(title: "Active")
                            ForEach(activeSessions) { session in
                                sessionRow(for: session)
                            }
                        }

                        if !archiveSessions.isEmpty {
                            SessionSectionHeader(title: "Archive")
                            ForEach(archiveSessions) { session in
                                sessionRow(for: session)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Sessions")
            }

            Spacer(minLength: 0)
        }
        .background(.clear)
    }

    // MARK: - New Session Row

    private var newSessionRow: some View {
        Menu {
            ForEach(store.projects) { project in
                Button(project.name) { startNewSession(in: project) }
            }
        } label: {
            HStack(spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)
                Text("New Session")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 4)
            }
            .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
            .padding(.trailing, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(store.projects.isEmpty)
        .accessibilityLabel("New Session")
    }

    // MARK: - Session Row

    private func sessionRow(for session: AgentSession) -> some View {
        let projectName = store.projects
            .first { $0.id == session.projectId }?.name ?? "Unknown"
        let indicatorState = store.globalIndicatorStates[session.id] ?? .inactive
        return RecentsRowView(
            session: session,
            projectName: projectName,
            indicatorState: indicatorState,
            isActive: coordinator.activeSessionId == session.id,
            onTap: { coordinator.focusSession(id: session.id) }
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            GhostCharacterView(character: .blinky, color: Color(.tertiaryLabelColor))
                .frame(width: 48, height: 48)

            Text("No sessions yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sessions yet")
    }

    // MARK: - Data

    /// Sessions with a live indicator state — process is alive or actively tracked.
    var activeSessions: [AgentSession] {
        Self.sorted(sessions: store.sessions.filter {
            (store.globalIndicatorStates[$0.id] ?? .inactive) != .inactive
        })
    }

    /// Sessions that have exited, completed, or never had a live process this launch.
    var archiveSessions: [AgentSession] {
        Self.sorted(sessions: store.sessions.filter {
            (store.globalIndicatorStates[$0.id] ?? .inactive) == .inactive
        })
    }

    // MARK: - Actions

    private func startNewSession(in project: Project) {
        let template: AgentTemplate = {
            if let defaultId = project.defaultTemplateId,
               let t = store.templates.first(where: { $0.id == defaultId }) {
                return t
            }
            return store.templates.first(where: { $0.kind == .shell })
                ?? AgentTemplate.shell
        }()
        Task {
            await coordinator.createQuickSession(for: project, template: template)
        }
    }

    // MARK: - Sorting (static so tests can call without a view instance)

    /// Sort sessions most-recently-active first; nil `lastActiveAt` sinks to bottom.
    static func sorted(sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { lhs, rhs in
            switch (lhs.lastActiveAt, rhs.lastActiveAt) {
            case (let l?, let r?): return l > r
            case (.some, .none):   return true
            case (.none, .some):   return false
            case (.none, .none):   return false
            }
        }
    }
}

// MARK: - Section Header

private struct SessionSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(WorkspaceLayout.sectionHeaderForeground)
            .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding
                         + WorkspaceLayout.sidebarIconColumnWidth
                         + WorkspaceLayout.sidebarIconLabelSpacing)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview("Sessions — active + archive") {
    let store = WorkspaceStore(testingProjects: [
        Project(name: "ghostties", rootPath: "~/Code/ghostties"),
        Project(name: "portfolio", rootPath: "~/Code/portfolio"),
    ])
    let coordinator = SessionCoordinator()
    return RecentsListView()
        .environmentObject(store)
        .environmentObject(coordinator)
        .frame(width: 220, height: 500)
        .preferredColorScheme(.dark)
}

#Preview("Sessions — empty") {
    let store = WorkspaceStore(testingProjects: [])
    let coordinator = SessionCoordinator()
    return RecentsListView()
        .environmentObject(store)
        .environmentObject(coordinator)
        .frame(width: 220, height: 500)
        .preferredColorScheme(.dark)
}
#endif
