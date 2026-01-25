import SwiftUI

struct TerminalWorkspaceView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var viewModel: ViewModel
    weak var delegate: (any TerminalViewDelegate)?

    @ObservedObject var worktrunkStore: WorktrunkStore
    @ObservedObject var worktrunkSidebarState: WorktrunkSidebarState
    let openWorktree: (String) -> Void
    let onSidebarWidthChange: (CGFloat) -> Void

    var body: some View {
        let columnVisibility = Binding(
            get: { worktrunkSidebarState.columnVisibility },
            set: { worktrunkSidebarState.columnVisibility = $0 }
        )
        NavigationSplitView(columnVisibility: columnVisibility) {
            WorktrunkSidebarView(store: worktrunkStore, openWorktree: openWorktree)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
                .background(SidebarWidthReader())
                .onPreferenceChange(SidebarWidthPreferenceKey.self) { newValue in
                    guard newValue > 0 else { return }
                    onSidebarWidthChange(newValue)
                }
        } detail: {
            TerminalView(
                ghostty: ghostty,
                viewModel: viewModel,
                delegate: delegate
            )
        }
    }
}

private struct SidebarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SidebarWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SidebarWidthPreferenceKey.self, value: proxy.size.width)
        }
    }
}
