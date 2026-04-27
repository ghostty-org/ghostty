import SwiftUI

struct KanbanBoardView: View {
    @ObservedObject var boardState: BoardState
    @Environment(\.themeColors) var colors: ThemeColors

    private let minColumnWidth: CGFloat = 240
    private let narrowWidth: CGFloat = 600

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < narrowWidth {
                // Narrow: Stack vertically with outer scroll
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
                // Wide: Show horizontally with scroll
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
    }
}