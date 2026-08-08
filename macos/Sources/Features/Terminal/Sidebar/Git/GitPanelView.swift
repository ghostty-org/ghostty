import AppKit
import Combine
import SwiftUI

/// The Git panel: the working state of the repository the selected
/// terminal is in.
struct GitPanelView: View {
    @ObservedObject var tabManager: SidebarTabManager

    /// Opens a terminal beside the selected one; every file opened here
    /// gets its own. See `FileOpener.openInTerminal`.
    var onSpawnTerminal: () -> Ghostty.SurfaceView? = { nil }

    @ObservedObject private var center: GitCenter = .shared
    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var refresh: GitPanelRefresh = .shared

    @State private var root: String?
    @State private var message = ""
    @State private var isAmending = false
    @State private var discarding: [GitFileChange] = []
    @State private var isCreatingBranch = false

    private var selectedTab: SidebarTabModel? {
        tabManager.models.first { $0.isSelected }
    }

    private var status: GitStatus? {
        root.flatMap { center.status(forRoot: $0) }
    }

    private var busy: String? {
        root.flatMap { center.isBusy($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if root == nil {
                empty
            } else {
                header
                commitBox
                changeList
            }
        }
        .onAppear { syncRoot() }
        // The repository changes from outside this panel constantly — the
        // terminal right next to it is where most of the committing still
        // happens. Nothing publishes that, so the panel polls while it's
        // the one on screen; `requestStatus` is a no-op until the TTL is up.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard let root else { return }
            center.requestStatus(root: root)
        }
        .onChange(of: tabManager.groupingVersion) { _ in syncRoot() }
        .onChange(of: refresh.token) { _ in
            guard let root else { return }
            center.requestStatus(root: root, force: true)
        }
        // Selection lives on the individual model, not on the published
        // array, so the array alone never announces it. The async hop is
        // required: objectWillChange fires *before* the value is written.
        .onReceive(
            Publishers.MergeMany(tabManager.models.map { $0.objectWillChange })
        ) { _ in
            DispatchQueue.main.async { syncRoot() }
        }
        .sheet(isPresented: $isCreatingBranch) {
            GitBranchCreator { name in
                guard let root else { return }
                center.createBranch(named: name, in: root)
            }
        }
        // A sheet rather than something inline: git's failures are
        // paragraphs, and rendering one inside a 240pt sidebar column
        // stretched the pane's intrinsic height until the window itself
        // was dragged into a tall thin sliver.
        .sheet(item: $center.lastError) { error in
            GitFailureSheet(operation: error.operation, failure: error.failure)
        }
        .alert(
            "Discard changes?",
            isPresented: Binding(
                get: { !discarding.isEmpty },
                set: { if !$0 { discarding = [] } }
            )
        ) {
            Button("Discard", role: .destructive) {
                guard let root else { return }
                center.discard(discarding, in: root)
                discarding = []
            }
            Button("Cancel", role: .cancel) { discarding = [] }
        } message: {
            Text(discardWarning)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            GitIcon(size: 11)

            Text(status?.branch ?? "—")
                .font(palette.font(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if let status, status.hasUpstream, status.ahead + status.behind > 0 {
                syncCounts(status)
            }

            Spacer(minLength: 0)

            // Operations are silent by design, so this is the only sign
            // one is running — and some of them (a pre-commit hook, a
            // push) take long enough that without it the panel looks
            // stuck rather than busy.
            if let busy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text(busy)
                        .font(palette.font(size: 10))
                        .lineLimit(1)
                }
                .transition(.opacity)
            }

            SidebarIconMenu(help: "Git Actions") {
                menuContents
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: busy)
    }

    /// Commits to pull / to push, in the same capsule the group headers
    /// use for their terminal count — both are "how many of these are
    /// there", so they read as one idea rather than two conventions.
    private func syncCounts(_ status: GitStatus) -> some View {
        HStack(spacing: 4) {
            if status.behind > 0 {
                syncBadge(count: status.behind, symbol: "arrow.down", help: "Commits to pull")
            }
            if status.ahead > 0 {
                syncBadge(count: status.ahead, symbol: "arrow.up", help: "Commits to push")
            }
        }
    }

    private func syncBadge(count: Int, symbol: String, help: String) -> some View {
        SidebarCountBadge(count: count, symbol: symbol).help(help)
    }

    @ViewBuilder
    private var menuContents: some View {
        if let root, let status {
            if status.hasUpstream {
                Button("Push") { center.push(in: root) }
                Button("Pull") { center.pull(in: root) }
            } else if let branch = status.branch, !status.isDetached {
                Button("Publish Branch") { center.publish(branch: branch, in: root) }
            }
            Button("Fetch") { center.fetch(in: root) }

            Divider()

            Menu("Switch Branch") {
                ForEach(center.branches[root] ?? [], id: \.self) { branch in
                    Button {
                        center.checkout(branch: branch, in: root)
                    } label: {
                        if branch == status.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
            Button("Create Branch…") { isCreatingBranch = true }

            Divider()

            Button("Stash Changes") { center.stashPush(message: nil, in: root) }
                .disabled(status.isClean)
            Button("Pop Stash") { center.stashPop(in: root) }
                .disabled((center.stashes[root] ?? []).isEmpty)

            Divider()

            Toggle("Amend Last Commit", isOn: $isAmending)
            Button("Refresh") { center.requestStatus(root: root, force: true) }
        }
    }

    // MARK: Commit

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(
                "",
                text: $message,
                prompt: Text(isAmending ? "Amend message" : "Message"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(palette.font(size: 11))
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )

            Button {
                commit()
            } label: {
                Text(commitTitle)
                    .font(palette.font(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent ?? .accentColor)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var commitTitle: String {
        guard let status else { return "Commit" }
        if isAmending { return "Amend" }
        return status.staged.isEmpty ? "Commit All" : "Commit"
    }

    private var canCommit: Bool {
        guard busy == nil, let status else { return false }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isAmending || !status.isClean
    }

    /// With nothing staged, commit everything — the shortcut VS Code
    /// offers. The staging is handed to the same operation rather than
    /// fired separately, so it can't race the commit for the busy lock.
    private func commit() {
        guard let root, let status else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)

        center.commit(
            message: text,
            amend: isAmending,
            stageAll: !isAmending && status.staged.isEmpty,
            in: root
        )
        message = ""
        isAmending = false
    }

    // MARK: Changes

    @ViewBuilder
    private var changeList: some View {
        if let status {
            if status.isClean {
                cleanState
            } else {
                ScrollView {
                    // A gap, so two adjacent rows' hover backgrounds never
                    // touch and read as one block.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        section("Merge Changes", status.unmerged, staged: false, merge: true)
                        section("Staged Changes", status.staged, staged: true, merge: false)
                        section("Changes", status.unstaged, staged: false, merge: false)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        } else {
            Spacer()
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ changes: [GitFileChange],
        staged: Bool,
        merge: Bool
    ) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 4) {
                Text(title)
                    .font(palette.font(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                SidebarCountBadge(count: changes.count)

                Spacer(minLength: 0)

                if !merge, let root {
                    SidebarIconButton(help: staged ? "Unstage All" : "Stage All") {
                        if staged {
                            center.unstageAll(in: root)
                        } else {
                            center.stageAll(in: root)
                        }
                    } label: {
                        Image(systemName: staged ? "minus" : "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.top, 6)
            .padding(.bottom, 0)

            ForEach(changes.map { SectionRow(change: $0, section: title) }) { row in
                GitChangeRow(
                    change: row.change,
                    staged: staged,
                    onOpen: { open(row.change) },
                    onPrimary: { toggleStage(row.change, staged: staged) },
                    onDiscard: merge ? nil : { discarding = [row.change] }
                )
            }
        }
    }

    private var cleanState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No changes")
                .font(palette.captionFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            GitIcon(size: 22)
                .foregroundStyle(.tertiary)
            Text("This terminal isn't in a git repository")
                .font(palette.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var discardWarning: String {
        guard let first = discarding.first else { return "" }
        if discarding.count == 1 {
            return first.isUntrackedOnly
                ? "\(first.name) will be deleted. This can't be undone."
                : "Changes to \(first.name) will be lost. This can't be undone."
        }
        return "Changes to \(discarding.count) files will be lost. This can't be undone."
    }

    // MARK: Actions

    private func toggleStage(_ change: GitFileChange, staged: Bool) {
        guard let root else { return }
        if staged {
            center.unstage([change.path], in: root)
        } else {
            center.stage([change.path], in: root)
        }
    }

    /// Same choice the file explorer offers, since it's the same question:
    /// look at this in the terminal, or hand it to an app. Git reports
    /// paths relative to the repository, so they have to be rejoined with
    /// the root before anything can open them.
    private func open(_ change: GitFileChange) {
        guard let root else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        FileOpener.prompt(
            for: url,
            in: selectedTab?.window,
            spawnTerminal: onSpawnTerminal
        )
    }

    /// The panel follows the terminal's repository, not the workspace root:
    /// a workspace can hold several repos side by side, and git is always
    /// about exactly one of them.
    private func syncRoot() {
        let next = selectedTab?.repoRoot
        if next != root {
            root = next
            message = ""
            isAmending = false
        }
        guard let next else { return }
        center.requestStatus(root: next)
        center.requestBranches(root: next)
        center.requestStashes(root: next)
    }
}

/// A change plus which section is showing it.
///
/// The section has to be part of the row's identity. A path can legitimately
/// appear twice — a file staged and then edited again is in both Staged
/// Changes and Changes — so identifying rows by path alone puts duplicate
/// ids in one list. It also lets SwiftUI match a row against the
/// same-named row in the *other* section when a file moves between them,
/// which it does on every stage: the row kept the props it had before the
/// move, so a freshly staged file went on showing its untracked badge and
/// a "stage" button that no longer applied.
private struct SectionRow: Identifiable {
    let change: GitFileChange
    let section: String

    var id: String { "\(section)/\(change.path)" }
}

/// One changed path.
private struct GitChangeRow: View {
    let change: GitFileChange
    let staged: Bool
    let onOpen: () -> Void
    let onPrimary: () -> Void
    let onDiscard: (() -> Void)?

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        HStack(spacing: 5) {
            // The name is its own hit target rather than the whole row
            // being one: the row also carries the action buttons, and a
            // row-wide gesture would swallow their clicks and their
            // tooltips along with them.
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    FileIconView(icon: icons.icon(forFile: change.name), size: 13)

                    Text(change.name)
                        .font(palette.font(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .font(palette.font(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(change.path)

            if isHovered {
                if let onDiscard {
                    rowButton("arrow.uturn.backward", help: "Discard Changes", action: onDiscard)
                }
                rowButton(
                    staged ? "minus" : "plus",
                    help: staged ? "Unstage" : "Stage",
                    action: onPrimary
                )
            } else {
                // Same box as the buttons that replace it on hover. A
                // bare label is shorter than a 22pt button, so without
                // this the row grew the moment the pointer touched it and
                // the whole list twitched.
                Text(change.badge(staged: staged))
                    .font(palette.font(size: 11, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .frame(width: Self.actionSize, height: Self.actionHeight)
            }
        }
        .frame(height: Self.actionHeight)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? accent.opacity(0.12) : .clear)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
    }

    /// Matches `SidebarIconButton`'s hit area exactly, so swapping the
    /// badge for the buttons on hover changes nothing about the layout.
    private static let actionSize: CGFloat = 24
    private static let actionHeight: CGFloat = 22

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        SidebarIconButton(help: help, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var badgeColor: Color {
        switch change.badge(staged: staged) {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "U": return .purple
        default: return .secondary
        }
    }
}

/// Explains a failed git operation: what happened, what to do, and the
/// transcript underneath for when that isn't enough.
private struct GitFailureSheet: View {
    let operation: String
    let failure: GitFailure

    @Environment(\.dismiss) private var dismiss
    @State private var showsTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.title)
                        .font(.headline)

                    if let summary = failure.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if !failure.files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(failure.files, id: \.self) { file in
                        Label(file, systemImage: "doc")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // A git that failed without printing anything is rare but real
            // (killed, or exited on a signal). Offering to expand and copy
            // an empty transcript would be a dead end.
            if !failure.raw.isEmpty {
                DisclosureGroup(isExpanded: $showsTranscript) {
                    ScrollView {
                        Text(failure.raw)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    // Bounded on purpose — this is exactly the content that
                    // has no natural size limit.
                    .frame(maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    )
                } label: {
                    Text("Git output")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            Spacer(minLength: 12)

            Divider()

            HStack {
                if !failure.raw.isEmpty {
                    Button("Copy Output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(failure.raw, forType: .string)
                    }
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460)
        .frame(minHeight: 220, maxHeight: 520)
    }
}

/// Names a new branch. Same skeleton as the sidebar's other editors.
private struct GitBranchCreator: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $name, prompt: Text("feat/my-change"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text("Branches off whatever is currently checked out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 360, height: 200)
    }
}

/// Lets the titlebar's refresh button reach the panel, same shape as
/// `FileExplorerRefresh` and for the same ownership reason.
@MainActor
final class GitPanelRefresh: ObservableObject {
    static let shared = GitPanelRefresh()

    @Published private(set) var token = 0

    func request() {
        token &+= 1
    }
}
