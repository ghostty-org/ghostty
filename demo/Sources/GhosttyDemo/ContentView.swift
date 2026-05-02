import SwiftUI
import AppKit
import GhosttyRuntime

// MARK: - Main Layout

struct ContentView: View {
    @EnvironmentObject private var ghostty: GhosttyApp
    @StateObject private var tabManager = TerminalTabManager()
    @StateObject private var boardState = BoardState.shared
    @StateObject private var sessionManager = SessionManager.shared

    // JsonlWatcher is kept alive by this @State reference
    @State private var jsonlWatcher: JsonlWatcher?

    var body: some View {
        HSplitView {
            KanbanView(
                boardState: boardState,
                sessionManager: sessionManager,
                tabManager: tabManager,
                ghosttyApp: ghostty.app!
            )
            .frame(minWidth: Status.columnMinWidth + Status.columnHPadding,
                   idealWidth: Status.columnMinWidth * 1.5 + Status.columnHPadding)
            .layoutPriority(0)

            // Right: tab bar + terminal
            VStack(spacing: 0) {
                // Tab Bar (hidden when only one tab)
                if tabManager.showTabBar {
                    TabBarView(tabManager: tabManager, sessionManager: sessionManager)
                        .environmentObject(boardState)
                }

                // Terminal area (only render active tab to save GPU)
                ZStack {
                    Color.black
                    if let activeTab = tabManager.activeTab {
                        SurfaceViewWrapper(surfaceView: activeTab.surfaceView)
                            .id(activeTab.id)  // Force recreation when tab changes
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minWidth: 400, idealWidth: 600)
            .layoutPriority(1)
        }
        .frame(minWidth: 900, minHeight: 500)
        .environment(\.themeColors, ThemeColors.colors(isDark: boardState.isDarkMode))
        .preferredColorScheme(boardState.isDarkMode ? .dark : .light)
        .onAppear {
            if let app = ghostty.app {
                if tabManager.tabs.isEmpty {
                    tabManager.newTab(app: app)
                }
                sessionManager.configure(tabManager: tabManager, app: app)
                boardState.configure(sessionManager: sessionManager)

                // If workspace is set, cd the initial terminal into it
                if let ws = boardState.workspacePath, let tab = tabManager.activeTab {
                    tab.surfaceView.sendText("cd \(ws)")
                    tab.surfaceView.sendEnter()
                }
            }

            // Start monitoring Claude JSONL session files under ~/.claude/projects
            let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects").path
            let watchPath = claudeProjects

            let sessionWatcher = JsonlWatcher(path: watchPath)
            sessionWatcher.start(
                onChange: { [sessionManager] parsedSessions in
                    for (_, parsed) in parsedSessions {
                        sessionManager.updateSession(from: parsed)
                    }
                },
                onNewSessionId: { [sessionManager] sessionId, parsedSession in
                    sessionManager.matchNewSessionId(sessionId, from: parsedSession)
                }
            )
            jsonlWatcher = sessionWatcher
        }
    }

}

// MARK: - Tab Bar

struct TabBarView: View {
    @EnvironmentObject private var ghostty: GhosttyApp
    @EnvironmentObject private var boardState: BoardState
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 0) {
            // Draggable tab list — expands to fill available width
            ForEach(tabManager.tabs) { tab in
                TabButton(
                    title: tab.title,
                    isActive: tab.id == tabManager.activeTabID,
                    canClose: tabManager.tabs.count > 1,
                    onSelect: { tabManager.selectTab(id: tab.id) },
                    onClose: {
                        tabManager.closeTab(id: tab.id)
                        sessionManager.unlinkTab(tabID: tab.id)
                    }
                )
                .frame(maxWidth: .infinity)
                .onDrag {
                    NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(
                    tab: tab,
                    tabManager: tabManager
                ))
            }

            // "+" button — always fixed at the far right
            Button(action: {
                if let app = ghostty.app {
                    tabManager.newTab(app: app, workspacePath: boardState.workspacePath)
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 20)
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
        .frame(height: 28)
        .background(Color(.controlBackgroundColor).opacity(0.8))
        .overlay(Divider(), alignment: .bottom)
    }
}

struct TabButton: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }
}

struct TabDropDelegate: DropDelegate {
    let tab: TerminalTabManager.Tab
    let tabManager: TerminalTabManager

    func performDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        guard let items = info.itemProviders(for: [.text]).first else { return }
        _ = items.loadObject(ofClass: NSString.self) { reading, _ in
            guard let uuidString = reading as? String,
                  let sourceID = UUID(uuidString: uuidString),
                  sourceID != tab.id else { return }
            DispatchQueue.main.async {
                guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == sourceID }),
                      let destIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                withAnimation {
                    tabManager.tabs.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destIndex > sourceIndex ? destIndex + 1 : destIndex)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Terminal View Wrapper (NSViewRepresentable)

struct SurfaceViewWrapper: NSViewRepresentable {
    let surfaceView: GhosttySurfaceView

    func makeNSView(context: Context) -> GhosttySurfaceView {
        surfaceView
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}
