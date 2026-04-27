import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()

    var body: some View {
        KanbanBoardView(boardState: boardState)
            .environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
            .frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}