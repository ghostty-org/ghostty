import SwiftUI

struct WorktrunkSettingsView: View {
    @AppStorage(WorktrunkPreferences.worktreeTabsKey) private var worktreeTabsEnabled: Bool = false
    @AppStorage(WorktrunkPreferences.sidebarTabsKey) private var sidebarTabsEnabled: Bool = false
    @AppStorage(WorktrunkPreferences.openBehaviorKey) private var openBehaviorRaw: String = WorktrunkOpenBehavior.newTab.rawValue
    @AppStorage(WorktrunkPreferences.defaultAgentKey) private var defaultActionRaw: String = WorktrunkDefaultAction.terminal.rawValue
    @AppStorage(WorktrunkPreferences.githubIntegrationKey) private var githubIntegrationEnabled: Bool = true

    @State private var ghAvailable: Bool = false

    private var openBehavior: WorktrunkOpenBehavior {
        WorktrunkOpenBehavior(rawValue: openBehaviorRaw) ?? .newTab
    }

    private var availableActions: [WorktrunkDefaultAction] {
        WorktrunkDefaultAction.availableActions()
    }

    private var defaultActionSelection: Binding<WorktrunkDefaultAction> {
        Binding(
            get: {
                WorktrunkDefaultAction.preferredAction(from: defaultActionRaw, availableActions: availableActions)
            },
            set: { defaultActionRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Tabs") {
                Toggle("Worktree tabs", isOn: $worktreeTabsEnabled)
                Text("When enabled: opening a worktree or AI session creates a split in a dedicated tab for that worktree, and the tab title stays pinned to the worktree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Sidebar tabs", isOn: $sidebarTabsEnabled)
                Text("When enabled: open tabs are shown at the top of the sidebar and the native tab bar is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Action") {
                Picker("New session", selection: defaultActionSelection) {
                    ForEach(availableActions) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("New Session Placement") {
                Picker("Open in", selection: $openBehaviorRaw) {
                    ForEach(WorktrunkOpenBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if worktreeTabsEnabled && openBehavior == .newTab {
                    Text("With Worktree tabs enabled, \"New Tab\" behaves like \"Split Right\".")
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
            normalizeDefaultActionIfNeeded()
            checkGHAvailability()
        }
    }

    private func checkGHAvailability() {
        Task {
            ghAvailable = await GHClient.isAvailable()
        }
    }

    private func normalizeDefaultActionIfNeeded() {
        let preferred = WorktrunkDefaultAction.preferredAction(from: defaultActionRaw, availableActions: availableActions)
        if preferred.rawValue != defaultActionRaw {
            defaultActionRaw = preferred.rawValue
        }
    }
}
