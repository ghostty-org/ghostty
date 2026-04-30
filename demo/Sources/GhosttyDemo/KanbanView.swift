import SwiftUI
import GhosttyKit

// MARK: - KanbanView

struct KanbanView: View {
    @ObservedObject var boardState: BoardState
    @ObservedObject var sessionManager: SessionManager
    let tabManager: TerminalTabManager
    let ghosttyApp: ghostty_app_t

    @Environment(\.themeColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            KanbanToolbar(boardState: boardState)

            Divider()

            GeometryReader { geometry in
                let isHorizontal = geometry.size.width >= 360
                if isHorizontal {
                    horizontalLayout
                } else {
                    verticalLayout
                }
            }
        }
        .background(colors.bgPrimary)
    }

    // MARK: - Adaptive Layouts

    @ViewBuilder
    private var horizontalLayout: some View {
        HStack(spacing: 6) {
            ForEach(Status.allCases) { status in
                KanbanColumnView(
                    status: status,
                    tasks: boardState.tasks(for: status),
                    boardState: boardState,
                    sessionManager: sessionManager,
                    tabManager: tabManager,
                    ghosttyApp: ghosttyApp
                )
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var verticalLayout: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(Status.allCases) { status in
                    KanbanColumnView(
                        status: status,
                        tasks: boardState.tasks(for: status),
                        boardState: boardState,
                        sessionManager: sessionManager,
                        tabManager: tabManager,
                        ghosttyApp: ghosttyApp
                    )
                }
            }
            .padding(6)
        }
    }
}

// MARK: - KanbanToolbar

struct KanbanToolbar: View {
    @ObservedObject var boardState: BoardState
    @State private var showNewTaskModal = false

    var body: some View {
        HStack {
            Text("Kanban").font(.headline)
            Spacer()
            Button(action: { showNewTaskModal = true }) {
                Image(systemName: "plus")
            }
            Button(action: { boardState.toggleTheme() }) {
                Image(systemName: boardState.isDarkMode ? "sun.max" : "moon")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showNewTaskModal) {
            TaskEditModal(task: nil, boardState: boardState)
        }
    }
}
