import SwiftUI

/// Archive / queue zone — bottom of the sidebar. Four lane headers stacked
/// vertically (Inbox · Backlog · Review · Done), each click-to-expand.
///
/// Rollup dots surface items requiring attention while the lane is collapsed.
/// In v0 only Inbox carries a (terracotta) dot — and only when it has items.
/// Other lanes surface a neutral dot when a future rule populates them.
struct ArchiveZoneView: View {
    @ObservedObject var taskStore: TaskStore

    /// Per-lane expand/collapse state. Collapsed by default.
    @State private var expanded: Set<TaskStatus> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            lane(.inbox,   label: "Inbox",   tasks: taskStore.inbox,   rollup: .terracotta)
            lane(.backlog, label: "Backlog", tasks: taskStore.backlog, rollup: .none)
            lane(.review,  label: "Review",  tasks: taskStore.review,  rollup: .none)
            lane(.done,    label: "Done",    tasks: taskStore.done,    rollup: .none)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Zone header

    private var header: some View {
        HStack {
            Text("Archive".uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 6)
    }

    // MARK: - Lane

    /// One collapsible lane. Header is a 32pt row; when expanded the matching
    /// compact `TaskRowView`s render below.
    private func lane(
        _ status: TaskStatus,
        label: String,
        tasks: [TaskItem],
        rollup: RollupDot
    ) -> some View {
        let isExpanded = expanded.contains(status)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { toggle(status) }) {
                HStack(spacing: 8) {
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.28))
                        .frame(width: 10)

                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)

                    Spacer(minLength: 0)

                    Text("\(tasks.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

                    if rollup != .none, !tasks.isEmpty {
                        Circle()
                            .fill(rollup.color)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, TaskRowMetrics.horizontalPadding)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        TaskRowView(task: task, style: .compact)
                        Divider()
                            .overlay(Color.primary.opacity(0.06))
                    }
                }
            }

            Divider()
                .overlay(Color.primary.opacity(0.06))
        }
    }

    private func toggle(_ status: TaskStatus) {
        if expanded.contains(status) {
            expanded.remove(status)
        } else {
            expanded.insert(status)
        }
    }

    // MARK: - Rollup

    private enum RollupDot {
        case none
        case terracotta
        case neutral

        var color: Color {
            switch self {
            case .none:       return .clear
            case .terracotta: return WorkspaceLayout.waitingTerracotta
            case .neutral:    return Color(nsColor: .tertiaryLabelColor)
            }
        }
    }
}
