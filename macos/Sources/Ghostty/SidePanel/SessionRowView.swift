import SwiftUI
import GhosttyKit

struct SessionRowView: View {
    let session: Session
    let cardId: String
    @ObservedObject var viewModel: SidePanelViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)

                if let timestamp = session.timestamp {
                    Text(formatTimestamp(timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if session.isWorktree {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 9))
                    Text(session.branch ?? "main")
                        .font(.system(size: 10))
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.15))
                .cornerRadius(4)
            }

            Spacer()

            Button(action: {
                viewModel.deleteSession(cardId: cardId, sessionId: session.id)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(0)
            .padding(4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            activateSession()
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return .green
        case .idle: return .gray
        case .needInput: return .orange
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if hours < 24 { return "\(hours)h ago" }
        return "\(days)d ago"
    }

    private func activateSession() {
        viewModel.activate(session)
    }
}
