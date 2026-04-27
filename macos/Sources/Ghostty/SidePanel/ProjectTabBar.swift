import SwiftUI
import GhosttyKit

struct ProjectTabBar: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @State private var showingAddProject = false
    @State private var newProjectName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(viewModel.projects.enumerated()), id: \.element.id) { index, project in
                    ProjectTab(
                        name: project.name,
                        isSelected: index == viewModel.currentProjectIndex,
                        onSelect: { viewModel.selectProject(at: index) },
                        onDelete: viewModel.projects.count > 1 ? { viewModel.deleteProject(at: index) } : nil
                    )
                }

                Button(action: { showingAddProject = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Add Project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("New Project", isPresented: $showingAddProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {
                newProjectName = ""
            }
            Button("Create") {
                if !newProjectName.isEmpty {
                    viewModel.addProject(name: newProjectName)
                    newProjectName = ""
                }
            }
        }
    }
}

struct ProjectTab: View {
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}