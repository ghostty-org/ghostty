import AppKit
import SwiftUI

@MainActor
final class GitReferenceListPopoverController: NSViewController, NSSearchFieldDelegate {
    private let refs: [GitRefDecoration]
    private let initialSelection: GitRefDecoration?
    private let state: GitCollectionState
    private var colors: GitCollectionColors
    private let pasteboard: NSPasteboard
    private let close: () -> Void
    private let searchField = GitCollectionSearchField.Field()
    private let modeControl = GitPopoverSegments()
    private let copiedLabel = NSTextField(labelWithString: "")
    private let collectionCoordinator = GitCollectionView.Coordinator()
    private let collectionController = GitCollectionController()
    private var query = ""
    private var mode = GitCollectionMode(
        rawValue: UserDefaults.standard.string(forKey: "git.refs.viewMode") ?? ""
    ) ?? .tree
    var searchFieldForTesting: NSSearchField { searchField }
    var copiedLabelForTesting: NSTextField { copiedLabel }
    var refsForTesting: [GitRefDecoration] { refs }

    init(refs: [GitRefDecoration], selected: GitRefDecoration?, state: GitCollectionState,
         colors: GitCollectionColors, pasteboard: NSPasteboard,
         close: @escaping () -> Void) {
        self.refs = refs
        self.initialSelection = selected
        self.state = state
        self.colors = colors
        self.pasteboard = pasteboard
        self.close = close
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = GitRefPopoverStyle.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let searchRow = NSStackView(views: [searchField, modeControl])
        searchRow.orientation = .horizontal
        searchRow.spacing = 5
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.cell = GitSearchFieldCell(textCell: "")
        searchField.placeholderAttributedString = NSAttributedString(
            string: GitL10n.text("Search references…"),
            attributes: [.foregroundColor: colors.secondary, .font: NSFont.systemFont(ofSize: 11)]
        )
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBezeled = true
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.colors = colors
        searchField.textColor = colors.text
        searchField.delegate = self
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.identifier = NSUserInterfaceItemIdentifier("git-reference-search")
        searchField.setAccessibilityLabel(GitL10n.text("Search references…"))
        modeControl.configure(
            segments: GitCollectionMode.allCases.map {
                GitPopoverSegment(id: $0.rawValue, title: "", symbol: $0.symbol,
                                  accessibilityLabel: GitL10n.format("{0} view", $0.title))
            },
            selectedID: mode.rawValue,
            colors: colors,
            widths: Array(repeating: 26, count: GitCollectionMode.allCases.count)
        )
        modeControl.onSelect = { [weak self] id in self?.selectMode(id) }

        let scroll = makeCollection().makeNativeView(coordinator: collectionCoordinator, colors: colors)
        copiedLabel.stringValue = ""
        copiedLabel.textColor = .secondaryLabelColor
        copiedLabel.font = .systemFont(ofSize: 10)
        copiedLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [searchRow, scroll, copiedLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            modeControl.widthAnchor.constraint(equalToConstant: 54),
            modeControl.heightAnchor.constraint(equalToConstant: 26),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            copiedLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            copiedLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        view = root
        root.onThemeChange = { [weak self] theme in self?.applyTheme(theme) }
    }

    func bindTheme(to window: NSWindow?) {
        _ = view
        (view as? OMGNativeSurfaceView)?.bindTheme(to: window)
    }

    private func applyTheme(_ theme: OMGNativeTheme) {
        colors = GitCollectionColors(nativeTheme: theme)
        searchField.colors = colors
        searchField.textColor = colors.text
        searchField.placeholderAttributedString = NSAttributedString(string: GitL10n.text("Search references…"),
            attributes: [.foregroundColor: colors.secondary, .font: NSFont.systemFont(ofSize: 11)])
        (searchField.currentEditor() as? NSTextView)?.textColor = colors.text
        searchField.needsDisplay = true
        modeControl.applyTheme(theme)
        copiedLabel.textColor = theme.secondary
        collectionCoordinator.update(makeCollection())
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        query = field.stringValue
        collectionCoordinator.update(makeCollection())
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch NSStringFromSelector(command) {
        case "moveUp:": collectionController.move(-1)
        case "moveDown:": collectionController.move(1)
        case "insertNewline:": collectionController.activate()
        case "cancelOperation:": close()
        default: return false
        }
        return true
    }

    func saveAnchor() { collectionCoordinator.saveAnchor() }

    private func selectMode(_ id: String) {
        guard let next = GitCollectionMode(rawValue: id), next != mode else { return }
        mode = next
        UserDefaults.standard.set(mode.rawValue, forKey: "git.refs.viewMode")
        collectionCoordinator.update(makeCollection())
    }

    private func makeCollection() -> GitCollectionView {
        GitCollectionView(
            source: .decorations(refs),
            mode: mode,
            query: query,
            languageCode: GitL10n.current.languageCode,
            interaction: .references,
            state: state,
            stateKey: "decoration-refs",
            selectedID: initialSelection.map(GitCollectionBuilder.referenceID),
            pasteboard: pasteboard,
            referenceAction: { [weak self] ref in
                guard let self else { return }
                InspectorCopyMenu.copy(ref.name, to: self.pasteboard)
                self.copiedLabel.stringValue = GitL10n.text("Copied")
            },
            controller: collectionController,
            cancel: close,
            perform: { _ in },
            explicitColors: colors
        )
    }
}

/// Repository refs stay named and visible; long names wrap instead of aggregating.
struct GitHeaderReferences: NSViewRepresentable {
    let refs: [GitRefDecoration]
    func makeNSView(context: Context) -> GitHeaderReferencesView {
        let view = GitHeaderReferencesView()
        view.configure(refs)
        return view
    }
    func updateNSView(_ view: GitHeaderReferencesView, context: Context) { view.configure(refs) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GitHeaderReferencesView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: nsView.frames(width: width).map(\.maxY).max() ?? 0)
    }
}

