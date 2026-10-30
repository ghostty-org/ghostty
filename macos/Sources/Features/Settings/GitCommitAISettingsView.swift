import SwiftUI

struct GitCommitAISettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings

    var body: some View {
        OMGSettingsSection(GitL10n.text("AI Commit Messages")) {
            Text(GitL10n.text(
                "Try models from top to bottom. Drag rows to change priority. The first successful response is used."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if settings.gitCommitAIRoutes.isEmpty {
                Text(GitL10n.text("No models configured."))
                    .foregroundStyle(.secondary)
            }

            GitCommitAIRoutesTable(settings: settings)
                .frame(minHeight: settings.gitCommitAIRoutes.isEmpty ? 0 : 40,
                       idealHeight: min(CGFloat(settings.gitCommitAIRoutes.count) * 42, 210),
                       maxHeight: 210)

            HStack {
                NativeActionButton(
                    title: GitL10n.text("Add models…"),
                    symbol: "plus",
                    help: GitL10n.text("Add models…"),
                    style: .bordered,
                    height: 26,
                    identifier: "git.commit-ai.add-models"
                ) { button in
                    GitCommitAISettingsPanel.presentAddModels(settings: settings, from: button.window)
                }

                Spacer()

                NativeActionButton(
                    title: GitL10n.text("Commit style…"),
                    symbol: "slider.horizontal.3",
                    help: GitL10n.text("Commit style…"),
                    style: .bordered,
                    height: 26,
                    identifier: "git.commit-ai.edit-prompt"
                ) { button in
                    GitCommitAISettingsPanel.presentPrompt(settings: settings, from: button.window)
                }
            }
            .controlSize(.small)
        }
    }
}
