import SwiftUI

/// Graveyard / queue zone — bottom of the sidebar. Four lane headers stacked
/// vertically (Inbox · Backlog · Review · Done), each click-to-expand.
/// Named "Graveyard" to pair with the ghost theme — retired/resting tasks.
///
/// Rollup dots surface items requiring attention while the lane is collapsed.
/// In v0 only Inbox carries a (terracotta) dot — and only when it has items.
/// Other lanes surface a neutral dot when a future rule populates them.
///
/// Done-lane rows support inline expansion (U7 / SEA-163). Tap a done row to
/// reveal a chip + body-preview panel below it. Only one panel open at a time
/// within this lane (D11 / D4). Tap outside leaves it open (D25).
struct ArchiveZoneView: View {
    @ObservedObject var taskStore: TaskStore
    /// SEA-213: observe at zone level so individual TaskRowViews don't each
    /// hold an independent @ObservedObject on the singleton.
    @ObservedObject private var router = RowClickRouter.shared

    /// Per-lane expand/collapse state. Collapsed by default.
    @State private var expanded: Set<TaskStatus> = []

    /// Reduced-motion preference for D18 / D19 animation grammar.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True when all four graveyard lanes are empty. Drives a single muted
    /// "nothing here yet" line so the zone doesn't read as broken.
    private var isFullyEmpty: Bool {
        taskStore.inbox.isEmpty
            && taskStore.backlog.isEmpty
            && taskStore.review.isEmpty
            && taskStore.done.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isFullyEmpty {
                emptyState
            } else {
                lane(.inbox, label: "Inbox", tasks: taskStore.inbox, rollup: .terracotta)
                lane(.backlog, label: "Backlog", tasks: taskStore.backlog, rollup: .none)
                lane(.review, label: "Review", tasks: taskStore.review, rollup: .none)
                // Done lane uses dedicated Graveyard expansion rendering (U7).
                graveyardDoneLane(tasks: taskStore.done)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Text("No tasks in the graveyard.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .opacity(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 8)
    }

    // MARK: - Zone header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Graveyard".uppercased())
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
            Button(action: { toggle(status) }, label: {
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
            })
            .buttonStyle(.plain)

            if isExpanded, !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
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

    // MARK: - Graveyard done lane (U7 inline expansion)

    /// Done lane with per-row inline expansion. Each done row renders a chevron
    /// affordance (D24) and, when tapped, expands an inline panel below the row
    /// showing frontmatter chips + body preview (D4, D10, D11, D18, D19, D20).
    private func graveyardDoneLane(tasks: [TaskItem]) -> some View {
        let isLaneExpanded = expanded.contains(.done)
        return VStack(alignment: .leading, spacing: 0) {
            // Lane header — same treatment as other lanes
            Button(action: { toggle(.done) }, label: {
                HStack(spacing: 8) {
                    Text(isLaneExpanded ? "▾" : "▸")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.28))
                        .frame(width: 10)

                    Text("Done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)

                    Spacer(minLength: 0)

                    Text("\(tasks.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(.horizontal, TaskRowMetrics.horizontalPadding)
                .frame(height: 32)
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            if isLaneExpanded, !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        let isRowExpanded = taskStore.expandedGraveyardTaskId == task.id
                        VStack(spacing: 0) {
                            // Anchor row — chevron slot active (D24)
                            TaskRowView(
                                task: task,
                                style: .compact,
                                showChevron: true,
                                isExpanded: isRowExpanded,
                                isHitTestBlocked: router.hitTestingBlockedTaskIds.contains(task.id),
                                rowError: router.taskRowErrors[task.id]
                            )

                            // Inline expansion panel (D4 push — rows below shift down)
                            if isRowExpanded {
                                GraveyardRowExpansionView(
                                    content: GraveyardExpansionContent.make(from: task)
                                )
                                .transition(
                                    .asymmetric(
                                        insertion: revealTransition,
                                        removal: collapseTransition
                                    )
                                )
                            }
                        }
                        // D18/D19 — token-based animation for row expansion.
                        .animation(
                            reduceMotion ? .sidebarReducedMotion : .sidebarPush,
                            value: isRowExpanded
                        )

                        Divider()
                            .overlay(Color.primary.opacity(0.06))
                    }
                }
            }

            Divider()
                .overlay(Color.primary.opacity(0.06))
        }
    }

    // MARK: - Animation transitions (D18 / D19) — tokens from WorkspaceLayout.Animation

    /// Panel reveal — uses `.sidebarPush` token (D18).
    /// Reduced-motion: opacity-only at 200ms (D19).
    private var revealTransition: AnyTransition {
        reduceMotion
            ? .opacity.animation(.sidebarReducedMotion)
            : .opacity.combined(with: .move(edge: .top)).animation(.sidebarPush)
    }

    /// Panel collapse — uses `.sidebarCollapse` token (D18).
    /// Reduced-motion: opacity-only at 200ms (D19).
    private var collapseTransition: AnyTransition {
        reduceMotion
            ? .opacity.animation(.sidebarReducedMotion)
            : .opacity.combined(with: .move(edge: .top)).animation(.sidebarCollapse)
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
