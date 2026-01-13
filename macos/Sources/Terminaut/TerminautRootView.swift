import SwiftUI
import GhosttyKit

/// Root view for Terminaut - switches between launcher and session
/// Lives in a single fullscreen window, no window management needed
struct TerminautRootView: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    @ObservedObject var coordinator: TerminautCoordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if coordinator.showLauncher {
                LauncherView(projectStore: ProjectStore.shared) { project in
                    coordinator.launchProject(project)
                }
                .transition(.opacity)
            } else if let project = coordinator.activeProject {
                TerminautSessionView(
                    project: project,
                    onReturnToLauncher: {
                        coordinator.returnToLauncher()
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.showLauncher)
    }
}

/// Session view with embedded terminal and control panel
struct TerminautSessionView: View {
    let project: Project
    let onReturnToLauncher: () -> Void

    @EnvironmentObject private var ghostty: Ghostty.App
    @StateObject private var stateWatcher = SessionStateWatcher()

    // Control panel width - roughly 1/3 of 16" MacBook Pro screen
    private let controlPanelWidth: CGFloat = 500

    var body: some View {
        HStack(spacing: 0) {
            // Left 2/3: Terminal
            terminalPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right 1/3: Control Panel
            ControlPanelView(
                project: project,
                stateWatcher: stateWatcher,
                onReturnToLauncher: onReturnToLauncher
            )
            .frame(width: controlPanelWidth)
        }
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let app = ghostty.app {
            TerminalSurface(
                app: app,
                workingDirectory: project.path,
                command: "/Users/pete/.local/bin/claude"
            )
        } else {
            // Fallback if ghostty not ready
            Color.black
                .overlay(
                    Text("Initializing terminal...")
                        .foregroundColor(.gray)
                )
        }
    }
}

/// Wraps Ghostty.SurfaceView with project-specific configuration
struct TerminalSurface: View {
    let app: ghostty_app_t
    let workingDirectory: String
    let command: String

    @StateObject private var surfaceView: Ghostty.SurfaceView

    init(app: ghostty_app_t, workingDirectory: String, command: String) {
        self.app = app
        self.workingDirectory = workingDirectory
        self.command = command

        // Create surface configuration
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = workingDirectory
        config.command = command

        // Initialize surface view with config
        _surfaceView = StateObject(wrappedValue: Ghostty.SurfaceView(app, baseConfig: config))
    }

    var body: some View {
        Ghostty.SurfaceWrapper(surfaceView: surfaceView)
    }
}

/// Control panel with all interactive panels
struct ControlPanelView: View {
    let project: Project
    let stateWatcher: SessionStateWatcher
    let onReturnToLauncher: () -> Void

    @State private var selectedPanel: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Project header
            projectHeader

            Divider()
                .background(Color.white.opacity(0.2))

            // Scrollable panels
            ScrollView {
                VStack(spacing: 12) {
                    // Context panel
                    ContextPanel(state: stateWatcher.state)

                    // Tools panel
                    ToolsPanel(state: stateWatcher.state)

                    // Todos panel
                    TodosPanel(state: stateWatcher.state)

                    // Git panel
                    GitPanel(state: stateWatcher.state)

                    // Agents/Background panel (placeholder)
                    AgentsPanel()
                }
                .padding(12)
            }

            Divider()
                .background(Color.white.opacity(0.2))

            // Footer with controls
            controlsFooter
        }
        .background(Color.black.opacity(0.95))
    }

    private var projectHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text(project.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Back to launcher button
            Button {
                onReturnToLauncher()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .help("Return to Launcher (Cmd+L)")
        }
        .padding(12)
    }

    private var controlsFooter: some View {
        HStack(spacing: 20) {
            controlHint(key: "D-pad", action: "Navigate")
            controlHint(key: "A", action: "Select")
            controlHint(key: "B", action: "Back")
            controlHint(key: "Start", action: "Launcher")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(.gray)
        .padding(12)
    }

    private func controlHint(key: String, action: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1))
                .cornerRadius(3)
            Text(action)
        }
    }
}

// MARK: - Panel Components

struct ContextPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("CONTEXT")

            HStack {
                // Context usage bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))

                        RoundedRectangle(cornerRadius: 4)
                            .fill(contextColor)
                            .frame(width: geo.size.width * (state.contextPercent ?? 0) / 100)
                    }
                }
                .frame(height: 20)

                Text("\(Int(state.contextPercent ?? 0))%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(contextColor)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(panelBackground)
    }

    private var contextColor: Color {
        let pct = state.contextPercent ?? 0
        if pct > 80 { return .red }
        if pct > 60 { return .orange }
        return .green
    }
}

struct ToolsPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("TOOLS")

            if let tool = state.currentTool {
                HStack {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(.cyan)
                    Text(tool)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                Text("No active tool")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(panelBackground)
    }
}

struct AgentsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("AGENTS / BACKGROUND")

            Text("No background tasks")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(panelBackground)
    }
}

// MARK: - Preview

#Preview {
    let coordinator = TerminautCoordinator.shared
    coordinator.showLauncher = false
    coordinator.activeProject = Project(name: "terminaut-ghostty", path: "/Users/pete/Projects/terminaut-ghostty")

    return TerminautRootView(coordinator: coordinator)
        .frame(width: 1600, height: 1000)
        .environmentObject(Ghostty.App())
}
