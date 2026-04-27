import SwiftUI
import Ghostty

struct CardEditSheet: View {
    @Binding var card: Card
    @ObservedObject var viewModel: SidePanelViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var priority: Priority
    @State private var status: CardStatus
    @State private var showingAddSession = false

    init(card: Binding<Card>, viewModel: SidePanelViewModel) {
        self._card = card
        self.viewModel = viewModel
        self._title = State(initialValue: card.wrappedValue.title)
        self._description = State(initialValue: card.wrappedValue.description)
        self._priority = State(initialValue: card.wrappedValue.priority)
        self._status = State(initialValue: card.wrappedValue.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Card")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description)

                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { p in
                        Text(p.title).tag(p)
                    }
                }

                Picker("Status", selection: $status) {
                    ForEach(CardStatus.allCases, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sessions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showingAddSession = true }) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                }

                if card.sessions.isEmpty {
                    Text("No sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(card.sessions) { session in
                        SessionRowView(session: session, cardId: card.id, viewModel: viewModel)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Delete", role: .destructive) {
                    viewModel.deleteCard(id: card.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveCard()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 450)
        .sheet(isPresented: $showingAddSession) {
            AddSessionSheet(cardId: card.id, viewModel: viewModel)
        }
    }

    private func saveCard() {
        card.title = title
        card.description = description
        card.priority = priority
        card.status = status
        viewModel.updateCard(card)
    }
}
