import SwiftUI
import Ghostty

struct SidePanelView: View {
    @StateObject var viewModel = SidePanelViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ProjectTabBar(viewModel: viewModel)

            Divider()

            kanbanBoard
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var kanbanBoard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(CardStatus.allCases, id: \.self) { status in
                    KanbanColumn(
                        status: status,
                        cards: viewModel.currentProject?.cards.filter { $0.status == status } ?? [],
                        viewModel: viewModel
                    )
                }
            }
            .padding(16)
        }
    }
}
