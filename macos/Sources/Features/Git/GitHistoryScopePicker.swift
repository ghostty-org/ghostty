import AppKit
import SwiftUI

struct GitHistoryScopePicker: NSViewRepresentable {
    let title: String
    let branches: [GitBranchInfo]
    let enabled: Bool
    var isActive = true
    var isBusy = false
    var worktrees: [GitWorktreeInfo] = []
    var worktreesError: String?
    var state: GitCollectionState?
    var stateKey = "history-refs"
    var selectedID: String?
    var tags: [GitRefDecoration] = []
    var repository: GitRepositoryIdentity?
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors
    var nativeColors: GitCollectionColors { colors }

    final class Control: NSButton, NSPopoverDelegate {
        private let chevron = NSImageView()
        fileprivate var content: GitHistoryScopePicker?
        private(set) var popover: NSPopover?
        private var host: GitHistoryScopePopoverController?
        private weak var responderBeforePopover: NSResponder?
        override init(frame: NSRect) {
            super.init(frame: frame)
            cell = GitScopeButtonCell()
            font = .systemFont(ofSize: 11, weight: .medium)
            alignment = .left
            isBordered = false
            imagePosition = .imageLeft
            cell?.lineBreakMode = .byTruncatingMiddle
            chevron.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            addSubview(chevron)
            wantsLayer = true
            layer?.cornerRadius = 4
            target = self
            action = #selector(showPicker)
            setAccessibilityLabel(GitL10n.text("Choose history branch or worktree"))
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ content: GitHistoryScopePicker) {
            self.content = content
            isEnabled = content.enabled && !content.isBusy
            if !isEnabled { popover?.performClose(nil) }
            host?.updateContent(content)
            if title != content.title { title = content.title }
            toolTip = content.title
            contentTintColor = content.colors.text
            let selected = content.selectedID ?? "scope:allBranches"
            let symbol = selected.hasPrefix("refs/tags/") ? "tag" : selected.hasPrefix("refs/remotes/") ? "network"
                : selected.hasPrefix("worktree:") ? "folder" : selected == "scope:allBranches" ? "square.stack.3d.up" : "arrow.triangle.branch"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            chevron.contentTintColor = content.colors.secondary
            layer?.backgroundColor = (selected == "scope:allBranches" ? content.colors.hover : content.colors.accent.withAlphaComponent(0.09)).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = content.colors.separator.cgColor
            setAccessibilityValue(content.title)
        }
        private func browser(_ content: GitHistoryScopePicker) -> GitHistoryScopePopoverController {
            GitHistoryScopePopoverController(content: content) { [weak self] in
                self?.popover?.performClose(nil)
            }
        }
        @objc func showPicker() {
            guard isEnabled, window != nil, let snapshot = content else { return }
            if popover?.isShown == true { popover?.performClose(nil); return }
            responderBeforePopover = window?.firstResponder
            let host = browser(snapshot)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            host.bindTheme(to: window)
            popover.contentViewController = host
            popover.contentSize = host.preferredContentSize
            self.host = host
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
        }
        func popoverDidClose(_ notification: Notification) {
            host?.saveAnchor()
            if let window {
                if let view = responderBeforePopover as? NSView, view.window === window {
                    window.makeFirstResponder(view)
                } else if self.window != nil {
                    window.makeFirstResponder(self)
                }
            }
            responderBeforePopover = nil
            popover = nil
            host = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { popover?.performClose(nil) }
        }
        override func layout() {
            super.layout()
            chevron.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) {
        view.configure(self)
        view.isHidden = !isActive
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 28)
    }
}

struct GitHistoryBranchFavorites {
    struct Entry: Codable, Equatable {
        var target: String
        var identity: String
        var commonGitDir: String
        var refs: [String]
    }

    private struct Store: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    private let defaults: UserDefaults
    private let target: String
    private let identity: String
    private let commonGitDir: String
    private static let defaultsKey = "git.history.favoriteBranches.v2"
    /// Legacy dictionaries used NUL-separated composite keys, and the property
    /// list dropped those NULs on write. Reads still migrate the surviving
    /// concatenated key so existing favorites are not lost.
    private static let legacyDefaultsKey = "git.history.favoriteBranches"

    init(repository: GitRepositoryIdentity, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        switch repository.target {
        case .local:
            target = "local"
            identity = ""
        case .ssh(let connection):
            target = "ssh"
            identity = connection.identity
        }
        commonGitDir = repository.commonGitDirPath
    }

    var refs: Set<String> {
        var store = load()
        if let entry = store.entries.first(where: matches) {
            return Set(entry.refs)
        }
        guard let migrated = legacyRefs else { return [] }
        store.entries.append(.init(target: target, identity: identity,
                                   commonGitDir: commonGitDir, refs: migrated))
        save(store)
        return Set(migrated)
    }

    func toggle(_ ref: String) {
        guard ref == "HEAD" || ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") ||
                ref.hasPrefix("worktree:") else { return }
        var values = refs
        if !values.insert(ref).inserted { values.remove(ref) }
        var store = load()
        store.entries.removeAll(where: matches)
        if !values.isEmpty {
            store.entries.append(.init(target: target, identity: identity,
                                       commonGitDir: commonGitDir, refs: values.sorted()))
        }
        save(store)
    }

    /// Worktrees are favorited by their exact path so a favorite survives
    /// branch renames and detached HEAD states.
    static func worktreeID(path: String) -> String { "worktree:" + path }

    private func matches(_ entry: Entry) -> Bool {
        entry.target == target && entry.identity == identity &&
            entry.commonGitDir == commonGitDir
    }

    private func load() -> Store {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return Store()
        }
        return store
    }

    private func save(_ store: Store) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Reads the legacy `[repositoryKey: [String]]` dictionary. Its keys were
    /// written with NUL separators, which plist serialization strips.
    private var legacyRefs: [String]? {
        let repositories = defaults.dictionary(forKey: Self.legacyDefaultsKey) ?? [:]
        let components = target == "local" ? ["local", commonGitDir] : ["ssh", identity, commonGitDir]
        let stripped = components.joined()
        guard let values = repositories[stripped] as? [String], !values.isEmpty else { return nil }
        return values.sorted()
    }
}
