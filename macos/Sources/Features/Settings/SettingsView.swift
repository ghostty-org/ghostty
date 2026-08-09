import SwiftUI

/// Root of the settings window: section list on the left, the selected
/// section's form on the right. Appearance owns every style control;
/// the other sections hold behavior only.
struct SettingsRootView: View {
    let ghostty: Ghostty.App

    @ObservedObject private var store = GuiConfigStore.shared

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case appearance
        case sidebar
        case files
        case behaviors
        case agents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .sidebar: return "Sidebar"
            case .files: return "Files"
            case .behaviors: return "Behaviors"
            case .agents: return "Agents"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .sidebar: return "sidebar.left"
            case .files: return "doc.text"
            case .behaviors: return "slider.horizontal.3"
            case .agents: return "sparkles"
            }
        }
    }

    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView(ghostty: ghostty, store: store)
            case .appearance:
                AppearanceSettingsView(ghostty: ghostty, store: store)
            case .sidebar:
                SidebarSettingsView(ghostty: ghostty, store: store)
            case .files:
                FilesSettingsView()
            case .behaviors:
                BehaviorsSettingsView(ghostty: ghostty, store: store)
            case .agents:
                AgentsSettingsView()
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// General behavior: access to the raw configuration.
struct GeneralSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Phantom Settings File") {
                    Button("Open in Editor") {
                        NSWorkspace.shared.open(store.guiFileURL)
                    }
                }

                LabeledContent("Main Config File") {
                    Button("Open in Editor") {
                        ghostty.openConfig()
                    }
                }
            } footer: {
                Text("Everything changed in this window is stored in \(GuiConfigStore.fileName) (the Phantom settings file), which is included from your main config. Hand-written options in the main config stay untouched. Style options (fonts, colors, blur) live in Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

/// Sidebar behavior: visibility, ordering and which tab info shows.
struct SidebarSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var sidebarEnabled: Bool = false

    @AppStorage("SidebarShowFilesPane") private var showFilesPane = true
    @AppStorage("SidebarShowGitPane") private var showGitPane = true

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true
    @AppStorage("SidebarShowDevServer") private var showDevServer = true

    @AppStorage("SidebarGroupShowPullRequests") private var groupShowPullRequests = true
    @AppStorage("SidebarGroupShowClaude") private var groupShowClaude = true
    @AppStorage("SidebarGroupShowNewTerminal") private var groupShowNewTerminal = true
    @AppStorage("SidebarGroupShowCount") private var groupShowCount = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Sidebar", isOn: $sidebarEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: sidebarEnabled) { value in
                        store.set("sidebar", value ? "true" : "false")
                        store.apply(ghostty: ghostty)
                    }

            } footer: {
                Text("The sidebar toggle applies to new windows. Sidebar style (background, width, tab item look) lives in Appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("File Explorer", isOn: $showFilesPane)
                    .toggleStyle(.switch)
                Toggle("Git", isOn: $showGitPane)
                    .toggleStyle(.switch)
            } header: {
                Text("Panels")
            } footer: {
                Text("Terminals is always available. With everything else off there is nothing to switch between, so the tabs disappear and the sidebar is just the terminal list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tab Info") {
                Toggle("Show Working Directory", isOn: $showDirectory)
                    .toggleStyle(.switch)
                Toggle("Show Git Branch", isOn: $showGitBranch)
                    .toggleStyle(.switch)
                Toggle("Show Uncommitted Changes", isOn: $showGitStatus)
                    .toggleStyle(.switch)
                Toggle("Show Open Pull Request", isOn: $showPullRequest)
                    .toggleStyle(.switch)
                Toggle("Show Dev Server Port", isOn: $showDevServer)
                    .toggleStyle(.switch)
            }

            Section {
                Toggle("Show Pull Requests", isOn: $groupShowPullRequests)
                    .toggleStyle(.switch)
                Toggle("Show New Claude Session", isOn: $groupShowClaude)
                    .toggleStyle(.switch)
                Toggle("Show New Terminal", isOn: $groupShowNewTerminal)
                    .toggleStyle(.switch)
                Toggle("Show Terminal Count", isOn: $groupShowCount)
                    .toggleStyle(.switch)
            } header: {
                Text("Group")
            } footer: {
                Text("The action icons appear in a group's header on hover. The group's icon, name and color are set per group, from its context menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Sidebar")
        .onAppear {
            sidebarEnabled = store.bool("sidebar")
        }
    }
}

/// Behavioral options grouped by area — nothing here changes looks.
struct BehaviorsSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @AppStorage("SidebarRestoreAgentSessions") private var restoreAgentSessions = true
    @AppStorage("SidebarNewTabPosition") private var newTabPosition = "end"
    @AppStorage("AgentNotificationsEnabled") private var agentNotifications = true
    @AppStorage(FileOpenTarget.defaultsKey)
    private var fileOpenTarget = FileOpenTarget.alwaysNewTerminal.rawValue

    @State private var restoreWindows = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Restore Windows on Launch", isOn: $restoreWindows)
                    .toggleStyle(.switch)
                    .onChange(of: restoreWindows) { value in
                        store.set("window-save-state", value ? "always" : "default")
                        store.apply(ghostty: ghostty)
                    }
            }

            Section {
                Toggle("Resume Agent Sessions on Restore", isOn: $restoreAgentSessions)
                    .toggleStyle(.switch)

                Toggle("Notify on Agent Activity", isOn: $agentNotifications)
                    .toggleStyle(.switch)
            } header: {
                Text("Terminal")
            } footer: {
                Text("When windows are restored, tabs that were running a Claude Code session run `claude --continue` to pick the conversation back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Picker("New Terminal Position", selection: $newTabPosition) {
                    Text("Bottom of List").tag("end")
                    Text("Top of List").tag("start")
                }
            }

            Section {
                Picker("Opening a File", selection: $fileOpenTarget) {
                    ForEach(FileOpenTarget.allCases) { target in
                        Text(target.title).tag(target.rawValue)
                    }
                }
            } header: {
                Text("Panels")
            } footer: {
                Text("Reuse only applies to a terminal sitting at a prompt. One that's still running something — an editor from the last file, a dev server — always gets a new terminal instead, so a command can never land inside whatever is already open there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Behaviors")
        .onAppear {
            restoreWindows = (store.string("window-save-state") ?? "always") == "always"
        }
    }
}

