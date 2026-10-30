import AppKit
import SwiftUI

/// Sidebar and picker share search, modes, grouping, rows and selection.
struct GitRefBrowser: View {
    let branches: [GitBranchInfo]
    var worktrees: [GitWorktreeInfo] = []
    var isBusy = false
    var branchesError: String?
    var worktreesError: String?
    var isPicker = false
    var externalQuery: String?
    var externalMode: GitCollectionMode?
    var showsToolbar = true
    var externalController: GitCollectionController?
    var externalCancel: (() -> Void)?
    var state: GitCollectionState?
    var stateKey = "refs"
    var selectedID: String?
    var decorations: [GitRefDecoration]?
    var tags: [GitRefDecoration] = []
    var pasteboard = NSPasteboard.general
    var close: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors
    @State private var query = ""
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @State private var copied: String?
    @State private var controller = GitCollectionController()
    @AppStorage("git.refs.viewMode") private var mode: GitCollectionMode = .tree
    var body: some View {
        VStack(spacing: 6) {
            if showsToolbar {
            HStack(spacing: 5) {
                GitCollectionToolbar(query: $query, mode: $mode, placeholder: decorations == nil ? GitL10n.text("Search branches…") : GitL10n.text("Search references…"), autofocus: isPicker || decorations != nil,
                                     showsMode: false, controller: controller, cancel: cancel)
                if !isPicker && decorations == nil {
                    NativeActionButton(
                        symbol: "plus",
                        help: GitL10n.text("New Worktree"),
                        enabled: !isBusy && worktreesError == nil,
                        height: 28,
                        identifier: "git.refbrowser.newWorktree",
                        action: { _ in perform(.createWorktree(nil)) }
                    )
                    .frame(width: 28)
                }
                GitCollectionModePicker(mode: $mode)
            }.padding(.horizontal, 10)
            }
            if isPicker {
                GitHistoryScopeSegments(selectedID: selectedID) { scope in
                    close()
                    perform(.selectHistoryScope(scope))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            GitCollectionView(source: decorations.map(GitCollectionSource.decorations) ?? .refs(branches: branches, worktrees: worktrees, scopes: false,
                                            branchesError: branchesError, worktreesError: worktreesError),
                mode: externalMode ?? mode, query: externalQuery ?? query, canWrite: !isBusy,
                interaction: decorations != nil ? .references : isPicker ? .picker : .branches, state: state, stateKey: stateKey,
                selectedID: selectedID, extraRefs: tags, pasteboard: pasteboard,
                referenceAction: { ref in copied = ref.name; InspectorCopyMenu.copy(ref.name, to: pasteboard) },
                controller: externalController ?? controller, cancel: cancel, perform: { action in
                    if isPicker { close() }
                    perform(action)
                })
            if let copied {
                HStack { Text(GitL10n.text("Copied")).font(.caption).foregroundStyle(.secondary); InspectorCopyText(text: copied) }
                    .padding(.horizontal, 10).frame(height: 20)
            }
        }.environment(\.locale, Locale(identifier: SettingsStrings(language: settings.language).languageCode))
    }
    private func cancel() {
        if let externalCancel { externalCancel() } else if isPicker || decorations != nil { close() } else { query = "" }
    }
}
