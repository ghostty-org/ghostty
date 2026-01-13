import SwiftUI
import GhosttyKit

/// View that combines the terminal with the dashboard sidebar
struct SessionView<TerminalContent: View>: View {
    let project: Project
    let terminalContent: () -> TerminalContent
    @StateObject private var stateWatcher = SessionStateWatcher()
    @State private var showDashboard: Bool = true

    // Dashboard width (collapsible)
    private let dashboardWidth: CGFloat = 280

    var body: some View {
        HSplitView {
            // Terminal area (left side)
            terminalContent()
                .frame(minWidth: 400)

            // Dashboard sidebar (right side)
            if showDashboard {
                DashboardPanel(stateWatcher: stateWatcher)
                    .frame(width: dashboardWidth)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDashboard.toggle()
                    }
                } label: {
                    Image(systemName: showDashboard ? "sidebar.right" : "sidebar.left")
                }
                .help(showDashboard ? "Hide Dashboard" : "Show Dashboard")
            }
        }
    }
}

// MARK: - Tab Bar with Activity Indicators

/// Custom tab item showing project activity status
struct TerminautTabItem: View {
    let project: Project
    let isSelected: Bool
    let hasActivity: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Activity indicator
            if hasActivity {
                Text("*")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.green)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
            }

            Text(project.name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
        )
    }
}
