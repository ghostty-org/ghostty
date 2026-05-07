import SwiftUI

/// Backlog zone — planned tasks not yet started.
///
/// Renders tasks whose status is `.backlog`: work the user (or an agent) has
/// staged for a future session. This zone is always visible as a thin header
/// when empty; the body collapses so the sidebar does not thrash as tasks
/// move into or out of backlog (spatial stability, brief §4).
///
/// Promoted from a sub-lane of ArchiveZoneView in the six-zone parity layout
/// (feat/six-zone-parity). Now a first-class zone between Inbox and Active.
struct BacklogZoneView: View {
    @ObservedObject var taskStore: TaskStore
    /// SEA-213: observe at zone level so individual TaskRowViews don't each
    /// hold an independent @ObservedObject on the singleton.
    @ObservedObject private var router = RowClickRouter.shared

    private var rows: [TaskItem] {
        taskStore.backlog
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { task in
                        TaskRowView(
                            task: task,
                            style: .compact,
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("Backlog".uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("· \(rows.count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 6)
    }
}
