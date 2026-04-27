import SwiftUI
import GhosttyKit

struct KanbanToolbar: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @State private var showingNewTaskSheet = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { showingNewTaskSheet = true }) {
                Label("New Task", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .cornerRadius(6)

            Spacer()

            ThemeToggle()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showingNewTaskSheet) {
            NewTaskSheet(viewModel: viewModel)
        }
    }
}

struct ThemeToggle: View {
    @AppStorage("kanban-theme") private var isDark = false

    var body: some View {
        Button(action: { isDark.toggle() }) {
            Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
    }
}

struct NewTaskSheet: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var priority: Priority = .p2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
                TextField("Description (optional)", text: $description)

                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    viewModel.addCard(title: title, description: description, priority: priority)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