final class GitHeaderReferencesView: NSView {
    private var refs: [GitRefDecoration] = []
    private var fields: [InspectorCopyableTextField] = []
    override var isFlipped: Bool { true }

    func configure(_ refs: [GitRefDecoration]) {
        guard self.refs != refs else { return }
        self.refs = refs
        fields.forEach { $0.removeFromSuperview() }
        fields = refs.map { ref in
            let field = InspectorCopyableTextField(wrappingLabelWithString: "")
            field.attributedStringValue = GitRefBadgesView.attributed(ref)
            // The shared field editor flattens symbol attachments on selection.
            // Keep this a display label; the context menu copies the full ref.
            field.isSelectable = false
            field.lineBreakMode = .byCharWrapping
            field.maximumNumberOfLines = 0
            field.copyValue = ref.name
            field.toolTip = ref.name
            field.setAccessibilityLabel(ref.kind.displayName + ": " + ref.name)
            field.wantsLayer = true
            field.layer?.cornerRadius = 3
            field.layer?.backgroundColor = GitRefBadgesView.tint(for: ref.kind).withAlphaComponent(0.10).cgColor
            addSubview(field)
            return field
        }
        needsLayout = true
    }

    func frames(width: CGFloat) -> [NSRect] {
        let available = max(1, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return fields.map { field in
            let width = min(available, ceil(field.attributedStringValue.size().width) + 4)
            if x > 0, x + width > available { x = 0; y += rowHeight + 4; rowHeight = 0 }
            let height = max(17, ceil(field.cell?.cellSize(forBounds:
                NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 17))
            let frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 4
            rowHeight = max(rowHeight, height)
            return frame
        }
    }

    override func layout() {
        super.layout()
        for (field, frame) in zip(fields, frames(width: bounds.width)) { field.frame = frame }
    }
}

struct InspectorCopyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> InspectorCopyableTextField {
        let view = InspectorCopyableTextField(labelWithString: "")
        view.isSelectable = true
        view.font = .systemFont(ofSize: 10)
        view.textColor = .secondaryLabelColor
        view.lineBreakMode = .byTruncatingMiddle
        view.maximumNumberOfLines = 1
        return view
    }
    func updateNSView(_ view: InspectorCopyableTextField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        view.toolTip = text
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorCopyableTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 14)
    }
}
