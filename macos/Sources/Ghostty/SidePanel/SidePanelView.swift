import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()

    private let narrowWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < narrowWidth {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 16) {
                        ForEach(Status.allCases) { status in
                            ColumnView(
                                status: status,
                                tasks: boardState.tasks(for: status),
                                boardState: boardState
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 16) {
                        ForEach(Status.allCases) { status in
                            ColumnView(
                                status: status,
                                tasks: boardState.tasks(for: status),
                                boardState: boardState
                            )

                            if status != Status.allCases.last {
                                Divider()
                                    .frame(width: 6)
                                    .background(Color.clear)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
        .background(Color(nsColor: .windowBackgroundColor))
    }
}