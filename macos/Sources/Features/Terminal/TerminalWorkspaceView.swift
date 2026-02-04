import AppKit
import SwiftUI

struct TerminalWorkspaceView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var viewModel: ViewModel
    weak var delegate: (any TerminalViewDelegate)?

    @ObservedObject var worktrunkStore: WorktrunkStore
    @ObservedObject var worktrunkSidebarState: WorktrunkSidebarState
    @ObservedObject var gitDiffSidebarState: GitDiffSidebarState
    let openWorktree: (String) -> Void
    let openWorktreeAgent: (String, WorktrunkAgent) -> Void
    let resumeSession: ((AISession) -> Void)?
    let onSidebarWidthChange: (CGFloat) -> Void
    let onGitDiffSelect: (GitDiffEntry, GitDiffScope) -> Void
    let onGitDiffWorktreeSelect: (String?) -> Void

    @StateObject private var statusRingTooltipState = StatusRingTooltipState()

    var body: some View {
        let columnVisibility = Binding(
            get: { worktrunkSidebarState.columnVisibility },
            set: { worktrunkSidebarState.columnVisibility = $0 }
        )
        NavigationSplitView(columnVisibility: columnVisibility) {
            WorktrunkSidebarView(
                store: worktrunkStore,
                sidebarState: worktrunkSidebarState,
                tooltipState: statusRingTooltipState,
                openWorktree: openWorktree,
                openWorktreeAgent: openWorktreeAgent,
                resumeSession: resumeSession,
                onSelectWorktree: { path in
                    onGitDiffWorktreeSelect(path)
                }
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
                .background(SidebarWidthReader())
                .onPreferenceChange(SidebarWidthPreferenceKey.self) { newValue in
                    if newValue > 0 {
                        onSidebarWidthChange(newValue)
                        return
                    }

                    if worktrunkSidebarState.columnVisibility == .detailOnly {
                        onSidebarWidthChange(0)
                    }
                }
        } detail: {
            if #available(macOS 26.0, *) {
                if gitDiffSidebarState.isVisible {
                    HStack(spacing: 0) {
                        mainDetailView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        GitDiffSidebarView(
                            state: gitDiffSidebarState,
                            onSelect: onGitDiffSelect
                        )
                        .frame(width: gitDiffSidebarState.panelWidth)
                        .overlay(
                            DiffSidebarResizeHandle(width: $gitDiffSidebarState.panelWidth),
                            alignment: .leading
                        )
                    }
                } else {
                    mainDetailView
                }
            } else {
                mainDetailView
            }
        }
        .animation(.easeOut(duration: 0.12), value: worktrunkSidebarState.columnVisibility)
        .overlay {
            StatusRingTooltipOverlay(state: statusRingTooltipState)
        }
    }

    @ViewBuilder
    private var mainDetailView: some View {
        ZStack {
            TerminalView(
                ghostty: ghostty,
                viewModel: viewModel,
                delegate: delegate
            )
            .opacity(gitDiffSidebarState.isDiffActive ? 0 : 1)
            .allowsHitTesting(!gitDiffSidebarState.isDiffActive)

            if gitDiffSidebarState.isDiffActive {
                GitDiffMainView(state: gitDiffSidebarState)
            }
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

private struct DiffSidebarResizeHandle: View {
    @Binding var width: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newWidth = width - value.translation.width
                        width = max(260, min(420, newWidth))
                    }
            )
    }
}
