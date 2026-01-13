import SwiftUI
import AppKit

/// Game-style full-screen project launcher
struct LauncherView: View {
    @ObservedObject var projectStore: ProjectStore
    @State private var searchText: String = ""
    @FocusState private var isFocused: Bool

    /// Active session project IDs (for highlighting)
    var activeProjectIds: Set<UUID> = []

    var onSelect: (Project) -> Void

    /// Projects sorted with active sessions at top
    private var sortedProjects: [Project] {
        let projects = projectStore.projects
        let active = projects.filter { activeProjectIds.contains($0.id) }
        let inactive = projects.filter { !activeProjectIds.contains($0.id) }
        return active + inactive
    }

    private var filteredProjects: [Project] {
        let projects = sortedProjects
        if searchText.isEmpty {
            return projects
        }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // Fixed 6 columns for predictable keyboard navigation
    private let columnCount = 6
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 24), count: columnCount)
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search bar at top
                searchBar
                    .padding(.horizontal, 40)
                    .padding(.top, 24)

                // Project grid
                ScrollView {
                    if filteredProjects.isEmpty {
                        emptyStateView
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(Array(filteredProjects.enumerated()), id: \.element.id) { index, project in
                                ProjectTile(
                                    project: project,
                                    isSelected: index == projectStore.selectedIndex && searchText.isEmpty,
                                    isActive: activeProjectIds.contains(project.id)
                                )
                                .onTapGesture {
                                    projectStore.selectedIndex = index
                                    onSelect(project)
                                }
                            }

                            // Add new project tile
                            AddProjectTile()
                                .onTapGesture {
                                    // TODO: Show folder picker
                                }
                        }
                        .padding(40)
                    }
                }

                // Footer with controls
                footerView
            }
        }
        .focused($isFocused)
        .onAppear { isFocused = true }
        .background(KeyboardHandlerView { event in
            handleKeyEvent(event)
        })
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)

            TextField("Search projects...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .font(.system(size: 16, design: .monospaced))
        }
        .padding(12)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("No projects found")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)

            Text("Add a project or scan your ~/Projects folder")
                .font(.system(size: 14))
                .foregroundColor(.gray.opacity(0.7))

            Button("Scan for Projects") {
                projectStore.scanForProjects()
            }
            .buttonStyle(.bordered)
        }
        .padding(60)
    }

    private var footerView: some View {
        HStack(spacing: 40) {
            controlHint(key: "Arrow Keys", action: "Navigate")
            controlHint(key: "Enter", action: "Launch")
            controlHint(key: "R", action: "Rescan")
            controlHint(key: "Esc", action: "Quit")
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
    }

    private func controlHint(key: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.2))
                .cornerRadius(4)

            Text(action)
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: // Up arrow
            projectStore.moveVertical(by: -1, columnCount: columnCount)
            return true
        case 125: // Down arrow
            projectStore.moveVertical(by: 1, columnCount: columnCount)
            return true
        case 123: // Left arrow
            projectStore.moveHorizontal(by: -1, columnCount: columnCount)
            return true
        case 124: // Right arrow
            projectStore.moveHorizontal(by: 1, columnCount: columnCount)
            return true
        case 36: // Return/Enter
            if let project = projectStore.selectedProject {
                onSelect(project)
            }
            return true
        case 15: // R key
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                projectStore.scanForProjects()
                return true
            }
            return false
        default:
            return false
        }
    }

    private var columnsCount: Int {
        columnCount
    }
}

/// NSViewRepresentable that captures keyboard events
struct KeyboardHandlerView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyboardCapturingView {
        let view = KeyboardCapturingView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyboardCapturingView, context: Context) {
        nsView.onKeyDown = onKeyDown
        // Ensure we're first responder when view updates
        DispatchQueue.main.async {
            if nsView.window?.firstResponder != nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    class KeyboardCapturingView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Become first responder when added to window
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if let handler = onKeyDown, handler(event) {
                return
            }
            super.keyDown(with: event)
        }
    }
}

/// Individual project tile in the grid
struct ProjectTile: View {
    let project: Project
    let isSelected: Bool
    var isActive: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Icon area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconBackgroundColor)
                    .frame(width: 80, height: 80)

                if let icon = project.icon {
                    Text(icon)
                        .font(.system(size: 36))
                } else {
                    // Default folder icon
                    Image(systemName: isActive ? "terminal.fill" : "folder.fill")
                        .font(.system(size: 32))
                        .foregroundColor(iconColor)
                }

                // Active badge
                if isActive {
                    VStack {
                        HStack {
                            Spacer()
                            Circle()
                                .fill(Color.green)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .stroke(Color.black, lineWidth: 2)
                                )
                        }
                        Spacer()
                    }
                    .frame(width: 80, height: 80)
                    .padding(4)
                }
            }

            // Project name
            Text(project.name)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)

            // Active label
            if isActive {
                Text("ACTIVE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
        .frame(width: 180, height: 160)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: isActive ? 2 : (isSelected ? 2 : 0))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(tileBackgroundColor)
                )
        )
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private var iconBackgroundColor: Color {
        if isSelected { return Color.cyan.opacity(0.3) }
        if isActive { return Color.green.opacity(0.2) }
        return Color.white.opacity(0.1)
    }

    private var iconColor: Color {
        if isSelected { return .cyan }
        if isActive { return .green }
        return .gray
    }

    private var borderColor: Color {
        if isSelected { return .cyan }
        if isActive { return .green.opacity(0.5) }
        return .clear
    }

    private var tileBackgroundColor: Color {
        if isActive { return Color.green.opacity(0.05) }
        return Color.white.opacity(0.05)
    }
}

/// Add new project tile
struct AddProjectTile: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .frame(width: 80, height: 80)

                Image(systemName: "plus")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
            }

            Text("Add Project")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }
        .frame(width: 180, height: 160)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.02))
        )
    }
}

#Preview {
    LauncherView(projectStore: ProjectStore.shared) { project in
        print("Selected: \(project.name)")
    }
    .frame(width: 1200, height: 800)
}
