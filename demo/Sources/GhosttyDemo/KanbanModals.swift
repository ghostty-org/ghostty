import SwiftUI
import GhosttyKit

// MARK: - TaskEditModal

struct TaskEditModal: View {
    @State var title: String
    @State var description: String
    @State var priority: Priority
    @State var selectedTags: [Tag]
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
        _selectedTags = State(initialValue: task?.tags ?? [])
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(task == nil ? "New Task" : "Edit Task")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            AppKitTextView(text: $description)
                .frame(height: 80)
                .background(colors.inputBg)
                .foregroundColor(colors.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colors.borderColor, lineWidth: 1)
                )

            // Priority row
            HStack {
                Text("Priority").foregroundColor(colors.textSecondary)
                Spacer()
                Picker("", selection: $priority) {
                    ForEach(Priority.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160, alignment: .trailing)
            }

            // Tags row
            HStack {
                Text("Tags").foregroundColor(colors.textSecondary)
                Spacer()
                Menu {
                    ForEach(Tag.allCases) { tag in
                        Button(action: {
                            if selectedTags.contains(tag) {
                                selectedTags.removeAll { $0 == tag }
                            } else {
                                selectedTags.append(tag)
                            }
                        }) {
                            HStack {
                                Text(tag.displayName)
                                if selectedTags.contains(tag) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedTags.isEmpty ? "Select tags" : selectedTags.map(\.displayName).joined(separator: ", "))
                            .foregroundColor(selectedTags.isEmpty ? colors.textMuted : colors.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(colors.textMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colors.inputBg)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(colors.borderColor, lineWidth: 1)
                    )
                }
                .frame(width: 160, alignment: .trailing)
            }

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
                        sessions: task?.sessions ?? [],
                        tags: selectedTags
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
    @Environment(\.themeColors) var colors

    var body: some View {
        VStack(spacing: 12) {
            Text("New Session")
                .font(.headline)
                .foregroundColor(colors.textPrimary)

            Toggle("Git Worktree", isOn: $isWorkTree)
                .toggleStyle(.switch)
                .foregroundColor(colors.textPrimary)

            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundColor(colors.textPrimary)
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
        .background(colors.modalBg)
    }
}

// MARK: - NSTextView Wrapper

struct AppKitTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.lineFragmentPadding = 4

        // Increase line spacing for readability
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitTextView

        init(_ parent: AppKitTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
