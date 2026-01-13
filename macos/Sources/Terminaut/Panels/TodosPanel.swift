import SwiftUI

/// Shows the current todo list from Claude Code
struct TodosPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("TODOS")

            if let todos = state.todos, !todos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos) { todo in
                        todoRow(todo)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Text("No active tasks")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(panelBackground)
    }

    private func todoRow(_ todo: SessionState.TodoItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Status indicator
            statusIcon(for: todo.status)

            // Task content
            VStack(alignment: .leading, spacing: 2) {
                if todo.status == "in_progress", let activeForm = todo.activeForm {
                    Text(activeForm)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                } else {
                    Text(todo.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(todo.status == "completed" ? .gray : .white)
                        .strikethrough(todo.status == "completed")
                }
            }
            .lineLimit(2)

            Spacer()
        }
    }

    private func statusIcon(for status: String) -> some View {
        Group {
            switch status {
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case "in_progress":
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.cyan)
            default:
                Image(systemName: "circle")
                    .foregroundColor(.gray)
            }
        }
        .font(.system(size: 12))
    }
}
