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
/// **U8 exception to hide-when-empty:** when the new-task composer is open
/// the Inbox zone renders even when `rows` is empty:
///   • If empty: composer replaces the empty canvas in place (D5).
///   • If non-empty: composer renders at the top of the lane, rows push down.
///
/// **U8 empty-area click target (D5, trigger b):** when Inbox is empty and
/// the composer is NOT open, the whole empty-inbox area is a tap target that
/// opens the composer. Copy: "Nothing in the inbox." / "Click anywhere here
/// to start a new task." (D23 — locked strings).
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
    /// SEA-213: observe at zone level so individual TaskRowViews don't each
    /// hold an independent @ObservedObject on the singleton.
    @ObservedObject private var router = RowClickRouter.shared

    /// U8: composer store — drives the empty-area click target + composer slot.
    @ObservedObject var composerStore: NewTaskComposerStore

    /// U6: triage store drives the inline card slot.
    @ObservedObject private var triageStore: OrphanTriageStore = .shared

    @EnvironmentObject private var coordinator: SessionCoordinator
    @AppStorage("ghostties.defaultTaskTemplate") private var defaultTaskTemplate: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// SEA-215: Read the pre-sorted array from the store instead of sorting
    /// inline. `TaskStore.recomputeLanes()` performs the O(n log n) sort once
    /// when the task list changes; this computed var is now O(1).
    ///
    /// Sort order: primary `priority` descending (high → none), secondary
    /// `created` descending (newest first). Matches R15 from the U1 spec.
    private var rows: [TaskItem] {
        taskStore.sortedExternalInbox
    }

    /// True when every lane is empty — triggers the first-run hint (SG-03).
    private var isAllEmpty: Bool {
        taskStore.externalInbox.isEmpty
            && taskStore.active.isEmpty
            && taskStore.needsYou.isEmpty
            && taskStore.inbox.isEmpty
            && taskStore.backlog.isEmpty
            && taskStore.review.isEmpty
            && taskStore.done.isEmpty
    }

    var body: some View {
        if rows.isEmpty && !composerStore.isOpen {
            // U8 trigger b: the whole empty-inbox area is a tap target.
            // "Nothing in the inbox. / Click anywhere here to start a new task."
            emptyInboxClickTarget
        } else if rows.isEmpty && composerStore.isOpen {
            // D5: composer replaces the empty-Inbox canvas in place.
            VStack(alignment: .leading, spacing: 0) {
                composerSlot
            }
            .padding(.vertical, 4)
        } else {
            // Inbox has rows — render header + optional composer at top + rows.
            VStack(alignment: .leading, spacing: 0) {
                header

                // D5: composer at the top of the lane when Inbox has rows.
                if composerStore.isOpen {
                    composerSlot
                    Divider().overlay(Color.primary.opacity(0.06))
                }

                VStack(spacing: 0) {
                    ForEach(rows) { task in
                        rowWithTriageSlot(task: task)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - U8 composer slot

    /// Renders `NewTaskComposerView` when open (D5). The view owns its own
    /// animation, so we just insert/remove it from the hierarchy here.
    @ViewBuilder
    private var composerSlot: some View {
        if composerStore.isOpen {
            NewTaskComposerView(
                store: composerStore,
                taskStore: taskStore
            )
            .environmentObject(workspaceStore)
            .transition(composerTransition)
            .animation(composerAnimation, value: composerStore.isOpen)
        }
    }

    // MARK: - Animations (D18, D19) — tokens from WorkspaceLayout.Animation

    private var composerAnimation: Animation {
        reduceMotion ? .sidebarReducedMotion : .sidebarPush
    }

    private var composerTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity.animation(.sidebarReducedMotion)
            : AnyTransition.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal:   .opacity.combined(with: .move(edge: .top))
            ).animation(.sidebarPush)
    }

    // MARK: - Row + inline triage card slot (D4)

    /// Renders the task row and, if this task is the active orphan, the triage
    /// card immediately below it. Rows below shift down (intra-zone reflow).
    @ViewBuilder
    private func rowWithTriageSlot(task: TaskItem) -> some View {
        let isAnchor = triageStore.activeTaskId == task.id

        // Anchor row with optional 2px terracotta left-rule (D20).
        TaskRowView(
            task: task,
            style: .compact,
            isHitTestBlocked: router.hitTestingBlockedTaskIds.contains(task.id),
            rowError: router.taskRowErrors[task.id]
        )
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

    // MARK: - Triage card animations (D18, D19) — tokens from WorkspaceLayout.Animation

    private var cardAnimation: Animation {
        reduceMotion ? .sidebarReducedMotion : .sidebarPush
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? AnyTransition.opacity.animation(.sidebarReducedMotion)
            : AnyTransition.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            ).animation(.sidebarCollapse)
    }

    // MARK: - U8 empty-inbox click target (trigger b, D5, D23)

    /// Renders the empty-inbox dead-end state with locked copy and a full-area
    /// tap target. Only shown when Inbox has no rows AND the composer is closed.
    /// Clicking anywhere opens the composer (D11 guard lives in composerStore.open).
    ///
    /// SG-03: when ALL lanes are empty, appends a first-run hint pointing at
    /// the [+ Start] button so new users understand the entry point.
    private var emptyInboxClickTarget: some View {
        VStack(spacing: 4) {
            Text("Nothing in the inbox.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.center)

            Text("Click anywhere here to start a new task.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .multilineTextAlignment(.center)

            // SG-03: first-run hint — shown only when every lane is empty.
            if isAllEmpty {
                Text("Press ⌘⇧N or click [+ Start] to begin.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 20)
        .contentShape(Rectangle())
        .onTapGesture {
            composerStore.open(workspaceStore: workspaceStore)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isAllEmpty
                ? "Inbox empty. Press Command Shift N or click Start to begin."
                : "Nothing in the inbox. Tap to start a new task."
        )
        .accessibilityHint("Opens the new task composer")
        .accessibilityAddTraits(.isButton)
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
