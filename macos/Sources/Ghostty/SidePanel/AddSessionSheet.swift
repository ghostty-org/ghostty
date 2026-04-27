import SwiftUI

struct AddSessionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var cwd: String = ""
    @State private var command: String = ""
    @State private var splitId: String = ""
    @State private var isWorktree: Bool = false
    @State private var worktreeName: String = ""

    var onAdd: (Session) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Session")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Working Directory", text: $cwd)
                TextField("Command", text: $command)
                TextField("Split ID (optional)", text: $splitId)

                Toggle("Worktree", isOn: $isWorktree)

                if isWorktree {
                    TextField("Worktree Name", text: $worktreeName)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    let session = Session(
                        id: UUID().uuidString,
                        name: name,
                        cwd: cwd,
                        command: command,
                        splitId: splitId.isEmpty ? nil : splitId,
                        isWorktree: isWorktree,
                        worktreeName: isWorktree && !worktreeName.isEmpty ? worktreeName : nil
                    )
                    onAdd(session)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }
}