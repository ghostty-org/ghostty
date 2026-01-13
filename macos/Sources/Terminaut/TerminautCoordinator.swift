import AppKit
import SwiftUI
import GhosttyKit

/// Coordinates Terminaut state - launcher vs session, active project, etc.
/// No longer manages windows - that's handled by SwiftUI in TerminautRootView
class TerminautCoordinator: ObservableObject {
    static let shared = TerminautCoordinator()

    /// True when showing the launcher, false when in a session
    @Published var showLauncher: Bool = true

    /// The currently active project (when in session mode)
    @Published var activeProject: Project?

    /// Active sessions for tab management
    @Published var activeSessions: [Session] = []

    /// Currently selected session index (for tabs)
    @Published var selectedSessionIndex: Int = 0

    /// Reference to ghostty app for creating surfaces
    weak var ghosttyApp: Ghostty.App?

    /// Session struct that holds the project and its terminal surface
    struct Session: Identifiable {
        let id = UUID()
        let project: Project
        var surfaceView: Ghostty.SurfaceView?
        var hasActivity: Bool = false

        init(project: Project, surfaceView: Ghostty.SurfaceView? = nil) {
            self.project = project
            self.surfaceView = surfaceView
        }
    }

    private init() {
        setupMenuItems()
    }

    // MARK: - Navigation

    /// Launch a project - transitions from launcher to session
    func launchProject(_ project: Project) {
        // Mark project as opened
        ProjectStore.shared.markOpened(project)

        // Check if already have a session for this project
        if let existingIndex = activeSessions.firstIndex(where: { $0.project.id == project.id }) {
            // Switch to existing session
            selectedSessionIndex = existingIndex
            activeProject = project
        } else {
            // Create new session with SurfaceView
            var surfaceView: Ghostty.SurfaceView? = nil

            if let ghostty = ghosttyApp, let app = ghostty.app {
                var config = Ghostty.SurfaceConfiguration()
                config.workingDirectory = project.path
                config.command = "/bin/zsh -ic '/Users/pete/.local/bin/claude --continue'"
                config.waitAfterCommand = false  // Close immediately when process exits
                // Set PATH so claude doesn't complain about ~/.local/bin not being in PATH
                let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                config.environmentVariables["PATH"] = "\(homePath)/.local/bin:/opt/homebrew/bin:\(existingPath)"
                surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
            }

            let session = Session(project: project, surfaceView: surfaceView)
            activeSessions.append(session)
            selectedSessionIndex = activeSessions.count - 1
            activeProject = project
        }

        showLauncher = false
    }

    /// Return to launcher from session
    func returnToLauncher() {
        showLauncher = true
        // Keep activeProject and sessions so we can return
    }

    /// Close current session and return to launcher
    func closeCurrentSession() {
        closeSession(at: selectedSessionIndex)
    }

    /// Close session at specific index - always returns to launcher
    func closeSession(at index: Int) {
        guard index >= 0, index < activeSessions.count else {
            returnToLauncher()
            return
        }

        activeSessions.remove(at: index)

        // Always return to launcher when closing a session
        if activeSessions.isEmpty {
            activeProject = nil
        } else {
            // Adjust selection for when user returns from launcher
            if selectedSessionIndex >= activeSessions.count {
                selectedSessionIndex = activeSessions.count - 1
            } else if index < selectedSessionIndex {
                selectedSessionIndex -= 1
            }
            activeProject = activeSessions[selectedSessionIndex].project
        }
        showLauncher = true
    }

    /// Switch to a specific session tab
    func switchToSession(at index: Int) {
        guard index >= 0, index < activeSessions.count else { return }
        selectedSessionIndex = index
        activeProject = activeSessions[index].project
        showLauncher = false
    }

    /// Switch to next session tab
    func nextSession() {
        guard !activeSessions.isEmpty else { return }
        switchToSession(at: (selectedSessionIndex + 1) % activeSessions.count)
    }

    /// Switch to previous session tab
    func previousSession() {
        guard !activeSessions.isEmpty else { return }
        let newIndex = selectedSessionIndex - 1
        switchToSession(at: newIndex < 0 ? activeSessions.count - 1 : newIndex)
    }

    // MARK: - Menu Items

    private func setupMenuItems() {
        DispatchQueue.main.async {
            self.addTerminautMenu()
        }
    }

    private func addTerminautMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Check if we already added the menu
        if mainMenu.items.contains(where: { $0.title == "Terminaut" }) {
            return
        }

        let terminautMenu = NSMenu(title: "Terminaut")

        // Show Launcher - Cmd+L
        let launcherItem = NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncherAction),
            keyEquivalent: "l"
        )
        launcherItem.keyEquivalentModifierMask = .command
        launcherItem.target = self
        terminautMenu.addItem(launcherItem)

        // Close Session - Cmd+W (when in session)
        let closeItem = NSMenuItem(
            title: "Close Session",
            action: #selector(closeSessionAction),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        terminautMenu.addItem(closeItem)

        terminautMenu.addItem(NSMenuItem.separator())

        // Next Tab - Ctrl+Tab
        let nextTabItem = NSMenuItem(
            title: "Next Session",
            action: #selector(nextSessionAction),
            keyEquivalent: "\t"
        )
        nextTabItem.keyEquivalentModifierMask = .control
        nextTabItem.target = self
        terminautMenu.addItem(nextTabItem)

        // Previous Tab - Ctrl+Shift+Tab
        let prevTabItem = NSMenuItem(
            title: "Previous Session",
            action: #selector(previousSessionAction),
            keyEquivalent: "\t"
        )
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.target = self
        terminautMenu.addItem(prevTabItem)

        let terminautMenuItem = NSMenuItem(title: "Terminaut", action: nil, keyEquivalent: "")
        terminautMenuItem.submenu = terminautMenu

        // Insert after File menu
        if mainMenu.items.count > 1 {
            mainMenu.insertItem(terminautMenuItem, at: 2)
        } else {
            mainMenu.addItem(terminautMenuItem)
        }
    }

    @objc private func showLauncherAction() {
        returnToLauncher()
    }

    @objc private func closeSessionAction() {
        closeCurrentSession()
    }

    @objc private func nextSessionAction() {
        nextSession()
    }

    @objc private func previousSessionAction() {
        previousSession()
    }
}

// MARK: - Window Setup

extension TerminautCoordinator {
    /// Creates the single fullscreen window for Terminaut
    /// Call this from AppDelegate on launch
    func createMainWindow(ghostty: Ghostty.App) -> NSWindow {
        // Store reference for creating surfaces later
        self.ghosttyApp = ghostty

        let rootView = TerminautRootView(coordinator: self)
            .environmentObject(ghostty)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Terminaut"

        // Enter fullscreen
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        return window
    }
}
