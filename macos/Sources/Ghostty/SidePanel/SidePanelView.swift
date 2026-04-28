import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()
    @State private var showTaskModal = false

    private let narrowWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            KanbanWebView(
                boardState: boardState,
                showTaskModal: $showTaskModal,
                containerWidth: geometry.size.width,
                isNarrow: geometry.size.width < narrowWidth
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}