/// Integration with AI coding agents: installs the terminal-side hooks
/// that surface agent activity in the sidebar. Claude Code today; more
/// agents later.
struct AgentsSettingsView: View {
    @State private var installed = ClaudeHooksInstaller.isInstalled
    @State private var feedback: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(installed ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(installed ? "Hooks installed" : "Not installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if installed {
                            Button("Uninstall") {
                                let ok = ClaudeHooksInstaller.uninstall()
                                installed = ClaudeHooksInstaller.isInstalled
                                feedback = ok && !installed
                                    ? "Hooks removed"
                                    : "Removal failed: \(ClaudeHooksInstaller.lastError ?? "check ~/.claude/settings.json")"
                            }
                        } else {
                            Button("Install") {
                                let ok = ClaudeHooksInstaller.install()
                                installed = ClaudeHooksInstaller.isInstalled
                                feedback = ok && installed
                                    ? "Hooks installed \u{2713}"
                                    : "Install failed: \(ClaudeHooksInstaller.lastError ?? "status did not update")"
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        ClaudeIcon(size: 14, tint: .original)
                        Text("Claude Code")
                    }
                }

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.contains("failed") ? .red : .secondary)
                }
            } header: {
                Text("Hooks")
            } footer: {
                Text("Installs a hook script in ~/.claude/hooks and registers it in ~/.claude/settings.json (existing hooks are preserved). With the hooks in place, tabs running Claude Code show a spinner while it works, a bubble while it waits for input, and an attention dot when a response is ready — and sessions resume on window restore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .onAppear {
            ClaudeHooksInstaller.logStatus()
            installed = ClaudeHooksInstaller.isInstalled
        }
        // Claude Code owns this settings file too and rewrites it when its
        // own settings change, which can drop our registrations. Recheck on
        // every activation so the buttons never describe a stale state.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            installed = ClaudeHooksInstaller.isInstalled
        }
    }
}
