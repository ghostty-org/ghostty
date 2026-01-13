import SwiftUI

// MARK: - Shared Panel Components

/// Panel header with title
func panelHeader(_ title: String) -> some View {
    HStack {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.gray)
            .tracking(1.5)

        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
    .padding(.bottom, 4)
}

/// Standard panel background
var panelBackground: some View {
    RoundedRectangle(cornerRadius: 8)
        .fill(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
}

// MARK: - Panel Container

/// Container for all dashboard panels
struct DashboardPanel: View {
    @ObservedObject var stateWatcher: SessionStateWatcher

    var body: some View {
        VStack(spacing: 12) {
            StatusPanel(state: stateWatcher.state)
            VitalsPanel(state: stateWatcher.state)
            GitPanel(state: stateWatcher.state)
            TodosPanel(state: stateWatcher.state)
            Spacer()
        }
        .padding(12)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Preview

#Preview {
    let watcher = SessionStateWatcher()
    // Set some sample data for preview
    watcher.state = SessionState(
        model: "Claude Opus 4.5",
        version: "v2.0.76",
        cwd: "/Users/pete/Projects/terminaut",
        contextPercent: 45.0,
        quotaPercent: 12.0,
        gitBranch: "main",
        gitUncommitted: 3,
        gitAhead: 1,
        gitBehind: 0,
        currentTool: nil,
        todos: [
            .init(content: "Build Ghostty with Zig", status: "completed", activeForm: nil),
            .init(content: "Add Launcher view", status: "in_progress", activeForm: "Adding Launcher view"),
            .init(content: "Add Dashboard sidebar", status: "pending", activeForm: nil),
        ],
        timestamp: Date()
    )

    return DashboardPanel(stateWatcher: watcher)
        .frame(width: 280, height: 600)
        .background(Color.black)
}
