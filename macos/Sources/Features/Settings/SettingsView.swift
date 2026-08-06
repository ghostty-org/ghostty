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
        case behaviors
        case agents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .sidebar: return "Sidebar"
            case .behaviors: return "Behaviors"
            case .agents: return "Agents"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .sidebar: return "sidebar.left"
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

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true

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

            Section("Tab Info") {
                Toggle("Show Working Directory", isOn: $showDirectory)
                    .toggleStyle(.switch)
                Toggle("Show Git Branch", isOn: $showGitBranch)
                    .toggleStyle(.switch)
                Toggle("Show Uncommitted Changes", isOn: $showGitStatus)
                    .toggleStyle(.switch)
                Toggle("Show Open Pull Request", isOn: $showPullRequest)
                    .toggleStyle(.switch)
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
    @State private var lastActionFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(installed ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(installed ? "Hooks installed" : "Not installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button(installed ? "Reinstall Hooks" : "Install Hooks") {
                            lastActionFailed = !ClaudeHooksInstaller.install()
                            installed = ClaudeHooksInstaller.isInstalled
                        }

                        if installed {
                            Button("Remove") {
                                lastActionFailed = !ClaudeHooksInstaller.uninstall()
                                installed = ClaudeHooksInstaller.isInstalled
                            }
                        }
                    }
                }

                if lastActionFailed {
                    Text("Something went wrong updating ~/.claude/settings.json — check the file and try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Installs a hook script in ~/.claude/hooks and registers it in ~/.claude/settings.json (existing hooks are preserved). With the hooks in place, tabs running Claude Code show a spinner while it works, a bubble while it waits for input, and an attention dot when a response is ready — and sessions resume on window restore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .onAppear {
            installed = ClaudeHooksInstaller.isInstalled
        }
    }
}
