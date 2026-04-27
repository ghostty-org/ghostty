import SwiftUI
import GhosttyKit

struct CardView: View {
    let card: Card
    @ObservedObject var viewModel: SidePanelViewModel

    @State private var isExpanded = false
    @State private var showingEditSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            priorityStrip

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    if !card.sessions.isEmpty {
                        Button(action: { withAnimation { isExpanded.toggle() } }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !card.description.isEmpty {
                    Text(card.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    priorityBadge

                    if !card.sessions.isEmpty {
                        sessionCountBadge
                    }
                }
            }
            .padding(12)

            if !card.sessions.isEmpty && isExpanded {
                Divider()
                sessionsList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { showingEditSheet = true }
        .contextMenu {
            Button("Edit") { showingEditSheet = true }
            Divider()
            Button("Move to Todo") { viewModel.moveCard(id: card.id, to: .todo) }
            Button("Move to In Progress") { viewModel.moveCard(id: card.id, to: .inProgress) }
            Button("Move to Review") { viewModel.moveCard(id: card.id, to: .review) }
            Button("Move to Done") { viewModel.moveCard(id: card.id, to: .done) }
            Divider()
            Button("Delete", role: .destructive) { viewModel.deleteCard(id: card.id) }
        }
        .sheet(isPresented: $showingEditSheet) {
            editSheet
        }
        .draggable(card.id) {
            Text(card.id)
                .padding(8)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(4)
        }
    }

    private var priorityStrip: some View {
        Rectangle()
            .fill(priorityColor)
            .frame(height: 4)
    }

    private var priorityBadge: some View {
        Text(card.priority.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(priorityColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(priorityColor.opacity(0.15))
            .cornerRadius(4)
    }

    private var sessionCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.split.bottomrightquarter")
                .font(.system(size: 10))
            Text("\(card.sessions.count)")
                .font(.system(size: 10))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(4)
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.sessions) { session in
                SessionRowView(session: session, cardId: card.id, viewModel: viewModel)
                if session.id != card.sessions.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var priorityColor: Color {
        switch card.priority {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .yellow
        case .p3: return .gray
        }
    }

    @ViewBuilder
    private var editSheet: some View {
        if let binding = makeCardBinding() {
            CardEditSheet(card: binding, viewModel: viewModel)
        }
    }

    private func makeCardBinding() -> Binding<Card>? {
        guard let project = viewModel.currentProject,
              let index = project.cards.firstIndex(where: { $0.id == card.id }) else {
            return nil
        }
        return Binding(
            get: { viewModel.projects[viewModel.currentProjectIndex].cards[index] },
            set: { viewModel.projects[viewModel.currentProjectIndex].cards[index] = $0 }
        )
    }
}
