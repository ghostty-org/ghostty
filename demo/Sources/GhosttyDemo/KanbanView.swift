import SwiftUI
import GhosttyKit

// MARK: - DragDropState

final class DragDropState: ObservableObject {
    @Published var isDragging = false
    @Published var draggedTask: KanbanTask?
    @Published var ghostRect: CGRect = .zero
    @Published var targetStatus: Status?
    @Published var targetIndex: Int = 0
    @Published var sourceStatus: Status?

    var columnFrames: [Status: CGRect] = [:]
    var cardFrames: [UUID: CGRect] = [:]
    private var _tasks: [KanbanTask] = []

    var cardOrigin: CGPoint = .zero

    func start(task: KanbanTask, cardFrame: CGRect) {
        draggedTask = task
        isDragging = true
        sourceStatus = task.status
        targetStatus = task.status
        cardOrigin = cardFrame.origin
        ghostRect = cardFrame
        updateTargetHitTest()
    }

    func updateGhostPosition(at location: CGPoint) {
        ghostRect.origin = CGPoint(
            x: location.x - ghostRect.width / 2,
            y: location.y - ghostRect.height / 2
        )
        updateTargetHitTest()
    }

    func updateTargetHitTest() {
        guard isDragging else { return }
        let center = CGPoint(x: ghostRect.midX, y: ghostRect.midY)

        var bestStatus: Status?
        for (status, frame) in columnFrames {
            let expanded = frame.insetBy(dx: -15, dy: -5)
            if expanded.contains(center) {
                bestStatus = status
                break
            }
        }
        targetStatus = bestStatus

        if let target = bestStatus {
            let cardsInCol = cardFrames
                .filter { kv in
                    _tasks.first(where: { $0.id == kv.key && $0.status == target }) != nil
                }
                .sorted { $0.value.midY < $1.value.midY }

            var idx = 0
            for (i, (_, frame)) in cardsInCol.enumerated() {
                if center.y < frame.midY { break }
                idx = i + 1
            }
            targetIndex = idx
        }
    }

    func setTasks(_ tasks: [KanbanTask]) {
        _tasks = tasks
    }

    func endDrag() {
        isDragging = false
    }

    func cancelDrag() {
        isDragging = false
        draggedTask = nil
        targetStatus = nil
    }
}

// MARK: - Frame Preferences

