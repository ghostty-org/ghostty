import SwiftUI

/// Inbox zone — top of the sidebar. Renders tasks that arrived from an
/// external MCP source (Linear, GitHub, Sentry, …) — anything where
/// `source != .shell`.
///
/// First user-visible payoff of the Phase 5 architecture pivot
/// (agent-as-middleman). The user's agent reads tickets from external
/// sources and writes them as tasks; those tasks land here so the user can
/// see "the agent fetched 8 tickets from Linear into my Inbox."
///
/// **Hides itself when empty** — unlike `NeedsYouZoneView`, the Inbox does
/// not reserve vertical space when it has nothing to show. Most days this
/// zone won't render at all, so collapsing it keeps the sidebar quiet
/// (mission posture: tool, not companion).
///
/// The Graveyard zone still has its own status-based `.inbox` lane for
/// triaged-but-not-yet-actioned items; the two are intentionally distinct.
/// Source-based Inbox = external arrivals; status-based Inbox = local
/// triage state.
///
/// U6: inline orphan triage card rendered below the anchor row (D4 push
/// mechanic). The `triageStore` is observed so the card appears/disappears
/// reactively when `OrphanTriageStore.shared.activeTaskId` changes.
struct InboxZoneView: View {
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var workspaceStore: WorkspaceStore

    /// U6: triage store drives the inline card slot.
    @ObservedObject private var triageStore: OrphanTriageStore = .shared

    @EnvironmentObject private var coordinator: SessionCoordinator
    @AppStorage("ghostties.defaultTaskTemplate") private var defaultTaskTemplate: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cached once per render so the header count and the `ForEach` agree
    /// on what they're showing.
    ///
    /// Sort order: primary `priority` descending (high → none), secondary
    /// `created` descending (newest first). Matches R15 from the U1 spec.
    private var rows: [TaskItem] {
        taskStore.externalInbox.sorted {
            if $0.priority.sortRank != $1.priority.sortRank {
                return $0.priority.sortRank > $1.priority.sortRank
            }
            return $0.created > $1.created
        }
    }

    var body: some View {
        // Empty: render nothing (no header, no divider, no reserved height).
        // The parent's `zoneDivider` is what would otherwise be visible.
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: 0) {
                    ForEach(rows) { task in
                        rowWithTriageSlot(task: task)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Row + inline triage card slot (D4)

    /// Renders the task row and, if this task is the active orphan, the triage
    /// card immediately below it. Rows below shift down (intra-zone reflow).
    @ViewBuilder
    private func rowWithTriageSlot(task: TaskItem) -> some View {
        let isAnchor = triageStore.activeTaskId == task.id

        // Anchor row with optional 2px terracotta left-rule (D20).
        TaskRowView(task: task, style: .compact)
            .overlay(alignment: .leading) {
                if isAnchor {
                    Rectangle()
                        .fill(WorkspaceLayout.waitingTerracotta)
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
            // D14: disable hit testing on the anchor row for 180ms while
            // the card reveals or collapses.
            .allowsHitTesting(!triageStore.isAnimating || !isAnchor)

        // D4: push rows below down by inserting the card here.
        // D11: only one card at a time — guarded by `isAnchor`.
        if isAnchor {
            let handlersBox = makeHandlersBox()
            OrphanTriageCardView(
                task: task,
                triageStore: triageStore,
                taskStore: taskStore,
                workspaceStore: workspaceStore,
                handlers: handlersBox
            )
            // Click-outside cancels (D25). Background tap cancels the card.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { triageStore.cancel() }
            )
            // D18/D19: animated reveal driven by `triageStore.activeTaskId`.
            .transition(cardTransition)
            .animation(cardAnimation, value: triageStore.activeTaskId)
        }

        Divider()
            .overlay(Color.primary.opacity(0.06))
    }

    // MARK: - RowClickHandlersBox factory

    /// Build a fresh `RowClickHandlersBox` with the current environment objects.
    /// Called at render time so the box always captures the latest coordinator
    /// and store references.
    private func makeHandlersBox() -> RowClickHandlersBox {
        RowClickHandlersBox(
            RowClickHandlers(
                taskStore: taskStore,
                coordinator: coordinator,
                workspaceStore: workspaceStore,
                defaultTaskTemplate: defaultTaskTemplate
            )
        )
    }

    // MARK: - Animations (D18, D19)

    private var cardAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .easeOut(duration: 0.18)
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity.animation(.easeInOut(duration: 0.2))
            : AnyTransition.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            ).animation(.easeOut(duration: 0.14))
    }

    // MARK: - Header

    /// Left-aligned uppercase caption + monospaced count. Mirrors
    /// `ActiveZoneView` so the two top zones share a header rhythm.
    /// No accent colour — terracotta is reserved for the "Needs you" zone.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Inbox".uppercased())
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
