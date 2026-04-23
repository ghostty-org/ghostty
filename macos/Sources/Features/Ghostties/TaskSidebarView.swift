import SwiftUI

/// Top-level task-first sidebar (Concept F). Composes the three zones —
/// Needs you · Active · Archive — plus a muted footer.
///
/// Designed to replace `WorkspaceSidebarView` behind a feature toggle. In
/// Wave 2 this view is standalone; Agent E wires it into the workspace shell
/// in a follow-up commit.
///
/// Width is 280pt (slightly wider than the 220pt legacy sidebar) — Concept F
/// is denser vertically but needs more horizontal room for the hero row's
/// two-line typography.
struct TaskSidebarView: View {
    @ObservedObject var taskStore: TaskStore

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            NeedsYouZoneView(taskStore: taskStore)

            zoneDivider

            ActiveZoneView(taskStore: taskStore)

            zoneDivider

            ArchiveZoneView(taskStore: taskStore)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(backgroundColor)
    }

    // MARK: - Zone divider

    /// 1pt zone separator. Slightly stronger than the 0.5pt intra-zone row
    /// dividers so the three zones read as distinct regions of the sidebar.
    private var zoneDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.486, green: 0.702, blue: 0.259))
                .frame(width: 5, height: 5)

            Text("3 sources")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("·").foregroundStyle(Color.primary.opacity(0.28))

            Text("linear")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("·").foregroundStyle(Color.primary.opacity(0.28))

            Text("gh")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("·").foregroundStyle(Color.primary.opacity(0.28))

            Text("sentry")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Spacer(minLength: 0)

            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .frame(height: 30)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    // MARK: - Background

    private var backgroundColor: Color {
        Color(nsColor: colorScheme == .dark
              ? WorkspaceLayout.chromeBackgroundDark
              : WorkspaceLayout.chromeBackgroundLight)
    }
}

// MARK: - Preview

#Preview("Task Sidebar — Light + Dark") {
    HStack(spacing: 24) {
        TaskSidebarView(taskStore: TaskStore())
            .preferredColorScheme(.light)
        TaskSidebarView(taskStore: TaskStore())
            .preferredColorScheme(.dark)
    }
    .padding(24)
    .frame(height: 780)
}
