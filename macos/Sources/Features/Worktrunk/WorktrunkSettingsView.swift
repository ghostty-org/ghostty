import SwiftUI

struct WorktrunkSettingsView: View {
    @AppStorage(WorktrunkPreferences.worktreeTabsKey) private var worktreeTabsEnabled: Bool = false
    @AppStorage(WorktrunkPreferences.openBehaviorKey) private var openBehaviorRaw: String = WorktrunkOpenBehavior.newTab.rawValue

    private var openBehavior: WorktrunkOpenBehavior {
        WorktrunkOpenBehavior(rawValue: openBehaviorRaw) ?? .newTab
    }

    var body: some View {
        Form {
            Section("Tabs") {
                Toggle("Worktree tabs", isOn: $worktreeTabsEnabled)
                Text("When enabled: opening a worktree or AI session creates a split in a dedicated tab for that worktree, and the tab title stays pinned to the worktree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("New Session Placement") {
                Picker("Open in", selection: $openBehaviorRaw) {
                    ForEach(WorktrunkOpenBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if worktreeTabsEnabled && openBehavior == .newTab {
                    Text("With Worktree tabs enabled, “New Tab” behaves like “Split Right”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 460)
    }
}

