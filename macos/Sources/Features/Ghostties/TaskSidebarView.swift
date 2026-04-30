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
///
/// U8 (SEA-164): adds the persistent `[+ Start]` button in the header strip
/// (D22) and the inline composer slot driven by `NewTaskComposerStore.shared`.
struct TaskSidebarView: View {
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var sessionDraftStore: SessionDraftStore

    /// U8: composer store — drives [+ Start] button state and the composer card.
    @ObservedObject private var composerStore: NewTaskComposerStore = .shared

    @EnvironmentObject private var workspaceStore: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("ghostties.hasSeenTasksPreviewNotice") private var hasSeenTasksPreviewNotice = false

    var body: some View {
        VStack(spacing: 0) {
            // D22: header strip with [+ Start] button at top-right.
            sidebarHeader

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !hasSeenTasksPreviewNotice {
                        SidebarCalloutCard(
                            iconName: "wrench.and.screwdriver.fill",
                            message: "Tasks is an early preview. Things may change. Send feedback to sean@seansmithdesign.com.",
                            onDismiss: { hasSeenTasksPreviewNotice = true }
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                    // Zone order follows the brief's locked lane order:
                    // Inbox · Backlog · Running · Needs you · Review · Graveyard.
                    //
                    // Only four of the six lanes have a dedicated top-level
                    // zone view today — Backlog and Review currently live as
                    // sub-lanes inside the Graveyard (ArchiveZoneView) and are
                    // not rendered as standalone zones. The order below is the
                    // brief's order with those two skipped:
                    //
                    //   Inbox (source-based) → Running (Active) →
                    //   Needs you → Graveyard (which internally holds
                    //   Backlog · Review · Done).
                    //
                    // Inbox hides itself entirely when empty — most days it
                    // will not render at all, so we only emit the trailing
                    // divider when it has rows.
                    InboxZoneView(
                        taskStore: taskStore,
                        workspaceStore: workspaceStore,
                        composerStore: composerStore
                    )
                    // Only emit the trailing divider when the inbox actually
                    // rendered rows (or is empty with the composer open).
                    if !taskStore.externalInbox.isEmpty || composerStore.isOpen {
                        zoneDivider
                    }

                    // SG-03: Active / Running zone — fully hidden when empty.
                    // "Empty" means no running tasks AND no unpromoted session drafts.
                    let activeIsEmpty = taskStore.active.isEmpty && sessionDraftStore.drafts.filter { $0.promotedToTaskId == nil }.isEmpty
                    if !activeIsEmpty {
                        ActiveZoneView(
                            taskStore: taskStore,
                            sessionDraftStore: sessionDraftStore
                        )
                        zoneDivider
                    }

                    // SG-03: Needs-you zone — fully hidden when empty.
                    if !taskStore.needsYou.isEmpty {
                        NeedsYouZoneView(taskStore: taskStore)
                        zoneDivider
                    }

                    // SG-03: Graveyard / Archive zone — fully hidden when all sub-lanes empty.
                    let graveyardIsEmpty = taskStore.inbox.isEmpty
                        && taskStore.backlog.isEmpty
                        && taskStore.review.isEmpty
                        && taskStore.done.isEmpty
                    if !graveyardIsEmpty {
                        ArchiveZoneView(taskStore: taskStore)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(maxHeight: .infinity)
        .background(backgroundColor)
        // U8: Observe the notification that AppDelegate's ⌘⇧N monitor posts.
        .onReceive(NotificationCenter.default.publisher(for: .openNewTaskComposer)) { _ in
            composerStore.open(workspaceStore: workspaceStore)
        }
    }

    // MARK: - Header strip (D22)

    /// Sticky header with a low-contrast `[+ Start]` button at top-right.
    /// Stays outside the ScrollView so it doesn't scroll away.
    private var sidebarHeader: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // D22: low-contrast chrome button — NOT terracotta.
            Button {
                composerStore.open(workspaceStore: workspaceStore)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Start")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.primary.opacity(0.60))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                // D20: rgba(255,255,255,0.08) background — no terracotta.
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("New task — ⌘⇧N")
            .accessibilityLabel("Start a new task")
            .accessibilityHint("Opens the new task composer. Keyboard shortcut: Command Shift N")
            .padding(.trailing, TaskRowMetrics.horizontalPadding)
        }
        .frame(height: 28)
        .background(backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
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
                .fill(Color(red: 0.541, green: 0.663, blue: 0.416))
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

#if DEBUG
#Preview("Task Sidebar — Light + Dark") {
    let ws = WorkspaceStore(testingProjects: [])
    HStack(spacing: 24) {
        TaskSidebarView(
            taskStore: TaskStore(),
            sessionDraftStore: SessionDraftStore()
        )
        .environmentObject(ws)
        .preferredColorScheme(.light)
        TaskSidebarView(
            taskStore: TaskStore(),
            sessionDraftStore: SessionDraftStore()
        )
        .environmentObject(ws)
        .preferredColorScheme(.dark)
    }
    .padding(24)
    .frame(height: 780)
}
#endif
