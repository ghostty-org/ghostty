import SwiftUI
import AppKit
import GhosttyRuntime

// MARK: - Main Layout

struct ContentView: View {
    @EnvironmentObject private var ghostty: GhosttyApp
    @StateObject private var tabManager = TerminalTabManager()
    @State private var commandText = ""

    var body: some View {
        HSplitView {
            LeftPanel(commandText: $commandText, tabManager: tabManager)
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
                .layoutPriority(0)

            // Right: tab bar + terminal
            VStack(spacing: 0) {
                // Tab Bar
                TabBarView(tabManager: tabManager)

                // Terminal area (stacked views, only active is visible)
                ZStack {
                    Color.black
                    ForEach(tabManager.tabs) { tab in
                        SurfaceViewWrapper(surfaceView: tab.surfaceView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .opacity(tab.id == tabManager.activeTabID ? 1 : 0)
                    }
                }

                // Bottom status bar
                HStack {
                    Circle()
                        .fill(tabManager.activeTab != nil ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(tabManager.activeTab?.title ?? "No terminal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.windowBackgroundColor))

                // Command bar
                HStack {
                    TextField("command", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { sendCommand() }

                    SmallButton("Send") { sendCommand() }
                }
                .padding(6)
                .background(Color(.windowBackgroundColor))
            }
            .frame(minWidth: 400, idealWidth: 600)
            .layoutPriority(1)
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            if tabManager.tabs.isEmpty, let app = ghostty.app {
                tabManager.newTab(app: app)
            }
        }
    }

    private func sendCommand() {
        guard !commandText.isEmpty, let tab = tabManager.activeTab else { return }
        tab.surfaceView.sendText(commandText + "\n")
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    @ObservedObject var tabManager: TerminalTabManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabManager.tabs) { tab in
                    TabButton(
                        title: tab.title,
                        isActive: tab.id == tabManager.activeTabID,
                        canClose: tabManager.tabs.count > 1,
                        onSelect: { tabManager.selectTab(id: tab.id) },
                        onClose: { tabManager.closeTab(id: tab.id) }
                    )
                }

                Button(action: {
                    // New tab button — needs the app handle from environment
                    // This is handled via the environmentObject in ContentView
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
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
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
        }
        .buttonStyle(.plain)
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

// MARK: - Left Panel

struct LeftPanel: View {
    @Binding var commandText: String
    @ObservedObject var tabManager: TerminalTabManager
    @EnvironmentObject private var ghostty: GhosttyApp

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(tabManager: tabManager)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    sectionHeader("Tab Management")
                    SmallButton("+ New Tab") {
                        if let app = ghostty.app {
                            tabManager.newTab(app: app)
                        }
                    }
                    SmallButton("Close Current Tab", color: .red) {
                        if let id = tabManager.activeTabID {
                            tabManager.closeTab(id: id)
                        }
                    }

                    sectionHeader("Switch Tab")
                    HStack(spacing: 4) {
                        ForEach(tabManager.tabs) { tab in
                            SmallButton(tab.title) { tabManager.selectTab(id: tab.id) }
                        }
                    }

                    sectionHeader("Send Command")
                    Picker("", selection: $commandText) {
                        Text("(type command)").tag("")
                        Text("echo hello").tag("echo hello")
                        Text("pwd").tag("pwd")
                        Text("ls -la").tag("ls -la")
                        Text("top").tag("top")
                        Text("claude --help").tag("claude --help")
                    }
                    .pickerStyle(.menu).labelsHidden()

                    TextField("command", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    HStack(spacing: 4) {
                        SmallButton("Send") {
                            guard !commandText.isEmpty else { return }
                            tabManager.activeTab?.surfaceView.sendText(commandText + "\n")
                        }
                    }

                    Divider()
                    sectionHeader("Terminal Control")
                    SmallButton("^C") { tabManager.activeTab?.surfaceView.sendText("\u{3}") }
                    SmallButton("^D") { tabManager.activeTab?.surfaceView.sendText("\u{4}") }
                    SmallButton("^Z") { tabManager.activeTab?.surfaceView.sendText("\u{1a}") }
                    SmallButton("clear") { tabManager.activeTab?.surfaceView.sendText("clear\n") }
                }
                .padding(12)
            }
        }
        .background(Color(.windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption).fontWeight(.semibold)
                .foregroundColor(.secondary).textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 6)
    }
}

struct HeaderView: View {
    @ObservedObject var tabManager: TerminalTabManager

    var body: some View {
        HStack {
            Circle()
                .fill(tabManager.activeTab != nil ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text("Ghostty Demo")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Sub-views

struct SmallButton: View {
    let title: String
    var color: Color = .accentColor
    let action: () -> Void

    init(_ title: String, color: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
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
