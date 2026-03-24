import SwiftUI

/// SwiftUI view shown inside the menu bar popover.
///
/// Lists active sessions grouped by project. Each row shows a status dot,
/// session name, and template name. Clicking a row posts a notification
/// to focus that session in its coordinator's window.
struct MenuBarDropdownView: View {
    @ObservedObject private var store = WorkspaceStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if activeProjects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(activeProjects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            // "Open Ghostties" button at bottom.
            Button(action: openApp) {
                Text("Open Ghostties")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .frame(width: 280)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Project name header.
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            // Session rows.
            ForEach(activeSessions(for: project.id)) { session in
                sessionRow(session)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession) -> some View {
        let state = store.globalIndicatorStates[session.id] ?? .inactive
        let templateName = store.templates.first(where: { $0.id == session.templateId })?.name

        Button(action: { focusSession(session.id) }) {
            HStack(spacing: 8) {
                // Status dot.
                Circle()
                    .fill(dotColor(for: state))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if let templateName {
                        Text(templateName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.00001)) // invisible hit area
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No active sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Data

    /// Projects that have at least one session with a non-inactive indicator state.
    private var activeProjects: [Project] {
        store.sortedProjects.filter { project in
            !activeSessions(for: project.id).isEmpty
        }
    }

    /// Sessions for a project that have a live (non-inactive) indicator state.
    private func activeSessions(for projectId: UUID) -> [AgentSession] {
        store.sessions(for: projectId).filter { session in
            let state = store.globalIndicatorStates[session.id] ?? .inactive
            return state != .inactive
        }
    }

    // MARK: - Actions

    private func focusSession(_ sessionId: UUID) {
        // Close the popover first so it doesn't block the window activation.
        NSApp.keyWindow?.contentViewController?.dismiss(nil)
        NotificationCenter.default.post(
            name: .menuBarFocusSession,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the first visible terminal window to the front.
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Colors

    private func dotColor(for state: SessionIndicatorState) -> Color {
        switch state {
        case .error:          return Color(.systemRed)
        case .needsAttention: return WorkspaceLayout.needsAttentionPurple
        case .waiting:        return WorkspaceLayout.waitingTerracotta
        case .longRunning:    return Color(.systemYellow)
        case .processing:     return Color(.systemGreen)
        case .idle:           return Color.primary.opacity(0.3)
        case .inactive:       return Color.clear
        }
    }
}
