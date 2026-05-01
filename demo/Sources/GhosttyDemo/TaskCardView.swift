import SwiftUI
import GhosttyKit

// MARK: - TaskCardView

struct TaskCardView: View {
    let task: KanbanTask
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t
    @ObservedObject var dragState: DragDropState
    var insertedTaskId: UUID?

    @State private var isHovering = false
    @State private var showEditModal = false
    @State private var cardFrame: CGRect = .zero
    @State private var hasPoppedIn = false
    @Environment(\.themeColors) var colors
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(priorityColor).frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(task.title).font(.system(size: 12, weight: .medium))
                            .lineLimit(2).foregroundColor(colors.textPrimary)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { showEditModal = true }

                        Spacer()

                        Button(action: { boardState.toggleTaskExpanded(task.id) }) {
                            Image(systemName: task.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(colors.textMuted)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if !task.description.isEmpty {
                            Text(task.description).font(.system(size: 10))
                                .lineLimit(2).foregroundColor(colors.textSecondary)
                        }

                        HStack(spacing: 6) {
                            PriorityBadge(priority: task.priority)

                            if !task.tags.isEmpty {
                                ForEach(task.tags) { tag in
                                    Text(tag.displayName)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(tagTextColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(tagColor(tag))
                                        .cornerRadius(4)
                                }
                            }

                            Spacer()

                            if !task.sessions.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "terminal").font(.system(size: 9))
                                    Text("\(task.sessions.count)").font(.system(size: 9))
                                }
                                .foregroundColor(colors.textMuted)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { showEditModal = true }

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
                .stroke(
                    isHovering && !isBeingDragged ? colors.taskHoverBorder : colors.borderSubtle,
                    lineWidth: 1
                )
        )
        .overlay(
            isBeingDragged
                ? RoundedRectangle(cornerRadius: 8)
                    .stroke(colors.accent.opacity(0.2),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                : nil
        )
        .shadow(color: isBeingDragged ? Color.clear : Color.black.opacity(isHovering ? 0.08 : 0.04),
                radius: isHovering ? 6 : 2, y: isHovering ? 3 : 1)
        .opacity(isBeingDragged ? 0.35 : 1.0)
        .scaleEffect(popInScale)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: CardFramesKey.self,
                        value: cardFrame == .zero ? [:] : [task.id: cardFrame]
                    )
                    .onAppear {
                        updateFrame(geo)
                    }
                    .onChange(of: geo.frame(in: .named("board"))) { frame in
                        cardFrame = frame
                    }
            }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("board"))
                .onChanged { value in
                    guard cardFrame != .zero else { return }
                    if !dragState.isDragging {
                        dragState.start(task: task, cardFrame: cardFrame)
                    }
                    dragState.updateGhostPosition(at: value.location)
                }
                .onEnded { _ in
                    dragState.endDrag()
                }
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
        .onChange(of: insertedTaskId) { newId in
            if newId == task.id {
                hasPoppedIn = true
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                    hasPoppedIn = false
                }
            }
        }
        .sheet(isPresented: $showEditModal) {
            TaskEditModal(task: task, boardState: boardState)
        }
    }

    // MARK: - Computed

    private var isBeingDragged: Bool {
        dragState.isDragging && dragState.draggedTask?.id == task.id
    }

    private var popInScale: CGFloat {
        guard insertedTaskId == task.id else { return 1.0 }
        return hasPoppedIn ? 0.92 : 1.0
    }

    private var priorityColor: Color {
        switch task.priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return colors.accent
        case .p3: return colors.textMuted
        }
    }

    private var tagTextColor: Color {
        boardState.isDarkMode ? .white : Color(hex: "555555")
    }

    private func tagColor(_ tag: Tag) -> Color {
        switch tag {
        case .bug:  return colors.tagBug
        case .feat: return colors.tagFeat
        case .docs: return colors.tagDocs
        case .refac:return colors.tagRefac
        case .test: return colors.tagTest
        case .ui:   return colors.tagUI
        case .sec:  return colors.tagSec
        case .perf: return colors.tagPerf
        }
    }

    private func updateFrame(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .named("board"))
        if frame != cardFrame {
            DispatchQueue.main.async {
                cardFrame = frame
            }
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
    @Environment(\.themeColors) var colors

    var body: some View {
        VStack(spacing: 0) {
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

                HStack(spacing: 12) {
                    Button("Cancel") { showCreateSession = false }
                    Button("Create") {
                        _ = sessionManager.createSession(
                            for: taskId,
                            worktree: createWorktree,
                            branch: "",
                            cwd: boardState.workspacePath,
                            boardState: boardState
                        )
                        showCreateSession = false
                        createWorktree = false
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
