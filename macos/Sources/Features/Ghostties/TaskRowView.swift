import AppKit
import SwiftUI

// MARK: - ReturnKeyActivationModifier

/// Applies `.onKeyPress(.return)` only on macOS 14+.
/// On macOS 13 the handler is a no-op — the AppDelegate menu path
/// (`ghosttiesActivateFocusedTaskRow` notification) provides Return coverage.
private struct ReturnKeyActivationModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.onKeyPress(.return) {
                action()
                return .handled
            }
        } else {
            content
        }
    }
}

/// Visual row style for the task-first sidebar.
///
/// - `hero`:    oversized 2-line row used by the "Needs you" zone. Title on
///              line one, contextual sub-line (the `needs` prompt or branch/
///              files/time) on line two. ~56pt tall.
/// - `compact`: 2-line compact row used by the "Active" zone. Title on line
///              one, SF Mono branch · file count · source on line two. ~48pt.
///
/// The row atom deliberately owns both styles rather than being two views so
/// that field resolution (title, meta line, trailing time) stays co-located
/// with the visual rules. Archive-lane rows render in `compact` as well.
enum TaskRowStyle {
    case compact
    case hero
}

/// Heights are mirrored in `SlotPlaceholderView` so empty slots and filled
/// active rows land on the same grid — the linchpin of the "spatial stability"
/// principle from the design brief.
enum TaskRowMetrics {
    static let compactHeight: CGFloat = 48
    static let heroHeight: CGFloat = 56
    static let horizontalPadding: CGFloat = 14
}

/// One task row. See `TaskRowStyle` for the two visual variants.
///
/// Clicking a row opens the task's `.md` file in the user's default markdown
/// editor and, if the task's `project` name matches a `WorkspaceStore`
/// project, switches the terminal to that project's last active session.
///
/// ### D14 — Hit-test guard
///
/// The row observes `RowClickRouter.shared` to apply `.allowsHitTesting(false)`
/// for 180ms after a click fires. This swallows in-animation re-taps without
/// requiring a separate state variable on the view. The router publishes
/// `hitTestingBlockedTaskIds` on the main actor.
///
/// ### D13 — Error chip
///
/// When a write to disk fails in `startInboxTask`, `RowClickRouter` stores the
/// error message in `taskRowErrors`. This view renders a compact red label
/// below the row content while the error is present. The chip clears on the
/// next successful write.
///
/// For Graveyard rows, pass `showChevron: true` and bind `isExpanded` to the
/// store's expansion state. The 14px chevron column is Graveyard-only (D24);
/// all other lanes pass the defaults (both false) and the column is absent.
struct TaskRowView: View {
    let task: TaskItem
    let style: TaskRowStyle
    /// D24: show the 14pt leading chevron slot. Graveyard rows pass `true`.
    /// Inbox / Running / Needs-you rows omit this (default false).
    var showChevron: Bool = false
    /// D24: current expansion state for this row. Used to rotate the chevron.
    var isExpanded: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var workspaceStore: WorkspaceStore
    /// User preference: which `AgentTemplate` to launch when a task row is
    /// clicked and the task itself doesn't specify one. Empty string = use
    /// the built-in default (whatever `startOrFocusSession` falls back to).
    /// No Settings UI in v0 — set via
    /// `defaults write com.mitchellh.ghostty ghostties.defaultTaskTemplate "Orchestrator"`.
    @AppStorage("ghostties.defaultTaskTemplate") private var defaultTaskTemplate: String = ""
    @State private var isHovered = false

    /// Observed so that D14 hit-test guard and D13 error chip react to router state.
    @ObservedObject private var router = RowClickRouter.shared

    // MARK: - U11 — Row focus model

