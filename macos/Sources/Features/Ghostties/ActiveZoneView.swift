import SwiftUI

/// Monitor zone — "Active". Middle of the sidebar, expands to fill
/// available space.
///
/// Renders a **mixed stream** of running `TaskItem`s and `SessionDraft`s
/// (unpromoted terminal sessions), sorted so the most recent activity floats
/// to the top. Placeholder slots count against both so the zone never resizes
/// as tasks + drafts come and go (brief §4: spatial stability).
///
/// The "machine ok" hint in the header is hardcoded for v0; a later revision
/// will read thermal state / pressure and drive the color.
struct ActiveZoneView: View {
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var sessionDraftStore: SessionDraftStore
    /// SEA-213: observe at zone level so individual TaskRowViews don't each
    /// hold an independent @ObservedObject on the singleton.
    @ObservedObject private var router = RowClickRouter.shared

    /// SEA-216: Cache the merged+sorted rows in state so `body` never rebuilds
    /// the array. Populated on appear and updated via `.onChange` whenever either
    /// source store changes. This avoids re-running the map+concat+sort on every
    /// body call (which previously fired on every user interaction across the sidebar).
    @State private var cachedMergedRows: [ActiveRow] = []

    var body: some View {
        let rows = cachedMergedRows
        return VStack(alignment: .leading, spacing: 0) {
            header(rowCount: rows.count)

            VStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    rowView(for: row)
                    Divider()
                        .overlay(Color.primary.opacity(0.06))
                }

                let placeholderCount = max(0, taskStore.machineCap - rows.count)
                if placeholderCount > 0 {
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        SlotPlaceholderView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { cachedMergedRows = buildMergedRows() }
        .onChange(of: taskStore.active) { _ in cachedMergedRows = buildMergedRows() }
        // SessionDraft is a reference type so its array isn't Equatable.
        // Receive the store's own change signal instead.
        .onReceive(sessionDraftStore.objectWillChange) { cachedMergedRows = buildMergedRows() }
    }

    // MARK: - Merged stream

    /// Typed enum so `ForEach` can render tasks and drafts in one list while
    /// keeping `id` and sort keys unambiguous.
    private enum ActiveRow {
        case task(TaskItem)
        case draft(SessionDraft)

        var id: String {
            switch self {
            case .task(let t):   return "task:\(t.id)"
            case .draft(let d):  return "draft:\(d.id)"
            }
        }

        var sortDate: Date {
            switch self {
            case .task(let t):   return t.created
            case .draft(let d):  return d.startedAt
            }
        }
    }

    /// SEA-216: Build the merged+sorted rows. Called once on appear and on every
    /// change to `taskStore.active` or `sessionDraftStore.drafts`. The result is
    /// cached in `cachedMergedRows` so `body` never re-runs this computation.
    ///
    /// Union of running tasks and drafts, sorted newest-first. Promoted drafts
    /// (`promotedToTaskId != nil`) are filtered out — they're represented by
    /// the new task row instead.
    private func buildMergedRows() -> [ActiveRow] {
        let taskRows = taskStore.active.map(ActiveRow.task)
        let draftRows = sessionDraftStore.drafts
            .filter { $0.promotedToTaskId == nil }
            .map(ActiveRow.draft)
        return (taskRows + draftRows).sorted { $0.sortDate > $1.sortDate }
    }

    @ViewBuilder
    private func rowView(for row: ActiveRow) -> some View {
        switch row {
        case .task(let task):
            TaskRowView(
                task: task,
                style: .compact,
                isHitTestBlocked: router.hitTestingBlockedTaskIds.contains(task.id),
                rowError: router.taskRowErrors[task.id]
            )
        case .draft(let draft):
            SessionDraftRowView(draft: draft)
        }
    }

    // MARK: - Header

    private func header(rowCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("Active".uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("· \(rowCount) of ~\(taskStore.machineCap)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Spacer(minLength: 0)

            Text("machine ok")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 6)
    }
}
