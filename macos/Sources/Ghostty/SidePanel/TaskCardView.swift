import SwiftUI

struct TaskCardView: View {
    let task: KanbanTask
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            HStack(alignment: .top, spacing: 0) {
                // Priority strip
                Rectangle()
                    .fill(priorityColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Title row
                    HStack {
                        Text(task.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(colors.textPrimary)
                            .lineLimit(2)

                        Spacer()

                        // Expand button
                        Button(action: { boardState.toggleTaskExpanded(task.id) }) {
                            Image(systemName: task.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14))
                                .foregroundColor(colors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                    // Description
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 12))
                            .foregroundColor(colors.textMuted)
                            .lineLimit(2)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }

                    // Meta row
                    HStack(spacing: 8) {
                        PriorityBadge(priority: task.priority)

                        if !task.sessions.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.stack")
                                    .font(.system(size: 12))
                                Text("\(task.sessions.count)")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(colors.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(colors.bgTertiary)
                            .cornerRadius(4)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    // Session panel (expanded)
                    if task.isExpanded {
                        SessionPanelView(taskId: task.id, sessions: task.sessions)
                    }
                }
            }
            .background(colors.taskBg)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? colors.taskHoverBorder : colors.borderColor, lineWidth: 1)
            )
            .shadow(color: isHovering ? .black.opacity(0.1) : .black.opacity(0.04), radius: isHovering ? 3 : 1, y: isHovering ? 3 : 1)
        }
        .padding(.leading, 0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .draggable(task.id.uuidString)
    }

    private var priorityColor: Color {
        switch task.priority {
        case .p0: return colors.danger
        case .p1: return colors.warning
        case .p2: return Color.yellow
        case .p3: return colors.textMuted
        }
    }
}
