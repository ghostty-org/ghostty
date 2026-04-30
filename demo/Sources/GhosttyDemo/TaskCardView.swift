import SwiftUI
import GhosttyKit

// MARK: - TaskCardView

struct TaskCardView: View {
    let task: KanbanTask
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t

    @State private var isHovering = false
    @State private var showEditModal = false
    @Environment(\.themeColors) var colors

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Priority color strip
                Rectangle().fill(priorityColor).frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    // Title row + description + footer (task edit tap zone)
                    VStack(alignment: .leading, spacing: 4) {
                        // Title row
                        HStack {
                            Text(task.title).font(.system(size: 12, weight: .medium))
                                .lineLimit(2).foregroundColor(colors.textPrimary)
                            Spacer()
                            // Expand/collapse button
                            Button(action: { boardState.toggleTaskExpanded(task.id) }) {
                                Image(systemName: task.isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10)).foregroundColor(colors.textMuted)
                            }
                            .buttonStyle(.plain)
                        }

                        // Description snippet
                        if !task.description.isEmpty {
                            Text(task.description).font(.system(size: 10))
                                .lineLimit(2).foregroundColor(colors.textSecondary)
                        }

                        // Footer: priority badge + session count
                        HStack(spacing: 8) {
                            PriorityBadge(priority: task.priority)
                            if !task.sessions.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "terminal").font(.system(size: 9))
                                    Text("\(task.sessions.count)").font(.system(size: 9))
                                }
                                .foregroundColor(colors.textMuted)
                            }
                            Spacer()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { showEditModal = true }

                    // Expanded session panel (no task edit gesture)
                    if task.isExpanded {
                        SessionPanelView(
                            taskId: task.id,
                            sessions: task.sessions,
                            boardState: boardState,
                            sessionManager: sessionManager,
                            tabManager: tabManager,
                            ghosttyApp: ghosttyApp
                        )
                    }
                }
                .padding(8)
            }
        }
        .background(colors.taskBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? colors.taskHoverBorder : colors.borderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .draggable(task.id.uuidString)
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showEditModal) {
            TaskEditModal(task: task, boardState: boardState)
        }
    }

    var priorityColor: Color {
        switch task.priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return colors.accent
        case .p3: return colors.textMuted
        }
    }
}

// MARK: - PriorityBadge

struct PriorityBadge: View {
    let priority: Priority
    @Environment(\.themeColors) var colors

    var body: some View {
        Text(priority.displayName)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(badgeColor).cornerRadius(3)
    }

    var badgeColor: Color {
        switch priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return colors.accent
        case .p3: return colors.textMuted
        }
    }
}

// MARK: - SessionPanelView

struct SessionPanelView: View {
    let taskId: UUID
    let sessions: [Session]
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t

    @State private var showCreateSession = false
    @State private var createWorktree = false
    @State private var createBranch = "main"
    @Environment(\.themeColors) var colors

    var body: some View {
        VStack(spacing: 0) {
            // Session list
            ForEach(sessions) { session in
                SessionRowView(
                    session: session,
                    onResume: { sessionManager.resumeSession(session) },
                    onDelete: { boardState.removeSession(from: taskId, sessionId: session.id) }
                )
                if session.id != sessions.last?.id {
                    Divider().padding(.leading, 24)
                }
            }

            // Add session button
            Button(action: { showCreateSession = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle").font(.system(size: 10))
                    Text("Add Session").font(.system(size: 10))
                }
                .foregroundColor(colors.accent)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(colors.accent.opacity(0.08))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(8)
        .background(colors.sessionPanelBg)
        .cornerRadius(6)
        .sheet(isPresented: $showCreateSession) {
            VStack(spacing: 16) {
                Text("New Session").font(.headline)

                Toggle("Create worktree", isOn: $createWorktree)

                if createWorktree {
                    HStack {
                        Text("Branch:").font(.caption)
                        TextField("branch name", text: $createBranch)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 12) {
                    Button("Cancel") { showCreateSession = false }
                    Button("Create") {
                        _ = sessionManager.createSession(
                            for: taskId,
                            worktree: createWorktree,
                            branch: createBranch,
                            boardState: boardState
                        )
                        showCreateSession = false
                        createWorktree = false
                        createBranch = "main"
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 300)
            .background(colors.modalBg)
        }
    }
}

// MARK: - SessionRowView

struct SessionRowView: View {
    let session: Session
    let onResume: () -> Void
    let onDelete: () -> Void
    @Environment(\.themeColors) var colors

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 6) {
                // Status dot: green=running, gray=idle, orange=needInput
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(session.relativeTimestamp)
                            .font(.system(size: 9))
                            .foregroundColor(colors.textMuted)

                        if session.isWorkTree {
                            Text("worktree")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(colors.worktree)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(colors.worktree.opacity(0.15))
                                .cornerRadius(2)
                        }

                        if !session.branch.isEmpty {
                            Text(session.branch)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(colors.textMuted)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(colors.borderSubtle)
                                .cornerRadius(2)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Remove session")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var statusColor: Color {
        switch session.status {
        case .running: return colors.success
        case .idle: return colors.textMuted
        case .needInput: return colors.warning
        }
    }
}
