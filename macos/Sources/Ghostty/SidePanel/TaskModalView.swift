import SwiftUI

struct TaskModalView: View {
    @Binding var isPresented: Bool
    var task: KanbanTask?
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    @State private var title = ""
    @State private var description = ""
    @State private var priority: Priority = .p2
    @State private var status: Status = .todo
    @State private var sessions: [Session] = []
    @State private var newSessionTitle = ""

    var isEditing: Bool { task != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Task" : "New Task")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Spacer()
                Button(action: { isPresented = false }) {
                    Text("×")
                        .font(.system(size: 18))
                        .foregroundColor(colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                        TextField("Enter task title", text: $title)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(colors.inputBg)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(colors.inputBorder, lineWidth: 1)
                            )
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                        TextEditor(text: $description)
                            .font(.system(size: 13))
                            .frame(minHeight: 60)
                            .padding(4)
                            .background(colors.inputBg)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(colors.inputBorder, lineWidth: 1)
                            )
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(colors.textSecondary)
                        Picker("Priority", selection: $priority) {
                            ForEach(Priority.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(8)
                        .background(colors.inputBg)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(colors.inputBorder, lineWidth: 1)
                        )
                    }

                    // Sessions (only in edit mode)
                    if isEditing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sessions")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(colors.textSecondary)

                            // Sessions list
                            VStack(spacing: 0) {
                                ForEach(sessions) { session in
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(sessionStatusColor(session.status))
                                            .frame(width: 8, height: 8)
                                        Text(session.title)
                                            .font(.system(size: 13))
                                            .foregroundColor(colors.textPrimary)
                                        Spacer()
                                        Button(action: { removeSession(session) }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 12))
                                                .foregroundColor(colors.textMuted)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(10)
                                    .background(colors.bgSecondary)
                                    .overlay(
                                        Rectangle()
                                            .fill(colors.borderSubtle)
                                            .frame(height: 1),
                                        alignment: .bottom
                                    )
                                }
                            }
                            .background(colors.inputBg)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(colors.borderColor, lineWidth: 1)
                            )

                            // Add session row
                            HStack(spacing: 8) {
                                TextField("Enter session title", text: $newSessionTitle)
                                    .textFieldStyle(.plain)
                                    .padding(8)
                                    .background(colors.inputBg)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(colors.inputBorder, lineWidth: 1)
                                    )

                                Button(action: addSession) {
                                    Text("Add")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(colors.accent)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(action: { isPresented = false }) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colors.btnGradientEnd)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(colors.borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: saveTask) {
                    Text("Save")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(colors.accent)
                        .cornerRadius(6)
                        .shadow(color: colors.accent.opacity(0.3), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(colors.modalFooterBg)
        }
        .frame(width: 520)
        .background(colors.modalBg)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 25, y: 10)
        .onAppear(perform: loadTask)
    }

    private func loadTask() {
        if let task = task {
            title = task.title
            description = task.description
            priority = task.priority
            status = task.status
            sessions = task.sessions
        }
    }

    private func saveTask() {
        guard !title.isEmpty else { return }

        let newTask = KanbanTask(
            id: task?.id ?? UUID(),
            title: title,
            description: description,
            priority: priority,
            status: status,
            sessions: sessions,
            isExpanded: task?.isExpanded ?? false
        )

        if isEditing {
            boardState.updateTask(newTask)
        } else {
            boardState.addTask(newTask)
        }
        isPresented = false
    }

    private func addSession() {
        let session = SessionManager.shared.createSession(
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            isWorktree: false,
            worktreeName: nil
        )
        sessions.append(session)
        newSessionTitle = ""
    }

    private func removeSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
    }

    private func sessionStatusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .running: return colors.success
        case .idle: return colors.textMuted
        case .needInput: return colors.warning
        }
    }
}
