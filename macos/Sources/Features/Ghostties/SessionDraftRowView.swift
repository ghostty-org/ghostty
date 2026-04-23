import AppKit
import SwiftUI

/// Anonymous-session row — the visual sibling of `TaskRowView` for terminal
/// sessions that haven't been promoted to tasks. See design-session-hybrid.md.
///
/// Visual contract:
/// - Leading glyph: hollow ring `◌` (vs filled `●` for tasks) — "uncommitted"
/// - Title: monospaced cwd, dimmer than a task title
/// - Meta row: "session · {relative_time}" — no project pill, no branch, no files
/// - Hover: reveals a right-aligned `+ Name` button; click swaps in an inline
///   text field. Enter promotes the draft to a task (new .md in `.ghostties/tasks/`,
///   draft removed from this list).
/// - Body click: focuses the terminal session via `SessionCoordinator`.
struct SessionDraftRowView: View {
    let draft: SessionDraft

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var sessionDraftStore: SessionDraftStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var workspaceStore: WorkspaceStore

    @State private var isHovered = false
    @State private var isNaming = false
    @State private var draftTitle: String = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ringGlyph
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                if isNaming {
                    nameField
                } else {
                    Text(displayCwd)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(metaLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            if isNaming {
                // Replaces the + Name affordance while we're editing.
                Text("↵")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.top, 2)
            } else if isHovered {
                promoteButton
            } else {
                // Reserve slot for the time label so the row width doesn't
                // shift when the hover button appears.
                Text(trailingTime)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .frame(height: TaskRowMetrics.compactHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(hoverFill)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // Keep hover state sticky while the inline field is active so the
            // row doesn't "reset" on pointer motion during typing.
            isHovered = hovering
            if hovering, !isNaming {
                NSCursor.pointingHand.push()
            } else if !hovering {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            guard !isNaming else { return }
            handleBodyTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal session at \(displayCwd). \(metaLine)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Subviews

    private var ringGlyph: some View {
        // Hollow ring — the unmistakable "uncommitted" signal. Slightly bigger
        // than the task status glyph so it reads as the primary mark.
        Circle()
            .stroke(Color(nsColor: .secondaryLabelColor), lineWidth: 1.2)
            .frame(width: 8, height: 8)
    }

    private var nameField: some View {
        TextField("Name this task…", text: $draftTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundColor(.primary)
            .focused($isNameFieldFocused)
            .onSubmit { commitPromotion() }
            .onExitCommand { cancelNaming() }
            .onAppear {
                // Focus after the transition animates in so the TextField is
                // actually in the hierarchy.
                DispatchQueue.main.async { isNameFieldFocused = true }
            }
    }

    private var promoteButton: some View {
        Button(action: startNaming) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Actions

    private func handleBodyTap() {
        guard let id = draft.terminalSessionId else { return }
        coordinator.focusSession(id: id)
    }

    private func startNaming() {
        draftTitle = ""
        isNaming = true
    }

    private func commitPromotion() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelNaming()
            return
        }
        _ = sessionDraftStore.promoteToTask(
            draftId: draft.id,
            title: trimmed,
            workspaceStore: workspaceStore
        )
        // The store removed the draft. SwiftUI will drop this row on the next
        // publish cycle; nothing more to do here.
    }

    private func cancelNaming() {
        isNaming = false
        draftTitle = ""
    }

    // MARK: - Derived copy

    /// Collapse `$HOME` back to `~` so rows stay short. Raw cwd is the
    /// canonical form on disk; we only prettify for display.
    private var displayCwd: String {
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let path = (draft.cwd as NSString).expandingTildeInPath
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return draft.cwd
    }

    private var metaLine: String {
        draft.isStale
            ? "session · stale · \(relativeTime(from: draft.startedAt))"
            : "session · \(relativeTime(from: draft.startedAt))"
    }

    private var trailingTime: String {
        relativeTime(from: draft.startedAt)
    }

    private var hoverFill: Color {
        guard isHovered else { return .clear }
        return colorScheme == .dark
            ? WorkspaceLayout.activeRowDark
            : WorkspaceLayout.activeRowLight
    }

    private func relativeTime(from date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        return "\(Int(delta / 86_400))d"
    }
}
