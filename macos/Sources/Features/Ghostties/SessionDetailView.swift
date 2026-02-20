import SwiftUI

/// Shows the session list for a selected project in the detail panel.
///
/// Displays active and exited sessions with status indicators, supports
/// click-to-focus, context menu actions, and a "New Session" button
/// that presents a template picker.
struct SessionDetailView: View {
    let project: Project

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var coordinator: SessionCoordinator

    @State private var showingTemplatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sessionList
            Spacer(minLength: 0)
            Divider()
            newSessionButton
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(project.rootPath)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Session List

    private var sessions: [AgentSession] {
        store.sessions(for: project.id)
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessions.isEmpty {
            emptySessionState
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            status: coordinator.statuses[session.id] ?? .exited,
                            isActive: coordinator.activeSessionId == session.id
                        )
                        .onTapGesture {
                            coordinator.focusSession(id: session.id)
                        }
                        .contextMenu {
                            if coordinator.isRunning(id: session.id) {
                                Button("Close") {
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
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptySessionState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)

            Text("No sessions")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - New Session Button

    private var newSessionButton: some View {
        Button(action: { showingTemplatePicker = true }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                Text("New Session")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .popover(isPresented: $showingTemplatePicker) {
            TemplatePickerView(project: project)
        }
    }

    // MARK: - Actions

    private func relaunchSession(_ session: AgentSession) {
        guard let template = store.templates.first(where: { $0.id == session.templateId }) else {
            return
        }
        coordinator.clearRuntime(id: session.id)
        coordinator.createSession(session: session, template: template, project: project)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: AgentSession
    let status: SessionStatus
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(session.name)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(statusLabel)\(isActive ? ", active" : "")")
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .exited: return Color(.tertiaryLabelColor)
        case .killed: return .red
        }
    }

    private var statusLabel: String {
        switch status {
        case .running: return "running"
        case .exited: return "exited"
        case .killed: return "killed"
        }
    }
}
