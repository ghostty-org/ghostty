import SwiftUI
import GhosttyKit

// MARK: - TaskEditModal

struct TaskEditModal: View {
    @State var title: String
    @State var description: String
    @State var priority: Priority
    let task: KanbanTask?  // nil = new task, non-nil = edit
    @ObservedObject var boardState: BoardState
    @Environment(\.dismiss) var dismiss
    @Environment(\.themeColors) var colors

    // Initialize from task or empty for new
    init(task: KanbanTask?, boardState: BoardState) {
        self.task = task
        self.boardState = boardState
        _title = State(initialValue: task?.title ?? "")
        _description = State(initialValue: task?.description ?? "")
        _priority = State(initialValue: task?.priority ?? .p2)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(task == nil ? "New Task" : "Edit Task")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $description)
                .frame(height: 80)
                .border(Color.gray.opacity(0.3))
                .cornerRadius(4)

            Picker("Priority", selection: $priority) {
                ForEach(Priority.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if task != nil {
                    Button("Delete") {
                        boardState.deleteTask(task!.id)
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let t = KanbanTask(
                        id: task?.id ?? UUID(),
                        title: title,
                        description: description,
                        priority: priority,
                        status: task?.status ?? .todo,
                        sessions: task?.sessions ?? []
                    )
                    if task != nil {
                        boardState.updateTask(t)
                    } else {
                        boardState.addTask(t)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(colors.modalBg)
    }
}

// MARK: - SessionCreateModal

struct SessionCreateModal: View {
    let taskId: UUID
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t

    @State private var isWorkTree = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("New Session").font(.headline)

            Toggle("Git Worktree", isOn: $isWorkTree)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Create") {
                    _ = sessionManager.createSession(
                        for: taskId,
                        worktree: isWorkTree,
                        branch: "main",
                        cwd: boardState.workspacePath,
                        boardState: boardState
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}
