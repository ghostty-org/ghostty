import SwiftUI
import Ghostty

struct KanbanColumn: View {
    let status: CardStatus
    let cards: [Card]
    @ObservedObject var viewModel: SidePanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(status.title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(cards.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardView(card: card, viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .dropDestination(for: String.self) { cardIds, _ in
            for cardId in cardIds {
                viewModel.moveCard(id: cardId, to: status)
            }
            return true
        }
    }

    private var statusColor: Color {
        switch status {
        case .todo: return .blue
        case .inProgress: return .orange
        case .review: return .purple
        case .done: return .green
        }
    }
}
