import SwiftUI
import Ghostty

struct SessionRowView: View {
    let session: Session
    let cardId: String
    @ObservedObject var viewModel: SidePanelViewModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sessionColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }

            if session.isWorktree {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.branch")
                        .font(.system(size: 9))
                    Text(session.worktreeName ?? "worktree")
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

    private var sessionColor: Color {
        if session.splitId != nil {
            return .green
        }
        return .gray
    }

    private func activateSession() {
        // TODO: Terminal bridge - focus or create split
    }
}
