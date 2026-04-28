import SwiftUI
import UniformTypeIdentifiers

struct ColumnView: View {
    let status: Status
    let tasks: [KanbanTask]
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(status.displayName.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(colors.textSecondary)
                    .tracking(0.3)

                Spacer()

                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(colors.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(colors.bgTertiary)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [colors.headerGradientStart, colors.headerGradientEnd],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Rectangle()
                    .fill(colors.borderColor)
                    .frame(height: 1),
                alignment: .bottom
            )

            // Tasks - drop zone on the scroll view area
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        TaskCardView(task: task, boardState: boardState)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .dropDestination(for: String.self) { items, location in
                guard let taskIdString = items.first,
                      let taskId = UUID(uuidString: taskIdString) else {
                    return false
                }
                // Determine drop position based on location
                let targetIndex = calculateDropIndex(location: location)
                handleDrop(taskId: taskId, at: targetIndex)
                return true
            }
        }
        .background(colors.columnBg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(colors.borderColor, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch status {
        case .todo: return colors.accent
        case .inProgress: return colors.warning
        case .review: return colors.worktree
        case .done: return colors.success
        }
    }

    private func calculateDropIndex(location: CGPoint) -> Int {
        let cardHeight: CGFloat = 80
        let spacing: CGFloat = 10
        let headerHeight: CGFloat = 50
        let adjustedY = max(0, location.y - headerHeight)
        let index = Int((adjustedY + spacing / 2) / (cardHeight + spacing))
        return max(0, min(index, tasks.count))
    }

    private func handleDrop(taskId: UUID, at index: Int) {
        if let task = boardState.tasks.first(where: { $0.id == taskId }) {
            if task.status == status {
                boardState.reorderTask(taskId, to: index, in: status)
            } else {
                boardState.moveTask(taskId, to: status)
            }
        }
    }
}
