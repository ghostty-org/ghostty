import SwiftUI

struct AddSessionSheet: View {
    let cardId: String
    @ObservedObject var viewModel: SidePanelViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sessionName = ""
    @State private var cwd = ""
    @State private var command = ""
    @State private var isWorktree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Session")
                .font(.headline)

            Form {
                TextField("Session Name", text: $sessionName)
                TextField("Working Directory", text: $cwd)
                TextField("Command", text: $command)
            }

            Toggle("Create Worktree", isOn: $isWorktree)
                .toggleStyle(.switch)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    addSession()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sessionName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func addSession() {
        let session = Session(
            name: sessionName,
            cwd: cwd.isEmpty ? "~" : cwd,
            command: command.isEmpty ? "" : command,
            isWorktree: isWorktree,
            worktreeName: isWorktree ? sessionName.lowercased().replacingOccurrences(of: " ", with: "-") : nil
        )
        viewModel.addSession(to: cardId, session: session)
    }
}
