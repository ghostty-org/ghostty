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
struct InboxZoneView: View {
    @ObservedObject var taskStore: TaskStore

    /// Cached once per render so the header count and the `ForEach` agree
    /// on what they're showing.
    private var rows: [TaskItem] { taskStore.externalInbox }

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
                        TaskRowView(task: task, style: .compact)
                        Divider()
                            .overlay(Color.primary.opacity(0.06))
                    }
                }
            }
            .padding(.vertical, 4)
        }
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
