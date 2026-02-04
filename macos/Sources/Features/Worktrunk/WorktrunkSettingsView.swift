import SwiftUI

struct WorktrunkSettingsView: View {
    @AppStorage(WorktrunkPreferences.worktreeTabsKey) private var worktreeTabsEnabled: Bool = false
    @AppStorage(WorktrunkPreferences.openBehaviorKey) private var openBehaviorRaw: String = WorktrunkOpenBehavior.newTab.rawValue
    @AppStorage(WorktrunkPreferences.defaultAgentKey) private var defaultAgentRaw: String = WorktrunkAgent.claude.rawValue
    @AppStorage(WorktrunkPreferences.githubIntegrationKey) private var githubIntegrationEnabled: Bool = true

    @State private var ghAvailable: Bool = false

    private var openBehavior: WorktrunkOpenBehavior {
        WorktrunkOpenBehavior(rawValue: openBehaviorRaw) ?? .newTab
    }

    private var availableAgents: [WorktrunkAgent] {
        WorktrunkAgent.availableAgents()
    }

    private var defaultAgentSelection: Binding<WorktrunkAgent> {
        Binding(
            get: {
                WorktrunkAgent.preferredAgent(from: defaultAgentRaw, availableAgents: availableAgents) ?? .claude
            },
            set: { defaultAgentRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Tabs") {
                Toggle("Worktree tabs", isOn: $worktreeTabsEnabled)
                Text("When enabled: opening a worktree or AI session creates a split in a dedicated tab for that worktree, and the tab title stays pinned to the worktree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Agent") {
                if availableAgents.isEmpty {
                    Text("Install Claude Code, Codex, or OpenCode to enable agent sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("New session", selection: defaultAgentSelection) {
                        ForEach(availableAgents) { agent in
                            Text(agent.title).tag(agent)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Section("New Session Placement") {
                Picker("Open in", selection: $openBehaviorRaw) {
                    ForEach(WorktrunkOpenBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if worktreeTabsEnabled && openBehavior == .newTab {
                    Text("With Worktree tabs enabled, "New Tab" behaves like "Split Right".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("GitHub Integration") {
                Toggle("Show PR and CI status", isOn: $githubIntegrationEnabled)
                Text("Display CI check status for branches with open pull requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if githubIntegrationEnabled && !ghAvailable {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("GitHub CLI (gh) not found. Install with: brew install gh")
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Worktrunk")
        .onAppear {
            normalizeDefaultAgentIfNeeded()
            checkGHAvailability()
        }
    }

    private func checkGHAvailability() {
        Task {
            ghAvailable = await GHClient.isAvailable()
        }
    }

    private func normalizeDefaultAgentIfNeeded() {
        guard let preferred = WorktrunkAgent.preferredAgent(from: defaultAgentRaw, availableAgents: availableAgents) else {
            return
        }
        if preferred.rawValue != defaultAgentRaw {
            defaultAgentRaw = preferred.rawValue
        }
    }
}
