import AppKit
import SwiftUI

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
struct TaskRowView: View {
    let task: TaskItem
    let style: TaskRowStyle

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

    var body: some View {
        Group {
            switch style {
            case .hero:    heroBody
            case .compact: compactBody
            }
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .frame(height: style == .hero ? TaskRowMetrics.heroHeight : TaskRowMetrics.compactHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(hoverFill)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
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
            handleTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title). \(statusPhrase)")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Tap handler

    /// Single click: open the task's `.md` note in the user's default editor
    /// and, when possible, start-or-focus a terminal session for the task's
    /// project. The two sides are independent — a missing file or an
    /// unresolvable project is tolerated silently.
    ///
    /// Path resolution order for the terminal spawn:
    ///   1. Explicit `project-path` frontmatter (authoritative; tilde-expanded)
    ///   2. `WorkspaceStore.projects` lookup by `name == task.project`
    ///   3. Give up on the terminal side — keep the `.md` open as the useful
    ///      half of the action.
    private func handleTap() {
        // Always: open the .md file.
        if let url = taskStore.fileURL(for: task) {
            NSWorkspace.shared.open(url)
        }

        // Terminal side: resolve the project cwd path.
        let resolvedPath: String? = {
            if let raw = task.projectPath, !raw.isEmpty {
                return (raw as NSString).expandingTildeInPath
            }
            if let storeProject = workspaceStore.projects
                .first(where: { $0.name == task.project }) {
                return storeProject.rootPath
            }
            return nil
        }()

        // Template resolution: task frontmatter wins over user preference.
        // A nil result lets `startOrFocusSession` use its own fallback.
        let resolvedTemplateName: String? = task.template
            ?? (defaultTaskTemplate.isEmpty ? nil : defaultTaskTemplate)

        if let path = resolvedPath {
            coordinator.startOrFocusSession(
                forProjectNamed: task.project,
                rootPath: path,
                templateName: resolvedTemplateName
            )
        } else if let storeProject = workspaceStore.projects
            .first(where: { $0.name == task.project }) {
            // Fallback: no path resolvable, but a project with this name
            // exists — focus whatever live session it has, don't spawn.
            coordinator.focusLastSession(forProject: storeProject.id)
        }
        // else: silent skip; the .md was already opened.
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

            Text(statusPhrase)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
        }
    }

    // MARK: - Compact body

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 8) {
            statusGlyph(isHero: false)
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

            Text(trailingTime)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .padding(.top, 2)
        }
    }

    // MARK: - Glyphs

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

    /// v0: all fixtures use `project: ghostties` — render a single green dot
    /// matching the HTML mock (`--dot-green: #7cb342`). Future revisions
    /// will map project → color.
    private var projectGlyph: some View {
        Circle()
            .fill(Color(red: 0.486, green: 0.702, blue: 0.259))
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
        case .running:  return Color(red: 0.486, green: 0.702, blue: 0.259) // green
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
    /// shell tasks without a branch.
    private var compactMetaLine: String {
        var parts: [String] = []
        if let b = task.branch { parts.append("⎇ \(b)") }
        if let n = task.filesStaged { parts.append("\(n) file\(n == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append(task.project) }
        return parts.joined(separator: " · ")
    }

    /// Trailing time column: relative minutes/hours from `created`.
    private var trailingTime: String {
        return relativeTime(from: task.created)
    }

    // MARK: - Hover

    private var hoverFill: Color {
        guard isHovered else { return .clear }
        return colorScheme == .dark
            ? WorkspaceLayout.activeRowDark
            : WorkspaceLayout.activeRowLight
    }

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