struct ColumnFramesKey: PreferenceKey {
    static var defaultValue: [Status: CGRect] = [:]
    static func reduce(value: inout [Status: CGRect], nextValue: () -> [Status: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CardFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - KanbanView

struct KanbanView: View {
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t

    @Environment(\.themeColors) private var colors
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var dragState = DragDropState()
    @State private var columnFrames: [Status: CGRect] = [:]
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var insertedTaskId: UUID?
    @State private var escMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            KanbanToolbar(boardState: boardState)

            Divider()

            GeometryReader { geometry in
                let isHorizontal = geometry.size.width >= Status.columnMinWidth * 1.5
                ZStack {
                    if isHorizontal {
                        horizontalContent(availableHeight: geometry.size.height)
                    } else {
                        verticalContent
                    }
                    if dragState.isDragging, let task = dragState.draggedTask {
                        dragGhostView(for: task)
                    }
                }
                .coordinateSpace(name: "board")
            }
        }
        .background(colors.bgPrimary)
        .onPreferenceChange(ColumnFramesKey.self) { frames in
            columnFrames = frames
            dragState.columnFrames = frames
        }
        .onPreferenceChange(CardFramesKey.self) { frames in
            cardFrames = frames
            dragState.cardFrames = frames
        }
        .onChange(of: dragState.isDragging) { newValue in
            if !newValue {
                DispatchQueue.main.async {
                    executeDrop()
                }
            }
        }
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53, dragState.isDragging {
                    DispatchQueue.main.async { dragState.cancelDrag() }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            dragState.cancelDrag()
        }
        .onReceive(boardState.$tasks) { tasks in
            dragState.setTasks(tasks)
        }
    }
    // MARK: - Drag Ghost

    private func dragGhostView(for task: KanbanTask) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(priorityColor(task.priority))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .foregroundColor(colors.textPrimary)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundColor(colors.textSecondary)
                    }
                    if !task.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(task.tags) { tag in
                                Text(tag.displayName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(tagTextColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(themeTagColor(tag))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        PriorityBadge(priority: task.priority)
                        if !task.sessions.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "terminal").font(.system(size: 9))
                                Text("\(task.sessions.count)").font(.system(size: 9))
                            }
                            .foregroundColor(colors.textMuted)
                        }
                    }
                }
                .padding(8)
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: dragState.ghostRect.width)
        .background(colors.taskBg)
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
        .position(x: dragState.ghostRect.midX, y: dragState.ghostRect.midY)
        .allowsHitTesting(false)
        .zIndex(9999)
    }

    // MARK: - Drop Execution

    private func executeDrop() {
        guard let task = dragState.draggedTask,
              let source = dragState.sourceStatus,
              let target = dragState.targetStatus else {
            dragState.draggedTask = nil
            return
        }

        let index = dragState.targetIndex
        let taskId = task.id
        let changed: Bool

        if source == target {
            changed = reorderWithin(taskId: taskId, status: source, to: index)
        } else {
            boardState.moveTask(taskId, to: target)
            changed = true
        }

        if changed {
            insertedTaskId = taskId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                insertedTaskId = nil
            }
        }

        dragState.draggedTask = nil
        dragState.targetStatus = nil
    }

    private func reorderWithin(taskId: UUID, status: Status, to newIndex: Int) -> Bool {
        let taskIds = boardState.tasks.filter { $0.status == status }
        guard let fromIndex = taskIds.firstIndex(where: { $0.id == taskId }) else { return false }
        // newIndex is in the full list (including source); adjust for removal
        let adjusted = newIndex > fromIndex ? newIndex - 1 : newIndex
        guard adjusted != fromIndex else { return false }
        boardState.reorderTask(taskId, to: adjusted, in: status)
        return true
    }

    // MARK: - Layout

    @ViewBuilder
    private func horizontalContent(availableHeight: CGFloat) -> some View {
        let gap: CGFloat = 6
        let pad = Status.columnHPadding / 2

        GeometryReader { geometry in
            let layout = ColumnLayout.compute(
                totalWidth: geometry.size.width,
                gap: gap,
                pad: pad
            )

            Group {
                if layout.needsScroll || layout.centerContent {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: gap) {
                            if layout.centerContent { Spacer(minLength: 0) }

                            ForEach(Status.allCases) { status in
                                KanbanColumnView(
                                    status: status,
                                    tasks: boardState.tasks(for: status),
                                    boardState: boardState,
                                    sessionManager: sessionManager,
                                    tabManager: tabManager,
                                    ghosttyApp: ghosttyApp,
                                    dragState: dragState,
                                    insertedTaskId: insertedTaskId
                                )
                                .frame(width: layout.colWidth)
                                .frame(maxHeight: .infinity)
                            }

                            if layout.centerContent { Spacer(minLength: 0) }
                        }
                        .padding(.horizontal, pad)
                    }
                    .scrollDisabled(!layout.needsScroll)
                } else {
                    // No scroll, no centering -- stretch to fill
                    HStack(spacing: gap) {
                        ForEach(Status.allCases) { status in
                            KanbanColumnView(
                                status: status,
                                tasks: boardState.tasks(for: status),
                                boardState: boardState,
                                sessionManager: sessionManager,
                                tabManager: tabManager,
                                ghosttyApp: ghosttyApp,
                                dragState: dragState,
                                insertedTaskId: insertedTaskId
                            )
                            .frame(minWidth: Status.columnMinWidth)
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .padding(.horizontal, pad)
                }
            }
        }
    }

    @ViewBuilder
    private var verticalContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(Status.allCases) { status in
                    KanbanColumnView(
                        status: status,
                        tasks: boardState.tasks(for: status),
                        boardState: boardState,
                        sessionManager: sessionManager,
                        tabManager: tabManager,
                        ghosttyApp: ghosttyApp,
                        dragState: dragState,
                        insertedTaskId: insertedTaskId
                    )
                }
            }
            .padding(6)
        }
        .scrollDisabled(dragState.isDragging)
    }

    private func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return colors.accent
        case .p3: return colors.textMuted
        }
    }

    private var tagTextColor: Color {
        boardState.isDarkMode ? .white : Color(hex: "555555")
    }

    private func themeTagColor(_ tag: Tag) -> Color {
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
}

// MARK: - ColumnLayout

private struct ColumnLayout {
    let colWidth: CGFloat
    let needsScroll: Bool
    let centerContent: Bool

    static func compute(totalWidth: CGFloat, gap: CGFloat, pad: CGFloat) -> ColumnLayout {
        let availForCols = totalWidth - pad * 2 - gap * CGFloat(Status.allCases.count - 1)
        let naturalPerCol = availForCols / CGFloat(Status.allCases.count)

        if naturalPerCol <= Status.columnMinWidth {
            return ColumnLayout(colWidth: Status.columnMinWidth, needsScroll: true, centerContent: false)
        } else if naturalPerCol >= Status.columnMaxWidth {
            return ColumnLayout(colWidth: Status.columnMaxWidth, needsScroll: false, centerContent: true)
        } else {
            return ColumnLayout(colWidth: naturalPerCol, needsScroll: false, centerContent: false)
        }
    }
}

// MARK: - KanbanToolbar

struct KanbanToolbar: View {
    @ObservedObject var boardState: BoardState
    @State private var showNewTaskModal = false

    var body: some View {
        HStack {
            Text("Kanban").font(.headline)

            if let path = boardState.workspacePath {
                Text(path)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }

            Spacer()
            Button(action: { boardState.selectWorkspace() }) {
                Image(systemName: "folder")
            }
            .help("Select workspace folder")
            Button(action: { showNewTaskModal = true }) {
                Image(systemName: "plus")
            }
            Button(action: { boardState.toggleTheme() }) {
                Image(systemName: boardState.isDarkMode ? "sun.max" : "moon")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showNewTaskModal) {
            TaskEditModal(task: nil, boardState: boardState)
        }
    }
}
