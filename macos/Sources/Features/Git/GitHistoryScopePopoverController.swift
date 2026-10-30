import AppKit

@MainActor
final class GitHistoryScopePopoverController: NSViewController, NSSearchFieldDelegate {
    private let content: GitHistoryScopePicker
    private let closePopover: () -> Void
    private let searchField = NSSearchField()
    private let scopeControl = NSSegmentedControl()
    private let modeControl = NSSegmentedControl()
    private let collectionCoordinator = GitCollectionView.Coordinator()
    private let collectionController = GitCollectionController()
    private var query = ""
    private var mode = GitCollectionMode(rawValue: UserDefaults.standard.string(forKey: "git.refs.viewMode") ?? "") ?? .tree

    init(content: GitHistoryScopePicker, close: @escaping () -> Void) {
        self.content = content
        self.closePopover = close
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = GitRefPopoverStyle.pickerSize(
            branchCount: content.branches.count,
            worktreeCount: content.worktrees.count,
            tagCount: content.tags.count
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        let searchRow = NSStackView(views: [searchField, modeControl])
        searchRow.spacing = 6
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = GitL10n.text("Search branches…")
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.identifier = .init("git-collection-search")
        searchField.setAccessibilityLabel(GitL10n.text("Search branches…"))

        modeControl.segmentCount = GitCollectionMode.allCases.count
        modeControl.trackingMode = .selectOne
        modeControl.segmentStyle = .texturedRounded
        modeControl.controlSize = .small
        modeControl.selectedSegment = GitCollectionMode.allCases.firstIndex(of: mode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for (index, value) in GitCollectionMode.allCases.enumerated() {
            modeControl.setLabel("", forSegment: index)
            modeControl.setImage(NSImage(systemSymbolName: value.symbol, accessibilityDescription: value.title), forSegment: index)
            modeControl.setToolTip(GitL10n.format("{0} view", value.title), forSegment: index)
            modeControl.setWidth(26, forSegment: index)
        }
        modeControl.setAccessibilityLabel(GitL10n.text("Git collection view mode"))

        scopeControl.segmentCount = GitHistoryScope.allCases.count
        scopeControl.trackingMode = .selectOne
        scopeControl.segmentStyle = .rounded
        scopeControl.controlSize = .small
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        for (index, scope) in GitHistoryScope.allCases.enumerated() {
            scopeControl.setLabel(scope.displayName, forSegment: index)
            scopeControl.setToolTip(scope.displayName, forSegment: index)
            scopeControl.setWidth(110, forSegment: index)
        }
        scopeControl.setAccessibilityLabel(GitL10n.text("History branch scope"))

        let collection = makeCollection()
        let scroll = collection.makeNativeView(coordinator: collectionCoordinator, colors: content.nativeColors)
        let scopeSelection = GitHistoryScope.allCases.firstIndex {
            content.selectedID == "scope:" + $0.rawValue
        } ?? -1
        scopeControl.selectedSegment = scopeSelection

        let stack = NSStackView(views: [searchRow, scopeControl, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        query = searchField.stringValue
        collectionCoordinator.update(makeCollection())
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(command) {
        case "moveUp:": collectionController.move(-1)
        case "moveDown:": collectionController.move(1)
        case "insertNewline:": collectionController.activate()
        case "cancelOperation:": closePopover()
        default: return false
        }
        return true
    }

    @objc private func modeChanged() {
        guard GitCollectionMode.allCases.indices.contains(modeControl.selectedSegment) else { return }
        mode = GitCollectionMode.allCases[modeControl.selectedSegment]
        UserDefaults.standard.set(mode.rawValue, forKey: "git.refs.viewMode")
        collectionCoordinator.update(makeCollection())
    }

    @objc private func scopeChanged() {
        guard GitHistoryScope.allCases.indices.contains(scopeControl.selectedSegment) else { return }
        let scope = GitHistoryScope.allCases[scopeControl.selectedSegment]
        closePopover()
        content.perform(.selectHistoryScope(scope))
    }

    func saveAnchor() {
        collectionCoordinator.saveAnchor()
    }

    private func makeCollection() -> GitCollectionView {
        let selected = content.selectedID.map {
            $0.hasPrefix("refs/tags/") ? "ref:tag:" + String($0.dropFirst("refs/tags/".count)) : $0
        }
        return GitCollectionView(
            source: .refs(
                branches: content.branches,
                worktrees: content.worktrees,
                scopes: false,
                branchesError: content.enabled ? nil : GitL10n.text("Branch status unavailable"),
                worktreesError: content.worktreesError
            ),
            mode: mode,
            query: query,
            languageCode: GitL10n.current.languageCode,
            canWrite: !content.isBusy,
            interaction: .picker,
            state: content.state,
            stateKey: content.stateKey,
            selectedID: selected,
            extraRefs: content.tags,
            controller: collectionController,
            cancel: closePopover,
            perform: { [content, closePopover] action in
                closePopover()
                content.perform(action)
            },
            explicitColors: content.nativeColors
        )
    }
}
