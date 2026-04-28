import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()
    @State private var showTaskModal = false

    var body: some View {
        KanbanWebView(boardState: boardState, showTaskModal: $showTaskModal)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}