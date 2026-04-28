import SwiftUI
import GhosttyKit

struct SidePanelView: View {
    @ObservedObject var viewModel: SidePanelViewModel
    @StateObject private var boardState = BoardState()
    @State private var showTaskModal = false

    private let narrowWidth: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            // Compact Toolbar
            HStack(spacing: 12) {
                Text("Kanban")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(themeColors.textSecondary)

                Spacer()

                Button(action: { showTaskModal = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                        Text("New Task")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeColors.btnGradientStart)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(themeColors.borderColor, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                ThemeToggleButton(boardState: boardState)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(themeColors.bgTertiary)
            .overlay(
                Rectangle()
                    .fill(themeColors.borderSubtle)
                    .frame(height: 1),
                alignment: .bottom
            )

            // Board
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
        }
        .environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showTaskModal) {
            TaskModalView(isPresented: $showTaskModal, boardState: boardState)
        }
    }

    private var themeColors: ThemeColors {
        ThemeColors.colors(isDark: boardState.isDarkMode)
    }
}