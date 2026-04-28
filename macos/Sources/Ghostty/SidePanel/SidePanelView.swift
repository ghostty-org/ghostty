import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()
    @State private var showTaskModal = false
    @State private var containerWidth: CGFloat = 0
    @State private var isNarrow: Bool = false

    private let narrowWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            KanbanWebView(
                boardState: boardState,
                showTaskModal: $showTaskModal,
                containerWidth: containerWidth,
                isNarrow: isNarrow
            )
            .onChange(of: geometry.size.width) { newWidth in
                containerWidth = newWidth
                isNarrow = newWidth < narrowWidth
            }
            .onAppear {
                containerWidth = geometry.size.width
                isNarrow = geometry.size.width < narrowWidth
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}