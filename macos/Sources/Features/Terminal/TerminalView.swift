import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform a binding action on the specified surface.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    func sendQuickCommand(_ command: QuickCommand, customText: String?, execute: Bool, broadcast: Bool)
    func toggleQuickCommands(_ sender: Any?)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    var quickCommandsIsShowing: Bool { get set }
    var quickCommandsWidth: CGFloat { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?
    @StateObject private var topBarProcessMonitor = TerminalProcessMonitor()

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    private var activeSurface: Ghostty.SurfaceView? {
        lastFocusedSurface?.value.flatMap {
            viewModel.surfaceTree.contains($0) ? $0 : nil
        }
    }

    private var formattedPwd: String {
        let raw = surfacePwd ?? topBarProcessMonitor.currentWorkingDir ?? ""
        guard !raw.isEmpty else { return "~" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if raw == home {
            return "~"
        } else if raw.hasPrefix(home + "/") {
            return "~/" + raw.dropFirst(home.count + 1)
        }
        return raw
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                        DebugBuildWarningView()
                    }

                    // Enhanced Balanced Terminal Top Bar
                    if ghostty.config.macosTopbar {
                        HStack(spacing: 8) {
                            // --- LEFT SECTION: Context & Quick Actions ---
                            HStack(spacing: 6) {
                                // Current Working Directory Badge (Click to copy path)
                                Button {
                                    let raw = surfacePwd ?? topBarProcessMonitor.currentWorkingDir ?? FileManager.default.homeDirectoryForCurrentUser.path
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(raw, forType: .string)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.accentColor)
                                        Text(formattedPwd)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .help("Current directory (Click to copy): \(surfacePwd ?? topBarProcessMonitor.currentWorkingDir ?? "~")")

                                // New Tab Quick Action
                                if let surface = activeSurface {
                                    Button {
                                        delegate?.performAction("new_tab", on: surface)
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("New Tab (Cmd+T)")
                                }

                                // Command Palette Quick Search
                                if ghostty.config.macosTopbarPalette {
                                    Button {
                                        viewModel.commandPaletteIsShowing = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 10))
                                            Text("Palette")
                                                .font(.system(size: 10, weight: .medium))
                                            Text("⌘⇧P")
                                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                                .foregroundStyle(Color.secondary.opacity(0.8))
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(6)
                                        .foregroundStyle(Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Command Palette (Cmd+Shift+P)")
                                }

                                // Clear Screen Action
                                if let surface = activeSurface {
                                    Button {
                                        delegate?.performAction("clear_screen", on: surface)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Clear Screen (Cmd+K)")
                                }
                            }

                            Spacer()

                            // --- CENTER SECTION: Live Process & Job Activity ---
                            HStack(spacing: 6) {
                                // Active Foreground Process with AI & SSH Detection
                                if let fg = topBarProcessMonitor.foregroundJob {
                                    if fg.isSSH {
                                        // SSH Session Badge (with Production Warning Guardrail)
                                        HStack(spacing: 4) {
                                            Image(systemName: fg.isProduction ? "exclamationmark.triangle.fill" : "network")
                                                .font(.system(size: 8))
                                                .foregroundStyle(fg.isProduction ? Color.white : Color.blue)
                                            Text(fg.isProduction ? "PROD: \(fg.sshTarget ?? "ssh")" : "ssh: \(fg.sshTarget ?? "remote")")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundStyle(fg.isProduction ? Color.white : Color.primary)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(fg.isProduction ? Color.red : Color.blue.opacity(0.18))
                                        .cornerRadius(5)
                                        .help(fg.isProduction ? "⚠️ PRODUCTION SERVER: \(fg.commandLine ?? "ssh")" : "Remote SSH: \(fg.commandLine ?? "ssh")")
                                    } else if fg.isAIAgent {
                                        // AI Agent Active Badge (agy, claude, codex)
                                        HStack(spacing: 5) {
                                            Image(systemName: fg.isThinking ? "sparkles" : "sparkle")
                                                .font(.system(size: 8))
                                                .foregroundStyle(fg.isThinking ? Color.purple : Color.secondary)
                                            Text("🤖 \(fg.aiAgentName)")
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color.primary)
                                            BrailleProgressBarView(
                                                style: .bar,
                                                color: fg.isThinking ? Color.purple : Color.secondary,
                                                isAnimating: fg.isThinking
                                            )
                                            Text(fg.isThinking ? "thinking" : "idle")
                                                .font(.system(size: 9, weight: fg.isThinking ? .bold : .medium))
                                                .foregroundStyle(fg.isThinking ? Color.purple.opacity(0.85) : Color.secondary)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(fg.isThinking ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.12))
                                        .cornerRadius(5)
                                        .help("AI Agent \(fg.aiAgentName): \(fg.isThinking ? "thinking / executing" : "idle (waiting for user input)") - PID \(fg.pid)")
                                    } else {
                                        // Standard foreground process
                                        HStack(spacing: 5) {
                                            Image(systemName: "terminal.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(Color.accentColor)
                                            Text(fg.name)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color.primary)
                                            BrailleProgressBarView(style: .spinner, color: Color.accentColor)
                                            if fg.state == .waiting {
                                                Text("waiting")
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(5)
                                        .help("Running in foreground: \(fg.name) (\(fg.state.rawValue)) - PID \(fg.pid)")
                                    }
                                }

                                // Background AI Agent Badge (when agent is working in background)
                                if let bgAgent = topBarProcessMonitor.backgroundAIAgent, topBarProcessMonitor.foregroundJob?.isAIAgent != true {
                                    HStack(spacing: 5) {
                                        Image(systemName: bgAgent.isThinking ? "sparkles" : "sparkle")
                                            .font(.system(size: 8))
                                            .foregroundStyle(bgAgent.isThinking ? Color.purple : Color.secondary)
                                        Text("🤖 \(bgAgent.aiAgentName)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.primary)
                                        BrailleProgressBarView(
                                            style: .bar,
                                            color: bgAgent.isThinking ? Color.purple : Color.secondary,
                                            isAnimating: bgAgent.isThinking
                                        )
                                        Text(bgAgent.isThinking ? "thinking (bg)" : "idle (bg)")
                                            .font(.system(size: 9, weight: bgAgent.isThinking ? .bold : .medium))
                                            .foregroundStyle(bgAgent.isThinking ? Color.purple.opacity(0.85) : Color.secondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(bgAgent.isThinking ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.12))
                                    .cornerRadius(5)
                                    .help("AI Agent in background: \(bgAgent.aiAgentName) (\(bgAgent.isThinking ? "thinking" : "idle")) - PID \(bgAgent.pid)")
                                }

                                // Background Jobs Indicator (Always visible!)
                                BackgroundJobsTopBarIndicator(monitor: topBarProcessMonitor)

                                // Split Counter
                                if viewModel.surfaceTree.count > 1 {
                                    HStack(spacing: 3) {
                                        Image(systemName: "rectangle.split.2x2")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.secondary)
                                        Text("\(viewModel.surfaceTree.count) splits")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.secondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(5)
                                }
                            }

                            Spacer()

                            // --- RIGHT SECTION: Split Controls & Quick Commands Toggle ---
                            HStack(spacing: 5) {
                                if let surface = activeSurface {
                                    Button {
                                        delegate?.performAction("new_split:right", on: surface)
                                    } label: {
                                        Image(systemName: "rectangle.split.2x1")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Split Terminal Right")

                                    Button {
                                        delegate?.performAction("new_split:down", on: surface)
                                    } label: {
                                        Image(systemName: "rectangle.split.1x2")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Split Terminal Down")
                                }

                                Divider()
                                    .frame(height: 14)
                                    .padding(.horizontal, 2)

                                // Sidebar Toggle Button
                                Button {
                                    delegate?.toggleQuickCommands(nil)
                                } label: {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 12, weight: viewModel.quickCommandsIsShowing ? .semibold : .regular))
                                        .foregroundStyle(viewModel.quickCommandsIsShowing ? Color.accentColor : Color.secondary)
                                        .frame(width: 24, height: 22)
                                        .background(viewModel.quickCommandsIsShowing ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                                .help(viewModel.quickCommandsIsShowing ? "Hide Quick Commands (Cmd+Shift+B)" : "Show Quick Commands (Cmd+Shift+B)")
                                .accessibilityLabel("Toggle Quick Commands")
                                .accessibilityValue(viewModel.quickCommandsIsShowing ? "Shown" : "Hidden")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }

                    QuickCommandsLayout(
                        isShowing: $viewModel.quickCommandsIsShowing,
                        width: $viewModel.quickCommandsWidth
                    ) {
                        TerminalSplitTreeView(
                            tree: viewModel.surfaceTree,
                            action: { delegate?.performSplitAction($0) })
                            .environmentObject(ghostty)
                            .ghosttyLastFocusedSurface(lastFocusedSurface)
                            .focused($focused)
                            .onAppear { self.focused = true }
                            .onChange(of: focusedSurface) { newValue in
                                // We want to keep track of our last focused surface so even if
                                // we lose focus we keep this set to the last non-nil value.
                                if newValue != nil {
                                    lastFocusedSurface = .init(newValue)
                                    self.delegate?.focusedSurfaceDidChange(to: newValue)
                                }
                            }
                            .onChange(of: pwdURL) { newValue in
                                self.delegate?.pwdDidChange(to: newValue)
                            }
                            .onChange(of: cellSize) { newValue in
                                guard let size = newValue else { return }
                                self.delegate?.cellSizeDidChange(to: size)
                            }
                            .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                                   idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                    } sidebar: {
                        QuickCommandsView(
                            configuredCommands: ghostty.config.quickCommands,
                            surface: lastFocusedSurface?.value.flatMap {
                                viewModel.surfaceTree.contains($0) ? $0 : nil
                            },
                            send: { command, customText, execute, broadcast in
                                delegate?.sendQuickCommand(command, customText: customText, execute: execute, broadcast: broadcast)
                            },
                            splitAndSend: { command, customText, execute in
                                guard let surface = activeSurface else { return }
                                delegate?.performAction("new_split:right", on: surface)
                                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
                                    delegate?.sendQuickCommand(command, customText: customText, execute: execute, broadcast: false)
                                }
                            }
                        )
                    }
                    .frame(idealWidth: lastFocusedSurface?.value?.initialSize?.width,
                           idealHeight: lastFocusedSurface?.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == .hidden ? .top : [])

                if let surfaceView = lastFocusedSurface?.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }

                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    UpdateOverlay()
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
            .onAppear {
                topBarProcessMonitor.setSurfaceView(activeSurface)
            }
            .onChange(of: activeSurface) { newSurface in
                topBarProcessMonitor.setSurfaceView(newSurface)
            }
        }
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}

private struct BackgroundJobsTopBarIndicator: View {
    @ObservedObject var monitor: TerminalProcessMonitor
    @State private var showPopover = false

    var body: some View {
        if !monitor.recentExits.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text("\(monitor.recentExits.joined(separator: ", ")) finished")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)
            .transition(.opacity)
        } else if !monitor.backgroundJobs.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    BrailleProgressBarView(style: .spinner, color: Color.orange)
                    Text("\(monitor.backgroundJobs.count) bg")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.18))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Background Jobs")
                            .font(.headline)
                        Spacer()
                        Text("\(monitor.backgroundJobs.count) active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    ForEach(monitor.backgroundJobs) { job in
                        HStack(spacing: 8) {
                            if job.isAIAgent {
                                Text("🤖")
                                    .font(.system(size: 11))
                                BrailleProgressBarView(
                                    style: .bar,
                                    color: job.isThinking ? Color.purple : Color.secondary,
                                    isAnimating: job.isThinking
                                )
                            } else if job.isSSH {
                                Image(systemName: "network")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.blue)
                                BrailleProgressBarView(style: .spinner, color: Color.blue)
                            } else {
                                BrailleProgressBarView(style: .spinner, color: Color.orange)
                            }
                            Text(job.isAIAgent ? "\(job.aiAgentName) (\(job.agentStatusText))" : job.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            if !job.isAIAgent && job.state == .waiting {
                                Text("(waiting)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            Text("PID \(job.pid)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Kill", role: .destructive) {
                                monitor.terminateJob(job)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .frame(minWidth: 240)
            }
            .help("Background jobs running in this terminal")
        }
    }
}
