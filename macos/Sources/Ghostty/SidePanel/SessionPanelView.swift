import SwiftUI

struct SessionPanelView: View {
    let taskId: UUID
    let sessions: [Session]
    @Environment(\.themeColors) var colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Sessions")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colors.textMuted)
                Spacer()
                AddSessionButton(taskId: taskId)
            }
            .padding(.bottom, 10)

            if sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 12))
                    .foregroundColor(colors.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(sessions) { session in
                    SessionItemView(session: session, taskId: taskId)
                }
            }
        }
        .padding(12)
        .background(colors.sessionPanelBg)
    }
}

struct AddSessionButton: View {
    let taskId: UUID
    @Environment(\.themeColors) var colors: ThemeColors

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                Text("Add")
                    .font(.system(size: 11))
            }
            .foregroundColor(colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(colors.bgSecondary)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(colors.inputBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SessionItemView: View {
    let session: Session
    let taskId: UUID
    @Environment(\.themeColors) var colors: ThemeColors

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundColor(colors.textPrimary)
                Text(session.relativeTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(colors.textMuted)
            }

            Spacer()

            // Branch badge
            HStack(spacing: 4) {
                Image(systemName: "arrow.branch")
                    .font(.system(size: 10))
                Text(session.isWorkTree ? session.branch : "main")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(colors.worktree)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(colors.worktree.opacity(0.15))
            .cornerRadius(4)

            // Remove button
            Button(action: {}) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(colors.textMuted)
            }
            .buttonStyle(.plain)
            .opacity(0)
        }
        .padding(8)
        .background(colors.bgSecondary)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(colors.borderSubtle, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return colors.success
        case .idle: return colors.textMuted
        case .needInput: return colors.warning
        }
    }
}
