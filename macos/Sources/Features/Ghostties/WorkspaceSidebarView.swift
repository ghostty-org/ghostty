import SwiftUI

/// The full sidebar: icon rail overlays a detail panel within a fixed-width container.
///
/// Layout strategy: ZStack with .leading alignment. The detail panel is positioned
/// after a 52pt spacer (to avoid the collapsed rail). The icon rail sits on top and
/// expands from 52pt to 220pt on hover, covering the detail panel with an opaque
/// background. This keeps the sidebar width fixed so the terminal never re-layouts.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore

    /// Per-window selection state — each window can focus a different project.
    @State private var selectedProjectID: UUID?

    var body: some View {
        ZStack(alignment: .leading) {
            // Detail layer: always present, offset past the collapsed rail
            HStack(spacing: 0) {
                Spacer()
                    .frame(width: WorkspaceLayout.collapsedRailWidth)
                Divider()
                detailPanel
            }

            // Icon rail: overlays the detail panel when expanded
            IconRailView(selectedProjectID: $selectedProjectID)
        }
        .onAppear {
            // Default to the first project on initial display.
            if selectedProjectID == nil {
                selectedProjectID = store.sortedProjects.first?.id
            }
        }
    }

    // MARK: - Detail Panel

    private var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return store.projects.first { $0.id == id }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let project = selectedProject {
            SessionDetailView(project: project)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Add a project")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Button("Add Project", action: presentFolderPicker)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func presentFolderPicker() {
        if let id = store.addProjectViaFolderPicker() {
            selectedProjectID = id
        }
    }
}
