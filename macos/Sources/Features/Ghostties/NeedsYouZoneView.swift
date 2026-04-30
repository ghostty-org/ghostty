import SwiftUI

/// Hero zone — "Needs you". Top of the sidebar, terracotta-accented.
///
/// Renders one hero-style `TaskRowView` per task. When empty, shows a single
/// reserved-height line ("✓ Nothing needs you right now.") so the zone below
/// does not shift. Spatial stability is the top goal here (brief §4).
///
/// Terracotta appears only in two places: the zone-header accent rule and
/// each row's leading status dot. Nowhere else in the sidebar.
struct NeedsYouZoneView: View {
    @ObservedObject var taskStore: TaskStore
    /// SEA-213: observe at zone level so individual TaskRowViews don't each
    /// hold an independent @ObservedObject on the singleton.
    @ObservedObject private var router = RowClickRouter.shared

    /// Reserved minimum height when the zone is empty. Keeps the divider
    /// below from walking up the sidebar when the list clears out.
    private let emptyHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if taskStore.needsYou.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(taskStore.needsYou) { task in
                        TaskRowView(
                            task: task,
                            style: .hero,
                            isHitTestBlocked: router.hitTestingBlockedTaskIds.contains(task.id),
                            rowError: router.taskRowErrors[task.id]
                        )
                        Divider()
                            .overlay(Color.primary.opacity(0.06))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    /// Uppercase "NEEDS YOU" caption flanked by two low-opacity rules,
    /// tinted terracotta per the mock — reads as `————— NEEDS YOU —————`.
    /// The far right carries a monospaced count so scanning is quick.
    private var header: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(WorkspaceLayout.waitingTerracotta.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: 1)

            Text("Needs you".uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(WorkspaceLayout.waitingTerracotta)
                .fixedSize()

            Rectangle()
                .fill(WorkspaceLayout.waitingTerracotta.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: 1)

            Text("\(taskStore.needsYou.count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .fixedSize()
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 14, height: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            Text("Nothing needs you right now.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .frame(height: emptyHeight)
    }
}
