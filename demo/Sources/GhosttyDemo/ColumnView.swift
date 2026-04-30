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

    @Environment(\.themeColors) var colors

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCardView(
                            task: task,
                            boardState: boardState,
                            sessionManager: sessionManager,
                            tabManager: tabManager,
                            ghosttyApp: ghosttyApp
                        )
                    }
                }
                .padding(6)
            }
        }
        .frame(minWidth: Status.columnMinWidth, maxHeight: .infinity, alignment: .top)
        .background(colors.columnBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(colors.borderColor, lineWidth: 1)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first,
                  let id = UUID(uuidString: idString) else { return false }
            boardState.moveTask(id, to: status)
            return true
        }
    }

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
