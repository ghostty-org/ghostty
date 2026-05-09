import SwiftUI

/// A single row in the Sessions recents list.
///
/// Displays a status dot (colored by `SessionIndicatorState`), the session name,
/// the owning project name in muted text, and a right-aligned relative timestamp.
/// Tapping focuses the session in the terminal area.
struct RecentsRowView: View {
    let session: AgentSession
    let projectName: String
    let indicatorState: SessionIndicatorState
    let isActive: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: WorkspaceLayout.sidebarIconLabelSpacing) {
            // Status dot — same color mapping as MenuBarDropdownView.
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .frame(width: WorkspaceLayout.sidebarIconColumnWidth, alignment: .center)

            // Session name + project name stacked
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(projectName)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(.tertiaryLabelColor))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Relative timestamp
            if let ts = session.lastActiveAt {
                Text(Self.relativeLabel(ts))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(.tertiaryLabelColor))
                    .monospacedDigit()
            }
        }
        .padding(.leading, WorkspaceLayout.sidebarRowLeadingPadding)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Dot Color

    private var dotColor: Color {
        switch indicatorState {
        case .error:          return Color(.systemRed)
        case .needsAttention: return WorkspaceLayout.needsAttentionPurple
        case .waiting:        return WorkspaceLayout.waitingTerracotta
        case .longRunning:    return Color(.systemYellow)
        case .processing:     return Color(.systemGreen)
        case .idle:           return Color.primary.opacity(0.30)
        case .inactive:       return Color.primary.opacity(0.12)
        }
    }

    // MARK: - Row Background

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(rowFill)
    }

    private var rowFill: Color {
        if isActive {
            return colorScheme == .dark
                ? WorkspaceLayout.activeRowDark
                : WorkspaceLayout.activeRowLight
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var parts = [session.name, "in \(projectName)"]
        if let ts = session.lastActiveAt {
            parts.append(Self.relativeLabel(ts))
        }
        if isActive { parts.append("active") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Relative Time

    /// Formats a past date as a compact relative string.
    /// - "just now" for < 1 min
    /// - "2m", "45m" for < 1 hr
    /// - "3h" for < 24 hr
    /// - Day abbreviation ("Mon") for < 7 days
    /// - "May 5" for older
    static func relativeLabel(_ date: Date) -> String {
        let elapsed = Date.now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h" }
        if elapsed < 604800 { return dayFormatter.string(from: date) }
        return monthDayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}
