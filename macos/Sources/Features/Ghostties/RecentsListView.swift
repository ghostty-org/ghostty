import SwiftUI

/// The Sessions tab content: a flat, time-sorted list of all sessions across projects.
///
/// Mirrors the recents list pattern from Claude Code — most recently active sessions
/// appear at the top, with a "+ New Session" button pinned to the header.
/// Sessions with no `lastActiveAt` timestamp sink below timestamped sessions.
struct RecentsListView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            newSessionHeader

            if sortedSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sortedSessions) { session in
                            let projectName = store.projects
                                .first { $0.id == session.projectId }?.name ?? "Unknown"
                            let indicatorState = store.globalIndicatorStates[session.id]
                                ?? .inactive
                            RecentsRowView(
                                session: session,
                                projectName: projectName,
                                indicatorState: indicatorState,
                                isActive: coordinator.activeSessionId == session.id,
                                onTap: { coordinator.focusSession(id: session.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Recent sessions")
            }

            Spacer(minLength: 0)
        }
        .background(.clear)
    }

    // MARK: - Header

    private var newSessionHeader: some View {
        HStack {
            Spacer(minLength: 0)

            Button(action: startNewSession) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Session")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.primary.opacity(0.60))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(mostRecentProject == nil)
            .help("New session")
            .accessibilityLabel("New session")
            .padding(.trailing, 10)
        }
        .frame(height: 28)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
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

    /// Sessions sorted most-recently-active first.
    /// Sessions with no `lastActiveAt` timestamp appear below all timestamped sessions,
    /// ordered by their position in the store (insertion order).
    var sortedSessions: [AgentSession] {
        Self.sorted(sessions: store.sessions)
    }

    /// Finds the project that owns the most recently active session.
    /// Falls back to `store.projects.first` if no sessions have timestamps.
    private var mostRecentProject: Project? {
        let recentSession = Self.sorted(sessions: store.sessions).first
        if let projectId = recentSession?.projectId {
            return store.projects.first { $0.id == projectId }
        }
        return store.projects.first
    }

    // MARK: - Actions

    private func startNewSession() {
        guard let project = mostRecentProject else { return }
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

    // MARK: - Background

    private var backgroundColor: Color {
        Color(nsColor: colorScheme == .dark
              ? WorkspaceLayout.chromeBackgroundDark
              : WorkspaceLayout.chromeBackgroundLight)
    }
}

#if DEBUG
#Preview("Recents — populated") {
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

#Preview("Recents — empty") {
    let store = WorkspaceStore(testingProjects: [])
    let coordinator = SessionCoordinator()
    return RecentsListView()
        .environmentObject(store)
        .environmentObject(coordinator)
        .frame(width: 220, height: 500)
        .preferredColorScheme(.dark)
}
#endif
