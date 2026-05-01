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
                // Tab Bar
                TabBarView(tabManager: tabManager, sessionManager: sessionManager)
                    .environmentObject(boardState)

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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
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
                }

                Button(action: {
                    if let app = ghostty.app {
                        tabManager.newTab(app: app, workspacePath: boardState.workspacePath)
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("New Tab")
            }
            .padding(.horizontal, 4)
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
            Button(action: onSelect) {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

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
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .background(TabMiddleClickView(onClose: onClose))
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


// MARK: - Middle-click Close on Tab

struct TabMiddleClickView: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MiddleClickMonitor()
        v.onMiddleClick = onClose
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MiddleClickMonitor)?.onMiddleClick = onClose
    }
}

class MiddleClickMonitor: NSView {
    var onMiddleClick: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard let self, event.buttonNumber == 2 else { return event }
            let loc = convert(event.locationInWindow, from: nil)
            if bounds.contains(loc) {
                onMiddleClick?()
                return nil
            }
            return event
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