    /// When true this row is the active keyboard target within the sidebar list.
    /// `Return` activates the row; `⌘O` opens the `.md` file.
    /// One row at a time holds focus (SwiftUI enforces mutual exclusion across
    /// the same `FocusState` scope when rows are in a shared `List` or `VStack`).
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch style {
                case .hero:    heroBody
                case .compact: compactBody
                }
            }
            .padding(.horizontal, TaskRowMetrics.horizontalPadding)
            .frame(height: style == .hero ? TaskRowMetrics.heroHeight : TaskRowMetrics.compactHeight)
            .frame(maxWidth: .infinity, alignment: .leading)

            // D13 — Error chip: shown when a write to disk fails.
            // Persists until the next successful write clears the entry in the router.
            if let errorMessage = router.taskRowErrors[task.id] {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(Color(nsColor: .systemRed))
                .padding(.horizontal, TaskRowMetrics.horizontalPadding)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                // Hover / expanded anchor background
                Rectangle()
                    .fill(anchorFill)
                    .allowsHitTesting(false)
                // D20: neutral left-rule when expanded (no terracotta on Graveyard)
                if isExpanded {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
        )
        .contentShape(Rectangle())
        // D14-a — Disable hit-testing during the 180ms animation window.
        .allowsHitTesting(!router.hitTestingBlockedTaskIds.contains(task.id))
        .onHover { hovering in
            isHovered = hovering
            // Pointer cursor on hover — the row is a handle to a real thing.
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            RowClickRouter.shared.handleRowClick(
                task,
                taskStore: taskStore,
                coordinator: coordinator,
                workspaceStore: workspaceStore,
                defaultTaskTemplate: defaultTaskTemplate
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        .accessibilityHint("Opens in editor and switches terminal to this task's project")
        .accessibilityAddTraits(.isButton)
        // U11 — Row focus model
        .focusable()
        .focused($isFocused)
        .overlay(alignment: .leading) {
            // Subtle 1px leading rule visible when this row has keyboard focus.
            // Uses chrome-system white at low opacity (matches WorkspaceLayout chrome tones).
            if isFocused {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: isFocused) { focused in
            if focused {
                RowFocusStore.shared.setFocused(task, taskStore: taskStore)
            } else {
                RowFocusStore.shared.clearFocus(for: task.id)
            }
        }
        // U11: direct Return key press when this row has SwiftUI focus.
        // Requires macOS 14+; on macOS 13 the Return menu-item path (below) provides coverage.
        .modifier(ReturnKeyActivationModifier {
            RowClickRouter.shared.handleRowClick(
                task,
                taskStore: taskStore,
                coordinator: coordinator,
                workspaceStore: workspaceStore,
                defaultTaskTemplate: defaultTaskTemplate
            )
        })
        // U11: observe the Return menu-item notification fired by AppDelegate.
        // This path activates the row when the menu shortcut fires (rather than
        // direct key press), using this view's own SwiftUI environment objects
        // so window-scoped coordinator references stay correct.
        .onReceive(NotificationCenter.default.publisher(
            for: .ghosttiesActivateFocusedTaskRow
        )) { notification in
            guard isFocused,
                  let taskId = notification.object as? String,
                  taskId == task.id else { return }
            RowClickRouter.shared.handleRowClick(
                task,
                taskStore: taskStore,
                coordinator: coordinator,
                workspaceStore: workspaceStore,
                defaultTaskTemplate: defaultTaskTemplate
            )
        }
    }

    private var accessibilityRowLabel: String {
        // FYI-2: include action verb "Open task" so VoiceOver announces intent.
        if let err = router.taskRowErrors[task.id] {
            return "Open task: \(task.title). \(statusPhrase). Write error: \(err)"
        }
        return "Open task: \(task.title). \(statusPhrase)"
    }

    // MARK: - Hero body

    private var heroBody: some View {
        HStack(alignment: .top, spacing: 10) {
            statusGlyph(isHero: true)
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(heroSubline)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            // U11: 📝 chip visible on hover. Same code path as ⌘O.
            if isHovered {
                notesChip
            }

            Text(statusPhrase)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
        }
    }

    // MARK: - Compact body

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 8) {
            // D24: 14px chevron leading slot, Graveyard-only.
            // Inbox / Running / Needs-you rows don't render this column at all.
            if showChevron {
                chevronGlyph
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 3)
            }

            // D21: priority glyph for Inbox rows; status glyph for all others.
            // Both occupy the same 12px monospaced slot so column width is stable.
            leadingSlotGlyph
                .frame(width: 12, alignment: .center)
                .padding(.top, 3)

            projectGlyph
                .frame(width: 14, height: 14, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(compactMetaLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            // U11: 📝 chip visible on hover. Same code path as ⌘O.
            if isHovered {
                notesChip
                    .padding(.top, 2)
            }

            Text(trailingTime)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .padding(.top, 2)
        }
    }

    // MARK: - Chevron glyph (Graveyard-only, D24)

    /// Animated chevron. 0° (pointing right) when collapsed; 90° when expanded.
    /// 11pt SF Mono. Opacity 0.45 collapsed → 1.0 expanded.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chevronGlyph: some View {
        Text("›")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(isExpanded ? 1.0 : 0.45))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(
                reduceMotion
                    ? .linear(duration: 0)
                    : .timingCurve(0.2, 0.0, 0.2, 1.0, duration: 0.16),
                value: isExpanded
            )
            // FYI-2: announce expansion state so VoiceOver users know the affordance.
            .accessibilityLabel(isExpanded ? "Collapse task notes" : "Expand task notes")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Notes chip (U11, R13)

    /// Pencil-note chip shown on hover. Tapping opens the task's `.md` file in
    /// the user's default editor — the same action as `⌘O` from the menu.
    ///
    /// Tooltip reads "Open notes — ⌘O" so the keyboard shortcut is discoverable
    /// from the pointer surface (FYI item 3 from the U11 design brief).
    private var notesChip: some View {
        Button {
            if let url = taskStore.fileURL(for: task) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text("📝")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .help("Open notes — ⌘O")
        // FYI-2: VoiceOver label includes task title so it's unambiguous.
        .accessibilityLabel("Open notes for \(task.title)")
        .accessibilityHint("Keyboard shortcut: Command O")
    }

    // MARK: - Glyphs

    /// D21: leading 12px slot dispatcher for compact rows.
    ///
    /// Inbox rows show the priority glyph (▲/►/▼/·). All other rows show the
    /// standard status glyph. The slot width is 12px in both cases so the
    /// column layout is stable regardless of which glyph occupies it.
    @ViewBuilder
    private var leadingSlotGlyph: some View {
        if task.status == .inbox {
            priorityGlyph
        } else {
            statusGlyph(isHero: false)
        }
    }

    /// D21 priority glyph — Inbox rows only, compact style.
    ///
    /// Four glyphs, monospaced 12px:
    ///  - `.high`   → ▲  muted foreground (rgba 255,255,255,0.55)
    ///  - `.medium` → ►  same
    ///  - `.low`    → ▼  same
    ///  - `.none`   → ·  quieter foreground (rgba 255,255,255,0.30)
    ///
    /// Intentionally no color — priority is conveyed through shape only.
    private var priorityGlyph: some View {
        Text(priorityGlyphCharacter)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(priorityGlyphColor)
    }

    private var priorityGlyphCharacter: String {
        switch task.priority {
        case .high:   return "▲"
        case .medium: return "►"
        case .low:    return "▼"
        case .none:   return "·"
        }
    }

    private var priorityGlyphColor: Color {
        task.priority == .none
            ? Color.white.opacity(0.30)
            : Color.white.opacity(0.55)
    }

    /// Leading status glyph. Terracotta only when the row represents a
    /// needs-you item (hero style); every other row tone is neutral.
    @ViewBuilder
    private func statusGlyph(isHero: Bool) -> some View {
        if isHero {
            // 7pt filled dot with a subtle halo — matches the HTML mock
            // "dot.terra" treatment.
            Circle()
                .fill(WorkspaceLayout.waitingTerracotta)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(WorkspaceLayout.waitingTerracotta.opacity(0.35), lineWidth: 3)
                        .blur(radius: 1.5)
                )
        } else {
            Image(systemName: statusSymbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusSymbolColor)
        }
    }

    /// v0: all fixtures use `project: ghostties` — render a single sage dot
    /// (`#8aa96a`, muted olive/sage). Desaturated from the original lime
    /// `#7cb342` to sit more quietly against the warm chrome. Future
    /// revisions will map project → color.
    private var projectGlyph: some View {
        Circle()
            .fill(Color(red: 0.541, green: 0.663, blue: 0.416))
    }

    private var statusSymbolName: String {
        switch task.status {
        case .needsYou: return "bolt.fill"
        case .running:  return "play.fill"
        case .inbox:    return "circle"
        case .backlog:  return "circle.dotted"
        case .review:   return "arrow.triangle.branch"
        case .done:     return "checkmark"
        }
    }

    private var statusSymbolColor: Color {
        switch task.status {
        case .running:  return Color(red: 0.541, green: 0.663, blue: 0.416) // sage
        case .done:     return Color(nsColor: .tertiaryLabelColor)
        default:        return Color(nsColor: .secondaryLabelColor)
        }
    }

    // MARK: - Copy

    /// Right-aligned status phrase. Short, verb-first. Matches brief §7.
    private var statusPhrase: String {
        switch task.status {
        case .needsYou:
            return relativeTime(from: task.created)
        case .running:
            return "Running"
        case .inbox:
            return "Inbox"
        case .backlog:
            return "Queued"
        case .review:
            if let n = task.pr { return "PR #\(n)" }
            return "Review"
        case .done:
            return "Done \(relativeTime(from: task.completed ?? task.created))"
        }
    }

    /// Hero-row second line: the `needs` question if present, else fall back
    /// to branch + relative time.
    private var heroSubline: String {
        if let needs = task.needs, !needs.isEmpty {
            return needs
        }
        if let b = task.branch {
            return "⎇ \(b)"
        }
        return task.project
    }

    /// Compact-row meta line: branch · N files · source OR just source for
    /// shell tasks without a branch. When project+branch is already long
    /// (>20 chars combined), drop the lower-priority files count so the more
    /// valuable fields survive tail-truncation at 280pt sidebar width.
    private var compactMetaLine: String {
        var parts: [String] = []
        if let b = task.branch { parts.append("⎇ \(b)") }
        let cramped = (task.project.count + (task.branch?.count ?? 0)) > 20
        if let n = task.filesStaged, !cramped {
            parts.append("\(n) file\(n == 1 ? "" : "s")")
        }
        if parts.isEmpty { parts.append(task.project) }
        return parts.joined(separator: " · ")
    }

    /// Trailing time column: relative minutes/hours from `created`.
    private var trailingTime: String {
        return relativeTime(from: task.created)
    }

    // MARK: - Hover / anchor fill

    /// Background fill for the anchor row.
    ///
    /// Precedence:
    /// 1. Expanded: rgba(255,255,255,0.04) — anchored-open state (D spec).
    /// 2. Hovered: standard hover color.
    /// 3. Default: clear.
    private var anchorFill: Color {
        if isExpanded {
            return Color.white.opacity(0.04)
        }
        guard isHovered else { return .clear }
        return colorScheme == .dark
            ? WorkspaceLayout.activeRowDark
            : WorkspaceLayout.activeRowLight
    }

    // Keep the old name as an alias so future callers that read the property
    // directly still compile without change.
    private var hoverFill: Color { anchorFill }

    // MARK: - Helpers

    private func relativeTime(from date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "now" }
        if delta < 3600 {
            let m = Int(delta / 60)
            return "\(m)m"
        }
        if delta < 86_400 {
            let h = Int(delta / 3600)
            return "\(h)h"
        }
        let d = Int(delta / 86_400)
        return "\(d)d"
    }
}
