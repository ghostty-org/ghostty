import SwiftUI
import GhosttyRuntime

// MARK: - KanbanColumnView

struct KanbanColumnView: View {
    let status: Status
    let tasks: [KanbanTask]
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t
    @ObservedObject var dragState: DragDropState
    var insertedTaskId: UUID?

    @Environment(\.themeColors) var colors
    @State private var columnFrame: CGRect = .zero

    private var isTargeted: Bool {
        dragState.isDragging && dragState.targetStatus == status
    }

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            ScrollView(.vertical, showsIndicators: insertedTaskId == nil) {
                VStack(spacing: 8) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        // Placeholder above this card
                        if isTargeted && dragState.targetIndex == index {
                            placeholderView
                        }

                        TaskCardView(
                            task: task,
                            boardState: boardState,
                            sessionManager: sessionManager,
                            tabManager: tabManager,
                            ghosttyApp: ghosttyApp,
                            dragState: dragState,
                            insertedTaskId: insertedTaskId
                        )
                    }

                    // Placeholder at end
                    if isTargeted && dragState.targetIndex >= tasks.count {
                        placeholderView
                    }
                }
                .padding(6)
            }
            .scrollDisabled(dragState.isDragging || insertedTaskId != nil)
        }
        .frame(minWidth: Status.columnMinWidth, maxHeight: .infinity, alignment: .top)
        .background(colors.columnBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: isTargeted ? colors.accent.opacity(0.15) : Color.clear, radius: 8, x: 0, y: 0)
        .scaleEffect(isTargeted ? 1.008 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTargeted)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ColumnFramesKey.self,
                    value: [status: geo.frame(in: .named("board"))]
                )
                .onAppear {
                    columnFrame = geo.frame(in: .named("board"))
                }
                .onChange(of: geo.frame(in: .named("board"))) { frame in
                    columnFrame = frame
                }
            }
        )
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(colors.accent.opacity(isPlaceholderPulsing ? 0.6 : 0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(colors.accent.opacity(isPlaceholderPulsing ? 0.12 : 0.06))
            )
            .frame(height: 72)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPlaceholderPulsing
            )
            .onAppear { isPlaceholderPulsing = true }
            .onDisappear { isPlaceholderPulsing = false }
    }

    @State private var isPlaceholderPulsing = false

    // MARK: - Column Header

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(columnColor)
                .frame(width: 8, height: 8)
            Text(status.displayName.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(colors.textSecondary)
            Text("\(tasks.count)")
                .font(.caption2)
                .foregroundColor(colors.textMuted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Dynamic Border

    private var borderColor: Color {
        isTargeted ? colors.accent.opacity(0.5) : colors.borderColor
    }

    private var borderWidth: CGFloat {
        isTargeted ? 2 : 1
    }

    // MARK: - Column Color

    private var columnColor: Color {
        switch status {
        case .todo:     return colors.accent
        case .inProgress: return colors.warning
        case .review:   return colors.worktree
        case .done:     return colors.success
        }
    }
}
