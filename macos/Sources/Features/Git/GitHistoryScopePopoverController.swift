import AppKit

@MainActor
final class GitHistoryScopePopoverController: NSViewController, NSSearchFieldDelegate {
    private let content: GitHistoryScopePicker
    private let closePopover: () -> Void
    private let searchField = GitCollectionSearchField.Field()
    private let scopeControl = GitPopoverSegments()
    private let modeControl = GitPopoverSegments()
    private let collectionCoordinator = GitCollectionView.Coordinator()
    private let collectionController = GitCollectionController()
    private var query = ""
    private var mode = GitCollectionMode(rawValue: UserDefaults.standard.string(forKey: "git.refs.viewMode") ?? "") ?? .tree
    var searchFieldForTesting: GitCollectionSearchField.Field { searchField }
    var scopeControlForTesting: GitPopoverSegments { scopeControl }
    var modeControlForTesting: GitPopoverSegments { modeControl }

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
        let root = GitPopoverBackgroundView(backgroundColor: content.nativeColors.background)
        let searchRow = NSStackView(views: [searchField, modeControl])
        searchRow.spacing = 5
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        searchField.cell = GitSearchFieldCell(textCell: "")
        searchField.placeholderAttributedString = NSAttributedString(
            string: GitL10n.text("Search branches…"),
            attributes: [.foregroundColor: content.nativeColors.secondary, .font: NSFont.systemFont(ofSize: 11)]
        )
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBezeled = true
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.colors = content.nativeColors
        searchField.textColor = content.nativeColors.text
        searchField.delegate = self
        searchField.identifier = .init("git-collection-search")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel(GitL10n.text("Search branches…"))

        modeControl.configure(
            segments: GitCollectionMode.allCases.map {
                GitPopoverSegment(id: $0.rawValue, title: "", symbol: $0.symbol,
                                  accessibilityLabel: GitL10n.format("{0} view", $0.title))
            },
            selectedID: mode.rawValue,
            colors: content.nativeColors,
            widths: Array(repeating: 26, count: GitCollectionMode.allCases.count)
        )
        modeControl.onSelect = { [weak self] id in self?.selectMode(id) }

        let selectedScope = content.selectedID.flatMap {
            $0.hasPrefix("scope:") ? String($0.dropFirst("scope:".count)) : nil
        }
        scopeControl.configure(
            segments: GitHistoryScope.allCases.map {
                GitPopoverSegment(id: $0.rawValue, title: $0.displayName,
                                  accessibilityLabel: $0.displayName)
            },
            selectedID: selectedScope,
            colors: content.nativeColors,
            widths: Array(repeating: (preferredContentSize.width - 22) / 2, count: GitHistoryScope.allCases.count)
        )
        scopeControl.onSelect = { [weak self] id in self?.selectScope(id) }

        let collection = makeCollection()
        let scroll = collection.makeNativeView(coordinator: collectionCoordinator, colors: content.nativeColors)

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
            searchField.heightAnchor.constraint(equalToConstant: 28),
            modeControl.widthAnchor.constraint(equalToConstant: 54),
            modeControl.heightAnchor.constraint(equalToConstant: 26),
            scopeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scopeControl.heightAnchor.constraint(equalToConstant: 26),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        searchField.setFocused(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        searchField.setFocused(false)
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

    private func selectMode(_ id: String) {
        guard let next = GitCollectionMode(rawValue: id), next != mode else { return }
        mode = next
        UserDefaults.standard.set(mode.rawValue, forKey: "git.refs.viewMode")
        collectionCoordinator.update(makeCollection())
    }

    private func selectScope(_ id: String) {
        guard let scope = GitHistoryScope(rawValue: id) else { return }
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
